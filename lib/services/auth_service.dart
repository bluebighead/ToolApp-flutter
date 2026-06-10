// 认证服务：封装 HTTP + JWT 的注册/登录/登出逻辑
// 替代 Supabase SDK，使用自建轻量服务器
// 提供全局单例，供 UI 层和同步服务调用
// 支持游客模式：未登录时可进入游客模式，所有功能正常使用，数据存本地
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/user_data_manager.dart';

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

  // 当前登录用户信息（内存缓存）
  String? _token;
  String? _userId;
  String? _userEmail;

  // 游客模式状态
  bool _isGuestMode = false;

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

    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    _userId = prefs.getString(_kUserId);
    _userEmail = prefs.getString(_kUserEmail);
    _isGuestMode = prefs.getBool(_kGuestMode) ?? false;

    // 如果已有登录态，清除游客模式标记
    if (isLoggedIn && _isGuestMode) {
      _isGuestMode = false;
      await prefs.setBool(_kGuestMode, false);
    }

    AppLogger.i('AuthService', '认证服务初始化完成 - 已登录: $isLoggedIn, 游客模式: $_isGuestMode');
  }

  // 保存登录态到本地
  Future<void> _saveSession(String token, String userId, String email) async {
    _token = token;
    _userId = userId;
    _userEmail = email;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
    await prefs.setString(_kUserId, userId);
    await prefs.setString(_kUserEmail, email);
  }

  // 清除登录态
  Future<void> _clearSession() async {
    _token = null;
    _userId = null;
    _userEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUserId);
    await prefs.remove(_kUserEmail);
  }

  /// 进入游客模式
  /// 跳过登录直接使用应用，数据仅存本地
  Future<void> enterGuestMode() async {
    _isGuestMode = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGuestMode, true);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '进入游客模式');
    notifyListeners();
  }

  /// 退出游客模式（登录成功后调用）
  /// 清除游客标记，数据将同步到服务器
  Future<void> exitGuestMode() async {
    _isGuestMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGuestMode, false);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '退出游客模式');
    notifyListeners();
  }

  /// 静默退出游客模式（不触发 notifyListeners）
  /// 用于 AuthWrapper 回调中避免递归通知
  Future<void> exitGuestModeQuiet() async {
    _isGuestMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGuestMode, false);
    UserDataManager.instance.clearAllCaches();
    AppLogger.i('AuthService', '静默退出游客模式');
  }

  /// 邮箱+密码注册
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> signUp({
    required String email,
    required String password,
  }) async {
    try {
      AppLogger.i('AuthService', '注册请求 - 邮箱: $email');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 201) {
        // 注册成功，自动登录
        final token = data['token'] as String;
        final user = data['user'] as Map<String, dynamic>;
        final userId = user['id'].toString();
        final userEmail = user['email'] as String;

        await _saveSession(token, userId, userEmail);
        UserDataManager.instance.clearAllCaches();
        AppLogger.i('AuthService', '注册成功 - 用户ID: $userId');
        notifyListeners();
        return null;
      }

      // 注册失败
      final error = data['error'] as String? ?? '注册失败';
      AppLogger.e('AuthService', '注册失败: $error');
      // 翻译常见错误
      if (error.contains('已被注册') || error.contains('already')) {
        return '该邮箱已被注册';
      }
      if (error.contains('6位') || error.contains('password')) {
        return '密码不符合要求（至少6位）';
      }
      return error;
    } catch (e) {
      AppLogger.e('AuthService', '注册失败: $e');
      return '注册失败：无法连接服务器';
    }
  }

  /// 邮箱+密码登录
  /// 返回 null 表示成功，否则返回错误信息
  Future<String?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      AppLogger.i('AuthService', '登录请求 - 邮箱: $email');
      final response = await http.post(
        Uri.parse('$_baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        // 登录成功
        final token = data['token'] as String;
        final user = data['user'] as Map<String, dynamic>;
        final userId = user['id'].toString();
        final userEmail = user['email'] as String;

        await _saveSession(token, userId, userEmail);
        UserDataManager.instance.clearAllCaches();
        AppLogger.i('AuthService', '登录成功');
        notifyListeners();
        return null;
      }

      // 登录失败
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

  /// 登出
  Future<void> signOut() async {
    try {
      AppLogger.i('AuthService', '登出请求');
      _token = null;
      _userId = null;
      _userEmail = null;
      _isGuestMode = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kToken);
      await prefs.remove(_kUserId);
      await prefs.remove(_kUserEmail);
      await prefs.setBool(_kGuestMode, false);
      // 登出时如果未勾选记住密码，清除保存的密码
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
      // 即使 SharedPreferences 操作失败，也要通知 UI 更新
      _token = null;
      _userId = null;
      _userEmail = null;
      _isGuestMode = false;
      UserDataManager.instance.clearAllCaches();
      notifyListeners();
    }
  }

  // ==================== 记住账号密码 ====================

  /// 保存账号密码（登录成功时调用）
  /// 密码使用 base64 编码存储，避免明文
  Future<void> saveCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRememberMe, true);
    await prefs.setString(_kSavedEmail, email);
    await prefs.setString(_kSavedPassword, base64Encode(utf8.encode(password)));
    AppLogger.i('AuthService', '已保存登录凭证');
  }

  /// 清除保存的账号密码（取消记住密码时调用）
  Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRememberMe, false);
    await prefs.remove(_kSavedEmail);
    await prefs.remove(_kSavedPassword);
    AppLogger.i('AuthService', '已清除保存的登录凭证');
  }

  /// 是否勾选了记住密码
  Future<bool> isRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kRememberMe) ?? false;
  }

  /// 获取保存的邮箱
  Future<String?> getSavedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSavedEmail);
  }

  /// 获取保存的密码（解码 base64）
  Future<String?> getSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_kSavedPassword);
    if (encoded == null) return null;
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return null;
    }
  }

  // ==================== 服务器扫描 ====================

  // 常见局域网子网前缀
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
  /// 返回找到的服务器 URL，未找到返回 null
  /// 扫描策略：先测试当前设置地址，再扫描常见子网
  Future<String?> scanServer({void Function(String)? onProgress}) async {
    // 1. 先测试当前设置的服务器地址
    onProgress?.call('测试当前服务器地址...');
    final currentOk = await _testServer(appSettings.serverUrl);
    if (currentOk) {
      AppLogger.i('AuthService', '当前服务器地址可用: ${appSettings.serverUrl}');
      return appSettings.serverUrl;
    }

    // 2. 扫描常见子网
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

  /// 扫描指定子网（并发 20 个一批）
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
  Future<bool> _testServer(String url) async {
    try {
      final response = await http
          .get(Uri.parse('$url/api/health'))
          .timeout(const Duration(milliseconds: 800));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
