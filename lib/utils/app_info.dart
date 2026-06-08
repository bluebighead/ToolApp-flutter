// 应用信息常量
// 集中存放应用名称、版本、开发者、更新时间等元数据。
// 版本号规则见 PROJECT_RULES.md：每次发版必须同步更新 pubspec.yaml 与本文件。
class AppInfo {
  // 应用名称（与 pubspec.yaml 的 name 字段保持一致概念）
  static const String appName = '实用工具箱';

  // 应用包名（与 pubspec.yaml 的 name 字段保持一致）
  static const String packageName = 'toolapp';

  // 当前版本号（遵循 PROJECT_RULES.md 中的语义化版本规则）
  // 每次发版时同步更新 pubspec.yaml 中的 version 字段
  // v1.6.36+ 升级说明（bug22 修复：续转卡在FFmpeg启动中、暂停按钮状态优化）：
  //   - convert_coordinator.dart 的 resume() 方法中，不再传 onSessionStarting 回调，
  //     避免续转时 UI 进入"FFmpeg 启动中..."状态并卡住。续转期间 UI 保持显示
  //     "正在恢复转换..."直到 FFmpeg 出第一帧，然后切到"正在转换..."
  //   - video_convert_page.dart 的 _onCoordinatorEvent 中，_resuming 只在
  //     hasDuration=true 时才复位，确保"正在恢复转换..."一直显示到真正开始转换
  //   - video_convert_page.dart 的 _buildActionButtons 中，续转准备期间
  //     （_ffmpegSessionStarting 或 _resuming 为 true）暂停按钮不可点击，
  //     取消按钮随时可用
  //   - video_convert_page.dart 的 _syncFromCoordinatorSnapshot 中，状态切到
  //     paused 时复位 _resuming 和 _ffmpegSessionStarting 标志位
  static const String version = '1.6.36';

  // 当前构建号（整数，每次发版递增）
  // 每次发版时同步更新 pubspec.yaml 中 version 字段的 + 号后的数字
  static const int buildNumber = 64;

  // 开发者署名
  static const String developer = 'SuperYH';

  // 最近一次发版的更新时间（格式：yyyy-MM-dd）
  // 每次发版时必须更新到当天日期
  static const String lastUpdate = '2026-06-08';

  // 完整版本字符串，UI 上直接显示使用
  static String get fullVersion => '$version (Build $buildNumber)';

  // 应用一句话简介
  static const String description = '一款轻量、好用的工具集合 App';

  // 版权信息
  static const String copyright = '© 2026 SuperYH. All rights reserved.';
}
