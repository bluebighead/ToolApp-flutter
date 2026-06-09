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
