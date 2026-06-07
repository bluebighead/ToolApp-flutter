// 应用数据目录统一管理工具
// 集中管理 App 在手机上创建的数据根目录及其子目录。
// 数据根目录位于 App 沙盒的 Documents 目录下，名称为 "ToolApp"，
// 下面按用途划分子目录：
//   - logs/     存放导出的调试日志文件
//   - videos/   存放视频转换后保存的 MP4 等文件
//   - data/     存放其它业务数据（如未来需要持久化的 JSON、缓存文件等）
// 后续如果有新的数据需要落盘，应继续在此新增子目录，不要在业务页面里
// 自行调用 path_provider。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用数据目录统一管理工具
class AppStorage {
  /// 应用数据根目录名称（位于 App 沙盒 Documents 下）
  static const String rootFolderName = 'ToolApp';

  /// 子目录：导出的调试日志
  static const String logsSubFolder = 'logs';

  /// 子目录：视频转换输出文件
  static const String videosSubFolder = 'videos';

  /// 子目录：其它业务数据
  static const String dataSubFolder = 'data';

  /// 缓存：根目录的完整路径
  /// 使用懒加载，第一次访问时初始化
  static String? _rootPathCache;

  /// 获取 App 数据根目录（ToolApp/）的完整路径
  /// 不存在时会自动创建
  static Future<String> getRootPath() async {
    final cached = _rootPathCache;
    if (cached != null) return cached;
    // App 沙盒的 Documents 目录，卸载 App 时会随之删除
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/$rootFolderName');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final path = root.path;
    _rootPathCache = path;
    return path;
  }

  /// 获取指定名称的子目录完整路径，不存在时自动创建
  /// [subFolder] 子目录名称，建议使用本类提供的 logsSubFolder / videosSubFolder / dataSubFolder
  static Future<Directory> getSubDirectory(String subFolder) async {
    final root = await getRootPath();
    final dir = Directory('$root/$subFolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 获取日志导出目录：ToolApp/logs/
  /// 用于保存从 AppLogger 导出的调试日志文件
  static Future<Directory> getLogsDirectory() => getSubDirectory(logsSubFolder);

  /// 获取视频输出目录：ToolApp/videos/
  /// 用于保存视频格式转换后的 MP4 等文件
  static Future<Directory> getVideosDirectory() => getSubDirectory(videosSubFolder);

  /// 获取其它业务数据目录：ToolApp/data/
  static Future<Directory> getDataDirectory() => getSubDirectory(dataSubFolder);
}
