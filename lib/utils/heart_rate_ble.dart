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
  String? _connectedDeviceId;
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
            _connectedDeviceId = device.id;
            onStatus('已连接');
            await _subscribeToHeartRate(onStatus: onStatus);
          } else if (connectionState.connectionState == DeviceConnectionState.disconnected) {
            _isConnected = false;
            _connectedDeviceId = null;
            onStatus('已断开');
          }
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '连接错误', error);
          _isConnected = false;
          _connectedDeviceId = null;
          onStatus('连接失败: $error');
        },
      );
    } catch (e) {
      AppLogger.e('HeartRateBle', '连接设备失败', e);
      _isConnected = false;
      _connectedDeviceId = null;
      onStatus('连接失败: $e');
    }
  }

  /// 订阅心率特征值
  Future<void> _subscribeToHeartRate({required Function(String status) onStatus}) async {
    AppLogger.i('HeartRateBle', '订阅心率特征值');

    if (_connectedDeviceId == null) {
      onStatus('设备ID为空');
      return;
    }

    final characteristic = QualifiedCharacteristic(
      serviceId: Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb'),
      characteristicId: Uuid.parse('00002a37-0000-1000-8000-00805f9b34fb'),
      deviceId: _connectedDeviceId!,
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
    _connectedDeviceId = null;
    _heartRateCharacteristic = null;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await disconnect();
    await heartRateStream.close();
  }
}
