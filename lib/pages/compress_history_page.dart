// 压缩历史记录页面
// 展示所有压缩任务的记录，支持点击查看详情、多选删除
import 'package:flutter/material.dart';

import '../models/compress_history.dart';
import '../services/compress_history_service.dart';
import '../utils/app_logger.dart';

class CompressHistoryPage extends StatefulWidget {
  const CompressHistoryPage({super.key});

  @override
  State<CompressHistoryPage> createState() => _CompressHistoryPageState();
}

class _CompressHistoryPageState extends State<CompressHistoryPage> {
  // 历史记录列表
  List<CompressHistory> _records = [];
  // 是否处于多选模式
  bool _isSelectMode = false;
  // 选中的记录 ID 集合
  final Set<String> _selectedIds = {};
  // 是否正在加载
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  // 构建顶部导航栏
  PreferredSizeWidget _buildAppBar() {
    if (_isSelectMode) {
      // 多选模式下的 AppBar
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelectMode,
        ),
        title: Text('已选 ${_selectedIds.length} 项'),
        actions: [
          TextButton(
            onPressed: _selectedIds.length == _records.length
                ? _deselectAll
                : _selectAll,
            child: Text(
              _selectedIds.length == _records.length ? '取消全选' : '全选',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _selectedIds.isEmpty ? null : _confirmDelete,
          ),
        ],
      );
    }
    // 普通模式下的 AppBar
    return AppBar(
      title: const Text('压缩历史'),
      actions: [
        if (_records.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空记录',
            onPressed: _confirmClearAll,
          ),
      ],
    );
  }

  // 构建主体内容
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('暂无压缩记录',
                style: TextStyle(
                    fontSize: 16, color: Colors.grey.shade500)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _records.length,
        itemBuilder: (context, index) => _buildRecordCard(_records[index]),
      ),
    );
  }

  // 构建单条记录卡片
  Widget _buildRecordCard(CompressHistory record) {
    final isSelected = _selectedIds.contains(record.id);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: InkWell(
        onTap: () {
          if (_isSelectMode) {
            _toggleSelect(record.id);
          } else {
            _showDetailDialog(record);
          }
        },
        onLongPress: () {
          if (!_isSelectMode) {
            _enterSelectMode(record.id);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 多选复选框
              if (_isSelectMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    isSelected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                ),
              // 类型图标
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _getTypeColor(record.type)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _getTypeIcon(record.type),
                  color: _getTypeColor(record.type),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              // 文件信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.inputFileName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          record.typeLabel,
                          style: TextStyle(
                            fontSize: 11,
                            color: _getTypeColor(record.type),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatFileSize(record.originalSize),
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600),
                        ),
                        const SizedBox(width: 4),
                        Text('→', style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade400)),
                        const SizedBox(width: 4),
                        Text(
                          _formatFileSize(record.compressedSize),
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.green.shade600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 压缩率
              Text(
                '-${record.compressionRatio.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 显示详情对话框
  void _showDetailDialog(CompressHistory record) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(_getTypeIcon(record.type),
                color: _getTypeColor(record.type), size: 24),
            const SizedBox(width: 8),
            const Text('压缩详情', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('压缩类型', record.typeLabel),
              _detailRow('压缩时间',
                  _formatDateTime(record.timestamp)),
              _detailRow('源文件名', record.inputFileName),
              _detailRow('输出文件名', record.outputFileName),
              const Divider(),
              _detailRow('原始大小', _formatFileSize(record.originalSize)),
              _detailRow('压缩后大小', _formatFileSize(record.compressedSize)),
              _detailRow('压缩率',
                  '-${record.compressionRatio.toStringAsFixed(1)}%'),
              _detailRow('耗时', _formatDuration(record.durationMs)),
              const Divider(),
              _detailRow('预设模式', record.preset),
              _detailRow('参数', record.params),
              const SizedBox(height: 8),
              // 输出路径（完整显示）
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('输出路径',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    SelectableText(record.outputPath,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // 详情对话框中的一行
  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // 确认删除选中记录
  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除选中的 ${_selectedIds.length} 条记录吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await CompressHistoryService.delete(_selectedIds.toList());
      _exitSelectMode();
      await _loadRecords();
    }
  }

  // 确认清空所有记录
  Future<void> _confirmClearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定清空所有压缩记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('清空', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await CompressHistoryService.clear();
      await _loadRecords();
    }
  }

  // 多选操作
  void _enterSelectMode(String id) {
    setState(() {
      _isSelectMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _isSelectMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIds.addAll(_records.map((r) => r.id));
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedIds.clear();
    });
  }

  // 加载记录
  Future<void> _loadRecords() async {
    try {
      final records = await CompressHistoryService.loadAll();
      if (mounted) {
        setState(() {
          _records = records;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.e('CompressHistoryPage', '加载历史记录失败：$e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 格式化日期时间
  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} ${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  // 工具方法
  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      case 'image':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'video':
        return Colors.blue;
      case 'audio':
        return Colors.orange;
      case 'image':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}秒';
    final minutes = seconds / 60;
    final secs = seconds % 60;
    return '${minutes.toStringAsFixed(0)}分${secs.toStringAsFixed(0)}秒';
  }
}
