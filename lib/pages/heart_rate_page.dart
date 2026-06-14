// 心率广播接收器页面
// 支持BLE和WiFi UDP两种接收方式
// 提供数字显示、折线图、组合三种显示模式
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';
import '../utils/heart_rate_ble.dart';
import '../utils/heart_rate_history.dart';
import '../utils/heart_rate_udp.dart';
import '../widgets/heart_rate_display.dart';
import '../widgets/heart_rate_chart.dart';
import 'heart_rate_history_page.dart';

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
  DisplayMode _displayMode = DisplayMode.number;

  // BLE接收器
  final HeartRateBle _ble = HeartRateBle();

  // UDP接收器
  HeartRateUdp? _udp;

  // 心率数据流订阅
  StreamSubscription<int>? _heartRateSubscription;

  // 设备列表流订阅
  StreamSubscription<List<ScannedDevice>>? _devicesSubscription;

  // 当前心率值
  int _heartRate = 0;

  // 心率历史数据（最多60个点）
  final List<int> _history = [];
  static const int _maxPoints = 60;

  // 是否正在接收数据（已连接并接收心率）
  bool _isActive = false;

  // 是否正在扫描设备
  bool _isScanning = false;

  // 扫描到的设备列表
  List<ScannedDevice> _scannedDevices = [];

  // 状态信息
  String _status = '未连接';

  // 错误信息
  String? _errorMessage;

  // 记忆设备ID（缓存，用于UI标记"上次连接"的设备）
  String? _memoryDeviceId;

  // 会话数据收集：用于保存历史记录
  // 当前会话的所有心率采样值
  final List<int> _sessionData = [];
  // 当前会话开始时间（毫秒），null 表示未开始
  int? _sessionStartTimeMs;

  // 节流：限制心率UI刷新频率 BPM 更新
  DateTime _lastBpmUiUpdate = DateTime(2000);
  static const Duration _bpmUiThrottle = Duration(milliseconds: 200); // 5fps 上限

  // 节流：限制 BLE 扫描结果 UI 刷新频率
  DateTime _lastScanUiUpdate = DateTime(2000);
  static const Duration _scanUiThrottle = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    // 订阅设备列表更新（节流：限制刷新频率）
    _devicesSubscription = _ble.devicesStream.stream.listen(
      (devices) {
        if (!mounted) return;
        _scannedDevices = devices;
        final now = DateTime.now();
        if (now.difference(_lastScanUiUpdate) >= _scanUiThrottle) {
          _lastScanUiUpdate = now;
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    // 页面销毁时保存会话数据（如果正在接收中退出页面）
    _saveSessionToHistory();
    // 先取消页面层的订阅，防止BLE/UDP关闭stream后仍收到回调
    _heartRateSubscription?.cancel();
    _heartRateSubscription = null;
    _devicesSubscription?.cancel();
    _devicesSubscription = null;
    // 释放BLE和UDP资源（disconnect/stopScan是async但dispose中无法await，
    // 在dispose中同步调用确保资源尽快释放）
    _ble.dispose();
    _udp?.dispose();
    _udp = null;
    super.dispose();
  }

  /// 开始接收心率数据
  Future<void> _startReceiving() async {
    AppLogger.i('HeartRatePage', '开始接收心率数据，模式: $_connectionMode');
    setState(() {
      _errorMessage = null;
      _status = '准备中...';
    });

    // 重置会话数据收集
    _sessionData.clear();
    _sessionStartTimeMs = DateTime.now().millisecondsSinceEpoch;

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
        _isScanning = false;
        _status = '未连接';
      });
    }
  }

  /// 启动BLE接收
  Future<void> _startBle() async {
    // 检查蓝牙和位置权限（Android 12+需要bluetoothScan和bluetoothConnect）
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    final locationStatus = await Permission.location.request();

    if (!scanStatus.isGranted || !connectStatus.isGranted || !locationStatus.isGranted) {
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

    // 检查是否有记忆设备，有则尝试自动连接
    final memoryDevice = await _ble.getLastConnectedDevice();

    if (memoryDevice != null) {
      // 有记忆设备，尝试自动连接
      _memoryDeviceId = memoryDevice['id'];
      await _ble.autoConnectLastDevice(
        onStatus: (status) {
          if (mounted) {
            setState(() {
              _status = status;
              // 自动连接成功时，更新扫描和激活状态
              if (status == '已连接') {
                _isScanning = false;
                _isActive = true;
              }
            });
          }
        },
        onDeviceFound: () {
          if (mounted) {
            setState(() {
              _status = '找到记忆设备，正在连接...';
            });
          }
        },
      );
      setState(() {
        _isScanning = true;
      });
    } else {
      // 无记忆设备，保持原有行为（扫描等待用户选择）
      await _ble.startScan(
        onStatus: (status) {
          if (mounted) {
            setState(() => _status = status);
          }
        },
      );
      setState(() {
        _isScanning = true;
      });
    }
  }

  /// 启动UDP接收
  Future<void> _startUdp() async {
    // 释放旧的UDP实例，避免内存泄漏
    await _udp?.dispose();
    _udp = null;

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

    // 保存会话数据到历史记录（至少有1个采样点才保存）
    _saveSessionToHistory();

    await _heartRateSubscription?.cancel();
    _heartRateSubscription = null;

    if (_connectionMode == ConnectionMode.ble) {
      await _ble.disconnect();
      await _ble.stopScan();
    } else {
      await _udp?.dispose();
      _udp = null;
    }

    if (mounted) {
      setState(() {
        _isActive = false;
        _isScanning = false;
        _memoryDeviceId = null;
        _heartRate = 0; // 断开连接后心率归零
        _history.clear(); // 清空历史数据
        _scannedDevices.clear(); // 清空扫描设备列表
        _status = '未连接';
      });
    }
  }

  /// 保存当前会话数据到历史记录
  void _saveSessionToHistory() {
    if (_sessionData.isEmpty || _sessionStartTimeMs == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final maxBpm = _sessionData.reduce((a, b) => a > b ? a : b);
    final minBpm = _sessionData.reduce((a, b) => a < b ? a : b);
    final avgBpm = (_sessionData.reduce((a, b) => a + b) / _sessionData.length).round();

    final record = HeartRateRecord(
      id: _sessionStartTimeMs!,
      startTimeMs: _sessionStartTimeMs!,
      endTimeMs: now,
      maxBpm: maxBpm,
      minBpm: minBpm,
      avgBpm: avgBpm,
      samples: _sessionData.length,
      connectionMode: _connectionMode == ConnectionMode.ble
          ? HeartRateConnectionMode.ble
          : HeartRateConnectionMode.udp,
    );

    HeartRateHistory.add(record);
    AppLogger.i('HeartRatePage', '保存心率历史记录: avg=$avgBpm, samples=${_sessionData.length}');

    // 清空会话数据
    _sessionData.clear();
    _sessionStartTimeMs = null;
  }

  /// 显示扫描列表弹窗
  Future<void> _showDeviceList() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _buildDeviceListSheet(),
    );
  }

  /// 构建设备列表弹窗
  Widget _buildDeviceListSheet() {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Text(
                  '扫描到的设备',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                // 刷新按钮
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  onPressed: () {
                    // 重新扫描
                    _ble.stopScan().then((_) {
                      setState(() => _scannedDevices.clear());
                      _ble.startScan(
                        onStatus: (status) {
                          if (mounted) {
                            setState(() => _status = status);
                          }
                        },
                      );
                    });
                  },
                ),
                // 关闭按钮
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // 设备列表
          if (_scannedDevices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(Icons.bluetooth_disabled, size: 48, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    '暂无设备\n请确保心率设备已开启广播',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _scannedDevices.length,
                itemBuilder: (context, index) {
                  final device = _scannedDevices[index];
                  final isConnected = _ble.connectedDeviceId == device.id;

                  return ListTile(
                    leading: Icon(
                      isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                      color: isConnected ? Colors.green : Colors.blue,
                    ),
                    title: Text(device.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ID: ${device.id}\n信号强度: ${device.rssi} dBm',
                          style: const TextStyle(fontSize: 12),
                        ),
                        // 标记上次连接的设备
                        if (_ble.connectedDeviceId != device.id &&
                            _memoryDeviceId != null &&
                            device.id == _memoryDeviceId)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '上次连接',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    trailing: isConnected
                        ? OutlinedButton.icon(
                            onPressed: () async {
                              // 断开连接时取消心率数据流订阅，避免收到残留数据
                              await _heartRateSubscription?.cancel();
                              _heartRateSubscription = null;
                              // 断开连接
                              await _ble.disconnect();
                              if (!mounted) return;
                              setState(() {
                                _isActive = false;
                                _isScanning = true;
                                _status = '已断开，继续扫描...';
                              });
                              // 断开后重新订阅心率数据流并开始扫描
                              _heartRateSubscription = _ble.heartRateStream.stream.listen(
                                _onHeartRateData,
                                onError: _onHeartRateError,
                              );
                              _ble.startScan(
                                onStatus: (status) {
                                  if (mounted) {
                                    setState(() => _status = status);
                                  }
                                },
                              );
                              // ignore: use_build_context_synchronously
                              if (mounted) Navigator.of(context).pop();
                            },
                            icon: const Icon(Icons.cancel, size: 16),
                            label: const Text('断开'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: () async {
                              // 连接设备
                              Navigator.pop(context);
                              try {
                                await _ble.connectToDevice(
                                  device.id,
                                  onStatus: (status) {
                                    if (mounted) {
                                      setState(() {
                                        _status = status;
                                        if (status == '已连接') {
                                          _isActive = true;
                                          _isScanning = false;
                                        }
                                      });
                                    }
                                  },
                                );
                              } catch (e) {
                                // 连接失败时重置UI状态，避免卡在"停止扫描"
                                AppLogger.e('HeartRatePage', '连接设备失败', e);
                                if (mounted) {
                                  setState(() {
                                    _isActive = false;
                                    _isScanning = false;
                                    _status = '连接失败: $e';
                                    _errorMessage = '连接失败: $e';
                                  });
                                }
                              }
                            },
                            icon: const Icon(Icons.link, size: 16),
                            label: const Text('连接'),
                          ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 处理心率数据
  void _onHeartRateData(int bpm) {
    if (!mounted) return;
    // 收集会话数据用于历史记录
    _sessionData.add(bpm);
    _history.add(bpm);
    if (_history.length > _maxPoints) {
      _history.removeAt(0);
    }
    // 节流：限制 UI 刷新频率，避免 BPM 数据触发过度重建
    final now = DateTime.now();
    if (now.difference(_lastBpmUiUpdate) >= _bpmUiThrottle) {
      _lastBpmUiUpdate = now;
      setState(() {
        _heartRate = bpm;
      });
    }
  }

  /// 处理心率错误
  void _onHeartRateError(Object error) {
    if (!mounted) return;
    AppLogger.e('HeartRatePage', '心率接收错误', error);
    setState(() {
      _errorMessage = '接收错误: $error';
      _isActive = false;
      _isScanning = false;
      _status = '错误';
    });
  }

  /// 切换连接方式（下拉框回调）
  void _onConnectionModeChanged(ConnectionMode? mode) {
    if (mode == null || mode == _connectionMode) return;
    if (_isActive || _isScanning) {
      _stopReceiving().then((_) {
        setState(() {
          _connectionMode = mode;
          _history.clear();
          _heartRate = 0;
          _scannedDevices.clear();
        });
      });
    } else {
      setState(() {
        _connectionMode = mode;
        _history.clear();
        _heartRate = 0;
        _scannedDevices.clear();
      });
    }
  }

  /// 切换显示模式（下拉框回调）
  void _onDisplayModeChanged(DisplayMode? mode) {
    if (mode == null) return;
    setState(() {
      _displayMode = mode;
    });
  }

  /// 显示使用说明对话框
  void _showUsageDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline),
            SizedBox(width: 8),
            Text('使用说明'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildUsageSection(
                'BLE蓝牙连接',
                [
                  '1. 点击"开始接收"，系统会自动扫描附近的BLE心率设备',
                  '2. 如果之前连接过设备，会自动尝试连接记忆设备',
                  '3. 在弹出的设备列表中选择要连接的心率设备',
                  '4. 连接成功后即可实时接收心率数据',
                ],
              ),
              const Divider(),
              _buildUsageSection(
                'WiFi UDP接收',
                [
                  '1. 切换到"WiFi UDP"连接方式',
                  '2. 点击"开始接收"，监听UDP端口8888',
                  '3. 确保心率设备在同一WiFi网络下发送数据',
                ],
              ),
              const Divider(),
              _buildUsageSection(
                '显示模式',
                [
                  '• 组合：同时显示数字和折线图（推荐）',
                  '• 数字：仅显示当前心率数值',
                  '• 图表：仅显示心率变化折线图',
                ],
              ),
              const Divider(),
              _buildUsageSection(
                '设备记忆功能',
                [
                  '• 首次连接成功后会自动记住设备',
                  '• 下次使用时自动扫描并连接记忆设备',
                  '• 设备未开机时会持续等待，开机后自动连接',
                  '• 手动选择其他设备会自动更新记忆',
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  /// 构建使用说明段落
  Widget _buildUsageSection(String title, List<String> lines) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('心率广播接收器'),
        actions: [
          // 历史记录按钮
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HeartRateHistoryPage()),
              );
            },
          ),
          // 使用说明按钮
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '使用说明',
            onPressed: _showUsageDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // 顶部：连接方式下拉框 + 显示模式下拉框
              Row(
                children: [
                  // 连接方式下拉框
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '连接方式',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        DropdownButton<ConnectionMode>(
                          isExpanded: true,
                          value: _connectionMode,
                          items: const [
                            DropdownMenuItem(
                              value: ConnectionMode.ble,
                              child: Row(
                                children: [
                                  Icon(Icons.bluetooth, size: 18),
                                  SizedBox(width: 8),
                                  Text('BLE蓝牙'),
                                ],
                              ),
                            ),
                            DropdownMenuItem(
                              value: ConnectionMode.udp,
                              child: Row(
                                children: [
                                  Icon(Icons.wifi, size: 18),
                                  SizedBox(width: 8),
                                  Text('WiFi UDP'),
                                ],
                              ),
                            ),
                          ],
                          onChanged: _onConnectionModeChanged,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 显示模式下拉框
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '显示模式',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        DropdownButton<DisplayMode>(
                          isExpanded: true,
                          value: _displayMode,
                          items: const [
                            DropdownMenuItem(
                              value: DisplayMode.combined,
                              child: Row(
                                children: [
                                  Icon(Icons.dashboard, size: 18),
                                  SizedBox(width: 8),
                                  Text('组合'),
                                ],
                              ),
                            ),
                            DropdownMenuItem(
                              value: DisplayMode.number,
                              child: Row(
                                children: [
                                  Icon(Icons.numbers, size: 18),
                                  SizedBox(width: 8),
                                  Text('数字'),
                                ],
                              ),
                            ),
                            DropdownMenuItem(
                              value: DisplayMode.chart,
                              child: Row(
                                children: [
                                  Icon(Icons.show_chart, size: 18),
                                  SizedBox(width: 8),
                                  Text('图表'),
                                ],
                              ),
                            ),
                          ],
                          onChanged: _onDisplayModeChanged,
                        ),
                      ],
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
                  color: _isActive ? Colors.green : (_isScanning ? Colors.orange : Colors.grey),
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
              Row(
                children: [
                  // 扫描列表按钮（仅BLE模式显示）
                  if (_connectionMode == ConnectionMode.ble)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isScanning || _scannedDevices.isNotEmpty
                            ? _showDeviceList
                            : null,
                        icon: const Icon(Icons.list),
                        label: const Text('扫描列表'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 56),
                        ),
                      ),
                    ),
                  if (_connectionMode == ConnectionMode.ble)
                    const SizedBox(width: 12),
                  // 开始/停止按钮
                  Expanded(
                    flex: _connectionMode == ConnectionMode.ble ? 2 : 1,
                    child: ElevatedButton.icon(
                      onPressed: (_isActive || _isScanning) ? _stopReceiving : _startReceiving,
                      icon: Icon(_isActive || _isScanning ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        _isScanning && !_isActive ? '停止扫描' : (_isActive ? '停止' : '开始接收'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (_isActive || _isScanning) ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                    ),
                  ),
                ],
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
        return RepaintBoundary(
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
              child: RepaintBoundary(
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
            ),
          ],
        );
    }
  }
}
