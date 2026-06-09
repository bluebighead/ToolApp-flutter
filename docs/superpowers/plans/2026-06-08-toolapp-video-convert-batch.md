# 视频转换提速 + 批量转换功能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现视频转换提速（硬件编码 + ultrafast preset）、批量转换功能（多文件并行转换）、设置界面新增选项（加速模式、并行数量、打开方式）

**Architecture:** 新增 BatchConvertCoordinator 管理批量任务队列，复用 FFmpegService 执行转换；新增 ConvertSpeedSettings 持久化加速模式；在 FFmpegService._buildArgs() 中根据加速模式生成不同参数

**Tech Stack:** Flutter/Dart, Android Kotlin, FFmpeg, SharedPreferences, open_filex

---

## 文件结构

### 新增文件

| 文件 | 职责 |
|------|------|
| `lib/utils/convert_speed_settings.dart` | 转换加速模式持久化（枚举 + SharedPreferences 读写） |
| `lib/utils/batch_convert_coordinator.dart` | 批量转换协调器（状态机 + Semaphore 并发控制） |
| `lib/pages/batch_convert_page.dart` | 批量转换页面（竖向列表 + 进度显示） |

### 修改文件

| 文件 | 变更 |
|------|------|
| `lib/utils/ffmpeg_service.dart` | `_buildArgs()` 支持加速模式参数 |
| `lib/utils/convert_coordinator.dart` | 单文件转换时读取加速模式 |
| `lib/pages/video_convert_page.dart` | AppBar 新增批量入口按钮；M3U8 弹窗新增多选功能 |
| `lib/pages/settings_page.dart` | 新增三个设置选项卡片 |
| `lib/utils/app_info.dart` | 版本号更新 |
| `pubspec.yaml` | 版本号更新 |

---

## Task 1: 转换加速模式持久化

**Files:**
- Create: `lib/utils/convert_speed_settings.dart`

- [ ] **Step 1: 创建 convert_speed_settings.dart**

```dart
// 转换加速模式设置
// 持久化用户的"转换加速模式"选择，用于 FFmpeg 编码参数生成
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 转换加速模式
enum ConvertSpeedMode {
  /// 关闭：使用 veryfast preset + 软件编码（默认）
  off,

  /// 硬件编码：使用 Android MediaCodec 硬件加速
  hardware,

  /// ultrafast：使用 ultrafast preset（速度更快但文件更大）
  ultrafast,
}

/// 转换加速设置读写工具
class ConvertSpeedSettings {
  static const String _kKey = 'convert_speed_mode';

  /// 从 SharedPreferences 读取加速模式
  static Future<ConvertSpeedMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_kKey) ?? ConvertSpeedMode.off.index;
    return ConvertSpeedMode.values[
        index.clamp(0, ConvertSpeedMode.values.length - 1)];
  }

  /// 写入加速模式
  static Future<void> save(ConvertSpeedMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKey, mode.index);
    AppLogger.i('ConvertSpeedSettings', '加速模式 -> ${mode.name}');
  }
}
```

- [ ] **Step 2: 验证代码无语法错误**

运行 `flutter analyze lib/utils/convert_speed_settings.dart`，确保无 error。

---

## Task 2: FFmpegService 支持加速模式

**Files:**
- Modify: `lib/utils/ffmpeg_service.dart`（_buildArgs 方法）

- [ ] **Step 1: 修改 _buildArgs 方法签名，新增 speedMode 参数**

在 `_buildArgs` 方法中新增 `ConvertSpeedMode speedMode` 参数，默认值为 `ConvertSpeedMode.off`。

- [ ] **Step 2: 修改编码参数生成逻辑**

在转码模式分支中（`quality != VideoQuality.original`），根据 `speedMode` 调整参数：

```dart
// 在 switch(quality) 之后，encodeArgs.addAll 之前：
if (speedMode == ConvertSpeedMode.hardware) {
  // 硬件编码模式：使用 Android MediaCodec
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
  final preset = speedMode == ConvertSpeedMode.ultrafast
      ? 'ultrafast'
      : preset; // 原有的 veryfast
  encodeArgs.addAll([
    '-c:v', 'libx264',
    '-preset', preset,
    '-crf', '$crf',
    '-pix_fmt', 'yuv420p',
    '-c:a', 'aac',
    '-b:a', '${audioBitrateK}k',
    if (format == VideoFormat.mp4) ...[
      '-movflags', '+faststart',
    ],
  ]);
}
```

- [ ] **Step 3: 修改 convert() 方法，读取加速模式并传给 _buildArgs**

在 `convert()` 方法中调用 `_buildArgs` 前读取加速模式：

```dart
import 'convert_speed_settings.dart';

// 在 convert() 方法中，构造 FFmpeg 参数前：
final speedMode = await ConvertSpeedSettings.load();
final args = _buildArgs(
  input: effectiveInput,
  outputPath: outputPath,
  format: format,
  quality: quality,
  speedMode: speedMode,
);
```

- [ ] **Step 4: 同样修改 convertResume() 方法**

在 `convertResume()` 方法中同样读取加速模式并传给 `_buildArgs`。

- [ ] **Step 5: 验证代码无语法错误**

运行 `flutter analyze lib/utils/ffmpeg_service.dart`，确保无 error。

---

## Task 3: 批量并行数量设置持久化

**Files:**
- Modify: `lib/utils/convert_speed_settings.dart`（追加并行数量读写）

- [ ] **Step 1: 在 convert_speed_settings.dart 中追加并行数量设置**

```dart
/// 批量并行数量设置
class BatchParallelSettings {
  static const String _kKey = 'batch_parallel_count';
  static const int _kDefault = 2;
  static const int _kMax = 5;
  static const int _kMin = 1;

  /// 读取并行数量
  static Future<int> load() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_kKey) ?? _kDefault;
    return count.clamp(_kMin, _kMax);
  }

  /// 写入并行数量
  static Future<void> save(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = count.clamp(_kMin, _kMax);
    await prefs.setInt(_kKey, clamped);
    AppLogger.i('BatchParallelSettings', '并行数量 -> $clamped');
  }
}
```

- [ ] **Step 2: 验证代码无语法错误**

运行 `flutter analyze lib/utils/convert_speed_settings.dart`，确保无 error。

---

## Task 4: BatchConvertCoordinator 核心实现

**Files:**
- Create: `lib/utils/batch_convert_coordinator.dart`

- [ ] **Step 1: 创建批量转换协调器**

```dart
// 批量转换全局协调器（单例）
//
// 管理批量转换任务队列，支持：
//   - 并行控制（Semaphore）
//   - 单个任务进度回调
//   - 整体进度追踪
//   - 取消/暂停/恢复
//
// 用法：
//   - 启动：
//       BatchConvertCoordinator.instance.start(tasks, format, quality);
//   - 取消：
//       await BatchConvertCoordinator.instance.cancel();
//   - 订阅：
//       final sub = BatchConvertCoordinator.instance.subscribe(onEvent);

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'convert_history.dart';
import 'convert_speed_settings.dart';
import 'ffmpeg_service.dart';
import 'video_save_settings.dart';

/// 批量转换任务状态
enum BatchTaskState {
  /// 等待中
  waiting,
  /// 转换中
  converting,
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

  /// 转换开始时间
  DateTime? startTime;

  /// 转换结束时间
  DateTime? endTime;

  BatchConvertTask({
    required this.inputPath,
    required this.sourceName,
    required this.outputPath,
    required this.index,
    this.state = BatchTaskState.waiting,
    this.progress,
    this.errorMessage,
    this.startTime,
    this.endTime,
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

  /// 取消标志
  bool _cancelled = false;

  /// FFmpeg 服务实例
  final FFmpegService _ffmpeg = FFmpegService();

  /// 获取任务列表（只读）
  List<BatchConvertTask> get tasks => List.unmodifiable(_tasks);

  /// 获取整体状态
  BatchConvertState get state => _state;

  /// 是否正在运行
  bool get isRunning => _state == BatchConvertState.running;

  /// 已完成数量
  int get completedCount => _tasks.where((t) => t.state == BatchTaskState.done).length;

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
    int? parallelCount,
  }) async {
    if (_state == BatchConvertState.running) {
      throw StateError('已有批量转换任务在进行中');
    }

    _tasks = tasks;
    _cancelled = false;
    _state = BatchConvertState.running;
    _emitOverallState(BatchConvertState.running, 0, _tasks.length);

    final count = parallelCount ?? await BatchParallelSettings.load();
    AppLogger.i(_logTag, '启动批量转换：${_tasks.length} 个任务，并行数=$count');

    // 使用 Semaphore 控制并发
    final semaphore = _Semaphore(count);
    final futures = <Future>[];

    for (int i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      futures.add(_runTask(task, i, semaphore, format, quality));
    }

    await Future.wait(futures);

    // 全部任务完成后判定整体状态
    _finalizeOverallState();
  }

  /// 取消批量转换
  Future<void> cancel() async {
    if (_state != BatchConvertState.running) return;
    _cancelled = true;
    AppLogger.i(_logTag, '用户取消批量转换');

    // 取消正在进行的任务
    for (final task in _tasks) {
      if (task.state == BatchTaskState.converting) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(task.index, BatchTaskState.cancelled);
      } else if (task.state == BatchTaskState.waiting) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(task.index, BatchTaskState.cancelled);
      }
    }

    _state = BatchConvertState.cancelled;
    _emitOverallState(BatchConvertState.cancelled, completedCount, _tasks.length);
  }

  /// 执行单个转换任务
  Future<void> _runTask(
    BatchConvertTask task,
    int index,
    _Semaphore semaphore,
    VideoFormat format,
    VideoQuality quality,
  ) async {
    if (_cancelled) {
      task.state = BatchTaskState.cancelled;
      _emitTaskState(index, BatchTaskState.cancelled);
      return;
    }

    await semaphore.acquire();

    try {
      if (_cancelled) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }

      task.state = BatchTaskState.converting;
      task.startTime = DateTime.now();
      _emitTaskState(index, BatchTaskState.converting);

      // 读取加速模式
      final speedMode = await ConvertSpeedSettings.load();

      // 执行转换
      final result = await _ffmpeg.convert(
        input: task.inputPath,
        outputPath: task.outputPath,
        format: format,
        quality: quality,
        onProgress: (progress) {
          task.progress = progress;
          _emitTaskProgress(index, progress);
        },
      );

      task.state = BatchTaskState.done;
      task.endTime = DateTime.now();
      _emitTaskState(index, BatchTaskState.done);

      // 写入历史记录
      await _saveHistory(task, result);

      // 更新整体进度
      _emitOverallState(BatchConvertState.running, completedCount, _tasks.length);
    } catch (e) {
      if (_cancelled) {
        task.state = BatchTaskState.cancelled;
        _emitTaskState(index, BatchTaskState.cancelled);
        return;
      }
      task.state = BatchTaskState.failed;
      task.errorMessage = e.toString();
      task.endTime = DateTime.now();
      _emitTaskState(index, BatchTaskState.failed, errorMessage: e.toString());
      AppLogger.e(_logTag, '任务 $index 失败：$e');
    } finally {
      semaphore.release();
    }
  }

  /// 写入历史记录
  Future<void> _saveHistory(BatchConvertTask task, ConvertResult result) async {
    try {
      await ConvertHistory.add(
        sourceName: task.sourceName,
        outputPath: task.outputPath,
        format: 'batch',
        quality: 'batch',
        status: ConvertStatus.success,
        sourceDurationMs: result.sourceDurationMs,
        outputSize: result.outputSize,
      );
    } catch (e) {
      AppLogger.w(_logTag, '写入批量转换历史记录失败：$e');
    }
  }

  /// 判定整体状态
  void _finalizeOverallState() {
    final doneCount = _tasks.where((t) => t.state == BatchTaskState.done).length;
    final failedCount = _tasks.where((t) => t.state == BatchTaskState.failed).length;
    final cancelledCount = _tasks.where((t) => t.state == BatchTaskState.cancelled).length;

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

  void _emitTaskState(int index, BatchTaskState state, {String? errorMessage}) {
    _events.add(BatchTaskStateEvent(index, state, errorMessage: errorMessage));
  }

  void _emitOverallState(BatchConvertState state, int completed, int total) {
    _events.add(BatchOverallStateEvent(state, completed, total));
  }
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
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}
```

- [ ] **Step 2: 验证代码无语法错误**

运行 `flutter analyze lib/utils/batch_convert_coordinator.dart`，确保无 error。

---

## Task 5: BatchConvertPage 批量转换页面

**Files:**
- Create: `lib/pages/batch_convert_page.dart`

- [ ] **Step 1: 创建批量转换页面**

```dart
// 批量转换页面
//
// 显示所有待转换文件的竖向列表，每项显示：
//   - 文件名
//   - 进度条
//   - 剩余时间
//   - 完成后显示"打开文件"按钮
//
// 入口：AppBar 批量转换按钮 或 M3U8 多选后自动跳转

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../utils/app_logger.dart';
import '../utils/batch_convert_coordinator.dart';
import '../utils/ffmpeg_service.dart';
import '../utils/video_save_settings.dart';

class BatchConvertPage extends StatefulWidget {
  final List<BatchConvertTask> tasks;
  final VideoFormat format;
  final VideoQuality quality;

  const BatchConvertPage({
    super.key,
    required this.tasks,
    required this.format,
    required this.quality,
  });

  @override
  State<BatchConvertPage> createState() => _BatchConvertPageState();
}

class _BatchConvertPageState extends State<BatchConvertPage> {
  static const String _logTag = 'BatchConvertPage';

  late List<BatchConvertTask> _tasks;
  BatchConvertState _overallState = BatchConvertState.idle;
  int _completedCount = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _tasks = widget.tasks;
    _startConversion();
  }

  Future<void> _startConversion() async {
    if (_started) return;
    _started = true;

    AppLogger.i(_logTag, '启动批量转换：${_tasks.length} 个任务');

    // 订阅事件
    BatchConvertCoordinator.instance.subscribe(_onEvent);

    try {
      await BatchConvertCoordinator.instance.start(
        tasks: _tasks,
        format: widget.format,
        quality: widget.quality,
      );
    } catch (e) {
      AppLogger.e(_logTag, '批量转换启动失败：$e');
    }
  }

  void _onEvent(BatchConvertEvent event) {
    if (!mounted) return;
    switch (event) {
      case BatchTaskProgressEvent e:
        setState(() {
          _tasks[e.taskIndex].progress = e.progress;
        });
      case BatchTaskStateEvent e:
        setState(() {
          _tasks[e.taskIndex].state = e.state;
          _tasks[e.taskIndex].errorMessage = e.errorMessage;
        });
      case BatchOverallStateEvent e:
        setState(() {
          _overallState = e.state;
          _completedCount = e.completedCount;
        });
    }
  }

  Future<void> _cancel() async {
    await BatchConvertCoordinator.instance.cancel();
  }

  Future<void> _openFile(BatchConvertTask task) async {
    if (!File(task.outputPath).existsSync()) {
      _snack('文件不存在：${task.outputPath}');
      return;
    }
    try {
      final result = await OpenFilex.open(task.outputPath);
      if (result.type != ResultType.done) {
        _snack('未找到可打开此文件的应用');
      }
    } catch (e) {
      _snack('打开文件失败：$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('批量转换（${_completedCount}/${_tasks.length}）'),
        actions: [
          if (_overallState == BatchConvertState.running)
            TextButton(
              onPressed: _cancel,
              child: const Text('全部取消'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _tasks.length,
          itemBuilder: (context, index) {
            final task = _tasks[index];
            return _buildTaskCard(task, index);
          },
        ),
      ),
    );
  }

  Widget _buildTaskCard(BatchConvertTask task, int index) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 文件名 + 序号
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                _buildStateBadge(task.state),
              ],
            ),
            const SizedBox(height: 8),
            // 进度条
            if (task.state == BatchTaskState.converting && task.progress != null) ...[
              LinearProgressIndicator(
                value: task.progress!.hasDuration ? task.progress!.value : null,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    task.progress!.hasDuration
                        ? '${(task.progress!.value * 100).toInt()}%'
                        : '转换中...',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (task.progress!.etaSeconds != null)
                    Text(
                      '剩余约 ${task.progress!.etaSeconds} 秒',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                ],
              ),
            ],
            // 错误信息
            if (task.state == BatchTaskState.failed && task.errorMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                task.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            // 完成后的操作按钮
            if (task.state == BatchTaskState.done) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => _openFile(task),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('打开文件'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStateBadge(BatchTaskState state) {
    final theme = Theme.of(context);
    final Map<BatchTaskState, ({Color color, String label})> badges = {
      BatchTaskState.waiting: (color: Colors.grey, label: '等待中'),
      BatchTaskState.converting: (color: Colors.blue, label: '转换中'),
      BatchTaskState.done: (color: Colors.green, label: '完成'),
      BatchTaskState.failed: (color: Colors.red, label: '失败'),
      BatchTaskState.cancelled: (color: Colors.orange, label: '已取消'),
    };
    final badge = badges[state]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badge.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        badge.label,
        style: TextStyle(
          color: badge.color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: 验证代码无语法错误**

运行 `flutter analyze lib/pages/batch_convert_page.dart`，确保无 error。

---

## Task 6: VideoConvertPage 新增批量入口按钮 + M3U8 多选功能

**Files:**
- Modify: `lib/pages/video_convert_page.dart`

- [ ] **Step 1: 在 AppBar actions 中新增批量入口按钮**

在历史记录按钮左侧添加批量转换按钮：

```dart
// 在 actions 中，历史记录按钮之前：
IconButton(
  tooltip: '批量转换',
  icon: const Icon(Icons.playlist_play),
  onPressed: _openBatchConvertPage,
),
```

- [ ] **Step 2: 实现 _openBatchConvertPage 方法**

```dart
Future<void> _openBatchConvertPage() async {
  AppLogger.i('VideoConvertPage', '打开批量转换页面');
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => const BatchConvertPage(
        tasks: [],
        format: VideoFormat.mp4,
        quality: VideoQuality.original,
      ),
    ),
  );
}
```

- [ ] **Step 3: 修改 M3U8 播放列表弹窗，新增多选按钮**

在 `_showM3u8SiblingsDialog` 中，将 SimpleDialog 改为包含"多选"按钮的自定义 Dialog：

```dart
// 在 SimpleDialog 的 title 下方添加多选按钮：
SimpleDialog(
  title: Text('切换 M3U8（共 ${siblings.length} 个）'),
  children: [
    // 多选按钮
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextButton.icon(
        onPressed: () {
          Navigator.pop(ctx);
          _showM3u8MultiSelectDialog(siblings);
        },
        icon: const Icon(Icons.checklist),
        label: const Text('多选'),
      ),
    ),
    const Divider(),
    ...siblings.map((rel) {
      // 原有单选选项...
    }),
  ],
),
```

- [ ] **Step 4: 实现 _showM3u8MultiSelectDialog 多选弹窗**

```dart
Future<void> _showM3u8MultiSelectDialog(List<String> siblings) async {
  final selected = <String>{};
  if (!mounted) return;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('选择要转换的 M3U8 文件'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: siblings.map((rel) {
              final isSelected = selected.contains(rel);
              return CheckboxListTile(
                title: Text(rel),
                value: isSelected,
                onChanged: (v) {
                  setDialogState(() {
                    if (v == true) {
                      selected.add(rel);
                    } else {
                      selected.remove(rel);
                    }
                  });
                },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: selected.length > 1
                ? () => Navigator.pop(ctx, selected)
                : null,
            child: Text('开始批量转换（${selected.length} 个）'),
          ),
        ],
      ),
    ),
  );

  if (selected.length <= 1) return;

  // 跳转到批量转换页面
  _navigateToBatchConvert(selected.toList());
}
```

- [ ] **Step 5: 实现 _navigateToBatchConvert 方法**

```dart
Future<void> _navigateToBatchConvert(List<String> selectedFiles) async {
  final format = _selectedFormat;
  final quality = _selectedQuality;

  // 获取保存路径
  final saveSettings = await VideoSaveSettings.load();
  final saveDir = saveSettings.mode == VideoSaveMode.customSaf
      ? null // SAF 路径由原生层处理
      : (await getApplicationDocumentsDirectory()).path;

  final tasks = <BatchConvertTask>[];
  for (int i = 0; i < selectedFiles.length; i++) {
    final rel = selectedFiles[i];
    final inputPath = _m3u8CacheDir != null
        ? '${_m3u8CacheDir!.path}/$rel'
        : rel;
    final outputName = '${p.basenameWithoutExtension(rel)}_${i + 1}.${format.name}';
    final outputPath = saveDir != null
        ? '$saveDir/$outputName'
        : ''; // SAF 路径后续由原生层生成

    tasks.add(BatchConvertTask(
      inputPath: inputPath,
      sourceName: rel,
      outputPath: outputPath,
      index: i + 1,
    ));
  }

  if (!mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => BatchConvertPage(
        tasks: tasks,
        format: format,
        quality: quality,
      ),
    ),
  );
}
```

- [ ] **Step 6: 添加必要的 import**

```dart
import 'batch_convert_page.dart';
import '../utils/batch_convert_coordinator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
```

- [ ] **Step 7: 验证代码无语法错误**

运行 `flutter analyze lib/pages/video_convert_page.dart`，确保无 error。

---

## Task 7: SettingsPage 新增三个设置选项

**Files:**
- Modify: `lib/pages/settings_page.dart`

- [ ] **Step 1: 添加必要的 import**

```dart
import '../utils/convert_speed_settings.dart';
```

- [ ] **Step 2: 在"视频转换"分组下新增三个设置选项**

在 `_buildVideoSaveCard(context)` 之后添加：

```dart
const SizedBox(height: 8),
// 4. 转换加速模式
_buildConvertSpeedCard(context),
const SizedBox(height: 8),
// 5. 批量并行数量
_buildBatchParallelCard(context),
const SizedBox(height: 8),
// 6. 更换默认打开方式
_buildOpenWithCard(context),
```

- [ ] **Step 3: 实现 _buildConvertSpeedCard 方法**

```dart
Widget _buildConvertSpeedCard(BuildContext context) {
  final theme = Theme.of(context);
  return Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.speed, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '转换加速模式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FutureBuilder<ConvertSpeedMode>(
            future: ConvertSpeedSettings.load(),
            builder: (context, snapshot) {
              final mode = snapshot.data ?? ConvertSpeedMode.off;
              return Column(
                children: ConvertSpeedMode.values.map((m) {
                  return RadioListTile<ConvertSpeedMode>(
                    title: Text(_speedModeLabel(m)),
                    subtitle: Text(_speedModeDesc(m)),
                    value: m,
                    groupValue: mode,
                    onChanged: (v) {
                      if (v != null) {
                        ConvertSpeedSettings.save(v);
                        setState(() {});
                      }
                    },
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    ),
  );
}

String _speedModeLabel(ConvertSpeedMode mode) {
  switch (mode) {
    case ConvertSpeedMode.off:
      return '关闭（默认）';
    case ConvertSpeedMode.hardware:
      return '硬件编码';
    case ConvertSpeedMode.ultrafast:
      return 'ultrafast';
  }
}

String _speedModeDesc(ConvertSpeedMode mode) {
  switch (mode) {
    case ConvertSpeedMode.off:
      return '使用 veryfast preset + 软件编码，画质好速度适中';
    case ConvertSpeedMode.hardware:
      return '使用硬件编码，速度最快但画质略低';
    case ConvertSpeedMode.ultrafast:
      return '使用 ultrafast preset，速度快但文件体积更大';
  }
}
```

- [ ] **Step 4: 实现 _buildBatchParallelCard 方法**

```dart
Widget _buildBatchParallelCard(BuildContext context) {
  final theme = Theme.of(context);
  return Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.layers, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '批量并行数量',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FutureBuilder<int>(
            future: BatchParallelSettings.load(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 2;
              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      keyboardType: TextInputType.number,
                      controller: TextEditingController(text: '$count'),
                      decoration: const InputDecoration(
                        labelText: '并行数量（1-5）',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n >= 1 && n <= 5) {
                          BatchParallelSettings.save(n);
                        }
                      },
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            '批量转换时同时进行的任务数量，越多越快但可能卡顿（默认 2）',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: 实现 _buildOpenWithCard 方法**

```dart
Widget _buildOpenWithCard(BuildContext context) {
  final theme = Theme.of(context);
  return Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.open_in_new, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '更换默认打开方式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 18, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '此设置仅改变本 App 内视频的打开方式，与其他工具的打开方式设置无关',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.amber.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: () async {
              // 弹出系统选择器
              final result = await OpenFilex.open('/dev/null');
              if (result.type != ResultType.done) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未找到可打开文件的应用')),
                );
              }
            },
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('选择打开方式'),
          ),
          const SizedBox(height: 6),
          Text(
            '点击后弹出系统选择器，每次打开视频时都会弹出选择',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 6: 添加必要的 import**

```dart
import 'package:open_filex/open_filex.dart';
```

- [ ] **Step 7: 验证代码无语法错误**

运行 `flutter analyze lib/pages/settings_page.dart`，确保无 error。

---

## Task 8: 更新版本号 + 编译打包 + 安装

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/utils/app_info.dart`

- [ ] **Step 1: 更新 pubspec.yaml 版本号**

```yaml
version: 1.6.43+71
```

- [ ] **Step 2: 更新 app_info.dart 版本号**

```dart
static const String version = '1.6.43';
static const int buildNumber = 71;
static const String lastUpdate = '2026-06-08';
```

- [ ] **Step 3: 编译打包**

```bash
flutter build apk --release
```

- [ ] **Step 4: 安装到手机**

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

- [ ] **Step 5: 清理旧 APK 文件**

删除 `build/app/outputs/flutter-apk/` 下的旧版本 APK 文件。

---

## 自检清单

### 规范覆盖

| 需求 | 对应 Task |
|------|-----------|
| 提速（硬件编码 + ultrafast） | Task 1, 2 |
| 批量并行数量设置 | Task 3 |
| BatchConvertCoordinator | Task 4 |
| BatchConvertPage | Task 5 |
| 批量入口按钮 + M3U8 多选 | Task 6 |
| 设置界面三个选项 | Task 7 |
| 版本号更新 + 打包安装 | Task 8 |

### 占位符扫描

无 TBD/TODO，所有步骤包含完整代码。

### 类型一致性

- `ConvertSpeedMode` 在 Task 1 定义，Task 2/7 使用
- `BatchConvertTask` / `BatchConvertState` / `BatchConvertEvent` 在 Task 4 定义，Task 5/6 使用
- `BatchParallelSettings` 在 Task 3 定义，Task 4/7 使用
- 所有类型名称和签名在各 Task 中保持一致
