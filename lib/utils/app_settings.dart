// 应用全局设置服务
// 使用 shared_preferences 持久化用户的偏好设置（屏幕旋转、暗色模式等）
// 通过 ChangeNotifier 通知整个 App 主题/方向发生变化
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

// 应用设置类（继承 ChangeNotifier 以便全局监听变化）
class AppSettings extends ChangeNotifier {
  // SharedPreferences key 常量
  static const String _kAllowRotation = 'settings_allow_rotation';
  static const String _kDarkMode = 'settings_dark_mode';
  static const String _kServerUrl = 'settings_server_url';
  static const String _kAutoSyncInterval = 'settings_auto_sync_interval';

  // 默认服务器地址（自建轻量服务器，cpolar内网穿透公网地址）
  static const String defaultServerUrl = 'http://63e160ef.r18.cpolar.top';
  static const String _defaultServerUrl = defaultServerUrl;

  // 内部 SharedPreferences 实例
  SharedPreferences? _prefs;

  // 是否允许屏幕旋转（默认 false：关闭屏幕旋转）
  bool _allowRotation = false;
  bool get allowRotation => _allowRotation;

  // 是否启用暗色模式（默认 false：使用亮色主题）
  bool _darkMode = false;
  bool get darkMode => _darkMode;

  // 服务器地址
  String _serverUrl = _defaultServerUrl;
  String get serverUrl => _serverUrl;

  // 自动同步间隔（分钟），0 表示关闭自动同步，默认 5 分钟
  int _autoSyncInterval = 5;
  int get autoSyncInterval => _autoSyncInterval;

  // 可选的自动同步间隔列表（分钟）
  static const List<int> autoSyncIntervalOptions = [0, 5, 10, 15, 20, 30, 45, 60];

  // 初始化设置：从 SharedPreferences 读取已保存的偏好
  // 必须在 runApp 之前调用一次以加载历史数据
  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _allowRotation = _prefs?.getBool(_kAllowRotation) ?? false;
      _darkMode = _prefs?.getBool(_kDarkMode) ?? false;
      _serverUrl = _prefs?.getString(_kServerUrl) ?? _defaultServerUrl;
      _autoSyncInterval = _prefs?.getInt(_kAutoSyncInterval) ?? 5;
      AppLogger.i(
        'AppSettings',
        '设置已加载 - 屏幕旋转: $_allowRotation, 暗色模式: $_darkMode, 服务器: $_serverUrl',
      );
    } catch (e, st) {
      // 加载失败时使用默认值，并记录错误
      AppLogger.e('AppSettings', '加载设置失败：$e', e, st);
      _allowRotation = false;
      _darkMode = false;
      _serverUrl = _defaultServerUrl;
    }
    // 应用加载到的初始屏幕方向
    _applyOrientation(_allowRotation);
    // 通知监听者设置已就绪
    notifyListeners();
  }

  // 设置是否允许屏幕旋转
  // 切换后立即将新的方向策略应用到系统，并持久化到本地
  Future<void> setAllowRotation(bool value) async {
    if (_allowRotation == value) return;
    _allowRotation = value;
    AppLogger.i('AppSettings', '屏幕旋转 -> $value');
    // 立即应用屏幕方向变更
    _applyOrientation(value);
    // 持久化到本地
    await _prefs?.setBool(_kAllowRotation, value);
    notifyListeners();
  }

  // 设置是否启用暗色模式
  // 切换后主题会立即变化（由 MaterialApp 的 themeMode 监听）
  Future<void> setDarkMode(bool value) async {
    if (_darkMode == value) return;
    _darkMode = value;
    AppLogger.i('AppSettings', '暗色模式 -> $value');
    await _prefs?.setBool(_kDarkMode, value);
    notifyListeners();
  }

  // 设置服务器地址
  Future<void> setServerUrl(String value) async {
    if (_serverUrl == value) return;
    _serverUrl = value;
    AppLogger.i('AppSettings', '服务器地址 -> $value');
    await _prefs?.setString(_kServerUrl, value);
    notifyListeners();
  }

  // 设置自动同步间隔（分钟），0 表示关闭
  Future<void> setAutoSyncInterval(int value) async {
    if (_autoSyncInterval == value) return;
    _autoSyncInterval = value;
    AppLogger.i('AppSettings', '自动同步间隔 -> $value 分钟');
    await _prefs?.setInt(_kAutoSyncInterval, value);
    notifyListeners();
  }

  // 将屏幕方向设置应用到系统
  // 当关闭时仅允许竖屏；开启时允许所有方向（随屏幕旋转）
  void _applyOrientation(bool allow) {
    if (allow) {
      // 开启：允许所有方向（横屏/竖屏均可）
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // 关闭：仅允许竖屏正方向（默认行为）
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }
}

// 全局 AppSettings 实例（在 main() 中 load 一次即可）
final appSettings = AppSettings();
