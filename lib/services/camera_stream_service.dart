// 摄像头推流服务
// 通过WebSocket连接服务器，接收管理员的推流请求
// 收到请求后启动摄像头，将画面帧以Base64编码推送到服务器
// 服务器中转给PC端管理员
// 支持前/后摄像头切换和双摄同时推流
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
// v1.52.5+ GPS定位上报
import 'package:geolocator/geolocator.dart';

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';

/// 摄像头选择模式
enum CameraMode {
  front,  // 前置摄像头
  rear,   // 后置摄像头
  dual,   // 前后双摄
}

/// 摄像头推流服务
class CameraStreamService {
  static const String _logTag = 'CameraStreamService';

  /// 全局单例
  static final CameraStreamService instance = CameraStreamService._();

  CameraStreamService._();

  /// WebSocket连接
  WebSocketChannel? _channel;

  /// 连接是否活跃
  bool _isConnected = false;

  /// 前置摄像头控制器
  CameraController? _frontController;

  /// 后置摄像头控制器
  CameraController? _rearController;

  /// 是否正在推流
  bool _isStreaming = false;

  /// 当前摄像头模式
  CameraMode _cameraMode = CameraMode.front;

  /// 可用摄像头列表
  List<CameraDescription> _cameras = [];

  // ---- 回调 ----

  /// 收到推流请求
  VoidCallback? onStreamRequested;

  /// 推流状态变化
  void Function(bool isStreaming)? onStreamStateChanged;

  /// 连接断开
  VoidCallback? onDisconnected;

  /// 是否正在推流
  bool get isStreaming => _isStreaming;

  /// 是否已连接
  bool get isConnected => _isConnected;

  /// 当前摄像头模式
  CameraMode get cameraMode => _cameraMode;

  /// 重连定时器
  Timer? _reconnectTimer;

  /// 是否主动断开（不自动重连）
  bool _intentionalDisconnect = false;

  /// 重连次数
int _reconnectAttempts = 0;

// v1.52.5+ GPS定位追踪状态
/// 是否正在GPS追踪上报
bool _isGpsTracking = false;
/// GPS位置监听订阅
StreamSubscription<Position>? _gpsSubscription;
/// GPS更新间隔（秒）
static const int _gpsUpdateIntervalSec = 3;

  /// 心跳定时器（App端主动发心跳，保持连接活跃）
  Timer? _heartbeatTimer;

  /// 连接服务器WebSocket
  Future<bool> connect() async {
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    try {
      final token = AuthService.instance.token;
      if (token == null) {
        AppLogger.e(_logTag, '未登录，无法连接');
        return false;
      }

      final serverUrl = appSettings.serverUrl;
      final parsedUrl = Uri.parse(serverUrl);
      final wsScheme = serverUrl.startsWith('https') ? 'wss' : 'ws';
      final wsHost = parsedUrl.host;

      String wsUrl;
      if (parsedUrl.hasPort &&
          ((wsScheme == 'ws' && parsedUrl.port != 80) ||
           (wsScheme == 'wss' && parsedUrl.port != 443))) {
        wsUrl = '$wsScheme://$wsHost:${parsedUrl.port}/ws?token=$token';
      } else {
        wsUrl = '$wsScheme://$wsHost/ws?token=$token';
      }

      AppLogger.i(_logTag, '连接WebSocket: $wsUrl');
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      try {
        await _channel!.ready.timeout(const Duration(seconds: 10));
      } catch (e) {
        AppLogger.e(_logTag, 'WebSocket连接超时: $e');
        await _channel!.sink.close();
        _channel = null;
        return false;
      }

      _isConnected = true;

      // 启动WebSocket保活前台服务，防止App切后台时连接被系统杀掉
      _startWsForegroundService();

      // 启动心跳定时器，每25秒发送一次心跳，保持连接活跃
      _startHeartbeat();

      // 监听消息
      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          AppLogger.e(_logTag, 'WebSocket错误: $error');
          _handleDisconnect();
        },
        onDone: () {
          AppLogger.i(_logTag, 'WebSocket连接关闭');
          _handleDisconnect();
        },
      );

      AppLogger.i(_logTag, 'WebSocket连接成功');
      return true;
    } catch (e) {
      AppLogger.e(_logTag, '连接失败: $e');
      return false;
    }
  }

  // 处理收到的消息
  void _onMessage(dynamic message) {
    try {
      final msgStr = (message as String).trim();
      final msg = jsonDecode(msgStr) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'] as Map<String, dynamic>? ?? {};

      switch (type) {
        case 'camera_start_request':
          // 管理员请求推流 - 解析摄像头模式
          final modeStr = data['cameraMode'] as String? ?? 'front';
          final mode = modeStr == 'rear' ? CameraMode.rear
              : modeStr == 'dual' ? CameraMode.dual
              : CameraMode.front;
          AppLogger.i(_logTag, '收到摄像头推流请求，模式: $modeStr');
          Future<void>(() async {
            final ok = await startStreaming(cameraMode: mode);
            if (!ok) {
              AppLogger.e(_logTag, '启动摄像头推流失败');
              _send('camera_error', {'message': '无法启动摄像头'});
            }
          });
          onStreamRequested?.call();
          break;

        case 'camera_snapshot_request':
          // 管理员请求抓拍
          final modeStr = data['cameraMode'] as String? ?? 'front';
          final mode = modeStr == 'rear' ? CameraMode.rear
              : modeStr == 'dual' ? CameraMode.dual
              : CameraMode.front;
          AppLogger.i(_logTag, '收到抓拍请求，模式: $modeStr');
          Future<void>(() async {
            final ok = await _takeSnapshot(cameraMode: mode);
            if (!ok) {
              _send('camera_error', {'message': '抓拍失败'});
            }
          });
          break;

        case 'camera_stop_request':
          // 管理员停止推流
          AppLogger.i(_logTag, '收到停止推流请求');
          stopStreaming();
          break;

        case 'heartbeat':
        // 响应服务器心跳，防止被断开
        _send('heartbeat_ack', {'timestamp': data['timestamp']});
        break;

      // v1.52.5+ GPS定位追踪：管理员请求
      case 'gps_start_request':
        AppLogger.i(_logTag, '收到GPS定位开始请求');
        _startGpsTracking();
        break;
      case 'gps_stop_request':
        AppLogger.i(_logTag, '收到GPS定位停止请求');
        _stopGpsTracking();
        break;
      }
    } catch (e) {
      AppLogger.e(_logTag, '消息解析失败: $e');
    }
  }

  // 发送消息到服务器

// v1.52.5+ 开始GPS定位追踪（响应管理员请求）
Future<void> _startGpsTracking() async {
  if (_isGpsTracking) return;

  // 检查定位服务是否开启
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    _send('camera_error', {'message': '手机GPS定位服务未开启'});
    return;
  }

  // 检查定位权限
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      _send('camera_error', {'message': 'GPS定位权限被拒绝'});
      return;
    }
  }
  if (permission == LocationPermission.deniedForever) {
    _send('camera_error', {'message': 'GPS定位权限被永久拒绝，请在设置中开启'});
    return;
  }

  _isGpsTracking = true;
  AppLogger.i(_logTag, 'GPS定位追踪已启动，每$_gpsUpdateIntervalSec秒上报一次');

  // 使用PositionStream监听位置变化（不设timeLimit，避免GPS冷启动超时被中断）
  _gpsSubscription = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // 移动5米更新一次
    ),
  ).listen(
    (Position position) {
      if (!_isGpsTracking) return;
      _send('app_gps_position', {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
        'heading': position.heading,
      });
    },
    onError: (error) {
      AppLogger.e(_logTag, 'GPS位置监听出错: $error');
      _send('camera_error', {'message': 'GPS定位出错: $error'});
    },
  );
}

// v1.52.5+ 停止GPS定位追踪
void _stopGpsTracking() {
  if (!_isGpsTracking) return;
  _isGpsTracking = false;
  _gpsSubscription?.cancel();
  _gpsSubscription = null;
  AppLogger.i(_logTag, 'GPS定位追踪已停止');
}
void _send(String type, Map<String, dynamic> data) {
  if (!_isConnected || _channel == null) return;
  _channel!.sink.add(jsonEncode({ 'type': type, 'data': data }));
}

  /// 查找摄像头索引
  int _findCameraIndex(CameraLensDirection direction) {
    for (int i = 0; i < _cameras.length; i++) {
      if (_cameras[i].lensDirection == direction) {
        return i;
      }
    }
    return -1;
  }

  /// 开始推流
  Future<bool> startStreaming({CameraMode cameraMode = CameraMode.front}) async {
    if (_isStreaming) {
      // 如果已经在推流但模式不同，先停止再重启
      if (_cameraMode != cameraMode) {
        await stopStreaming();
      } else {
        return true;
      }
    }

    _cameraMode = cameraMode;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        AppLogger.e(_logTag, '未检测到摄像头');
        return false;
      }

      final frontIdx = _findCameraIndex(CameraLensDirection.front);
      final rearIdx = _findCameraIndex(CameraLensDirection.back);

      // 根据模式启动摄像头
      if (cameraMode == CameraMode.front || cameraMode == CameraMode.dual) {
        if (frontIdx >= 0) {
          _frontController = CameraController(
            _cameras[frontIdx],
            ResolutionPreset.medium,
            enableAudio: false,
          );
          await _frontController!.initialize();
          _frontController!.startImageStream((image) => _onImageAvailable(image, 'front'));
        } else if (cameraMode == CameraMode.front) {
          AppLogger.e(_logTag, '未找到前置摄像头');
          return false;
        }
      }

      if (cameraMode == CameraMode.rear || cameraMode == CameraMode.dual) {
        if (rearIdx >= 0) {
          _rearController = CameraController(
            _cameras[rearIdx],
            ResolutionPreset.medium,
            enableAudio: false,
          );
          await _rearController!.initialize();
          _rearController!.startImageStream((image) => _onImageAvailable(image, 'rear'));
        } else if (cameraMode == CameraMode.rear) {
          AppLogger.e(_logTag, '未找到后置摄像头');
          return false;
        }
      }

      // 如果双摄模式但只有一个摄像头，降级为单摄
      if (cameraMode == CameraMode.dual && _frontController == null && _rearController == null) {
        AppLogger.e(_logTag, '双摄模式：无可用摄像头');
        return false;
      }

      _isStreaming = true;

      // 通知服务器推流已开始
      _send('app_camera_start', {
        'cameraMode': cameraMode.name,
      });

      onStreamStateChanged?.call(true);
      AppLogger.i(_logTag, '摄像头推流已开始，模式: ${cameraMode.name}');
      return true;
    } catch (e) {
      AppLogger.e(_logTag, '启动推流失败: $e');
      return false;
    }
  }

  // 图像帧回调：将YUV420图像转为Base64并发送
  // 帧率控制：每200ms发送一帧（约5fps），降低带宽压力
  DateTime? _lastFrontFrameTime;
  DateTime? _lastRearFrameTime;

  void _onImageAvailable(CameraImage image, String source) {
    if (!_isStreaming) return;

    // 帧率控制
    final now = DateTime.now();
    if (source == 'front') {
      if (_lastFrontFrameTime != null && now.difference(_lastFrontFrameTime!).inMilliseconds < 200) {
        return;
      }
      _lastFrontFrameTime = now;
    } else {
      if (_lastRearFrameTime != null && now.difference(_lastRearFrameTime!).inMilliseconds < 200) {
        return;
      }
      _lastRearFrameTime = now;
    }

    try {
      final width = image.width;
      final height = image.height;

      final yPlane = image.planes[0].bytes;
      final uPlane = image.planes.length > 1 ? image.planes[1].bytes : Uint8List(0);
      final vPlane = image.planes.length > 2 ? image.planes[2].bytes : Uint8List(0);

      _send('app_camera_frame', {
        'source': source,
        'width': width,
        'height': height,
        'format': image.format.toString(),
        'y': base64Encode(yPlane),
        'u': base64Encode(uPlane),
        'v': base64Encode(vPlane),
        'yRowStride': image.planes[0].bytesPerRow,
        'uRowStride': image.planes.length > 1 ? image.planes[1].bytesPerRow : 0,
        'vRowStride': image.planes.length > 2 ? image.planes[2].bytesPerRow : 0,
      });
    } catch (e) {
      AppLogger.e(_logTag, '发送帧数据失败: $e');
    }
  }

  /// 停止推流
  Future<void> stopStreaming() async {
    if (!_isStreaming) return;

    _isStreaming = false;

    try {
      await _frontController?.stopImageStream();
      _frontController?.dispose();
      _frontController = null;
    } catch (e) {
      AppLogger.e(_logTag, '停止前置摄像头失败: $e');
    }

    try {
      await _rearController?.stopImageStream();
      _rearController?.dispose();
      _rearController = null;
    } catch (e) {
      AppLogger.e(_logTag, '停止后置摄像头失败: $e');
    }

    // 通知服务器推流已停止
    _send('app_camera_stop', {});

    onStreamStateChanged?.call(false);
    AppLogger.i(_logTag, '摄像头推流已停止');
  }

  /// 抓拍：复用已有摄像头控制器快速拍照，或临时打开摄像头拍照
  Future<bool> _takeSnapshot({CameraMode cameraMode = CameraMode.front}) async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        AppLogger.e(_logTag, '未检测到摄像头');
        return false;
      }

      final frontIdx = _findCameraIndex(CameraLensDirection.front);
      final rearIdx = _findCameraIndex(CameraLensDirection.back);

      // 前置抓拍
      if (cameraMode == CameraMode.front || cameraMode == CameraMode.dual) {
        if (frontIdx < 0 && cameraMode == CameraMode.front) {
          AppLogger.e(_logTag, '未找到前置摄像头');
          return false;
        }
        if (frontIdx >= 0) {
          await _takeSingleSnapshot(_cameras[frontIdx], 'front');
        }
      }

      // 后置抓拍
      if (cameraMode == CameraMode.rear || cameraMode == CameraMode.dual) {
        if (rearIdx < 0 && cameraMode == CameraMode.rear) {
          AppLogger.e(_logTag, '未找到后置摄像头');
          return false;
        }
        if (rearIdx >= 0) {
          await _takeSingleSnapshot(_cameras[rearIdx], 'rear');
        }
      }

      AppLogger.i(_logTag, '抓拍成功，已发送');
      return true;
    } catch (e) {
      AppLogger.e(_logTag, '抓拍失败: $e');
      return false;
    }
  }

  /// 单摄像头抓拍
  Future<void> _takeSingleSnapshot(CameraDescription camera, String source) async {
    // 如果正在推流且是同一个摄像头，直接用现有控制器拍照
    if (_isStreaming) {
      final controller = source == 'front' ? _frontController : _rearController;
      if (controller != null && controller.value.isInitialized) {
        try {
          final xFile = await controller.takePicture();
          final bytes = await File(xFile.path).readAsBytes();
          final base64Image = base64Encode(bytes);
          _send('app_camera_snapshot', {
            'image': base64Image,
            'format': 'jpeg',
            'source': source,
          });
          try { await File(xFile.path).delete(); } catch (_) {}
          return;
        } catch (e) {
          AppLogger.w(_logTag, '复用控制器拍照失败，尝试新建: $e');
        }
      }
    }

    // 推流中无法复用或未推流，临时打开摄像头快速拍照
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    await controller.initialize();

    // 缩短等待时间，尽快拍照
    await Future.delayed(const Duration(milliseconds: 100));

    final xFile = await controller.takePicture();
    await controller.dispose();

    final bytes = await File(xFile.path).readAsBytes();
    final base64Image = base64Encode(bytes);

    _send('app_camera_snapshot', {
      'image': base64Image,
      'format': 'jpeg',
      'source': source,
    });

    try { await File(xFile.path).delete(); } catch (_) {}
  }

  // 断开连接处理
  void _handleDisconnect() {
    _isConnected = false;
    _stopHeartbeat();
    if (_isStreaming) {
      stopStreaming();
    }
    _channel = null;
    onDisconnected?.call();

    // 断开连接时停止保活前台服务
    _stopWsForegroundService();

    if (!_intentionalDisconnect) {
      _scheduleReconnect();
    }
  }

  // 自动重连
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;

    final delay = Duration(seconds: (5 * (1 << (_reconnectAttempts - 1))).clamp(5, 60));
    AppLogger.i(_logTag, '将在 ${delay.inSeconds} 秒后尝试重连 (第${_reconnectAttempts}次)');

    _reconnectTimer = Timer(delay, () async {
      if (_intentionalDisconnect) return;
      AppLogger.i(_logTag, '开始自动重连...');
      final ok = await connect();
      if (!ok) {
        AppLogger.w(_logTag, '自动重连失败');
      }
    });
  }

  /// 取消自动重连定时器（外部调用，如App恢复前台时主动重连前先取消）
  void cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// 断开连接
Future<void> disconnect() async {
  _intentionalDisconnect = true;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;
  _stopHeartbeat();
  await stopStreaming();
  // v1.52.5+ 停止GPS追踪
  _stopGpsTracking();
  await _channel?.sink.close();
  _channel = null;
  _isConnected = false;
  // 主动断开时停止保活前台服务
  _stopWsForegroundService();
}

  // ---- 心跳机制 ----

  /// 启动心跳定时器（每25秒发送一次，服务端120秒超时）
  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_isConnected && _channel != null) {
        try {
          _send('app_heartbeat', {});
        } catch (e) {
          AppLogger.w(_logTag, '发送心跳失败: $e');
        }
      }
    });
  }

  /// 停止心跳定时器
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ---- WebSocket保活前台服务 ----

  static const _foregroundServiceChannel = MethodChannel('com.example.toolapp/foreground_service');

  /// 启动WebSocket保活前台服务
  void _startWsForegroundService() {
    try {
      _foregroundServiceChannel.invokeMethod('startWsForegroundService', {
        'content': '设备连接保持中',
      });
      AppLogger.i(_logTag, 'WebSocket保活前台服务已启动');
    } catch (e) {
      AppLogger.w(_logTag, '启动WebSocket保活前台服务失败: $e');
    }
  }

  /// 停止WebSocket保活前台服务
  void _stopWsForegroundService() {
    try {
      _foregroundServiceChannel.invokeMethod('stopWsForegroundService');
      AppLogger.i(_logTag, 'WebSocket保活前台服务已停止');
    } catch (e) {
      AppLogger.w(_logTag, '停止WebSocket保活前台服务失败: $e');
    }
  }
}
