# 网速测试自定义目标 URL 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在网速测试页加入"自定义目标 URL"复选框 + 输入框，跨重启保留设置，默认目标改为 `https://www.baidu.com`。

**Architecture:** 新增 `NetworkSpeedSettings` 工具类负责 SharedPreferences 读写；`NetworkSpeedPage` 增加内联 Card（复选框 + TextField）+ 当前目标提示；`_runTest` 启动前对自定义 URL 走 `_validateUrl` 校验，失败 SnackBar 阻断。

**Tech Stack:** Flutter (StatefulWidget + setState), `shared_preferences` (已有), `http` (已有), `flutter_test` + `shared_preferences` mock for unit tests.

**Spec:** [2026-06-06-toolapp-networkspeed-customurl-design.md](../specs/2026-06-06-toolapp-networkspeed-customurl-design.md)

**当前版本：** 1.2.2+6 → 升级至 1.2.3+7

---

## File Structure

### 新增
- `lib/utils/network_speed_settings.dart` — 读写 SharedPreferences 中两个 key 的工具
- `test/network_speed_settings_test.dart` — 设置单元测试
- `test/network_speed_page_validate_test.dart` — URL 校验函数单元测试（通过 `@visibleForTesting` 暴露）

### 修改
- `lib/pages/network_speed_page.dart` — UI 新增 + 替换 `_kPingUrl` 派生 + 校验流程
- `pubspec.yaml` — bump `version: 1.2.2+6` → `1.2.3+7`

---

## Task 1: 新增 NetworkSpeedSettings 工具（先写测试）

**Files:**
- Create: `test/network_speed_settings_test.dart`
- Create: `lib/utils/network_speed_settings.dart`

- [ ] **Step 1.1: 写失败的测试**

`test/network_speed_settings_test.dart`：

```dart
// 网速测试设置读写工具测试
// 验证 SharedPreferences 中两个 key 的默认行为与持久化往返
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolapp/utils/network_speed_settings.dart';

void main() {
  // 每个 test 前清空 mock prefs，确保隔离
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load() 默认值：未持久化时返回 useCustom=false, url=空', () async {
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isFalse);
    expect(s.url, isEmpty);
  });

  test('save 后 load 应返回保存值', () async {
    await NetworkSpeedSettings.save(useCustom: true, url: 'https://example.com');
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://example.com');
  });

  test('save 只传 useCustom 不应清空 url', () async {
    await NetworkSpeedSettings.save(url: 'https://keep.com');
    await NetworkSpeedSettings.save(useCustom: true);
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://keep.com');
  });

  test('save 只传 url 不应修改 useCustom', () async {
    await NetworkSpeedSettings.save(useCustom: true);
    await NetworkSpeedSettings.save(url: 'https://updated.com');
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://updated.com');
  });
}
```

- [ ] **Step 1.2: 运行测试，确认失败（function not defined）**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter test test/network_speed_settings_test.dart
```

Expected: FAIL — `Target of URI doesn't exist: 'package:toolapp/utils/network_speed_settings.dart'`

- [ ] **Step 1.3: 实现 NetworkSpeedSettings**

`lib/utils/network_speed_settings.dart`：

```dart
// 网速测试用户设置读写工具
// 持久化两个字段：是否启用自定义目标 URL、自定义 URL 字符串
import 'package:shared_preferences/shared_preferences.dart';

/// 网速测试设置快照
typedef NetworkSpeedSettingsSnapshot = ({bool useCustom, String url});

/// 网速测试设置读写工具
class NetworkSpeedSettings {
  /// SharedPreferences 键：是否启用自定义目标
  static const String _kKeyUseCustom = 'networkspeed_use_custom_url';

  /// SharedPreferences 键：自定义目标 URL 字符串
  static const String _kKeyCustomUrl = 'networkspeed_custom_url';

  /// 从 SharedPreferences 读取设置
  /// 缺失字段时返回默认值：useCustom=false, url=''
  static Future<NetworkSpeedSettingsSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final useCustom = prefs.getBool(_kKeyUseCustom) ?? false;
    final url = prefs.getString(_kKeyCustomUrl) ?? '';
    return (useCustom: useCustom, url: url);
  }

  /// 写入设置；只持久化非 null 的字段，保留另一个字段的现有值
  static Future<void> save({bool? useCustom, String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    if (useCustom != null) {
      await prefs.setBool(_kKeyUseCustom, useCustom);
    }
    if (url != null) {
      await prefs.setString(_kKeyCustomUrl, url);
    }
  }
}
```

- [ ] **Step 1.4: 运行测试，确认通过**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter test test/network_speed_settings_test.dart
```

Expected: 4 tests PASS

- [ ] **Step 1.5: 运行 flutter analyze**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter analyze
```

Expected: No issues

---

## Task 2: 暴露 _validateUrl 并写测试

**Files:**
- Modify: `lib/pages/network_speed_page.dart` (加 `@visibleForTesting` 标记的顶级函数)
- Create: `test/network_speed_page_validate_test.dart`

- [ ] **Step 2.1: 写失败的测试**

`test/network_speed_page_validate_test.dart`：

```dart
// 网速测试 URL 校验函数测试
// 通过 @visibleForTesting 暴露的顶级函数 validateNetworkSpeedUrl 测试
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/pages/network_speed_page.dart';

void main() {
  group('validateNetworkSpeedUrl 合法用例', () {
    test('https 简单 URL', () {
      expect(validateNetworkSpeedUrl('https://www.baidu.com'), isNull);
    });
    test('http 带端口和路径', () {
      expect(validateNetworkSpeedUrl('http://example.com:8080/path?q=1'), isNull);
    });
    test('https 子域', () {
      expect(validateNetworkSpeedUrl('https://api.github.com/users'), isNull);
    });
  });

  group('validateNetworkSpeedUrl 非法用例', () {
    test('空字符串', () {
      expect(validateNetworkSpeedUrl(''), isNotNull);
    });
    test('仅空白', () {
      expect(validateNetworkSpeedUrl('   '), isNotNull);
    });
    test('无 scheme', () {
      expect(validateNetworkSpeedUrl('baidu.com'), isNotNull);
    });
    test('ftp scheme', () {
      expect(validateNetworkSpeedUrl('ftp://x.com'), isNotNull);
    });
    test('https 后无 host', () {
      expect(validateNetworkSpeedUrl('https://'), isNotNull);
    });
    test('含非法字符', () {
      expect(validateNetworkSpeedUrl('https://a b.com'), isNotNull);
    });
  });
}
```

- [ ] **Step 2.2: 运行测试，确认失败**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter test test/network_speed_page_validate_test.dart
```

Expected: FAIL — `validateNetworkSpeedUrl` not found

- [ ] **Step 2.3: 在 network_speed_page.dart 顶部添加顶级函数**

修改 [lib/pages/network_speed_page.dart](file:///h:/Mycode/Trae/Flutter/ToolApp/lib/pages/network_speed_page.dart) 第 6 行（import 之后、const 之前）插入：

```dart
import 'package:flutter/foundation.dart' show visibleForTesting;
```

并在 const `_kPingUrl` 之前插入：

```dart
/// 校验自定义 URL 合法性
/// 返回 null 表示通过；返回错误信息表示失败原因
/// 暴露为顶级函数以便单测；调用方为 [NetworkSpeedPage]
@visibleForTesting
String? validateNetworkSpeedUrl(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 'URL 不能为空';
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    return 'URL 必须以 http:// 或 https:// 开头';
  }
  Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return 'URL 格式不合法';
  }
  if (u.scheme != 'http' && u.scheme != 'https') {
    return 'URL 必须以 http:// 或 https:// 开头';
  }
  if (u.host.isEmpty) return 'URL 缺少主机名';
  return null;
}
```

- [ ] **Step 2.4: 运行测试，确认通过**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter test test/network_speed_page_validate_test.dart
```

Expected: 9 tests PASS

- [ ] **Step 2.5: 运行 flutter analyze**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter analyze
```

Expected: No issues

---

## Task 3: 改造 NetworkSpeedPage - 状态/常量/初始化

**Files:**
- Modify: `lib/pages/network_speed_page.dart`（仅修改，不新增 widget 代码）

- [ ] **Step 3.1: 替换默认 URL 常量**

将第 6 行：
```dart
const String _kPingUrl = 'https://httpbin.org/get';
```
改为：
```dart
const String _kDefaultUrl = 'https://www.baidu.com';
```

- [ ] **Step 3.2: 在 _NetworkSpeedPageState 增加字段**

在 `http.Client? _client;` 之前插入：

```dart
/// 是否启用自定义目标 URL
bool _useCustomUrl = false;

/// 自定义目标 URL 字符串
String _customUrl = '';

/// TextField 控制器
final TextEditingController _urlController = TextEditingController();
```

- [ ] **Step 3.3: 在 initState 加载设置，dispose 释放 controller**

将现有 `initState` 改为：

```dart
@override
void initState() {
  super.initState();
  _client = http.Client();
  _loadSettings();
}

Future<void> _loadSettings() async {
  final s = await NetworkSpeedSettings.load();
  if (!mounted) return;
  setState(() {
    _useCustomUrl = s.useCustom;
    _customUrl = s.url;
    _urlController.text = _customUrl;
  });
}
```

将现有 `dispose` 改为：

```dart
@override
void dispose() {
  _cancelled = true;
  _urlController.dispose();
  _client?.close();
  super.dispose();
}
```

- [ ] **Step 3.4: 增加 _resolveTargetUrl 私有方法**

放在 `_runTest` 之前：

```dart
/// 解析当前应使用的目标 URL：勾选且 URL 非空时用自定义值，否则用默认值
String _resolveTargetUrl() {
  return _useCustomUrl && _customUrl.isNotEmpty ? _customUrl : _kDefaultUrl;
}
```

- [ ] **Step 3.5: 修改 _runTest 入口增加校验并使用派生 target**

将 `_runTest` 方法签名与开头的重置保持不变，但在 for 循环之前、调用 `_client!.head(...)` 处将：

```dart
await _client!.head(Uri.parse(_kPingUrl)).timeout(_kRequestTimeout);
```

改为：

```dart
final target = _resolveTargetUrl();
if (_useCustomUrl) {
  final err = validateNetworkSpeedUrl(_customUrl);
  if (err != null) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
    }
    AppLogger.w('NetworkSpeedPage', '自定义 URL 校验失败：$err');
    return;
  }
}
// ... 此处保留重置逻辑 ...
// for 循环里改为 await _client!.head(Uri.parse(target)).timeout(_kRequestTimeout);
```

完整新 `_runTest` 如下（替换整个方法）：

```dart
Future<void> _runTest() async {
  // 自定义模式下先校验
  if (_useCustomUrl) {
    final err = validateNetworkSpeedUrl(_customUrl);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
      AppLogger.w('NetworkSpeedPage', '自定义 URL 校验失败：$err');
      return;
    }
  }
  final target = _resolveTargetUrl();

  // 重置状态
  setState(() {
    _status = _Status.running;
    _samples.clear();
    _completedCount = 0;
    _currentLatency = null;
    _stats = null;
    _errorMessage = null;
    _cancelled = false;
  });
  AppLogger.i('NetworkSpeedPage', '开始测速 target=$target');

  // 串行 10 次请求
  for (var i = 0; i < _kTotalSamples; i++) {
    if (_cancelled) break;
    _stopwatch
      ..reset()
      ..start();
    try {
      await _client!.head(Uri.parse(target)).timeout(_kRequestTimeout);
      _stopwatch.stop();
      final ms = _stopwatch.elapsedMilliseconds;
      _samples.add(ms);
      if (mounted) {
        setState(() {
          _currentLatency = ms;
          _completedCount = _samples.length;
        });
      }
    } catch (e) {
      _stopwatch.stop();
      _samples.add(null);
      if (mounted) {
        setState(() {
          _completedCount = _samples.length;
        });
      }
      AppLogger.w('NetworkSpeedPage', '第 ${i + 1} 次请求失败：$e');
    }
    if (i < _kTotalSamples - 1) {
      await Future.delayed(_kSampleInterval);
    }
  }

  if (!mounted) return;

  final stats = NetworkSpeedHistory.computeStats(_samples);
  _stats = stats;

  if (_cancelled) {
    _saveRecord(stats, target);
    setState(() => _status = _Status.done);
    AppLogger.i('NetworkSpeedPage', '用户中途停止，已保存');
  } else if (_samples.every((s) => s == null)) {
    setState(() {
      _status = _Status.error;
      _errorMessage = '网络不可达，请检查连接后重试';
    });
    AppLogger.w('NetworkSpeedPage', '10 次请求全部失败');
  } else {
    _saveRecord(stats, target);
    setState(() => _status = _Status.done);
    AppLogger.i('NetworkSpeedPage',
        '测速完成 avg=${stats.avg}ms loss=${stats.lossRate}');
  }
}
```

- [ ] **Step 3.6: 修改 _saveRecord 接受 target 参数**

将 `_saveRecord` 改为：

```dart
Future<void> _saveRecord(PingRecordStats stats, String target) async {
  try {
    final record = PingRecord(
      timestamp: DateTime.now(),
      server: target,
      samples: List<int?>.from(_samples),
      min: stats.min,
      avg: stats.avg,
      max: stats.max,
      jitter: stats.jitter,
      lossRate: stats.lossRate,
    );
    await NetworkSpeedHistory.save(record);
  } catch (e) {
    AppLogger.e('NetworkSpeedPage', '保存历史失败', e);
  }
}
```

- [ ] **Step 3.7: 运行 flutter analyze**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter analyze
```

Expected: No issues

---

## Task 4: 改造 NetworkSpeedPage - UI（仪表盘上方加 Card + 当前目标提示）

**Files:**
- Modify: `lib/pages/network_speed_page.dart` (`build` 方法 + 新增 widget)

- [ ] **Step 4.1: 在 build 方法 Column 顶部插入新 widget**

将 build 方法 Column 改为：

```dart
child: Column(
  children: [
    _buildCustomUrlCard(),
    _buildCurrentTargetLabel(),
    const SizedBox(height: 16),
    _buildGauge(),
    const SizedBox(height: 24),
    _buildProgressDots(),
    const SizedBox(height: 24),
    _buildStatsRow(),
    const Spacer(),
    if (_status == _Status.error && _errorMessage != null)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.red),
        ),
      ),
    _buildControlButton(),
    const SizedBox(height: 8),
  ],
),
```

并删除原 `const SizedBox(height: 24),` 顶部那行。

- [ ] **Step 4.2: 在 `_buildGauge` 之前新增 _buildCustomUrlCard 与 _buildCurrentTargetLabel**

```dart
/// 自定义目标 URL 设置卡：复选框 + 输入框
Widget _buildCustomUrlCard() {
  return Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: _useCustomUrl,
            onChanged: (v) async {
              final newVal = v ?? false;
              // 兜底保存未失焦的输入
              setState(() {
                _customUrl = _urlController.text.trim();
                _useCustomUrl = newVal;
              });
              await NetworkSpeedSettings.save(
                useCustom: newVal,
                url: _customUrl,
              );
            },
          ),
          const Text('自定义目标'),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _urlController,
              enabled: _useCustomUrl,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'https://...',
                isDense: true,
                counterText: '',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onEditingComplete: () async {
                setState(() => _customUrl = _urlController.text.trim());
                await NetworkSpeedSettings.save(
                  useCustom: _useCustomUrl,
                  url: _customUrl,
                );
                FocusScope.of(context).unfocus();
              },
              onSubmitted: (v) async {
                setState(() => _customUrl = v.trim());
                await NetworkSpeedSettings.save(
                  useCustom: _useCustomUrl,
                  url: _customUrl,
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// 当前生效目标 host 提示
Widget _buildCurrentTargetLabel() {
  final url = _resolveTargetUrl();
  String host;
  try {
    host = Uri.parse(url).host;
  } catch (_) {
    host = url;
  }
  if (host.isEmpty) host = url;
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '当前目标: $host',
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    ),
  );
}
```

- [ ] **Step 4.3: 运行 flutter analyze**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter analyze
```

Expected: No issues

---

## Task 5: 升级版本号

**Files:**
- Modify: `pubspec.yaml` (line 15)

- [ ] **Step 5.1: 替换 version 字段**

将 `version: 1.2.2+6` 改为 `version: 1.2.3+7`

- [ ] **Step 5.2: 运行 flutter pub get 验证**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter pub get
```

Expected: 成功，无错误

---

## Task 6: 跑全量测试

- [ ] **Step 6.1: 运行所有单元与 widget 测试**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter test
```

Expected: 全部通过（原有 widget_test + 4 settings + 9 validate + 后续 widget test）

- [ ] **Step 6.2: 运行 flutter analyze**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter analyze
```

Expected: No issues

---

## Task 7: 打包并安装到手机

- [ ] **Step 7.1: 确认手机连接**

```bash
adb devices
```

Expected: 输出一个 device 行（如 `f29a7eb9        device`）

- [ ] **Step 7.2: 构建 release APK**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp && flutter build apk --release
```

Expected: `✓ Built build\app\outputs\flutter-apk\app-release.apk (47.6MB)`

- [ ] **Step 7.3: 安装到手机**

```bash
adb install -r h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\flutter-apk\app-release.apk
```

Expected: `Success`

---

## Task 8: 手动验证（请用户操作）

请用户在手机端：
1. 打开"实用工具箱"App
2. 进入"网速测试"
3. 验证默认状态：复选框未勾选、输入框置灰、提示"当前目标: www.baidu.com"
4. 点击"开始测试"，确认能正常测速（验证默认 URL 仍工作）
5. 勾选复选框，输入框启用
6. 输入 `https://www.example.com`，失焦
7. 点击"开始测试"，确认能测速且历史记录中显示 example.com
8. 输入 `baidu.com`（无 scheme），点击"开始测试"
   - 预期：SnackBar「URL 必须以 http:// 或 https:// 开头」，不进入测速
9. 输入 `https://`（无 host），点击"开始测试"
   - 预期：SnackBar「URL 缺少主机名」
10. 关闭 app，重新打开
    - 预期：复选框仍勾选、URL 仍为 example.com
11. 取消勾选，关闭 app，重新打开
    - 预期：复选框未勾选、URL 仍保留在输入框（即便置灰）

---

## Task 9: 清理（视情况）

本次实现没有引入调试插桩，无需清理。debug-netspeed-unreachable.md 已在上一轮修复时删除。

- [ ] **Step 9.1: 确认没有遗留文件**

```bash
ls h:\Mycode\Trae\Flutter\ToolApp\debug-*.md 2>$null
```

Expected: No such file

---

## 风险与回滚

- 若新功能在手机上引发崩溃，回滚命令：恢复本计划前 4 个文件的 git 状态（如未提交则用 IDE 撤销）。
- 关键文件：[lib/pages/network_speed_page.dart](file:///h:/Mycode/Trae/Flutter/ToolApp/lib/pages/network_speed_page.dart)，单点修改。
