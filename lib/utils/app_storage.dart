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

import 'package:flutter/services.dart';
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

  // ==================== v1.6.56+ 新增：存储空间统计与清理 ====================

  /// 递归计算指定目录的总大小（字节）
  static Future<int> _calcDirSize(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 跳过无法访问的文件
        }
      }
    }
    return total;
  }

  /// 获取视频输出目录大小（字节）：ToolApp/videos/
  static Future<int> getVideosDirSize() async {
    final dir = await getVideosDirectory();
    return _calcDirSize(dir.path);
  }

  /// 获取日志目录大小（字节）：ToolApp/logs/
  static Future<int> getLogsDirSize() async {
    final dir = await getLogsDirectory();
    return _calcDirSize(dir.path);
  }

  /// 获取数据目录大小（字节）：ToolApp/data/
  static Future<int> getDataDirSize() async {
    final dir = await getDataDirectory();
    return _calcDirSize(dir.path);
  }

  /// 获取 App 数据总大小（字节）：ToolApp/ 下所有文件
  static Future<int> getTotalDataSize() async {
    final root = await getRootPath();
    return _calcDirSize(root);
  }

  /// 获取缓存目录大小（字节）：系统临时目录
  static Future<int> getCacheDirSize() async {
    final tempDir = await getTemporaryDirectory();
    return _calcDirSize(tempDir.path);
  }

  /// v1.6.58+ 新增：获取 App 本体大小（APK 大小，字节）
  /// 通过原生 MethodChannel 获取
  static Future<int> getAppApkSize() async {
    try {
      const channel = MethodChannel('com.example.toolapp/storage');
      final size = await channel.invokeMethod<int?>('getAppSize');
      return size ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// v1.6.58+ 新增：获取 M3U8 复制内容目录大小
  /// M3U8 文件在转换前会被复制到 ToolApp/data/ 下的临时目录
  static Future<int> getM3u8CopySize() async {
    final dataDir = await getDataDirectory();
    return _calcDirSize(dataDir.path);
  }

  /// v1.6.58+ 新增：获取断点续转状态文件总大小
  static Future<int> getResumeStateSize() async {
    // 断点续转状态文件存储在应用 Documents 目录下
    final docs = await getApplicationDocumentsDirectory();
    int total = 0;
    final dir = Directory(docs.path);
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          if (name.startsWith('resume_state_')) {
            try {
              total += await entity.length();
            } catch (_) {}
          }
        }
      }
    }
    return total;
  }

  /// v1.6.58+ 新增：存储空间详细信息
  /// 返回各分类的大小，便于 UI 展示
  static Future<StorageDetailInfo> getStorageDetailInfo() async {
    final results = await Future.wait([
      getTotalDataSize(),
      getCacheDirSize(),
      getVideosDirSize(),
      getLogsDirSize(),
      getM3u8CopySize(),
      getResumeStateSize(),
      getAppApkSize(),
    ]);
    return StorageDetailInfo(
      totalDataSize: results[0],
      cacheSize: results[1],
      videosSize: results[2],
      logsSize: results[3],
      m3u8CopySize: results[4],
      resumeStateSize: results[5],
      apkSize: results[6],
    );
  }

  /// 清理缓存目录（系统临时目录下的所有文件）
  /// 返回清理的字节数
  static Future<int> clearCache() async {
    final tempDir = await getTemporaryDirectory();
    return _clearDirectory(tempDir.path);
  }

  /// 清理用户数据中无关紧要的文件（视频输出、日志、临时数据）
  /// 但保留软件配置数据（SharedPreferences 中的设置不受影响）
  /// 返回清理的字节数
  static Future<int> clearJunkData() async {
    int cleaned = 0;
    // 清理视频输出目录
    cleaned += await _clearDirectory(
      (await getVideosDirectory()).path,
    );
    // 清理日志目录
    cleaned += await _clearDirectory(
      (await getLogsDirectory()).path,
    );
    // 清理 data 目录中的临时文件
    cleaned += await _clearDirectory(
      (await getDataDirectory()).path,
    );
    // 清理缓存
    cleaned += await clearCache();
    return cleaned;
  }

  /// 清空指定目录下的所有文件和子目录，但保留目录本身
  /// 返回清理的字节数
  static Future<int> _clearDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    int cleaned = 0;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is File) {
          cleaned += await entity.length();
          await entity.delete();
        } else if (entity is Directory) {
          cleaned += await _calcDirSize(entity.path);
          await entity.delete(recursive: true);
        }
      } catch (_) {
        // 跳过无法删除的文件
      }
    }
    return cleaned;
  }

  /// 格式化字节数为可读字符串
  static String formatBytes(int bytes) {
    if (bytes < 0) return '--';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// v1.6.58+ 新增：存储空间详细信息
class StorageDetailInfo {
  final int totalDataSize; // 用户数据总大小
  final int cacheSize; // 缓存大小
  final int videosSize; // 视频输出文件大小
  final int logsSize; // 日志文件大小
  final int m3u8CopySize; // M3U8 复制内容大小
  final int resumeStateSize; // 断点续转状态文件大小
  final int apkSize; // App 本体（APK）大小

  const StorageDetailInfo({
    required this.totalDataSize,
    required this.cacheSize,
    required this.videosSize,
    required this.logsSize,
    required this.m3u8CopySize,
    required this.resumeStateSize,
    required this.apkSize,
  });

  /// 其他数据 = 总数据 - 视频输出 - 日志 - M3U8复制 - 断点状态
  int get otherDataSize =>
      totalDataSize - videosSize - logsSize - m3u8CopySize - resumeStateSize;

  /// 整体占用 = APK + 用户数据 + 缓存
  int get overallSize => apkSize + totalDataSize + cacheSize;
}
