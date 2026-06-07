// 视频转换全局协调器（单例）
//
// 背景（v1.6.19+ 引入）：
//   之前 _VideoConvertPageState 把"转换任务"和"页面 UI 状态"耦合在一起，
//   导致：
//     1) 用户点"后台运行"时，dispose() 仍调用 _ffmpeg.cancel()，FFmpeg 直接被杀
//     2) 临时 M3U8 目录在 dispose 时被清，FFmpeg 正在读的 segments 没了
//     3) ConvertNotification 也在 dispose 时撤了，通知栏全空
//   表现为"选了后台运行，等于直接结束了任务"。
//
// 本类把"转换任务的控制权"与"页面 State 的生命周期"完全解耦：
//   - ConvertCoordinator 是全局单例，App 整个生命周期内只有一份
//   - FFmpegService、通知、历史、临时目录清理都托管在这里
//   - UI 只通过 Stream<ConvertEvent> 订阅进度 / 状态变化
//   - Page State 在 dispose() 时**不**取消 FFmpeg，只解除订阅
//   - 重新进入页面时，订阅会立即收到当前状态（恢复 UI 同步）
//
// 用法：
//   - 启动：
//       unawaited(ConvertCoordinator.instance.start(ConvertTaskConfig(...)));
//   - 取消：
//       await ConvertCoordinator.instance.cancel();
//   - 订阅：
//       final sub = ConvertCoordinator.instance.subscribe(onEvent);
//       ... 使用 ...
//       sub.cancel();
//
// 设计原则：
//   - State 字段全部公开 getter，但不暴露 setter（避免外部乱改状态）
//   - 事件是 sealed class：ConvertProgressEvent / ConvertStateEvent
//   - 转换主流程内的所有"后处理"（保存历史、复制到 SAF、通知切换）
//     都在 Coordinator 内完成，不依赖任何 Page State

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'convert_history.dart';
import 'convert_notification.dart';
import 'convert_resume_state.dart';
import 'ffmpeg_service.dart';
import 'video_save_settings.dart';

/// Coordinator 状态机
enum ConvertState {
  /// 无任务
  idle,

  /// 正在转换
  running,

  /// 用户暂停（可恢复，进度保留）
  paused,

  /// 转换完成（成功）
  done,

  /// 转换失败
  failed,

  /// 用户取消
  cancelled,
}

/// 事件：sealed，订阅者按类型分支处理
sealed class ConvertEvent {
  const ConvertEvent();
}

/// 进度更新事件
class ConvertProgressEvent extends ConvertEvent {
  final ConvertProgress progress;
  const ConvertProgressEvent(this.progress);
}

/// 状态切换事件（带相关输出/错误信息）
class ConvertStateEvent extends ConvertEvent {
  final ConvertState state;
  final String? errorMessage;
  final String? outputPath;
  final int? outputSize;
  final int? sourceDurationMs;
  const ConvertStateEvent({
    required this.state,
    this.errorMessage,
    this.outputPath,
    this.outputSize,
    this.sourceDurationMs,
  });
}

/// 单次转换任务的配置（由 Page 在启动时构建并交给 Coordinator）
class ConvertTaskConfig {
  /// 输入源：本地文件绝对路径 或 http(s):// URL
  final String input;

  /// 输出文件路径（App 私有目录）
  final String outputPath;

  /// 输出容器格式
  final VideoFormat format;

  /// 质量档位
  final VideoQuality quality;

  /// 输入源显示名（用于通知 / 日志）
  final String sourceName;

  /// 是否是网络 URL
  final bool isNetwork;

  /// 视频保存设置（用于决定是否复制到 SAF 自定义目录）
  final VideoSaveSettingsSnapshot saveSettings;

  /// M3U8 导入的临时目录（任务结束后由 Coordinator 自动清理）
  final Directory? importedTempDir;

  /// 历史记录用：转换开始时间（毫秒）
  final int startTimeMs;

  /// 历史记录用：输入源字符串
  final String startInput;

  const ConvertTaskConfig({
    required this.input,
    required this.outputPath,
    required this.format,
    required this.quality,
    required this.sourceName,
    required this.isNetwork,
    required this.saveSettings,
    required this.startTimeMs,
    required this.startInput,
    this.importedTempDir,
  });
}

/// 视频转换全局协调器（单例）
class ConvertCoordinator {
  ConvertCoordinator._();
  static final ConvertCoordinator instance = ConvertCoordinator._();

  static const String _logTag = 'ConvertCoordinator';

  /// FFmpeg 服务实例（Coordinator 独占持有）
  final FFmpegService _ffmpeg = FFmpegService();

  /// 进度/状态事件广播流
  final StreamController<ConvertEvent> _events =
      StreamController<ConvertEvent>.broadcast();

  /// 当前状态
  ConvertState _state = ConvertState.idle;
  ConvertState get state => _state;

  /// 当前进度
  ConvertProgress _progress = const ConvertProgress(
    value: 0,
    hasDuration: false,
  );
  ConvertProgress get progress => _progress;

  /// 当前输出文件路径
  String? _outputPath;
  String? get outputPath => _outputPath;

  /// 当前输出文件大小
  int? _outputSize;
  int? get outputSize => _outputSize;

  /// 源时长（毫秒）
  int? _sourceDurationMs;
  int? get sourceDurationMs => _sourceDurationMs;

  /// 错误信息（failed 状态时）
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// 完整 FFmpeg 日志（failed 状态时）
  String? _lastErrorLogs;
  String? get lastErrorLogs => _lastErrorLogs;

  /// 是否正在运行
  bool get isRunning => _state == ConvertState.running;

  /// 当前任务配置
  ConvertTaskConfig? _config;
  ConvertTaskConfig? get currentConfig => _config;

  // ------------------------------------------------------------------
  // 公开 API
  // ------------------------------------------------------------------

  /// 启动一次转换任务
  ///
  /// - 入参 config 描述本次任务的所有信息
  /// - 任务在 Coordinator 内部异步执行，调用方**不需要 await**
  /// - 多次调用：第二次 start() 在已有任务未结束时直接抛 StateError
  Future<void> start(ConvertTaskConfig config) async {
    if (_state == ConvertState.running) {
      AppLogger.w(_logTag, '已有任务在运行，忽略新的 start() 调用');
      throw StateError('已有转换任务在进行中，请先取消');
    }

    AppLogger.i(_logTag, '收到新任务：input=${config.input}');
    _config = config;
    _resetRuntimeFields();
    _emitState(ConvertState.running);

    // 通知：弹出"开始转换"持续通知
    try {
      final granted = await ConvertNotification.instance.requestPermission();
      if (granted) {
        await ConvertNotification.instance
            .showStart(sourceName: config.sourceName);
      } else {
        AppLogger.w(_logTag, '通知权限未授予，仅在 App 内展示进度');
      }
    } catch (e) {
      AppLogger.w(_logTag, '显示开始通知失败：$e');
    }

    try {
      // ============ 真正跑 FFmpeg ============
      final result = await _ffmpeg.convert(
        input: config.input,
        outputPath: config.outputPath,
        format: config.format,
        quality: config.quality,
        onProgress: (p) async {
          // 进度更新：先更新 Coordinator 内部状态，再广播给订阅者，
          // 最后推送通知栏（保证通知与 UI 一致）
          _progress = p;
          _events.add(ConvertProgressEvent(p));
          try {
            await ConvertNotification.instance.updateProgress(p);
          } catch (e) {
            AppLogger.w(_logTag, '推送进度通知失败：$e');
          }
        },
      );

      // ============ 成功分支：更新结果字段 ============
      _outputPath = result.outputPath;
      _outputSize = result.outputSize;
      _sourceDurationMs = result.sourceDurationMs;

      // ============ 复制到 SAF 自定义目录（如果有） ============
      if (config.saveSettings.mode == VideoSaveMode.customSaf &&
          config.saveSettings.customSafTreeUri != null) {
        try {
          final customUri = config.saveSettings.customSafTreeUri!;
          final fileName = p.basename(result.outputPath);
          const channel = MethodChannel('com.example.toolapp/storage');
          final written = await channel.invokeMethod<String>(
            'writeFileToSafTree',
            {
              'treeUri': customUri,
              'fileName': fileName,
              'srcPath': result.outputPath,
            },
          );
          AppLogger.i(_logTag, '已复制到 SAF 自定义目录：$written');
        } catch (e, st) {
          AppLogger.e(_logTag, '复制到 SAF 自定义目录失败：$e', e, st);
          // 不影响 done 状态；上层订阅者会在 UI 上提示
        }
      }

      // ============ 完成通知 ============
      try {
        await ConvertNotification.instance
            .showCompleted(outputName: p.basename(result.outputPath));
      } catch (e) {
        AppLogger.w(_logTag, '显示完成通知失败：$e');
      }

      // ============ 保存历史 ============
      await _saveHistory(
        status: ConvertStatus.success,
        outputPath: result.outputPath,
        outputSize: result.outputSize,
      );

      _emitState(ConvertState.done);
    } on FFmpegException catch (e, st) {
      AppLogger.e(_logTag, 'FFmpeg 异常', e, st);
      if (e.isCancelled) {
        // ============ 取消分支 ============
        try {
          await ConvertNotification.instance.showCancelled();
        } catch (e) {
          AppLogger.w(_logTag, '显示取消通知失败：$e');
        }
        await _saveHistory(
          status: ConvertStatus.cancelled,
          errorMessage: '用户取消',
        );
        _emitState(ConvertState.cancelled);
      } else {
        // ============ 失败分支 ============
        _errorMessage = e.message;
        _lastErrorLogs = e.fullLogs;
        try {
          await ConvertNotification.instance
              .showFailed(reason: e.message);
        } catch (e) {
          AppLogger.w(_logTag, '显示失败通知失败：$e');
        }
        await _saveHistory(
          status: ConvertStatus.failed,
          errorMessage: e.message,
        );
        _emitState(ConvertState.failed);
      }
    } catch (e, st) {
      AppLogger.e(_logTag, '转换异常', e, st);
      _errorMessage = '启动/执行失败：$e';
      try {
        await ConvertNotification.instance
            .showFailed(reason: _errorMessage!);
      } catch (e) {
        AppLogger.w(_logTag, '显示失败通知失败：$e');
      }
      await _saveHistory(
        status: ConvertStatus.failed,
        errorMessage: _errorMessage!,
      );
      _emitState(ConvertState.failed);
    } finally {
      // 不管成功/失败/取消，都清理 M3U8 临时目录
      await _cleanupImportedTempDir();
    }
  }

  /// 取消正在运行的转换（仅在 running 状态下有效）
  ///
  /// v1.6.21+ 升级：
  ///   - 原来的 cancel 现在专指"彻底取消"，会清掉所有恢复状态
  ///   - 如果用户想"暂停"，请改用 pause()
  Future<void> cancel() async {
    if (_state != ConvertState.running) {
      AppLogger.i(_logTag, '当前无运行中的任务，跳过 cancel()');
      return;
    }
    AppLogger.i(_logTag, '用户请求彻底取消任务');
    // 彻底取消：清掉可能存在的恢复状态
    await ConvertResumeStore.instance.clear();
    await _ffmpeg.cancel();
    // 真正的状态切换由 FFmpegSession 回调触发（cancelled 事件）
  }

  /// 暂停正在运行的转换（仅在 running 状态下有效）
  ///
  /// v1.6.21+ 新增：
  ///   行为与"取消"不同 —— 暂停会**保留**已编码的部分 + 写入恢复状态，
  ///   让用户随时可以从中断点继续。
  ///
  /// 实现：
  ///   1) 调用 FFmpegService.cancel() 终止当前会话
  ///   2) 读取 _lastEncodedTimeMs（FFmpegService 内部统计的最后一帧时间）
  ///   3) 把完整的 ConvertResumeState 写入磁盘
  ///   4) 状态切到 paused
  ///   5) 通知栏更新为"已暂停"
  Future<void> pause() async {
    if (_state != ConvertState.running) {
      AppLogger.w(_logTag, '当前无运行中的任务，跳过 pause()');
      return;
    }
    final cfg = _config;
    if (cfg == null) {
      AppLogger.w(_logTag, 'pause() 时 _config 为空，按取消处理');
      await cancel();
      return;
    }
    AppLogger.i(_logTag, '用户请求暂停任务');

    // 在 cancel 之前抢最后一帧时间（cancel 之后会话仍在收尾，统计可能变）
    final encodedMs = _ffmpeg.lastEncodedTimeMs;
    AppLogger.i(_logTag, '暂停时已编码时长：${encodedMs}ms');

    // 主动 cancel FFmpeg
    await _ffmpeg.cancel();

    // 写恢复状态
    final resume = ConvertResumeState(
      input: cfg.input,
      outputPath: cfg.outputPath,
      format: cfg.format,
      quality: cfg.quality,
      sourceName: cfg.sourceName,
      isNetwork: cfg.isNetwork,
      saveSettings: cfg.saveSettings,
      importedTempDirPath: cfg.importedTempDir?.path,
      startTimeMs: cfg.startTimeMs,
      startInput: cfg.startInput,
      encodedTimeMs: encodedMs,
      totalDurationMs: _sourceDurationMs ?? 0,
      pausedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await ConvertResumeStore.instance.save(resume);

    // 更新通知
    try {
      await ConvertNotification.instance
          .showPaused(sourceName: cfg.sourceName, progressPct: _progress.value);
    } catch (e) {
      AppLogger.w(_logTag, '显示暂停通知失败：$e');
    }

    // 状态切换为 paused（保持进度值不变）
    _emitState(ConvertState.paused);
    AppLogger.i(_logTag, '已暂停，可恢复');
  }

  /// 恢复已暂停的转换（仅在 paused 状态下有效）
  ///
  /// v1.6.21+ 新增：
  ///   读取磁盘上的 ConvertResumeState，调 FFmpegService.convertResume()
  ///   从中断点继续编码 + 拼接。
  ///   完成后：保存历史、复制到 SAF（如果有）、删除恢复状态。
  Future<void> resume() async {
    if (_state != ConvertState.paused) {
      AppLogger.w(_logTag, '当前状态不是 paused，无法 resume()');
      return;
    }
    final resume = ConvertResumeStore.instance.current;
    if (resume == null) {
      AppLogger.w(_logTag, '没有可用的恢复状态，状态置为 idle');
      _emitState(ConvertState.idle);
      return;
    }
    AppLogger.i(
      _logTag,
      '用户请求恢复转换：encodedTimeMs=${resume.encodedTimeMs}，'
      'total=${resume.totalDurationMs}ms',
    );

    // 恢复通知为"继续转换中"
    try {
      await ConvertNotification.instance
          .showResumed(sourceName: resume.sourceName);
    } catch (e) {
      AppLogger.w(_logTag, '显示恢复通知失败：$e');
    }

    _emitState(ConvertState.running);

    try {
      // 进度：从中断点开始（占整体 0.0~0.7）
      // 实际进度由 FFmpegService.convertResume 内部重新计算
      final resumeProgressBase = resume.encodedTimeMs /
          (resume.totalDurationMs > 0 ? resume.totalDurationMs : 1);
      _progress = ConvertProgress(
        value: resumeProgressBase.clamp(0.0, 1.0),
        hasDuration: resume.totalDurationMs > 0,
      );
      _events.add(ConvertProgressEvent(_progress));

      final result = await _ffmpeg.convertResume(
        input: resume.input,
        partialOutputPath: resume.outputPath,
        finalOutputPath: resume.outputPath,
        resumeFromMs: resume.encodedTimeMs,
        format: resume.format,
        quality: resume.quality,
        onProgress: (p) async {
          _progress = p;
          _events.add(ConvertProgressEvent(p));
          try {
            await ConvertNotification.instance.updateProgress(p);
          } catch (e) {
            AppLogger.w(_logTag, '推送进度通知失败：$e');
          }
        },
      );

      // ============ 成功分支 ============
      _outputPath = result.outputPath;
      _outputSize = result.outputSize;
      _sourceDurationMs = resume.totalDurationMs;

      // 复制到 SAF 自定义目录（如果有）
      if (resume.saveSettings.mode == VideoSaveMode.customSaf &&
          resume.saveSettings.customSafTreeUri != null) {
        try {
          final customUri = resume.saveSettings.customSafTreeUri!;
          final fileName = p.basename(result.outputPath);
          const channel = MethodChannel('com.example.toolapp/storage');
          final written = await channel.invokeMethod<String>(
            'writeFileToSafTree',
            {
              'treeUri': customUri,
              'fileName': fileName,
              'srcPath': result.outputPath,
            },
          );
          AppLogger.i(_logTag, '已复制到 SAF 自定义目录：$written');
        } catch (e, st) {
          AppLogger.e(_logTag, '复制到 SAF 自定义目录失败：$e', e, st);
        }
      }

      try {
        await ConvertNotification.instance
            .showCompleted(outputName: p.basename(result.outputPath));
      } catch (e) {
        AppLogger.w(_logTag, '显示完成通知失败：$e');
      }

      // 构造一个伪 ConvertTaskConfig 喂给 _saveHistory
      _config = ConvertTaskConfig(
        input: resume.input,
        outputPath: result.outputPath,
        format: resume.format,
        quality: resume.quality,
        sourceName: resume.sourceName,
        isNetwork: resume.isNetwork,
        saveSettings: resume.saveSettings,
        startTimeMs: resume.startTimeMs,
        startInput: resume.startInput,
        importedTempDir: resume.importedTempDirPath == null
            ? null
            : Directory(resume.importedTempDirPath!),
      );
      await _saveHistory(
        status: ConvertStatus.success,
        outputPath: result.outputPath,
        outputSize: result.outputSize,
      );
      // 删恢复状态
      await ConvertResumeStore.instance.clear();
      _emitState(ConvertState.done);
    } on FFmpegException catch (e, st) {
      AppLogger.e(_logTag, '恢复-FFmpeg 异常', e, st);
      if (e.isCancelled) {
        // 恢复过程中被取消：保留恢复状态，让用户可以再次 resume
        try {
          await ConvertNotification.instance.showCancelled();
        } catch (err) {
          AppLogger.w(_logTag, '显示取消通知失败：$err');
        }
        _emitState(ConvertState.paused);
      } else {
        _errorMessage = e.message;
        _lastErrorLogs = e.fullLogs;
        try {
          await ConvertNotification.instance
              .showFailed(reason: e.message);
        } catch (err) {
          AppLogger.w(_logTag, '显示失败通知失败：$err');
        }
        // 失败：保留恢复状态？或者清除？
        // 这里选择清除 —— 失败后再 resume 没什么意义
        await ConvertResumeStore.instance.clear();
        _emitState(ConvertState.failed);
      }
    } catch (e, st) {
      AppLogger.e(_logTag, '恢复-异常', e, st);
      _errorMessage = '恢复失败：$e';
      try {
        await ConvertNotification.instance.showFailed(reason: _errorMessage!);
      } catch (err) {
        AppLogger.w(_logTag, '显示失败通知失败：$err');
      }
      await ConvertResumeStore.instance.clear();
      _emitState(ConvertState.failed);
    }
  }

  /// 主动检查并加载"上次未完成的暂停任务"
  ///
  /// v1.6.21+ 新增：App 启动 / 进入转换页时调用一次。
  /// - 如果磁盘上有暂停状态，状态机恢复为 paused
  /// - 如果没有，正常保持 idle
  Future<ConvertResumeState?> bootstrapFromDisk() async {
    final resume = await ConvertResumeStore.instance.load();
    if (resume == null) return null;
    AppLogger.i(
      _logTag,
      '从磁盘恢复暂停任务：encodedTimeMs=${resume.encodedTimeMs}ms',
    );
    // 还原 config（供后续 resume() 用）
    _config = ConvertTaskConfig(
      input: resume.input,
      outputPath: resume.outputPath,
      format: resume.format,
      quality: resume.quality,
      sourceName: resume.sourceName,
      isNetwork: resume.isNetwork,
      saveSettings: resume.saveSettings,
      startTimeMs: resume.startTimeMs,
      startInput: resume.startInput,
      importedTempDir: resume.importedTempDirPath == null
          ? null
          : Directory(resume.importedTempDirPath!),
    );
    _sourceDurationMs = resume.totalDurationMs;
    // 进度设为上次的位置
    final pct = resume.totalDurationMs > 0
        ? resume.encodedTimeMs / resume.totalDurationMs
        : 0.0;
    _progress = ConvertProgress(
      value: pct.clamp(0.0, 1.0),
      hasDuration: resume.totalDurationMs > 0,
    );
    _emitState(ConvertState.paused);
    return resume;
  }

  /// 订阅事件流
  ///
  /// 重要：StreamController 是 broadcast 模式，但**不**重放历史事件。
  /// 调用方在订阅时应先读取当前 state / progress 同步 UI 一次。
  StreamSubscription<ConvertEvent> subscribe(
    void Function(ConvertEvent event) onEvent,
  ) {
    return _events.stream.listen(onEvent);
  }

  // ------------------------------------------------------------------
  // 内部
  // ------------------------------------------------------------------

  /// 重置运行期字段（每次 start() 时调用）
  void _resetRuntimeFields() {
    _outputPath = null;
    _outputSize = null;
    _sourceDurationMs = null;
    _errorMessage = null;
    _lastErrorLogs = null;
    _progress = const ConvertProgress(value: 0, hasDuration: false);
  }

  /// 广播状态变化事件
  void _emitState(ConvertState s) {
    _state = s;
    AppLogger.i(_logTag, '状态切换：$s');
    _events.add(ConvertStateEvent(
      state: s,
      errorMessage: _errorMessage,
      outputPath: _outputPath,
      outputSize: _outputSize,
      sourceDurationMs: _sourceDurationMs,
    ));
  }

  /// 清理 M3U8 导入的临时目录
  Future<void> _cleanupImportedTempDir() async {
    final dir = _config?.importedTempDir;
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        AppLogger.i(_logTag, '已清理导入临时目录：${dir.path}');
      }
    } catch (e) {
      AppLogger.w(_logTag, '清理导入临时目录失败：$e');
    }
  }

  /// 保存历史记录（失败不影响主流程）
  Future<void> _saveHistory({
    required ConvertStatus status,
    String? outputPath,
    int? outputSize,
    String? errorMessage,
  }) async {
    final cfg = _config;
    if (cfg == null) return;
    try {
      final now = DateTime.now();
      await ConvertHistory.add(
        ConvertHistoryEntry(
          id: now.millisecondsSinceEpoch,
          timestampMs: now.millisecondsSinceEpoch,
          input: cfg.startInput,
          isNetwork: cfg.isNetwork,
          outputPath: outputPath,
          outputSize: outputSize,
          sourceDurationMs: _sourceDurationMs,
          durationMs: now.millisecondsSinceEpoch - cfg.startTimeMs,
          format: cfg.format,
          quality: cfg.quality,
          status: status,
          errorMessage: errorMessage,
        ),
      );
    } catch (e, st) {
      AppLogger.e(_logTag, '保存历史失败', e, st);
    }
  }
}
