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
  static const String version = '1.6.18';

  // 当前构建号（整数，每次发版递增）
  // 每次发版时同步更新 pubspec.yaml 中 version 字段的 + 号后的数字
  static const int buildNumber = 44;

  // 开发者署名
  static const String developer = 'SuperYH';

  // 最近一次发版的更新时间（格式：yyyy-MM-dd）
  // 每次发版时必须更新到当天日期
  static const String lastUpdate = '2026-06-07';

  // 完整版本字符串，UI 上直接显示使用
  static String get fullVersion => '$version (Build $buildNumber)';

  // 应用一句话简介
  static const String description = '一款轻量、好用的工具集合 App';

  // 版权信息
  static const String copyright = '© 2026 SuperYH. All rights reserved.';
}
