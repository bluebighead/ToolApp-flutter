// 心率历史记录页面
// 展示所有心率测量会话记录，支持：
//   - 点击查看详情（最高/最低/平均心率、测量时间段）
//   - 多选模式：批量删除
//   - 全选 / 取消多选
import 'package:flutter/material.dart';

import '../utils/app_logger.dart';
import '../utils/heart_rate_history.dart';

class HeartRateHistoryPage extends StatefulWidget {
  const HeartRateHistoryPage({super.key});

  @override
  State<HeartRateHistoryPage> createState() => _HeartRateHistoryPageState();
}

class _HeartRateHistoryPageState extends State<HeartRateHistoryPage> {
  static const String _logTag = 'HeartRateHistoryPage';

  /// 历史记录列表
  List<HeartRateRecord> _records = [];

  /// 是否正在加载
  bool _loading = true;

  /// 是否处于多选模式
  bool _isMultiSelectMode = false;

  /// 多选模式下已选中的记录 ID 集合
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 加载历史记录
  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await HeartRateHistory.loadAll();
    if (!mounted) return;
    setState(() {
      _records = list;
      _loading = false;
    });
  }

  /// 进入多选模式
  void _enterMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = true;
      _selectedIds.clear();
    });
  }

  /// 退出多选模式
  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedIds.clear();
    });
  }

  /// 全选 / 取消全选
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _records.length) {
        // 已全选，取消全选
        _selectedIds.clear();
      } else {
        // 未全选，全选
        _selectedIds.clear();
        _selectedIds.addAll(_records.map((r) => r.id));
      }
    });
  }

  /// 切换某条记录的选中状态
  void _toggleSelect(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        // 如果取消选中后没有选中项了，退出多选模式
        if (_selectedIds.isEmpty) {
          _isMultiSelectMode = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// 批量删除选中记录
  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 $count 条记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await HeartRateHistory.removeBatch(_selectedIds.toList());
    AppLogger.i(_logTag, '批量删除 $count 条心率历史');
    _exitMultiSelectMode();
    await _load();
  }

  /// 显示记录详情
  void _showDetail(HeartRateRecord record) {
    // 根据平均心率确定颜色
    Color getBpmColor(int bpm) {
      if (bpm < 50) return Colors.blue;
      if (bpm <= 100) return Colors.green;
      if (bpm <= 140) return Colors.orange;
      return Colors.red;
    }

    final avgColor = getBpmColor(record.avgBpm);
    final startDt = DateTime.fromMillisecondsSinceEpoch(record.startTimeMs);
    final endDt = DateTime.fromMillisecondsSinceEpoch(record.endTimeMs);

    // 格式化时间
    String formatTime(DateTime dt) {
      return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部拖拽指示条
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Row(
              children: [
                Icon(Icons.favorite, color: avgColor, size: 28),
                const SizedBox(width: 8),
                Text(
                  '测量详情',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // 详情卡片
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: avgColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  // 最高心率
                  _buildDetailRow(
                    icon: Icons.arrow_upward,
                    label: '最高心率',
                    value: '${record.maxBpm} BPM',
                    color: getBpmColor(record.maxBpm),
                  ),
                  const Divider(height: 24),
                  // 最低心率
                  _buildDetailRow(
                    icon: Icons.arrow_downward,
                    label: '最低心率',
                    value: '${record.minBpm} BPM',
                    color: getBpmColor(record.minBpm),
                  ),
                  const Divider(height: 24),
                  // 平均心率
                  _buildDetailRow(
                    icon: Icons.favorite,
                    label: '平均心率',
                    value: '${record.avgBpm} BPM',
                    color: avgColor,
                  ),
                  const Divider(height: 24),
                  // 测量时间段
                  _buildDetailRow(
                    icon: Icons.schedule,
                    label: '测量时间段',
                    value: '${formatTime(startDt)}\n~ ${formatTime(endDt)}',
                    color: Colors.grey.shade700,
                  ),
                  const Divider(height: 24),
                  // 测量时长
                  _buildDetailRow(
                    icon: Icons.timer,
                    label: '测量时长',
                    value: record.durationText,
                    color: Colors.grey.shade700,
                  ),
                  const Divider(height: 24),
                  // 采样点数
                  _buildDetailRow(
                    icon: Icons.data_usage,
                    label: '采样点数',
                    value: '${record.samples} 个',
                    color: Colors.grey.shade700,
                  ),
                  const Divider(height: 24),
                  // 连接方式
                  _buildDetailRow(
                    icon: record.connectionMode == HeartRateConnectionMode.ble
                        ? Icons.bluetooth
                        : Icons.wifi,
                    label: '连接方式',
                    value: record.connectionModeText,
                    color: Colors.grey.shade700,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// 构建详情行
  Widget _buildDetailRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: color,
          ),
          textAlign: TextAlign.right,
        ),
      ],
    );
  }

  /// 格式化日期时间（用于列表卡片）
  String _formatDateTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    final hm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (dt.year == now.year) {
      return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hm';
    }
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hm';
  }

  /// 根据心率值返回颜色
  Color _getBpmColor(int bpm) {
    if (bpm < 50) return Colors.blue;
    if (bpm <= 100) return Colors.green;
    if (bpm <= 140) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isMultiSelectMode
            ? '已选择 ${_selectedIds.length} 项'
            : '心率历史记录'),
        actions: [
          if (!_isMultiSelectMode) ...[
            // 多选按钮
            if (_records.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.checklist),
                tooltip: '多选',
                onPressed: _enterMultiSelectMode,
              ),
          ] else ...[
            // 全选/取消全选按钮
            IconButton(
              icon: Icon(_selectedIds.length == _records.length
                  ? Icons.deselect
                  : Icons.select_all),
              tooltip: _selectedIds.length == _records.length ? '取消全选' : '全选',
              onPressed: _toggleSelectAll,
            ),
            // 取消多选按钮
              IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消多选',
              onPressed: _exitMultiSelectMode,
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? _buildEmptyView()
              : _buildRecordList(),
      // 多选模式下底部显示批量删除按钮
      bottomNavigationBar: _isMultiSelectMode && _selectedIds.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: _deleteSelected,
                  icon: const Icon(Icons.delete),
                  label: Text('删除选中 (${_selectedIds.length})'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  /// 空列表占位
  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '暂无心率记录',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '开始心率测量后，记录将自动保存到这里',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建记录列表
  Widget _buildRecordList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final record = _records[index];
        final isSelected = _selectedIds.contains(record.id);
        final avgColor = _getBpmColor(record.avgBpm);

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            elevation: isSelected ? 2 : 0.5,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: isSelected
                  ? BorderSide(color: Theme.of(context).primaryColor, width: 2)
                  : BorderSide.none,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                if (_isMultiSelectMode) {
                  _toggleSelect(record.id);
                } else {
                  _showDetail(record);
                }
              },
              onLongPress: () {
                if (!_isMultiSelectMode) {
                  _enterMultiSelectMode();
                  _toggleSelect(record.id);
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // 多选模式下显示复选框
                    if (_isMultiSelectMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Checkbox(
                          value: isSelected,
                          onChanged: (_) => _toggleSelect(record.id),
                        ),
                      ),
                    // 心率图标
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: avgColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.favorite,
                        color: avgColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 信息区
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 第一行：日期 + 连接方式标签
                          Row(
                            children: [
                              Text(
                                _formatDateTime(record.startTimeMs),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // 连接方式标签
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      record.connectionMode ==
                                              HeartRateConnectionMode.ble
                                          ? Icons.bluetooth
                                          : Icons.wifi,
                                      size: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      record.connectionModeText,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // 第二行：平均心率 + 时长
                          Row(
                            children: [
                              Text(
                                '平均 ${record.avgBpm} BPM',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: avgColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                record.durationText,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '${record.samples} 次',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 非多选模式下显示箭头
                    if (!_isMultiSelectMode)
                      Icon(Icons.chevron_right, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
