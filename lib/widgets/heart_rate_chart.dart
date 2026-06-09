// 心率折线图组件
// 使用 fl_chart 实现实时滚动折线图
// 最多展示最近 60 个采样点（约 1 分钟）
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class HeartRateChart extends StatelessWidget {
  /// 心率历史数据
  final List<int> data;

  const HeartRateChart({
    super.key,
    required this.data,
  });

  /// 根据当前心率范围确定线条颜色
  Color _getLineColor() {
    if (data.isEmpty) return Colors.grey;
    final latest = data.last;
    if (latest < 50) return Colors.blue;
    if (latest <= 100) return Colors.green;
    if (latest <= 140) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    // 如果数据为空，显示占位提示
    if (data.isEmpty) {
      return const Center(
        child: Text(
          '连接设备后显示心率趋势',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    // 构造折线图数据点列表
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].toDouble()));
    }

    return LineChart(
      LineChartData(
        // 网格配置：仅显示水平网格线
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 20,
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
          // Y 轴：左侧显示心率值
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 20,
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
        // Y 轴范围：固定 30 ~ 200 BPM
        minY: 30,
        maxY: 200,
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
