// 内存实时监控曲线图
// 显示最近 60s 的内存使用量变化趋势
// v1.54.0+ 新增
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../services/profiler_service.dart';

class ProfilerMemoryChart extends StatelessWidget {
  final List<MemorySample> samples;
  const ProfilerMemoryChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const Center(child: Text('等待数据...', style: TextStyle(color: Colors.grey)));
    }

    // Y 轴上限：总内存
    final totalMb = samples.first.totalMb.toDouble();
    final spots = <FlSpot>[];
    for (var i = 0; i < samples.length; i++) {
      spots.add(FlSpot(i.toDouble(), samples[i].usedMb.toDouble()));
    }

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: totalMb,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: Colors.grey.shade300,
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: totalMb / 4,
                getTitlesWidget: (value, meta) => Text(
                  '${(value / 1024).toStringAsFixed(1)}G',
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
              color: Colors.deepPurple,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.deepPurple.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
