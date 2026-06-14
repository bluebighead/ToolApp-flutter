// 网速测试用户设置读写工具
// 持久化三个字段：是否启用自定义目标 URL、自定义 URL 字符串、显示模式（int 枚举 index）
import 'app_settings.dart';

/// 网速测试设置快照
typedef NetworkSpeedSettingsSnapshot = ({
  bool useCustom,
  String url,
  int displayMode,
});

/// 网速测试设置读写工具
class NetworkSpeedSettings {
  /// SharedPreferences 键：是否启用自定义目标
  static const String _kKeyUseCustom = 'networkspeed_use_custom_url';

  /// SharedPreferences 键：自定义目标 URL 字符串
  static const String _kKeyCustomUrl = 'networkspeed_custom_url';

  /// SharedPreferences 键：显示模式（int 枚举 index）
  static const String _kKeyDisplayMode = 'networkspeed_display_mode';

  /// 从 SharedPreferences 读取设置
  /// 缺失字段时返回默认值：useCustom=false, url='', displayMode=0
  static Future<NetworkSpeedSettingsSnapshot> load() async {
    final prefs = AppSettings.prefs!;
    final useCustom = prefs.getBool(_kKeyUseCustom) ?? false;
    final url = prefs.getString(_kKeyCustomUrl) ?? '';
    final displayMode = prefs.getInt(_kKeyDisplayMode) ?? 0;
    return (useCustom: useCustom, url: url, displayMode: displayMode);
  }

  /// 写入设置；只持久化非 null 的字段，保留其他字段的现有值
  static Future<void> save({
    bool? useCustom,
    String? url,
    int? displayMode,
  }) async {
    final prefs = AppSettings.prefs!;
    if (useCustom != null) {
      await prefs.setBool(_kKeyUseCustom, useCustom);
    }
    if (url != null) {
      await prefs.setString(_kKeyCustomUrl, url);
    }
    if (displayMode != null) {
      await prefs.setInt(_kKeyDisplayMode, displayMode);
    }
  }
}
