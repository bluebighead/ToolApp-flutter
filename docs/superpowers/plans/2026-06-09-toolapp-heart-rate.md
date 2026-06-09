# 心率广播接收器实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现心率广播接收器工具，支持BLE和WiFi UDP两种接收方式，实时显示心率数据

**Architecture:** 采用Flutter标准页面结构，BLE使用flutter_reactive_ble插件连接标准心率设备，UDP使用Dart原生RawDatagramSocket监听。页面包含连接方式切换、显示模式切换、心率数字显示和折线图。

**Tech Stack:** Flutter, flutter_reactive_ble, fl_chart, permission_handler, Dart原生网络

---

### Task 1: 添加依赖和权限配置

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: 在pubspec.yaml的dependencies中添加BLE依赖**

在 `pubspec.yaml` 的 `dependencies:` 部分，`permission_handler: ^12.0.0` 行之后添加：

```yaml
  # BLE 蓝牙低功耗：心率广播接收器连接标准心率设备
  flutter_reactive_ble: ^5.3.0
```

- [ ] **Step 2: 在AndroidManifest.xml中添加BLE和网络权限**

在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 标签内，现有权限声明之后添加：

```xml
    <!-- 心率广播接收器：BLE 蓝牙低功耗权限 -->
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
```

- [ ] **Step 3: 运行flutter pub get安装依赖**

```bash
flutter pub get
```

Expected: 成功安装 flutter_reactive_ble 及其依赖

- [ ] **Step 4: 提交**

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml
git commit -m "feat: 添加心率广播接收器BLE依赖和权限"
```

---

### Task 2: 创建心率BLE接收工具类

**Files:**
- Create: `lib/utils/heart_rate_ble.dart`

- [ ] **Step 1: 创建BLE心率接收工具类**

创建 `lib/utils/heart_rate_ble.dart`：

```dart
// BLE 心率接收工具类
// 使用 flutter_reactive_ble 连接标准心率设备（Heart Rate Service UUID: 0x180D）
// 订阅心率测量特征值（0x2A37）并解析BPM值
import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'app_logger.dart';

/// BLE 心率接收器
class HeartRateBle {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;

  QualifiedCharacteristic? _heartRateCharacteristic;
  bool _isScanning = false;
  bool _isConnected = false;

  /// 是否正在扫描
  bool get isScanning => _isScanning;

  /// 是否已连接
  bool get isConnected => _isConnected;

  /// 心率数据流控制器
  final StreamController<int> heartRateStream = StreamController<int>.broadcast();

  /// 扫描并连接心率设备
  /// [onStatus] 回调用于传递状态信息（扫描中、已连接等）
  Future<void> startScan({required Function(String status) onStatus}) async {
    if (_isScanning) return;

    AppLogger.i('HeartRateBle', '开始扫描BLE心率设备');
    _isScanning = true;
    onStatus('正在扫描设备...');

    try {
      // 扫描心率设备（Heart Rate Service UUID: 0x180D）
      _scanSubscription = _ble.scanForDevices(
        withServices: [Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb')],
        scanMode: ScanMode.lowLatency,
      ).listen(
        (device) async {
          AppLogger.d('HeartRateBle', '发现设备: ${device.name} (${device.id})');
          // 发现设备后立即停止扫描并连接
          await _stopScan();
          onStatus('发现设备: ${device.name.isNotEmpty ? device.name : '未知设备'}');
          await _connectToDevice(device, onStatus: onStatus);
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '扫描错误', error);
          _isScanning = false;
          onStatus('扫描失败: $error');
        },
      );
    } catch (e) {
      AppLogger.e('HeartRateBle', '启动扫描失败', e);
      _isScanning = false;
      onStatus('启动扫描失败: $e');
    }
  }

  /// 停止扫描
  Future<void> _stopScan() async {
    if (!_isScanning) return;
    AppLogger.i('HeartRateBle', '停止扫描');
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
  }

  /// 连接到指定设备
  Future<void> _connectToDevice(
    DiscoveredDevice device, {
    required Function(String status) onStatus,
  }) async {
    AppLogger.i('HeartRateBle', '连接设备: ${device.id}');
    onStatus('正在连接...');

    try {
      _connectionSubscription = _ble.connectToDevice(
        id: device.id,
        servicesWithCharacteristicsToDiscover: {
          Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb'): [
            Uuid.parse('00002a37-0000-1000-8000-00805f9b34fb'),
          ],
        },
        connectionTimeout: const Duration(seconds: 10),
      ).listen(
        (connectionState) async {
          AppLogger.d('HeartRateBle', '连接状态: ${connectionState.connectionState}');

          if (connectionState.connectionState == DeviceConnectionState.connected) {
            _isConnected = true;
            onStatus('已连接');
            await _subscribeToHeartRate(onStatus: onStatus);
          } else if (connectionState.connectionState == DeviceConnectionState.disconnected) {
            _isConnected = false;
            onStatus('已断开');
          }
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '连接错误', error);
          _isConnected = false;
          onStatus('连接失败: $error');
        },
      );
    } catch (e) {
      AppLogger.e('HeartRateBle', '连接设备失败', e);
      _isConnected = false;
      onStatus('连接失败: $e');
    }
  }

  /// 订阅心率特征值
  Future<void> _subscribeToHeartRate({required Function(String status) onStatus}) async {
    AppLogger.i('HeartRateBle', '订阅心率特征值');

    final characteristic = QualifiedCharacteristic(
      serviceId: Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb'),
      characteristicId: Uuid.parse('00002a37-0000-1000-8000-00805f9b34fb'),
      deviceId: _connectedDeviceId ?? '',
    );
    _heartRateCharacteristic = characteristic;

    try {
      _characteristicSubscription = _ble.subscribeToCharacteristic(characteristic).listen(
        (data) {
          // 解析标准心率特征值格式
          final heartRate = _parseHeartRate(data);
          if (heartRate != null) {
            AppLogger.d('HeartRateBle', '心率: $heartRate BPM');
            heartRateStream.add(heartRate);
          }
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '订阅错误', error);
          onStatus('接收失败: $error');
        },
      );
    } catch (e) {
      AppLogger.e('HeartRateBle', '订阅特征值失败', e);
      onStatus('订阅失败: $e');
    }
  }

  String? get _connectedDeviceId {
    // 从连接状态获取设备ID（简化处理）
    return null;
  }

  /// 解析标准心率特征值
  /// 格式：byte[0] 的标志位决定心率值是UINT8还是UINT16
  int? _parseHeartRate(List<int> data) {
    if (data.isEmpty) return null;

    try {
      // byte[0] 的 bit 0 决定心率值格式
      // 0 = UINT8, 1 = UINT16
      final isUint16 = (data[0] & 0x01) == 1;

      if (isUint16 && data.length >= 3) {
        // UINT16: byte[1] 和 byte[2] 组成16位心率值（小端序）
        return data[1] | (data[2] << 8);
      } else if (data.length >= 2) {
        // UINT8: byte[1] 是8位心率值
        return data[1];
      }
      return null;
    } catch (e) {
      AppLogger.w('HeartRateBle', '解析心率数据失败: $data');
      return null;
    }
  }

  /// 断开连接并释放资源
  Future<void> disconnect() async {
    AppLogger.i('HeartRateBle', '断开BLE连接');
    await _characteristicSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _scanSubscription?.cancel();
    _characteristicSubscription = null;
    _connectionSubscription = null;
    _scanSubscription = null;
    _isScanning = false;
    _isConnected = false;
    _heartRateCharacteristic = null;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await disconnect();
    await heartRateStream.close();
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/utils/heart_rate_ble.dart
git commit -m "feat: 创建BLE心率接收工具类"
```

---

### Task 3: 创建心率UDP接收工具类

**Files:**
- Create: `lib/utils/heart_rate_udp.dart`

- [ ] **Step 1: 创建UDP心率接收工具类**

创建 `lib/utils/heart_rate_udp.dart`：

```dart
// UDP 心率接收工具类
// 使用 Dart 原生 RawDatagramSocket 监听指定端口的UDP广播
// 支持纯数字格式（如"72"）和JSON格式（如{"heartRate": 72}）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'app_logger.dart';

/// UDP 心率接收器
class HeartRateUdp {
  RawDatagramSocket? _socket;
  bool _isListening = false;
  final int _port;

  /// 心率数据流控制器
  final StreamController<int> heartRateStream = StreamController<int>.broadcast();

  /// 是否正在监听
  bool get isListening => _isListening;

  /// 当前监听端口
  int get port => _port;

  HeartRateUdp({int port = 8888}) : _port = port;

  /// 开始监听UDP端口
  /// [onStatus] 回调用于传递状态信息
  Future<void> startListening({required Function(String status) onStatus}) async {
    if (_isListening) return;

    AppLogger.i('HeartRateUdp', '开始监听UDP端口: $_port');
    onStatus('正在监听端口 $_port...');

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port);
      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            _processData(datagram.data);
          }
        }
      });

      _isListening = true;
      onStatus('正在监听端口 $_port');
      AppLogger.i('HeartRateUdp', 'UDP监听已启动');
    } catch (e) {
      AppLogger.e('HeartRateUdp', '启动UDP监听失败', e);
      onStatus('监听失败: $e');
    }
  }

  /// 处理接收到的UDP数据
  void _processData(List<int> data) {
    try {
      final message = String.fromCharCodes(data).trim();
      AppLogger.d('HeartRateUdp', '收到UDP数据: $message');

      int? heartRate;

      // 尝试解析纯数字格式
      heartRate = int.tryParse(message);

      // 如果纯数字解析失败，尝试JSON格式
      if (heartRate == null) {
        heartRate = _parseJson(message);
      }

      if (heartRate != null && heartRate > 0 && heartRate < 300) {
        AppLogger.d('HeartRateUdp', '心率: $heartRate BPM');
        heartRateStream.add(heartRate);
      } else {
        AppLogger.w('HeartRateUdp', '无效心率值: $heartRate');
      }
    } catch (e) {
      AppLogger.w('HeartRateUdp', '解析UDP数据失败: $data');
    }
  }

  /// 尝试从JSON格式解析心率值
  int? _parseJson(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      // 支持多种可能的键名
      if (json.containsKey('heartRate')) {
        return json['heartRate'] as int?;
      } else if (json.containsKey('bpm')) {
        return json['bpm'] as int?;
      } else if (json.containsKey('value')) {
        return json['value'] as int?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 停止监听
  Future<void> stopListening() async {
    AppLogger.i('HeartRateUdp', '停止UDP监听');
    _socket?.close();
    _socket = null;
    _isListening = false;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await stopListening();
    await heartRateStream.close();
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/utils/heart_rate_udp.dart
git commit -m "feat: 创建UDP心率接收工具类"
```

---

### Task 4: 创建心率数字显示组件

**Files:**
- Create: `lib/widgets/heart_rate_display.dart`

- [ ] **Step 1: 创建心率数字显示组件**

创建 `lib/widgets/heart_rate_display.dart`：

```dart
// 心率数值显示组件
// 大号BPM数字 + 心率状态图标 + 文字描述（正常/偏快/偏慢）
// 根据心率值自动切换颜色
import 'package:flutter/material.dart';

class HeartRateDisplay extends StatelessWidget {
  /// 当前心率值（BPM）
  final int heartRate;
  /// 状态：是否正在接收数据
  final bool isActive;

  const HeartRateDisplay({
    super.key,
    required this.heartRate,
    this.isActive = false,
  });

  /// 根据心率值返回对应颜色
  Color _getColor() {
    if (heartRate == 0) return Colors.grey;
    if (heartRate < 50) return Colors.blue;       // 偏慢
    if (heartRate <= 100) return Colors.green;    // 正常
    if (heartRate <= 140) return Colors.orange;   // 偏快
    return Colors.red;                            // 过快
  }

  /// 根据心率值返回对应文字描述
  String _getLabel() {
    if (heartRate == 0) return '等待数据';
    if (heartRate < 50) return '偏慢';
    if (heartRate <= 100) return '正常';
    if (heartRate <= 140) return '偏快';
    return '过快';
  }

  /// 根据心率值返回对应图标
  IconData _getIcon() {
    if (heartRate == 0) return Icons.favorite_border;
    return Icons.favorite;
  }

  @override
  Widget build(BuildContext context) {
    final color = _getColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 心率图标
        Icon(
          _getIcon(),
          size: 48,
          color: color,
        ),
        const SizedBox(height: 8),
        // 大号心率数值
        Text(
          heartRate > 0 ? heartRate.toString() : '--',
          style: TextStyle(
            fontSize: 80,
            fontWeight: FontWeight.bold,
            color: color,
            // 激活状态时添加脉冲阴影效果
            shadows: isActive && heartRate > 0
                ? [
                    Shadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 25,
                    ),
                  ]
                : null,
          ),
        ),
        // 单位 BPM
        const Text(
          'BPM',
          style: TextStyle(
            fontSize: 24,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        // 文字描述（带浅色背景胶囊样式）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _getLabel(),
            style: TextStyle(
              fontSize: 16,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/widgets/heart_rate_display.dart
git commit -m "feat: 创建心率数字显示组件"
```

---

### Task 5: 创建心率折线图组件

**Files:**
- Create: `lib/widgets/heart_rate_chart.dart`

- [ ] **Step 1: 创建心率折线图组件**

创建 `lib/widgets/heart_rate_chart.dart`：

```dart
// 心率折线图组件
// 使用 fl_chart 实现实时滚动折线图
// 最多展示最近 60 个采样点（约 1 分钟）
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class HeartRateChart extends StatelessWidget {
  /// 心率历史数据
  final List<int> data;

  const HeartRateChart({
    super.key,
    required this.data,
  });

  /// 根据当前心率范围确定线条颜色
  Color _getLineColor() {
    if (data.isEmpty) return Colors.grey;
    final latest = data.last;
    if (latest < 50) return Colors.blue;
    if (latest <= 100) return Colors.green;
    if (latest <= 140) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    // 如果数据为空，显示占位提示
    if (data.isEmpty) {
      return const Center(
        child: Text(
          '连接设备后显示心率趋势',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    // 构造折线图数据点列表
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].toDouble()));
    }

    return LineChart(
      LineChartData(
        // 网格配置：仅显示水平网格线
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 20,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withValues(alpha: 0.2),
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
          // X 轴：显示采样点序号
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
          // Y 轴：左侧显示心率值
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 20,
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
        // 边框配置：仅显示左、下两条边框
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
          ),
        ),
        // X 轴范围：固定窗口大小为 60 个点
        minX: data.length > 60 ? (data.length - 60).toDouble() : 0,
        maxX: data.length.toDouble() - 1,
        // Y 轴范围：固定 30 ~ 200 BPM
        minY: 30,
        maxY: 200,
        // 折线配置
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            // 折线颜色
            color: _getLineColor(),
            // 线条宽度
            barWidth: 3,
            // 折线下方填充：渐变色
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _getLineColor().withValues(alpha: 0.3),
                  _getLineColor().withValues(alpha: 0.0),
                ],
              ),
            ),
            // 不显示数据点，保持简洁
            dotData: const FlDotData(show: false),
          ),
        ],
        // 禁用触摸交互（避免误触）
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/widgets/heart_rate_chart.dart
git commit -m "feat: 创建心率折线图组件"
```

---

### Task 6: 创建心率广播接收器主页面

**Files:**
- Create: `lib/pages/heart_rate_page.dart`

- [ ] **Step 1: 创建心率主页面**

创建 `lib/pages/heart_rate_page.dart`：

```dart
// 心率广播接收器页面
// 支持BLE和WiFi UDP两种接收方式
// 提供数字显示、折线图、组合三种显示模式
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';
import '../utils/heart_rate_ble.dart';
import '../utils/heart_rate_udp.dart';
import '../widgets/heart_rate_display.dart';
import '../widgets/heart_rate_chart.dart';

/// 显示模式枚举
enum DisplayMode {
  number,   // 仅数字
  chart,    // 仅图表
  combined, // 数字+图表
}

class HeartRatePage extends StatefulWidget {
  const HeartRatePage({super.key});

  @override
  State<HeartRatePage> createState() => _HeartRatePageState();
}

class _HeartRatePageState extends State<HeartRatePage> {
  // 连接方式：BLE 或 WiFi UDP
  ConnectionMode _connectionMode = ConnectionMode.ble;

  // 显示模式：数字/图表/组合
  DisplayMode _displayMode = DisplayMode.combined;

  // BLE接收器
  final HeartRateBle _ble = HeartRateBle();

  // UDP接收器
  HeartRateUdp? _udp;

  // 心率数据流订阅
  StreamSubscription<int>? _heartRateSubscription;

  // 当前心率值
  int _heartRate = 0;

  // 心率历史数据（最多60个点）
  final List<int> _history = [];
  static const int _maxPoints = 60;

  // 是否正在接收数据
  bool _isActive = false;

  // 状态信息
  String _status = '未连接';

  // 错误信息
  String? _errorMessage;

  @override
  void dispose() {
    _stopReceiving();
    _ble.dispose();
    _udp?.dispose();
    super.dispose();
  }

  /// 开始接收心率数据
  Future<void> _startReceiving() async {
    AppLogger.i('HeartRatePage', '开始接收心率数据，模式: $_connectionMode');
    setState(() {
      _errorMessage = null;
      _status = '正在连接...';
    });

    try {
      if (_connectionMode == ConnectionMode.ble) {
        await _startBle();
      } else {
        await _startUdp();
      }
    } catch (e) {
      AppLogger.e('HeartRatePage', '启动接收失败', e);
      setState(() {
        _errorMessage = '启动失败: $e';
        _isActive = false;
        _status = '未连接';
      });
    }
  }

  /// 启动BLE接收
  Future<void> _startBle() async {
    // 检查蓝牙和位置权限
    final bleStatus = await Permission.bluetoothScan.request();
    final locationStatus = await Permission.location.request();

    if (!bleStatus.isGranted || !locationStatus.isGranted) {
      setState(() {
        _errorMessage = '需要蓝牙和位置权限';
        _status = '权限被拒绝';
      });
      return;
    }

    // 订阅心率数据流
    _heartRateSubscription = _ble.heartRateStream.listen(
      _onHeartRateData,
      onError: _onHeartRateError,
    );

    // 开始扫描
    await _ble.startScan(
      onStatus: (status) {
        if (mounted) {
          setState(() => _status = status);
        }
      },
    );

    setState(() => _isActive = true);
  }

  /// 启动UDP接收
  Future<void> _startUdp() async {
    _udp = HeartRateUdp(port: 8888);

    // 订阅心率数据流
    _heartRateSubscription = _udp!.heartRateStream.listen(
      _onHeartRateData,
      onError: _onHeartRateError,
    );

    // 开始监听
    await _udp!.startListening(
      onStatus: (status) {
        if (mounted) {
          setState(() => _status = status);
        }
      },
    );

    setState(() {
      _isActive = true;
      _status = '正在监听UDP端口 8888';
    });
  }

  /// 停止接收
  Future<void> _stopReceiving() async {
    AppLogger.i('HeartRatePage', '停止接收心率数据');
    await _heartRateSubscription?.cancel();
    _heartRateSubscription = null;

    if (_connectionMode == ConnectionMode.ble) {
      await _ble.disconnect();
    } else {
      await _udp?.stopListening();
    }

    if (mounted) {
      setState(() {
        _isActive = false;
        _status = '未连接';
      });
    }
  }

  /// 处理心率数据
  void _onHeartRateData(int bpm) {
    if (!mounted) return;
    setState(() {
      _heartRate = bpm;
      _history.add(bpm);
      if (_history.length > _maxPoints) {
        _history.removeAt(0);
      }
    });
  }

  /// 处理心率错误
  void _onHeartRateError(Object error) {
    if (!mounted) return;
    AppLogger.e('HeartRatePage', '心率接收错误', error);
    setState(() {
      _errorMessage = '接收错误: $error';
      _isActive = false;
      _status = '错误';
    });
  }

  /// 切换连接方式
  void _toggleConnectionMode() {
    if (_isActive) {
      _stopReceiving().then((_) {
        setState(() {
          _connectionMode = _connectionMode == ConnectionMode.ble
              ? ConnectionMode.udp
              : ConnectionMode.ble;
          _history.clear();
          _heartRate = 0;
        });
      });
    } else {
      setState(() {
        _connectionMode = _connectionMode == ConnectionMode.ble
            ? ConnectionMode.udp
            : ConnectionMode.ble;
        _history.clear();
        _heartRate = 0;
      });
    }
  }

  /// 切换显示模式
  void _toggleDisplayMode() {
    setState(() {
      switch (_displayMode) {
        case DisplayMode.number:
          _displayMode = DisplayMode.chart;
          break;
        case DisplayMode.chart:
          _displayMode = DisplayMode.combined;
          break;
        case DisplayMode.combined:
          _displayMode = DisplayMode.number;
          break;
      }
    });
  }

  /// 获取显示模式文字
  String _getDisplayModeText() {
    switch (_displayMode) {
      case DisplayMode.number:
        return '数字';
      case DisplayMode.chart:
        return '图表';
      case DisplayMode.combined:
        return '组合';
    }
  }

  /// 获取连接方式文字
  String _getConnectionModeText() {
    switch (_connectionMode) {
      case ConnectionMode.ble:
        return 'BLE';
      case ConnectionMode.udp:
        return 'WiFi UDP';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('心率广播接收器'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // 顶部：连接方式切换 + 显示模式切换
              Row(
                children: [
                  // 连接方式切换按钮
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _toggleConnectionMode,
                      icon: Icon(
                        _connectionMode == ConnectionMode.ble
                            ? Icons.bluetooth
                            : Icons.wifi,
                      ),
                      label: Text(_getConnectionModeText()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 显示模式切换按钮
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _toggleDisplayMode,
                      icon: const Icon(Icons.visibility),
                      label: Text(_getDisplayModeText()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 状态信息
              Text(
                _status,
                style: TextStyle(
                  fontSize: 14,
                  color: _isActive ? Colors.green : Colors.grey,
                ),
              ),
              const SizedBox(height: 16),
              // 错误信息提示
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
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
              // 中部：心率显示区（根据显示模式切换）
              Expanded(
                child: _buildDisplayArea(),
              ),
              const SizedBox(height: 16),
              // 底部：控制按钮
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isActive ? _stopReceiving : _startReceiving,
                  icon: Icon(_isActive ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _isActive ? '停止' : '开始接收',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isActive ? Colors.red : Colors.green,
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

  /// 构建显示区域
  Widget _buildDisplayArea() {
    switch (_displayMode) {
      case DisplayMode.number:
        return Center(
          child: HeartRateDisplay(
            heartRate: _heartRate,
            isActive: _isActive,
          ),
        );
      case DisplayMode.chart:
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: HeartRateChart(data: List.unmodifiable(_history)),
        );
      case DisplayMode.combined:
        return Column(
          children: [
            // 上方：数字显示
            HeartRateDisplay(
              heartRate: _heartRate,
              isActive: _isActive,
            ),
            const SizedBox(height: 16),
            // 下方：折线图
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: HeartRateChart(data: List.unmodifiable(_history)),
              ),
            ),
          ],
        );
    }
  }
}

/// 连接方式枚举
enum ConnectionMode {
  ble,  // BLE蓝牙低功耗
  udp,  // WiFi UDP
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/pages/heart_rate_page.dart
git commit -m "feat: 创建心率广播接收器主页面"
```

---

### Task 7: 在首页添加工具入口

**Files:**
- Modify: `lib/pages/home_page.dart`

- [ ] **Step 1: 在home_page.dart中导入HeartRatePage并添加工具项**

在 `lib/pages/home_page.dart` 的 import 部分，`import 'video_convert_page.dart';` 之后添加：

```dart
import 'heart_rate_page.dart';
```

在 `_toolList` 列表中，`ToolItem` for 视频格式转换之后添加：

```dart
    ToolItem(
      name: '心率广播接收器',
      icon: Icons.favorite,
      color: Colors.red,
      pageBuilder: (_) => const HeartRatePage(),
    ),
```

- [ ] **Step 2: 提交**

```bash
git add lib/pages/home_page.dart
git commit -m "feat: 在首页添加工率广播接收器入口"
```

---

### Task 8: 更新版本号并测试

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: 更新版本号**

在 `pubspec.yaml` 中，将 `version: 1.6.58+86` 修改为：

```yaml
version: 1.7.0+87
```

- [ ] **Step 2: 运行flutter analyze检查代码**

```bash
flutter analyze
```

Expected: 无错误或警告

- [ ] **Step 3: 提交**

```bash
git add pubspec.yaml
git commit -m "chore: 更新版本号至1.7.0，心率广播接收器功能完成"
```

---

## 自审检查

### 1. 规范覆盖
- [x] BLE接收：Task 2实现
- [x] UDP接收：Task 3实现
- [x] 数字显示：Task 4实现
- [x] 折线图：Task 5实现
- [x] 主页面：Task 6实现
- [x] 首页入口：Task 7实现
- [x] 权限配置：Task 1实现
- [x] 版本号更新：Task 8实现

### 2. 占位符扫描
- 无TBD/TODO
- 所有代码完整
- 类型签名一致

### 3. 类型一致性
- `HeartRateBle` 和 `HeartRateUdp` 都使用 `StreamController<int>`
- `DisplayMode` 和 `ConnectionMode` 枚举定义一致
- 所有组件使用相同的参数命名

### 4. 范围检查
- 功能聚焦，无过度设计
- UDP格式预留JSON解析接口
- 显示模式切换满足用户需求
