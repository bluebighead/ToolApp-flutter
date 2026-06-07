// 分贝数值显示组件
// 顶部大号数字 + 文字描述（安静/正常/嘈杂/很吵）
// 根据当前分贝值自动切换颜色
import 'package:flutter/material.dart';

class DecibelDisplay extends StatelessWidget {
  // 当前分贝值
  final double decibel;
  // 状态：是否采集中（true 时数字放大并加阴影）
  final bool isRunning;

  const DecibelDisplay({
    super.key,
    required this.decibel,
    this.isRunning = false,
  });

  // 根据分贝值返回对应颜色
  Color _getColor() {
    if (decibel < 40) return Colors.green;
    if (decibel < 70) return Colors.blue;
    if (decibel < 90) return Colors.orange;
    return Colors.red;
  }

  // 根据分贝值返回对应文字描述
  String _getLabel() {
    if (decibel < 40) return '安静';
    if (decibel < 70) return '正常';
    if (decibel < 90) return '嘈杂';
    return '很吵';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 大号分贝数值
        Text(
          decibel.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 72,
            fontWeight: FontWeight.bold,
            color: _getColor(),
            // 采集中时添加阴影，提示用户正在录音
            shadows: isRunning
                ? [
                    Shadow(
                      color: _getColor().withValues(alpha: 0.3),
                      blurRadius: 20,
                    ),
                  ]
                : null,
          ),
        ),
        // 单位 dB
        const Text(
          'dB',
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
            color: _getColor().withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _getLabel(),
            style: TextStyle(
              fontSize: 16,
              color: _getColor(),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
