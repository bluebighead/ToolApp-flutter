// 经期宝记录Tab
// 经期记录列表、排卵日标记列表、新增/编辑/删除操作
import 'package:flutter/material.dart';

import '../utils/period_model.dart';

class PeriodRecordTab extends StatefulWidget {
  final List<PeriodRecord> records;
  final List<OvulationMark> ovulationMarks;
  final PeriodSettings settings;
  final Future<void> Function() onRefresh;

  const PeriodRecordTab({
    super.key,
    required this.records,
    required this.ovulationMarks,
    required this.settings,
    required this.onRefresh,
  });

  @override
  State<PeriodRecordTab> createState() => _PeriodRecordTabState();
}

class _PeriodRecordTabState extends State<PeriodRecordTab> {
  // 筛选状态
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _filterMode = 'all'; // 'all'=全部, 'precise'=精确, 'fuzzy'=模糊

  /// 应用筛选条件
  List<PeriodRecord> _applyFilters(List<PeriodRecord> records) {
    return records.where((r) {
      // 日期范围筛选
      if (_filterStartDate != null) {
        final start = DateTime(
            _filterStartDate!.year, _filterStartDate!.month, _filterStartDate!.day);
        if (r.startDate.isBefore(start)) return false;
      }
      if (_filterEndDate != null) {
        final end = DateTime(
            _filterEndDate!.year, _filterEndDate!.month, _filterEndDate!.day);
        if (r.startDate.isAfter(end)) return false;
      }
      // 模式筛选
      if (_filterMode != 'all' && r.mode != _filterMode) return false;
      return true;
    }).toList();
  }

  /// 清除所有筛选条件
  void _clearFilters() {
    setState(() {
      _filterStartDate = null;
      _filterEndDate = null;
      _filterMode = 'all';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 按时间倒序排列
    final sortedRecords = List<PeriodRecord>.from(widget.records)
      ..sort((a, b) => b.startDate.compareTo(a.startDate));

    // 应用筛选条件
    final hasActiveFilters = _filterStartDate != null ||
        _filterEndDate != null ||
        _filterMode != 'all';
    final filteredRecords = hasActiveFilters
        ? _applyFilters(sortedRecords)
        : sortedRecords;

    return Column(
      children: [
        // 筛选栏
        _buildFilterBar(theme),
        // 经期记录列表
        Expanded(
          child: filteredRecords.isEmpty
              ? _buildEmptyState(theme, hasActiveFilters)
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filteredRecords.length + 1, // +1 for section header
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Text('经期记录', style: theme.textTheme.titleSmall),
                            const Spacer(),
                            Text('共 ${filteredRecords.length} 条',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500)),
                          ],
                        ),
                      );
                    }
                    final record = filteredRecords[index - 1];
                    return _buildRecordItem(theme, record);
                  },
                ),
        ),
        // 底部操作按钮
        _buildBottomButtons(context),
      ],
    );
  }

  /// 空状态
  Widget _buildEmptyState(ThemeData theme, bool hasActiveFilters) {
    if (hasActiveFilters) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.filter_alt_off, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('没有匹配的记录',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            Text('请调整筛选条件后重试',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.clear_all, size: 16),
              label: const Text('清除筛选'),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 64, color: Colors.pink.shade200),
          const SizedBox(height: 16),
          Text('暂无经期记录',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          Text('点击下方按钮开始记录',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  /// 经期记录条目
  Widget _buildRecordItem(ThemeData theme, PeriodRecord record) {
    // 经量标签
    final flowLabel = ['', '少', '中', '多'][record.flowLevel];
    final flowColor = [null, Colors.blue, Colors.orange, Colors.red][record.flowLevel];

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: () => _showEditDialog(record),
        onLongPress: () => _showDeleteConfirm(record),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部：日期 + 经量
              Row(
                children: [
                  Text(
                    _formatDateRange(record.startDate, record.endDate),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 8),
                  // 模式标签
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: record.mode == 'precise'
                          ? Colors.green.shade50
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: record.mode == 'precise'
                            ? Colors.green.shade300
                            : Colors.orange.shade300,
                      ),
                    ),
                    child: Text(
                      record.mode == 'precise' ? '精确' : '模糊',
                      style: TextStyle(
                        fontSize: 10,
                        color: record.mode == 'precise'
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (record.endDate == null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('进行中',
                          style: TextStyle(
                              fontSize: 10, color: Colors.red.shade600)),
                    ),
                  const Spacer(),
                  // 一键结束按钮（仅进行中显示）
                  if (record.endDate == null)
                    InkWell(
                      onTap: () => _quickEndPeriod(record),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.shade100,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle,
                                size: 14, color: Colors.red.shade700),
                            const SizedBox(width: 2),
                            Text('结束',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.red.shade700)),
                          ],
                        ),
                      ),
                    ),
                  if (record.endDate == null) const SizedBox(width: 4),
                  // 经量
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: (flowColor ?? Colors.grey).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '经量：$flowLabel',
                      style: TextStyle(
                          fontSize: 10,
                          color: flowColor ?? Colors.grey,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 持续天数
                  Text(
                    '${record.durationDays}天',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
              // 症状标签
              if (record.symptoms.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: record.symptoms
                      .map((s) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.pink.shade50,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(s,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.pink.shade600)),
                          ))
                      .toList(),
                ),
              ],
              // 备注
              if (record.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(record.notes,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 筛选栏
  Widget _buildFilterBar(ThemeData theme) {
    final hasActiveFilters = _filterStartDate != null ||
        _filterEndDate != null ||
        _filterMode != 'all';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行：日期范围筛选
          Row(
            children: [
              Text('日期：',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
              // 开始日期
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _filterStartDate ?? DateTime.now(),
                    firstDate: DateTime(2020, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _filterStartDate = picked);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(6),
                    color: _filterStartDate != null ? Colors.blue.shade50 : null,
                  ),
                  child: Text(
                    _filterStartDate != null ? _formatDateShort(_filterStartDate!) : '开始',
                    style: TextStyle(
                      fontSize: 12,
                      color: _filterStartDate != null ? Colors.blue.shade700 : Colors.grey.shade500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text('~', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              const SizedBox(width: 4),
              // 结束日期
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _filterEndDate ?? DateTime.now(),
                    firstDate: DateTime(2020, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _filterEndDate = picked);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(6),
                    color: _filterEndDate != null ? Colors.blue.shade50 : null,
                  ),
                  child: Text(
                    _filterEndDate != null ? _formatDateShort(_filterEndDate!) : '结束',
                    style: TextStyle(
                      fontSize: 12,
                      color: _filterEndDate != null ? Colors.blue.shade700 : Colors.grey.shade500,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // 清除筛选按钮
              if (hasActiveFilters)
                InkWell(
                  onTap: _clearFilters,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.clear, size: 14, color: Colors.red.shade600),
                        const SizedBox(width: 2),
                        Text('清除',
                            style: TextStyle(
                                fontSize: 11, color: Colors.red.shade600)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // 第二行：模式筛选
          Row(
            children: [
              Text('模式：',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(width: 4),
              _buildModeFilterChip('全部', 'all'),
              const SizedBox(width: 4),
              _buildModeFilterChip('精确', 'precise'),
              const SizedBox(width: 4),
              _buildModeFilterChip('模糊', 'fuzzy'),
            ],
          ),
        ],
      ),
    );
  }

  /// 模式筛选 Chip
  Widget _buildModeFilterChip(String label, String value) {
    final isSelected = _filterMode == value;
    return InkWell(
      onTap: () => setState(() => _filterMode = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.green.shade100 : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.green.shade400 : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isSelected ? Colors.green.shade700 : Colors.grey.shade600,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 底部操作按钮
  Widget _buildBottomButtons(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // 新增经期记录
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _showAddRecordDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('记录经期'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 标记排卵日
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _showAddOvulationDialog(),
              icon: const Icon(Icons.star, size: 18),
              label: const Text('标记排卵'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 新增经期记录弹窗
  void _showAddRecordDialog() {
    final now = DateTime.now();
    DateTime startDate = DateTime(now.year, now.month, now.day);
    DateTime? endDate;
    int flowLevel = 2;
    final selectedSymptoms = <String>[];
    final notesController = TextEditingController();
    String recordMode = 'precise'; // 默认精确模式

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('记录经期'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 记录模式选择
                  Text('记录模式',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: recordMode,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                            value: 'precise',
                            child: Text('精确记录模式'),
                          ),
                          DropdownMenuItem(
                            value: 'fuzzy',
                            child: Text('模糊记录模式'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => recordMode = value);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 模式说明
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: recordMode == 'precise'
                          ? Colors.green.shade50
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: recordMode == 'precise'
                            ? Colors.green.shade200
                            : Colors.orange.shade200,
                      ),
                    ),
                    child: Text(
                      recordMode == 'precise'
                          ? '适用于能明确知道经期开始和结束时间的用户，记录精准，为主要预测数据'
                          : '适用于只记得经期开始时间而不记得结束时间的用户，数据不全，仅提供辅助预测',
                      style: TextStyle(
                        fontSize: 11,
                        color: recordMode == 'precise'
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 开始日期
                  Text('开始日期',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  _buildDatePicker(context, startDate,
                      (date) => setDialogState(() => startDate = date)),
                  const SizedBox(height: 12),
                  // 结束日期（仅精确模式显示）
                  if (recordMode == 'precise') ...[
                    Text('结束日期（可选）',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () =>
                              setDialogState(() => endDate = null),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            backgroundColor:
                                endDate == null ? Colors.red.shade50 : null,
                          ),
                          child: const Text('进行中'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: endDate ?? startDate,
                              firstDate: startDate,
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setDialogState(() => endDate = picked);
                            }
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            backgroundColor:
                                endDate != null ? Colors.blue.shade50 : null,
                          ),
                          child: Text(endDate != null
                              ? _formatDateShort(endDate!)
                              : '选择日期'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  // 经量
                  Text('经量',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildFlowChip(
                          '少', 1, flowLevel, setDialogState, (v) => flowLevel = v),
                      const SizedBox(width: 8),
                      _buildFlowChip(
                          '中', 2, flowLevel, setDialogState, (v) => flowLevel = v),
                      const SizedBox(width: 8),
                      _buildFlowChip(
                          '多', 3, flowLevel, setDialogState, (v) => flowLevel = v),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 症状
                  Text('症状（可多选）',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: kSymptomOptions
                        .map((s) => ChoiceChip(
                              label: Text(s, style: const TextStyle(fontSize: 11)),
                              selected: selectedSymptoms.contains(s),
                              onSelected: (selected) {
                                setDialogState(() {
                                  if (selected) {
                                    selectedSymptoms.add(s);
                                  } else {
                                    selectedSymptoms.remove(s);
                                  }
                                });
                              },
                              visualDensity: VisualDensity.compact,
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  // 备注
                  Text('备注',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: notesController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      hintText: '可选备注',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                notesController.dispose();
                Navigator.pop(ctx);
              },
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final record = PeriodRecord(
                  id: startDate.millisecondsSinceEpoch.toString(),
                  startDate: startDate,
                  endDate: recordMode == 'precise' ? endDate : null,
                  flowLevel: flowLevel,
                  symptoms: selectedSymptoms,
                  notes: notesController.text.trim(),
                  mode: recordMode,
                );
                notesController.dispose();
                await PeriodStorage.addRecord(record);
                if (ctx.mounted) Navigator.pop(ctx);
                widget.onRefresh();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 经量选择Chip
  Widget _buildFlowChip(String label, int value, int currentValue,
      StateSetter setState, Function(int) onChanged) {
    final isSelected = currentValue == value;
    final colors = [null, Colors.blue, Colors.orange, Colors.red];
    final color = colors[value] ?? Colors.grey;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => onChanged(value)),
      selectedColor: color.withValues(alpha: 0.15),
      side: BorderSide(
          color: isSelected ? color : Colors.grey.shade300),
    );
  }

  /// 日期选择器
  Widget _buildDatePicker(BuildContext context, DateTime date,
      Function(DateTime) onChanged) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(2020, 1, 1),
          lastDate: DateTime.now(),
        );
        if (picked != null) onChanged(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(_formatDateShort(date)),
            const Spacer(),
            const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  /// 编辑经期记录弹窗
  void _showEditDialog(PeriodRecord record) {
    int flowLevel = record.flowLevel;
    final selectedSymptoms = List<String>.from(record.symptoms);
    final notesController = TextEditingController(text: record.notes);
    // 编辑时使用的结束日期（可为null表示进行中）
    DateTime? editEndDate = record.endDate;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑记录'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 开始日期（固定，不可修改）
                  Text('开始：${_formatDateShort(record.startDate)}',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  // 结束日期选择器（进行中记录可设置结束日期）
                  Row(
                    children: [
                      Text('结束：',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade600)),
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: editEndDate ?? record.startDate,
                              firstDate: record.startDate,
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setDialogState(() => editEndDate = picked);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  editEndDate != null
                                      ? _formatDateShort(editEndDate!)
                                      : '进行中',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: editEndDate != null
                                          ? null
                                          : Colors.red.shade600),
                                ),
                                const Spacer(),
                                const Icon(Icons.calendar_today,
                                    size: 14, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 一键结束按钮（仅进行中显示）
                      if (editEndDate == null)
                        ElevatedButton.icon(
                          onPressed: () {
                            setDialogState(() => editEndDate = DateTime.now());
                          },
                          icon: const Icon(Icons.check_circle, size: 16),
                          label: const Text('今天结束',
                              style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 经量
                  Text('经量',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildFlowChip(
                          '少', 1, flowLevel, setDialogState, (v) => flowLevel = v),
                      const SizedBox(width: 8),
                      _buildFlowChip(
                          '中', 2, flowLevel, setDialogState, (v) => flowLevel = v),
                      const SizedBox(width: 8),
                      _buildFlowChip(
                          '多', 3, flowLevel, setDialogState, (v) => flowLevel = v),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 症状
                  Text('症状',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: kSymptomOptions
                        .map((s) => ChoiceChip(
                              label: Text(s, style: const TextStyle(fontSize: 11)),
                              selected: selectedSymptoms.contains(s),
                              onSelected: (selected) {
                                setDialogState(() {
                                  if (selected) {
                                    selectedSymptoms.add(s);
                                  } else {
                                    selectedSymptoms.remove(s);
                                  }
                                });
                              },
                              visualDensity: VisualDensity.compact,
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  // 备注
                  Text('备注',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: notesController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                notesController.dispose();
                Navigator.pop(ctx);
              },
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final updated = record.copyWith(
                  endDate: editEndDate,
                  flowLevel: flowLevel,
                  symptoms: selectedSymptoms,
                  notes: notesController.text.trim(),
                );
                notesController.dispose();
                await PeriodStorage.updateRecord(updated);
                if (ctx.mounted) Navigator.pop(ctx);
                widget.onRefresh();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 一键结束经期（将结束日期设为今天）
  void _quickEndPeriod(PeriodRecord record) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束经期'),
        content: Text('确定将 ${_formatDateShort(record.startDate)} 开始的经期结束日期设为今天吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final updated = record.copyWith(endDate: DateTime.now());
              await PeriodStorage.updateRecord(updated);
              if (ctx.mounted) Navigator.pop(ctx);
              widget.onRefresh();
            },
            child: const Text('确认结束'),
          ),
        ],
      ),
    );
  }

  /// 删除确认
  void _showDeleteConfirm(PeriodRecord record) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content:
            Text('确定删除 ${_formatDateShort(record.startDate)} 的经期记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await PeriodStorage.deleteRecord(record.id);
              if (ctx.mounted) Navigator.pop(ctx);
              widget.onRefresh();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 标记排卵日弹窗
  void _showAddOvulationDialog() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      await PeriodStorage.addOvulationMark(OvulationMark(date: picked));
      widget.onRefresh();
    }
  }

  String _formatDateShort(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateRange(DateTime start, DateTime? end) {
    if (end == null) {
      return '${start.month}月${start.day}日 ~ 进行中';
    }
    if (start.month == end.month) {
      return '${start.month}月${start.day}日 ~ ${end.day}日';
    }
    return '${start.month}月${start.day}日 ~ ${end.month}月${end.day}日';
  }
}
