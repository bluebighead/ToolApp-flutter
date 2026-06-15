// 电量实时监控曲线图
// 显示最近 60s 的电量变化趋势
// v1.54.0+ 新增
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../services/profiler_service.dart';

class ProfilerBatteryChart extends StatelessWidget {
  final List<BatterySample> samples;
  const ProfilerBatteryChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const Center(child: Text('等待数据...', style: TextStyle(color: Colors.grey)));
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < samples.length; i++) {
      spots.add(FlSpot(i.toDouble(), samples[i].level.toDouble()));
    }

    // 电量颜色：>50% 绿色，20-50% 橙色，<20% 红色
    final lastLevel = samples.last.level;
    final color = lastLevel > 50
        ? Colors.green
        : lastLevel > 20
            ? Colors.orange
            : Colors.red;

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 25,
            getDrawingHorizontalLine: (value) => FlLine(
              color: Colors.grey.shade300,
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 25,
                getTitlesWidget: (value, meta) => Text(
                  '${value.toInt()}%',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
            ),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
