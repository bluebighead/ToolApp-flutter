// 经期宝统计Tab
// 周期趋势图、统计数据、预测概览、参数设置、数据导出
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../utils/period_export.dart';
import '../utils/period_model.dart';

class PeriodStatsTab extends StatefulWidget {
  final List<PeriodRecord> records;
  final PeriodPrediction prediction;
  final PeriodSettings settings;
  final Future<void> Function(PeriodSettings) onUpdateSettings;
  final List<OvulationMark> ovulationMarks;

  const PeriodStatsTab({
    super.key,
    required this.records,
    required this.prediction,
    required this.settings,
    required this.onUpdateSettings,
    this.ovulationMarks = const [],
  });

  @override
  State<PeriodStatsTab> createState() => _PeriodStatsTabState();
}

class _PeriodStatsTabState extends State<PeriodStatsTab> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = PeriodCalculator.calculateStats(widget.records);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 下次经期倒计时
          _buildCountdownCard(theme),
          const SizedBox(height: 12),
          // 统计数据卡片
          _buildStatsCard(theme, stats),
          const SizedBox(height: 12),
          // 周期趋势图
          if (stats.cycleLengths.isNotEmpty) ...[
            _buildCycleChart(theme, stats),
            const SizedBox(height: 12),
          ],
          // 设置
          _buildSettingsCard(theme),
          const SizedBox(height: 16),
          // 数据导出按钮
          _buildExportButton(theme),
        ],
      ),
    );
  }

  /// 下次经期倒计时卡片
  Widget _buildCountdownCard(ThemeData theme) {
    if (widget.prediction.nextPeriodStart == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.favorite, size: 32, color: Colors.pink.shade200),
                const SizedBox(height: 8),
                Text('添加经期记录后即可查看预测',
                    style: TextStyle(color: Colors.grey.shade500)),
              ],
            ),
          ),
        ),
      );
    }

    final now = DateTime.now();
    final daysUntil =
        widget.prediction.nextPeriodStart!.difference(now).inDays;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('下次经期预测', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Text(
              daysUntil > 0 ? '$daysUntil' : '已到',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: daysUntil > 0 ? Colors.pink : Colors.red,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              daysUntil > 0 ? '天后到来' : '请记录经期开始日期',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 8),
            Text(
              '预计日期：${_formatDate(widget.prediction.nextPeriodStart!)}',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  /// 统计数据卡片
  Widget _buildStatsCard(ThemeData theme, PeriodStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('周期统计', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildStatItem('平均周期', '${stats.averageCycle}天', Colors.pink),
                _buildStatItem(
                    '平均经期', '${stats.averagePeriodLength}天', Colors.red),
              ],
            ),
            const SizedBox(height: 8),
            if (stats.shortestCycle > 0)
              Row(
                children: [
                  _buildStatItem(
                      '最短周期', '${stats.shortestCycle}天', Colors.blue),
                  _buildStatItem(
                      '最长周期', '${stats.longestCycle}天', Colors.orange),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  /// 周期趋势折线图
  Widget _buildCycleChart(ThemeData theme, PeriodStats stats) {
    final data = stats.cycleLengths;
    final displayData =
        data.length > 12 ? data.sublist(data.length - 12) : data;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('周期趋势', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx >= 0 && idx < displayData.length) {
                            return Text(
                              '${idx + 1}',
                              style: const TextStyle(fontSize: 10),
                            );
                          }
                          return const Text('');
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: displayData
                          .asMap()
                          .entries
                          .map((e) =>
                              FlSpot(e.key.toDouble(), e.value.toDouble()))
                          .toList(),
                      isCurved: true,
                      curveSmoothness: 0.3,
                      color: Colors.pink,
                      barWidth: 2.5,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 3,
                            color: Colors.pink,
                            strokeWidth: 1,
                            strokeColor: Colors.white,
                          );
                        },
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.pink.withValues(alpha: 0.1),
                      ),
                    ),
                  ],
                  minY: _calculateChartMinY(displayData),
                  maxY: _calculateChartMaxY(displayData),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text('周期序号',
                  style: TextStyle(
                      fontSize: 10, color: Colors.grey.shade400)),
            ),
          ],
        ),
      ),
    );
  }

  double _calculateChartMinY(List<int> data) {
    if (data.isEmpty) return 20;
    final min = data.reduce((a, b) => a < b ? a : b);
    return (min - 3).toDouble();
  }

  double _calculateChartMaxY(List<int> data) {
    if (data.isEmpty) return 35;
    final max = data.reduce((a, b) => a > b ? a : b);
    return (max + 3).toDouble();
  }

  /// 设置卡片
  Widget _buildSettingsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('参数设置', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            // 智能模式开关
            _buildSmartModeToggle(theme),
            const SizedBox(height: 8),
            // 智能模式说明
            if (widget.settings.smartMode) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome, size: 18, color: Colors.blue.shade600),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '智能模式已开启：系统将根据您的历史记录自动计算并优化周期参数，无需手动调整。记录越多，预测越精准。',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            _buildSettingRow(
              '默认周期天数',
              widget.settings.averageCycleLength,
              20,
              45,
              (v) => widget.onUpdateSettings(
                  widget.settings.copyWith(averageCycleLength: v)),
              disabled: widget.settings.smartMode,
            ),
            const SizedBox(height: 8),
            _buildSettingRow(
              '默认经期天数',
              widget.settings.averagePeriodLength,
              1,
              10,
              (v) => widget.onUpdateSettings(
                  widget.settings.copyWith(averagePeriodLength: v)),
              disabled: widget.settings.smartMode,
            ),
            const SizedBox(height: 8),
            _buildSettingRow(
              '黄体期天数',
              widget.settings.lutealPhaseLength,
              10,
              16,
              (v) => widget.onUpdateSettings(
                  widget.settings.copyWith(lutealPhaseLength: v)),
              disabled: widget.settings.smartMode,
            ),
          ],
        ),
      ),
    );
  }

  /// 智能模式开关
  Widget _buildSmartModeToggle(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: widget.settings.smartMode ? Colors.purple.shade50 : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.settings.smartMode ? Colors.purple.shade200 : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          Icon(
            widget.settings.smartMode ? Icons.auto_awesome : Icons.tune,
            size: 20,
            color: widget.settings.smartMode ? Colors.purple.shade600 : Colors.grey.shade600,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.settings.smartMode ? '智能模式' : '手动模式',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: widget.settings.smartMode ? Colors.purple.shade700 : Colors.grey.shade700,
                  ),
                ),
                Text(
                  widget.settings.smartMode
                      ? '系统自动计算最优参数'
                      : '手动设置周期参数',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Switch(
            value: widget.settings.smartMode,
            onChanged: (v) => widget.onUpdateSettings(widget.settings.copyWith(smartMode: v)),
            activeTrackColor: Colors.purple.shade300,
            activeThumbColor: Colors.purple,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingRow(
      String label, int value, int min, int max, Function(int) onChanged, {bool disabled = false}) {
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: IgnorePointer(
        ignoring: disabled,
        child: Row(
          children: [
            SizedBox(
                width: 100,
                child: Text(label, style: const TextStyle(fontSize: 13))),
            IconButton(
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(
              width: 36,
              child: Center(
                child: Text('$value',
                    style:
                        const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_circle_outline, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 数据导出按钮
  Widget _buildExportButton(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.download, color: Colors.green.shade700),
                const SizedBox(width: 8),
                Text('数据导出', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '将经期记录、排卵日标记等数据导出到本地，方便备份和分享',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isExporting ? null : _showExportDialog,
                icon: _isExporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.file_download),
                label: Text(_isExporting ? '导出中...' : '选择格式导出'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示导出格式选择对话框
  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.download),
            SizedBox(width: 8),
            Text('选择导出格式'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ExportFormat.values.map((format) {
            final isRecommended = format == ExportFormat.xls;
            return ListTile(
              leading: Icon(
                format == ExportFormat.xls
                    ? Icons.table_chart
                    : format == ExportFormat.csv
                        ? Icons.text_snippet
                        : format == ExportFormat.txt
                            ? Icons.description
                            : Icons.article,
                color: isRecommended ? Colors.green : null,
              ),
              title: Row(
                children: [
                  Text(format.label),
                  if (format.badge.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isRecommended
                            ? Colors.green.shade100
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        format.badge,
                        style: TextStyle(
                          fontSize: 10,
                          color: isRecommended
                              ? Colors.green.shade700
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(_getFormatDescription(format)),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(format);
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  String _getFormatDescription(ExportFormat format) {
    switch (format) {
      case ExportFormat.xls:
        return 'Excel 格式，居中对齐，自动适配列宽（推荐）';
      case ExportFormat.csv:
        return '纯文本表格格式，通用性强';
      case ExportFormat.txt:
        return '纯文本报告格式，适合快速浏览';
      case ExportFormat.docx:
        return 'Word 文档格式，排版精美，适合打印';
    }
  }

  /// 执行导出
  Future<void> _doExport(ExportFormat format) async {
    setState(() => _isExporting = true);

    try {
      final filePath = await PeriodDataExporter.export(
        records: widget.records,
        ovulationMarks: widget.ovulationMarks,
        settings: widget.settings,
        format: format,
      );

      if (!mounted) return;

      // 导出成功，提示用户
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导出成功！文件已保存到应用目录'),
          action: SnackBarAction(
            label: '分享',
            onPressed: () {
              PeriodDataExporter.shareExport(filePath);
            },
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }
}
