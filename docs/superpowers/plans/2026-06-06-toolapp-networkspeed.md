# 工具箱 App - 网速测试（Ping 延迟）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在工具箱 App 中新增"网速测试"工具，使用 `http` 包对 `httpbin.org` 进行 10 次 HEAD 请求测延迟，并支持本地历史记录（最多 20 条）。

**Architecture:** 单 Flutter 项目；网速测试主页为独立 StatefulWidget 子页面，通过串行 HTTP HEAD + Stopwatch 测量延迟；历史记录使用 `SharedPreferences` 以 JSON 数组形式持久化；历史列表页从主页 AppBar 图标进入。

**Tech Stack:** Flutter 3.41.4 (Dart 3.11.1) · `http` ^1.2.0 · `shared_preferences` ^2.2.2

**注释约定:** 所有 Dart 代码注释使用中文（遵循用户规则）。

**关联文档:**
- 设计文档: `docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md`

---

## Task 1: 添加 http 依赖

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\pubspec.yaml`

- [ ] **Step 1.1: 编辑 pubspec.yaml**

在 `dependencies:` 块下增加（`shared_preferences` 已有，仅新增 `http`）:

```yaml
  # 网速测试：HTTP 客户端
  http: ^1.2.0
```

完整 `dependencies` 块示例:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  noise_meter: ^5.1.0
  fl_chart: ^0.68.0
  permission_handler: ^12.0.0
  shared_preferences: ^2.2.2
  # 网速测试：HTTP 客户端
  http: ^1.2.0
```

- [ ] **Step 1.2: 安装依赖**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter pub get
```

预期: `Got dependencies!` 无错误。

---

## Task 2: 创建 PingRecord 模型与历史读写工具

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\utils\network_speed_history.dart`

- [ ] **Step 2.1: 编写完整文件内容**

```dart
// 网速测试历史记录工具
// 负责 PingRecord 的 JSON 序列化、SharedPreferences 持久化、容量裁剪、统计计算
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 单次测速记录
class PingRecord {
  /// 测速时间（本地时区）
  final DateTime timestamp;

  /// 测速服务器 URL
  final String server;

  /// 原始样本（毫秒），null 表示丢包
  final List<int?> samples;

  /// 最小有效延迟（毫秒）
  final int min;

  /// 平均有效延迟（毫秒）
  final int avg;

  /// 最大有效延迟（毫秒）
  final int max;

  /// 相邻样本差绝对值的平均（毫秒）
  final int jitter;

  /// 丢包率 0.0 ~ 1.0
  final double lossRate;

  PingRecord({
    required this.timestamp,
    required this.server,
    required this.samples,
    required this.min,
    required this.avg,
    required this.max,
    required this.jitter,
    required this.lossRate,
  });

  /// 序列化为 JSON Map
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'server': server,
        'samples': samples.map((s) => s).toList(),
        'min': min,
        'avg': avg,
        'max': max,
        'jitter': jitter,
        'lossRate': lossRate,
      };

  /// 从 JSON Map 反序列化
  factory PingRecord.fromJson(Map<String, dynamic> json) {
    final raw = (json['samples'] as List).cast<dynamic>();
    return PingRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      server: json['server'] as String,
      samples: raw.map((e) => e == null ? null : e as int).toList(),
      min: json['min'] as int,
      avg: json['avg'] as int,
      max: json['max'] as int,
      jitter: json['jitter'] as int,
      lossRate: (json['lossRate'] as num).toDouble(),
    );
  }
}

/// 历史记录读写工具
class NetworkSpeedHistory {
  /// SharedPreferences 键名
  static const String _key = 'network_speed_history';

  /// 最大保存条数
  static const int _maxRecords = 20;

  /// 保存一条记录：序列化、追加、裁剪、写回
  static Future<void> save(PingRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    // 读取现有记录
    final existing = await loadAll();
    // 追加新记录
    existing.insert(0, record);
    // 裁剪到 _maxRecords 条
    final trimmed = existing.take(_maxRecords).toList();
    // 序列化为 JSON 字符串
    final jsonList = trimmed.map((r) => r.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    // 写回 SharedPreferences
    await prefs.setString(_key, jsonString);
  }

  /// 读取全部记录：按 timestamp 倒序（最新在前）
  static Future<List<PingRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_key);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((e) => PingRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 解析失败视为空
      return [];
    }
  }

  /// 清空全部记录
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// 从原始样本计算统计指标
  /// 返回 (min, avg, max, jitter, lossRate)
  /// 全部为 null 时所有统计项均返回 0，lossRate 返回 1.0
  static PingRecordStats computeStats(List<int?> samples) {
    if (samples.isEmpty) {
      return PingRecordStats(min: 0, avg: 0, max: 0, jitter: 0, lossRate: 1.0);
    }
    final valid = samples.whereType<int>().toList();
    final loss = (samples.length - valid.length) / samples.length;
    if (valid.isEmpty) {
      return PingRecordStats(min: 0, avg: 0, max: 0, jitter: 0, lossRate: loss);
    }
    final min = valid.reduce((a, b) => a < b ? a : b);
    final max = valid.reduce((a, b) => a > b ? a : b);
    final sum = valid.reduce((a, b) => a + b);
    final avg = (sum / valid.length).round();
    // 抖动：相邻样本差绝对值的平均
    int jitter = 0;
    if (valid.length >= 2) {
      var jitterSum = 0;
      for (var i = 1; i < valid.length; i++) {
        jitterSum += (valid[i] - valid[i - 1]).abs();
      }
      jitter = (jitterSum / (valid.length - 1)).round();
    }
    return PingRecordStats(
      min: min,
      avg: avg,
      max: max,
      jitter: jitter,
      lossRate: loss,
    );
  }
}

/// 统计指标聚合
class PingRecordStats {
  final int min;
  final int avg;
  final int max;
  final int jitter;
  final double lossRate;

  const PingRecordStats({
    required this.min,
    required this.avg,
    required this.max,
    required this.jitter,
    required this.lossRate,
  });
}
```

- [ ] **Step 2.2: 验证无编译错误**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter analyze lib/utils/network_speed_history.dart
```

预期: `No issues found!`

---

## Task 3: 创建网速测试主页 NetworkSpeedPage

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\pages\network_speed_page.dart`

- [ ] **Step 3.1: 编写完整文件内容**

```dart
// 网速测试主页
// 状态：idle / running / done / error
// 串行 HEAD 请求 10 次（间隔 1s，每次超时 3s）测延迟，统计 min/avg/max/jitter/loss
// 完成时通过 NetworkSpeedHistory 保存记录
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import '../utils/network_speed_history.dart';
import 'network_speed_history_page.dart';

/// 测速目标 URL
const String _kPingUrl = 'https://httpbin.org/get';

/// 采样次数
const int _kTotalSamples = 10;

/// 每次请求超时
const Duration _kRequestTimeout = Duration(seconds: 3);

/// 采样间隔
const Duration _kSampleInterval = Duration(seconds: 1);

/// 测速状态
enum _Status { idle, running, done, error }

class NetworkSpeedPage extends StatefulWidget {
  const NetworkSpeedPage({super.key});

  @override
  State<NetworkSpeedPage> createState() => _NetworkSpeedPageState();
}

class _NetworkSpeedPageState extends State<NetworkSpeedPage> {
  /// 当前状态
  _Status _status = _Status.idle;

  /// 最近一次有效延迟（毫秒），null 表示无数据
  int? _currentLatency;

  /// 原始样本：null 表示丢包
  final List<int?> _samples = [];

  /// 已完成样本数（用于进度点）
  int _completedCount = 0;

  /// 用户中途停止标志
  bool _cancelled = false;

  /// 错误信息
  String? _errorMessage;

  /// 缓存的统计结果
  PingRecordStats? _stats;

  /// HTTP 客户端
  http.Client? _client;

  /// 单次计时器
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _client = http.Client();
  }

  @override
  void dispose() {
    // 页面销毁：设取消标志、关闭 HTTP 客户端
    _cancelled = true;
    _client?.close();
    super.dispose();
  }

  /// 主测速流程
  Future<void> _runTest() async {
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
    AppLogger.i('NetworkSpeedPage', '开始测速');

    // 串行 10 次请求
    for (var i = 0; i < _kTotalSamples; i++) {
      if (_cancelled) break;
      _stopwatch
        ..reset()
        ..start();
      try {
        await _client!.head(Uri.parse(_kPingUrl)).timeout(_kRequestTimeout);
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
      // 最后一次不等待
      if (i < _kTotalSamples - 1) {
        await Future.delayed(_kSampleInterval);
      }
    }

    if (!mounted) return;

    // 计算统计
    final stats = NetworkSpeedHistory.computeStats(_samples);
    _stats = stats;

    // 状态判定
    if (_cancelled) {
      // 用户中途停止：保存为 done（哪怕 0 样本）
      _saveRecord(stats);
      setState(() => _status = _Status.done);
      AppLogger.i('NetworkSpeedPage', '用户中途停止，已保存');
    } else if (_samples.every((s) => s == null)) {
      // 10 次全失败
      setState(() {
        _status = _Status.error;
        _errorMessage = '网络不可达，请检查连接后重试';
      });
      AppLogger.w('NetworkSpeedPage', '10 次请求全部失败');
    } else {
      _saveRecord(stats);
      setState(() => _status = _Status.done);
      AppLogger.i('NetworkSpeedPage',
          '测速完成 avg=${stats.avg}ms loss=${stats.lossRate}');
    }
  }

  /// 保存到历史
  Future<void> _saveRecord(PingRecordStats stats) async {
    try {
      final record = PingRecord(
        timestamp: DateTime.now(),
        server: _kPingUrl,
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

  /// 用户主动停止
  void _stop() {
    AppLogger.i('NetworkSpeedPage', '用户点击停止');
    setState(() => _cancelled = true);
  }

  /// 进入历史页面
  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NetworkSpeedHistoryPage()),
    );
  }

  /// 根据延迟返回颜色
  Color _latencyColor(int? ms) {
    if (ms == null) return Colors.grey;
    if (ms < 50) return Colors.green;
    if (ms < 100) return Colors.blue;
    if (ms < 200) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网速测试'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '测速历史',
            onPressed: _openHistory,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const SizedBox(height: 24),
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
        ),
      ),
    );
  }

  /// 仪表盘：大号延迟数字
  Widget _buildGauge() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _currentLatency?.toString() ?? '--',
            style: TextStyle(
              fontSize: 80,
              fontWeight: FontWeight.bold,
              color: _latencyColor(_currentLatency),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'ms',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// 进度点：10 个圆点
  Widget _buildProgressDots() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: List.generate(_kTotalSamples, (i) {
        Color color;
        if (i < _completedCount) {
          // 已完成（含丢包）
          color = Colors.green;
        } else if (i == _completedCount && _status == _Status.running) {
          // 正在请求中
          color = Colors.amber;
        } else {
          color = Colors.grey.shade300;
        }
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }

  /// 统计行：5 个数字卡
  Widget _buildStatsRow() {
    final stats = _stats;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _StatCard(label: '最小', value: stats?.min.toString() ?? '--', unit: 'ms'),
        _StatCard(label: '平均', value: stats?.avg.toString() ?? '--', unit: 'ms'),
        _StatCard(label: '最大', value: stats?.max.toString() ?? '--', unit: 'ms'),
        _StatCard(label: '抖动', value: stats?.jitter.toString() ?? '--', unit: 'ms'),
        _StatCard(
          label: '丢包',
          value: stats == null ? '--' : (stats.lossRate * 100).round().toString(),
          unit: '%',
        ),
      ],
    );
  }

  /// 控制按钮
  Widget _buildControlButton() {
    final (text, onPressed) = switch (_status) {
      _Status.idle => ('开始测试', _runTest),
      _Status.running => ('停止', _stop),
      _Status.done => ('重新测试', _runTest),
      _Status.error => ('重试', _runTest),
    };
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: onPressed,
        child: Text(text, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

/// 统计数字卡
class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.black),
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3.2: 验证无编译错误**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter analyze lib/pages/network_speed_page.dart
```

预期: `No issues found!`

---

## Task 4: 创建网速测试历史列表页 NetworkSpeedHistoryPage

**Files:**
- Create: `h:\Mycode\Trae\Flutter\ToolApp\lib\pages\network_speed_history_page.dart`

- [ ] **Step 4.1: 编写完整文件内容**

```dart
// 网速测试历史列表页
// 从 SharedPreferences 读取历史记录，按时间倒序展示
// 点击行弹底部弹层显示完整详情
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'package:flutter/material.dart';
import '../utils/app_logger.dart';
import '../utils/network_speed_history.dart';

class NetworkSpeedHistoryPage extends StatefulWidget {
  const NetworkSpeedHistoryPage({super.key});

  @override
  State<NetworkSpeedHistoryPage> createState() =>
      _NetworkSpeedHistoryPageState();
}

class _NetworkSpeedHistoryPageState extends State<NetworkSpeedHistoryPage> {
  late Future<List<PingRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = NetworkSpeedHistory.loadAll();
  }

  /// 重新加载
  void _reload() {
    setState(() {
      _future = NetworkSpeedHistory.loadAll();
    });
  }

  /// 清空确认
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定要清空所有测速历史吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkSpeedHistory.clear();
      AppLogger.i('NetworkSpeedHistoryPage', '已清空历史');
      _reload();
    }
  }

  /// 弹出详情
  void _showDetail(PingRecord record) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PingDetailSheet(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('测速历史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: FutureBuilder<List<PingRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = snapshot.data ?? [];
          if (records.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 12),
                  Text(
                    '暂无测速记录',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '完成一次测速即可查看历史',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = records[index];
              return ListTile(
                leading: const Icon(Icons.network_check),
                title: Text(_formatTime(r.timestamp)),
                subtitle: Text(_hostOf(r.server)),
                trailing: Text(
                  '${r.avg}ms · ${(r.lossRate * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () => _showDetail(r),
              );
            },
          );
        },
      ),
    );
  }

  /// 时间格式：yyyy-MM-dd HH:mm
  String _formatTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 提取 URL 主机部分
  String _hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isEmpty ? url : uri.host;
    } catch (_) {
      return url;
    }
  }
}

/// 详情底部弹层
class _PingDetailSheet extends StatelessWidget {
  final PingRecord record;

  const _PingDetailSheet({required this.record});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '测速详情',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _detailRow('时间', record.timestamp.toIso8601String().substring(0, 19)),
            _detailRow('服务器', record.server),
            const Divider(),
            const SizedBox(height: 8),
            _detailRow('最小', '${record.min} ms'),
            _detailRow('平均', '${record.avg} ms'),
            _detailRow('最大', '${record.max} ms'),
            _detailRow('抖动', '${record.jitter} ms'),
            _detailRow('丢包', '${(record.lossRate * 100).round()} %'),
            const SizedBox(height: 12),
            const Text(
              '原始样本',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: record.samples
                  .map((s) => Chip(
                        label: Text(s == null ? '--' : '${s}ms'),
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4.2: 验证无编译错误**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter analyze lib/pages/network_speed_history_page.dart
```

预期: `No issues found!`

---

## Task 5: 接入首页工具列表

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\lib\pages\home_page.dart`

- [ ] **Step 5.1: 在文件顶部 import 中追加**

在 `import 'decibel_page.dart';` 之后追加:

```dart
import 'network_speed_page.dart';
```

- [ ] **Step 5.2: 在 _toolList 末尾追加新工具项**

定位到 `_toolList` 列表末尾（`ToolItem(...DecibelPage(),),` 之后），在列表闭合 `];` 之前追加:

```dart
    ToolItem(
      name: '网速测试',
      icon: Icons.network_check,
      color: Colors.teal,
      pageBuilder: (_) => const NetworkSpeedPage(),
    ),
```

完整 `_toolList` 应当为:

```dart
  static final List<ToolItem> _toolList = [
    ToolItem(
      name: '分贝测试仪',
      icon: Icons.graphic_eq,
      color: Colors.indigo,
      pageBuilder: (_) => const DecibelPage(),
    ),
    ToolItem(
      name: '网速测试',
      icon: Icons.network_check,
      color: Colors.teal,
      pageBuilder: (_) => const NetworkSpeedPage(),
    ),
  ];
```

- [ ] **Step 5.3: 验证整体无编译错误**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter analyze
```

预期: `No issues found!` 或仅有原有 warning（无新增 error）。

---

## Task 6: 更新项目版本号

**Files:**
- Modify: `h:\Mycode\Trae\Flutter\ToolApp\pubspec.yaml`

- [ ] **Step 6.1: 提升 patch 版本号**

将 `version: 1.2.0+4` 改为 `version: 1.2.1+5`（新增"网速测试"功能，patch +1，build +1）。

修改后该行:

```yaml
version: 1.2.1+5
```

---

## Task 7: 手动功能测试

- [ ] **Step 7.1: 启动 App 进行验证**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter run
```

预期: App 启动，首页网格显示"分贝测试仪"和"网速测试"两个工具。

- [ ] **Step 7.2: 测试网速测试主页**

点击"网速测试"卡片，验证:
- 进入网速测试页
- 仪表盘显示 `--`
- 点击"开始测试"按钮
- 进度点依次亮起（共 10 个，约 10 秒）
- 仪表盘数字随每次请求更新
- 完成后 5 个统计卡（最小/平均/最大/抖动/丢包）显示具体数值
- 按钮变为"重新测试"
- 关闭飞行模式 / 断开网络后再次测试，验证 10 次全失败后显示"网络不可达"和"重试"按钮

- [ ] **Step 7.3: 测试中途停止**

测速中点击"停止"按钮，验证:
- 立即停止（不再等待剩余间隔）
- 仪表盘和统计卡显示已收集样本的统计
- 状态切到 `done`，按钮变为"重新测试"

- [ ] **Step 7.4: 测试历史记录**

点击 AppBar 右上角历史图标，验证:
- 进入历史页，列表显示刚才的测速记录（按时间倒序）
- 点击列表行，弹出详情底部弹层
- 弹层显示完整时间戳、URL、5 项统计、原始样本
- 返回 AppBar 点"清空"，确认后列表清空

- [ ] **Step 7.5: 停止调试运行**

回到终端按 `q` 退出 `flutter run`。

---

## Task 8: 打包 Release APK

- [ ] **Step 8.1: 构建 Release APK**

```powershell
cd h:\Mycode\Trae\Flutter\ToolApp
flutter build apk --release
```

预期: 构建成功，输出 `build\app\outputs\flutter-apk\app-release.apk`。

- [ ] **Step 8.2: 验证 APK 生成**

```powershell
Test-Path h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\flutter-apk\app-release.apk
```

预期: `True`

---

## Task 9: 检查手机连接并安装 APK

- [ ] **Step 9.1: 检查 ADB 设备**

```powershell
adb devices
```

预期: 至少一行设备列表，形如 `xxx device`。

- [ ] **Step 9.2: 安装 APK**

```powershell
adb install -r h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\flutter-apk\app-release.apk
```

预期: `Success`

---

## Task 10: 清理旧 APK 文件

- [ ] **Step 10.1: 查找 APK 副本**

```powershell
Get-ChildItem h:\Mycode\Trae\Flutter\ToolApp\build -Recurse -Filter *.apk
```

预期: 仅列出当前新构建的 `app-release.apk`。

- [ ] **Step 10.2: 删除非当前 APK 副本**

若有同名/不同名的旧 APK（如 `app-release-1.apk` 或上次构建残留），删除：

```powershell
# 仅在发现旧 APK 时执行，示例：
Remove-Item h:\Mycode\Trae\Flutter\ToolApp\build\app\outputs\apk\release\app-release.apk -Force
```

若 `build\app\outputs\flutter-apk\app-release.apk` 之外还有其他 APK，手动删除。

预期: 仅保留当前新构建的 APK 文件。

---

## 自检

- [x] **Spec 覆盖**：5 个 spec 章节（架构/状态机/测速逻辑/历史/UI）均有对应 Task
- [x] **类型一致**：`PingRecord` 字段、`NetworkSpeedHistory.save/loadAll/clear/computeStats` 方法签名、状态枚举 `_Status`、`_StatCard` 私有类在引入处与使用处名称一致
- [x] **无占位符**：所有步骤包含完整代码
- [x] **用户规则**：所有新增 Dart 代码注释为中文
- [x] **项目规范**：包含版本号更新、APK 打包、手机安装、旧 APK 清理四个步骤
