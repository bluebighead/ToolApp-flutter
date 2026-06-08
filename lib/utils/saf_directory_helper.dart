// SAF 目录选择 + 递归复制工具
//
// 背景：
//   file_picker 8.1.x 在小米/Redmi 等深度定制 ROM 上 getDirectoryPath 只返回物理路径，
//   Android 11+ Scoped Storage 下无法直接读取。所以我们走项目自带的
//   `com.example.toolapp/saf_helper` MethodChannel（见 MainActivity.kt）：
//     - pickDirectory({ initialUri? }) -> content://... tree URI
//     - copyTreeToCache(treeUri, destDir) -> 复制文件数（v1.6.10 全量复制）
//     - listM3u8InTree(treeUri) -> [.m3u8, ...] 相对路径列表（v1.6.10 递归）
//     - listM3u8InDir(treeUri) -> [.m3u8, ...] 直接子项的 .m3u8（v1.6.11+ 浅扫）
//     - copyM3u8WithSegments(treeUri, destDir, m3u8Rel) -> 单 M3U8 精准复制
//       （v1.6.11+ 新增：启发式 + 解析兜底，只复制选中的那一份）
//
// 用法（典型流程）：
//   v1.6.10 老流程（全量复制）：
//     1. await SafDirectoryHelper.pickDirectory() 得到 treeUri
//     2. await AppStorage.createTempDir('m3u8_import_xxx')
//     3. await SafDirectoryHelper.copyTreeToCache(treeUri, destDir.path)
//     4. await SafDirectoryHelper.listM3u8InTree(treeUri) 找 .m3u8
//
//   v1.6.11+ 新流程（先扫后选 + 精准复制）：
//     1. await SafDirectoryHelper.pickDirectory() 得到 treeUri
//     2. await SafDirectoryHelper.listM3u8InDir(treeUri) 浅扫 .m3u8
//     3. 用户选 m3u8Rel
//     4. await SafDirectoryHelper.copyM3u8WithSegments(treeUri, destDir, m3u8Rel)

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 复制进度数据
class CopyProgress {
  final int fileCount;
  final int byteCount;

  const CopyProgress({required this.fileCount, required this.byteCount});

  @override
  String toString() => 'CopyProgress(files: $fileCount, bytes: $byteCount)';
}

/// 前台服务控制工具
///
/// 用于在 FFmpeg 转换期间启动 Android 前台服务，保持 App 进程不被系统限制。
/// 息屏、切后台、离开页面时 FFmpeg 仍能正常执行。
class ForegroundServiceHelper {
  ForegroundServiceHelper._();

  static const _logTag = 'ForegroundServiceHelper';
  static const _channel = MethodChannel('com.example.toolapp/foreground_service');

  // v1.6.56+ 修复：通知栏"停止"按钮取消回调
  // 当用户在通知栏点击"停止"时，Kotlin 端通过 MethodChannel 回调到此处，
  // 再通知 ConvertCoordinator / BatchConvertCoordinator 取消 FFmpeg
  static void Function()? _onCancelRequested;

  /// 注册通知栏"停止"按钮的取消回调
  /// 在 App 启动时调用一次，将 Kotlin 端的取消事件桥接到 Dart 端
  static void registerCancelCallback(void Function() onCancel) {
    _onCancelRequested = onCancel;
    // 通过 MethodChannel 告诉 Kotlin 端注册回调
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCancelRequested') {
        AppLogger.i(_logTag, '收到通知栏取消请求');
        _onCancelRequested?.call();
      }
    });
  }

  /// 启动前台服务
  /// [title] 通知标题
  /// [content] 通知内容（如输入源名称）
  static Future<void> start({
    required String title,
    required String content,
  }) async {
    try {
      AppLogger.i(_logTag, '请求启动前台服务: $title - $content');
      await _channel.invokeMethod('startForegroundService', {
        'title': title,
        'content': content,
      });
      AppLogger.i(_logTag, '前台服务启动成功');
    } catch (e) {
      AppLogger.w(_logTag, '启动前台服务失败：$e');
    }
  }

  /// 更新前台服务进度
  /// [title] 通知标题
  /// [content] 通知内容
  /// [progress] 进度百分比（0~100）
  /// [subtext] 子文本（如剩余时间）
  static Future<void> update({
    required String title,
    required String content,
    required int progress,
    String? subtext,
  }) async {
    try {
      await _channel.invokeMethod('updateForegroundService', {
        'title': title,
        'content': content,
        'progress': progress,
        'subtext': subtext ?? '',
      });
    } catch (e) {
      AppLogger.w(_logTag, '更新前台服务失败：$e');
    }
  }

  /// 停止前台服务
  static Future<void> stop() async {
    try {
      AppLogger.i(_logTag, '请求停止前台服务');
      await _channel.invokeMethod('stopForegroundService');
      AppLogger.i(_logTag, '前台服务已停止');
    } catch (e) {
      AppLogger.w(_logTag, '停止前台服务失败：$e');
    }
  }
}

/// SAF 目录操作工具类
class SafDirectoryHelper {
  SafDirectoryHelper._();

  static const _logTag = 'SafDirHelper';
  static const _channel = MethodChannel('com.example.toolapp/saf_helper');

  /// 复制进度 EventChannel（Kotlin 端主动推送实时进度）
  static const _progressChannel = EventChannel('com.example.toolapp/copy_progress');

  /// 复制进度流（广播流，多个监听者可同时接收）
  static final Stream<CopyProgress> copyProgressStream = _progressChannel
      .receiveBroadcastStream()
      .map((event) {
        final map = event as Map<dynamic, dynamic>;
        return CopyProgress(
          fileCount: (map['fileCount'] as num).toInt(),
          byteCount: (map['byteCount'] as num).toInt(),
        );
      })
      .handleError((error) {
        AppLogger.w(_logTag, '复制进度流异常：$error');
      })
      .asBroadcastStream();

  /// 弹出系统 SAF 目录选择器，让用户选择 M3U8 所在目录。
  /// 返回 `content://com.android.externalstorage.documents/tree/...` 形式的 URI；
  /// 用户取消则返回 null。
  /// [initialUri] 可选，让 SAF 默认定位到该目录。
  static Future<String?> pickDirectory({String? initialUri}) async {
    AppLogger.i(_logTag, '调起 SAF 目录选择器 (initialUri=$initialUri)');
    final uri = await _channel.invokeMethod<String?>('pickDirectory', {
      if (initialUri != null) 'initialUri': initialUri,
    });
    AppLogger.i(_logTag, '用户选择目录：$uri');
    return uri;
  }

  /// 递归把 tree 目录里的所有文件复制到 [destDir] 真实目录下。
  /// 返回成功复制的文件数。
  static Future<int> copyTreeToCache({
    required String treeUri,
    required String destDir,
  }) async {
    AppLogger.i(_logTag, '开始复制目录：$treeUri -> $destDir');
    final count = await _channel.invokeMethod<int>('copyTreeToCache', {
      'treeUri': treeUri,
      'destDir': destDir,
    });
    AppLogger.i(_logTag, '目录复制完成：成功 $count 个文件');
    return count ?? 0;
  }

  /// 列出 tree 目录里所有 .m3u8 文件的相对路径。
  /// 返回如 ["测试视频.m3u8", "sub/播放列表.m3u8"]。
  static Future<List<String>> listM3u8InTree(String treeUri) async {
    final list = await _channel.invokeMethod<List<dynamic>>(
      'listM3u8InTree',
      {'treeUri': treeUri},
    );
    return (list ?? const []).map((e) => e.toString()).toList();
  }

  /// 浅扫：只列 tree 目录**直接子项**里的 .m3u8 文件（不递归）。
  ///
  /// 用于 v1.6.11+ "先扫后选"流程：避免一开始就把整个根目录都拷过来。
  /// 返回如 ["测试视频.m3u8", "另一个.m3u8"]（都是 basename，不带子目录）。
  static Future<List<String>> listM3u8InDir(String treeUri) async {
    final list = await _channel.invokeMethod<List<dynamic>>(
      'listM3u8InDir',
      {'treeUri': treeUri},
    );
    return (list ?? const []).map((e) => e.toString()).toList();
  }

  /// 精准复制单个 M3U8 + 它的 segments。
  ///
  /// Kotlin 端策略（见 MainActivity.kt）：
  ///   1) 复制 M3U8 文件本身
  ///   2) 启发式：尝试复制"同名 segments 文件夹"（如 "测试视频.m3u8" -> "测试视频/"）
  ///   3) 启发式失败则解析 M3U8，按引用逐个复制 segments
  ///
  /// [treeUri] SAF tree URI
  /// [destDir] 目标目录（需要先建好，Kotlin 端不会 mkdirs）
  /// [m3u8Rel] M3U8 相对路径（如 "测试视频.m3u8"）
  ///
  /// 返回成功复制的文件数。
  static Future<int> copyM3u8WithSegments({
    required String treeUri,
    required String destDir,
    required String m3u8Rel,
  }) async {
    AppLogger.i(_logTag, '精准复制：$treeUri/$m3u8Rel -> $destDir');
    final count = await _channel.invokeMethod<int>('copyM3u8WithSegments', {
      'treeUri': treeUri,
      'destDir': destDir,
      'm3u8Rel': m3u8Rel,
    });
    AppLogger.i(_logTag, '精准复制完成：成功 $count 个文件');
    return count ?? 0;
  }
}

/// 常见的 SAF 初始定位目录
///
/// 传入 `SafDirectoryHelper.pickDirectory(initialUri: SafInitialUris.primaryDownload)`
/// 后，SAF 选择器会优先定位到该目录
enum SafInitialUris {
  /// 主存储的下载目录（最常用）
  /// 对应 content://com.android.externalstorage.documents/tree/primary%3ADownload
  primaryDownload('primary:Download'),

  /// 主存储的相册（Movies）目录
  primaryMovies('primary:Movies'),

  /// 主存储的 DCIM 目录（相机照片/视频）
  primaryDcim('primary:DCIM'),

  /// 主存储的 Documents 目录
  primaryDocuments('primary:Documents'),

  /// 主存储的根目录
  primaryRoot('primary:');

  const SafInitialUris(this.treeId);

  /// Document Tree 内部 ID 形式（"primary:Download" 之类）
  final String treeId;

  /// 拼装成 content:// URI，给 pickDirectory(initialUri: ...) 用
  String get contentUri {
    // 用 base64-encode 掉 : 和 /，符合 SAF Document ID 编码规则
    return 'content://com.android.externalstorage.documents/tree/'
        '${Uri.encodeComponent(treeId)}';
  }
}
