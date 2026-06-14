import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../utils/app_logger.dart';

class BtLogEntry {
  final DateTime time;
  final String level;
  final String tag;
  final String message;

  BtLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  String format() {
    final t = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    return '[$t][$level][$tag] $message';
  }
}

enum BtBeaconType { none, iBeacon, eddystone }

class BtDevice {
  final String id;
  final String name;
  int rssi;
  bool isConnected;
  BtBeaconType beaconType;
  Map<String, dynamic>? beaconData;

  BtDevice({
    required this.id,
    required this.name,
    this.rssi = -100,
    this.isConnected = false,
    this.beaconType = BtBeaconType.none,
    this.beaconData,
  });
}

class BtCharacteristic {
  final String uuid;
  final bool isReadable;
  final bool isWritableWithResponse;
  final bool isWritableWithoutResponse;
  final bool isNotifiable;
  final bool isIndicatable;
  List<int>? value;
  bool isNotifying;

  BtCharacteristic({
    required this.uuid,
    this.isReadable = false,
    this.isWritableWithResponse = false,
    this.isWritableWithoutResponse = false,
    this.isNotifiable = false,
    this.isIndicatable = false,
    this.value,
    this.isNotifying = false,
  });
}

class BtService {
  final String uuid;
  final List<BtCharacteristic> characteristics;

  BtService({required this.uuid, this.characteristics = const []});
}

class BluetoothDebugger {
  static const String _logTag = 'BtDebugger';

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  Timer? _scanTimer;

  String? _connectedDeviceId;
  bool _isScanning = false;
  bool _isConnected = false;

  static const Duration scanDuration = Duration(seconds: 10);

  final List<BtDevice> _scannedDevices = [];
  final StreamController<List<BtDevice>> _devicesController =
      StreamController<List<BtDevice>>.broadcast();
  Stream<List<BtDevice>> get devicesStream => _devicesController.stream;

  final List<BtService> _services = [];
  final StreamController<List<BtService>> _servicesController =
      StreamController<List<BtService>>.broadcast();
  Stream<List<BtService>> get servicesStream => _servicesController.stream;

  int _mtu = 23;
  int get mtu => _mtu;

  final List<int> _rssiHistory = [];
  List<int> get rssiHistory => List.unmodifiable(_rssiHistory);
  static const int _maxRssiSamples = 60;

  final List<BtLogEntry> _logs = [];
  static const int _maxLogs = 500;
  List<BtLogEntry> get logs => List.unmodifiable(_logs);

  String? _scanError;
  String? get scanError => _scanError;

  String? get connectedDeviceId => _connectedDeviceId;
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;

  void _addLog(String level, String tag, String message) {
    _logs.add(BtLogEntry(time: DateTime.now(), level: level, tag: tag, message: message));
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
  }

  void _notifyDevices() {
    _scannedDevices.sort((a, b) => b.rssi.compareTo(a.rssi));
    _devicesController.add(List.from(_scannedDevices));
  }

  void _notifyServices() {
    _servicesController.add(List.from(_services));
  }

  Future<void> startScan() async {
    if (_isScanning) return;
    _isScanning = true;
    _scannedDevices.clear();
    _scanError = null;
    _addLog('INFO', _logTag, '开始扫描 BLE 设备');
    _notifyDevices();

    _scanTimer = Timer(scanDuration, () {
      if (_isScanning) {
        _addLog('INFO', _logTag, '扫描超时，自动停止');
        _isScanning = false;
        _scanSubscription?.cancel();
        _scanSubscription = null;
        _notifyDevices();
      }
    });

    try {
      _scanSubscription = _ble.scanForDevices(
        withServices: [],
        scanMode: ScanMode.lowLatency,
      ).listen((device) {
        final beaconInfo = _parseBeaconData(device);
        final existing = _scannedDevices.indexWhere((d) => d.id == device.id);
        if (existing >= 0) {
          _scannedDevices[existing].rssi = device.rssi;
        } else {
          _scannedDevices.add(BtDevice(
            id: device.id,
            name: device.name.isNotEmpty ? device.name : '未知设备',
            rssi: device.rssi,
            beaconType: beaconInfo.$1,
            beaconData: beaconInfo.$2,
          ));
          _addLog('INFO', _logTag, '发现设备: ${device.name} (${device.id})');
        }
        if (device.id == _connectedDeviceId) {
          _rssiHistory.add(device.rssi);
          if (_rssiHistory.length > _maxRssiSamples) {
            _rssiHistory.removeAt(0);
          }
        }
        _notifyDevices();
      }, onError: (e) {
        final msg = '扫描出错: $e';
        _addLog('ERROR', _logTag, msg);
        _isScanning = false;
        _scanError = msg;
        _notifyDevices();
      });
    } catch (e) {
      final msg = '启动扫描失败: $e';
      _addLog('ERROR', _logTag, msg);
      _isScanning = false;
      _scanError = msg;
      _notifyDevices();
    }
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
    _addLog('INFO', _logTag, '停止扫描');
    _notifyDevices();
  }

  Future<void> connect(String deviceId) async {
    await stopScan();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _isConnected = false;
    _services.clear();
    _notifyServices();
    _connectedDeviceId = deviceId;

    _addLog('INFO', _logTag, '正在连接: $deviceId');

    final completer = Completer<void>();

    try {
      _connectionSubscription = _ble.connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 15),
      ).listen((state) {
        _addLog('DEBUG', _logTag, '连接状态: ${state.connectionState}');
        if (state.connectionState == DeviceConnectionState.connected) {
          _isConnected = true;
          _connectedDeviceId = deviceId;
          if (!completer.isCompleted) completer.complete();
          _requestMtu().then((_) => _discoverServices());
        } else if (state.connectionState == DeviceConnectionState.disconnected) {
          _isConnected = false;
          _connectedDeviceId = null;
          _services.clear();
          _notifyServices();
          _addLog('WARN', _logTag, '设备已断开');
          if (!completer.isCompleted) {
            completer.completeError('设备连接失败：已断开');
          }
        }
      }, onError: (e) {
        _addLog('ERROR', _logTag, '连接出错: $e');
        _isConnected = false;
        _connectedDeviceId = null;
        if (!completer.isCompleted) completer.completeError(e);
      });

      await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('连接超时'),
      );
    } catch (e) {
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      _isConnected = false;
      _connectedDeviceId = null;
      _addLog('ERROR', _logTag, '连接失败: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _addLog('INFO', _logTag, '手动断开连接');
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _isConnected = false;
    _connectedDeviceId = null;
    _services.clear();
    _notifyServices();
  }

  (BtBeaconType, Map<String, dynamic>?) _parseBeaconData(DiscoveredDevice device) {
    if (device.serviceUuids.any((u) => u.toString().toUpperCase() == '0000FEAA-0000-1000-8000-00805F9B34FB')) {
      return (BtBeaconType.eddystone, {'type': 'Eddystone'});
    }
    final mfr = device.manufacturerData;
    if (mfr.length >= 4 && mfr[0] == 0x4C && mfr[1] == 0x00 && mfr[2] == 0x02 && mfr[3] == 0x15) {
      final d = mfr;
      final uuid = '${d[4].toRadixString(16).padLeft(2, '0')}${d[5].toRadixString(16).padLeft(2, '0')}-'
          '${d[6].toRadixString(16).padLeft(2, '0')}${d[7].toRadixString(16).padLeft(2, '0')}-'
          '${d[8].toRadixString(16).padLeft(2, '0')}${d[9].toRadixString(16).padLeft(2, '0')}-'
          '${d[10].toRadixString(16).padLeft(2, '0')}${d[11].toRadixString(16).padLeft(2, '0')}-'
          '${d[12].toRadixString(16).padLeft(2, '0')}${d[13].toRadixString(16).padLeft(2, '0')}'
          '${d[14].toRadixString(16).padLeft(2, '0')}${d[15].toRadixString(16).padLeft(2, '0')}';
      final major = d.length > 18 ? (d[16] << 8) | d[17] : 0;
      final minor = d.length > 20 ? (d[18] << 8) | d[19] : 0;
      return (BtBeaconType.iBeacon, {
        'type': 'iBeacon',
        'uuid': uuid,
        'major': major,
        'minor': minor,
      });
    }
    return (BtBeaconType.none, null);
  }

  Future<void> requestMtuManually(int targetMtu) async {
    if (_connectedDeviceId == null) return;
    try {
      _mtu = await _ble.requestMtu(deviceId: _connectedDeviceId!, mtu: targetMtu);
      _addLog('INFO', _logTag, '手动 MTU 协商完成: $_mtu (请求 $targetMtu)');
    } catch (e) {
      _addLog('ERROR', _logTag, '手动 MTU 协商失败: $e');
    }
  }

  void clearRssiHistory() {
    _rssiHistory.clear();
  }

  Future<void> _requestMtu() async {
    if (_connectedDeviceId == null) return;
    try {
      _mtu = await _ble.requestMtu(deviceId: _connectedDeviceId!, mtu: 512);
      _addLog('INFO', _logTag, 'MTU 协商完成: $_mtu');
    } catch (e) {
      _addLog('WARN', _logTag, 'MTU 协商失败: $e');
    }
  }

  Future<void> _discoverServices() async {
    if (_connectedDeviceId == null) return;
    _services.clear();
    try {
      final discovered = await _ble.discoverServices(_connectedDeviceId!);
      for (final svc in discovered) {
        final chars = svc.characteristics.map((c) {
          return BtCharacteristic(
            uuid: c.characteristicId.toString(),
            isReadable: c.isReadable,
            isWritableWithResponse: c.isWritableWithResponse,
            isWritableWithoutResponse: c.isWritableWithoutResponse,
            isNotifiable: c.isNotifiable,
            isIndicatable: c.isIndicatable,
          );
        }).toList();
        _services.add(BtService(uuid: svc.serviceId.toString(), characteristics: chars));
      }
      _addLog('INFO', _logTag, '服务发现完成: ${_services.length} 个服务');
      _notifyServices();
    } catch (e) {
      _addLog('ERROR', _logTag, '服务发现失败: $e');
    }
  }

  Future<List<int>?> readCharacteristic(String serviceUuid, String charUuid) async {
    if (_connectedDeviceId == null) return null;
    try {
      final value = await _ble.readCharacteristic(QualifiedCharacteristic(
        serviceId: Uuid.parse(serviceUuid),
        characteristicId: Uuid.parse(charUuid),
        deviceId: _connectedDeviceId!,
      ));
      _addLog('INFO', _logTag, '读取特征值 $charUuid: ${value.toString()}');
      return value;
    } catch (e) {
      _addLog('ERROR', _logTag, '读取特征值失败 $charUuid: $e');
      return null;
    }
  }

  Future<bool> writeCharacteristic(String serviceUuid, String charUuid, List<int> value,
      {bool withResponse = true}) async {
    if (_connectedDeviceId == null) return false;
    try {
      await _ble.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
          serviceId: Uuid.parse(serviceUuid),
          characteristicId: Uuid.parse(charUuid),
          deviceId: _connectedDeviceId!,
        ),
        value: value,
      );
      _addLog('INFO', _logTag, '写入特征值 $charUuid: ${value.toString()}');
      return true;
    } catch (e) {
      _addLog('ERROR', _logTag, '写入特征值失败 $charUuid: $e');
      return false;
    }
  }

  Future<bool> writeWithoutResponse(String serviceUuid, String charUuid, List<int> value) async {
    if (_connectedDeviceId == null) return false;
    try {
      await _ble.writeCharacteristicWithoutResponse(
        QualifiedCharacteristic(
          serviceId: Uuid.parse(serviceUuid),
          characteristicId: Uuid.parse(charUuid),
          deviceId: _connectedDeviceId!,
        ),
        value: value,
      );
      _addLog('INFO', _logTag, '无响应写入 $charUuid: ${value.toString()}');
      return true;
    } catch (e) {
      _addLog('ERROR', _logTag, '无响应写入失败 $charUuid: $e');
      return false;
    }
  }

  Future<bool> subscribeToCharacteristic(String serviceUuid, String charUuid,
      {required void Function(List<int> data) onData}) async {
    if (_connectedDeviceId == null) return false;
    try {
      await _notifySubscription?.cancel();
      _notifySubscription = _ble.subscribeToCharacteristic(
        QualifiedCharacteristic(
          serviceId: Uuid.parse(serviceUuid),
          characteristicId: Uuid.parse(charUuid),
          deviceId: _connectedDeviceId!,
        ),
      ).listen((data) {
        _addLog('NOTIFY', _logTag, '通知 $charUuid: ${data.toString()}');
        onData(data);
      }, onError: (e) {
        _addLog('ERROR', _logTag, '通知订阅出错 $charUuid: $e');
      }, onDone: () {
        _addLog('WARN', _logTag, '通知订阅结束 $charUuid');
      });
      _addLog('INFO', _logTag, '通知订阅成功 $charUuid');
      return true;
    } catch (e) {
      _addLog('ERROR', _logTag, '通知订阅失败 $charUuid: $e');
      return false;
    }
  }

  Future<void> unsubscribeFromCharacteristic() async {
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    _addLog('INFO', _logTag, '取消通知订阅');
  }

  void clearLogs() {
    _logs.clear();
  }

  void dispose() {
    _scanTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notifySubscription?.cancel();
    _devicesController.close();
    _servicesController.close();
  }
}
