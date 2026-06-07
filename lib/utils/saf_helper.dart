import 'package:flutter/services.dart';

/// 与 Android 原生（MainActivity.kt）通信的 SAF 目录选择助手。
///
/// 为什么不直接用 `FilePicker.platform.getDirectoryPath`？
///   在小米 / Redmi 等深度定制 ROM 上，file_picker 8.1.x 的
///   `getDirectoryPath` 在 Android 11+ 上**只返回物理路径**（如
///   `/storage/emulated/0/Download/QuarkDownloads`），不返回 SAF `content://`
///   URI。后续无法走 `DocumentFile.fromTreeUri` 流程。
///
///   解决方案：在原生侧用 `ACTION_OPEN_DOCUMENT_TREE` 启动 SAF，强制
///   拿到 `content://com.android.externalstorage.documents/tree/...`。
class SafHelper {
  SafHelper._();

  static const MethodChannel _channel = MethodChannel('com.example.toolapp/saf_helper');

  /// 启动系统 SAF 让用户选目录。
  ///
  /// - 返回 `null`：用户取消。
  /// - 返回 `content://...` 形式的 URI：用户选中的目录，可直接传给
  ///   [copyTreeToCache] / [listM3u8InTree]。
  ///
  /// [initialUri] 可选：让 SAF 默认定位到该目录
  /// （如 `content://com.android.externalstorage.documents/tree/primary%3ADownload`）。
  static Future<String?> pickDirectory({String? initialUri}) async {
    final result = await _channel.invokeMethod<String?>('pickDirectory', {
      'initialUri': ?initialUri,
    });
    return result;
  }

  /// 递归复制 SAF 目录树（或直接路径）到 [destDir] 真实目录。
  /// 返回成功复制的文件数。
  static Future<int> copyTreeToCache({
    required String treeUriOrPath,
    required String destDir,
  }) async {
    final n = await _channel.invokeMethod<int>('copyTreeToCache', {
      'treeUri': treeUriOrPath,
      'destDir': destDir,
    });
    return n ?? 0;
  }

  /// 扫描目标目录下所有 .m3u8 文件的相对路径列表。
  static Future<List<String>> listM3u8InTree(String treeUriOrPath) async {
    final list = await _channel.invokeMethod<List<dynamic>>(
      'listM3u8InTree',
      {'treeUri': treeUriOrPath},
    );
    return list?.map((e) => e.toString()).toList() ?? <String>[];
  }
}

/// 常见 primary 存储卷根的 tree URI 工厂。
/// 给 `SafHelper.pickDirectory(initialUri: ...)` 用，
/// 让 SAF 默认展开到指定位置，用户少点几次。
class SafInitialUris {
  SafInitialUris._();

  static const String _authority = 'com.android.externalstorage.documents';

  /// primary 卷的 Download 根
  static const String primaryDownload =
      'content://$_authority/tree/primary%3ADownload';

  /// primary 卷的 Documents 根
  static const String primaryDocuments =
      'content://$_authority/tree/primary%3ADocuments';

  /// primary 卷根
  static const String primaryRoot =
      'content://$_authority/tree/primary%3A';

  /// 根据普通文件路径推测最可能"上一层"的 SAF 树位置。
  /// 例如 `/storage/emulated/0/Download/QuarkDownloads/xxx.m3u8`
  /// → 返回 `content://.../tree/primary%3ADownload`。
  /// 不一定 100% 准确，但能让 SAF 少展开几层，体验更好。
  static String? guessFromFsPath(String? fsPath) {
    if (fsPath == null || fsPath.isEmpty) return null;
    // 找最前面是 /storage/emulated/0/<name>/ 还是 /<name>/
    const segs = ['Download', 'Documents', 'Movies', 'Music', 'Pictures', 'DCIM'];
    for (final s in segs) {
      final marker = '/$s/';
      final idx = fsPath.indexOf(marker);
      if (idx >= 0) {
        return 'content://$_authority/tree/primary%3A$s';
      }
      // 也兼容 /sdcard/<s>/ 之类
      if (fsPath.startsWith('/$s/')) {
        return 'content://$_authority/tree/primary%3A$s';
      }
    }
    return null;
  }
}
