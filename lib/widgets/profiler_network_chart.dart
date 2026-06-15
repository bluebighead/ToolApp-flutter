// 网络实时监控曲线图
// 显示最近 60s 的上下行速率变化趋势（双线）
// v1.54.0+ 新增
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../services/profiler_service.dart';

class ProfilerNetworkChart extends StatelessWidget {
  final List<NetworkSample> samples;
  const ProfilerNetworkChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const Center(child: Text('等待数据...', style: TextStyle(color: Colors.grey)));
    }

    // 计算最大速率用于 Y 轴
    double maxSpeed = 100; // 默认 100 Kbps
    for (final s in samples) {
      if (s.downloadSpeedKbps > maxSpeed) maxSpeed = s.downloadSpeedKbps;
      if (s.uploadSpeedKbps > maxSpeed) maxSpeed = s.uploadSpeedKbps;
    }
    maxSpeed = (maxSpeed * 1.2).clamp(100, double.infinity);

    final dlSpots = <FlSpot>[];
    final ulSpots = <FlSpot>[];
    for (var i = 0; i < samples.length; i++) {
      dlSpots.add(FlSpot(i.toDouble(), samples[i].downloadSpeedKbps));
      ulSpots.add(FlSpot(i.toDouble(), samples[i].uploadSpeedKbps));
    }

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxSpeed,
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
                getTitlesWidget: (value, meta) => Text(
                  _formatSpeed(value),
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
            // 下行速率
            LineChartBarData(
              spots: dlSpots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: Colors.teal,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.teal.withValues(alpha: 0.1),
              ),
            ),
            // 上行速率
            LineChartBarData(
              spots: ulSpots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: Colors.orange,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.orange.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 格式化速率显示
  String _formatSpeed(double kbps) {
    if (kbps < 1000) return '${kbps.toStringAsFixed(0)}K';
    return '${(kbps / 1000).toStringAsFixed(1)}M';
  }
}
