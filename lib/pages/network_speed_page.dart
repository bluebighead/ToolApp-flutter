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
import '../utils/network_speed_settings.dart';
import '../utils/network_speed_utils.dart';
import '../widgets/network_speed_dial.dart';
import '../widgets/network_speed_line_chart.dart';
import 'network_speed_history_page.dart';

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

/// 可用 URL scheme 列表
const List<String> _kAvailableSchemes = ['https://', 'http://'];

/// 默认 scheme
const String _kDefaultScheme = 'https://';

/// 解析 URL 文本对应的 scheme，未识别返回 null
/// 暴露为顶级函数以便单测；调用方为 [NetworkSpeedPage]
@visibleForTesting
String? detectScheme(String text) {
  for (final s in _kAvailableSchemes) {
    if (text.startsWith(s)) return s;
  }
  return null;
}

/// 应用 scheme 到 URL 文本：
/// - 空文本 -> 返回 scheme
/// - 已以 http:// 或 https:// 开头 -> 替换为指定 scheme
/// - 否则 -> 前缀 scheme
/// 暴露为顶级函数以便单测；调用方为 [NetworkSpeedPage]
@visibleForTesting
String applySchemeToUrl(String currentText, String scheme) {
  assert(_kAvailableSchemes.contains(scheme), 'scheme 必须是 $_kAvailableSchemes 之一');
  if (currentText.isEmpty) return scheme;
  final existing = detectScheme(currentText);
  if (existing != null) {
    return scheme + currentText.substring(existing.length);
  }
  return scheme + currentText;
}

/// 测速目标 URL（默认）
const String _kDefaultUrl = 'https://www.baidu.com';

/// 采样次数
const int _kTotalSamples = 10;

/// 每次请求超时
const Duration _kRequestTimeout = Duration(seconds: 3);

/// 采样间隔
const Duration _kSampleInterval = Duration(seconds: 1);

/// 测速状态
enum _Status { idle, running, done, error }

/// 仪表盘显示模式
enum _DisplayMode {
  /// 大号数字
  digital,

  /// 半圆 0~1000ms 圆盘指针
  dial,

  /// 折线图（本次 10 个采样）
  chart,
}

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

  /// 是否启用自定义目标 URL
  bool _useCustomUrl = false;

  /// 自定义目标 URL 字符串
  String _customUrl = '';

  /// 当前 scheme 下拉框选中值
  String _scheme = _kDefaultScheme;

  /// TextField 控制器
  final TextEditingController _urlController = TextEditingController();

  /// 当前显示模式
  _DisplayMode _displayMode = _DisplayMode.digital;

  /// HTTP 客户端
  http.Client? _client;

  /// 单次计时器
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _client = http.Client();
    _loadSettings();
  }

  /// 从 SharedPreferences 加载自定义 URL 与显示模式设置
  Future<void> _loadSettings() async {
    final s = await NetworkSpeedSettings.load();
    if (!mounted) return;
    // 从已保存的 URL 反推 scheme（默认 https://）
    final detected = detectScheme(s.url) ?? _kDefaultScheme;
    // 显示模式越界钳位到 [0, length-1]
    final modeIndex =
        s.displayMode.clamp(0, _DisplayMode.values.length - 1);
    setState(() {
      _useCustomUrl = s.useCustom;
      _customUrl = s.url;
      _scheme = detected;
      _urlController.text = _customUrl;
      _displayMode = _DisplayMode.values[modeIndex];
    });
  }

  @override
  void dispose() {
    // 页面销毁：设取消标志、关闭 HTTP 客户端
    _cancelled = true;
    _urlController.dispose();
    _client?.close();
    super.dispose();
  }

  /// 解析当前应使用的目标 URL：勾选且 URL 非空时用自定义值，否则用默认值
  String _resolveTargetUrl() {
    return _useCustomUrl && _customUrl.isNotEmpty ? _customUrl : _kDefaultUrl;
  }

  /// 主测速流程
  Future<void> _runTest() async {
    // 1. 同步输入框文本到 _customUrl（用户可能在输入后未提交就点开始）
    //    不同则刷新"当前目标"显示并持久化，确保测的是用户最新输入的网址
    if (_useCustomUrl) {
      final newUrl = _urlController.text.trim();
      if (newUrl != _customUrl) {
        setState(() => _customUrl = newUrl);
        await NetworkSpeedSettings.save(
          useCustom: _useCustomUrl,
          url: newUrl,
        );
        AppLogger.i('NetworkSpeedPage', '已同步自定义 URL -> $newUrl');
      }
    }
    if (!mounted) return;

    // 2. 自定义模式下校验 URL
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
      _saveRecord(stats, target);
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
      _saveRecord(stats, target);
      setState(() => _status = _Status.done);
      AppLogger.i('NetworkSpeedPage',
          '测速完成 avg=${stats.avg}ms loss=${stats.lossRate}');
    }
  }

  /// 保存到历史
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网速测试'),
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
            itemBuilder: (_) => [
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
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildCustomUrlCard(),
              _buildCurrentTargetLabel(),
              const SizedBox(height: 16),
              _buildDisplay(),
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

  /// 自定义目标 URL 设置卡：
  /// 第 1 行 = 复选框 + 标签
  /// 第 2 行 = scheme 下拉 + URL 输入框（让输入框占据几乎全部宽度，避免被压短）
  Widget _buildCustomUrlCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第 1 行：开关
            Row(
              children: [
                Checkbox(
                  value: _useCustomUrl,
                  onChanged: (v) async {
                    final newVal = v ?? false;
                    // 勾选时若输入框为空，自动填入当前 scheme
                    String text = _urlController.text.trim();
                    if (newVal && text.isEmpty) {
                      text = _scheme;
                      _urlController.text = text;
                      _urlController.selection = TextSelection.collapsed(
                        offset: text.length,
                      );
                    }
                    setState(() {
                      _customUrl = text;
                      _useCustomUrl = newVal;
                    });
                    await NetworkSpeedSettings.save(
                      useCustom: newVal,
                      url: _customUrl,
                    );
                  },
                ),
                const Text('自定义目标'),
              ],
            ),
            // 第 2 行：scheme 下拉 + URL 输入框
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 4, bottom: 4),
              child: Row(
                children: [
                  // Scheme 下拉框：点击即可快速切换 https:// 或 http://
                  DropdownButton<String>(
                    value: _scheme,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    items: _kAvailableSchemes
                        .map(
                          (s) => DropdownMenuItem<String>(
                            value: s,
                            child: Text(
                              s,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _useCustomUrl
                        ? (v) {
                            if (v == null || v == _scheme) return;
                            final newText = applySchemeToUrl(
                              _urlController.text,
                              v,
                            );
                            _urlController.text = newText;
                            _urlController.selection = TextSelection.collapsed(
                              offset: newText.length,
                            );
                            setState(() {
                              _scheme = v;
                              _customUrl = newText.trim();
                            });
                            NetworkSpeedSettings.save(
                              useCustom: _useCustomUrl,
                              url: _customUrl,
                            );
                          }
                        : null,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      enabled: _useCustomUrl,
                      maxLength: 500,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        hintText: 'example.com',
                        isDense: true,
                        counterText: '',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      // 用户手动输入时，实时反推 scheme
                      onChanged: (v) {
                        final detected = detectScheme(v);
                        if (detected != null && detected != _scheme) {
                          setState(() => _scheme = detected);
                        }
                      },
                      onEditingComplete: () async {
                        setState(() => _customUrl = _urlController.text.trim());
                        await NetworkSpeedSettings.save(
                          useCustom: _useCustomUrl,
                          url: _customUrl,
                        );
                        if (!mounted) return;
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

  /// 数显：大号延迟数字
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

/// 显示模式菜单项：Radio + 文字 + 图标
/// 当前选中项的 Radio 实心
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
    return RadioGroup<_DisplayMode>(
      groupValue: current,
      onChanged: (v) {
        if (v != null) Navigator.of(context).pop(v);
      },
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Radio<_DisplayMode>(value: mode),
        title: Text(label),
        trailing: Icon(icon, size: 18, color: Colors.grey),
      ),
    );
  }
}
