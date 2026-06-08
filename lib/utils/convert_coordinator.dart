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

/// v1.6.30+ 新增（bug16 配套）：
///   续转 / 启动时 FFmpeg 会话已创建但还没出第一帧的事件。
///   用于在 FFmpeg 启动的 5~10s 空窗期内给 UI 明确的"系统在干活"反馈。
///   之前没有这个事件，UI 只能等第一个 ConvertProgressEvent 到达才更新，
///   大体积文件时用户能明显感到"卡在准备中"。
///
/// 与 ConvertProgressEvent 的区别：
///   - ConvertProgressEvent 携带**真实**的编码进度
///   - ConvertSessionStartingEvent 携带**会话阶段**信息（"启动中"）
///     UI 收到后应该：进度条停在 resumeProgressBase，按钮文字切到
///     "FFmpeg 启动中..."，等真正的 ConvertProgressEvent 来了再切换
class ConvertSessionStartingEvent extends ConvertEvent {
  /// 阶段标签（给 UI 选用）：
  ///   - "starting-resume"：续转场景
  ///   - "starting"：首次启动场景（未来可扩展）
  final String phase;
  const ConvertSessionStartingEvent({this.phase = 'starting'});
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

/// v1.6.22+ 新增：暂停意图包
///
/// pause() 在挂起时把 encodedMs + cfg 打包塞进 _pendingPauseRequest，
/// start()/resume() 的 catch 块在处理 FFmpegException(isCancelled=true) 时
/// 消费它：写恢复状态、推通知、emitState(paused)。
///
/// 用对象而不是简单 bool 的原因：
///   1) 暂停时需要带 encodedMs（最新已编码时长）一起传给后续逻辑，
///      单 bool 标志位表达不了；
///   2) 区分"pause() 触发的取消"和"用户点取消触发的取消"在异步回调中
///      更可靠——非空 = 是 pause() 留下的、空 = 是用户取消。
class _PauseRequest {
  final int encodedMs;
  final ConvertTaskConfig cfg;
  _PauseRequest({required this.encodedMs, required this.cfg});
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

  /// v1.6.22+ 新增：pause() 挂起的暂停请求
  ///
  /// 用法：
  ///   1) pause() 把 _pendingPauseRequest 设为非空（带着 encodedMs + cfg）
  ///   2) pause() 调 _ffmpeg.cancel() 终止 FFmpeg 会话
  ///   3) **FFmpegKit 的 cancel 回调是异步派发的**，可能在 pause() 返回之后才跑
  ///   4) 回调跑起来后，start()/resume() 的 await 抛出 FFmpegException(isCancelled=true)
  ///   5) start()/resume() 的 catch 块看到 _pendingPauseRequest 非空 → 走"暂停"分支：
  ///      写恢复状态、推暂停通知、emitState(paused)，**但不要消费 _pendingPauseRequest**
  ///   6) catch 块 return
  ///   7) finally 块消费 _pendingPauseRequest = null，并根据"是不是 pause 流程"
  ///      决定要不要清理 M3U8 tempDir —— pause 流程必须跳过清理（resume() 还要用）
  ///
  /// **为什么 catch 块不能消费 _pendingPauseRequest（v1.6.22+ bug5 教训）**：
  ///   旧版设计让 catch 块在暂停分支里把 _pendingPauseRequest 置为 null，
  ///   准备让 finally 块看到 null 走"正常清理"——这是错的！
  ///   那样 finally 块会调 _cleanupImportedTempDir() 把 M3U8 临时目录删掉，
  ///   等用户点"继续转换"时 resume() 启动 FFmpeg 找不到 M3U8 文件，
  ///   报"No such file or directory"。这就是上一版 v1.6.22+ 留下的 bug。
  ///   新版：catch 块只读 _pendingPauseRequest 字段，**不消费**；
  ///   让 finally 块统一消费：非空说明是 pause 流程→跳过清理；空说明走完了。
  ///   但 FFmpegKit 的 cancel 回调是**异步**的，等它派发到 start() 的 catch 块时，
  ///   pause() 已经跑完、_pauseRequested 已经被复位为 false，catch 块就按
  ///   "用户取消"把状态切到 cancelled、删掉 tempDir，把刚 emit 的 paused 顶掉。
  ///   表现就是用户点"暂停" → 状态被错切到 cancelled → 临时目录被删，
  ///   完全等同"取消"。
  ///
  ///   新的设计：pause() 不再 reset 任何标志（pause() 自己根本不写恢复状态 /
  ///   emit paused，全部工作挪到 start() catch 块里去），pause() 只挂个
  ///   "暂停意图"对象，cancel 回调跑起来时由 start() catch 块**只读不消费**地读它。
  ///   这就避免了"标志位被早于回调 reset"这种时序坑。
  _PauseRequest? _pendingPauseRequest;

  // ------------------------------------------------------------------
  // 公开 API
  // ------------------------------------------------------------------

  /// 启动一次转换任务
  ///
  /// - 入参 config 描述本次任务的所有信息
  /// - 任务在 Coordinator 内部异步执行，调用方**不需要 await**
  /// - 多次调用：第二次 start() 在已有任务未结束时直接抛 StateError
  /// v1.6.33+ 修复（bug19）：
  ///   旧版 start() 头部 `if (_state == running) throw StateError(...)` 是在
  ///   try-catch 块**之外**同步抛的，抛出来的 StateError 不会被下方的
  ///   `catch (e) { _errorMessage = '启动/执行失败：$e'; _emitState(failed); }`
  ///   捕获，而是作为 unhandled async error 直接飘走。
  ///   后果：状态没有切到 failed（仍是 running），用户后续点"开始转换"会一直
  ///   触发同一个 Bad state 错误，看起来"卡死了"——这就是用户报的
  ///   "停止/取消后无法再次开始转换"。
  ///   修复：把 running 检查也包进 try-catch，让它走统一的失败收尾。
  ///   效果：state 立即切到 failed，errorMessage 写好，UI 立刻可重新点开始。
  Future<void> start(ConvertTaskConfig config) async {
    try {
      // v1.6.35+ 修复（bug20）：
      //   检查 Coordinator 状态与 FFmpegService 内部状态是否一致。
      //   如果 Coordinator 状态不是 running，但 FFmpegService 的 isRunning == true，
      //   说明有状态残留（比如上次取消时 FFmpeg 的 finally 没走到，_isRunning 还是 true），
      //   此时要强制调用 _ffmpeg.forceReset() 清空所有标志位，否则下次调用 _ffmpeg.convert()
      //   会直接抛 "已有转换任务在进行中，请先取消" 错误！
      if (_state != ConvertState.running && _ffmpeg.isRunning) {
        AppLogger.w(_logTag, '检测到状态不一致：_state != running 但 _ffmpeg.isRunning = true，强制重置 FFmpegService');
        _ffmpeg.forceReset();
      }

      if (_state == ConvertState.running) {
        AppLogger.w(_logTag, '已有任务在运行，忽略新的 start() 调用');
        throw StateError('已有转换任务在进行中，请先取消');
      }

      // v1.6.22+ 修复（bug3，第二次）：
      //   清掉可能残留的 _pendingPauseRequest。
      //   理论上新 start() 进来时应该已经没有残留（上次 pause 流程的 catch 块
      //   已经消费过），但保险起见在每次新任务入口处都重置一下。
      _pendingPauseRequest = null;

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
        // v1.6.22+ 修复（bug3，第二次 + bug5 修复）：
        //   如果这次 FFmpegException 是 pause() 触发的（_pendingPauseRequest 非空），
        //   写恢复状态、推暂停通知、emitState(paused) 全部由这里（catch 块）执行。
        //   pause() 只挂请求 + cancel FFmpeg，**不再自己**做这些收尾工作。
        //
        //   **关键 bug5 修复**：catch 块**不要**把 _pendingPauseRequest 置为 null！
        //   旧版（v1.6.22+ 第一次）catch 块把 _pendingPauseRequest 消费掉 = null 之后，
        //   finally 块看到它是 null 就跑了 _cleanupImportedTempDir()，把 M3U8
        //   临时目录删了，resume() 启动 FFmpeg 时找不到 M3U8 文件就报
        //   "No such file or directory"。
        //   新版：catch 块只读 _pendingPauseRequest 的字段，**不消费**；
        //   让 finally 块去消费，并根据"是不是还在"决定要不要清理 tempDir。
        final pending = _pendingPauseRequest;
        if (pending != null) {
          // ⚠️ 注意：不要写 _pendingPauseRequest = null！
          //   让 finally 块自己消费（见 finally 块注释）。
          AppLogger.i(_logTag, 'FFmpeg 被 pause() 取消，在 catch 块里写暂停收尾');

          // 写恢复状态
          final resume = ConvertResumeState(
            input: pending.cfg.input,
            outputPath: pending.cfg.outputPath,
            format: pending.cfg.format,
            quality: pending.cfg.quality,
            sourceName: pending.cfg.sourceName,
            isNetwork: pending.cfg.isNetwork,
            saveSettings: pending.cfg.saveSettings,
            importedTempDirPath: pending.cfg.importedTempDir?.path,
            startTimeMs: pending.cfg.startTimeMs,
            startInput: pending.cfg.startInput,
            encodedTimeMs: pending.encodedMs,
            totalDurationMs: _ffmpeg.lastDurationMs ?? _sourceDurationMs ?? 0,
            pausedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          await ConvertResumeStore.instance.save(resume);

          // 推暂停通知
          try {
            await ConvertNotification.instance.showPaused(
                sourceName: pending.cfg.sourceName,
                progressPct: _progress.value);
          } catch (err) {
            AppLogger.w(_logTag, '显示暂停通知失败：$err');
          }

          // 状态切到 paused（保持进度值不变，让 UI 显示"继续转换"按钮）
          _emitState(ConvertState.paused);
          AppLogger.i(_logTag, '已暂停，可恢复（catch 块处理完毕）');
          return;
        }
        try {
          await ConvertNotification.instance.showCancelled();
        } catch (e) {
          AppLogger.w(_logTag, '显示取消通知失败：$e');
        }
        // v1.6.37+ 修复（BUG3 配套）：
        //   cancel() 方法现在会立即 emit cancelled 状态。
        //   如果 _state 已经是 cancelled，说明 cancel() 已经处理过了，
        //   这里跳过重复写历史和 emit，避免双重通知/双重历史记录。
        if (_state != ConvertState.cancelled) {
          await _saveHistory(
            status: ConvertStatus.cancelled,
            errorMessage: '用户取消',
          );
          _emitState(ConvertState.cancelled);
        } else {
          AppLogger.d(_logTag, 'cancel() 已处理过取消逻辑，跳过重复收尾');
        }
      } else {
        // ============ 失败分支 ============
        // v1.6.31+ 修复（bug17 配套）：区分"源文件不存在"和"普通失败"
        //   取消转换时 _importedTempDir 被 Coordinator 删（v1.6.31+ 起
        //   _sourceValue 不会自动清），用户点"开始转换"会触发
        //   convert() 的源文件预校验失败（isResumeSourceMissing=true）。
        //   弹明确引导提示，而不是通用的"启动失败"措辞。
        if (e.isResumeSourceMissing) {
          _errorMessage = e.message;
          AppLogger.w(_logTag, 'start()-源文件已不存在：${e.message}');
        } else {
          _errorMessage = e.message;
          _lastErrorLogs = e.fullLogs;
        }
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
      // v1.6.22+ 修复（bug5）：
      //   pause() 触发的取消不能清理 M3U8 临时目录（resume() 还要用它），
      //   所以这里消费 _pendingPauseRequest 并据此决定要不要清理：
      //     - _pendingPauseRequest 非空：catch 块走的"暂停"分支，
      //       消费掉、跳过清理（让 resume() 还能用 M3U8 文件）
      //     - _pendingPauseRequest 已为 null：正常清理（成功/失败/用户取消）
      //
      //   旧版设计（v1.6.22+ 第一次）有 bug：catch 块在暂停分支里把
      //   _pendingPauseRequest 置回 null，导致 finally 块判断失误、
      //   误删 M3U8 tempDir，resume() 报"No such file or directory"。
      if (_pendingPauseRequest != null) {
        AppLogger.i(_logTag,
            'finally 块：检测到 _pendingPauseRequest（pause 流程），消费并跳过清理 tempDir');
        _pendingPauseRequest = null;
        // ⚠️ 不要 await _cleanupImportedTempDir() — resume() 还要用 M3U8 文件
      } else if (_state == ConvertState.done) {
        // v1.6.40+ 修复（问题3）：只有转换成功完成时才清理临时目录。
        //   取消/失败时保留临时目录，让用户可以重新开始转换而不需要重新复制 M3U8 文件。
        //   旧版不管成功/失败/取消都清理，导致取消后重新开始时需要重新复制，
        //   用户体验差（大文件复制可能要几十秒）。
        await _cleanupImportedTempDir();
      } else {
        // 取消或失败：保留临时目录，用户可能要重新开始转换
        AppLogger.i(_logTag,
            'finally 块：任务未成功完成（state=$_state），保留临时目录供重新转换使用');
      }
    }
    } catch (e, st) {
      // v1.6.33+ 修复（bug19）：
      //   外层 try-catch 专门接 start() 头部那个"已有任务在运行"的 StateError
      //   以及其他在进入内层 try 之前就抛的异常。走和内层 catch 一样的
      //   失败收尾：写 errorMessage、弹失败通知、写历史、emitState(failed)，
      //   状态立刻从 running 切走，UI 重新可点"开始转换"。
      AppLogger.e(_logTag, 'start() 头部异常', e, st);
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
      // 重新抛给调用方（fire-and-forget 路径下会成为 unhandled，
      //   但此时状态已切到 failed，不会卡死 UI）
      rethrow;
    }
  }

  /// 取消正在运行的转换（在 running / paused 状态下均有效）
  ///
  /// v1.6.21+ 升级：
  ///   - 原来的 cancel 现在专指"彻底取消"，会清掉所有恢复状态
  ///   - 如果用户想"暂停"，请改用 pause()
  ///
  /// v1.6.29+ 修复（bug13，针对大体积文件取消卡顿）：
  ///   旧版 `await _ffmpeg.cancel()` 会一直等 FFmpeg 原生层把会话杀掉。
  ///   FFmpeg 在收到取消信号后还要：处理完当前帧 → 编码器 flush → 写完
  ///   moov atom → 关闭文件 → 进程退出。对大体积文件（H.264 关键帧间隔
  ///   较长时）这一连串收尾可能要 5~30 秒，UI 线程被 await 卡住，
  ///   取消按钮点完没反应。
  ///   新版改为**不 await** _ffmpeg.cancel()，本方法立即返回：
  ///     - 状态机立刻置为 cancelling（不是 cancelled），让 UI 立即知道
  ///       "取消请求已派发，正在等待 FFmpeg 收尾"
  ///     - FFmpeg 收尾结束后 session 回调触发，convert() 的 catch 块
  ///       会走 _emitState(cancelled)，状态机最终稳定到 cancelled
  ///   注意：暂停流程也用同样的非阻塞模式（见 pause() 注释），不要回退到
  ///   `await _ffmpeg.cancel()`，否则大文件取消/暂停卡顿问题会重现。
  ///
  /// v1.6.32+ 修复（bug18，针对 paused 状态下"取消"按钮没反应）：
  ///   旧版只处理 running 状态：`_state != running` 直接 return，
  ///   导致 paused 状态下用户点"取消"按钮（_discardResume 走这里）完全没反应：
  ///     - 恢复状态文件没清
  ///     - Coordinator 状态没切（保持 paused）
  ///     - 临时目录没清
  ///   用户视角看到的就是"按钮按下去啥都没发生"。
  ///   后续用户想开始新一次转换时：
  ///     - 如果在当前页点"开始转换"，_canConvert 因为 _status == paused
  ///       把按钮禁掉，用户看不到任何反馈
  ///     - 如果先点"继续转换"让 Coordinator 状态变 running，再去点
  ///       "开始转换"，start() 看到 _state == running 就抛
  ///       StateError('已有转换任务在进行中，请先取消')，触发用户报的
  ///       "启动、执行失败：Bad state：已有转换任务在进行中，请先取消"
  ///   修复：paused 状态也走取消流程——没有 FFmpeg 在跑，可以同步完成
  ///   所有清理（清恢复状态、清临时目录、复位内部字段、emit cancelled），
  ///   让 UI 立即从 paused 切回 idle，_canConvert 变 true，用户能正常
  ///   点"开始转换"开始新一次任务。
  Future<void> cancel() async {
    if (_state == ConvertState.paused) {
      // ========== paused 分支：放弃恢复 ==========
      //   没有 FFmpeg 会话在跑，cancel 走同步流程：
      //     1) 清掉磁盘上的 resume state（让下次 _tryBootstrapPausedTask 不会恢复）
      //     2) 复位内部字段（_config / _progress / _outputPath / _errorMessage / ...）
      //     3) 清掉 M3U8 导入临时目录（任务已放弃，临时目录没用了）
      //     4) emitState(cancelled) → 触发 UI 切回 idle + 弹"已取消转换"snack
      AppLogger.i(_logTag, 'paused 状态下的取消：清恢复状态 + 复位到 cancelled');
      try {
        await ConvertResumeStore.instance.clear();
      } catch (e) {
        AppLogger.w(_logTag, '清恢复状态失败：$e');
      }
      // 复位内部字段
      _config = null;
      _progress = const ConvertProgress(value: 0, hasDuration: false);
      _outputPath = null;
      _outputSize = null;
      _sourceDurationMs = null;
      _errorMessage = null;
      _lastErrorLogs = null;
      // v1.6.40+ 修复（问题3）：取消时不清理 M3U8 临时目录。
      //   旧版取消时删临时目录，导致用户重新开始转换时需要重新复制 M3U8 文件。
      //   新版保留临时目录，让用户可以直接重新开始转换。
      //   临时目录会在以下时机被清理：
      //     1) 转换成功完成（start() 的 finally 块）
      //     2) 用户主动更换输入源（Page 端 _resetOutputState）
      //     3) Page dispose 时
      // await _cleanupImportedTempDir();
      // 触发状态事件：UI 收到后 _status 切回 idle，"开始转换"按钮可用
      _emitState(ConvertState.cancelled);
      return;
    }
    if (_state != ConvertState.running) {
      AppLogger.i(_logTag, '当前无运行中的任务，跳过 cancel()');
      return;
    }
    AppLogger.i(_logTag, '用户请求彻底取消任务');
    // 彻底取消：清掉可能存在的恢复状态
    await ConvertResumeStore.instance.clear();
    // v1.6.38+ 修复（BUG-C）：清掉 _pendingPauseRequest，防止竞态条件。
    //   场景：用户先点暂停（_pendingPauseRequest 被设置），FFmpeg 还没回调
    //   之前又点取消。cancel() 立即 emit cancelled，但随后 FFmpeg 回调到达
    //   start() 的 catch 块时，_pendingPauseRequest 非空，catch 块走暂停
    //   分支 emit paused，覆盖 cancelled 状态！
    //   清掉 _pendingPauseRequest 后，catch 块会走取消分支，且因为
    //   _state 已经是 cancelled，会跳过重复收尾。
    _pendingPauseRequest = null;
    // v1.6.29+ bug13 修复：不 await，避免大文件取消时 UI 线程被卡住 5~30s
    // FFmpeg 原生 cancel 仍在后台异步执行，session 回调最终会触发
    // convert() 的 catch 块走 _emitState(cancelled) 收尾
    unawaited(_ffmpeg.cancel());
    // v1.6.37+ 修复（BUG3）：cancel() 后立即 emit cancelled 状态，
    //   不再等 FFmpeg 异步回调（可能 5~30 秒）。
    //   旧版 cancel() 返回后 Coordinator 状态仍是 running，导致：
    //     - 用户退出页面再进来 → _syncFromCoordinatorSnapshot 看到 running → 显示"转换中"
    //     - 快速点"开始转换" → _canConvert 看到 isRunning=true → 被拒绝
    //   新版立即切到 cancelled，UI 立刻响应。
    //   同时在这里完成取消通知和历史记录，避免 start() catch 块重复处理。
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
  }

  /// 暂停正在运行的转换（仅在 running 状态下有效）
  ///
  /// v1.6.21+ 新增：
  ///   行为与"取消"不同 —— 暂停会**保留**已编码的部分 + 写入恢复状态，
  ///   让用户随时可以从中断点继续。
  ///
  /// v1.6.22+ 修正（bug3 二次修复）：
  ///   pause() **不再自己**写恢复状态 / emit paused，只挂个 _pendingPauseRequest
  ///   + 调 _ffmpeg.cancel() 终止 FFmpeg 会话。
  ///   真正的"暂停"工作（写恢复状态、推通知、emit paused）由 start()/resume()
  ///   的 catch 块在 FFmpeg cancel 回调派发过来时做。
  ///   原因：FFmpegKit 的 cancel 回调是**异步**派发的，如果 pause() 自己
  ///   在 `await _ffmpeg.cancel()` 返回后立刻 reset 标志位 / emit paused，
  ///   回调派发到 start() catch 时标志位已经没了，catch 块会按"用户取消"
  ///   把状态切到 cancelled + 清理 tempDir，把刚 emit 的 paused 顶掉。
  ///   这就是上一版"暂停=取消"bug 的根因。
  ///
  /// 与"取消"的关键区别：
  ///   - 取消：彻底清空，输出文件被删，下次需要重新选文件
  ///   - 暂停：进度保留，输出文件保留，下次可继续
  ///
  /// v1.6.29+ 修复（bug13，针对大体积文件暂停卡顿）：
  ///   旧版 `await _ffmpeg.cancel()` 会一直等 FFmpeg 原生层把会话杀掉。
  ///   跟 cancel() 一样，对大体积文件要等 5~30 秒，UI 线程被卡住。
  ///   新版不 await，pause() 立即返回，FFmpeg 原生 cancel 后台异步进行。
  ///   catch 块在收到 FFmpegException(isCancelled=true) 时根据
  ///   _pendingPauseRequest 是否非空判断走"暂停"还是"取消"分支，行为不变。
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

    // 挂起暂停请求：start()/resume() 的 catch 块会消费它
    //   - 真正的"写恢复状态 / 推通知 / emit paused"全部由 catch 块执行
    //   - pause() 不再 reset 任何标志，避免在异步回调之前把标志清掉
    _pendingPauseRequest = _PauseRequest(encodedMs: encodedMs, cfg: cfg);

    // 主动 cancel FFmpeg
    //   - v1.6.29+ bug13：不 await，避免大文件暂停时 UI 线程被卡住 5~30s
    //   - 这一步返回时 FFmpeg 还在收尾，cancel 回调还没派发
    //   - 回调派发后，start()/resume() 的 await 抛 FFmpegException(isCancelled=true)
    //   - catch 块看到 _pendingPauseRequest 非空 → 走暂停分支
    unawaited(_ffmpeg.cancel());

    AppLogger.i(_logTag,
        'pause() 返回（剩余工作交给 start()/resume() catch 块异步处理）');
  }

  /// 恢复已暂停的转换（仅在 paused 状态下有效）
  ///
  /// v1.6.21+ 新增：
  ///   读取磁盘上的 ConvertResumeState，调 FFmpegService.convertResume()
  ///   从中断点继续编码 + 拼接。
  ///   完成后：保存历史、复制到 SAF（如果有）、删除恢复状态。
  Future<void> resume() async {
    // v1.6.35+ 修复（bug20）：
    //   检查 Coordinator 状态与 FFmpegService 内部状态是否一致。
    //   如果 Coordinator 状态不是 running，但 FFmpegService 的 isRunning == true，
    //   说明有状态残留，强制调用 _ffmpeg.forceReset() 清空所有标志位！
    if (_state != ConvertState.running && _ffmpeg.isRunning) {
      AppLogger.w(_logTag, '检测到状态不一致：_state != running 但 _ffmpeg.isRunning = true，强制重置 FFmpegService');
      _ffmpeg.forceReset();
    }

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

    // v1.6.22+ 修复（bug3，第二次）：
    //   清掉可能残留的 _pendingPauseRequest。
    //   resume() 是新任务的入口之一，跟 start() 一样保险重置一下。
    _pendingPauseRequest = null;

    // v1.6.30+ 修复（bug16，针对大体积文件续转卡在"准备中"问题）：
    //   旧版这里 `await ConvertNotification.instance.showResumed(...)`，
    //   Android 通知系统是异步的，show() 至少要走一遍 IPC 到系统服务，
    //   实测在某些 ROM 上要 1~3 秒，FFmpeg 会话要等通知返回后才启动。
    //   而 FFmpeg 启动自身（解析 merged.ts、seek 到断点、出第一帧）
    //   还要 5~10 秒。两段加起来用户能感觉到 6~13 秒"卡在准备中"。
    //   改版：fire-and-forget 通知，FFmpeg 启动不再被通知阻塞。
    //   通知系统是"展示型"的，晚 1~3 秒再展示不会影响功能
    //   （用户已经在 App 里看着进度条了，通知只是辅助）。
    unawaited(ConvertNotification.instance
        .showResumed(sourceName: resume.sourceName)
        .catchError((e) {
      AppLogger.w(_logTag, '显示恢复通知失败：$e');
    }));

    _emitState(ConvertState.running);

    try {
      // 进度：从中断点开始（占整体 0.0~0.7）
      // 实际进度由 FFmpegService.convertResume 内部重新计算
      // v1.6.38+ 修复（BUG-F）：totalDurationMs==0 时 resumeProgressBase
      //   会被 clamp 到 1.0（因为 encodedTimeMs / 1 远大于 1），
      //   导致进度条直接跳到 100%。新版在 totalDurationMs<=0 时
      //   用 0.0 作为 base，让进度从 0% 开始。
      final resumeProgressBase = resume.totalDurationMs > 0
          ? (resume.encodedTimeMs / resume.totalDurationMs).clamp(0.0, 1.0)
          : 0.0;
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
        // v1.6.27+ 修复（bug8）：把真实 totalDurationMs 传下去，
        //   让 FFmpegService 能把统计 timeMs 正确归一化到 0~1。
        //   之前漏传（_executeSimple 内部硬编码成 1 占位）会导致
        //   p.value 被 clamp 截到 1.0，外层 p.value * 0.7 = 70%，
        //   resume 进度直接跳到 70%，没有"从暂停位置平滑过渡"的过程。
        totalDurationMs: resume.totalDurationMs,
        // v1.6.28+ 修复（bug10）：把上次规范化好的 tempDir 传下去，
        //   FFmpegService 会复用 merged.ts 跳过整个 M3U8 规范化流程，
        //   续转瞬间启动，不用再"卡在准备中"等好几秒。
        importedTempDir: resume.importedTempDirPath == null
            ? null
            : Directory(resume.importedTempDirPath!),
        format: resume.format,
        quality: resume.quality,
        // v1.6.36+ 修复（bug22，续转卡在"FFmpeg 启动中"问题）：
        //   旧版传 onSessionStarting 回调，FFmpeg 会话创建后 UI 切到
        //   "FFmpeg 启动中..."，但续转时 FFmpeg 需要 seek 到断点再出第一帧，
        //   这个过程可能要好几秒甚至更久，用户一直卡在"FFmpeg 启动中"。
        //   修复：续转时不传 onSessionStarting，UI 保持"正在恢复转换..."
        //   直到 FFmpeg 出第一帧（hasDuration=true），才切到"正在转换..."。
        //   这样用户看到的是连贯的"恢复中 → 正在转换"，不会卡在中间状态。
        onSessionStarting: null,
        onProgress: (p) async {
          // v1.6.29+ 修复（bug14，针对大体积文件续转卡顿体验）：
          //   旧版这里直接 `await ConvertNotification.instance.updateProgress(p)`
          //   并把 p 当作最终进度往外发，会导致用户看到进度从 resumeProgressBase
          //   （如 30%）突然跳到 0%，再缓慢爬回 70%，体验非常卡顿：
          //     - 旧版：emit(_events, p)；p.value 来自 _onStatistics，
          //       即 (timeMs / totalDurationMs).clamp(0, 1)。
          //       FFmpeg 在 encode 步骤开始时 timeMs == resumeFromMs，
          //       p.value = resumeFromMs / totalDurationMs = resumeProgressBase（如 0.3）。
          //       然后 convertResume() 在内部又包了一层 `p.value * 0.7`，
          //       最终 p.value = 0.3 * 0.7 = 0.21 (21%)，
          //       于是用户看到进度从 30% → 21% → 70% → 99% → 100% 的奇怪跳变。
          //   新版：把 p.value 重新缩放到 [resumeProgressBase, 1.0] 区间：
          //     overall = resumeProgressBase + p.value * (1.0 - resumeProgressBase)
          //   这样：
          //     - 用户点"继续转换"瞬间看到的是 resumeProgressBase（如 30%）
          //     - encode 步骤开始：p.value ≈ 0.21 → overall ≈ 30%（不变）
          //     - encode 步骤进行：p.value 缓慢增长 → overall 缓慢增长
          //     - encode 步骤结束：p.value ≈ 0.7 → overall ≈ 0.79
          //     - concat 步骤进行：p.value → 0.99 → overall → 0.993
          //     - done：overall = 1.0
          //   进度条从断点位置平滑爬到 100%，不再有 30%→21% 的回退跳变。
          //   对 totalDurationMs == 0 的兜底场景（duration 探测失败时），
          //   缩放后 p.value 仍然是 unknown，UI 走"准备中..."分支，
          //   由 bug5 配套的 UI 改造（v1.6.29+ todo 第 5 项）显示更友好的提示。
          // v1.6.39+ 修复（BUG-G 配套）：
          //   将 clamp 下限从 0.0 改为 base，确保续转进度不会低于
          //   resumeProgressBase。即使 FFmpeg 的 statistics 回调在
          //   续转初期报告异常值（如 timeMs 为负数或偏小），
          //   进度也不会回退到暂停位置以下。
          final base = resumeProgressBase.clamp(0.0, 1.0);
          final scaledValue = base + p.value * (1.0 - base);
          final scaled = ConvertProgress(
            value: scaledValue.clamp(base, 1.0),
            hasDuration: p.hasDuration,
            bitrate: p.bitrate,
            time: p.time,
            etaSeconds: p.etaSeconds,
          );
          _progress = scaled;
          _events.add(ConvertProgressEvent(scaled));
          try {
            await ConvertNotification.instance.updateProgress(scaled);
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
        // v1.6.22+ 修复（bug3，第二次 + bug5 修复）：
        //   恢复过程中如果是被 pause() 取消，由 catch 块写新的恢复状态
        //   （带着最新 encodedMs）、推暂停通知、emitState(paused)。
        //
        //   与 start() 流程的差异：resume() 流程里 pause() 挂起的
        //   _pendingPauseRequest.cfg 是旧的（在 pause() 调用之前已经在跑
        //   start()/resume() 的 _config），但**关键信息（input/outputPath/...
        //   等）在磁盘的 resume state 里都有**。所以这里以磁盘上的 resume
        //   state 为准，只把 encodedMs 替换成最新值，其它字段原样保留，
        //   再写回磁盘。这样下次 resume() 还能从断点继续。
        //
        //   **关键 bug5 修复**：catch 块**不要**把 _pendingPauseRequest 置为 null！
        //   跟 start() 一样，让 finally 块去消费。
        final pending = _pendingPauseRequest;
        if (pending != null) {
          // ⚠️ 注意：不要写 _pendingPauseRequest = null！
          //   让 finally 块自己消费（见 finally 块注释）。
          AppLogger.i(_logTag, '恢复被 pause() 取消，在 catch 块里写暂停收尾');

          // 构造新的 resume state：只更新 encodedMs 和 pausedAtMs，其它继承自旧 state
          final updated = ConvertResumeState(
            input: resume.input,
            outputPath: resume.outputPath,
            format: resume.format,
            quality: resume.quality,
            sourceName: resume.sourceName,
            isNetwork: resume.isNetwork,
            saveSettings: resume.saveSettings,
            importedTempDirPath: resume.importedTempDirPath,
            startTimeMs: resume.startTimeMs,
            startInput: resume.startInput,
            encodedTimeMs: pending.encodedMs,
            totalDurationMs: _ffmpeg.lastDurationMs ?? resume.totalDurationMs,
            pausedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          await ConvertResumeStore.instance.save(updated);

          // 推暂停通知
          try {
            await ConvertNotification.instance.showPaused(
                sourceName: resume.sourceName, progressPct: _progress.value);
          } catch (err) {
            AppLogger.w(_logTag, '显示暂停通知失败：$err');
          }

          _emitState(ConvertState.paused);
          AppLogger.i(_logTag, '已暂停（resume 流程中），可恢复');
          return;
        }
        // 恢复过程中被取消：彻底取消，清除恢复状态
        // v1.6.28+ 修复（bug11）：
        //   旧版这里写 _emitState(ConvertState.paused)，导致用户看到
        //   "暂停" 状态并能点 "继续转换"，但实际 resume 流程里有状态机
        //   问题，按钮点了也不能再次启动（暂停恢复逻辑的标志位被消费
        //   过了但磁盘上 resume state 已经被这个 catch 路径吃掉了，行为
        //   错乱）。现在改成彻底取消：清掉磁盘的 resume state，切到
        //   cancelled 状态，让用户重新开始一次转换。
        try {
          await ConvertNotification.instance.showCancelled();
        } catch (err) {
          AppLogger.w(_logTag, '显示取消通知失败：$err');
        }
        // 主动清除磁盘上的 resume state
        await ConvertResumeStore.instance.clear();
        // 还原 config 中残留的 importedTempDir 引用（状态机复位）
        _config = null;
        _progress = const ConvertProgress(value: 0, hasDuration: false);
        _emitState(ConvertState.cancelled);
        AppLogger.i(_logTag, '恢复-已被用户取消（彻底取消，不是暂停）');
      } else {
        // v1.6.31+ 修复（bug17）：区分"源文件不存在"和"普通失败"
        if (e.isResumeSourceMissing) {
          // 源文件已不存在（用户换 M3U8 文件夹 / 系统清 cache 等）
          // 弹明确的引导提示，引导用户重新选 M3U8
          _errorMessage = e.message;
          AppLogger.w(_logTag, '恢复-源文件已不存在：${e.message}');
          try {
            await ConvertNotification.instance
                .showFailed(reason: e.message);
          } catch (err) {
            AppLogger.w(_logTag, '显示失败通知失败：$err');
          }
        } else {
          _errorMessage = e.message;
          _lastErrorLogs = e.fullLogs;
          try {
            await ConvertNotification.instance
                .showFailed(reason: e.message);
          } catch (err) {
            AppLogger.w(_logTag, '显示失败通知失败：$err');
          }
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
    } finally {
      // v1.6.22+ 修复（bug5）：
      //   pause() 触发的取消不能清理 M3U8 临时目录（resume() 还要用它），
      //   跟 start() 的 finally 块逻辑保持一致。
      //   旧版设计（v1.6.22+ 第一次）有 bug：catch 块在暂停分支里把
      //   _pendingPauseRequest 置回 null，导致 finally 块判断失误、
      //   误删 M3U8 tempDir，resume() 报"No such file or directory"。
      if (_pendingPauseRequest != null) {
        AppLogger.i(_logTag,
            'finally 块：检测到 _pendingPauseRequest（pause 流程），消费并跳过清理 tempDir');
        _pendingPauseRequest = null;
        // ⚠️ 不要 await _cleanupImportedTempDir() — resume() 还要用 M3U8 文件
      } else if (_state == ConvertState.done) {
        // v1.6.40+ 修复（问题3）：只有转换成功完成时才清理临时目录
        await _cleanupImportedTempDir();
      } else {
        AppLogger.i(_logTag,
            'finally 块：任务未成功完成（state=$_state），保留临时目录供重新转换使用');
      }
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
