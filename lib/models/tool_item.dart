// 工具项数据模型
// 用于在首页 GridView 中展示可用的工具
// 后续新增工具时只需在 toolList 列表中追加一项即可
import 'package:flutter/material.dart';

class ToolItem {
  // 工具显示名称
  final String name;
  // 工具图标
  final IconData icon;
  // 工具颜色（用于卡片和图标着色）
  final Color color;
  // 点击工具后跳转的页面构建器
  final WidgetBuilder pageBuilder;

  const ToolItem({
    required this.name,
    required this.icon,
    required this.color,
    required this.pageBuilder,
  });
}
