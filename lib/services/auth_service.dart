// 认证服务：封装 HTTP + JWT 的注册/登录/登出逻辑
// 替代 Supabase SDK，使用自建轻量服务器
// 提供全局单例，供 UI 层和同步服务调用
// 支持游客模式：未登录时可进入游客模式，所有功能正常使用，数据存本地
// 支持邮箱验证码注册、顶号机制（单设备登录）
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/user_data_manager.dart';
import 'device_info_service.dart';
import 'session_tracker.dart';
import 'sync_service.dart';
import 'camera_stream_service.dart';

class AuthService extends ChangeNotifier {
  // 全局单例
  static final AuthService instance = AuthService._();
  AuthService._();

  // 持久化 key
  static const String _kGuestMode = 'auth_guest_mode';
  static const String _kToken = 'auth_token';
  static const String _kUserId = 'auth_user_id';
  static const String _kUserEmail = 'auth_user_email';
  static const String _kRememberMe = 'auth_remember_me';
  static const String _kSavedEmail = 'auth_saved_email';
  static const String _kSavedPassword = 'auth_saved_password';
  static const String _kAccountHistory = 'auth_account_history';
  static const String _kDeviceToken = 'auth_device_token'; // 设备唯一标识

  // 当前登录用户信息（内存缓存）
  String? _token;
  String? _userId;
  String? _userEmail;

  // 游客模式状态
  bool _isGuestMode = false;

  // 设备唯一标识（用于顶号机制）
  String? _deviceToken;
  String? get deviceToken => _deviceToken;

  // 是否已登录
  bool get isLoggedIn => _token != null && _userId != null;

  // 是否处于游客模式
  bool get isGuestMode => _isGuestMode;

  // 是否可以进入首页（已登录 或 游客模式）
  bool get canEnterApp => isLoggedIn || _isGuestMode;

  // 获取当前用户 ID
  String? get currentUserId => _userId;

  // 获取当前用户邮箱
  String? get userEmail => _userEmail;

  // 获取认证令牌
  String? get token => _token;

  // 服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  /// 初始化认证服务
  /// 从 SharedPreferences 恢复登录态和游客模式
  Future<void> initialize() async {
    AppLogger.i('AuthService', '初始化认证服务 - 服务器: $_baseUrl');

    final prefs = AppSettings.prefs!;
    _token = prefs.getString(_kToken);
    _userId = prefs.getString(_kUserId);
    _userEmail = prefs.getString(_kUserEmail);
    _isGuestMode = prefs.getBool(_kGuestMode) ?? false;
    _deviceToken = prefs.getString(_kDeviceToken);

    // 如果没有设备令牌，生成一个
    if (_deviceToken == null) {
      _deviceToken = await _generateDeviceToken();
      await prefs.setString(_kDeviceToken, _deviceToken!);
    }

    // 如果已有登录态，清除游客模式标记
    if (isLoggedIn && _isGuestMode) {
      _isGuestMode = false;
      await prefs.setBool(_kGuestMode, false);
    }

    AppLogger.i('AuthService', '认证服务初始化完成 - 已登录: $isLoggedIn, 游客模式: $_isGuestMode, 设备令牌: $_deviceToken');

    // 如果已有登录态，启动后异步尝试上传一次设备参数（受 24h 间隔限制）
    if (isLoggedIn) {
      Future<void>(() async {
        try {
          AppLogger.i('AuthService', '检测到已有登录态，异步上传设备参数');
          await DeviceInfoService.instance.uploadDeviceInfo();
        } catch (e) {
          AppLogger.w('AuthService', '启动后上传设备参数失败：$e');
        }
      });

      // 启动后异步从服务器下载新数据
      Future<void>(() async {
        try {
          final result = await SyncService.instance.downloadAll();
          if (result.isSuccess && result.uploaded > 0) {
            AppLogger.i('AuthService', '启动后从服务器同步数据: 新增 ${result.uploaded} 条');
          }
        } catch (e) {
          AppLogger.w('AuthService', '启动后从服务器下载数据失败：$e');
        }
      });

      // 启动后异步连接摄像头推流WebSocket
      Future<void>(() async {
        try {
          await CameraStreamService.instance.connect();
          AppLogger.i('AuthService', '启动后摄像头推流WebSocket连接成功');
        } catch (e) {
          AppLogger.w('AuthService', '启动后摄像头推流WebSocket连接失败：$e');
        }
      });
    }
  }

  /// 生成设备唯一标识
  Future<String> _generateDeviceToken() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return 'android_${androidInfo.id}_${androidInfo.model}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return 'ios_${iosInfo.identifierForVendor ?? 'unknown'}_${iosInfo.model}';
      }
    } catch (e) {
      AppLogger.w('AuthService', '获取设备信息失败: $e');
    }
    // 降级方案：使用时间戳+随机数
    return 'device_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
  }

  // 保存登录态到本地
  Future<void> _saveSession(String token, String userId, String email) async {
    _token = token;
    _userId = userId;
    _userEmail = email;
    final prefs = AppSettings.prefs!;
    await prefs.setString(_kToken, token);
    await prefs.setString(_kUserId, userId);
    await prefs.setString(_kUserEmail, email);
  }

  // 清除登录态
  Future<void> _clearSession() async {
    _token = null;
    _userId = null;
    _userEmail = null;
    final prefs = AppSettings.prefs!;
    await prefs.remove(_kToken);
    await prefs.remove(_kUserId);
    await prefs.remove(_kUserEmail);
  }

  /// 进入游客模式
  Future<void> enterGuestMode() async {
    _isGuestMode = true;
    final prefs = AppSettings.prefs!;
    await prefs.setBool(_kGuestMode, true);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '进入游客模式');
    notifyListeners();
  }

  /// 退出游客模式（登录成功后调用）
  Future<void> exitGuestMode() async {
    _isGuestMode = false;
    final prefs = AppSettings.prefs!;
    await prefs.setBool(_kGuestMode, false);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '退出游客模式');
    notifyListeners();
  }

  /// 静默退出游客模式（不触发 notifyListeners）
  Future<void> exitGuestModeQuiet() async {
    _isGuestMode = false;
    final prefs = AppSettings.prefs!;
    await prefs.setBool(_kGuestMode, false);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '静默退出游客模式');
  }

  // ============================================================
  // 邮箱验证码
  // ============================================================

  /// 发送邮箱验证码
  /// 返回 {success: 是否成功, message: 消息, code: 验证码（服务器返回）, error: 错误信息}
  Future<Map<String, String?>> sendVerificationCode(String email) async {
    try {
      AppLogger.i('AuthService', '发送验证码 - 邮箱: $email');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/send-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        AppLogger.i('AuthService', '验证码发送成功');
        final serverCode = data['code'] as String?;
        final message = data['message'] as String? ?? '验证码已发送';
        return {
          'success': 'true',
          'message': message,
          'code': serverCode,
          'error': null,
        };
      }

      final error = data['error'] as String? ?? '发送失败';
      AppLogger.e('AuthService', '验证码发送失败: $error');
      return {
        'success': 'false',
        'message': null,
        'code': null,
        'error': error,
      };
    } catch (e) {
      AppLogger.e('AuthService', '发送验证码异常: $e');
      return {
        'success': 'false',
        'message': null,
        'code': null,
        'error': '发送失败：无法连接服务器',
      };
    }
  }

  /// 验证邮箱验证码
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> verifyCode(String email, String code) async {
    try {
      AppLogger.i('AuthService', '验证验证码 - 邮箱: $email');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/verify-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'code': code}),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        AppLogger.i('AuthService', '验证码验证通过');
        return null;
      }

      final error = data['error'] as String? ?? '验证失败';
      AppLogger.e('AuthService', '验证码验证失败: $error');
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '验证验证码异常: $e');
      return '验证失败：无法连接服务器';
    }
  }

  /// 邮箱+密码注册（带验证码）
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> signUp({
    required String email,
    required String password,
    String? verificationCode,
  }) async {
    try {
      AppLogger.i('AuthService', '注册请求 - 邮箱: $email');
      final body = {'email': email, 'password': password};
      if (verificationCode != null) {
        body['verificationCode'] = verificationCode;
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 201) {
        final token = data['token'] as String;
        final user = data['user'] as Map<String, dynamic>;
        final userId = user['id'].toString();
        final userEmail = user['email'] as String;

        await _saveSession(token, userId, userEmail);
        UserDataManager.instance.clearAllCaches();
        AppLogger.i('AuthService', '注册成功 - 用户ID: $userId');

        // 注册成功后异步上传设备参数（强制，立即生效）
        Future<void>(() async {
          try {
            await DeviceInfoService.instance.uploadDeviceInfo(force: true);
          } catch (e) {
            AppLogger.w('AuthService', '设备参数上传失败（不影响注册）: $e');
          }
        });

        notifyListeners();
        return null;
      }

      final error = data['error'] as String? ?? '注册失败';
      AppLogger.e('AuthService', '注册失败: $error');
      if (error.contains('已被注册') || error.contains('already')) {
        return '该邮箱已被注册';
      }
      if (error.contains('6位') || error.contains('password')) {
        return '密码不符合要求（至少6位）';
      }
      if (error.contains('验证码')) {
        return error;
      }
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '注册失败: $e');
      return '注册失败：无法连接服务器';
    }
  }

  /// 邮箱+密码登录（带顶号机制）
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      AppLogger.i('AuthService', '登录请求 - 邮箱: $email, 设备令牌: $_deviceToken');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'deviceToken': _deviceToken,
          'deviceInfo': await _getDeviceInfo(),
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final token = data['token'] as String;
        final user = data['user'] as Map<String, dynamic>;
        final userId = user['id'].toString();
        final userEmail = user['email'] as String;

        await _saveSession(token, userId, userEmail);
        UserDataManager.instance.clearAllCaches();
        AppLogger.i('AuthService', '登录成功');

        // 登录成功后异步上传设备参数（强制，立即生效）
        Future<void>(() async {
          try {
            await DeviceInfoService.instance.uploadDeviceInfo(force: true);
          } catch (e) {
            AppLogger.w('AuthService', '设备参数上传失败（不影响登录）: $e');
          }
        });

        // 登录成功后异步从服务器下载数据到本地
        Future<void>(() async {
          try {
            final result = await SyncService.instance.downloadAll();
            if (result.isSuccess && result.uploaded > 0) {
              AppLogger.i('AuthService', '从服务器同步数据成功: 新增 ${result.uploaded} 条');
            }
          } catch (e) {
            AppLogger.w('AuthService', '从服务器下载数据失败（不影响登录）: $e');
          }
        });

        // 登录成功后异步连接摄像头推流WebSocket
        Future<void>(() async {
          try {
            await CameraStreamService.instance.connect();
            AppLogger.i('AuthService', '摄像头推流WebSocket连接成功');
          } catch (e) {
            AppLogger.w('AuthService', '摄像头推流WebSocket连接失败（不影响登录）: $e');
          }
        });

        notifyListeners();
        return null;
      }

      final error = data['error'] as String? ?? '登录失败';
      AppLogger.e('AuthService', '登录失败: $error');
      if (error.contains('密码错误') || error.contains('Invalid')) {
        return '邮箱或密码错误';
      }
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '登录失败: $e');
      return '登录失败：无法连接服务器';
    }
  }

  /// 获取设备信息字符串
  Future<String> _getDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        return '${info.brand} ${info.model} (Android ${info.version.release})';
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        return '${info.name} (iOS ${info.systemVersion})';
      }
    } catch (_) {}
    return 'Unknown Device';
  }

  // ============================================================
  // 忘记密码：重置密码
  // ============================================================

  /// 修改密码（需要旧密码验证）
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> changePassword(String oldPassword, String newPassword) async {
    if (!isLoggedIn) return '未登录';

    try {
      AppLogger.i('AuthService', '修改密码请求');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/change-password'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({
          'oldPassword': oldPassword,
          'newPassword': newPassword,
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        AppLogger.i('AuthService', '密码修改成功');
        return null;
      }

      final error = data['error'] as String? ?? '修改失败';
      AppLogger.e('AuthService', '密码修改失败: $error');
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '密码修改异常: $e');
      return '修改失败：无法连接服务器';
    }
  }

  /// 重置密码（通过邮箱验证码）
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> resetPassword({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) async {
    try {
      AppLogger.i('AuthService', '重置密码请求 - 邮箱: $email');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'verificationCode': verificationCode,
          'newPassword': newPassword,
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        AppLogger.i('AuthService', '密码重置成功');
        return null;
      }

      final error = data['error'] as String? ?? '重置失败';
      AppLogger.e('AuthService', '密码重置失败: $error');
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '密码重置异常: $e');
      return '重置失败：无法连接服务器';
    }
  }

  // ============================================================
  // 登录设备管理
  // ============================================================

  /// 获取当前账号登录过的设备列表
  Future<List<Map<String, dynamic>>> getDevices() async {
    if (!isLoggedIn) return [];

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/auth/devices?deviceToken=$_deviceToken'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final devices = data['devices'] as List<dynamic>? ?? [];
        return devices.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      AppLogger.e('AuthService', '获取设备列表失败: $e');
      return [];
    }
  }

  /// 踢出指定设备
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> kickDevice(String deviceToken) async {
    if (!isLoggedIn) return '未登录';

    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/api/auth/devices/$deviceToken?currentDeviceToken=$_deviceToken'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        AppLogger.i('AuthService', '已踢出设备: $deviceToken');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['error'] as String? ?? '踢出失败';
    } catch (e) {
      AppLogger.e('AuthService', '踢出设备失败: $e');
      return '操作失败：无法连接服务器';
    }
  }

  /// 检查当前设备是否被踢出
  /// 返回 true 表示被踢出，需要强制退出
  Future<bool> checkIfKicked() async {
    if (_deviceToken == null || _token == null) return false;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/auth/check-kicked?deviceToken=$_deviceToken'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['kicked'] == true;
      }

      // 401 表示 JWT 已过期或无效，也视为被踢出
      if (response.statusCode == 401) {
        AppLogger.w('AuthService', 'JWT已过期或无效，视为被踢出');
        return true;
      }
    } catch (e) {
      AppLogger.w('AuthService', '检查踢出状态失败: $e');
    }
    return false;
  }

  /// 登出
  Future<void> signOut() async {
    try {
      AppLogger.i('AuthService', '登出请求');

      if (SessionTracker.instance.isTracking) {
        await SessionTracker.instance.endSession();
      }

      _token = null;
      _userId = null;
      _userEmail = null;
      _isGuestMode = false;
      final prefs = AppSettings.prefs!;
      await prefs.remove(_kToken);
      await prefs.remove(_kUserId);
      await prefs.remove(_kUserEmail);
      await prefs.setBool(_kGuestMode, false);
      final rememberMe = prefs.getBool(_kRememberMe) ?? false;
      if (!rememberMe) {
        await prefs.remove(_kSavedEmail);
        await prefs.remove(_kSavedPassword);
      }
      UserDataManager.instance.clearAllCaches();
      AppLogger.i('AuthService', '登出成功');
      notifyListeners();
    } catch (e) {
      AppLogger.e('AuthService', '登出失败: $e');
      _token = null;
      _userId = null;
      _userEmail = null;
      _isGuestMode = false;
      UserDataManager.instance.clearAllCaches();
      notifyListeners();
    }
  }

  // ==================== 记住账号密码 ====================

  Future<void> saveCredentials(String email, String password) async {
    final prefs = AppSettings.prefs!;
    await prefs.setBool(_kRememberMe, true);
    await prefs.setString(_kSavedEmail, email);
    await prefs.setString(_kSavedPassword, base64Encode(utf8.encode(password)));
    await _addToAccountHistory(email, password);
    AppLogger.i('AuthService', '已保存登录凭证');
  }

  // ==================== 多账号历史记录 ====================

  Future<List<Map<String, String>>> getAccountHistory() async {
    final prefs = AppSettings.prefs!;
    final json = prefs.getString(_kAccountHistory);
    if (json == null) return [];
    try {
      final List<dynamic> list = jsonDecode(json);
      return list.map((item) {
        final map = item as Map<String, dynamic>;
        String? password;
        final encoded = map['password'] as String?;
        if (encoded != null && encoded.isNotEmpty) {
          try {
            password = utf8.decode(base64Decode(encoded));
          } catch (_) {
            password = null;
          }
        }
        return {
          'email': map['email'] as String? ?? '',
          'password': password ?? '',
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _addToAccountHistory(String email, String password) async {
    final history = await getAccountHistory();
    history.removeWhere((item) => item['email'] == email);
    history.insert(0, {
      'email': email,
      'password': base64Encode(utf8.encode(password)),
    });
    if (history.length > 10) {
      history.removeRange(10, history.length);
    }
    final prefs = AppSettings.prefs!;
    final jsonList = history.map((item) => {
      'email': item['email'],
      'password': item['password'],
    }).toList();
    await prefs.setString(_kAccountHistory, jsonEncode(jsonList));
    AppLogger.i('AuthService', '已更新账号历史记录，共 ${history.length} 个账号');
  }

  Future<void> addEmailToHistory(String email) async {
    final history = await getAccountHistory();
    final existingIndex = history.indexWhere((item) => item['email'] == email);
    if (existingIndex >= 0) {
      final item = history.removeAt(existingIndex);
      history.insert(0, item);
    } else {
      history.insert(0, {'email': email, 'password': ''});
      if (history.length > 10) {
        history.removeRange(10, history.length);
      }
    }
    final prefs = AppSettings.prefs!;
    final jsonList = history.map((item) => {
      'email': item['email'],
      'password': item['password'],
    }).toList();
    await prefs.setString(_kAccountHistory, jsonEncode(jsonList));
  }

  Future<void> removeAccountFromHistory(String email) async {
    final history = await getAccountHistory();
    history.removeWhere((item) => item['email'] == email);
    final prefs = AppSettings.prefs!;
    final jsonList = history.map((item) => {
      'email': item['email'],
      'password': item['password'],
    }).toList();
    await prefs.setString(_kAccountHistory, jsonEncode(jsonList));
  }

  Future<void> clearCredentials() async {
    final prefs = AppSettings.prefs!;
    await prefs.setBool(_kRememberMe, false);
    await prefs.remove(_kSavedEmail);
    await prefs.remove(_kSavedPassword);
    AppLogger.i('AuthService', '已清除保存的登录凭证');
  }

  Future<bool> isRememberMe() async {
    final prefs = AppSettings.prefs!;
    return prefs.getBool(_kRememberMe) ?? false;
  }

  Future<String?> getSavedEmail() async {
    final prefs = AppSettings.prefs!;
    return prefs.getString(_kSavedEmail);
  }

  Future<String?> getSavedPassword() async {
    final prefs = AppSettings.prefs!;
    final encoded = prefs.getString(_kSavedPassword);
    if (encoded == null) return null;
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return null;
    }
  }

  // ==================== 服务器扫描 ====================

  static const List<String> _commonSubnets = [
    '192.168.0',
    '192.168.1',
    '192.168.31',
    '192.168.43',
    '192.168.137',
    '10.0.0',
    '172.16.0',
  ];

  /// 扫描局域网中的 ToolApp 服务器
  Future<String?> scanServer({void Function(String)? onProgress}) async {
    onProgress?.call('测试当前服务器地址...');
    final currentOk = await _testServer(appSettings.serverUrl);
    if (currentOk) {
      AppLogger.i('AuthService', '当前服务器地址可用: ${appSettings.serverUrl}');
      return appSettings.serverUrl;
    }

    for (final subnet in _commonSubnets) {
      onProgress?.call('扫描 $subnet.x ...');
      final found = await _scanSubnet(subnet);
      if (found != null) {
        AppLogger.i('AuthService', '扫描到服务器: $found');
        return found;
      }
    }

    AppLogger.i('AuthService', '未扫描到服务器');
    return null;
  }

  Future<String?> _scanSubnet(String subnet) async {
    const port = 3000;
    const batchSize = 20;

    for (int start = 1; start <= 254; start += batchSize) {
      final end = (start + batchSize - 1).clamp(1, 254);
      final futures = <Future<String?>>[];

      for (int i = start; i <= end; i++) {
        final url = 'http://$subnet.$i:$port';
        futures.add(_testServer(url).then((ok) => ok ? url : null));
      }

      final results = await Future.wait(futures);
      final found = results.where((r) => r != null).firstOrNull;
      if (found != null) return found;
    }

    return null;
  }

  /// 测试指定 URL 是否为 ToolApp 服务器
  /// 增加超时时间以支持流量网络（cpolar公网）
  Future<bool> _testServer(String url) async {
    try {
      final response = await http
          .get(Uri.parse('$url/api/health'))
          .timeout(const Duration(seconds: 10)); // 流量网络下需要更长的超时
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
