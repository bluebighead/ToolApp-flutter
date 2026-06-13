// 批量转换页面
//
// 显示所有待转换文件的竖向列表，每项显示：
//   - 文件名 + 序号
//   - 进度条
//   - 剩余时间
//   - 转换中：暂停/取消按钮
//   - 已暂停：恢复/取消按钮
//   - 完成后：打开文件按钮
//   - 点击卡片：弹出详情（转换时间、视频类型、大小、路径、开始时间）
//
// v1.6.46+ 新增：
//   - 多选删除功能
//   - 手动清空按钮
//   - 记录不自动清空，需用户手动操作
//
// v1.6.53+ 新增：
//   - 单任务暂停/恢复/取消按钮
//   - 点击卡片弹出转换详情弹窗
//
// 入口：AppBar 批量转换按钮 或 M3U8 多选后自动跳转

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../utils/app_logger.dart';
import '../utils/batch_convert_coordinator.dart';
import '../utils/convert_speed_settings.dart';
import '../utils/ffmpeg_service.dart';
import '../utils/video_save_settings.dart';

class BatchConvertPage extends StatefulWidget {
  final List<BatchConvertTask> tasks;
  final VideoFormat format;
  final VideoQuality quality;
  // v1.6.53+ 新增：视频保存设置，用于 SAF 自定义目录复制
  final VideoSaveSettingsSnapshot? saveSettings;

  const BatchConvertPage({
    super.key,
    required this.tasks,
    required this.format,
    required this.quality,
    this.saveSettings,
  });

  @override
  State<BatchConvertPage> createState() => _BatchConvertPageState();
}

class _BatchConvertPageState extends State<BatchConvertPage> {
  static const String _logTag = 'BatchConvertPage';

  late List<BatchConvertTask> _tasks;
  int _completedCount = 0;
  bool _started = false;

  // v1.6.46+ 新增：多选模式
  bool _selectMode = false;
  final Set<int> _selectedIndices = {};

  // v1.6.52+ 修复：保存事件订阅，页面销毁时取消，避免内存泄漏
  StreamSubscription<BatchConvertEvent>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _tasks = widget.tasks;
    _startConversion();
  }

  // v1.6.52+ 修复：页面销毁时取消事件订阅
  @override
  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    super.dispose();
  }

  Future<void> _startConversion() async {
    if (_started) return;
    _started = true;

    AppLogger.i(_logTag, '启动批量转换：${_tasks.length} 个任务');

    // 订阅事件
    _eventSubscription = BatchConvertCoordinator.instance.subscribe(_onEvent);

    try {
      await BatchConvertCoordinator.instance.start(
        tasks: _tasks,
        format: widget.format,
        quality: widget.quality,
        saveSettings: widget.saveSettings,
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
          _completedCount = e.completedCount;
        });
    }
  }

  // 暂停单个任务
  Future<void> _pauseTask(int index) async {
    await BatchConvertCoordinator.instance.pauseTask(index);
  }

  // 恢复单个任务
  Future<void> _resumeTask(int index) async {
    await BatchConvertCoordinator.instance.resumeTask(index);
  }

  // 取消单个任务
  Future<void> _cancelTask(int index) async {
    await BatchConvertCoordinator.instance.cancelTask(index);
  }

  Future<void> _openFile(BatchConvertTask task) async {
    if (!File(task.outputPath).existsSync()) {
      _snack('文件不存在：${task.outputPath}');
      return;
    }
    try {
      // v1.35.0+ 优先使用原生选择器，每次询问用户选择打开方式
      const storageChannel = MethodChannel('com.example.toolapp/storage');
      try {
        final opened = await storageChannel.invokeMethod<bool>(
          'openContainingFolder',
          {'filePath': task.outputPath},
        );
        if (opened == true) return;
      } catch (_) {}
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

  // v1.6.51+ 新增：显示失败任务的完整日志弹窗
  void _showErrorDialog(BatchConvertTask task) {
    if (!mounted) return;
    final logs = task.fullLogs ?? task.errorMessage ?? '无日志信息';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转换失败详情'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '文件：${task.sourceName}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '错误日志：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      logs,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: logs));
              if (!mounted) return;
              Navigator.pop(ctx);
              _snack('日志已复制到剪贴板');
            },
            child: const Text('复制日志'),
          ),
        ],
      ),
    );
  }

  // v1.6.53+ 新增：显示转换详情弹窗
  //
  // 弹窗内容：
  //   - 转换所需时间
  //   - 转换后的视频类型
  //   - 转换前后的视频大小
  //   - 转换后将保存的路径
  //   - 开始转换的时间
  void _showTaskDetailDialog(BatchConvertTask task, int index) {
    if (!mounted) return;
    final theme = Theme.of(context);

    // 计算转换所需时间
    String durationText = '计算中...';
    if (task.startTime != null) {
      final end = task.endTime ?? DateTime.now();
      final diff = end.difference(task.startTime!);
      if (diff.inHours > 0) {
        durationText = '${diff.inHours}小时${diff.inMinutes.remainder(60)}分${diff.inSeconds.remainder(60)}秒';
      } else if (diff.inMinutes > 0) {
        durationText = '${diff.inMinutes}分${diff.inSeconds.remainder(60)}秒';
      } else {
        durationText = '${diff.inSeconds}秒';
      }
    } else {
      durationText = '尚未开始';
    }

    // 格式化文件大小
    String formatSize(int? bytes) {
      if (bytes == null || bytes <= 0) return '未知';
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      if (bytes < 1024 * 1024 * 1024) {
        return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }

    // 格式化视频类型
    String formatTypeText() {
      final fmt = task.format;
      final q = task.quality;
      if (fmt == null) return '未知';
      String text = fmt.name.toUpperCase();
      if (q != null) {
        final qualityLabels = {
          VideoQuality.original: '原画',
          VideoQuality.high: '高清',
          VideoQuality.standard: '标清',
          VideoQuality.low: '流畅',
        };
        text += ' · ${qualityLabels[q] ?? q.name}';
      }
      return text;
    }

    // 格式化开始时间
    String startTimeText = '尚未开始';
    if (task.startTime != null) {
      startTimeText =
          '${task.startTime!.year}-${task.startTime!.month.toString().padLeft(2, '0')}-${task.startTime!.day.toString().padLeft(2, '0')} '
          '${task.startTime!.hour.toString().padLeft(2, '0')}:${task.startTime!.minute.toString().padLeft(2, '0')}:${task.startTime!.second.toString().padLeft(2, '0')}';
    }

    // 详情行组件
    Widget detailRow(String label, String value, {IconData? icon}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
            ],
            SizedBox(
              width: 90,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.info_outline, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '转换详情',
                style: TextStyle(fontSize: 18, color: theme.colorScheme.onSurface),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件名
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.videocam, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.sourceName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 转换所需时间
              detailRow('转换耗时', durationText, icon: Icons.schedule),
              // 转换后的视频类型
              detailRow('视频类型', formatTypeText(), icon: Icons.movie),
              // 加速模式
              detailRow('加速模式', _getSpeedModeLabel(task.speedMode), icon: Icons.speed),
              // 转换前的视频大小
              detailRow('转换前大小', formatSize(task.inputSize), icon: Icons.folder_open),
              // 转换后的视频大小
              detailRow('转换后大小', formatSize(task.outputSize), icon: Icons.folder),
              // 保存路径
              // v1.6.53+ 修复：SAF 模式下显示自定义目录路径而非沙盒路径
              detailRow('保存路径', _getDisplaySavePath(task), icon: Icons.save),
              // 开始转换时间
              detailRow('开始时间', startTimeText, icon: Icons.access_time),
              // 当前状态
              detailRow('当前状态', _getStateLabel(task.state), icon: Icons.flag),
            ],
          ),
        ),
        actions: [
          // 暂停/恢复按钮
          if (task.state == BatchTaskState.converting)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _pauseTask(index);
              },
              icon: const Icon(Icons.pause_circle_outline, size: 18),
              label: const Text('暂停转换'),
            ),
          if (task.state == BatchTaskState.paused)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeTask(index);
              },
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('恢复转换'),
            ),
          // 取消按钮（转换中或暂停中）
          if (task.state == BatchTaskState.converting ||
              task.state == BatchTaskState.paused)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _cancelTask(index);
              },
              icon: Icon(
                Icons.cancel_outlined,
                size: 18,
                color: Colors.red.shade700,
              ),
              label: Text(
                '取消转换',
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          // 关闭按钮
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // 获取状态标签文字
  String _getStateLabel(BatchTaskState state) {
    switch (state) {
      case BatchTaskState.waiting:
        return '等待中';
      case BatchTaskState.converting:
        return '转换中';
      case BatchTaskState.paused:
        return '已暂停';
      case BatchTaskState.done:
        return '已完成';
      case BatchTaskState.failed:
        return '失败';
      case BatchTaskState.cancelled:
        return '已取消';
    }
  }

  /// v1.6.53+ 新增：获取详情弹窗中显示的保存路径
  ///
  /// SAF 模式下显示自定义目录路径 + 文件名，沙盒模式下显示原始 outputPath
  String _getDisplaySavePath(BatchConvertTask task) {
    final saveSettings = widget.saveSettings;
    if (saveSettings != null &&
        saveSettings.mode == VideoSaveMode.customSaf &&
        saveSettings.customSafTreeUri != null) {
      // SAF 模式：显示自定义目录名 + 文件名
      final dirName = saveSettings.customDisplayName ?? '自定义目录';
      final fileName = task.outputPath.isNotEmpty
          ? task.outputPath.split('/').last
          : '';
      return '$dirName/$fileName';
    }
    // 沙盒模式：直接显示完整路径
    return task.outputPath;
  }

  /// v1.6.55+ 新增：获取加速模式标签
  String _getSpeedModeLabel(ConvertSpeedMode? mode) {
    switch (mode) {
      case ConvertSpeedMode.off:
        return '关闭（默认）';
      case ConvertSpeedMode.hardware:
        return '硬件编码';
      case ConvertSpeedMode.ultrafast:
        return 'ultrafast 极速';
      case null:
        return '未知';
    }
  }

  // v1.6.46+ 新增：切换多选模式
  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) {
        _selectedIndices.clear();
      }
    });
  }

  // v1.6.46+ 新增：全选/取消全选
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIndices.length == _tasks.length) {
        _selectedIndices.clear();
      } else {
        _selectedIndices.addAll(List.generate(_tasks.length, (i) => i));
      }
    });
  }

  /// v1.6.55+ 新增：判断选中的任务中是否有可暂停的任务
  bool get _canBatchPause {
    for (final idx in _selectedIndices) {
      if (idx < _tasks.length &&
          _tasks[idx].state == BatchTaskState.converting) {
        return true;
      }
    }
    return false;
  }

  /// v1.6.55+ 新增：批量暂停选中的转换中任务
  Future<void> _batchPauseSelected() async {
    final toPause = _selectedIndices
        .where((idx) => idx < _tasks.length && _tasks[idx].state == BatchTaskState.converting)
        .toList();
    if (toPause.isEmpty) {
      _snack('没有可暂停的任务');
      return;
    }
    for (final idx in toPause) {
      await _pauseTask(idx);
    }
    _snack('已暂停 ${toPause.length} 个任务');
  }

  /// v1.6.55+ 新增：判断选中的任务中是否有可取消的任务
  bool get _canBatchCancel {
    for (final idx in _selectedIndices) {
      if (idx < _tasks.length) {
        final state = _tasks[idx].state;
        if (state == BatchTaskState.converting ||
            state == BatchTaskState.paused ||
            state == BatchTaskState.waiting) {
          return true;
        }
      }
    }
    return false;
  }

  /// v1.6.55+ 新增：批量取消选中的任务
  Future<void> _batchCancelSelected() async {
    final toCancel = _selectedIndices
        .where((idx) {
          if (idx >= _tasks.length) return false;
          final state = _tasks[idx].state;
          return state == BatchTaskState.converting ||
              state == BatchTaskState.paused ||
              state == BatchTaskState.waiting;
        })
        .toList();
    if (toCancel.isEmpty) {
      _snack('没有可取消的任务');
      return;
    }
    for (final idx in toCancel) {
      await _cancelTask(idx);
    }
    _snack('已取消 ${toCancel.length} 个任务');
  }

  // v1.6.46+ 新增：删除选中项
  void _deleteSelected() {
    if (_selectedIndices.isEmpty) {
      _snack('请先选择要删除的项目');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 ${_selectedIndices.length} 个记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                // 从后往前删除，避免索引变化
                final sorted = _selectedIndices.toList()..sort((a, b) => b.compareTo(a));
                for (final index in sorted) {
                  _tasks.removeAt(index);
                }
                _selectedIndices.clear();
                _selectMode = false;
              });
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // v1.6.46+ 新增：清空所有记录
  void _clearAll() {
    if (_tasks.isEmpty) {
      _snack('没有可清空的记录');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有转换记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _tasks.clear();
                _selectedIndices.clear();
                _selectMode = false;
              });
              // v1.6.46+ 同步清空协调器中的任务
              BatchConvertCoordinator.instance.clearTasks();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selectMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('已选择'),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_selectedIndices.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              )
            : Text('批量转换（$_completedCount/${_tasks.length}）'),
        actions: [
          // v1.6.55+ 重做：多选模式下的操作按钮
          if (_selectMode) ...[
            // 全选/取消全选
            IconButton(
              tooltip: _selectedIndices.length == _tasks.length ? '取消全选' : '全选',
              icon: Icon(
                _selectedIndices.length == _tasks.length
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
              ),
              onPressed: _toggleSelectAll,
            ),
            // 批量暂停（仅当选中的任务中有可暂停的任务时可用）
            IconButton(
              tooltip: '批量暂停',
              icon: const Icon(Icons.pause_circle_outline),
              onPressed: _canBatchPause ? _batchPauseSelected : null,
            ),
            // 批量取消（仅当选中的任务中有可取消的任务时可用）
            IconButton(
              tooltip: '批量取消',
              icon: const Icon(Icons.cancel_outlined),
              onPressed: _canBatchCancel ? _batchCancelSelected : null,
            ),
            // 删除选中
            IconButton(
              tooltip: '删除选中',
              icon: const Icon(Icons.delete),
              onPressed: _selectedIndices.isEmpty ? null : _deleteSelected,
            ),
          ] else ...[
            // v1.6.55+ 移除正常模式下的"全部取消"按钮
            // 正常模式下只保留清空按钮
            // v1.6.46+ 新增：清空按钮
            IconButton(
              tooltip: '清空记录',
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clearAll,
            ),
          ],
          // 多选模式切换按钮
          IconButton(
            tooltip: _selectMode ? '退出多选' : '多选操作',
            icon: Icon(_selectMode ? Icons.close : Icons.checklist),
            onPressed: _toggleSelectMode,
          ),
        ],
      ),
      body: SafeArea(
        child: _tasks.isEmpty
            ? const Center(child: Text('暂无转换记录'))
            : ListView.builder(
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

  /// 构建单个转换任务卡片
  ///
  /// v1.6.53+ 优化：
  ///   - 转换中：显示暂停/取消按钮
  ///   - 已暂停：显示恢复/取消按钮
  ///   - 点击卡片：弹出转换详情弹窗
  Widget _buildTaskCard(BatchConvertTask task, int index) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        // 点击卡片弹出详情弹窗
        onTap: () => _showTaskDetailDialog(task, index),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：复选框 + 序号 + 文件名 + 状态标签
              Row(
                children: [
                  if (_selectMode) ...[
                    Checkbox(
                      value: _selectedIndices.contains(index),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedIndices.add(index);
                          } else {
                            _selectedIndices.remove(index);
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                  // 序号
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
              // 进度条（转换中）
              if (task.state == BatchTaskState.converting &&
                  task.progress != null) ...[
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
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                  ],
                ),
              ],
              // 已暂停时的进度条（保持暂停时的进度）
              if (task.state == BatchTaskState.paused &&
                  task.progress != null) ...[
                LinearProgressIndicator(
                  value: task.progress!.hasDuration ? task.progress!.value : 0,
                  backgroundColor: Colors.orange.shade100,
                  color: Colors.orange,
                ),
                const SizedBox(height: 4),
                Text(
                  task.progress!.hasDuration
                      ? '已暂停 · ${(task.progress!.value * 100).toInt()}%'
                      : '已暂停',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                ),
              ],
              // 转换中的操作按钮：暂停 + 取消
              if (task.state == BatchTaskState.converting) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    // 暂停按钮
                    OutlinedButton.icon(
                      onPressed: () => _pauseTask(index),
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('暂停'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 取消按钮
                    OutlinedButton.icon(
                      onPressed: () => _cancelTask(index),
                      icon: Icon(Icons.cancel_outlined, size: 16, color: Colors.red.shade700),
                      label: Text('取消', style: TextStyle(color: Colors.red.shade700)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                  ],
                ),
              ],
              // 已暂停的操作按钮：恢复 + 取消
              if (task.state == BatchTaskState.paused) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    // 恢复按钮
                    FilledButton.icon(
                      onPressed: () => _resumeTask(index),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('恢复转换'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 取消按钮
                    OutlinedButton.icon(
                      onPressed: () => _cancelTask(index),
                      icon: Icon(Icons.cancel_outlined, size: 16, color: Colors.red.shade700),
                      label: Text('取消', style: TextStyle(color: Colors.red.shade700)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                  ],
                ),
              ],
              // 错误信息（可点击查看详情）
              if (task.state == BatchTaskState.failed &&
                  task.errorMessage != null) ...[
                const SizedBox(height: 4),
                InkWell(
                  onTap: () => _showErrorDialog(task),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, size: 14, color: Colors.red),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          task.errorMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.red, fontSize: 12),
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                    ],
                  ),
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
      ),
    );
  }

  /// 构建状态标签
  Widget _buildStateBadge(BatchTaskState state) {
    final Map<BatchTaskState, ({Color color, String label})> badges = {
      BatchTaskState.waiting: (color: Colors.grey, label: '等待中'),
      BatchTaskState.converting: (color: Colors.blue, label: '转换中'),
      BatchTaskState.paused: (color: Colors.orange, label: '已暂停'),
      BatchTaskState.done: (color: Colors.green, label: '完成'),
      BatchTaskState.failed: (color: Colors.red, label: '失败'),
      BatchTaskState.cancelled: (color: Colors.grey, label: '已取消'),
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
