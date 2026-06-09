// BLE 心率接收工具类
// 使用 flutter_reactive_ble 连接标准心率设备（Heart Rate Service UUID: 0x180D）
// 订阅心率测量特征值（0x2A37）并解析BPM值
import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'app_logger.dart';

/// 扫描到的设备信息
class ScannedDevice {
  final String id;
  final String name;
  final int rssi;

  ScannedDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScannedDevice && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// BLE 心率接收器
class HeartRateBle {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;

  String? _connectedDeviceId;
  bool _isScanning = false;
  bool _isConnected = false;

  /// 扫描到的设备列表
  final Map<String, ScannedDevice> _scannedDevices = {};

  /// 设备列表更新流
  final StreamController<List<ScannedDevice>> devicesStream =
      StreamController<List<ScannedDevice>>.broadcast();

  /// 是否正在扫描
  bool get isScanning => _isScanning;

  /// 是否已连接
  bool get isConnected => _isConnected;

  /// 已连接的设备ID
  String? get connectedDeviceId => _connectedDeviceId;

  /// 心率数据流控制器
  final StreamController<int> heartRateStream = StreamController<int>.broadcast();

  /// 开始扫描心率设备
  /// 不会自动连接，而是将设备添加到扫描列表中
  /// [onStatus] 回调用于传递状态信息
  Future<void> startScan({required Function(String status) onStatus}) async {
    if (_isScanning) return;

    AppLogger.i('HeartRateBle', '开始扫描BLE心率设备');
    _scannedDevices.clear();
    _isScanning = true;
    onStatus('正在扫描设备...');

    try {
      // 扫描心率设备（Heart Rate Service UUID: 0x180D）
      _scanSubscription = _ble.scanForDevices(
        withServices: [Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb')],
        scanMode: ScanMode.lowLatency,
      ).listen(
        (device) {
          // 将设备添加到扫描列表（去重）
          final scannedDevice = ScannedDevice(
            id: device.id,
            name: device.name.isNotEmpty ? device.name : '未知设备',
            rssi: device.rssi,
          );

          if (!_scannedDevices.containsKey(device.id)) {
            _scannedDevices[device.id] = scannedDevice;
            AppLogger.d('HeartRateBle', '发现新设备: ${scannedDevice.name} (${scannedDevice.id}) RSSI: ${scannedDevice.rssi}');
            // 通知设备列表更新
            devicesStream.add(_scannedDevices.values.toList());
          }
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
  Future<void> stopScan() async {
    if (!_isScanning) return;
    AppLogger.i('HeartRateBle', '停止扫描');
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
  }

  /// 连接到指定设备
  /// [deviceId] 设备ID
  /// [onStatus] 回调用于传递状态信息
  Future<void> connectToDevice(
    String deviceId, {
    required Function(String status) onStatus,
  }) async {
    // 先停止扫描
    await stopScan();

    AppLogger.i('HeartRateBle', '连接设备: $deviceId');
    onStatus('正在连接...');

    try {
      _connectionSubscription = _ble.connectToDevice(
        id: deviceId,
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
            _connectedDeviceId = deviceId;
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

  /// 断开连接
  Future<void> disconnect() async {
    AppLogger.i('HeartRateBle', '断开BLE连接');
    await _characteristicSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _characteristicSubscription = null;
    _connectionSubscription = null;
    _isConnected = false;
    _connectedDeviceId = null;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    await disconnect();
    await stopScan();
    await heartRateStream.close();
    await devicesStream.close();
  }
}
