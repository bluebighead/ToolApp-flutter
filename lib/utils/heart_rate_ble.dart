// BLE 心率接收工具类
// 使用 flutter_reactive_ble 连接标准心率设备（Heart Rate Service UUID: 0x180D）
// 订阅心率测量特征值（0x2A37）并解析BPM值
import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
          // 将设备添加到扫描列表（去重，更新RSSI）
          final scannedDevice = ScannedDevice(
            id: device.id,
            name: device.name.isNotEmpty ? device.name : '未知设备',
            rssi: device.rssi,
          );

          final isNew = !_scannedDevices.containsKey(device.id);
          final rssiChanged = !isNew && _scannedDevices[device.id]!.rssi != device.rssi;

          _scannedDevices[device.id] = scannedDevice;

          if (isNew) {
            AppLogger.d('HeartRateBle', '发现新设备: ${scannedDevice.name} (${scannedDevice.id}) RSSI: ${scannedDevice.rssi}');
          } else if (rssiChanged) {
            AppLogger.d('HeartRateBle', '设备RSSI更新: ${scannedDevice.name} RSSI: ${_scannedDevices[device.id]!.rssi} -> ${device.rssi}');
          }

          // 新设备或RSSI变化时通知列表更新
          if (isNew || rssiChanged) {
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

    // 取消自动连接订阅（如果是手动连接，需要终止自动连接流程）
    await _autoConnectSubscription?.cancel();
    _autoConnectSubscription = null;
    _isAutoConnecting = false;

    // 取消之前的连接订阅（如果有）
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    
    // 重置连接状态
    _isConnected = false;

    AppLogger.i('HeartRateBle', '连接设备: $deviceId');
    onStatus('正在连接...');

    // 使用 Completer 等待连接成功
    final completer = Completer<void>();

    try {
      _connectionSubscription = _ble.connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 15),
      ).listen(
        (connectionState) async {
          AppLogger.d('HeartRateBle', '连接状态更新: ${connectionState.connectionState}, deviceId: ${connectionState.deviceId}');

          if (connectionState.connectionState == DeviceConnectionState.connected) {
            AppLogger.i('HeartRateBle', '设备已连接: $deviceId');
            _isConnected = true;
            _connectedDeviceId = deviceId;
            // 保存记忆设备（从扫描列表中获取设备名称）
            final deviceName = _scannedDevices[deviceId]?.name ?? '未知设备';
            await _saveLastConnectedDevice(deviceId, deviceName);
            onStatus('已连接');
            // 完成 completer
            if (!completer.isCompleted) {
              completer.complete();
            }
            // 延迟一下再订阅，确保服务发现完成
            await Future.delayed(const Duration(milliseconds: 500));
            await _subscribeToHeartRate(onStatus: onStatus);
          } else if (connectionState.connectionState == DeviceConnectionState.disconnected) {
            AppLogger.w('HeartRateBle', '设备已断开: $deviceId, 之前已连接: $_isConnected');
            // 重置自动连接标记，避免意外断开后无法再次自动连接
            _isAutoConnecting = false;
            // 如果还没连接成功就断开了，报错
            if (!_isConnected && !completer.isCompleted) {
              completer.completeError('设备连接失败：已断开');
            } else if (_isConnected) {
              _isConnected = false;
              _connectedDeviceId = null;
              onStatus('已断开');
            }
          } else if (connectionState.connectionState == DeviceConnectionState.connecting) {
            AppLogger.d('HeartRateBle', '正在连接中...');
          }
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '连接错误', error);
          _isConnected = false;
          _connectedDeviceId = null;
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
          onStatus('连接失败: $error');
        },
      );

      // 等待连接完成或超时
      await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('连接超时'),
      );
      AppLogger.i('HeartRateBle', '连接流程完成');
    } catch (e) {
      AppLogger.e('HeartRateBle', '连接设备失败', e);
      // 连接超时或失败后，取消连接订阅，防止后续状态回调导致状态不一致
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      _isConnected = false;
      _connectedDeviceId = null;
      _isAutoConnecting = false;
      onStatus('连接失败: $e');
      rethrow;
    }
  }

  /// 订阅心率特征值
  Future<void> _subscribeToHeartRate({required Function(String status) onStatus}) async {
    AppLogger.i('HeartRateBle', '订阅心率特征值');

    if (_connectedDeviceId == null) {
      onStatus('设备ID为空');
      return;
    }

    // 取消之前的订阅（如果有）
    await _characteristicSubscription?.cancel();
    _characteristicSubscription = null;

    final characteristic = QualifiedCharacteristic(
      serviceId: Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb'),
      characteristicId: Uuid.parse('00002a37-0000-1000-8000-00805f9b34fb'),
      deviceId: _connectedDeviceId!,
    );

    try {
      AppLogger.d('HeartRateBle', '开始订阅心率特征值...');
      _characteristicSubscription = _ble.subscribeToCharacteristic(characteristic).listen(
        (data) {
          AppLogger.d('HeartRateBle', '收到原始数据: $data');
          // 解析标准心率特征值格式
          final heartRate = _parseHeartRate(data);
          if (heartRate != null) {
            AppLogger.d('HeartRateBle', '心率: $heartRate BPM');
            heartRateStream.add(heartRate);
          } else {
            AppLogger.w('HeartRateBle', '无法解析心率数据: $data');
          }
        },
        onError: (error) {
          AppLogger.e('HeartRateBle', '订阅错误', error);
          onStatus('接收失败: $error');
        },
        onDone: () {
          AppLogger.w('HeartRateBle', '心率订阅完成（可能设备已断开）');
        },
      );
      AppLogger.i('HeartRateBle', '心率特征值订阅成功');
      onStatus('已连接，正在接收心率数据');
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
    await _autoConnectSubscription?.cancel();
    _autoConnectSubscription = null;
    await _characteristicSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _characteristicSubscription = null;
    _connectionSubscription = null;
    _isConnected = false;
    _connectedDeviceId = null;
    _isAutoConnecting = false;
  }

  /// 保存最后连接的设备信息到本地存储
  Future<void> _saveLastConnectedDevice(String deviceId, String deviceName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_connected_ble_device_id', deviceId);
      await prefs.setString('last_connected_ble_device_name', deviceName);
      AppLogger.i('HeartRateBle', '已保存记忆设备: $deviceName ($deviceId)');
    } catch (e) {
      AppLogger.e('HeartRateBle', '保存记忆设备失败', e);
    }
  }

  /// 获取最后连接的设备信息
  Future<Map<String, String>?> _getLastConnectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('last_connected_ble_device_id');
      final deviceName = prefs.getString('last_connected_ble_device_name');
      if (deviceId != null && deviceName != null) {
        return {'id': deviceId, 'name': deviceName};
      }
      return null;
    } catch (e) {
      AppLogger.e('HeartRateBle', '读取记忆设备失败', e);
      return null;
    }
  }

  /// 获取记忆设备信息（public版本，供页面层使用）
  Future<Map<String, String>?> getLastConnectedDevice() => _getLastConnectedDevice();

  /// 自动连接记忆设备
  /// 开始扫描，当扫描到记忆设备时自动连接
  /// 如果设备未开机，持续扫描等待
  /// [onStatus] 回调用于传递状态信息
  /// [onDeviceFound] 回调用于通知页面层记忆设备已找到
  Future<void> autoConnectLastDevice({
    required Function(String status) onStatus,
    Function()? onDeviceFound,
  }) async {
    final lastDevice = await _getLastConnectedDevice();
    if (lastDevice == null) {
      AppLogger.i('HeartRateBle', '无记忆设备，跳过自动连接');
      return;
    }

    // 如果已经处于自动连接流程中，避免重复触发
    if (_isAutoConnecting) {
      AppLogger.i('HeartRateBle', '自动连接流程已在运行中，跳过');
      return;
    }

    AppLogger.i('HeartRateBle', '开始自动连接记忆设备: ${lastDevice['name']} (${lastDevice['id']})');
    _isAutoConnecting = true;
    onStatus('正在寻找上次连接的设备...');

    // 开始扫描
    await startScan(
      onStatus: (status) {
        if (!status.contains('正在寻找')) {
          onStatus(status);
        }
      },
    );

    // 监听设备列表，当记忆设备出现时自动连接
    final autoConnectSubscription = devicesStream.stream.listen(
      (devices) {
        final targetDevice = devices.firstWhere(
          (d) => d.id == lastDevice['id'],
          orElse: () => ScannedDevice(id: '', name: '', rssi: 0),
        );

        if (targetDevice.id.isNotEmpty && !_isConnected && _isAutoConnecting) {
          AppLogger.i('HeartRateBle', '找到记忆设备: ${targetDevice.name}');
          onDeviceFound?.call();
          // 停止扫描并自动连接
          stopScan().then((_) {
            connectToDevice(
              targetDevice.id,
              onStatus: onStatus,
            ).then((_) {
              // 自动连接成功，重置标记
              _isAutoConnecting = false;
            }).catchError((e) {
              AppLogger.w('HeartRateBle', '自动连接失败', e);
              // 连接失败后重置自动连接标记，不再自动重启扫描
              _isAutoConnecting = false;
              onStatus('自动连接失败: $e');
            });
          });
        }
      },
    );

    // 保存订阅引用，用于后续取消（防止泄漏）
    _autoConnectSubscription = autoConnectSubscription;
  }

  // 自动连接订阅（用于管理生命周期）
  StreamSubscription<List<ScannedDevice>>? _autoConnectSubscription;

  // 自动连接流程标记（防止重复触发）
  bool _isAutoConnecting = false;

  /// 释放所有资源
  Future<void> dispose() async {
    await _autoConnectSubscription?.cancel();
    _autoConnectSubscription = null;
    await disconnect();
    await stopScan();
    await heartRateStream.close();
    await devicesStream.close();
  }
}
