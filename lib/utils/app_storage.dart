// 应用数据目录统一管理工具
// 集中管理 App 在手机上创建的数据根目录及其子目录。
//
// v1.35.0+ 重构：
//   数据根目录改为外部存储可读目录（External Storage），不再使用沙盒 Documents。
//   根目录位于：/storage/emulated/0/Android/data/com.example.toolapp/files/ToolApp/
//   用户可通过文件管理器直接访问此目录下的文件。
//
//   子目录结构：
//     output/videos/    视频转换输出文件
//     output/logs/      导出的调试日志文件
//     output/codes/     扫码传信保存的码内容
//     output/data/      其它导出数据
//     output/compress/video/  压缩器-视频输出
//     output/compress/audio/  压缩器-音频输出
//     output/compress/image/  压缩器-图片输出
//     system/cache/     系统缓存文件
//     system/temp/      临时处理文件
//     system/data/      内部业务数据
//     system/m3u8/      M3U8 复制内容（独立于临时目录）
//
// v1.52.0+ 缓存压缩：对于超过阈值的缓存文件，自动进行 zlib 压缩减少占用
//
// 后续如果有新的数据需要落盘，应在此新增子目录，不要在业务页面里自行调用 path_provider。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 应用数据目录统一管理工具
class AppStorage {
  /// 应用数据根目录名称
  static const String rootFolderName = 'ToolApp';

  // ==================== 目录常量定义 ====================

  // --- 输出目录（供用户访问的文件） ---
  static const String outputRoot = 'output';
  static const String outputVideos = 'output/videos';
  static const String outputLogs = 'output/logs';
  static const String outputCodes = 'output/codes';
  static const String outputData = 'output/data';
  // 压缩器数据目录（v1.51.0+ 细分）
  static const String compressRoot = 'output/compress';
  static const String compressVideo = 'output/compress/video';
  static const String compressAudio = 'output/compress/audio';
  static const String compressImage = 'output/compress/image';

  // --- 内部系统目录 ---
  static const String systemRoot = 'system';
  static const String systemCache = 'system/cache';
  static const String systemTemp = 'system/temp';
  static const String systemData = 'system/data';
  static const String systemM3u8 = 'system/m3u8';  // v1.51.0+ M3U8 独立目录

  // --- 兼容旧版本的子目录名 ---
  static const String logsSubFolder = 'output/logs';
  static const String videosSubFolder = 'output/videos';
  static const String dataSubFolder = 'output/data';

  /// 根目录路径缓存
  static String? _rootPathCache;

  /// 获取应用数据根目录（ToolApp/）的完整路径
  ///
  /// v1.35.0+ 优先使用外部存储目录（用户可访问），
  /// 如果外部存储不可用则回退到沙盒 Documents 目录。
  static Future<String> getRootPath() async {
    if (_rootPathCache != null) return _rootPathCache!;

    // 尝试获取外部存储目录（用户可访问）
    Directory root;
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        root = Directory('${extDir.path}/$rootFolderName');
        if (!await root.exists()) {
          await root.create(recursive: true);
        }
        _rootPathCache = root.path;
        return root.path;
      }
    } catch (_) {
      // 外部存储不可用，回退到沙盒
    }

    // 回退到沙盒 Documents 目录
    final docsDir = await getApplicationDocumentsDirectory();
    root = Directory('${docsDir.path}/$rootFolderName');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _rootPathCache = root.path;
    return root.path;
  }

  /// 获取指定名称的子目录完整路径，不存在时自动创建
  static Future<Directory> getSubDirectory(String subFolder) async {
    final root = await getRootPath();
    final dir = Directory('$root/$subFolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 为确保所有子目录提前创建好（app 启动时调用）
  static Future<void> ensureDirectories() async {
    await getSubDirectory(outputVideos);
    await getSubDirectory(outputLogs);
    await getSubDirectory(outputCodes);
    await getSubDirectory(outputData);
    await getSubDirectory(compressVideo);
    await getSubDirectory(compressAudio);
    await getSubDirectory(compressImage);
    await getSubDirectory(systemCache);
    await getSubDirectory(systemTemp);
    await getSubDirectory(systemData);
    await getSubDirectory(systemM3u8);
  }

  // ==================== 便捷获取目录 ====================

  /// 获取视频输出目录
  static Future<Directory> getVideosDirectory() => getSubDirectory(outputVideos);

  /// 获取日志导出目录
  static Future<Directory> getLogsDirectory() => getSubDirectory(outputLogs);

  /// 获取扫码传信保存目录
  static Future<Directory> getCodesDirectory() => getSubDirectory(outputCodes);

  /// 获取输出数据目录
  static Future<Directory> getOutputDataDirectory() => getSubDirectory(outputData);

  /// 获取系统缓存目录
  static Future<Directory> getSystemCacheDirectory() => getSubDirectory(systemCache);

  /// 获取系统临时目录
  static Future<Directory> getSystemTempDirectory() => getSubDirectory(systemTemp);

  /// 获取系统数据目录
  static Future<Directory> getSystemDataDirectory() => getSubDirectory(systemData);

  /// 获取 M3U8 数据目录（v1.51.0+）
  static Future<Directory> getM3u8Directory() => getSubDirectory(systemM3u8);

  /// 获取压缩器视频输出目录（v1.51.0+）
  static Future<Directory> getCompressVideoDirectory() => getSubDirectory(compressVideo);

  /// 获取压缩器音频输出目录（v1.51.0+）
  static Future<Directory> getCompressAudioDirectory() => getSubDirectory(compressAudio);

  /// 获取压缩器图片输出目录（v1.51.0+）
  static Future<Directory> getCompressImageDirectory() => getSubDirectory(compressImage);

  /// 获取输出根目录
  static Future<Directory> getOutputRootDirectory() => getSubDirectory(outputRoot);

  // 兼容旧版 API
  static Future<Directory> getDataDirectory() => getSubDirectory(dataSubFolder);

  // ==================== 存储空间统计与清理 ====================

  /// 递归计算指定目录的总大小（字节）
  static Future<int> _calcDirSize(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// 获取单个目录的大小（字节）
  static Future<int> getDirectorySize(String subFolder) async {
    final dir = await getSubDirectory(subFolder);
    return _calcDirSize(dir.path);
  }

  /// 获取视频输出目录大小
  static Future<int> getVideosDirSize() => getDirectorySize(outputVideos);

  /// 获取日志目录大小
  static Future<int> getLogsDirSize() => getDirectorySize(outputLogs);

  /// 获取扫码传信保存目录大小
  static Future<int> getCodesDirSize() => getDirectorySize(outputCodes);

  /// 获取系统缓存目录大小
  static Future<int> getSystemCacheDirSize() => getDirectorySize(systemCache);

  /// 获取系统临时目录大小
  static Future<int> getSystemTempDirSize() => getDirectorySize(systemTemp);

  /// 获取整个输出目录总大小
  static Future<int> getOutputTotalSize() async {
    final root = await getRootPath();
    final outputDir = Directory('$root/$outputRoot');
    return _calcDirSize(outputDir.path);
  }

  /// 获取整个系统目录总大小
  static Future<int> getSystemTotalSize() async {
    final root = await getRootPath();
    final sysDir = Directory('$root/$systemRoot');
    return _calcDirSize(sysDir.path);
  }

  /// 获取整个 ToolApp 数据目录总大小
  static Future<int> getTotalDataSize() async {
    final root = await getRootPath();
    return _calcDirSize(root);
  }

  /// v1.7.8+ 兼容：获取缓存目录大小（系统临时 + 缓存）
  static Future<int> getCacheDirSize() async {
    int total = 0;
    try {
      total += await getDirectorySize(systemCache);
    } catch (_) {}
    try {
      final tempDir = await getTemporaryDirectory();
      total += await _calcDirSize(tempDir.path);
    } catch (_) {}
    return total;
  }

  /// 获取 App 本体大小（APK 大小）
  static Future<int> getAppApkSize() async {
    try {
      const channel = MethodChannel('com.example.toolapp/storage');
      final size = await channel.invokeMethod<int?>('getAppSize');
      return size ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 获取 M3U8 临时文件大小（v1.51.0+ 使用独立目录）
  static Future<int> getM3u8CopySize() async {
    int total = await getDirectorySize(systemM3u8);
    // 兼容旧数据：也检查旧的临时目录中是否有 M3U8 相关文件
    try {
      total += await getDirectorySize(systemTemp);
    } catch (_) {}
    try {
      final cacheDir = await getApplicationCacheDirectory();
      total += await _calcDirSize(cacheDir.path);
    } catch (_) {
      return total;
    }
    return total;
  }

  /// 获取压缩器视频输出大小（v1.51.0+）
  static Future<int> getCompressVideoSize() => getDirectorySize(compressVideo);

  /// 获取压缩器音频输出大小（v1.51.0+）
  static Future<int> getCompressAudioSize() => getDirectorySize(compressAudio);

  /// 获取压缩器图片输出大小（v1.51.0+）
  static Future<int> getCompressImageSize() => getDirectorySize(compressImage);

  /// 获取断点续转状态文件大小
  static Future<int> getResumeStateSize() async {
    try {
      final root = await getRootPath();
      final systemDataDir = Directory('$root/$systemData');
      return _calcDirSize(systemDataDir.path);
    } catch (_) {
      return 0;
    }
  }

  /// 存储空间详细信息（v1.51.0+ 增加更多细分信息）
  static Future<StorageDetailInfo> getStorageDetailInfo() async {
    final results = await Future.wait([
      getTotalDataSize(),
      getCacheDirSize(),
      getVideosDirSize(),
      getLogsDirSize(),
      getCodesDirSize(),
      getM3u8CopySize(),
      getResumeStateSize(),
      getAppApkSize(),
      getOutputTotalSize(),
      getSystemTotalSize(),
      getSystemCacheDirSize(),
      getSystemTempDirSize(),
      getOutputDataDirectory().then((d) => _calcDirSize(d.path)),
      getCompressVideoSize(),
      getCompressAudioSize(),
      getCompressImageSize(),
    ]);
    return StorageDetailInfo(
      totalDataSize: results[0],
      cacheSize: results[1],
      videosSize: results[2],
      logsSize: results[3],
      codesSize: results[4],
      m3u8CopySize: results[5],
      resumeStateSize: results[6],
      apkSize: results[7],
      outputTotalSize: results[8],
      systemTotalSize: results[9],
      systemCacheSize: results[10],
      systemTempSize: results[11],
      outputDataSize: results[12],
      compressVideoSize: results[13],
      compressAudioSize: results[14],
      compressImageSize: results[15],
    );
  }

  /// 清理指定子目录
  static Future<int> clearSubDirectory(String subFolder) async {
    final dir = await getSubDirectory(subFolder);
    return _clearDirectory(dir.path);
  }

  /// 清理输出目录
  static Future<int> clearOutputDirectory() async {
    final root = await getRootPath();
    final outputDir = Directory('$root/$outputRoot');
    return _clearDirectory(outputDir.path);
  }

  /// 清理系统缓存
  static Future<int> clearCache() async {
    int cleaned = 0;
    cleaned += await clearSubDirectory(systemCache);
    try {
      final tempDir = await getTemporaryDirectory();
      cleaned += await _clearDirectory(tempDir.path);
    } catch (_) {}
    try {
      final cacheDir = await getApplicationCacheDirectory();
      cleaned += await _clearDirectory(cacheDir.path);
    } catch (_) {}
    return cleaned;
  }

  /// 清理所有垃圾数据
  static Future<int> clearJunkData() async {
    int cleaned = 0;
    cleaned += await clearSubDirectory(outputVideos);
    cleaned += await clearSubDirectory(outputLogs);
    cleaned += await clearSubDirectory(outputCodes);
    cleaned += await clearSubDirectory(systemTemp);
    cleaned += await clearSubDirectory(systemM3u8);
    cleaned += await clearCache();
    return cleaned;
  }

  // ============================================================
  // 智能清理机制（v1.51.2+）
  // ============================================================

  /// 单次清理的最大文件数量限制（防止卡顿）
  static const int _maxCleanPerRun = 200;

  /// 各目录的存储阈值（字节），超过阈值才触发清理
  static const int _tempThreshold = 50 * 1024 * 1024;     // 50 MB
  static const int _cacheThreshold = 100 * 1024 * 1024;   // 100 MB
  static const int _m3u8Threshold = 100 * 1024 * 1024;    // 100 MB
  static const int _compressThreshold = 200 * 1024 * 1024; // 200 MB
  static const int _totalThreshold = 500 * 1024 * 1024;   // 500 MB 总数据

  /// 文件保留天数（超过此天数的旧文件可被清理）
  static const int _maxFileAgeDays = 7;

  /// 触发压缩的目录大小阈值（字节）
  static const int _compressTriggerSize = 50 * 1024 * 1024; // 50 MB
  /// 低于此大小的文件不压缩（避免小文件压缩开销大于收益）
  static const int _minCompressSize = 1024 * 1024; // 1 MB
  /// 视频/音频等已压缩格式的文件扩展名（跳过压缩）
  static const _skipCompressExts = {
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.3gp',
    '.mp3', '.aac', '.ogg', '.wav', '.flac',
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic',
    '.zip', '.gz', '.7z', '.rar', '.apk', '.pdf',
  };

  static bool _isCleaning = false;

  /// 智能清理（v1.51.2+ 创建，v1.52.0+ 增加缓存压缩）
  /// 在后台静默执行，包括：删除过期文件 + 压缩近期大文件
  static Future<int> smartClean() async {
    if (_isCleaning) return 0;
    _isCleaning = true;
    int cleaned = 0;

    try {
      // 1. 清理系统临时目录（超过50MB时清理7天前的文件）
      final tempDir = await getSubDirectory(systemTemp);
      if (await _calcDirSize(tempDir.path) > _tempThreshold) {
        cleaned += await _cleanOldFiles(tempDir.path, _maxFileAgeDays);
      }

      // 2. 清理系统缓存（超过100MB时清理）
      final cacheDir = await getSubDirectory(systemCache);
      if (await _calcDirSize(cacheDir.path) > _cacheThreshold) {
        cleaned += await _cleanOldFiles(cacheDir.path, _maxFileAgeDays);
      }

      // 3. 清理 M3U8 数据（超过100MB时清理7天前的）
      final m3u8Dir = await getSubDirectory(systemM3u8);
      if (await _calcDirSize(m3u8Dir.path) > _m3u8Threshold) {
        cleaned += await _cleanOldFiles(m3u8Dir.path, _maxFileAgeDays);
      }

      // 4. 清理压缩器输出（超过200MB时清理7天前的）
      final compressDir = await getSubDirectory(compressRoot);
      if (await _calcDirSize(compressDir.path) > _compressThreshold) {
        cleaned += await _cleanOldFiles(compressDir.path, _maxFileAgeDays);
      }

      // 5. 如果总数据超过500MB，额外清理旧文件
      final totalSize = await getTotalDataSize();
      if (totalSize > _totalThreshold) {
        cleaned += await _cleanOldFiles(tempDir.path, 3); // 更激进：3天
        cleaned += await _cleanOldFiles(cacheDir.path, 3);
        cleaned += await _cleanOldFiles(m3u8Dir.path, 3);
      }

      // 6. 清理系统App临时缓存目录
      try {
        final sysTempDir = await getTemporaryDirectory();
        cleaned += await _cleanOldFiles(sysTempDir.path, _maxFileAgeDays);
      } catch (_) {}

      try {
        final appCacheDir = await getApplicationCacheDirectory();
        cleaned += await _cleanOldFiles(appCacheDir.path, _maxFileAgeDays);
      } catch (_) {}

      // 7. v1.52.0+ 缓存压缩：对超过50MB的目录压缩1天前的文件
      final dirsToCompress = [tempDir.path, cacheDir.path, m3u8Dir.path];
      int compressed = 0;
      for (final dirPath in dirsToCompress) {
        if (await _calcDirSize(dirPath) > _compressTriggerSize) {
          compressed += await _compressOldFiles(dirPath, 1); // 压缩1天前的文件
        }
      }
      if (compressed > 0) cleaned += compressed;
    } catch (e) {
      // 静默失败，不影响用户体验
    } finally {
      _isCleaning = false;
    }

    return cleaned;
  }

  /// 清理指定目录中超过 [maxAgeDays] 天的旧文件
  /// 返回清理的字节数
  static Future<int> _cleanOldFiles(String path, int maxAgeDays) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;

    int cleaned = 0;
    int fileCount = 0;
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (fileCount >= _maxCleanPerRun) break;

        try {
          final stat = await entity.stat();
          final modified = stat.modified;

          if (modified.isBefore(cutoff)) {
            if (entity is File) {
              cleaned += await entity.length();
              await entity.delete();
              fileCount++;
            } else if (entity is Directory) {
              final subSize = await _calcDirSize(entity.path);
              cleaned += subSize;
              await entity.delete(recursive: true);
              fileCount++;
            }
          }
        } catch (_) {
          // 跳过无法读取的文件
        }
      }
    } catch (_) {}

    return cleaned;
  }

  /// v1.52.0+ 对指定目录中超过 [minAgeDays] 天的大文件进行 zlib 压缩
  /// 跳过已压缩格式的文件（视频/音频/图片/归档文件）
  /// 返回节省的字节数
  static Future<int> _compressOldFiles(String path, int minAgeDays) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;

    int saved = 0;
    int fileCount = 0;
    final cutoff = DateTime.now().subtract(Duration(days: minAgeDays));

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (fileCount >= _maxCleanPerRun) break;
        if (entity is! File) continue;
        // 跳过已压缩的文件和已知格式
        final ext = entity.path.toLowerCase();
        if (_skipCompressExts.any((e) => ext.endsWith(e))) continue;
        // 跳过已压缩的 .gz 文件
        if (ext.endsWith('.gz')) continue;

        try {
          final stat = await entity.stat();
          if (!stat.modified.isBefore(cutoff)) continue;
          if (stat.size < _minCompressSize) continue;

          // 读取原始数据
          final rawBytes = await entity.readAsBytes();
          // zlib 压缩（使用 gzip 格式，带文件头更兼容）
          final compressed = gzip.encode(rawBytes);
          // 只有压缩有意义（节省30%以上）才替换
          if (compressed.length < rawBytes.length * 0.7) {
            final savedBytes = rawBytes.length - compressed.length;
            // 写入压缩文件（原地替换）
            final gzPath = '${entity.path}.gz';
            await File(gzPath).writeAsBytes(compressed);
            // 删除原始文件
            await entity.delete();
            saved += savedBytes;
            fileCount++;
          }
        } catch (_) {
          // 跳过无法处理的文件
        }
      }
    } catch (_) {}

    return saved;
  }

  /// 获取各目录的详细大小信息（供设置页存储管理卡片使用）
  static Future<Map<String, int>> getDetailedSizes() async {
    final results = await Future.wait([
      getDirectorySize(systemTemp),
      getDirectorySize(systemCache),
      getDirectorySize(systemM3u8),
      getDirectorySize(compressVideo),
      getDirectorySize(compressAudio),
      getDirectorySize(compressImage),
      getDirectorySize(outputVideos),
      getDirectorySize(outputLogs),
      getDirectorySize(outputCodes),
      getTotalDataSize(),
    ]);
    return {
      'systemTemp': results[0],
      'systemCache': results[1],
      'systemM3u8': results[2],
      'compressVideo': results[3],
      'compressAudio': results[4],
      'compressImage': results[5],
      'outputVideos': results[6],
      'outputLogs': results[7],
      'outputCodes': results[8],
      'totalData': results[9],
    };
  }

  /// 清理指定目录下的所有内容，保留目录本身
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
      } catch (_) {}
    }
    return cleaned;
  }

  /// 格式化字节数为可读字符串
  static String formatBytes(int bytes) {
    if (bytes < 0) return '--';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 存储空间详细信息（v1.51.0+ 增强：细分压缩器及M3U8数据）
class StorageDetailInfo {
  final int totalDataSize; // ToolApp 目录总大小
  final int cacheSize; // 缓存大小
  final int videosSize; // 视频输出文件大小
  final int logsSize; // 日志文件大小
  final int codesSize; // 扫码传信保存内容大小
  final int m3u8CopySize; // M3U8 临时文件大小
  final int resumeStateSize; // 断点续转状态文件大小
  final int apkSize; // App 本体（APK）大小
  final int outputTotalSize; // 输出目录总大小
  final int systemTotalSize; // 系统目录总大小
  final int systemCacheSize; // 系统缓存大小
  final int systemTempSize; // 系统临时目录大小
  final int outputDataSize; // output/data 目录大小
  final int compressVideoSize; // 压缩器-视频输出大小（v1.51.0+）
  final int compressAudioSize; // 压缩器-音频输出大小（v1.51.0+）
  final int compressImageSize; // 压缩器-图片输出大小（v1.51.0+）

  const StorageDetailInfo({
    required this.totalDataSize,
    required this.cacheSize,
    required this.videosSize,
    required this.logsSize,
    required this.codesSize,
    required this.m3u8CopySize,
    required this.resumeStateSize,
    required this.apkSize,
    required this.outputTotalSize,
    required this.systemTotalSize,
    required this.systemCacheSize,
    required this.systemTempSize,
    required this.outputDataSize,
    this.compressVideoSize = 0,
    this.compressAudioSize = 0,
    this.compressImageSize = 0,
  });

  /// 整体占用 = APK + 数据 + 缓存
  int get overallSize => apkSize + totalDataSize + cacheSize;
}