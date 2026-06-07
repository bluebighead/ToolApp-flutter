// 首页工具卡片
// 显示工具图标和名称，点击触发回调
import 'package:flutter/material.dart';
import '../models/tool_item.dart';

class ToolCard extends StatelessWidget {
  // 工具数据
  final ToolItem tool;
  // 点击回调
  final VoidCallback onTap;

  const ToolCard({
    super.key,
    required this.tool,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      // 卡片整体样式
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        // 点击波纹效果
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          // 使用 FittedBox 在空间不足时自动缩小内容，避免溢出
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Column(
              // 垂直居中布局
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 工具图标（带浅色圆形背景）
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: tool.color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    tool.icon,
                    size: 28,
                    color: tool.color,
                  ),
                ),
                const SizedBox(height: 8),
                // 工具名称
                Text(
                  tool.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
