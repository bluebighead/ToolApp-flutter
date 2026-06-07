# 网速测试 3 种显示模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在网速测试页的仪表盘位置提供数显 / 圆盘指针 / 折线图 三种切换模式，通过 AppBar PopupMenu 单选，持久化到 SharedPreferences。

**Architecture:** 新增 `lib/utils/network_speed_utils.dart` 共享 `latencyColorFor` 颜色函数；新增 `lib/widgets/network_speed_dial.dart` (CustomPaint) 与 `lib/widgets/network_speed_line_chart.dart` (fl_chart)；扩展 `NetworkSpeedSettings` 增加 `displayMode` 字段；`NetworkSpeedPage` 引入 `_DisplayMode` 枚举并以 `AnimatedSwitcher` 派发渲染。

**Tech Stack:** Flutter 3 / Dart 3、`fl_chart: ^0.68.0`（已有）、`shared_preferences: ^2.2.2`（已有）、`@visibleForTesting` 顶级函数。

**Spec:** `docs/superpowers/specs/2026-06-06-toolapp-networkspeed-displaymodes-design.md`

---

## 文件总览

| 文件 | 状态 | 职责 |
|---|---|---|
| `lib/utils/network_speed_utils.dart` | 新建 | `latencyColorFor` 共享颜色函数 |
| `lib/utils/network_speed_settings.dart` | 改 | 增加 `displayMode` 字段 |
| `lib/widgets/network_speed_dial.dart` | 新建 | 半圆 CustomPaint 圆盘 |
| `lib/widgets/network_speed_line_chart.dart` | 新建 | fl_chart 折线图包装 |
| `lib/pages/network_speed_page.dart` | 改 | 加枚举 + PopupMenu + 派发 + 改 `_latencyColor` 为共享函数 |
| `test/network_speed_utils_test.dart` | 新建 | 颜色函数测试 |
| `test/network_speed_settings_test.dart` | 改 | displayMode 默认/往返 |
| `test/network_speed_dial_test.dart` | 新建 | pointerAngleFor 纯函数 |
| `test/network_speed_line_chart_test.dart` | 新建 | samplesToSpots / maxYFor 纯函数 |

---

## Task 1: 共享颜色函数 latencyColorFor + 测试

**Files:**
- Create: `lib/utils/network_speed_utils.dart`
- Create: `test/network_speed_utils_test.dart`

- [ ] **Step 1: 写测试** — 在 `test/network_speed_utils_test.dart` 写入：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/utils/network_speed_utils.dart';

void main() {
  group('latencyColorFor', () {
    test('null -> 灰', () {
      expect(latencyColorFor(null), Colors.grey);
    });
    test('0ms -> 绿', () {
      expect(latencyColorFor(0), Colors.green);
    });
    test('49ms -> 绿', () {
      expect(latencyColorFor(49), Colors.green);
    });
    test('50ms -> 蓝', () {
      expect(latencyColorFor(50), Colors.blue);
    });
    test('99ms -> 蓝', () {
      expect(latencyColorFor(99), Colors.blue);
    });
    test('100ms -> 橙', () {
      expect(latencyColorFor(100), Colors.orange);
    });
    test('199ms -> 橙', () {
      expect(latencyColorFor(199), Colors.orange);
    });
    test('200ms -> 红', () {
      expect(latencyColorFor(200), Colors.red);
    });
    test('9999ms -> 红', () {
      expect(latencyColorFor(9999), Colors.red);
    });
  });
}
```

- [ ] **Step 2: 跑测试，确认 fail** — `cd h:\Mycode\Trae\Flutter\ToolApp; flutter test test/network_speed_utils_test.dart` 应报 "Target of URI doesn't exist"。

- [ ] **Step 3: 实现** — 创建 `lib/utils/network_speed_utils.dart`：

```dart
// 网速测试共享工具
// 集中放延迟 -> 颜色等纯逻辑，方便仪表盘 / 圆盘 / 折线图复用
import 'package:flutter/material.dart';

/// 把延迟（毫秒）映射到颜色：
/// null=灰 / <50 绿 / <100 蓝 / <200 橙 / >=200 红
/// 与原 NetworkSpeedPage._latencyColor 行为一致
@visibleForTesting
Color latencyColorFor(int? ms) {
  if (ms == null) return Colors.grey;
  if (ms < 50) return Colors.green;
  if (ms < 100) return Colors.blue;
  if (ms < 200) return Colors.orange;
  return Colors.red;
}
```

- [ ] **Step 4: 跑测试** — 9/9 PASS。

- [ ] **Step 5: 提交** — `git add lib/utils/network_speed_utils.dart test/network_speed_utils_test.dart && git commit -m "feat(networkspeed): add shared latencyColorFor utility"`

---

## Task 2: NetworkSpeedSettings 增加 displayMode 字段 + 测试

**Files:**
- Modify: `lib/utils/network_speed_settings.dart`
- Modify: `test/network_speed_settings_test.dart`

- [ ] **Step 1: 看现状** — 读 `lib/utils/network_speed_settings.dart` 与 `test/network_speed_settings_test.dart`，确认当前 typedef 是 `({bool useCustom, String url})`。

- [ ] **Step 2: 改测试** — 替换 `test/network_speed_settings_test.dart` 内容为：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolapp/utils/network_speed_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load() 默认：useCustom=false, url=空, displayMode=0', () async {
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isFalse);
    expect(s.url, isEmpty);
    expect(s.displayMode, 0);
  });

  test('save 后 load 应返回保存值', () async {
    await NetworkSpeedSettings.save(
      useCustom: true,
      url: 'https://example.com',
      displayMode: 2,
    );
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://example.com');
    expect(s.displayMode, 2);
  });

  test('save 只传 useCustom 不应清空 url 和 displayMode', () async {
    await NetworkSpeedSettings.save(url: 'https://x.com', displayMode: 1);
    await NetworkSpeedSettings.save(useCustom: true);
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 1);
  });

  test('save 只传 url 不应修改 useCustom 和 displayMode', () async {
    await NetworkSpeedSettings.save(useCustom: true, displayMode: 2);
    await NetworkSpeedSettings.save(url: 'https://x.com');
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 2);
  });

  test('save 只传 displayMode 不应修改其他字段', () async {
    await NetworkSpeedSettings.save(useCustom: true, url: 'https://x.com');
    await NetworkSpeedSettings.save(displayMode: 1);
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 1);
  });
}
```

- [ ] **Step 3: 跑测试，确认 fail** — 编译报错 "displayMode 未定义"。

- [ ] **Step 4: 改实现** — 整个 `lib/utils/network_speed_settings.dart` 替换为：

```dart
// 网速测试用户设置读写工具
// 持久化三个字段：是否启用自定义目标 URL、自定义 URL 字符串、显示模式（int 枚举 index）
import 'package:shared_preferences/shared_preferences.dart';

/// 网速测试设置快照
typedef NetworkSpeedSettingsSnapshot = ({
  bool useCustom,
  String url,
  int displayMode,
});

/// 网速测试设置读写工具
class NetworkSpeedSettings {
  /// SharedPreferences 键：是否启用自定义目标
  static const String _kKeyUseCustom = 'networkspeed_use_custom_url';

  /// SharedPreferences 键：自定义目标 URL 字符串
  static const String _kKeyCustomUrl = 'networkspeed_custom_url';

  /// SharedPreferences 键：显示模式（int 枚举 index）
  static const String _kKeyDisplayMode = 'networkspeed_display_mode';

  /// 从 SharedPreferences 读取设置
  /// 缺失字段时返回默认值：useCustom=false, url='', displayMode=0
  static Future<NetworkSpeedSettingsSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final useCustom = prefs.getBool(_kKeyUseCustom) ?? false;
    final url = prefs.getString(_kKeyCustomUrl) ?? '';
    final displayMode = prefs.getInt(_kKeyDisplayMode) ?? 0;
    return (useCustom: useCustom, url: url, displayMode: displayMode);
  }

  /// 写入设置；只持久化非 null 的字段，保留其他字段的现有值
  static Future<void> save({
    bool? useCustom,
    String? url,
    int? displayMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (useCustom != null) {
      await prefs.setBool(_kKeyUseCustom, useCustom);
    }
    if (url != null) {
      await prefs.setString(_kKeyCustomUrl, url);
    }
    if (displayMode != null) {
      await prefs.setInt(_kKeyDisplayMode, displayMode);
    }
  }
}
```

- [ ] **Step 5: 跑测试** — 5/5 PASS。

- [ ] **Step 6: 提交** — `git add lib/utils/network_speed_settings.dart test/network_speed_settings_test.dart && git commit -m "feat(networkspeed): add displayMode field to settings"`

---

## Task 3: NetworkSpeedDial 圆盘指针 + pointerAngleFor 纯函数 + 测试

**Files:**
- Create: `lib/widgets/network_speed_dial.dart`
- Create: `test/network_speed_dial_test.dart`

- [ ] **Step 1: 写测试** — 创建 `test/network_speed_dial_test.dart`：

```dart
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/widgets/network_speed_dial.dart';

void main() {
  group('pointerAngleFor', () {
    test('null -> pi（指针在起点）', () {
      expect(pointerAngleFor(null), math.pi);
    });
    test('0ms -> pi', () {
      expect(pointerAngleFor(0), math.pi);
    });
    test('500ms -> pi + pi/2（正右方）', () {
      expect(pointerAngleFor(500), math.pi + math.pi / 2);
    });
    test('1000ms -> 2pi（指针在终点）', () {
      expect(pointerAngleFor(1000), 2 * math.pi);
    });
    test('>1000ms 钳位到 2pi', () {
      expect(pointerAngleFor(2000), 2 * math.pi);
      expect(pointerAngleFor(99999), 2 * math.pi);
    });
    test('负数钳位到 pi', () {
      expect(pointerAngleFor(-50), math.pi);
    });
    test('单调递增：0 < 100 < 500 < 1000', () {
      final a0 = pointerAngleFor(0);
      final a1 = pointerAngleFor(100);
      final a5 = pointerAngleFor(500);
      final a10 = pointerAngleFor(1000);
      expect(a0, lessThan(a1));
      expect(a1, lessThan(a5));
      expect(a5, lessThan(a10));
    });
  });
}
```

- [ ] **Step 2: 跑测试，确认 fail** — 编译报错 "Target of URI doesn't exist"。

- [ ] **Step 3: 实现** — 创建 `lib/widgets/network_speed_dial.dart`：

```dart
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
```

- [ ] **Step 4: 跑测试** — 7/7 PASS。

- [ ] **Step 5: 提交** — `git add lib/widgets/network_speed_dial.dart test/network_speed_dial_test.dart && git commit -m "feat(networkspeed): add NetworkSpeedDial widget with pointer"`

---

## Task 4: NetworkSpeedLineChart 折线图 + samplesToSpots/maxYFor 纯函数 + 测试

**Files:**
- Create: `lib/widgets/network_speed_line_chart.dart`
- Create: `test/network_speed_line_chart_test.dart`

- [ ] **Step 1: 写测试** — 创建 `test/network_speed_line_chart_test.dart`：

```dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/widgets/network_speed_line_chart.dart';

void main() {
  group('samplesToSpots', () {
    test('空列表 -> 空', () {
      expect(samplesToSpots([]), isEmpty);
    });
    test('全 null -> 空', () {
      expect(samplesToSpots([null, null, null]), isEmpty);
    });
    test('全成功 -> 长度=列表长度，X 从 1 开始', () {
      final spots = samplesToSpots([10, 20, 30]);
      expect(spots.length, 3);
      expect(spots[0], const FlSpot(1, 10));
      expect(spots[1], const FlSpot(2, 20));
      expect(spots[2], const FlSpot(3, 30));
    });
    test('含 null -> 跳过 null 保持 X 连续', () {
      final spots = samplesToSpots([10, null, 30, null, 50]);
      expect(spots.length, 3);
      expect(spots[0].x, 1);
      expect(spots[1].x, 3);
      expect(spots[2].x, 5);
    });
  });

  group('maxYFor', () {
    test('空列表 -> 100', () {
      expect(maxYFor([]), 100);
    });
    test('全 null -> 100', () {
      expect(maxYFor([null, null]), 100);
    });
    test('正常值 -> max * 1.2', () {
      expect(maxYFor([10, 20, 50]), 60);
    });
    test('小值钳位到 50', () {
      expect(maxYFor([1, 2, 3]), 50);
    });
    test('10 个等大值', () {
      expect(maxYFor([100, 100, 100, 100, 100, 100, 100, 100, 100, 100]), 120);
    });
  });
}
```

- [ ] **Step 2: 跑测试，确认 fail** — 编译报错。

- [ ] **Step 3: 实现** — 创建 `lib/widgets/network_speed_line_chart.dart`：

```dart
// 网速测试延迟折线图
// X 轴：1~10 采样序号；Y 轴：延迟毫秒
// 仅本次测速数据；丢包点（null）不画
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../utils/network_speed_utils.dart';

/// 把样本转成 FlSpot 列表，丢包点（null）跳过
@visibleForTesting
List<FlSpot> samplesToSpots(List<int?> samples) {
  final spots = <FlSpot>[];
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    if (v != null) spots.add(FlSpot((i + 1).toDouble(), v.toDouble()));
  }
  return spots;
}

/// 计算 Y 轴上限：max(样本最大值 * 1.2, 50)
@visibleForTesting
double maxYFor(List<int?> samples) {
  final valid = samples.whereType<int>();
  if (valid.isEmpty) return 100;
  return (valid.reduce(math.max) * 1.2).clamp(50, double.infinity).toDouble();
}

/// 折线图控件
class NetworkSpeedLineChart extends StatelessWidget {
  final List<int?> samples;
  const NetworkSpeedLineChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    final spots = samplesToSpots(samples);
    final maxY = maxYFor(samples);
    // 折线颜色 = 最后一个有效采样值
    final lastValid = samples.lastWhere(
      (s) => s != null,
      orElse: () => null,
    );
    final color = latencyColorFor(lastValid);
    return SizedBox(
      width: 280,
      height: 160,
      child: LineChart(
        LineChartData(
          minX: 1,
          maxX: 10,
          minY: 0,
          maxY: maxY,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 32),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 22),
            ),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: Colors.grey.shade300),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: color,
              barWidth: 3,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试** — 9/9 PASS。

- [ ] **Step 5: 提交** — `git add lib/widgets/network_speed_line_chart.dart test/network_speed_line_chart_test.dart && git commit -m "feat(networkspeed): add NetworkSpeedLineChart widget"`

---

## Task 5: NetworkSpeedPage 集成 — 枚举 + PopupMenu + 派发

**Files:**
- Modify: `lib/pages/network_speed_page.dart`

- [ ] **Step 1: 改 import 与枚举** — 在 `lib/pages/network_speed_page.dart` 顶部 import 块改为：

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import '../utils/network_speed_history.dart';
import '../utils/network_speed_settings.dart';
import '../utils/network_speed_utils.dart';
import '../widgets/network_speed_dial.dart';
import '../widgets/network_speed_line_chart.dart';
import 'network_speed_history_page.dart';
```

- [ ] **Step 2: 新增 `_DisplayMode` 枚举** — 在文件顶部（在 `enum _Status` 上方）新增：

```dart
/// 仪表盘显示模式
enum _DisplayMode {
  /// 大号数字
  digital,

  /// 半圆 0~1000ms 圆盘指针
  dial,

  /// 折线图（本次 10 个采样）
  chart,
}
```

- [ ] **Step 3: 替换私有 `_latencyColor`** — 找原 `_latencyColor` 方法（搜索 `Color _latencyColor`），整段删除，引用处全部改为顶层 `latencyColorFor(...)`。提示：在 `lib/pages/network_speed_page.dart` 中搜索 `_latencyColor(` 应能找到至少 1 处（仪表盘大字），删方法体即可。

- [ ] **Step 4: 加状态字段** — 在 `_NetworkSpeedPageState` 类内（其他 `final` 字段附近）新增：

```dart
/// 当前显示模式
_DisplayMode _displayMode = _DisplayMode.digital;
```

- [ ] **Step 5: `_loadSettings` 读 `displayMode`** — 把现有 `_loadSettings` 改为：

```dart
Future<void> _loadSettings() async {
  final s = await NetworkSpeedSettings.load();
  if (!mounted) return;
  final detected = detectScheme(s.url) ?? _kDefaultScheme;
  final mode = _DisplayMode.values[s.displayMode.clamp(0, _DisplayMode.values.length - 1)];
  setState(() {
    _useCustomUrl = s.useCustom;
    _customUrl = s.url;
    _scheme = detected;
    _urlController.text = _customUrl;
    _displayMode = mode;
  });
}
```

- [ ] **Step 6: 改 AppBar actions + 改 `_buildGauge` → `_buildDisplay`** — 把 `build` 方法里 `actions:` 数组改为：

```dart
actions: [
  // 1. 显示模式选择按钮（新增，左侧）
  PopupMenuButton<_DisplayMode>(
    icon: const Icon(Icons.bar_chart),
    tooltip: '显示模式',
    initialValue: _displayMode,
    onSelected: (m) async {
      if (m == _displayMode) return;
      setState(() => _displayMode = m);
      await NetworkSpeedSettings.save(displayMode: m.index);
      AppLogger.i('NetworkSpeedPage', '切换显示模式 -> $m');
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: _DisplayMode.digital,
        child: _ModeTile(
          mode: _DisplayMode.digital,
          current: _displayMode,
          label: '数显',
          icon: Icons.text_fields,
        ),
      ),
      PopupMenuItem(
        value: _DisplayMode.dial,
        child: _ModeTile(
          mode: _DisplayMode.dial,
          current: _displayMode,
          label: '圆盘指针',
          icon: Icons.donut_large,
        ),
      ),
      PopupMenuItem(
        value: _DisplayMode.chart,
        child: _ModeTile(
          mode: _DisplayMode.chart,
          current: _displayMode,
          label: '折线图',
          icon: Icons.show_chart,
        ),
      ),
    ],
  ),
  // 2. 历史按钮（保持现状）
  IconButton(
    icon: const Icon(Icons.history),
    tooltip: '测速历史',
    onPressed: _openHistory,
  ),
],
```

- [ ] **Step 7: Column 中替换 `_buildGauge` → `_buildDisplay`** — 把 `_buildGauge()` 调用改为 `_buildDisplay()`。在文件最末（`_buildCurrentTargetLabel` 之后或任意 `_build*` 方法后）新增：

```dart
/// 显示模式派发入口：按 _displayMode 选择渲染
Widget _buildDisplay() {
  return AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: switch (_displayMode) {
      _DisplayMode.digital => _buildDigitalGauge(
          key: const ValueKey('digital'),
        ),
      _DisplayMode.dial => NetworkSpeedDial(
          key: const ValueKey('dial'),
          latencyMs: _currentLatency,
        ),
      _DisplayMode.chart => NetworkSpeedLineChart(
          key: const ValueKey('chart'),
          samples: _samples,
        ),
    },
  );
}

/// 数显：大号延迟数字（原 _buildGauge 重命名）
Widget _buildDigitalGauge({Key? key}) {
  return Center(
    key: key,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _currentLatency?.toString() ?? '--',
          style: TextStyle(
            fontSize: 80,
            fontWeight: FontWeight.bold,
            color: latencyColorFor(_currentLatency),
          ),
        ),
        const SizedBox(height: 4),
        const Text('ms', style: TextStyle(fontSize: 18, color: Colors.grey)),
      ],
    ),
  );
}
```

**删除原 `_buildGauge()` 方法**（已被 `_buildDigitalGauge` 取代）。

- [ ] **Step 8: 新增 `_ModeTile` 类** — 在 `NetworkSpeedPage` 类外、`_NetworkSpeedPageState` 类下方新增：

```dart
/// 显示模式菜单项：Radio + 文字 + 图标
class _ModeTile extends StatelessWidget {
  final _DisplayMode mode;
  final _DisplayMode current;
  final String label;
  final IconData icon;

  const _ModeTile({
    required this.mode,
    required this.current,
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Radio<_DisplayMode>(
        value: mode,
        groupValue: current,
        onChanged: (_) => Navigator.of(context).pop(mode),
      ),
      title: Text(label),
      trailing: Icon(icon, size: 18, color: Colors.grey),
    );
  }
}
```

注意：`current: _displayMode` 是 `_NetworkSpeedPageState` 实例字段，传给 `_ModeTile` 时是从 build 闭包内访问，OK。

- [ ] **Step 9: analyze** — `cd h:\Mycode\Trae\Flutter\ToolApp; flutter analyze` 应返回 "No issues found!"。

- [ ] **Step 10: 跑全量测试** — `cd h:\Mycode\Trae\Flutter\ToolApp; flutter test` 应 PASS（>=30 个用例）。

- [ ] **Step 11: 提交** — `git add lib/pages/network_speed_page.dart && git commit -m "feat(networkspeed): integrate 3 display modes with popup menu"`

---

## Task 6: 升版本号 + 打 release APK + 装手机

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: 升版本** — 编辑 `pubspec.yaml`，`version: 1.2.5+9` → `version: 1.2.6+10`。

- [ ] **Step 2: `flutter pub get`** — `cd h:\Mycode\Trae\Flutter\ToolApp; flutter pub get`。

- [ ] **Step 3: 删旧 APK** — `Remove-Item h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\flutter-apk\app-release.apk -ErrorAction SilentlyContinue`。

- [ ] **Step 4: 打 release** — `cd h:\Mycode\Trae\Flutter\ToolApp; flutter build apk --release`，等出 `Built build\app\outputs\flutter-apk\app-release.apk`。

- [ ] **Step 5: 装手机** — `adb install -r h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\flutter-apk\app-release.apk`，输出 `Success`。

- [ ] **Step 6: 提交版本号** — `git add pubspec.yaml && git commit -m "chore: bump version to 1.2.6+10"`。

---

## Task 7: 手动验证（10 步）

- [ ] **Step 1: 打开"网速测试"** — 默认显示数显（80pt 大数字）。
- [ ] **Step 2: AppBar 左侧出现「柱状图」图标按钮** — 在历史按钮左边。
- [ ] **Step 3: 点击该按钮弹 PopupMenu** — 含 3 行：数显（Radio 实心）、圆盘指针、折线图，每行带图标。
- [ ] **Step 4: 选「圆盘指针」** — 仪表盘区变为半圆 0~1000ms 4 色梯度，指针在最左侧（无数据），中央显示 `--`。
- [ ] **Step 5: 选「折线图」** — 仪表盘区变为 280×160 折线图（无数据时空状态）。
- [ ] **Step 6: 选「数显」** — 回到 80pt 大数字。
- [ ] **Step 7: 点击「开始测试」** — 数显模式跑完 10 次，看大数字从 `--` → 100 → 80 → ... 变化。
- [ ] **Step 8: 测速完成后切到「圆盘指针」** — 指针指向最后一次延迟，颜色正确（绿/蓝/橙/红）。
- [ ] **Step 9: 切到「折线图」** — 看到完整 10 个点的折线（无丢包时全绿）。
- [ ] **Step 10: 杀进程重开** — 保持上次选择的模式，配置持久化生效。

如果都通过，本 plan 完成。
