# 工具箱 App - 分贝测试仪 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Flutter 创建一个安卓工具箱 App，第一期实现"分贝测试仪"工具，能实时检测环境分贝并用折线图展示。

**Architecture:** 单 Flutter 项目；首页为工具 GridView，分贝测试仪为独立子页面；通过 `noise_meter` 监听麦克风数据，维护一个最近 60 个点的折线图。

**Tech Stack:** Flutter 3.41.4 (Dart 3.11.1) · `noise_meter` ^4.0.1 · `fl_chart` ^0.68.0 · `permission_handler` ^11.0.0

**注释约定:** 所有 Dart 代码注释使用中文（遵循用户规则）。

---

## Task 1: 创建 Flutter 项目骨架

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\` 整个 Flutter 项目

- [ ] **Step 1.1: 创建 Flutter 项目**

```powershell
cd h:\Mycode\Trae\Flutter
flutter create --org com.example --project-name toolapp --platforms=android ToolApp
```

预期: 创建成功，包含 `android/`, `lib/`, `pubspec.yaml` 等。

- [ ] **Step 1.2: 验证项目结构**

```powershell
Test-Path h:\Mycode\Trae\Flutter\ToolApp\pubspec.yaml
Test-Path h:\Mycode\Trae\Flutter\ToolApp\lib\main.dart
Test-Path h:\Mycode\Trae\Flutter\ToolApp\android\app\src\main\AndroidManifest.xml
```

预期: 全部返回 `True`。

---

## Task 2: 添加依赖

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\pubspec.yaml`

- [ ] **Step 2.1: 编辑 pubspec.yaml**

在 `dependencies:` 块下增加:

```yaml
  # 实时获取麦克风分贝值
  noise_meter: ^4.0.1
  # 折线图绘制
  fl_chart: ^0.68.0
  # 统一处理麦克风权限申请
  permission_handler: ^11.0.0
```

完整 `dependencies` 块示例:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  noise_meter: ^4.0.1
  fl_chart: ^0.68.0
  permission_handler: ^11.0.0
```

- [ ] **Step 2.2: 安装依赖**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter pub get
```

预期: 依赖下载完成，无错误。

---

## Task 3: 配置 Android 权限

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\android\app\src\main\AndroidManifest.xml`

- [ ] **Step 3.1: 添加 RECORD_AUDIO 权限**

在 `<manifest>` 标签内、`<application>` 之前添加:

```xml
    <!-- 申请麦克风权限，用于分贝测试 -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
```

完整 manifest 关键部分:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- 申请麦克风权限，用于分贝测试 -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <application
        android:label="toolapp"
        ...
```

- [ ] **Step 3.2: 设置 Android 最低 SDK 版本**

修改 `h:\Mycode\Trae\Flutter\ToolApp\android\app\build.gradle.kts`（或 `build.gradle`），确保 `minSdk = 23`:

```kotlin
android {
    defaultConfig {
        minSdk = 23
        // ...
    }
}
```

---

## Task 4: 创建工具项数据模型

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\models\tool_item.dart`

- [ ] **Step 4.1: 编写 ToolItem 模型**

```dart
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
```

---

## Task 5: 编写主入口 main.dart

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\lib\main.dart`

- [ ] **Step 5.1: 重写 main.dart**

完整内容:

```dart
// 工具箱 App 主入口
// 配置 Material 3 主题并启动首页
import 'package:flutter/material.dart';
import 'pages/home_page.dart';

void main() {
  runApp(const ToolApp());
}

class ToolApp extends StatelessWidget {
  const ToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '实用工具箱',
      debugShowCheckedModeBanner: false,
      // Material 3 主题配置
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}
```

---

## Task 6: 创建首页 HomePage

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\pages\home_page.dart`

- [ ] **Step 6.1: 编写首页**

```dart
// 工具箱 App 首页
// 采用 GridView 展示所有可用工具
// 后续添加新工具时只需在 _toolList 列表中追加 ToolItem
import 'package:flutter/material.dart';
import '../models/tool_item.dart';
import '../widgets/tool_card.dart';
import 'decibel_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  // 工具列表：第一期仅含分贝测试仪
  static final List<ToolItem> _toolList = [
    ToolItem(
      name: '分贝测试仪',
      icon: Icons.graphic_eq,
      color: Colors.indigo,
      pageBuilder: (_) => const DecibelPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶部应用栏
      appBar: AppBar(
        title: const Text('实用工具箱'),
      ),
      // 主体：工具网格视图
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          // 每行显示 3 个工具
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: _toolList.length,
          itemBuilder: (context, index) {
            final tool = _toolList[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                // 点击工具卡片：跳转到对应页面
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: tool.pageBuilder),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
```

---

## Task 7: 创建工具卡片组件 ToolCard

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\widgets\tool_card.dart`

- [ ] **Step 7.1: 编写 ToolCard 组件**

```dart
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
          padding: const EdgeInsets.all(12.0),
          child: Column(
            // 垂直居中布局
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 工具图标（带浅色圆形背景）
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: tool.color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  tool.icon,
                  size: 32,
                  color: tool.color,
                ),
              ),
              const SizedBox(height: 12),
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
    );
  }
}
```

---

## Task 8: 创建分贝显示组件 DecibelDisplay

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\widgets\decibel_display.dart`

- [ ] **Step 8.1: 编写 DecibelDisplay 组件**

```dart
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
          '${decibel.toStringAsFixed(1)}',
          style: TextStyle(
            fontSize: 72,
            fontWeight: FontWeight.bold,
            color: _getColor(),
            // 采集中时添加阴影
            shadows: isRunning
                ? [
                    Shadow(
                      color: _getColor().withOpacity(0.3),
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
        // 文字描述
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: _getColor().withOpacity(0.15),
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
```

---

## Task 9: 创建折线图组件 DecibelChart

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\widgets\decibel_chart.dart`

- [ ] **Step 9.1: 编写 DecibelChart 组件**

```dart
// 分贝折线图组件
// 使用 fl_chart 实现实时滚动折线图
// 最多展示最近 60 个采样点（约 1 分钟）
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class DecibelChart extends StatelessWidget {
  // 分贝历史数据
  final List<double> data;

  const DecibelChart({
    super.key,
    required this.data,
  });

  // 根据当前最大分贝值确定线条颜色
  Color _getLineColor() {
    if (data.isEmpty) return Colors.blue;
    final maxVal = data.reduce((a, b) => a > b ? a : b);
    if (maxVal < 40) return Colors.green;
    if (maxVal < 70) return Colors.blue;
    if (maxVal < 90) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    // 如果数据为空，显示占位提示
    if (data.isEmpty) {
      return const Center(
        child: Text(
          '点击"开始测试"查看分贝变化',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    // 构造折线图数据点列表
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i]));
    }

    return LineChart(
      LineChartData(
        // 网格配置
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 30,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withOpacity(0.2),
              strokeWidth: 1,
            );
          },
        ),
        // 标题配置
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          // X 轴：隐藏刻度文字
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 10,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                );
              },
            ),
          ),
          // Y 轴：左侧显示分贝值
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 30,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                );
              },
            ),
          ),
        ),
        // 边框配置
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.grey.withOpacity(0.3)),
            bottom: BorderSide(color: Colors.grey.withOpacity(0.3)),
          ),
        ),
        // X 轴范围：固定窗口大小为 60
        minX: data.length > 60 ? (data.length - 60).toDouble() : 0,
        maxX: data.length > 60 ? (data.length - 1).toDouble() : (data.length - 1).toDouble(),
        // Y 轴范围：固定 30 ~ 120 dB
        minY: 30,
        maxY: 120,
        // 折线配置
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            // 渐变填充
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _getLineColor().withOpacity(0.4),
                _getLineColor().withOpacity(0.0),
              ],
            ),
            barWidth: 3,
            // 折线颜色
            color: _getLineColor(),
            // 折线下方填充
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _getLineColor().withOpacity(0.3),
                  _getLineColor().withOpacity(0.0),
                ],
              ),
            ),
            // 不显示数据点
            dotData: const FlDotData(show: false),
          ),
        ],
        // 交互：禁用触摸提示
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }
}
```

---

## Task 10: 创建分贝测试仪页面 DecibelPage

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\pages\decibel_page.dart`

- [ ] **Step 10.1: 编写 DecibelPage**

```dart
// 分贝测试仪页面
// 实时检测环境分贝值并用折线图展示
// 状态：idle（未开始） / running（采集中） / error（出错）
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../widgets/decibel_display.dart';
import '../widgets/decibel_chart.dart';

class DecibelPage extends StatefulWidget {
  const DecibelPage({super.key});

  @override
  State<DecibelPage> createState() => _DecibelPageState();
}

class _DecibelPageState extends State<DecibelPage> {
  // 噪声计实例
  final NoiseMeter _noiseMeter = NoiseMeter();
  // 订阅句柄
  StreamSubscription<NoiseReading>? _subscription;
  // 当前分贝值
  double _currentDb = 0.0;
  // 历史分贝数据队列（最多 60 个点）
  final List<double> _history = [];
  // 最大保留点数
  static const int _maxPoints = 60;
  // 是否正在采集
  bool _isRunning = false;
  // 错误信息
  String? _errorMessage;

  @override
  void dispose() {
    // 页面销毁时停止采集，防止后台占用麦克风
    _stop();
    super.dispose();
  }

  // 开始采集
  Future<void> _start() async {
    try {
      // 检查并申请麦克风权限
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        setState(() {
          _errorMessage = '需要麦克风权限才能测试分贝';
          _isRunning = false;
        });
        _showPermissionDialog();
        return;
      }

      // 启动噪声计监听
      _subscription = _noiseMeter.noiseStream.listen(
        _onData,
        onError: _onError,
        cancelOnError: false,
      );
      setState(() {
        _isRunning = true;
        _errorMessage = null;
        // 开始时清空历史
        _history.clear();
      });
    } catch (e) {
      setState(() {
        _errorMessage = '启动失败：$e';
        _isRunning = false;
      });
    }
  }

  // 停止采集
  Future<void> _stop() async {
    try {
      await _subscription?.cancel();
      _subscription = null;
      try {
        await _noiseMeter.stop();
      } catch (_) {
        // 忽略 stop 时的异常（如已经停止）
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  // 处理采集数据
  void _onData(NoiseReading reading) {
    if (!mounted) return;
    // 过滤异常值（NaN、负无穷等）
    final db = reading.meanDecibel;
    if (db.isNaN || db.isInfinite || db < 0) return;
    setState(() {
      _currentDb = db;
      _history.add(db);
      // 限制历史长度，最多保留 60 个点
      if (_history.length > _maxPoints) {
        _history.removeAt(0);
      }
    });
  }

  // 处理采集异常
  void _onError(Object error) {
    if (!mounted) return;
    setState(() {
      _errorMessage = '麦克风不可用：$error';
      _isRunning = false;
    });
  }

  // 显示权限申请对话框
  void _showPermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text('分贝测试需要使用麦克风，请在权限设置中允许。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶部应用栏
      appBar: AppBar(
        title: const Text('分贝测试仪'),
      ),
      // 主体内容
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // 顶部：分贝数值显示
              DecibelDisplay(
                decibel: _currentDb,
                isRunning: _isRunning,
              ),
              const SizedBox(height: 24),
              // 错误信息
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              // 中间：折线图
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: DecibelChart(data: List.unmodifiable(_history)),
                ),
              ),
              const SizedBox(height: 16),
              // 底部：控制按钮
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isRunning ? _stop : _start,
                  icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _isRunning ? '停止' : '开始测试',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isRunning ? Colors.red : Colors.indigo,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

## Task 11: 代码静态检查

**Files:**
- N/A (仅检查)

- [ ] **Step 11.1: 运行 Flutter Analyze**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter analyze
```

预期: 无 error（warning 可接受）。

- [ ] **Step 11.2: 处理常见问题**

如果出现 `withOpacity` 弃用警告（Flutter 3.27+ 推荐 `withValues`），统一替换为 `withValues(alpha: x.x)`，但 `.withOpacity(x)` 仍可用，本次保持原样不修改。

---

## Task 12: 构建 APK 验证

**Files:**
- N/A (仅构建)

- [ ] **Step 12.1: 构建 Debug APK**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter build apk --debug
```

预期: 成功生成 `build/app/outputs/flutter-apk/app-debug.apk`。

- [ ] **Step 12.2: 构建 Release APK（可选）**

```powershell
flutter build apk --release
```

预期: 生成 release 版 APK（仅在需要分发时构建）。

---

## 完成检查

- [ ] 首页能正常打开，GridView 显示"分贝测试仪"卡片
- [ ] 点击卡片跳转分贝测试页面
- [ ] 首次进入弹出麦克风权限申请
- [ ] 授权后点击"开始测试"，分贝数值实时变化
- [ ] 折线图持续滚动绘制
- [ ] 点击"停止"后停止采集，数值定格
- [ ] 离开页面后麦克风不再占用（后台无噪声）
- [ ] APK 构建成功

## 后续扩展提示

- 新增工具：只需在 `lib/pages/home_page.dart` 的 `_toolList` 中追加 `ToolItem`
- 如需保留历史记录：在 `_DecibelPageState` 中增加 `SharedPreferences` 或文件存储
