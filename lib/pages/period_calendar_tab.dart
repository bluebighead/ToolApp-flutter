// 经期宝日历Tab
// 月历视图，标注经期/排卵期/安全期，点击日期弹出小气泡说明，长按日期进行标记操作
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../utils/period_model.dart';

class PeriodCalendarTab extends StatefulWidget {
  final List<PeriodRecord> records;
  final List<OvulationMark> ovulationMarks;
  final PeriodSettings settings;
  final PeriodPrediction prediction;
  final Future<void> Function() onRefresh;

  const PeriodCalendarTab({
    super.key,
    required this.records,
    required this.ovulationMarks,
    required this.settings,
    required this.prediction,
    required this.onRefresh,
  });

  @override
  State<PeriodCalendarTab> createState() => _PeriodCalendarTabState();
}

class _PeriodCalendarTabState extends State<PeriodCalendarTab> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  // 日期显示语言：true=中文，false=英文
  bool _useChineseDate = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // 日历
        _buildCalendar(theme),
        const Divider(height: 1),
        // 下方信息卡片
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: _buildInfoCards(theme),
          ),
        ),
      ],
    );
  }

  /// 构建日历组件
  Widget _buildCalendar(ThemeData theme) {
    return Column(
      children: [
        // 自定义头部：可点击的年月选择器 + 中英转换按钮
        _buildCustomHeader(),
        // 日历本体（隐藏默认头部）
        TableCalendar(
          firstDay: DateTime(2020, 1, 1),
          lastDay: DateTime(2030, 12, 31),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          // 点击日期：选中并显示小气泡说明
          onDaySelected: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
            _showDayInfoBubble(selectedDay);
          },
          // 长按日期：弹出标记操作菜单
          onDayLongPressed: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
            _showDayActionMenu(selectedDay);
          },
          onPageChanged: (focusedDay) {
            _focusedDay = focusedDay;
          },
          calendarStyle: CalendarStyle(
            outsideDaysVisible: false,
            todayDecoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            todayTextStyle:
                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            selectedDecoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.primary, width: 2),
              shape: BoxShape.circle,
            ),
          ),
          calendarBuilders: CalendarBuilders(
            // 自定义日期单元格绘制
            defaultBuilder: (context, day, focusedDay) {
              return _buildDayCell(day);
            },
            todayBuilder: (context, day, focusedDay) {
              return _buildDayCell(day, isToday: true);
            },
            selectedBuilder: (context, day, focusedDay) {
              return _buildDayCell(day, isSelected: true);
            },
          ),
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: const TextStyle(fontSize: 0, height: 0),
            titleTextFormatter: (date, locale) => '',
            leftChevronVisible: false,
            rightChevronVisible: false,
            headerPadding: EdgeInsets.zero,
            headerMargin: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  /// 自定义日历头部（可点击的年月选择器 + 中英转换按钮）
  Widget _buildCustomHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 左箭头
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                _focusedDay = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
              });
            },
          ),
          // 可点击的年月标题
          Expanded(
            child: InkWell(
              onTap: () => _showYearMonthPicker(_focusedDay),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _formatYearMonth(_focusedDay),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          // 右箭头
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                _focusedDay = DateTime(_focusedDay.year, _focusedDay.month + 1, 1);
              });
            },
          ),
          // 中英切换按钮
          IconButton(
            icon: Icon(_useChineseDate ? Icons.language : Icons.translate, size: 20),
            onPressed: () => setState(() => _useChineseDate = !_useChineseDate),
            tooltip: _useChineseDate ? '切换英文' : '切换中文',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 格式化年月显示（支持中英切换）
  String _formatYearMonth(DateTime date) {
    if (_useChineseDate) {
      return '${date.year}年${date.month}月';
    } else {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ];
      return '${months[date.month - 1]} ${date.year}';
    }
  }

  /// 弹出年月选择器
  void _showYearMonthPicker(DateTime currentDate) {
    showDialog(
      context: context,
      builder: (ctx) => _YearMonthPicker(
        initialYear: currentDate.year,
        initialMonth: currentDate.month,
        onSelected: (year, month) {
          setState(() {
            _focusedDay = DateTime(year, month, 1);
          });
          Navigator.pop(ctx);
        },
      ),
    );
  }

  /// 构建单个日期单元格
  Widget _buildDayCell(DateTime day,
      {bool isToday = false, bool isSelected = false}) {
    final dayType = PeriodCalculator.getDayType(
      date: day,
      records: widget.records,
      prediction: widget.prediction,
      ovulationMarks: widget.ovulationMarks,
    );

    Color? bgColor;
    Color textColor = Colors.black87;
    Widget? indicator;

    switch (dayType) {
      case DayType.period:
        bgColor = Colors.red.shade100;
        textColor = Colors.red.shade700;
        break;
      case DayType.periodPredicted:
        bgColor = Colors.red.shade50;
        textColor = Colors.red.shade400;
        break;
      case DayType.ovulation:
        bgColor = Colors.blue.shade100;
        textColor = Colors.blue.shade700;
        indicator = _buildDot(Colors.blue.shade700);
        break;
      case DayType.ovulationMarked:
        bgColor = Colors.blue.shade100;
        textColor = Colors.blue.shade700;
        indicator = _buildStar(Colors.blue.shade700);
        break;
      case DayType.ovulationPhase:
        bgColor = Colors.blue.shade50;
        textColor = Colors.blue.shade400;
        break;
      case DayType.safe:
        bgColor = Colors.green.shade50;
        textColor = Colors.green.shade600;
        break;
      case DayType.none:
        break;
    }

    // 预测经期用虚线边框
    BoxBorder? border;
    if (dayType == DayType.periodPredicted) {
      border = Border.all(
        color: Colors.red.shade200,
        width: 1,
      );
    }

    return Container(
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: isToday ? null : border,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 今日高亮
          if (isToday)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          // 日期文字
          Center(
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                color: isToday ? Colors.white : textColor,
              ),
            ),
          ),
          // 指示器（排卵日圆点或星标）
          if (indicator != null)
            Positioned(
              bottom: 1,
              child: SizedBox(width: 8, height: 8, child: indicator),
            ),
        ],
      ),
    );
  }

  /// 小圆点指示器
  Widget _buildDot(Color color) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  /// 星标指示器
  Widget _buildStar(Color color) {
    return Icon(Icons.star, size: 8, color: color);
  }

  /// 点击日期弹出小气泡说明
  void _showDayInfoBubble(DateTime day) {
    final dayType = PeriodCalculator.getDayType(
      date: day,
      records: widget.records,
      prediction: widget.prediction,
      ovulationMarks: widget.ovulationMarks,
    );

    // 获取说明文字
    String title;
    String description;
    IconData icon;
    Color iconColor;

    switch (dayType) {
      case DayType.period:
        title = '经期';
        description = '今天是经期（已记录）';
        icon = Icons.water_drop;
        iconColor = Colors.red;
        break;
      case DayType.periodPredicted:
        title = '预测经期';
        description = '预计今天是经期';
        icon = Icons.water_drop_outlined;
        iconColor = Colors.red.shade400;
        break;
      case DayType.ovulation:
        title = '排卵日';
        description = '今天是预计排卵日';
        icon = Icons.auto_awesome;
        iconColor = Colors.blue;
        break;
      case DayType.ovulationMarked:
        title = '排卵日（已标记）';
        description = '您手动标记了今天为排卵日';
        icon = Icons.star;
        iconColor = Colors.blue;
        break;
      case DayType.ovulationPhase:
        title = '排卵期';
        description = '今天处于排卵期范围内';
        icon = Icons.auto_awesome;
        iconColor = Colors.blue.shade400;
        break;
      case DayType.safe:
        title = '安全期';
        description = '今天处于安全期范围内';
        icon = Icons.shield;
        iconColor = Colors.green.shade600;
        break;
      case DayType.none:
        title = '普通日';
        description = '今天没有特殊生理期标注';
        icon = Icons.circle_outlined;
        iconColor = Colors.grey;
        break;
    }

    // 检查是否有经期记录
    final existingRecord = widget.records.where((r) {
      final start =
          DateTime(r.startDate.year, r.startDate.month, r.startDate.day);
      final d = DateTime(day.year, day.month, day.day);
      if (d.isBefore(start)) return false;
      if (r.endDate != null) {
        final end =
            DateTime(r.endDate!.year, r.endDate!.month, r.endDate!.day);
        return !d.isAfter(end);
      }
      return d == start;
    }).firstOrNull;

    // 如果有经期记录，添加详细信息
    if (existingRecord != null) {
      final flowLabel = ['', '少', '中', '多'][existingRecord.flowLevel];
      description = '经期第${existingRecord.durationDays}天 · 经量：$flowLabel';
      if (existingRecord.symptoms.isNotEmpty) {
        description += ' · ${existingRecord.symptoms.join('、')}';
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  // 中英切换按钮
                  IconButton(
                    icon: Icon(
                      _useChineseDate ? Icons.language : Icons.translate,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() => _useChineseDate = !_useChineseDate);
                      Navigator.pop(ctx);
                      _showDayInfoBubble(day);
                    },
                    tooltip: _useChineseDate ? '切换英文' : '切换中文',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _formatDateFull(day),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  description,
                  style: TextStyle(
                      fontSize: 14,
                      color: iconColor,
                      fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '长按日期可进行标记操作',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按日期弹出操作菜单
  void _showDayActionMenu(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);

    // 检查该天是否已有经期记录
    final existingRecord = widget.records.where((r) {
      final start =
          DateTime(r.startDate.year, r.startDate.month, r.startDate.day);
      if (d.isBefore(start)) return false;
      if (r.endDate != null) {
        final end =
            DateTime(r.endDate!.year, r.endDate!.month, r.endDate!.day);
        return !d.isAfter(end);
      }
      return d == start;
    }).firstOrNull;

    // 检查该天是否已有排卵标记
    final hasOvulationMark = widget.ovulationMarks.any((m) =>
        m.date.year == d.year &&
        m.date.month == d.month &&
        m.date.day == d.day);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _formatDate(day),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            // 标记经期开始
            if (existingRecord == null)
              ListTile(
                leading: const Icon(Icons.play_arrow, color: Colors.red),
                title: const Text('标记经期开始'),
                onTap: () {
                  Navigator.pop(ctx);
                  _markPeriodStart(day);
                },
              ),
            // 标记经期结束（仅进行中的经期）
            if (existingRecord != null && existingRecord.endDate == null)
              ListTile(
                leading: const Icon(Icons.stop, color: Colors.red),
                title: const Text('标记经期结束'),
                onTap: () {
                  Navigator.pop(ctx);
                  _markPeriodEnd(existingRecord, day);
                },
              ),
            // 取消经期记录
            if (existingRecord != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.grey),
                title: const Text('取消该日经期记录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _cancelPeriodRecord(existingRecord, day);
                },
              ),
            // 标记排卵日
            if (!hasOvulationMark)
              ListTile(
                leading: const Icon(Icons.star, color: Colors.blue),
                title: const Text('标记排卵日'),
                onTap: () {
                  Navigator.pop(ctx);
                  _markOvulationDay(day);
                },
              ),
            // 取消排卵日标记
            if (hasOvulationMark)
              ListTile(
                leading: const Icon(Icons.star_border, color: Colors.grey),
                title: const Text('取消排卵日标记'),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeOvulationMark(day);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 标记经期开始
  Future<void> _markPeriodStart(DateTime day) async {
    final record = PeriodRecord(
      id: day.millisecondsSinceEpoch.toString(),
      startDate: day,
      flowLevel: 2,
    );
    await PeriodStorage.addRecord(record);
    widget.onRefresh();
  }

  /// 标记经期结束
  Future<void> _markPeriodEnd(PeriodRecord record, DateTime day) async {
    // 结束日期不能早于开始日期
    if (day.isBefore(record.startDate)) return;
    final updated = record.copyWith(endDate: day);
    await PeriodStorage.updateRecord(updated);
    widget.onRefresh();
  }

  /// 取消经期记录（从记录中移除该日）
  Future<void> _cancelPeriodRecord(PeriodRecord record, DateTime day) async {
    final d = DateTime(day.year, day.month, day.day);
    final start = DateTime(
        record.startDate.year, record.startDate.month, record.startDate.day);

    // 如果是开始日且是唯一的经期日，直接删除整条记录
    if (d == start &&
        (record.endDate == null ||
            DateTime(record.endDate!.year, record.endDate!.month,
                    record.endDate!.day) ==
                start)) {
      await PeriodStorage.deleteRecord(record.id);
    } else if (d == start) {
      // 如果是开始日但不是结束日，将开始日推迟一天
      final newStart = record.startDate.add(const Duration(days: 1));
      final updated = record.copyWith(startDate: newStart);
      await PeriodStorage.updateRecord(updated);
    } else if (record.endDate != null) {
      final end = DateTime(
          record.endDate!.year, record.endDate!.month, record.endDate!.day);
      if (d == end) {
        // 如果是结束日，将结束日提前一天
        final newEnd = record.endDate!.subtract(const Duration(days: 1));
        if (newEnd.isBefore(record.startDate)) {
          // 如果提前后早于开始日，删除记录
          await PeriodStorage.deleteRecord(record.id);
        } else {
          final updated = record.copyWith(endDate: newEnd);
          await PeriodStorage.updateRecord(updated);
        }
      }
    }
    widget.onRefresh();
  }

  /// 标记排卵日
  Future<void> _markOvulationDay(DateTime day) async {
    final mark = OvulationMark(date: day);
    await PeriodStorage.addOvulationMark(mark);
    widget.onRefresh();
  }

  /// 取消排卵日标记
  Future<void> _removeOvulationMark(DateTime day) async {
    await PeriodStorage.deleteOvulationMark(day);
    widget.onRefresh();
  }

  /// 下方信息卡片
  Widget _buildInfoCards(ThemeData theme) {
    final prediction = widget.prediction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 图例说明（调换到前面）
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('图例说明', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _buildLegendItem(Colors.red.shade100, Colors.red.shade700, '经期'),
                _buildLegendItem(
                    Colors.red.shade50, Colors.red.shade400, '预测经期'),
                _buildLegendItem(
                    Colors.blue.shade100, Colors.blue.shade700, '排卵日'),
                _buildLegendItem(
                    Colors.blue.shade50, Colors.blue.shade400, '排卵期'),
                _buildLegendItem(
                    Colors.green.shade50, Colors.green.shade600, '安全期'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 当前周期信息（调换到后面）
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('周期信息', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _buildInfoRow(
                    '平均周期', '${prediction.calculatedCycleLength} 天'),
                if (prediction.nextPeriodStart != null)
                  _buildInfoRow(
                      '下次经期预测', _formatDate(prediction.nextPeriodStart!)),
                if (prediction.ovulationDay != null)
                  _buildInfoRow(
                      '预计排卵日', _formatDate(prediction.ovulationDay!)),
                if (prediction.ovulationPhase != null)
                  _buildInfoRow(
                    '排卵期',
                    '${_formatDate(prediction.ovulationPhase!.start)} ~ ${_formatDate(prediction.ovulationPhase!.end)}',
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
              width: 100,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Colors.grey))),
          Expanded(
              child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color bgColor, Color textColor, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: textColor)),
        ],
      ),
    );
  }

  /// 完整日期格式化（支持中英）
  String _formatDateFull(DateTime date) {
    if (_useChineseDate) {
      return '${date.year}年${date.month}月${date.day}日';
    } else {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}月${date.day}日';
  }
}

/// 年月选择器对话框
class _YearMonthPicker extends StatefulWidget {
  final int initialYear;
  final int initialMonth;
  final void Function(int year, int month) onSelected;

  const _YearMonthPicker({
    required this.initialYear,
    required this.initialMonth,
    required this.onSelected,
  });

  @override
  State<_YearMonthPicker> createState() => _YearMonthPickerState();
}

class _YearMonthPickerState extends State<_YearMonthPicker> {
  late int _selectedYear;
  late int _selectedMonth;
  late final FixedExtentScrollController _yearController;
  late final FixedExtentScrollController _monthController;

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialYear;
    _selectedMonth = widget.initialMonth;
    final now = DateTime.now();
    final years = List.generate(12, (i) => now.year - 5 + i);
    final yearIdx = years.indexOf(_selectedYear);
    _yearController = FixedExtentScrollController(initialItem: yearIdx >= 0 ? yearIdx : 5);
    _monthController = FixedExtentScrollController(initialItem: _selectedMonth - 1);
  }

  @override
  void dispose() {
    _yearController.dispose();
    _monthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final years = List.generate(12, (i) => now.year - 5 + i);

    return AlertDialog(
      title: const Text('选择年月'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 年份选择
            Text('年份', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            SizedBox(
              height: 120,
              child: ListWheelScrollView.useDelegate(
                controller: _yearController,
                itemExtent: 40,
                perspective: 0.005,
                diameterRatio: 1.5,
                physics: const FixedExtentScrollPhysics(),
                onSelectedItemChanged: (idx) {
                  setState(() => _selectedYear = years[idx]);
                },
                childDelegate: ListWheelChildBuilderDelegate(
                  builder: (context, index) {
                    if (index < 0 || index >= years.length) return null;
                    final isSelected = years[index] == _selectedYear;
                    return Center(
                      child: Text(
                        '${years[index]}年',
                        style: TextStyle(
                          fontSize: isSelected ? 20 : 16,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? Colors.pink : Colors.black54,
                        ),
                      ),
                    );
                  },
                  childCount: years.length,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 月份选择
            Text('月份', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            SizedBox(
              height: 120,
              child: ListWheelScrollView.useDelegate(
                controller: _monthController,
                itemExtent: 40,
                perspective: 0.005,
                diameterRatio: 1.5,
                physics: const FixedExtentScrollPhysics(),
                onSelectedItemChanged: (idx) {
                  setState(() => _selectedMonth = idx + 1);
                },
                childDelegate: ListWheelChildBuilderDelegate(
                  builder: (context, index) {
                    if (index < 0 || index >= 12) return null;
                    final isSelected = index + 1 == _selectedMonth;
                    return Center(
                      child: Text(
                        '${index + 1}月',
                        style: TextStyle(
                          fontSize: isSelected ? 20 : 16,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? Colors.pink : Colors.black54,
                        ),
                      ),
                    );
                  },
                  childCount: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => widget.onSelected(_selectedYear, _selectedMonth),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
