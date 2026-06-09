// 应用数据目录统一管理工具
// 集中管理 App 在手机上创建的数据根目录及其子目录。
// 数据根目录位于 App 沙盒的 Documents 目录下，名称为 "ToolApp"，
// 下面按用途划分子目录：
//   - logs/     存放导出的调试日志文件
//   - videos/   存放视频转换后保存的 MP4 等文件
//   - data/     存放其它业务数据（如未来需要持久化的 JSON、缓存文件等）
// 后续如果有新的数据需要落盘，应继续在此新增子目录，不要在业务页面里
// 自行调用 path_provider。
//
// v1.7.8+ 修复：存储空间统计与系统设置对齐
//   - 用户数据：统计整个 Documents/ 目录（与 Android 系统设置一致）
//   - 缓存：同时统计临时目录和 cache 目录
//   - M3U8 临时文件：统计 cache/ 下的 m3u8_norm_* 目录
//   - 清理：增加对 Documents/ 下断点续转文件和 cache/ 下 M3U8 临时目录的清理
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

  /// v1.7.8+ 修复：获取 App 用户数据总大小（字节）
  /// 统计整个 Documents/ 目录，与 Android 系统设置的"用户数据"一致
  /// 包括：ToolApp/ 子目录 + Documents/ 下的断点续转文件等
  static Future<int> getTotalDataSize() async {
    final docs = await getApplicationDocumentsDirectory();
    return _calcDirSize(docs.path);
  }

  /// v1.7.8+ 修复：获取缓存目录大小（字节）
  /// 同时统计临时目录（getTemporaryDirectory）和缓存目录（getApplicationCacheDirectory）
  /// 与 Android 系统设置的"缓存"更接近
  static Future<int> getCacheDirSize() async {
    int total = 0;
    // 临时目录
    final tempDir = await getTemporaryDirectory();
    total += await _calcDirSize(tempDir.path);
    // 缓存目录（M3U8 临时文件存放在此）
    try {
      final cacheDir = await getApplicationCacheDirectory();
      total += await _calcDirSize(cacheDir.path);
    } catch (_) {
      // 某些平台可能不支持 getApplicationCacheDirectory
    }
    return total;
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

  /// v1.7.8+ 修复：获取 M3U8 临时文件大小
  /// 注意：M3U8 临时文件分布在两个位置：
  ///   1. cache/ 下的 m3u8_norm_* 目录（主要占用来源）—— 已被 getCacheDirSize() 统计
  ///   2. ToolApp/data/ 下的旧版临时文件 —— 已被 getTotalDataSize() 统计
  /// 本方法只统计第2项，避免与缓存重复计算
  static Future<int> getM3u8CopySize() async {
    final dataDir = await getDataDirectory();
    return _calcDirSize(dataDir.path);
  }

  /// v1.7.8+ 修复：获取断点续转状态文件总大小
  /// 统计 Documents/ 下所有 convert_resume_state.json 和 resume_state_* 文件
  static Future<int> getResumeStateSize() async {
    final docs = await getApplicationDocumentsDirectory();
    int total = 0;
    final dir = Directory(docs.path);
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          // 新版断点续转状态文件
          if (name == 'convert_resume_state.json' ||
              name.startsWith('resume_state_')) {
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

  /// v1.7.8+ 修复：清理缓存目录
  /// 同时清理临时目录和缓存目录（包括 M3U8 临时文件）
  /// 返回清理的字节数
  static Future<int> clearCache() async {
    int cleaned = 0;
    // 清理临时目录
    final tempDir = await getTemporaryDirectory();
    cleaned += await _clearDirectory(tempDir.path);
    // 清理缓存目录（包括 M3U8 临时文件）
    try {
      final cacheDir = await getApplicationCacheDirectory();
      cleaned += await _clearDirectory(cacheDir.path);
    } catch (_) {}
    return cleaned;
  }

  /// v1.7.8+ 修复：清理用户数据
  /// 清理范围：
  ///   - ToolApp/videos/  视频输出文件
  ///   - ToolApp/logs/    日志文件
  ///   - ToolApp/data/    临时数据文件
  ///   - Documents/ 下的断点续转状态文件（convert_resume_state.json, resume_state_*）
  ///   - cache/ 下的 M3U8 临时目录（m3u8_norm_*）
  ///   - 临时目录和缓存目录
  /// 保留：SharedPreferences 中的软件配置
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
    // 清理 Documents/ 下的断点续转状态文件
    cleaned += await _clearResumeStateFiles();
    // 清理缓存（包括 M3U8 临时目录）
    cleaned += await clearCache();
    return cleaned;
  }

  /// 清理 Documents/ 下的断点续转状态文件
  /// 包括 convert_resume_state.json 和 resume_state_* 文件
  /// 返回清理的字节数
  static Future<int> _clearResumeStateFiles() async {
    int cleaned = 0;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(docs.path);
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        final name = entity.path.split('/').last;
        if (name == 'convert_resume_state.json' ||
            name.startsWith('resume_state_')) {
          try {
            cleaned += await entity.length();
            await entity.delete();
          } catch (_) {}
        }
      }
    }
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
  final int totalDataSize; // 用户数据总大小（整个 Documents/ 目录）
  final int cacheSize; // 缓存大小（临时目录 + 缓存目录）
  final int videosSize; // 视频输出文件大小
  final int logsSize; // 日志文件大小
  final int m3u8CopySize; // M3U8 临时文件大小（cache/ 下 m3u8_norm_* + ToolApp/data/）
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
