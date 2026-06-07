// 视频转换输出路径设置
// 持久化用户的"自定义保存目录"选择，留空则用 App 私有目录 (ToolApp/videos/converted/)
//
// 设计要点：
//  1) "默认"路径：App 沙盒 Documents/ToolApp/videos/converted/
//     优点：卸载 App 一并清理，无需任何运行时权限
//     缺点：用户从系统文件管理器看不到，必须用"打开目录"按钮
//  2) "自定义"路径：用户通过 SAF 选定的目录（存储的是 SAF tree URI 字符串）
//     优点：视频在系统文件管理器可见（如 Download/Movies 等）
//     缺点：写入 SAF 目录需要原生层配合（见 MainActivity.kt 中新增的 storage 通道）
//
// SAF tree URI 持久化方案：
//  - Dart 端只存"URI 字符串" + 持久化权限（takePersistableUriPermission 在原生层完成）
//  - 写入时调原生 MethodChannel "writeFileToSafTree" 让原生层打开 DocumentFile 并写入
//  - 这样不需要任何 WRITE_EXTERNAL_STORAGE 权限（Scoped Storage 兼容）
import 'package:shared_preferences/shared_preferences.dart';

/// 视频转换路径模式
enum VideoSaveMode {
  /// 默认：App 私有目录（沙盒），卸载 App 一并清理
  defaultSandbox,

  /// 自定义：用户在"设置"中选定的 SAF 目录（系统可见）
  customSaf,
}

/// 视频保存路径设置快照
typedef VideoSaveSettingsSnapshot = ({
  VideoSaveMode mode,
  String? customSafTreeUri,
  String? customDisplayName,
});

/// VideoSaveSettingsSnapshot 的 JSON 序列化扩展
///
/// 放在这里而不是 convert_resume_state.dart 里，
/// 是因为它本质是 SaveSettings 自己的序列化逻辑。
extension VideoSaveSettingsSnapshotJson on VideoSaveSettingsSnapshot {
  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'customSafTreeUri': customSafTreeUri,
        'customDisplayName': customDisplayName,
      };

  static VideoSaveSettingsSnapshot fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = VideoSaveMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => VideoSaveMode.defaultSandbox,
    );
    return (
      mode: mode,
      customSafTreeUri: json['customSafTreeUri'] as String?,
      customDisplayName: json['customDisplayName'] as String?,
    );
  }
}

/// 视频保存路径设置读写工具
class VideoSaveSettings {
  /// SharedPreferences 键：保存模式（int 枚举 index）
  static const String _kKeyMode = 'video_save_mode';

  /// SharedPreferences 键：自定义 SAF tree URI
  static const String _kKeyCustomSafUri = 'video_save_custom_saf_uri';

  /// SharedPreferences 键：自定义目录显示名（仅展示用，原生层不参与）
  static const String _kKeyCustomDisplayName = 'video_save_custom_display_name';

  /// 从 SharedPreferences 读取设置
  /// 缺失字段时返回默认值：默认沙盒模式
  static Future<VideoSaveSettingsSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_kKeyMode) ?? VideoSaveMode.defaultSandbox.index;
    // 防御：越界保护
    final mode = VideoSaveMode.values[
        modeIndex.clamp(0, VideoSaveMode.values.length - 1)];
    final uri = prefs.getString(_kKeyCustomSafUri);
    final name = prefs.getString(_kKeyCustomDisplayName);
    return (
      mode: mode,
      customSafTreeUri: (uri != null && uri.isNotEmpty) ? uri : null,
      customDisplayName: (name != null && name.isNotEmpty) ? name : null,
    );
  }

  /// 写入设置
  /// - 不传 mode 则保留现状；不传 customSafTreeUri/customDisplayName 也不动
  static Future<void> save({
    VideoSaveMode? mode,
    String? customSafTreeUri,
    String? customDisplayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (mode != null) {
      await prefs.setInt(_kKeyMode, mode.index);
    }
    if (customSafTreeUri != null) {
      await prefs.setString(_kKeyCustomSafUri, customSafTreeUri);
    }
    if (customDisplayName != null) {
      await prefs.setString(_kKeyCustomDisplayName, customDisplayName);
    }
  }

  /// 清除自定义路径（恢复默认沙盒模式）
  static Future<void> clearCustom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKeyCustomSafUri);
    await prefs.remove(_kKeyCustomDisplayName);
    await prefs.setInt(_kKeyMode, VideoSaveMode.defaultSandbox.index);
  }
}
