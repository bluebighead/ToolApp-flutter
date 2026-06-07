# 网速测试：3 种延迟显示模式

**日期**: 2026-06-06
**状态**: Approved
**前置**: v1.2.5+9，已实现自定义 URL 输入

## 目标

在网速测试页的仪表盘位置提供 3 种延迟显示模式，让用户按偏好切换：

1. **数显（默认）**：现状，大号数字 + `ms`
2. **圆盘指针**：半圆 0~1000ms 表盘，指针指向当前延迟，按延迟区间上色
3. **折线图**：本次测试 10 个采样的实时折线动画

用户用 AppBar 上的「显示模式」按钮（在历史按钮左侧）打开 PopupMenu 单选切换，选项持久化。

## 非目标

- 不修改测速算法、不动 URL 自定义、不动历史记录
- 不引入新依赖（`fl_chart` 已在 `pubspec.yaml`）
- 不重做 AppBar 整体布局
- 不增加多套主题

## 架构

```
lib/
├─ pages/network_speed_page.dart          # 改：枚举 + 派发 + 持久化 + PopupMenu
├─ utils/network_speed_settings.dart      # 改：新增 displayMode 字段
├─ widgets/
│   ├─ network_speed_dial.dart            # 新：CustomPaint 半圆表盘
│   └─ network_speed_line_chart.dart      # 新：fl_chart 折线图包装
test/
├─ network_speed_settings_test.dart       # 改：displayMode 默认/往返
├─ network_speed_dial_test.dart           # 新：纯函数 pointerAngleFor
└─ network_speed_line_chart_test.dart     # 新：纯函数 samplesToSpots
```

新增枚举 `enum _DisplayMode { digital, dial, chart }`，仅在 `network_speed_page.dart` 文件内可见。Settings 持久化用 `int`（枚举 index）。

## 组件

### 1. `NetworkSpeedSettings` 扩展

在 `lib/utils/network_speed_settings.dart` 增加第三个字段：

```dart
static const String _kKeyDisplayMode = 'networkspeed_display_mode';

// 读：displayMode 缺失时返回 0（digital）
static Future<NetworkSpeedSettingsSnapshot> load() async {
  final prefs = await SharedPreferences.getInstance();
  final useCustom = prefs.getBool(_kKeyUseCustom) ?? false;
  final url = prefs.getString(_kKeyCustomUrl) ?? '';
  final displayMode = prefs.getInt(_kKeyDisplayMode) ?? 0;
  return (useCustom: useCustom, url: url, displayMode: displayMode);
}

// 写：displayMode 为 null 时不动
static Future<void> save({bool? useCustom, String? url, int? displayMode}) async {
  final prefs = await SharedPreferences.getInstance();
  if (useCustom != null) await prefs.setBool(_kKeyUseCustom, useCustom);
  if (url != null) await prefs.setString(_kKeyCustomUrl, url);
  if (displayMode != null) await prefs.setInt(_kKeyDisplayMode, displayMode);
}
```

`NetworkSpeedSettingsSnapshot` typedef 增加 `int displayMode` 字段。

### 2. `NetworkSpeedPage` 改动

**AppBar actions 调整**：

```dart
actions: [
  // 1. 显示模式选择按钮（新增，左侧）
  PopupMenuButton<_DisplayMode>(
    icon: const Icon(Icons.bar_chart),
    tooltip: '显示模式',
    initialValue: _displayMode,
    onSelected: (m) async {
      setState(() => _displayMode = m);
      await NetworkSpeedSettings.save(displayMode: m.index);
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: _DisplayMode.digital, child: _ModeTile('数显', Icons.text_fields)),
      PopupMenuItem(value: _DisplayMode.dial,    child: _ModeTile('圆盘指针', Icons.donut_large)),
      PopupMenuItem(value: _DisplayMode.chart,   child: _ModeTile('折线图', Icons.show_chart)),
    ],
  ),
  // 2. 历史按钮（保持现状）
  IconButton(icon: const Icon(Icons.history), tooltip: '测速历史', onPressed: _openHistory),
],
```

`_ModeTile` 是 `StatelessWidget`，结构 `ListTile(leading: Radio<_DisplayMode>(value: m, groupValue: _displayMode, onChanged: ...), title: Text('数显'), trailing: Icon(...))`，当前选中时 Radio 实心。

**显示区域派发**：

将 `_buildGauge()` 改为 `_buildDisplay()`，按 `_displayMode` 派发到 3 个 widget，**不改变外层 Column 顺序**：

```dart
Widget _buildDisplay() {
  return AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: switch (_displayMode) {
      _DisplayMode.digital => _buildDigitalGauge(key: const ValueKey('digital')),
      _DisplayMode.dial    => NetworkSpeedDial(latencyMs: _currentLatency, key: const ValueKey('dial')),
      _DisplayMode.chart   => NetworkSpeedLineChart(samples: _samples, key: const ValueKey('chart')),
    },
  );
}
```

`_buildDigitalGauge` 是原 `_buildGauge` 重命名（保持原样）。

### 3. `NetworkSpeedDial`（新组件）

文件：`lib/widgets/network_speed_dial.dart`

```dart
@visibleForTesting
double pointerAngleFor(int? ms) {
  // null -> 180°（指针在起点）
  if (ms == null) return math.pi;
  final clamped = ms.clamp(0, 1000).toDouble();
  return math.pi + (clamped / 1000.0) * math.pi;  // 180° ~ 360°
}

class NetworkSpeedDial extends StatelessWidget {
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
                  color: _latencyColor(latencyMs),
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

  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.9);
    final radius = size.width * 0.45;

    // 1. 画底色半圆（4 段：0-50 绿，50-100 蓝，100-200 橙，200-1000 红）
    final zones = [
      (Colors.green,  math.pi,       math.pi + 50 / 1000 * math.pi),
      (Colors.blue,   math.pi + 50 / 1000 * math.pi,   math.pi + 100 / 1000 * math.pi),
      (Colors.orange, math.pi + 100 / 1000 * math.pi,  math.pi + 200 / 1000 * math.pi),
      (Colors.red,    math.pi + 200 / 1000 * math.pi,  math.pi + math.pi),
    ];
    for (final (color, start, end) in zones) {
      final paint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start, end - start, false, paint,
      );
    }

    // 2. 画指针
    final angle = pointerAngleFor(latencyMs);
    final tip = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    final pointer = Paint()
      ..color = _latencyColor(latencyMs)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, pointer);
    canvas.drawCircle(center, 5, Paint()..color = Colors.grey.shade700);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.latencyMs != latencyMs;
}
```

颜色梯度定义：
- 0-50ms → 绿
- 50-100ms → 蓝
- 100-200ms → 橙
- 200-1000ms → 红

颜色逻辑复用 `NetworkSpeedPage._latencyColor`，提取为顶层 `@visibleForTesting` 函数 `latencyColorFor(int? ms)` 让两个 widget 都能用。

### 4. `NetworkSpeedLineChart`（新组件）

文件：`lib/widgets/network_speed_line_chart.dart`

```dart
@visibleForTesting
List<FlSpot> samplesToSpots(List<int?> samples) {
  final spots = <FlSpot>[];
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    if (v != null) spots.add(FlSpot((i + 1).toDouble(), v.toDouble()));
  }
  return spots;
}

@visibleForTesting
double maxYFor(List<int?> samples) {
  final valid = samples.whereType<int>();
  if (valid.isEmpty) return 100;
  return (valid.reduce(math.max) * 1.2).clamp(50, double.infinity).toDouble();
}

class NetworkSpeedLineChart extends StatelessWidget {
  final List<int?> samples;
  const NetworkSpeedLineChart({super.key, required this.samples});

  @override
  Widget build(BuildContext context) {
    final spots = samplesToSpots(samples);
    final maxY = maxYFor(samples);
    final color = latencyColorFor(
      samples.whereType<int>().isEmpty ? null : samples.lastWhere((s) => s != null),
    );
    return SizedBox(
      width: 280,
      height: 160,
      child: LineChart(
        LineChartData(
          minX: 1, maxX: 10,
          minY: 0, maxY: maxY,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22)),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.shade300)),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: color,
              barWidth: 3,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.15)),
            ),
          ],
        ),
      ),
    );
  }
}
```

- X 轴：1~10 整数刻度，对应 10 次采样
- Y 轴：动态上限 = `max(样本最大值 × 1.2, 50)`
- 丢包点（`null`）不画
- 折线颜色 = 最后一个有效采样值的颜色（复用 `latencyColorFor`）

### 5. 共享颜色函数

文件：`lib/utils/network_speed_utils.dart`（新）

```dart
@visibleForTesting
Color latencyColorFor(int? ms) {
  if (ms == null) return Colors.grey;
  if (ms < 50) return Colors.green;
  if (ms < 100) return Colors.blue;
  if (ms < 200) return Colors.orange;
  return Colors.red;
}
```

`network_speed_page.dart` 删掉私有 `_latencyColor`，改为 `latencyColorFor`。

## 数据流

1. 启动：`_loadSettings` 同时读 `displayMode`（默认 0 = digital）
2. 用户点 PopupMenuItem → `setState(_displayMode = m)` + `Settings.save(displayMode: m.index)`
3. 模式切换：Column 内的 `_buildDisplay` 重新 build，`AnimatedSwitcher` 200ms 淡入淡出
4. 测速进行中：每次采样后 `setState`，三种模式都基于最新 `_currentLatency` / `_samples` 重画

## 错误处理

- Settings.load 抛错 → 退到默认（digital），不阻塞 UI
- PopupMenu 关闭时无 onSelected（按 ESC）→ 不保存
- `pointerAngleFor` 接受 null/越界 → 已 clamp 或返回占位角度
- `samplesToSpots` 接受空列表 / 全 null → 返回 `[]`，LineChart 显示空状态

## 测试

新增/扩展用例：

| 文件 | 用例 |
|---|---|
| `network_speed_settings_test.dart` | ① `load()` 默认 `displayMode=0` ② `save(displayMode: 2) → load` 返回 2 ③ 旧版本数据无 `displayMode` 字段时不报错 |
| `network_speed_dial_test.dart` | ① `pointerAngleFor(null) == π` ② `pointerAngleFor(0) == π` ③ `pointerAngleFor(500) == π + π/2` ④ `pointerAngleFor(1000) == 2π` ⑤ `pointerAngleFor(2000) == 2π`（钳位） |
| `network_speed_line_chart_test.dart` | ① `samplesToSpots` 全成功 → 10 个点 ② 含 null → 跳过 null ③ 全 null → `[]` ④ 空列表 → `[]` ⑤ `maxYFor` 边界 |
| `network_speed_page_validate_test.dart` | 移动 `validateNetworkSpeedUrl` 的位置不动；新增 `latencyColorFor` 测试 |

不验证像素，仅验证纯函数与 widget 渲染不抛异常。

## 风险与缓解

- **圆盘指针精度**：固定 0~1000ms 梯度，>1000ms 全部归到 360°。如有需要后续可加第二圈刻度。
- **AnimatedSwitcher 闪烁**：key 必须稳定，按 ValueKey('digital'/'dial'/'chart') 区分。
- **折线图动画性能**：fl_chart 自带动画，每点重画 OK。10 点规模无压力。
- **PopupMenu 在窄屏溢出**：Material 默认会自适应。

## 验收

- 装 v1.2.6+10 APK
- AppBar 出现「柱状图」图标按钮（左），点击弹 3 选项 Radio 列表
- 默认数显；切到圆盘后画面立即变为半圆 + 当前延迟指针 + 中央数字
- 切到折线图后：idle 状态无折线，running 状态折线随采样生长，done 后定格
- 选完关 app 重开：保留上次选择
- 23 → 32+ 测试通过，analyze 无告警
