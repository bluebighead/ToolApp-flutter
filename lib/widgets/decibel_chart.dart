// 分贝折线图组件
// 使用 fl_chart 实现实时滚动折线图
// 最多展示最近 60 个采样点（约 1 分钟）
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class DecibelChart extends StatelessWidget {
  // 分贝历史数据
  final List<double> data;

  const DecibelChart({
    super.key,
    required this.data,
  });

  // 根据当前最大分贝值确定线条颜色
  // 颜色随音量大小变化，直观反映噪音等级
  Color _getLineColor() {
    if (data.isEmpty) return Colors.blue;
    final maxVal = data.reduce((a, b) => a > b ? a : b);
    if (maxVal < 40) return Colors.green;
    if (maxVal < 70) return Colors.blue;
    if (maxVal < 90) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    // 如果数据为空，显示占位提示
    if (data.isEmpty) {
      return const Center(
        child: Text(
          '点击"开始测试"查看分贝变化',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    // 构造折线图数据点列表
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i]));
    }

    return LineChart(
      LineChartData(
        // 网格配置：仅显示水平网格线
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 30,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withValues(alpha: 0.2),
              strokeWidth: 1,
            );
          },
        ),
        // 标题配置
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          // X 轴：显示采样点序号
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 10,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                );
              },
            ),
          ),
          // Y 轴：左侧显示分贝值
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 30,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                );
              },
            ),
          ),
        ),
        // 边框配置：仅显示左、下两条边框
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
          ),
        ),
        // X 轴范围：固定窗口大小为 60 个点
        minX: data.length > 60 ? (data.length - 60).toDouble() : 0,
        maxX: data.length.toDouble() - 1,
        // Y 轴范围：固定 30 ~ 120 dB
        minY: 30,
        maxY: 120,
        // 折线配置
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            // 折线颜色
            color: _getLineColor(),
            // 线条宽度
            barWidth: 3,
            // 折线下方填充：渐变色
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _getLineColor().withValues(alpha: 0.3),
                  _getLineColor().withValues(alpha: 0.0),
                ],
              ),
            ),
            // 不显示数据点，保持简洁
            dotData: const FlDotData(show: false),
          ),
        ],
        // 禁用触摸交互（避免误触）
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }
}
