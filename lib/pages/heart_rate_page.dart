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

/// 连接方式枚举
enum ConnectionMode {
  ble,  // BLE蓝牙低功耗
  udp,  // WiFi UDP
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
    _heartRateSubscription = _ble.heartRateStream.stream.listen(
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
    _heartRateSubscription = _udp!.heartRateStream.stream.listen(
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
