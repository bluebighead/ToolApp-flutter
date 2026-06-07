// 网速测试延迟圆盘指针
// 半圆 0~1000ms 4 段颜色梯度（绿/蓝/橙/红），指针指向当前延迟位置
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../utils/network_speed_utils.dart';

/// 把延迟（毫秒）映射到指针弧度：null=起点（pi），0=pi，1000=2pi
/// 越界钳位
@visibleForTesting
double pointerAngleFor(int? ms) {
  if (ms == null) return math.pi;
  final clamped = ms.clamp(0, 1000).toDouble();
  return math.pi + (clamped / 1000.0) * math.pi;
}

/// 圆盘指针控件
class NetworkSpeedDial extends StatelessWidget {
  /// 当前延迟（毫秒）；null 时指针在起点，中央显示 '--'
  final int? latencyMs;

  const NetworkSpeedDial({super.key, required this.latencyMs});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      height: 140,
      child: CustomPaint(
        painter: _DialPainter(latencyMs: latencyMs),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                latencyMs?.toString() ?? '--',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: latencyColorFor(latencyMs),
                ),
              ),
              const Text('ms', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final int? latencyMs;
  _DialPainter({required this.latencyMs});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.9);
    final radius = size.width * 0.45;

    // 4 段色带：0-50 绿, 50-100 蓝, 100-200 橙, 200-1000 红
    const segments = <(Color, int, int)>[
      (Colors.green, 0, 50),
      (Colors.blue, 50, 100),
      (Colors.orange, 100, 200),
      (Colors.red, 200, 1000),
    ];
    for (final (color, from, to) in segments) {
      final start = math.pi + (from / 1000.0) * math.pi;
      final end = math.pi + (to / 1000.0) * math.pi;
      final paint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        end - start,
        false,
        paint,
      );
    }

    // 指针
    final angle = pointerAngleFor(latencyMs);
    final tip = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    final pointerPaint = Paint()
      ..color = latencyColorFor(latencyMs)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, pointerPaint);
    canvas.drawCircle(center, 5, Paint()..color = Colors.grey.shade700);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.latencyMs != latencyMs;
}
