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
                // 工具图标（带浅色圆形背景）+ 右上角 Beta 角标
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
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
                    // v1.6.34+ Beta 角标：仅当 isBeta=true 时显示
                    //   放在 Stack 右上角，绝对定位，圆形 + 橙色 + 白字
                    if (tool.isBeta)
                      Positioned(
                        top: -4,
                        right: -4,
                        child: _buildBetaBadge(tool.color),
                      ),
                  ],
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

  /// 构建 Beta 实验室功能角标
  ///
  /// 样式：圆形 + 浅色背景 + 主题色文字 + "Beta" 文字。
  /// 用主题色（tool.color）作边框和文字色，与卡片配色协调。
  Widget _buildBetaBadge(Color themeColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: themeColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        'Beta',
        style: TextStyle(
          fontSize: 9,
          color: themeColor,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          height: 1.0,
        ),
      ),
    );
  }
}
