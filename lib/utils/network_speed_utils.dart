// 网速测试共享工具
// 集中放延迟 -> 颜色等纯逻辑，方便仪表盘 / 圆盘 / 折线图复用
import 'package:flutter/material.dart';

/// 把延迟（毫秒）映射到颜色：
/// null=灰 / <50 绿 / <100 蓝 / <200 橙 / >=200 红
/// 与原 NetworkSpeedPage._latencyColor 行为一致
Color latencyColorFor(int? ms) {
  if (ms == null) return Colors.grey;
  if (ms < 50) return Colors.green;
  if (ms < 100) return Colors.blue;
  if (ms < 200) return Colors.orange;
  return Colors.red;
}
