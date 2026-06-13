// 工具项数据模型
// 用于在首页 GridView 中展示可用的工具
// 后续新增工具时只需在 toolList 列表中追加一项即可
import 'package:flutter/material.dart';

// 工具分类枚举
// daily: 日常小白区 — 面向普通用户的日常工具
// geek: 极客区 — 面向专业/极客用户的高级工具
enum ToolCategory { daily, geek }

class ToolItem {
  // 工具显示名称
  final String name;
  // 工具图标
  final IconData icon;
  // 工具颜色（用于卡片和图标着色）
  final Color color;
  // 点击工具后跳转的页面构建器
  final WidgetBuilder pageBuilder;
  // 是否标记为 Beta（实验室功能，开发中、可能存在不足）
  //   true 时 ToolCard 会在右上角显示一个 "Beta" 小角标，
  //   提示用户该功能尚未完全稳定
  final bool isBeta;
  // 工具所属区块分类
  final ToolCategory category;
  // 二级入口副标题（如 "骰子 · 麻将 · 经期"），为空则不显示
  final String? subtitle;

  const ToolItem({
    required this.name,
    required this.icon,
    required this.color,
    required this.pageBuilder,
    this.isBeta = false,
    this.category = ToolCategory.daily,
    this.subtitle,
  });
}
