// 会话跟踪服务：管理用户在线状态和使用时长
// 登录后自动开启会话，定期发送心跳，登出或切后台时结束会话
// 同时记录用户页面访问活动日志，供管理端查看
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';

import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';

class SessionTracker extends ChangeNotifier {
  // 全局单例
  static final SessionTracker instance = SessionTracker._();
  SessionTracker._();

  // 当前会话 ID
  int? _sessionId;
  int? get sessionId => _sessionId;

  // 是否正在跟踪
  bool _isTracking = false;
  bool get isTracking => _isTracking;

  // 会话开始时间
  DateTime? _sessionStartTime;
  DateTime? get sessionStartTime => _sessionStartTime;

  // 心跳定时器
  Timer? _heartbeatTimer;

  // 活动日志缓冲区（批量上报）
  final List<Map<String, dynamic>> _activityBuffer = [];

  // 活动日志上报定时器
  Timer? _activityFlushTimer;

  // 当前页面名称
  String? _currentPage;

  // 服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  // 认证请求头
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };

  /// 启动会话跟踪
  /// 登录成功后调用，向服务器注册新会话
  Future<void> startSession() async {
    if (_isTracking) {
      AppLogger.w('SessionTracker', '会话已在跟踪中，跳过启动');
      return;
    }

    if (!AuthService.instance.isLoggedIn) {
      AppLogger.w('SessionTracker', '未登录，无法启动会话');
      return;
    }

    try {
      // 获取设备信息
      final deviceInfo = await _getDeviceInfo();

      AppLogger.i('SessionTracker', '启动会话 - 设备: $deviceInfo');

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/session/start'),
            headers: _authHeaders,
            body: jsonEncode({
              'deviceInfo': deviceInfo,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _sessionId = data['sessionId'] as int?;
        _sessionStartTime = DateTime.now();
        _isTracking = true;

        // 保存会话 ID 到本地（用于应用重启后恢复）
        final prefs = AppSettings.prefs!;
        if (_sessionId != null) {
          await prefs.setInt('session_id', _sessionId!);
        }

        // 启动心跳定时器（每 2 分钟发送一次心跳）
        _heartbeatTimer?.cancel();
        _heartbeatTimer = Timer.periodic(
          const Duration(minutes: 2),
          (_) => _sendHeartbeat(),
        );

        // 启动活动日志批量上报定时器（每 30 秒上报一次）
        _activityFlushTimer?.cancel();
        _activityFlushTimer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => _flushActivityLogs(),
        );

        AppLogger.i('SessionTracker', '会话启动成功 - ID: $_sessionId');
      } else {
        AppLogger.e('SessionTracker', '会话启动失败: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      AppLogger.e('SessionTracker', '会话启动异常: $e');
    }
  }

  /// 结束会话
  /// 登出或应用退出时调用
  Future<void> endSession() async {
    if (!_isTracking) return;

    try {
      AppLogger.i('SessionTracker', '结束会话 - ID: $_sessionId');

      // 先上报剩余活动日志
      await _flushActivityLogs();

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/session/end'),
            headers: _authHeaders,
            body: jsonEncode({
              if (_sessionId != null) 'sessionId': _sessionId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        AppLogger.i('SessionTracker', '会话结束成功');
      } else {
        AppLogger.e('SessionTracker', '会话结束失败: ${response.statusCode}');
      }
    } catch (e) {
      AppLogger.e('SessionTracker', '会话结束异常: $e');
    } finally {
      _isTracking = false;
      _sessionId = null;
      _sessionStartTime = null;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _activityFlushTimer?.cancel();
      _activityFlushTimer = null;
      _activityBuffer.clear();

      // 清除本地保存的会话 ID
      AppSettings.prefs!.remove('session_id');
    }
  }

  /// 发送心跳
  Future<void> _sendHeartbeat() async {
    if (!_isTracking || !AuthService.instance.isLoggedIn) return;

    try {
      await http
          .post(
            Uri.parse('$_baseUrl/api/session/heartbeat'),
            headers: _authHeaders,
            body: jsonEncode({
              if (_sessionId != null) 'sessionId': _sessionId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      AppLogger.d('SessionTracker', '心跳已发送');
    } catch (e) {
      AppLogger.w('SessionTracker', '心跳发送失败: $e');
    }
  }

  /// 记录页面访问活动
  /// 在页面切换时调用
  void logPageView(String pageName, {String? details}) {
    if (!_isTracking) return;

    _currentPage = pageName;
    _activityBuffer.add({
      'activityType': 'page_view',
      'pageName': pageName,
      'details': details,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    AppLogger.d('SessionTracker', '页面访问: $pageName');

    // 如果缓冲区超过 20 条，立即上报
    if (_activityBuffer.length >= 20) {
      _flushActivityLogs();
    }
  }

  /// 记录用户操作活动
  void logActivity(String activityType, {String? pageName, String? details}) {
    if (!_isTracking) return;

    _activityBuffer.add({
      'activityType': activityType,
      'pageName': pageName ?? _currentPage,
      'details': details,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    AppLogger.d('SessionTracker', '用户活动: $activityType');

    // 如果缓冲区超过 20 条，立即上报
    if (_activityBuffer.length >= 20) {
      _flushActivityLogs();
    }
  }

  /// 批量上报活动日志
  Future<void> _flushActivityLogs() async {
    if (_activityBuffer.isEmpty || !_isTracking || !AuthService.instance.isLoggedIn) return;

    // 取出当前缓冲区的日志
    final logs = List<Map<String, dynamic>>.from(_activityBuffer);
    _activityBuffer.clear();

    try {
      // 逐条上报
      for (final log in logs) {
        await http
            .post(
              Uri.parse('$_baseUrl/api/activity/log'),
              headers: _authHeaders,
              body: jsonEncode(log),
            )
            .timeout(const Duration(seconds: 5));
      }
      AppLogger.d('SessionTracker', '活动日志上报成功: ${logs.length} 条');
    } catch (e) {
      AppLogger.w('SessionTracker', '活动日志上报失败: $e');
      // 上报失败时将日志放回缓冲区（最多保留 50 条）
      if (_activityBuffer.length + logs.length <= 50) {
        _activityBuffer.addAll(logs);
      }
    }
  }

  /// 获取设备信息
  Future<String> _getDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        return '${android.manufacturer} ${android.model} (Android ${android.version.release})';
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        return '${ios.utsname.machine} (iOS ${ios.systemVersion})';
      } else {
        return 'Unknown Device';
      }
    } catch (e) {
      return 'Device Info Unavailable';
    }
  }

  /// 应用进入后台时暂停心跳
  void onAppPaused() {
    if (!_isTracking) return;
    AppLogger.i('SessionTracker', '应用进入后台，暂停心跳');
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // 上报剩余活动日志
    _flushActivityLogs();
  }

  /// 应用恢复前台时恢复心跳
  void onAppResumed() {
    if (!_isTracking) return;
    AppLogger.i('SessionTracker', '应用恢复前台，恢复心跳');
    // 立即发送一次心跳
    _sendHeartbeat();
    // 重启心跳定时器
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _sendHeartbeat(),
    );
  }
}
