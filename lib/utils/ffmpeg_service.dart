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

import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import 'app_logger.dart';
import 'convert_speed_settings.dart';
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

  /// v1.6.28+ 新增（bug9 修复配套）：
  ///   用户在 cancel() 调用时如果 FFmpeg 会话**还没起来**
  ///   （_session 还是 null，比如正在做 M3U8 规范化、时长探测），
  ///   旧的 cancel() 会直接 return，导致 cancel 无效。
  ///   现在用这个标志位记录"用户已请求取消"，等 convert()/convertResume()
  ///   在关键检查点（归一化后、探测后、启动会话前）看到这个标志就立刻
  ///   抛 FFmpegException(isCancelled=true)，让 Coordinator 的 catch 块
  ///   走取消分支。
  bool _cancelRequested = false;

  /// v1.6.29+ 新增（bug13 修复配套）：
  ///   标记"已经有 cancel 请求正在异步进行中"。
  ///   cancel() 现在不 await s.cancel()（避免大文件时阻塞 UI 线程），
  ///   但这意味着用户在 cancel 异步等待期间可能多次点取消按钮，
  ///   没有这个标志就会重复触发 s.cancel()（虽然不会出错但是日志会很乱）。
  ///   用 _cancelInFlight 拦截重复触发，等原生 cancel 完成时回调清掉。
  bool _cancelInFlight = false;

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

  // v1.6.37+ 新增（BUG8 修复配套）：
  //   记住当前转换任务的源视频总时长（ms）。
  //   暂停时 Coordinator 需要把 totalDurationMs 写入 ConvertResumeState，
  //   但 _sourceDurationMs 只在 convert() 成功返回后才赋值，
  //   暂停时还是 null，导致 resume state 的 totalDurationMs = 0，
  //   续转进度条永远不动。
  //   新增此字段，在 convert()/convertResume() 探测到时长后立刻赋值，
  //   Coordinator 暂停时通过 lastDurationMs 取值。
  int? _lastDurationMs;
  int? get lastDurationMs => _lastDurationMs;

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
    _lastDurationMs = null; // v1.6.37+ BUG8 修复：每次新任务重置
    // v1.6.28+ 修复（bug9）：新任务入口处重置 _cancelRequested
    // v1.6.35+ 修复（bug20）：还要重置 _cancelInFlight！避免上次取消后这个标志残留为 true，下次 cancel() 直接 return
    _cancelRequested = false;
    _cancelInFlight = false;

    // 关键调试：确认 input 路径与文件存在性
    AppLogger.i(_logTag, 'convert() 被调用，input=$input');
    if (input.startsWith('/') || input.contains(':\\')) {
      final f = File(input);
      AppLogger.i(_logTag, 'input 文件存在：${await f.exists()}，大小：${await f.length().catchError((_) => 0)} bytes');
    }

    // v1.6.31+ 修复（bug17 配套，针对 start() 场景）：
    //   取消转换后 _importedTempDir 已被 Coordinator 删（_sourceValue 也
    //   指向 tempDir 里的 .m3u8，但 v1.6.31+ 改成"取消时保留输入源卡片"，
    //   _sourceValue 不会自动清）。如果用户点"开始转换"，input 就是一个
    //   已删的路径 → M3U8Normalizer 静默 return null → FFmpeg 报
    //   "No such file or directory"，体验差。
    //   跟 convertResume() 同样策略：本地文件先校验存在性。
    //   URL 不校验（让 FFmpeg 自己报网络错误）。
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      if (!input.startsWith('/') && !input.contains(':\\')) {
        // 既不是 URL 也不是绝对路径（极少见但要兜底），
        // 可能是相对路径，FFmpeg 也会报"No such file"，这里直接 fail fast
        throw FFmpegException(
          '输入源路径无效：$input（不是本地绝对路径或 http(s) URL）',
          isResumeSourceMissing: true,
        );
      }
      final inputFile = File(input);
      if (!await inputFile.exists()) {
        AppLogger.w(_logTag, 'convert()-源文件预校验失败，input=$input');
        throw FFmpegException(
          '输入源文件已不存在：$input\n'
          '（取消转换时临时目录会被清理，请重新选择输入源）',
          isResumeSourceMissing: true,
        );
      }
    }

    // 重要：本地 M3U8 文件可能引用非标准扩展名的 segment（如 "0"、"1"），
    // FFmpeg 协议层会拒绝。预先规范化，转换为 .ts。
    M3U8NormalizeResult? normalizeResult;
    String effectiveInput = input;
    try {
      normalizeResult = await M3U8Normalizer.normalize(input);
      // v1.6.28+ 修复（bug9）：规范化完立刻检查取消标志
      if (_cancelRequested) {
        AppLogger.w(_logTag, 'convert() 规范化后检测到 _cancelRequested，直接抛异常');
        throw const FFmpegException('用户已取消转换', isCancelled: true);
      }
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
      // v1.6.37+ BUG8 修复：探测到时长后立刻赋值 _lastDurationMs，
      //   供 Coordinator 暂停时通过 lastDurationMs 取值。
      //   旧版只在 convert() 成功返回后通过 ConvertResult.sourceDurationMs
      //   赋值 _sourceDurationMs，暂停时该字段还是 null，
      //   导致 ConvertResumeState.totalDurationMs = 0，续转进度无法计算。
      _lastDurationMs = durationMs;
      // v1.6.28+ 修复（bug9）：时长探测完再检查一次取消标志
      if (_cancelRequested) {
        AppLogger.w(_logTag, 'convert() 探测时长后检测到 _cancelRequested，直接抛异常');
        throw const FFmpegException('用户已取消转换', isCancelled: true);
      }
      AppLogger.i(_logTag, '输入源时长：${durationMs ?? '未知'} ms');

      // v1.6.51+ 修复：确保输出目录存在，FFmpeg 不会自动创建父目录
      final outputDir = Directory(p.dirname(outputPath));
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
        AppLogger.i(_logTag, '已创建输出目录：${outputDir.path}');
      }

      // 构造 FFmpeg 参数（读取加速模式）
      final speedMode = await ConvertSpeedSettings.load();
      final args = _buildArgs(
        input: effectiveInput,
        outputPath: outputPath,
        format: format,
        quality: quality,
        speedMode: speedMode,
      );
      final command = args.join(' ');
      AppLogger.i(_logTag, '执行 FFmpeg 命令：$command');

      // 记录转换开始时刻（用于 ETA 预估）
      final startWallClockMs = DateTime.now().millisecondsSinceEpoch;
      // v1.6.39+ 修复（BUG-G 配套）：
      //   去掉全局 statistics 回调注册，只保留会话级回调。
      //   原因同 _executeSimple 中的注释。

      // v1.6.28+ 修复（bug9）：启动会话前再检查一次取消标志
      //   经过规范化 / 探测两次检查，理论已经够，但 executeWithArgumentsAsync
      //   本身可能也有 setup 耗时（注册 session 等），兜底再查一次。
      if (_cancelRequested) {
        AppLogger.w(_logTag, 'convert() 启动 FFmpeg 会话前检测到 _cancelRequested，直接抛异常');
        throw const FFmpegException('用户已取消转换', isCancelled: true);
      }

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
      // v1.6.37+ 修复（BUG4）：清理 M3U8Normalizer 创建的临时目录。
      //   旧版 normalizeResult.tempDir 从未被清理，每次转换都会在
      //   系统临时目录留下 m3u8_norm_* 文件夹，导致磁盘空间泄漏。
      //   注意：暂停场景下 tempDir 里的 merged.ts 理论上可被续转复用，
      //   但当前 convertResume() 的 importedTempDir 参数指向的是
      //   Page 端的 _importedTempDir（SAF 导入目录），不是 normalizeResult.tempDir，
      //   所以续转时找不到这里的 merged.ts，每次都会重新规范化。
      //   因此 normalizeResult.tempDir 在暂停后也无用，可以安全清理。
      if (normalizeResult != null) {
        try {
          await M3U8Normalizer.cleanup(normalizeResult);
        } catch (e) {
          AppLogger.w(_logTag, '清理 normalizeResult 临时目录失败：$e');
        }
      }
    }
  }

  /// 强制重置所有内部状态（用于 Coordinator 检测到状态不一致时）
  ///
  /// v1.6.35+ 新增（bug20 修复配套）：
  ///   场景：用户取消后 FFmpegService 的 _isRunning/_cancelInFlight/_cancelRequested
  ///   没有正确重置，导致下次转换时直接抛 "已有转换任务在进行中" 错误。
  ///   给外部一个"紧急逃生口"，可以强制重置所有标志位。
  void forceReset() {
    AppLogger.w(_logTag, 'forceReset() 被调用，强制重置所有 FFmpegService 内部状态');
    _isRunning = false;
    _cancelRequested = false;
    _cancelInFlight = false;
    _session = null;
    _lastDurationMs = null; // v1.6.37+ BUG8 修复配套
  }

  /// 取消当前正在执行的转换
  ///
  /// v1.6.28+ 修复（bug9）：
  ///   旧版 cancel() 只能取消"已经起来的 FFmpeg 会话"，如果用户点取消时
  ///   convert()/convertResume() 还在做 M3U8 规范化 / 时长探测（_session 还是 null），
  ///   就会直接 return，用户的取消请求被吞掉，转换继续进行。
  ///   现在分两种情况：
  ///     - _session 非空：调 s.cancel() 终止 FFmpeg（原有逻辑）
  ///     - _session 为空但 _isRunning 为 true：置 _cancelRequested = true，
  ///       convert()/convertResume() 在关键检查点会看到这个标志，抛
  ///       FFmpegException(isCancelled=true)，让 Coordinator 走取消分支
  ///     - _session 为空且 _isRunning 为 false：没有在跑的任务，直接 return
  ///
  /// v1.6.29+ 修复（bug13，针对大体积文件取消卡顿）：
  ///   旧版 `await s.cancel()` 会一直等待 FFmpeg 原生层真正把会话杀掉。
  ///   FFmpeg 在收到取消信号后还要：处理完当前帧 → 编码器 flush → 写完 moov atom
  ///   → 关闭文件 → 进程退出。对大体积文件（H.264 关键帧间隔较长时）这一连串
  ///   收尾动作可能要 5~30 秒，UI 线程被 await 卡住，用户感觉"点取消没反应"。
  ///   新版改为**异步触发** `s.cancel()`（不 await），FFmpegService.cancel() 本身
  ///   立刻返回：
  ///     - Coordinator 调完本方法后能立即更新状态为 cancelling/pausing
  ///     - 页面可以马上给用户视觉反馈（按钮变"取消中..." + 进度环暂停动画）
  ///     - FFmpeg 原生层仍在后台执行 cancel 流程，session 回调最终会触发，
  ///       convert()/convertResume() 的 await 抛 FFmpegException(isCancelled=true)，
  ///       Coordinator 的 catch 块走完正常取消/暂停收尾
  ///   同时新增 `_cancelInFlight` 标志位，防止用户在 cancel 异步等待期间
  ///   多次点取消按钮导致多次重复触发 s.cancel()。
  Future<void> cancel() async {
    final s = _session;
    if (s != null) {
      // 大体积文件取消慢的根因：之前 await s.cancel() 会阻塞当前 Future
      // 直到 FFmpeg 原生层完整收尾（处理完当前帧 + flush + 写 moov + 退出）。
      // 现在 fire-and-forget：不等待原生 cancel 完成，让它在后台异步进行，
      // 本方法立即返回，UI 层可以快速给用户反馈。
      if (_cancelInFlight) {
        AppLogger.d(_logTag, '已有取消请求在异步进行中，跳过重复触发');
        return;
      }
      _cancelInFlight = true;
      AppLogger.i(_logTag, '用户请求取消 FFmpeg 会话（异步触发，不等待原生收尾）');
      // 不 await：让原生 cancel 在后台异步执行，会话彻底结束后
      //   FFmpegKit 的 completeCallback 会触发 completer.completeError(...)
      //   convert()/convertResume() 的 await 抛 FFmpegException(isCancelled=true)。
      // 之所以可以放心不 await，是因为：
      //   1) _session 字段是同步赋值的引用，原生 cancel 内部会读这个引用
      //   2) 后续 _session = null 的清理只发生在 convert() 的 finally 块里，
      //      那时原生 cancel 已经派发完成，引用断开不会有竞态
      // 忽略返回值（原生 cancel 调用是 void）
      unawaited(s.cancel().whenComplete(() {
        _cancelInFlight = false;
      }));
      return;
    }
    // 没起来的会话
    if (!_isRunning) {
      AppLogger.i(_logTag, '无运行中的会话，跳过取消');
      return;
    }
    // _session 还没起来（多半在 M3U8 规范化 / 时长探测阶段）
    AppLogger.w(_logTag,
        '会话未启动但 _isRunning=true，置 _cancelRequested 标志；'
        'convert()/convertResume() 会在下一个检查点抛 FFmpegException');
    _cancelRequested = true;
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
  /// 关于 importedTempDir（v1.6.28+ 新增，bug10 修复配套）：
  ///   如果传了 tempDir（来自上次 convert() 规范化时创建的目录），
  ///   FFmpegService 会检查 tempDir/merged.ts 是否还在：
  ///     - 在 → 直接用，跳过 M3U8 规范化，续转瞬间启动
  ///     - 不在 → 降级调 M3U8Normalizer 重新规范化（仍然能用，就是慢）
  ///   没传就老老实实走规范化流程。
  ///
  /// 返回 ConvertResult：与 convert() 行为一致
  Future<ConvertResult> convertResume({
    required String input,
    required String partialOutputPath,
    required String finalOutputPath,
    required int resumeFromMs,
    required int totalDurationMs,
    Directory? importedTempDir,
    required VideoFormat format,
    required VideoQuality quality,
    required void Function(ConvertProgress progress) onProgress,
    void Function(String log)? onLog,
    // v1.6.30+ 新增（bug16 配套）：
    //   续转启动时回调，FFmpeg 会话**已创建**但**还没出第一帧**时触发。
    //   旧版没有这个回调，UI 在 "FFmpeg 会话启动" 和 "第一帧出来" 之间
    //   没有任何反馈，用户会以为 App 卡死。
    //   回调时机：_executeSimple() 内部 FFmpegKit.executeWithArgumentsAsync
    //   返回 session 对象后**立刻**调用，此时 session 已注册到全局，
    //   FFmpeg 主线程已经开始跑（开文件 / 解封装 / seek）。
    //   Coordinator 收到这个回调后，emit 一个 "session-starting" 事件，
    //   UI 把按钮文字从 "正在恢复转换..." 换成 "FFmpeg 启动中..."，
    //   给用户明确"系统在干活"的反馈。
    //   类型设计：传 null 等同于旧版行为（不通知）。
    void Function()? onSessionStarting,
  }) async {
    if (_isRunning) {
      throw StateError('已有转换任务在进行中，请先取消');
    }
    _isRunning = true;
    _lastEncodedTimeMs = 0;
    _lastDurationMs = null; // v1.6.37+ BUG8 修复：每次新任务重置
    // v1.6.28+ 修复（bug9）：新任务入口处重置 _cancelRequested
    // v1.6.35+ 修复（bug20）：还要重置 _cancelInFlight！避免上次取消后这个标志残留为 true，下次 cancel() 直接 return
    _cancelRequested = false;
    _cancelInFlight = false;

    AppLogger.i(
      _logTag,
      'convertResume() 被调用：input=$input，'
      'resumeFromMs=$resumeFromMs，partial=$partialOutputPath，'
      'importedTempDir=${importedTempDir?.path ?? '未传'}',
    );

    // v1.6.37+ BUG8 修复：续转时记录 totalDurationMs
    _lastDurationMs = totalDurationMs > 0 ? totalDurationMs : null;

    final part2Path = '$partialOutputPath.part2';

    // v1.6.31+ 修复（bug17，针对续转"No such file or directory"问题）：
    //   场景：用户暂停后，importedTempDir 里的 .m3u8 / segments 被删了
    //   （用户换了 M3U8 文件夹 → _evictCachesForOtherTrees 删旧 cache；
    //    或系统清 cache / App 卸载重装 / 手动清数据等）。
    //   此时 resume 流程：
    //     1) 复用 tempDir 检查：merged.ts / normalized.m3u8 都不在 → 降级
    //     2) M3U8Normalizer.normalize(input)：input 指向已删的 .m3u8
    //        → srcFile.exists() 返回 false → 静默 return null
    //     3) FFmpeg 用原始 input 路径跑 → 报 "xxx: No such file or directory"
    //   这个错误很难看懂（用户只看到一长串路径），并且 resume state 一直
    //   留着，下次点"继续转换"还是同样的错。
    //   修复：在跑任何 FFmpeg / normalizer 之前先校验 input 是不是本地文件
    //   且还存在。不存在就直接抛 FFmpegException(isResumeSourceMissing=true)，
    //   Coordinator catch 块会清掉 resume state + 弹明确提示。
    //   URL（http/https）不校验：网络源可能在断网时暂时不可达，
    //   让 FFmpeg 自己报网络错误更准确。
    //   校验策略：
    //     - 路径以 http/https 开头 → 跳过（网络源）
    //     - File(input).exists() == true → 通过
    //     - 校验 importedTempDir 是否存在（如果传了）
    //       重要：如果 importedTempDir 存在但里面 .m3u8 没了，说明
    //       用户在 _pickM3u8Folder 中清了原 .m3u8 但留了 dir ——
    //       这种情况理论上 normalize() 会静默 return null 然后 FFmpeg 报
    //       "No such file"，所以也要 fail fast。
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      final inputFile = File(input);
      final inputExists = await inputFile.exists();
      // importedTempDir 也校验一下：用户可能换了 M3U8 文件夹，旧的
      // importedTempDir 还在但里面 .m3u8 被 _evictCachesForOtherTrees 清了
      // 进一步：tempDir 整个被删的情况（系统清 cache）也走这里 catch
      bool tempDirOk = true;
      if (importedTempDir != null) {
        tempDirOk = await importedTempDir.exists();
      }
      if (!inputExists || !tempDirOk) {
        final reason = !inputExists
            ? 'M3U8/源文件已不存在：$input'
            : 'M3U8 临时目录已不存在：${importedTempDir!.path}';
        AppLogger.w(_logTag, '续转-源文件预校验失败：$reason，'
            'inputExists=$inputExists, tempDirOk=$tempDirOk');
        throw FFmpegException(
          '恢复失败：源文件已被删除或清理，请重新选择 M3U8 文件夹后开始新转换。\n'
          '（$reason）',
          isResumeSourceMissing: true,
        );
      }
    }

    // v1.6.28+ 修复（bug10）：
    //   续转时优先复用上次规范化好的 merged.ts，跳过 M3U8Normalizer
    //   整个"读 M3U8 + 复制 segments + 拼 merged.ts"流程（对 1000+ 段
    //   的 M3U8 要花好几秒甚至几十秒）。如果 tempDir 还在就直接用。
    String effectiveInput = input;
    bool reusedFromCache = false;
    if (importedTempDir != null) {
      final mergedTs = File('${importedTempDir.path}/merged.ts');
      final normalizedM3u8 =
          File('${importedTempDir.path}/normalized.m3u8');
      try {
        if (await mergedTs.exists() && (await mergedTs.length()) > 0) {
          effectiveInput = mergedTs.path;
          reusedFromCache = true;
          AppLogger.i(_logTag,
              '续转-复用上次的 merged.ts：$effectiveInput，'
              '跳过 M3U8 规范化（瞬间启动）');
        } else if (await normalizedM3u8.exists() &&
            (await normalizedM3u8.length()) > 0) {
          effectiveInput = normalizedM3u8.path;
          reusedFromCache = true;
          AppLogger.i(_logTag,
              '续转-复用上次的 normalized.m3u8：$effectiveInput，'
              '跳过 M3U8 规范化');
        } else {
          AppLogger.w(_logTag,
              '续转-tempDir 存在但 merged.ts / normalized.m3u8 都不在或为空，'
              '降级走规范化：${importedTempDir.path}');
        }
      } catch (e) {
        AppLogger.w(_logTag, '续转-检查复用 tempDir 失败，降级走规范化：$e');
      }
    }

    // v1.6.28+ 修复（bug9）：复用缓存后立刻检查取消标志
    if (reusedFromCache && _cancelRequested) {
      AppLogger.w(_logTag, 'convertResume() 复用缓存后检测到 _cancelRequested，直接抛异常');
      throw const FFmpegException('用户已取消转换', isCancelled: true);
    }

    // v1.6.25+ 修复（bug6）：
    //   convert() 在跑 FFmpeg 前会调 M3U8Normalizer.normalize() 把本地 M3U8
    //   规范化（segments 改名为 .ts、合并成 merged.ts 等），这样能绕开
    //   FFmpeg HLS demuxer 的 allowed_segment_extensions 白名单限制
    //   （{"aac","mp3","ts","vtt"} 之外的扩展名会被协议层直接拒绝）。
    //   convertResume() 之前没有这一步，resume state 里的 input 是原始
    //   M3U8 路径，FFmpeg 一跑就报 "URL xxx_contents/0 is not in allowed_segment_extensions"，
    //   然后 "Invalid data found when processing input"。
    //   现在补上规范化，跟 convert() 行为对齐。
    M3U8NormalizeResult? normalizeResult;
    if (!reusedFromCache) {
      try {
        normalizeResult = await M3U8Normalizer.normalize(input);
        // v1.6.28+ 修复（bug9）：规范化完检查取消标志
        if (_cancelRequested) {
          AppLogger.w(_logTag, 'convertResume() 规范化后检测到 _cancelRequested，直接抛异常');
          throw const FFmpegException('用户已取消转换', isCancelled: true);
        }
        if (normalizeResult != null) {
          if (normalizeResult.mergedTsPath != null) {
            effectiveInput = normalizeResult.mergedTsPath!;
          } else {
            effectiveInput = normalizeResult.normalizedM3u8Path;
          }
          AppLogger.i(
            _logTag,
            '恢复-本地 M3U8 已规范化：${normalizeResult.tempDir.path}，'
            '使用输入：$effectiveInput'
            '${normalizeResult.mergedTsPath != null ? "（合并TS）" : "（走HLS）"}',
          );
        }
      } catch (e, st) {
        // 规范化失败时降级：直接用原始 input，让 FFmpeg 自己去处理
        // （非本地 M3U8 的话 M3U8Normalizer 内部会直接返回 null，不会抛错；
        //   这里 catch 主要是为了兜底：万一 normalize 过程本身出 IO 异常）
        //   但是！bug9 修复时这里的 catch 会**吞掉** FFmpegException 取消信号，
        //   因为 isCancelled=true 的异常在 Dart 里也走通用 catch 分支。
        //   必须重新抛出"取消"类型的异常，否则用户的取消请求被吞掉。
        if (e is FFmpegException && e.isCancelled) {
          rethrow;
        }
        AppLogger.w(_logTag, '恢复-M3U8 规范化失败，降级用原始输入：$e', st);
        effectiveInput = input;
      }
    }

    // v1.6.28+ 修复（bug9）：启动编码 step1 前再检查一次取消标志
    if (_cancelRequested) {
      AppLogger.w(_logTag, 'convertResume() 启动编码 step1 前检测到 _cancelRequested，直接抛异常');
      throw const FFmpegException('用户已取消转换', isCancelled: true);
    }

    try {
      // ============ 第一步：编码剩余段 ============
      // 关键：在 base 数组里插入 -ss <ms>，放在 -i 之前
      // 这样 FFmpeg 在 demux 阶段就 seek，编码器从 seek 点开始推帧
      final seekSeconds = resumeFromMs / 1000.0;
      // v1.6.25+ 修复（bug6）：用规范化后的 effectiveInput 作为 FFmpeg 输入，
      //   而不是 resume state 里的原始 input
      // v1.6.43+ 新增：读取加速模式
      final speedMode = await ConvertSpeedSettings.load();
      final encodeArgs = _buildArgs(
        input: effectiveInput,
        outputPath: part2Path,
        format: format,
        quality: quality,
        seekSeconds: seekSeconds,
        speedMode: speedMode,
      );
      AppLogger.i(_logTag, '恢复-编码剩余段：${encodeArgs.join(' ')}');

      await _executeSimple(
        args: encodeArgs,
        sourceName: 'resume-encode',
        // v1.6.27+ 修复（bug8）：
        //   必须传真实 totalDurationMs，不能传占位 1（否则 _onStatistics 里
        //   `p = (timeMs / 1).clamp(0, 1) = 1.0`，
        //   外面 `p.value * 0.7 = 0.7` → 进度直接跳到 70%）。
        //   传 totalDurationMs 后，p.value 从 encodedMs/totalDurationMs（≈
        //   暂停时的比例）平滑走到 1.0，乘 0.7 后正好从暂停位置走到 70%。
        totalDurationMs: totalDurationMs,
        // v1.6.30+ 修复（bug16）：
        //   把 onSessionStarting 透传给 _executeSimple()，让 FFmpeg 会话
        //   启动的瞬间能回调到 Coordinator 推 UI 事件。
        //   第一步（编码剩余段）才是用户感受到"卡在准备中"的那一段。
        onSessionStarting: onSessionStarting,
        onProgress: (p) {
          // v1.6.40+ 修复（进度虚增 + 时长回退）：
          //   旧版 v1.6.39 在这里加了 absoluteProgress = resumeProgressBase + p.value，
          //   导致 Coordinator 的缩放逻辑 base + p.value*(1-base) 中 base 被加了两次，
          //   进度虚增（暂停2%→续转3%）。
          //
          //   正确做法：这里保持 p.value 为相对进度（从 0 开始），
          //   由 Coordinator 的缩放逻辑 base + p.value*(1-base) 负责映射到绝对进度。
          //   这样续转开始时 p.value≈0 → Coordinator: base+0=base（与暂停时一致）。
          //
          //   同时修复时长回退：FFmpeg -ss seeking 后 timeMs 从 0 开始（相对时间），
          //   需要加上 resumeFromMs 转为绝对时间，否则 UI 显示"已转换1分钟"回退。
          // 编码步骤占 70%（剩下 30% 留给 repair + concat）
          // 传给 Coordinator 的 p.value 必须是相对进度（不含 base），
          // 否则 Coordinator 的 base + p.value*(1-base) 会双重计算 base
          onProgress(ConvertProgress(
            value: p.value * 0.7,
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            // 修复时长回退：将相对时间转为绝对时间
            time: _addTimeOffset(p.time, resumeFromMs),
            etaSeconds: p.etaSeconds,
          ));
        },
        onLog: onLog,
      );

      // ============ 第二步：拼接两段 ============
      AppLogger.i(_logTag, '恢复-拼接两段：$partialOutputPath + $part2Path');

      // v1.6.38+ 重写续转拼接逻辑（修复 BUG-A + BUG-E）：
      //
      //   核心问题：暂停时 FFmpeg 被取消，partial 输出文件**没有 moov atom**
      //   （MP4 的索引结构在文件末尾，取消时还没写），导致：
      //     - concat demuxer（-f concat）要求每个输入文件都有完整容器头，
      //       partial 没有 moov → 报错 "moov atom not found"
      //     - concat filter（-filter_complex）虽然能容忍不完整输入，
      //       但需要重新编码（-c copy 被忽略），速度慢 10 倍+且画质下降
      //     - part2 文件扩展名是 .part2，concat demuxer 无法推断格式
      //
      //   最成熟方案（三步）：
      //     1) 修复 partial：用 FFmpeg 重新封装 partial（-c copy + -f mp4），
      //        FFmpeg 会自动补上 moov atom，输出为完整可播放的 MP4
      //     2) 用 concat demuxer（-f concat -safe 0）拼接修复后的 partial + part2
      //     3) -c copy 直接拷贝流，不重新编码，速度极快
      //
      //   为什么不用 concat filter：
      //     - concat filter 需要 FFmpeg 解码再编码（-c copy 被忽略）
      //     - 速度慢 10 倍以上，且输出质量下降
      //     - 还需要探测有无音频流来动态构造 filter，容易出错
      //
      //   为什么不用 concat protocol（concat:part1|part2）：
      //     - 只支持 MPEG-TS 格式，不支持 MP4/MKV/MOV
      //
      //   前提条件：两段的编码参数一致（续转时使用相同编码参数，满足此条件）

      // ---- 2a: 修复 partial（补 moov atom）----
      final repairedPartialPath = '$partialOutputPath.repaired';
      AppLogger.i(_logTag, '恢复-修复 partial：$partialOutputPath -> $repairedPartialPath');
      final repairArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel', 'info',
        '-i', partialOutputPath,
        '-c', 'copy',
        '-f', _ffmpegFormatName(format),
        if (format == VideoFormat.mp4) ...['-movflags', '+faststart'],
        repairedPartialPath,
      ];
      AppLogger.i(_logTag, '恢复-修复 partial 命令：${repairArgs.join(' ')}');

      await _executeSimple(
        args: repairArgs,
        sourceName: 'resume-repair',
        totalDurationMs: totalDurationMs,
        onProgress: (p) {
          // 修复步骤从 0.7 推到 0.75
          onProgress(ConvertProgress(
            value: 0.7 + p.value * 0.05,
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            time: p.time,
            etaSeconds: p.etaSeconds,
          ));
        },
        onLog: onLog,
      );

      // ---- 2b: 用 concat demuxer 拼接修复后的 partial + part2 ----
      // 写 concat list 文件
      final concatListPath = '$finalOutputPath.concat_list';
      try {
        final concatList = File(concatListPath);
        // concat demuxer 格式：每行 file 'path'
        // 路径中的单引号需要转义
        final escapedPart1 = repairedPartialPath.replaceAll("'", "'\\''");
        final escapedPart2 = part2Path.replaceAll("'", "'\\''");
        await concatList.writeAsString("file '$escapedPart1'\nfile '$escapedPart2'\n");
      } catch (e) {
        AppLogger.e(_logTag, '写 concat list 文件失败：$e');
        rethrow;
      }

      final concatArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel', 'info',
        // concat demuxer：读取 list 文件，按顺序拼接
        '-f', 'concat',
        '-safe', '0',
        '-i', concatListPath,
        // -c copy 直接拷贝流，不重新编码，速度快 10 倍以上
        '-c', 'copy',
        // 强制 faststart，让输出能立即被播放器读取
        if (format == VideoFormat.mp4) ...['-movflags', '+faststart'],
        // 显式指定输出容器格式
        '-f', _ffmpegFormatName(format),
        finalOutputPath,
      ];
      AppLogger.i(_logTag, '恢复-拼接命令：${concatArgs.join(' ')}');

      // 拼接进度：先推一个 75%~80% 的"过渡值"
      onProgress(ConvertProgress(
        value: 0.80,
        hasDuration: true,
        bitrate: '',
        time: '',
        etaSeconds: 0,
      ));
      await _executeSimple(
        args: concatArgs,
        sourceName: 'resume-concat',
        totalDurationMs: totalDurationMs,
        onProgress: (p) {
          // 拼接步骤从 0.75 推到 0.99
          onProgress(ConvertProgress(
            value: 0.75 + p.value * 0.24,
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            time: p.time,
            etaSeconds: p.etaSeconds,
          ));
        },
        onLog: onLog,
      );

      // 清理临时文件：part2、repaired partial、concat list
      for (final tempPath in [part2Path, repairedPartialPath, concatListPath]) {
        try {
          final f = File(tempPath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          AppLogger.w(_logTag, '清理临时文件失败 ($tempPath)：$e');
        }
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
      // v1.6.37+ 修复（BUG4）：清理 convertResume 中 M3U8Normalizer 创建的临时目录
      if (normalizeResult != null) {
        try {
          await M3U8Normalizer.cleanup(normalizeResult);
        } catch (e) {
          AppLogger.w(_logTag, '清理 normalizeResult 临时目录失败：$e');
        }
      }
    }
  }

  /// 简化的"执行一次 FFmpeg 命令"工具，给 convertResume 复用
  ///
  /// 与 convert() 的区别：
  ///   - 不做 M3U8 归一化（调用方自己保证 input 合法）
  ///   - 不做时长探测（resume 场景下不需要）
  ///   - 失败抛 FFmpegException，成功正常返回
  ///
  /// totalDurationMs：传给 _onStatistics 的"总时长"，用于把 timeMs 归一化到
  ///   0~1 范围。必须传真实值，**不能传 1 这种占位**：
  ///     - _onStatistics 里 `p = (timeMs / totalDurationMs).clamp(0, 1)`，
  ///       totalDurationMs=1 会让 p 直接被 clamp 截到 1.0，
  ///       然后外部 `p.value * 0.7 = 0.7 = 70%`，导致 resume 进度直接跳到 70%
  ///     - 传真实总时长后，p 会从 encodedMs/totalDurationMs（≈暂停时的比例）
  ///       平滑走到 1.0，进度条才会连续
  Future<void> _executeSimple({
    required List<String> args,
    required String sourceName,
    required int totalDurationMs,
    required void Function(ConvertProgress) onProgress,
    void Function(String log)? onLog,
    // v1.6.30+ 新增（bug16 配套）：
    //   FFmpeg 会话**已创建**但**还没出第一帧**时的回调。
    //   见 convertResume() 的同名参数注释。
    void Function()? onSessionStarting,
  }) async {
    final startWallClockMs = DateTime.now().millisecondsSinceEpoch;
    // v1.6.39+ 修复（BUG-G 配套）：
    //   去掉全局 statistics 回调注册，只保留会话级回调。
    //   旧版同时注册了全局回调（enableStatisticsCallback）和会话级回调
    //   （executeWithArgumentsAsync 的第三个参数），导致每个 statistics
    //   事件被处理两次，onProgress 被调用两次。虽然两次调用产生相同
    //   的 p.value，但双重调用可能导致进度抖动和性能浪费。
    //   会话级回调已经足够接收当前会话的 statistics，不需要全局回调。

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
          totalDurationMs,
          startWallClockMs,
          onProgress,
        );
      },
    );

    // v1.6.30+ 修复（bug16，针对大体积文件续转卡在"准备中"问题）：
    //   FFmpegKit.executeWithArgumentsAsync 返回后，session 已经被注册到
    //   FFmpegKit 全局，FFmpeg 主线程已经开始跑（开文件 / 解封装 / seek）。
    //   立刻调用 onSessionStarting 回调，让 Coordinator 推一个
    //   "session-starting" 事件给 UI，UI 可以：
    //     - 把按钮文字从 "正在恢复转换..." 换成 "FFmpeg 启动中..."
    //     - 切换到"启动阶段"专属的小提示（"正在打开输入文件..."等）
    //   不调用：用户只能等到第一帧 statistics 出来（5~10s）才看到任何动静，
    //   中间这段时间就感觉 App 卡死。
    //   用 try/catch 保护：即便回调本身抛错也不能让 FFmpeg 跟着炸。
    // v1.6.36+ 修复（bug22）：
    //   续转时不再传 onSessionStarting（避免卡在"FFmpeg 启动中"），
    //   此回调仅用于首次启动转换的场景。
    if (onSessionStarting != null) {
      try {
        onSessionStarting();
      } catch (e, st) {
        AppLogger.w(_logTag, 'onSessionStarting 回调执行失败：$e', st);
      }
    }

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
    ConvertSpeedMode speedMode = ConvertSpeedMode.off,
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

      // v1.6.43+ 新增：根据加速模式选择编码方式
      if (speedMode == ConvertSpeedMode.hardware) {
        // 硬件编码模式：使用 Android MediaCodec 硬件加速
        encodeArgs.addAll([
          '-c:v', 'h264_mediacodec',
          '-pix_fmt', 'yuv420p',
          '-c:a', 'aac',
          '-b:a', '${audioBitrateK}k',
          if (format == VideoFormat.mp4) ...[
            '-movflags', '+faststart',
          ],
        ]);
      } else {
        // 软件编码模式：根据 speedMode 选择 preset
        final effectivePreset = speedMode == ConvertSpeedMode.ultrafast
            ? 'ultrafast'
            : preset;
        encodeArgs.addAll([
          '-c:v', 'libx264',
          '-preset', effectivePreset,
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
    }

    return [
      ...base,
      ...encodeArgs,
      // v1.6.26+ 修复（bug7）：显式指定输出容器格式
      //   默认情况下 FFmpeg 通过输出文件扩展名推断格式（".mp4" → mp4 muxer）
      //   但恢复转换的 part2 文件名是 "xxx.mp4.part2"，
      //   FFmpeg 看到的扩展名是 ".part2"，无法推断，
      //   报 "Unable to choose an output format" + "Invalid argument"。
      //   显式加 -f 后 FFmpeg 就用我们指定的 muxer，不再依赖扩展名推断。
      //   兼容正常流程（输出是 .mp4/.mkv），不会影响原行为。
      '-f', _ffmpegFormatName(format),
      outputPath,
    ];
  }

  // ------------------------------------------------------------------
  // 内部：进度回调
  // ------------------------------------------------------------------

  /// 把 VideoFormat 映射到 FFmpeg -f 参数使用的 muxer 名称
  ///
  /// v1.6.26+ 新增（bug7 修复配套）：
  ///   恢复转换的 part2 文件名是 `xxx.mp4.part2`，
  ///   FFmpeg 看扩展名 `.part2` 推断不出容器，必须显式 `-f mp4`。
  ///   正常流程（`xxx.mp4` / `xxx.mkv`）下 FFmpeg 自己能从扩展名推断出来，
  ///   显式加 `-f` 也不冲突，行为一致。
  String _ffmpegFormatName(VideoFormat format) {
    switch (format) {
      case VideoFormat.mp4:
        return 'mp4';
      case VideoFormat.mkv:
        return 'matroska';
      case VideoFormat.mov:
        return 'mov';
    }
  }

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
      // v1.6.38+ 修复（BUG-D）：拿不到总时长时，不再永远返回 value:0.0。
      //   旧版在 totalDurationMs==null 时每次都返回 value:0.0 + hasDuration:false，
      //   导致进度条永远停在 0%，用户以为卡死了。
      //   新版用已处理时间 (timeMs) 做替代进度：
      //     - timeMs > 0 时给一个基于时间的估算进度（最大 0.9，避免到 100% 后又跳回）
      //     - timeMs <= 0 时才返回 0.0
      //   这样用户至少能看到进度在动，不会以为程序卡死。
      final timeMs = statistics.getTime();
      if (timeMs > 0) {
        // 用对数增长估算：30s → 0.3, 60s → 0.45, 120s → 0.6, 300s → 0.75
        // 上限 0.9，避免到达 100% 后发现还没完成
        final estimatedProgress = (0.1 + 0.8 * (1 - 1 / (1 + timeMs / 60000.0))).clamp(0.0, 0.9);
        final bitrate = statistics.getBitrate();
        onProgress(ConvertProgress(
          value: estimatedProgress,
          hasDuration: false,
          bitrate: bitrate > 0 ? '${bitrate.toStringAsFixed(0)}kbits/s' : '',
          time: _formatTimeMs(timeMs),
        ));
      } else {
        onProgress(const ConvertProgress(
          value: 0.0,
          hasDuration: false,
        ));
      }
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

  /// v1.6.40+ 新增：将时间字符串加上偏移毫秒
  ///   用于续转时将相对时间（FFmpeg -ss seeking 后从0开始）转为绝对时间
  ///   输入格式：HH:MM:SS.mmm（由 _formatTimeMs 生成）
  ///   如果解析失败，返回原始字符串
  String _addTimeOffset(String timeStr, int offsetMs) {
    if (timeStr.isEmpty || offsetMs <= 0) return timeStr;
    try {
      final parts = timeStr.split(':');
      if (parts.length != 3) return timeStr;
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      final s = int.parse(secParts[0]);
      final ms = secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) : 0;
      final totalMs = h * 3600000 + m * 60000 + s * 1000 + ms + offsetMs;
      return _formatTimeMs(totalMs);
    } catch (_) {
      return timeStr;
    }
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

  // v1.6.31+ 新增（bug17）：
  //   标记"源文件不存在"类型的失败，主要用于续转场景：
  //   暂停后 tempDir 被清理（用户换了 M3U8 文件夹 / 系统清了 cache /
  //   App 卸载重装），resume state's input 指向已删的文件。
  //   跟普通 FFmpeg 失败的语义不同，UI 要：
  //     - 弹一个明确的"恢复失败：源文件已被删除，请重新选择"提示
  //     - 清掉磁盘上的 resume state（已经是无效状态）
  //     - 引导用户重新选 M3U8 文件夹开始新转换
  //   旧版没这个标志，UI 只能从 message 字符串里 grep "No such file"，
  //   误判率高（FFmpeg 也会用同样字符串报"输出文件已存在"等其他场景）。
  final bool isResumeSourceMissing;

  const FFmpegException(
    this.message, {
    this.fullLogs,
    this.isCancelled = false,
    this.isResumeSourceMissing = false,
  });

  @override
  String toString() => message;
}
