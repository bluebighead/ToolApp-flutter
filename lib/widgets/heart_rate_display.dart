// 心率数值显示组件
// 大号BPM数字 + 心率状态图标 + 文字描述（正常/偏快/偏慢）
// 根据心率值自动切换颜色
import 'package:flutter/material.dart';

class HeartRateDisplay extends StatelessWidget {
  /// 当前心率值（BPM）
  final int heartRate;
  /// 状态：是否正在接收数据
  final bool isActive;

  const HeartRateDisplay({
    super.key,
    required this.heartRate,
    this.isActive = false,
  });

  /// 根据心率值返回对应颜色
  Color _getColor() {
    if (heartRate == 0) return Colors.grey;
    if (heartRate < 50) return Colors.blue;       // 偏慢
    if (heartRate <= 100) return Colors.green;    // 正常
    if (heartRate <= 140) return Colors.orange;   // 偏快
    return Colors.red;                            // 过快
  }

  /// 根据心率值返回对应文字描述
  String _getLabel() {
    if (heartRate == 0) return '等待数据';
    if (heartRate < 50) return '偏慢';
    if (heartRate <= 100) return '正常';
    if (heartRate <= 140) return '偏快';
    return '过快';
  }

  /// 根据心率值返回对应图标
  IconData _getIcon() {
    if (heartRate == 0) return Icons.favorite_border;
    return Icons.favorite;
  }

  @override
  Widget build(BuildContext context) {
    final color = _getColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 心率图标
        Icon(
          _getIcon(),
          size: 48,
          color: color,
        ),
        const SizedBox(height: 8),
        // 大号心率数值
        Text(
          heartRate > 0 ? heartRate.toString() : '--',
          style: TextStyle(
            fontSize: 80,
            fontWeight: FontWeight.bold,
            color: color,
            // 激活状态时添加脉冲阴影效果
            shadows: isActive && heartRate > 0
                ? [
                    Shadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 25,
                    ),
                  ]
                : null,
          ),
        ),
        // 单位 BPM
        const Text(
          'BPM',
          style: TextStyle(
            fontSize: 24,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        // 文字描述（带浅色背景胶囊样式）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _getLabel(),
            style: TextStyle(
              fontSize: 16,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
