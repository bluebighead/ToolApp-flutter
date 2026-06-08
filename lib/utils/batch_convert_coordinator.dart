// 批量转换全局协调器（单例）
//
// 管理批量转换任务队列，支持：
//   - 并行控制（Semaphore）
//   - 单个任务进度回调
//   - 整体进度追踪
//   - 单任务暂停/恢复（从断点续转）
//   - 单任务取消
//   - 全部取消
//
// 用法：
//   - 启动：
//       BatchConvertCoordinator.instance.start(tasks, format, quality);
//   - 单任务暂停：
//       await BatchConvertCoordinator.instance.pauseTask(index);
//   - 单任务恢复：
//       await BatchConvertCoordinator.instance.resumeTask(index);
//   - 单任务取消：
//       await BatchConvertCoordinator.instance.cancelTask(index);
//   - 全部取消：
//       await BatchConvertCoordinator.instance.cancel();
//   - 订阅：
//       final sub = BatchConvertCoordinator.instance.subscribe(onEvent);

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'convert_history.dart';
import 'convert_speed_settings.dart';
import 'ffmpeg_service.dart';
import 'saf_directory_helper.dart';
import 'video_save_settings.dart';

/// 批量转换任务状态
enum BatchTaskState {
  /// 等待中
  waiting,
  /// 转换中
  converting,
  /// 已暂停
  paused,
  /// 已完成
  done,
  /// 失败
  failed,
  /// 已取消
  cancelled,
}

/// 批量转换整体状态
enum BatchConvertState {
  /// 无任务
  idle,
  /// 转换中
  running,
  /// 已完成（全部成功）
  done,
  /// 部分失败
  partialFailed,
  /// 全部失败
  allFailed,
  /// 用户取消
  cancelled,
}

/// 单个批量转换任务
class BatchConvertTask {
  /// 输入文件绝对路径
  final String inputPath;

  /// 源文件名（用于展示）
  final String sourceName;

  /// 输出文件绝对路径
  final String outputPath;

  /// 序号（用于命名，从 1 开始）
  final int index;

  /// 当前状态
  BatchTaskState state;

  /// 进度
  ConvertProgress? progress;

  /// 错误信息（失败时）
  String? errorMessage;

  /// 完整 FFmpeg 日志（失败时）
  String? fullLogs;

  /// 转换开始时间
  DateTime? startTime;

  /// 转换结束时间
  DateTime? endTime;

  /// 源文件大小（字节）
  int? inputSize;

  /// 输出文件大小（字节）
  int? outputSize;

  /// 输出视频格式
  VideoFormat? format;

  /// 输出视频质量
  VideoQuality? quality;

  /// 源视频时长（毫秒）
  int? sourceDurationMs;

  /// v1.6.55+ 新增：转换加速模式
  ConvertSpeedMode? speedMode;

  BatchConvertTask({
    required this.inputPath,
    required this.sourceName,
    required this.outputPath,
    required this.index,
    this.state = BatchTaskState.waiting,
    this.progress,
    this.errorMessage,
    this.fullLogs,
    this.startTime,
    this.endTime,
    this.inputSize,
    this.outputSize,
    this.format,
    this.quality,
    this.sourceDurationMs,
    this.speedMode,
  });

  /// 是否处于终态
  bool get isTerminal =>
      state == BatchTaskState.done ||
      state == BatchTaskState.failed ||
      state == BatchTaskState.cancelled;
}

/// 批量转换事件
sealed class BatchConvertEvent {
  const BatchConvertEvent();
}

/// 单个任务进度更新
class BatchTaskProgressEvent extends BatchConvertEvent {
  final int taskIndex;
  final ConvertProgress progress;
  const BatchTaskProgressEvent(this.taskIndex, this.progress);
}

/// 单个任务状态变化
class BatchTaskStateEvent extends BatchConvertEvent {
  final int taskIndex;
  final BatchTaskState state;
  final String? errorMessage;
  const BatchTaskStateEvent(this.taskIndex, this.state, {this.errorMessage});
}

/// 整体状态变化
class BatchOverallStateEvent extends BatchConvertEvent {
  final BatchConvertState state;
  final int completedCount;
  final int totalCount;
  const BatchOverallStateEvent(this.state, this.completedCount, this.totalCount);
}

/// 简易 Semaphore 实现
class _Semaphore {
  final int max;
  int _current = 0;
  final _waiters = <Completer>[];

  _Semaphore(this.max);

  Future<void> acquire() async {
    if (_current < max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    // v1.6.56+ 修复：下溢保护，防止 release() 调用次数超过 acquire()
    // 导致 _current 变为负数，信号量失效
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else if (_current > 0) {
      _current--;
    } else {
      AppLogger.w(
        'BatchConvertCoordinator',
        'Semaphore.release() 被过度调用，_current 已为 0，忽略此次 release',
      );
    }
  }
}

/// 单个任务的暂停请求
class _PauseRequest {
  /// 暂停时已编码的媒体时长（毫秒）
  final int encodedMs;

  /// 暂停时的转换配置（用于恢复）
  final VideoFormat format;
  final VideoQuality quality;

  _PauseRequest({
    required this.encodedMs,
    required this.format,
    required this.quality,
  });
}

/// 单个任务的恢复状态（内存中保存，不持久化到磁盘）
class _TaskResumeState {
  /// FFmpeg 输入源
  final String input;

  /// 输出文件绝对路径（部分输出）
  final String partialOutputPath;

  /// 最终输出文件绝对路径
  final String finalOutputPath;

  /// 已编码时长（毫秒）
  final int encodedTimeMs;

  /// 源媒体总时长（毫秒）
  final int totalDurationMs;

  /// 输出格式
  final VideoFormat format;

  /// 输出质量
  final VideoQuality quality;

  /// 源文件名
  final String sourceName;

  const _TaskResumeState({
    required this.input,
    required this.partialOutputPath,
    required this.finalOutputPath,
    required this.encodedTimeMs,
    required this.totalDurationMs,
    required this.format,
    required this.quality,
    required this.sourceName,
  });
}

/// 批量转换协调器（单例）
class BatchConvertCoordinator {
  static const String _logTag = 'BatchConvertCoordinator';

  BatchConvertCoordinator._();
  static final instance = BatchConvertCoordinator._();

  /// 任务列表
  List<BatchConvertTask> _tasks = [];

  /// 整体状态
  BatchConvertState _state = BatchConvertState.idle;

  /// 事件流
  final _events = StreamController<BatchConvertEvent>.broadcast();

  /// 取消标志（全局）
  bool _cancelled = false;

  // v1.6.52+ 修复：记录当前正在运行的 FFmpegService 实例
  // 取消时需要调用它们的 cancel() 方法，才能真正终止 FFmpeg 进程
  final _activeFfmpegServices = <FFmpegService>[];

  // v1.6.56+ 修复：维护任务索引到 FFmpegService 的映射
  // 旧版 _getActiveFfmpegForTask() 在多并行时始终返回第一个实例，
  // 导致暂停/取消特定任务时可能操作错误的 FFmpeg 会话
  final _taskFfmpegMap = <int, FFmpegService>{};

  /// 单任务暂停请求（索引 -> 暂停请求）
  final _pendingPauseRequests = <int, _PauseRequest>{};

  /// 单任务恢复状态（索引 -> 恢复状态）
  final _taskResumeStates = <int, _TaskResumeState>{};

  /// 单任务取消标志（索引集合）
  final _cancelledTasks = <int>{};

  /// 信号量引用（用于恢复任务时重新获取）
  _Semaphore? _semaphore;

  /// v1.6.53+ 新增：当前批量转换的视频保存设置
  /// 用于在任务完成后将文件复制到 SAF 自定义目录（如果设置了的话）
  VideoSaveSettingsSnapshot? _currentSaveSettings;

  /// 获取任务列表（只读）
  List<BatchConvertTask> get tasks => List.unmodifiable(_tasks);

  /// v1.6.46+ 新增：设置任务列表（用于从外部传入任务）
  set tasksList(List<BatchConvertTask> value) {
    _tasks = value;
  }

  /// v1.6.46+ 新增：获取可变任务列表引用（用于页面直接修改）
  List<BatchConvertTask> get mutableTasks => _tasks;

  /// v1.6.46+ 新增：清空任务列表
  void clearTasks() {
    _tasks.clear();
    _state = BatchConvertState.idle;
    _cancelled = false;
    // v1.6.52+ 修复：清空活跃服务列表
    _activeFfmpegServices.clear();
    // v1.6.56+ 修复：清空索引映射
    _taskFfmpegMap.clear();
    _pendingPauseRequests.clear();
    _taskResumeStates.clear();
    _cancelledTasks.clear();
  }

  /// 获取整体状态
  BatchConvertState get state => _state;

  /// 是否正在运行
  bool get isRunning => _state == BatchConvertState.running;

  /// 已完成数量
  int get completedCount =>
      _tasks.where((t) => t.state == BatchTaskState.done).length;

  /// 订阅事件流
  StreamSubscription<BatchConvertEvent> subscribe(
    void Function(BatchConvertEvent event) onEvent,
  ) {
    return _events.stream.listen(onEvent);
  }

  /// 启动批量转换
  Future<void> start({
    required List<BatchConvertTask> tasks,
    required VideoFormat format,
    required VideoQuality quality,
    VideoSaveSettingsSnapshot? saveSettings,
    int? parallelCount,
  }) async {
    if (_state == BatchConvertState.running) {
      throw StateError('已有批量转换任务在进行中');
    }

    _tasks = tasks;
    _cancelled = false;
    _pendingPauseRequests.clear();
    _taskResumeStates.clear();
    _cancelledTasks.clear();
    _currentSaveSettings = saveSettings;
    _state = BatchConvertState.running;
    _emitOverallState(BatchConvertState.running, 0, _tasks.length);

    // v1.6.56+ 修复：启动前台服务，防止后台/息屏时被系统杀进程
    unawaited(ForegroundServiceHelper.start(
      title: '批量视频转换',
      content: '正在转换 ${_tasks.length} 个视频...',
    ).catchError((e) => AppLogger.w(_logTag, '启动前台服务失败：$e')));

    final count = parallelCount ?? await BatchParallelSettings.load();
    AppLogger.i(
      _logTag,
      '启动批量转换：${_tasks.length} 个任务，并行数=$count',
    );

    // 使用 Semaphore 控制并发
    _semaphore = _Semaphore(count);
    final futures = <Future>[];

    for (int i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      // 记录格式和质量信息到任务对象（详情弹窗需要）
      task.format = format;
      task.quality = quality;
      futures.add(_runTask(task, i, _semaphore!, format, quality));
    }

    // v1.6.55+ 新增：记录当前加速模式到所有任务
    final currentSpeedMode = await ConvertSpeedSettings.load();
    for (final task in _tasks) {
      task.speedMode = currentSpeedMode;
    }

    await Future.wait(futures);

    // v1.6.56+ 修复：批量转换完成后停止前台服务
    unawaited(ForegroundServiceHelper.stop()
        .catchError((e) => AppLogger.w(_logTag, '停止前台服务失败：$e')));

    // 全部任务完成后判定整体状态
    _finalizeOverallState();
  }

  /// 暂停单个任务
  ///
  /// 取消该任务的 FFmpeg 会话，保存断点信息，标记为 paused。
  /// 暂停后该任务的信号量槽位释放，其他等待中的任务可以开始。
  Future<void> pauseTask(int index) async {
    if (index < 0 || index >= _tasks.length) return;
    final task = _tasks[index];
    if (task.state != BatchTaskState.converting) {
      AppLogger.w(_logTag, '任务 $index 当前状态为 ${task.state}，无法暂停');
      return;
    }

    AppLogger.i(_logTag, '用户请求暂停任务 $index：${task.sourceName}');

    // 记录暂停请求（_runTask 的 catch 块会检查这个标志）
    _pendingPauseRequests[index] = _PauseRequest(
      encodedMs: _getActiveFfmpegForTask(index)?.lastEncodedTimeMs ?? 0,
      format: task.format ?? VideoFormat.mp4,
      quality: task.quality ?? VideoQuality.standard,
    );

    // 取消该任务的 FFmpeg 会话
    final ffmpeg = _getActiveFfmpegForTask(index);
    if (ffmpeg != null) {
      try {
        await ffmpeg.cancel();
        AppLogger.i(_logTag, '已取消任务 $index 的 FFmpeg 会话');
      } catch (e) {
        AppLogger.w(_logTag, '取消任务 $index 的 FFmpeg 会话失败：$e');
      }
    }
  }

  /// 恢复单个已暂停的任务
  ///
  /// 从断点续转，使用 FFmpegService.convertResume()。
  Future<void> resumeTask(int index) async {
    if (index < 0 || index >= _tasks.length) return;
    final task = _tasks[index];
    if (task.state != BatchTaskState.paused) {
      AppLogger.w(_logTag, '任务 $index 当前状态为 ${task.state}，无法恢复');
      return;
    }

    final resumeState = _taskResumeStates[index];
    if (resumeState == null) {
      AppLogger.w(_logTag, '任务 $index 没有恢复状态，无法续转');
      return;
    }

    AppLogger.i(_logTag, '用户请求恢复任务 $index：${task.sourceName}，从 ${resumeState.encodedTimeMs}ms 续转');

    // 获取信号量槽位
    if (_semaphore != null) {
      await _semaphore!.acquire();
    }

    FFmpegService? ffmpeg;
    try {
      ffmpeg = FFmpegService();
      _activeFfmpegServices.add(ffmpeg);
      // v1.6.56+ 修复：注册索引映射
      _taskFfmpegMap[index] = ffmpeg;

      task.state = BatchTaskState.converting;
      _emitTaskState(index, BatchTaskState.converting);

      // 读取加速模式
      await ConvertSpeedSettings.load();

      // 从断点续转
      final result = await ffmpeg.convertResume(
        input: resumeState.input,
        partialOutputPath: resumeState.partialOutputPath,
        finalOutputPath: resumeState.finalOutputPath,
        resumeFromMs: resumeState.encodedTimeMs,
        totalDurationMs: resumeState.totalDurationMs,
        format: resumeState.format,
        quality: resumeState.quality,
        onProgress: (progress) {
          task.progress = progress;
          _emitTaskProgress(index, progress);
        },
      );

      task.state = BatchTaskState.done;
      task.endTime = DateTime.now();
      task.outputSize = result.outputSize;
      task.sourceDurationMs = result.sourceDurationMs;
      _emitTaskState(index, BatchTaskState.done);

      // 清除恢复状态
      _taskResumeStates.remove(index);

      // 写入历史记录
      await _saveHistory(task, result, resumeState.format, resumeState.quality);

      // 更新整体进度
      _emitOverallState(
        BatchConvertState.running,
        completedCount,
        _tasks.length,
      );
    } catch (e, stackTrace) {
      // 检查是否是暂停请求
      if (_pendingPauseRequests.containsKey(index)) {
        final pauseReq = _pendingPauseRequests.remove(index)!;
        _saveResumeState(index, task, ffmpeg, pauseReq);
        task.state = BatchTaskState.paused;
        _emitTaskState(index, BatchTaskState.paused);
        return;
      }

      // 检查是否是取消请求
      if (_cancelledTasks.contains(index)) {
        _cancelledTasks.remove(index);
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }

      task.state = BatchTaskState.failed;
      task.errorMessage = e.toString();
      String? capturedLogs;
      if (e is FFmpegException && e.fullLogs != null) {
        capturedLogs = e.fullLogs;
      } else {
        capturedLogs = '$e\n\n堆栈：\n$stackTrace';
      }
      task.fullLogs = capturedLogs;
      task.endTime = DateTime.now();
      _emitTaskState(
        index,
        BatchTaskState.failed,
        errorMessage: e.toString(),
      );
      AppLogger.e(
        _logTag,
        '[DEBUG] 恢复任务 $index 失败：error="$e"',
      );
    } finally {
      if (_semaphore != null) {
        _semaphore!.release();
      }
      if (ffmpeg != null) {
        _activeFfmpegServices.remove(ffmpeg);
      }
      // v1.6.56+ 修复：清除索引映射
      _taskFfmpegMap.remove(index);
    }
  }

  /// 取消单个任务
  ///
  /// 取消该任务的 FFmpeg 会话，标记为 cancelled。
  Future<void> cancelTask(int index) async {
    if (index < 0 || index >= _tasks.length) return;
    final task = _tasks[index];

    if (task.state == BatchTaskState.waiting) {
      // 等待中的任务直接标记为取消
      task.state = BatchTaskState.cancelled;
      _cancelledTasks.add(index);
      _emitTaskState(index, BatchTaskState.cancelled);
      return;
    }

    if (task.state == BatchTaskState.paused) {
      // 暂停中的任务直接标记为取消
      task.state = BatchTaskState.cancelled;
      _taskResumeStates.remove(index);
      _emitTaskState(index, BatchTaskState.cancelled);
      return;
    }

    if (task.state != BatchTaskState.converting) {
      AppLogger.w(_logTag, '任务 $index 当前状态为 ${task.state}，无法取消');
      return;
    }

    AppLogger.i(_logTag, '用户请求取消任务 $index：${task.sourceName}');

    // 标记该任务为待取消
    _cancelledTasks.add(index);

    // 取消该任务的 FFmpeg 会话
    final ffmpeg = _getActiveFfmpegForTask(index);
    if (ffmpeg != null) {
      try {
        await ffmpeg.cancel();
        AppLogger.i(_logTag, '已取消任务 $index 的 FFmpeg 会话');
      } catch (e) {
        AppLogger.w(_logTag, '取消任务 $index 的 FFmpeg 会话失败：$e');
      }
    }
  }

  /// 获取指定任务对应的活跃 FFmpegService 实例
  /// v1.6.56+ 修复：使用 _taskFfmpegMap 精确查找，不再返回错误实例
  FFmpegService? _getActiveFfmpegForTask(int index) {
    return _taskFfmpegMap[index];
  }

  /// 保存任务的恢复状态
  void _saveResumeState(
    int index,
    BatchConvertTask task,
    FFmpegService? ffmpeg,
    _PauseRequest pauseReq,
  ) {
    final encodedMs = ffmpeg?.lastEncodedTimeMs ?? pauseReq.encodedMs;
    final totalMs = ffmpeg?.lastDurationMs ?? task.sourceDurationMs ?? 0;

    _taskResumeStates[index] = _TaskResumeState(
      input: task.inputPath,
      partialOutputPath: task.outputPath,
      finalOutputPath: task.outputPath,
      encodedTimeMs: encodedMs,
      totalDurationMs: totalMs,
      format: pauseReq.format,
      quality: pauseReq.quality,
      sourceName: task.sourceName,
    );

    AppLogger.i(
      _logTag,
      '已保存任务 $index 的恢复状态：encodedMs=$encodedMs, totalMs=$totalMs',
    );
  }

  /// 取消批量转换
  Future<void> cancel() async {
    if (_state != BatchConvertState.running) return;
    _cancelled = true;
    AppLogger.i(_logTag, '用户取消批量转换');

    // v1.6.56+ 修复：先复制列表再遍历，避免 await 期间
    // _runTask 的 finally 块修改 _activeFfmpegServices 导致 ConcurrentModificationError
    final servicesToCancel = List<FFmpegService>.from(_activeFfmpegServices);
    for (final ffmpeg in servicesToCancel) {
      try {
        await ffmpeg.cancel();
        AppLogger.i(_logTag, '已取消 FFmpegService 实例');
      } catch (e) {
        AppLogger.w(_logTag, '取消 FFmpegService 失败：$e');
      }
    }
    _activeFfmpegServices.clear();
    // v1.6.56+ 修复：清空索引映射
    _taskFfmpegMap.clear();

    // 取消正在进行的任务
    for (int i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.state == BatchTaskState.converting ||
          task.state == BatchTaskState.waiting ||
          task.state == BatchTaskState.paused) {
        task.state = BatchTaskState.cancelled;
        // v1.6.52+ 修复：使用数组索引 i（0-based）而非 task.index（1-based）
        // 旧版用 task.index 导致事件索引偏移或越界
        _emitTaskState(i, BatchTaskState.cancelled);
      }
    }

    // 清除暂停/恢复状态
    _pendingPauseRequests.clear();
    _taskResumeStates.clear();
    _cancelledTasks.clear();

    // v1.6.56+ 修复：取消时停止前台服务
    try {
      await ForegroundServiceHelper.stop();
    } catch (e) {
      AppLogger.w(_logTag, '停止前台服务失败：$e');
    }

    _state = BatchConvertState.cancelled;
    _emitOverallState(
      BatchConvertState.cancelled,
      completedCount,
      _tasks.length,
    );
  }

  /// 执行单个转换任务
  Future<void> _runTask(
    BatchConvertTask task,
    int index,
    _Semaphore semaphore,
    VideoFormat format,
    VideoQuality quality,
  ) async {
    if (_cancelled || _cancelledTasks.contains(index)) {
      task.state = BatchTaskState.cancelled;
      _emitTaskState(index, BatchTaskState.cancelled);
      return;
    }

    await semaphore.acquire();

    // v1.6.52+ 修复：在 try 外声明 ffmpeg 引用，finally 中需要移除
    FFmpegService? ffmpeg;

    try {
      if (_cancelled || _cancelledTasks.contains(index)) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }

      // 创建独立的 FFmpegService 实例（避免与单文件转换冲突）
      ffmpeg = FFmpegService();
      // v1.6.52+ 修复：注册到活跃列表，取消时可以调用 ffmpeg.cancel()
      _activeFfmpegServices.add(ffmpeg);
      // v1.6.56+ 修复：注册索引映射，暂停/取消时能精确找到对应实例
      _taskFfmpegMap[index] = ffmpeg;

      task.state = BatchTaskState.converting;
      task.startTime = DateTime.now();
      // 记录源文件大小
      final inputFile = File(task.inputPath);
      if (inputFile.existsSync()) {
        task.inputSize = inputFile.lengthSync();
      }
      _emitTaskState(index, BatchTaskState.converting);

      // v1.6.56+ 修复：输入文件不存在时提前返回清晰错误，
      // 避免 FFmpeg 报晦涩的原生错误
      if (!inputFile.existsSync()) {
        task.state = BatchTaskState.failed;
        task.errorMessage = '输入文件不存在：${task.inputPath}';
        task.endTime = DateTime.now();
        _emitTaskState(
          index,
          BatchTaskState.failed,
          errorMessage: task.errorMessage,
        );
        AppLogger.e(
          _logTag,
          '任务 $index 输入文件不存在：${task.inputPath}',
        );
        return;
      }

      // #region debug-point 1
      // v1.6.47+ 调试日志：记录任务输入路径和文件存在性
      final inputExists = inputFile.existsSync();
      AppLogger.i(
        _logTag,
        '[DEBUG] 任务 $index 开始执行：'
        'inputPath="${task.inputPath}", '
        'inputExists=$inputExists, '
        'outputPath="${task.outputPath}", '
        'sourceName="${task.sourceName}"',
      );
      if (!inputExists) {
        AppLogger.e(
          _logTag,
          '[DEBUG] 任务 $index 输入文件不存在！'
          'path="${task.inputPath}"',
        );
      }
      // #endregion

      // 读取加速模式（确保设置已初始化）
      await ConvertSpeedSettings.load();

      // #region debug-point 2
      AppLogger.i(
        _logTag,
        '[DEBUG] 任务 $index 调用 ffmpeg.convert：'
        'format=${format.name}, quality=${quality.name}',
      );
      // #endregion

      // 执行转换
      final result = await ffmpeg.convert(
        input: task.inputPath,
        outputPath: task.outputPath,
        format: format,
        quality: quality,
        onProgress: (progress) {
          task.progress = progress;
          _emitTaskProgress(index, progress);
        },
      );

      // #region debug-point 3
      AppLogger.i(
        _logTag,
        '[DEBUG] 任务 $index 转换成功：'
        'outputSize=${result.outputSize}, '
        'durationMs=${result.sourceDurationMs}',
      );
      // #endregion

      task.state = BatchTaskState.done;
      task.endTime = DateTime.now();
      task.outputSize = result.outputSize;
      task.sourceDurationMs = result.sourceDurationMs;
      _emitTaskState(index, BatchTaskState.done);

      // v1.6.53+ 修复：如果用户设置了 SAF 自定义保存目录，
      // 转换完成后将文件从沙盒目录复制到 SAF 自定义目录
      // 与单文件转换（ConvertCoordinator）逻辑一致
      final saveSettings = _currentSaveSettings;
      if (saveSettings != null &&
          saveSettings.mode == VideoSaveMode.customSaf &&
          saveSettings.customSafTreeUri != null) {
        try {
          final customUri = saveSettings.customSafTreeUri!;
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
          AppLogger.i(_logTag, '任务 $index 已复制到 SAF 自定义目录：$written');
        } catch (e) {
          AppLogger.e(_logTag, '任务 $index 复制到 SAF 自定义目录失败：$e');
          // 不影响 done 状态；SAF 复制失败时文件仍在沙盒目录中
        }
      }

      // 写入历史记录
      await _saveHistory(task, result, format, quality);

      // 更新整体进度
      _emitOverallState(
        BatchConvertState.running,
        completedCount,
        _tasks.length,
      );
    } catch (e, stackTrace) {
      // 检查是否是暂停请求
      if (_pendingPauseRequests.containsKey(index)) {
        final pauseReq = _pendingPauseRequests.remove(index)!;
        _saveResumeState(index, task, ffmpeg, pauseReq);
        task.state = BatchTaskState.paused;
        _emitTaskState(index, BatchTaskState.paused);
        return;
      }

      // 检查是否是单任务取消
      if (_cancelledTasks.contains(index)) {
        _cancelledTasks.remove(index);
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }

      if (_cancelled) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }
      task.state = BatchTaskState.failed;
      task.errorMessage = e.toString();
      // v1.6.51+ 新增：捕获 FFmpegException 的完整日志
      String? capturedLogs;
      if (e is FFmpegException && e.fullLogs != null) {
        capturedLogs = e.fullLogs;
      } else {
        capturedLogs = '$e\n\n堆栈：\n$stackTrace';
      }
      task.fullLogs = capturedLogs;
      task.endTime = DateTime.now();
      _emitTaskState(
        index,
        BatchTaskState.failed,
        errorMessage: e.toString(),
      );
      // #region debug-point 4
      AppLogger.e(
        _logTag,
        '[DEBUG] 任务 $index 失败：'
        'error="$e", '
        'inputPath="${task.inputPath}", '
        'stackTrace=$stackTrace',
      );
      // #endregion
    } finally {
      semaphore.release();
      // v1.6.52+ 修复：任务完成后从活跃列表移除
      if (ffmpeg != null) {
        _activeFfmpegServices.remove(ffmpeg);
      }
      // v1.6.56+ 修复：清除索引映射
      _taskFfmpegMap.remove(index);
    }
  }

  /// 写入历史记录
  Future<void> _saveHistory(
    BatchConvertTask task,
    ConvertResult result,
    VideoFormat format,
    VideoQuality quality,
  ) async {
    try {
      await ConvertHistory.add(
        ConvertHistoryEntry(
          id: DateTime.now().millisecondsSinceEpoch,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          input: task.sourceName,
          isNetwork: false,
          outputPath: task.outputPath,
          outputSize: result.outputSize,
          sourceDurationMs: result.sourceDurationMs,
          durationMs: null,
          format: format,
          quality: quality,
          status: ConvertStatus.success,
        ),
      );
    } catch (e) {
      AppLogger.w(_logTag, '写入批量转换历史记录失败：$e');
    }
  }

  /// 判定整体状态
  void _finalizeOverallState() {
    final doneCount =
        _tasks.where((t) => t.state == BatchTaskState.done).length;

    if (_cancelled) {
      _state = BatchConvertState.cancelled;
    } else if (doneCount == _tasks.length) {
      _state = BatchConvertState.done;
    } else if (doneCount == 0) {
      _state = BatchConvertState.allFailed;
    } else {
      _state = BatchConvertState.partialFailed;
    }

    _emitOverallState(_state, doneCount, _tasks.length);
  }

  void _emitTaskProgress(int index, ConvertProgress progress) {
    _events.add(BatchTaskProgressEvent(index, progress));
  }

  void _emitTaskState(
    int index,
    BatchTaskState state, {
    String? errorMessage,
  }) {
    _events.add(BatchTaskStateEvent(index, state, errorMessage: errorMessage));
  }

  void _emitOverallState(
    BatchConvertState state,
    int completed,
    int total,
  ) {
    _events.add(BatchOverallStateEvent(state, completed, total));
  }
}
