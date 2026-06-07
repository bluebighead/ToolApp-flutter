// FFmpeg 视频转换服务
// 封装 FFmpeg 命令构造、会话执行、进度回调、错误解析
//
// 设计原则：完全信任 FFmpeg 自带的 HLS demuxer
// FFmpeg 的 HLS demuxer 是业界处理 M3U8/HLS 的标准实现，
// 经过 FFmpeg 官方多年打磨，能正确处理：
//   - 各种 segment 命名（带不带扩展名、纯数字、带子目录等）
//   - AES-128 加密的 segment
//   - HTTP/HTTPS/file 协议的混合引用
//   - 主播放列表 + 媒体播放列表的多级结构
//   - EXT-X-KEY / EXT-X-MAP / EXT-X-DISCONTINUITY 等扩展标签
// 因此本服务不进行任何 M3U8 预处理，把 M3U8/视频 URL/文件路径
// 直接交给 FFmpeg 处理即可
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import 'app_logger.dart';
import 'm3u8_normalizer.dart';

/// 输出质量档位
/// 对应不同的 FFmpeg 编码参数
enum VideoQuality {
  /// 原画质：仅做封装转换（-c copy），不重新编码，最快，体积基本不变
  original,

  /// 高画质：libx264 CRF 18，画质损失极小，体积略缩
  high,

  /// 标准：libx264 CRF 23，画质与体积平衡（推荐默认值）
  standard,

  /// 高压缩：libx264 CRF 28，体积最小，画质可接受
  low,
}

/// 输出视频容器格式
enum VideoFormat {
  /// MP4：兼容性最好（首选）
  mp4,

  /// MKV：开源容器，支持任意编码组合
  mkv,

  /// MOV：Apple 生态
  mov,
}

/// 转换进度信息
class ConvertProgress {
  /// 0.0 ~ 1.0
  final double value;

  /// 是否拿到了总时长（true=确定式进度，false=不确定式进度）
  final bool hasDuration;

  /// 实时码率（如 "1234kbits/s"）
  final String bitrate;

  /// 已处理时长（如 "00:01:23.45"）
  final String time;

  /// 预估剩余时间（秒），可能为 null（进度刚开始或没有总时长时）
  ///
  /// 计算方式：(totalDuration - currentTime) / (currentTime - elapsedWallClock) * elapsedWallClock
  /// 即基于"实时进度"线性外推
  final int? etaSeconds;

  const ConvertProgress({
    required this.value,
    required this.hasDuration,
    this.bitrate = '',
    this.time = '',
    this.etaSeconds,
  });
}

/// 转换结果
class ConvertResult {
  /// 输出文件的完整路径
  final String outputPath;

  /// 输出文件大小（字节）
  final int outputSize;

  /// 源时长（毫秒，可能为 null）
  final int? sourceDurationMs;

  const ConvertResult({
    required this.outputPath,
    required this.outputSize,
    this.sourceDurationMs,
  });
}

/// FFmpeg 视频转换服务
/// 负责构造 FFmpeg 命令、执行转换、回调进度与日志
class FFmpegService {
  /// 全局注册的日志回调
  static const String _logTag = 'FFmpegService';

  /// 当前正在运行的会话（用于取消）
  Session? _session;

  /// 是否正在执行转换
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// 最近一次统计回调中的已编码时长（毫秒）
  ///
  /// 用于 v1.6.21+ 的"暂停"功能：
  ///   用户点暂停 → Coordinator 读这个值 → 持久化 → 后续 resume 时从这点继续
  ///
  /// 为什么放在 Service 而不是 Coordinator：
  ///   statistics 回调只在 Service 内部能稳定拿到（FFmpegKit 全局回调粒度太粗），
  ///   所以由 Service 负责"记住"最后一帧的时间。
  int _lastEncodedTimeMs = 0;
  int get lastEncodedTimeMs => _lastEncodedTimeMs;

  /// 注册全局日志回调（App 启动时调用一次即可）
  static void registerGlobalCallbacks() {
    // 启用 FFmpeg 日志回调，写入 AppLogger
    FFmpegKitConfig.enableLogCallback((log) {
      final msg = log.getMessage();
      if (msg.isEmpty) return;
      AppLogger.d(_logTag, msg);
    });
  }

  /// 探测输入源的时长（毫秒）
  /// 支持本地文件路径、http(s):// URL、m3u8(m) URL
  /// 失败返回 null
  Future<int?> probeDurationMs(String input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input);
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo == null) return null;
      final durationStr = mediaInfo.getDuration();
      if (durationStr == null || durationStr.isEmpty) return null;
      // FFprobe 返回的 duration 单位为秒（字符串形式）
      final seconds = double.tryParse(durationStr);
      if (seconds == null) return null;
      final ms = (seconds * 1000).round();
      return ms > 0 ? ms : null;
    } catch (e, st) {
      AppLogger.w(_logTag, '探测时长失败：$e', e);
      AppLogger.d(_logTag, '堆栈：$st');
      return null;
    }
  }

  /// 探测输入源的码率（kbps）
  ///
  /// 实现细节：
  ///   1) 优先用 `MediaInfo.getBitrate()`（FFprobe 全局码率，含音视频总和）
  ///   2) 若全局码率不可用，累加各 stream 的码率（视频 + 音频）
  ///   3) 都不行时返回 null，调用方应走"未知"占位
  ///
  /// 单位说明：ffmpeg_kit_flutter_new 中 getBitrate() 返回 String（形如 "1234 kb/s"），
  /// 本方法内部解析后统一转换为 kbps 整数返回。
  Future<int?> probeBitrateKbps(String input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input);
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo == null) return null;
      // 1) 优先用全局码率
      final overall = mediaInfo.getBitrate();
      final overallKbps = _parseBitrateString(overall);
      if (overallKbps != null && overallKbps > 0) {
        return overallKbps;
      }
      // 2) 累加 stream 码率
      final streams = mediaInfo.getStreams();
      if (streams.isEmpty) return null;
      int totalKbps = 0;
      bool hasAny = false;
      for (final s in streams) {
        final kbps = _parseBitrateString(s.getBitrate());
        if (kbps != null && kbps > 0) {
          totalKbps += kbps;
          hasAny = true;
        }
      }
      if (!hasAny) return null;
      return totalKbps;
    } catch (e, st) {
      AppLogger.w(_logTag, '探测码率失败：$e', e);
      AppLogger.d(_logTag, '堆栈：$st');
      return null;
    }
  }

  /// 解析 FFprobe 返回的码率字符串为 kbps 整数
  ///
  /// 支持的形式（ffmpeg 输出常见格式）：
  ///   - "1234 kb/s"
  ///   - "1.5 Mb/s"  → 1500 kb/s
  ///   - "2.3 mb/s"  → 2300 kb/s（大小写不敏感）
  ///   - "N/A" / ""  / null → null
  ///   - 纯数字 "1234" → 1234
  int? _parseBitrateString(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty || s.toUpperCase() == 'N/A') return null;
    // 提取前导数字（含可选小数点）
    final m = RegExp(r'([\d.]+)').firstMatch(s);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    // 单位换算
    final upper = s.toUpperCase();
    if (upper.contains('MB/S') || upper.contains('MBPS')) {
      return (n * 1000).round();
    }
    // "kb/s" 或 "kbps" 或无单位 → 视为 kb/s
    return n.round();
  }

  /// 执行 M3U8/视频 → MP4/MKV/MOV 转换
  ///
  /// [input] 输入源：本地文件绝对路径 或 http(s):// URL
  /// [outputPath] 输出文件绝对路径（含扩展名）
  /// [format] 输出容器格式（影响输出文件扩展名与编码参数）
  /// [quality] 质量档位
  /// [onProgress] 进度回调
  /// [onLog] 日志回调（可选）
  ///
  /// 返回：ConvertResult（成功）或抛出异常（失败）
  Future<ConvertResult> convert({
    required String input,
    required String outputPath,
    required VideoFormat format,
    required VideoQuality quality,
    required void Function(ConvertProgress progress) onProgress,
    void Function(String log)? onLog,
  }) async {
    if (_isRunning) {
      throw StateError('已有转换任务在进行中，请先取消');
    }
    _isRunning = true;
    _lastEncodedTimeMs = 0;

    // 关键调试：确认 input 路径与文件存在性
    AppLogger.i(_logTag, 'convert() 被调用，input=$input');
    if (input.startsWith('/') || input.contains(':\\')) {
      final f = File(input);
      AppLogger.i(_logTag, 'input 文件存在：${await f.exists()}，大小：${await f.length().catchError((_) => 0)} bytes');
    }

    // 重要：本地 M3U8 文件可能引用非标准扩展名的 segment（如 "0"、"1"），
    // FFmpeg 协议层会拒绝。预先规范化，转换为 .ts。
    M3U8NormalizeResult? normalizeResult;
    String effectiveInput = input;
    try {
      normalizeResult = await M3U8Normalizer.normalize(input);
      if (normalizeResult != null) {
        // 优先用合并后的单文件路径（merged.ts）作为 FFmpeg 输入。
        // 相比 normalized.m3u8（让 FFmpeg 自己走 HLS demuxer 一个个
        // open/parse segment），单文件输入：
        //   1) FFmpeg 一次 open()，一次 seek
        //   2) 不需要再解析 M3U8 playlist
        //   3) HLS demuxer 不再为每个 segment 单独建 stream
        // 这对几千个小 segment 的 M3U8 是数量级的提速。
        if (normalizeResult.mergedTsPath != null) {
          effectiveInput = normalizeResult.mergedTsPath!;
        } else {
          effectiveInput = normalizeResult.normalizedM3u8Path;
        }
        AppLogger.i(
          _logTag,
          '本地 M3U8 已规范化：${normalizeResult.tempDir.path}，'
          '使用输入：$effectiveInput'
          '${normalizeResult.mergedTsPath != null ? "（合并TS）" : "（走HLS）"}',
        );
      }

      // 先探测时长
      final durationMs = await probeDurationMs(effectiveInput);
      AppLogger.i(_logTag, '输入源时长：${durationMs ?? '未知'} ms');

      // 构造 FFmpeg 参数
      final args = _buildArgs(
        input: effectiveInput,
        outputPath: outputPath,
        format: format,
        quality: quality,
      );
      final command = args.join(' ');
      AppLogger.i(_logTag, '执行 FFmpeg 命令：$command');

      // 记录转换开始时刻（用于 ETA 预估）
      final startWallClockMs = DateTime.now().millisecondsSinceEpoch;
      // 启用统计回调
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        _onStatistics(statistics, durationMs, startWallClockMs, onProgress);
      });

      // 创建并执行会话
      final completer = Completer<ConvertResult>();
      _session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (completedSession) async {
          try {
            final returnCode = await completedSession.getReturnCode();
            AppLogger.i(_logTag, 'FFmpeg 返回码：$returnCode');

            if (ReturnCode.isSuccess(returnCode)) {
              // 成功：取输出文件信息
              int outSize = 0;
              try {
                final f = File(outputPath);
                if (await f.exists()) {
                  outSize = await f.length();
                }
              } catch (e) {
                AppLogger.w(_logTag, '读取输出文件大小失败：$e');
              }
              completer.complete(ConvertResult(
                outputPath: outputPath,
                outputSize: outSize,
                sourceDurationMs: durationMs,
              ));
            } else if (ReturnCode.isCancel(returnCode)) {
              completer.completeError(
                const FFmpegException('用户已取消转换', isCancelled: true),
              );
            } else {
              // 失败：取完整日志
              final logs = await completedSession.getAllLogsAsString() ?? '';
              final realError = _extractErrorMessage(logs);
              completer.completeError(
                FFmpegException(realError, fullLogs: logs),
              );
            }
          } catch (e, st) {
            AppLogger.e(_logTag, '处理 FFmpeg 回调时异常', e, st);
            completer.completeError(e, st);
          }
        },
        (log) {
          final msg = log.getMessage();
          if (msg.isEmpty) return;
          AppLogger.d(_logTag, msg);
          onLog?.call(msg);
        },
        (statistics) {
          _onStatistics(statistics, durationMs, startWallClockMs, onProgress);
        },
      );

      return await completer.future;
    } finally {
      _isRunning = false;
      _session = null;
    }
  }

  /// 取消当前正在执行的转换
  Future<void> cancel() async {
    final s = _session;
    if (s == null) {
      AppLogger.i(_logTag, '无运行中的会话，跳过取消');
      return;
    }
    AppLogger.i(_logTag, '用户请求取消 FFmpeg 会话');
    await s.cancel();
  }

  // ------------------------------------------------------------------
  // 恢复转换（v1.6.21+ 新增）
  // ------------------------------------------------------------------

  /// 从指定时间点继续编码，并把结果与已有部分拼接成完整文件
  ///
  /// 调用前提（由 Coordinator 校验）：
  ///   - partialOutputPath：上次被暂停时 FFmpeg 写到一半的输出文件
  ///     （可能没有 moov atom，不完整）
  ///   - resumeFromMs：从哪个媒体时间点继续编码（毫秒）
  ///   - 其余参数：与 convert() 一致
  ///
  /// 实现策略（两步）：
  ///   1) **再编码剩余段**：
  ///      `ffmpeg -y -ss <ms> -i INPUT ... <encode-args> <output>.part2`
  ///      用 `-ss` 跳过已编码的媒体时间，编码剩下的内容到临时文件
  ///   2) **拼接两段**：
  ///      `ffmpeg -y -i <partial> -i <part2> -filter_complex
  ///         [0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]
  ///         -map [v] -map [a] -c copy <final>`
  ///      用 concat filter 把两段拼起来，**c copy** 不重新编码，速度极快
  ///
  /// 为什么用 concat filter 而不是 demuxer（-f concat）：
  ///   - demuxer 要求两段都有完整 moov atom，而被 cancel 的 partial 通常没有
  ///   - filter 会自动 remux 输入，容忍不完整的 mp4
  ///   - 拼接处会做"边界对齐"，避免出现花屏/卡顿
  ///
  /// 关于 part2 的输入参数：
  ///   - `-ss` 放在 `-i` 前面：input seek，比 output seek 快得多
  ///   - 不加 `-t`：让编码跑到文件自然结束
  ///
  /// 返回 ConvertResult：与 convert() 行为一致
  Future<ConvertResult> convertResume({
    required String input,
    required String partialOutputPath,
    required String finalOutputPath,
    required int resumeFromMs,
    required VideoFormat format,
    required VideoQuality quality,
    required void Function(ConvertProgress progress) onProgress,
    void Function(String log)? onLog,
  }) async {
    if (_isRunning) {
      throw StateError('已有转换任务在进行中，请先取消');
    }
    _isRunning = true;
    _lastEncodedTimeMs = 0;

    AppLogger.i(
      _logTag,
      'convertResume() 被调用：input=$input，'
      'resumeFromMs=$resumeFromMs，partial=$partialOutputPath',
    );

    final part2Path = '$partialOutputPath.part2';

    try {
      // ============ 第一步：编码剩余段 ============
      // 关键：在 base 数组里插入 -ss <ms>，放在 -i 之前
      // 这样 FFmpeg 在 demux 阶段就 seek，编码器从 seek 点开始推帧
      final seekSeconds = resumeFromMs / 1000.0;
      final encodeArgs = _buildArgs(
        input: input,
        outputPath: part2Path,
        format: format,
        quality: quality,
        seekSeconds: seekSeconds,
      );
      AppLogger.i(_logTag, '恢复-编码剩余段：${encodeArgs.join(' ')}');

      await _executeSimple(
        args: encodeArgs,
        sourceName: 'resume-encode',
        onProgress: (p) {
          // 第一步只占整体的 70%（剩下 30% 留给 concat），
          // 让 UI 进度条不至于到 100% 然后又跳一下
          onProgress(ConvertProgress(
            value: p.value * 0.7,
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            time: p.time,
            etaSeconds: p.etaSeconds,
          ));
        },
        onLog: onLog,
      );

      // ============ 第二步：拼接两段 ============
      AppLogger.i(_logTag, '恢复-拼接两段：$partialOutputPath + $part2Path');
      final concatArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel', 'info',
        '-i', partialOutputPath,
        '-i', part2Path,
        // concat filter：n=2 表示两段输入，v=1/a=1 表示 1 路视频 1 路音频
        // [0:v][0:a] 是第一段，标签 v/a 喂给 concat 的 v/a 槽
        '-filter_complex',
        '[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]',
        '-map', '[v]',
        '-map', '[a]',
        // 用 -c copy 避免重新编码，速度快 10 倍以上
        // 拼接处有微小不连续的风险（keyframe 错位），但对一般观看无感
        '-c', 'copy',
        // 强制 faststart，让输出能立即被播放器读取
        if (format == VideoFormat.mp4) ...['-movflags', '+faststart'],
        finalOutputPath,
      ];
      AppLogger.i(_logTag, '恢复-拼接命令：${concatArgs.join(' ')}');

      // 拼接进度：先推一个 70%~85% 的"过渡值"，让用户感觉在动
      onProgress(ConvertProgress(
        value: 0.85,
        hasDuration: true,
        bitrate: '',
        time: '',
        etaSeconds: 0,
      ));
      await _executeSimple(
        args: concatArgs,
        sourceName: 'resume-concat',
        onProgress: (p) {
          // 第二步从 0.7 推到 0.99
          onProgress(ConvertProgress(
            value: 0.7 + p.value * 0.29,
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            time: p.time,
            etaSeconds: p.etaSeconds,
          ));
        },
        onLog: onLog,
      );

      // 清理 part2
      try {
        final f = File(part2Path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        AppLogger.w(_logTag, '清理 part2 失败：$e');
      }

      // 取最终输出文件大小
      int outSize = 0;
      try {
        final f = File(finalOutputPath);
        if (await f.exists()) outSize = await f.length();
      } catch (e) {
        AppLogger.w(_logTag, '读取最终输出大小失败：$e');
      }

      AppLogger.i(_logTag, '恢复完成：$finalOutputPath（$outSize bytes）');
      return ConvertResult(
        outputPath: finalOutputPath,
        outputSize: outSize,
        sourceDurationMs: null, // 恢复时不再关心源时长
      );
    } finally {
      _isRunning = false;
      _session = null;
    }
  }

  /// 简化的"执行一次 FFmpeg 命令"工具，给 convertResume 复用
  ///
  /// 与 convert() 的区别：
  ///   - 不做 M3U8 归一化（调用方自己保证 input 合法）
  ///   - 不做时长探测（resume 场景下不需要）
  ///   - 失败抛 FFmpegException，成功正常返回
  Future<void> _executeSimple({
    required List<String> args,
    required String sourceName,
    required void Function(ConvertProgress) onProgress,
    void Function(String log)? onLog,
  }) async {
    final startWallClockMs = DateTime.now().millisecondsSinceEpoch;
    // 启用统计回调（无 sourceDuration，用占位）
    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      _onStatistics(
        statistics,
        1, // 占位"总时长"=1ms，让 onProgress.value = timeMs
        startWallClockMs,
        onProgress,
      );
    });

    final completer = Completer<void>();
    _session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (completedSession) async {
        try {
          final returnCode = await completedSession.getReturnCode();
          if (ReturnCode.isSuccess(returnCode)) {
            completer.complete();
          } else if (ReturnCode.isCancel(returnCode)) {
            completer.completeError(
              const FFmpegException('用户已取消转换', isCancelled: true),
            );
          } else {
            final logs = await completedSession.getAllLogsAsString() ?? '';
            final realError = _extractErrorMessage(logs);
            completer.completeError(
              FFmpegException(realError, fullLogs: logs),
            );
          }
        } catch (e, st) {
          completer.completeError(e, st);
        }
      },
      (log) {
        final msg = log.getMessage();
        if (msg.isEmpty) return;
        AppLogger.d(_logTag, '[$sourceName] $msg');
        onLog?.call(msg);
      },
      (statistics) {
        _onStatistics(
          statistics,
          1,
          startWallClockMs,
          onProgress,
        );
      },
    );

    return await completer.future;
  }

  // ------------------------------------------------------------------
  // 内部：构造 FFmpeg 参数
  // ------------------------------------------------------------------

  /// 构造 FFmpeg 命令参数
  /// 关键：完全信任 FFmpeg 自带的 HLS demuxer
  /// 只需要给它正确的输入与输出，FFmpeg 会自动处理：
  ///   - M3U8 解析
  ///   - segment 下载与拼接
  ///   - 解密（AES-128）
  ///   - 转封装 / 转码
  ///   - 输出容器
  ///
  /// 速度优化（v1.6.13+）：
  ///   - `-threads 0` —— 自动用满所有 CPU 核心（FFmpeg 默认 1 线程，慢）
  ///   - `preset` 从 `medium` 改为 `veryfast` —— 编码速度快 3~4 倍，
  ///     体积增加约 10~20%，对转换效率提升巨大
  ///   - 网络参数 `-reconnect*` —— HLS segment 下载中断时自动重连，
  ///     避免整段转换失败
  ///   - `-timeout` —— 单个 segment 30s 超时，避免卡死
  List<String> _buildArgs({
    required String input,
    required String outputPath,
    required VideoFormat format,
    required VideoQuality quality,
    double? seekSeconds,
  }) {
    // 通用前缀：
    // -y：覆盖输出
    // -hide_banner：精简日志（去掉版本/配置 banner）
    // -loglevel info：保证能看到进度和错误
    // -stats：让 FFmpeg 在 stderr 输出实时进度
    // -threads 0：自动用满所有 CPU 核心（默认仅 1 线程，大文件慢）
    // -fflags +genpts+igndts+fastseek：
    //     +genpts    — 没有 PTS 时自动生成（segment 拼接场景常见）
    //     +igndts    — 忽略源里的 DTS，避免拼接后时间戳跳变触发警告
    //     +fastseek  — 启用快速 seek，seek 阶段 IO 读取大文件更高效
    // -analyzeduration / -probesize：把初始探测限制在 5MB / 1s，
    //     默认是 5MB+5s，对单文件无意义但会拖慢启动
    //
    // 关于曾用过的几个被这个 ffmpeg 套件拒绝的选项（v1.6.16 移除）：
    //   -reconnect / -reconnect_at_eof / -reconnect_streamed /
    //   -reconnect_delay_max / -timeout：
    //     需要 libavformat 启用网络扩展，该套件未编译进去
    //     → 报 "Option reconnect not found."
    //   -protocol_whitelist / -allowed_extensions：
    //     HLS demuxer 专用的旧版选项，要求 demuxer 模块内置这些选项；
    //     该套件的 HLS 模块没编译进去
    //     → 报 "Option allowed_extensions not found."
    //   现在所有本地 M3U8 都已经在 M3U8Normalizer 阶段把 segment
    //   拼接成 merged.ts 再喂给 FFmpeg，HLS demuxer 根本不会参与；
    //   网络 M3U8 走 FFmpeg 默认白名单也够用（http/https + .ts/.m4s）。
    //
    // v1.6.21+ 新增：可选 -ss <seconds>（在 -i 之前），给"恢复"功能用。
    //   input seek 比 output seek 快得多，且对编码器友好。
    final base = <String>[
      '-y',
      '-hide_banner',
      '-loglevel', 'info',
      '-stats',
      '-fflags', '+genpts+igndts+fastseek',
      '-analyzeduration', '5000000', // 5MB
      '-probesize', '5000000',
      '-threads', '0',
      if (seekSeconds != null && seekSeconds > 0) ...[
        '-ss', seekSeconds.toStringAsFixed(3),
      ],
      '-i', input,
    ];

    // 编码参数
    final encodeArgs = <String>[];

    // 注意：当 quality == original 时，使用 -c copy（不重新编码）
    // 复制模式下，转封装到不同容器是 FFmpeg 拿手好戏
    // 这是最快的模式（通常 10s 内完成 1GB 文件），适合不需要重新编码的场景
    if (quality == VideoQuality.original) {
      encodeArgs.addAll(['-c', 'copy']);
    } else {
      // 转码模式：根据质量档位选择 CRF + preset
      int crf;
      // preset 选择：
      //   - 'ultrafast'：最快，文件最大，画质略差
      //   - 'veryfast'：快 3~4 倍于 medium，体积增加 10~20%（推荐）
      //   - 'medium'：默认平衡点（之前用这个，太慢）
      String preset;
      int audioBitrateK;
      switch (quality) {
        case VideoQuality.high:
          crf = 18;
          preset = 'veryfast';
          audioBitrateK = 192;
          break;
        case VideoQuality.standard:
          crf = 23;
          preset = 'veryfast';
          audioBitrateK = 128;
          break;
        case VideoQuality.low:
          crf = 28;
          preset = 'veryfast';
          audioBitrateK = 96;
          break;
        case VideoQuality.original:
          // 不会走到这里，上面已处理
          crf = 0;
          preset = 'ultrafast';
          audioBitrateK = 128;
      }
      encodeArgs.addAll([
        '-c:v', 'libx264',
        '-preset', preset,
        '-crf', '$crf',
        '-pix_fmt', 'yuv420p', // 提升兼容性
        '-c:a', 'aac',
        '-b:a', '${audioBitrateK}k',
        // movflags 对 MP4 输出尤其重要：让 moov atom 写到文件头部，
        // 这样转换完成的 MP4 可以立即被播放器读取（无需先 seek）
        if (format == VideoFormat.mp4) ...[
          '-movflags', '+faststart',
        ],
      ]);
    }

    return [...base, ...encodeArgs, outputPath];
  }

  // ------------------------------------------------------------------
  // 内部：进度回调
  // ------------------------------------------------------------------

  /// FFmpeg 统计回调
  /// 解析 time / bitrate 计算进度百分比 + 估算剩余时间
  /// 注意：ffmpeg_kit_flutter_new 的 API：
  ///   - getTime() 返回 int（毫秒，非 nullable）
  ///   - getBitrate() 返回 double（kbits/s，非 nullable）
  ///
  /// ETA 估算逻辑：
  ///   - 已用墙钟时间 = now - startWallClockMs
  ///   - 已处理媒体时长 = timeMs
  ///   - 处理速度（媒体秒/墙钟秒）= timeMs / elapsedMs
  ///   - 剩余媒体时长 = totalDurationMs - timeMs
  ///   - 估算剩余墙钟时间 = 剩余媒体时长 / 处理速度
  ///     = (totalDurationMs - timeMs) * elapsedMs / timeMs
  ///
  /// 在转换速度波动大（HLS 边下边转）时这个估算误差会较大，
  /// 但作为"大致还有多久"显示是够用的。开始几秒会因 timeMs 太小而
  /// 估算偏大，所以会先累计 2 秒有效数据再开始报 ETA。
  void _onStatistics(
    Statistics statistics,
    int? totalDurationMs,
    int startWallClockMs,
    void Function(ConvertProgress) onProgress,
  ) {
    if (totalDurationMs == null || totalDurationMs <= 0) {
      // 拿不到总时长：返回不确定式进度
      onProgress(const ConvertProgress(
        value: 0.0,
        hasDuration: false,
      ));
      return;
    }
    final timeMs = statistics.getTime();
    if (timeMs < 0) {
      onProgress(ConvertProgress(
        value: 0.0,
        hasDuration: true,
      ));
      return;
    }
    // 记录最后一帧的时间，给"暂停"功能用
    _lastEncodedTimeMs = timeMs;
    final p = (timeMs / totalDurationMs).clamp(0.0, 1.0);
    final bitrate = statistics.getBitrate();

    // 计算 ETA
    int? etaSeconds;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - startWallClockMs;
    // 只在累计 2 秒以上数据且处理进度 > 1% 时报 ETA，避免开局数字乱跳
    if (elapsedMs >= 2000 && timeMs >= (totalDurationMs * 0.01).toInt()) {
      final remainingMs = (totalDurationMs - timeMs).clamp(0, totalDurationMs);
      // 公式：eta_ms = remainingMs * elapsedMs / timeMs
      // 加 500ms 做四舍五入
      final etaMs = (remainingMs * elapsedMs / timeMs + 500).round();
      var eta = etaMs ~/ 1000;
      // 兜底：ETA 超过 24h 视为异常，不显示
      if (eta > 86400) eta = -1;
      // 兜底：ETA < 0 不显示
      etaSeconds = eta < 0 ? null : eta;
    }

    onProgress(ConvertProgress(
      value: p.toDouble(),
      hasDuration: true,
      bitrate: bitrate > 0 ? '${bitrate.toStringAsFixed(0)}kbits/s' : '',
      time: _formatTimeMs(timeMs),
      etaSeconds: etaSeconds,
    ));
  }

  /// 把毫秒格式化为 HH:MM:SS.ms 字符串
  String _formatTimeMs(int ms) {
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final mss = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${mss.toString().padLeft(3, '0')}';
  }

  // ------------------------------------------------------------------
  // 内部：错误信息提取
  // ------------------------------------------------------------------

  /// 从 FFmpeg 全量日志中提取真正有用的错误信息
  /// 过滤掉版本/配置 banner、进度行等噪音
  String _extractErrorMessage(String logs) {
    if (logs.isEmpty) return '未知错误（无 FFmpeg 日志）';
    final lines = logs.split('\n');
    // 这些前缀都是 FFmpeg 启动 banner 或进度行，对用户没用
    const noisePrefixes = <String>[
      'ffmpeg version',
      'built with',
      'configuration:',
      'libavutil',
      'libavcodec',
      'libavformat',
      'libavdevice',
      'libavfilter',
      'libswscale',
      'libswresample',
      'Input #',
      'Output #',
      'Stream #',
      'Press [q]',
      'frame=',
      'size=',
      'time=',
      'bitrate=',
      'speed=',
      'video:',
      'audio:',
      'subtitle:',
    ];
    final keep = <String>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final isNoise = noisePrefixes.any((p) => line.startsWith(p));
      if (!isNoise) {
        keep.add(line);
        if (keep.length >= 12) break;
      }
    }
    if (keep.isEmpty) {
      final trimmed = logs.trim();
      if (trimmed.length > 300) {
        return '${trimmed.substring(0, 300)}...';
      }
      return trimmed.isEmpty ? '未知错误' : trimmed;
    }
    return keep.join('\n');
  }
}

/// FFmpeg 相关异常的封装
/// 公开给调用方（VideoConvertPage）用于错误处理
class FFmpegException implements Exception {
  final String message;
  final String? fullLogs;
  final bool isCancelled;

  const FFmpegException(this.message, {this.fullLogs, this.isCancelled = false});

  @override
  String toString() => message;
}
