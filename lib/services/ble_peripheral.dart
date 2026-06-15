import 'dart:async';

import 'package:flutter/services.dart';

class BlePeripheralService {
  static const _channel = MethodChannel('com.example.toolapp/ble_peripheral');

  bool _isAdvertising = false;
  int _connectedCount = 0;

  bool get isAdvertising => _isAdvertising;
  int get connectedCount => _connectedCount;

  final List<BtPeripheralLog> _logs = [];
  static const int _maxLogs = 200;
  List<BtPeripheralLog> get logs => List.unmodifiable(_logs);

  final StreamController<bool> _advertisingController =
      StreamController<bool>.broadcast();
  Stream<bool> get advertisingStream => _advertisingController.stream;

  void _addLog(String message) {
    _logs.add(BtPeripheralLog(time: DateTime.now(), message: message));
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
  }

  Future<bool> startAdvertising({
    required String name,
    List<String> serviceUuids = const [],
    bool includeDeviceName = true,
  }) async {
    try {
      // 如果没有指定 Service UUID，使用默认 UUID 以便其他设备可发现
      final uuids = serviceUuids.isEmpty
          ? ['0000FE00-0000-1000-8000-00805F9B34FB']
          : serviceUuids;
      final result = await _channel.invokeMethod<bool>('startAdvertising', {
        'name': name,
        'serviceUuids': uuids,
        'includeDeviceName': includeDeviceName,
      });
      if (result == true) {
        _isAdvertising = true;
        _addLog('开始广播: $name');
        _advertisingController.add(true);
        return true;
      }
      return false;
    } catch (e) {
      _addLog('启动广播失败: $e');
      return false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _channel.invokeMethod('stopAdvertising');
      _isAdvertising = false;
      _addLog('停止广播');
      _advertisingController.add(false);
    } catch (e) {
      _addLog('停止广播失败: $e');
    }
  }

  void clearLogs() {
    _logs.clear();
  }

  void dispose() {
    _advertisingController.close();
  }
}

class BtPeripheralLog {
  final DateTime time;
  final String message;

  BtPeripheralLog({required this.time, required this.message});

  String format() {
    final t = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    return '[$t] $message';
  }
}
