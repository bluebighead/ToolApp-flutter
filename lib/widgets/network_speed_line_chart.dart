// 网速测试延迟折线图
// X 轴：1~10 采样序号；Y 轴：延迟毫秒
// 仅本次测速数据；丢包点（null）不画
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../utils/network_speed_utils.dart';

/// 把样本转成 FlSpot 列表，丢包点（null）跳过
@visibleForTesting
List<FlSpot> samplesToSpots(List<int?> samples) {
  final spots = <FlSpot>[];
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    if (v != null) spots.add(FlSpot((i + 1).toDouble(), v.toDouble()));
  }
  return spots;
}

/// 计算 Y 轴上限：max(样本最大值 * 1.2, 50)
@visibleForTesting
double maxYFor(List<int?> samples) {
  final valid = samples.whereType<int>();
  if (valid.isEmpty) return 100;
  return (valid.reduce(math.max) * 1.2).clamp(50, double.infinity).toDouble();
}

/// 折线图控件
class NetworkSpeedLineChart extends StatelessWidget {
  final List<int?> samples;
  const NetworkSpeedLineChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    final spots = samplesToSpots(samples);
    final maxY = maxYFor(samples);
    // 折线颜色 = 最后一个有效采样值（反向遍历，找到即止）
    int? lastValid;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i] != null) {
        lastValid = samples[i];
        break;
      }
    }
    final color = latencyColorFor(lastValid);
    return SizedBox(
      width: 280,
      height: 160,
      child: LineChart(
        LineChartData(
          minX: 1,
          maxX: 10,
          minY: 0,
          maxY: maxY,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 32),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 22),
            ),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: Colors.grey.shade300),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: color,
              barWidth: 3,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
