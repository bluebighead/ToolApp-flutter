// 本地 M3U8 规范化器
//
// 背景：
// FFmpeg 的 HLS demuxer 在协议层（hls.c）硬编码了 segment 扩展名白名单：
//   {"aac", "mp3", "ts", "vtt"}
// 不在白名单中的 segment 会被直接拒绝（返回 EINVAL），
// 同时打印类似下面的警告：
//   [hls @ 0x...] URL /path/to/seg is not in allowed_segment_extensions,
//   consider updating hls.c and submitting a patch to ffmpeg-devel
//
// 用户常见问题：
//   - 有些工具导出的 M3U8 引用纯数字命名的 segment（"0", "1", "2"），
//     没有扩展名
//   - 移动端下载器有时会用 .mp4 扩展名（fMP4），也不在白名单
//   - 加密的 segment 偶尔会用 .m4s、.enc 等非标扩展名
//
// 解决方案：
// 无条件把所有本地 segment 复制到临时目录、改名为 .ts，
// 并把 M3U8 改成引用绝对路径。这样 FFmpeg 100% 能识别。
//
// 注意：
//   - 只处理本地文件（绝对/相对路径）的 segment
//   - 远程 URL（http://）的 segment 保持原样，让 FFmpeg 自行下载
//   - 不修改 M3U8 内的 tag 行（以 # 开头的）

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

class M3U8NormalizeResult {
  /// 规范化后的 M3U8 文件路径（绝对路径）
  final String normalizedM3u8Path;

  /// 合并后的单一 .ts 文件路径（绝对路径）
  ///
  /// 把所有 segment 字节流拼接到一个文件里，让 FFmpeg 当作单一输入处理，
  /// 彻底避开 HLS demuxer 对每个 segment 单独 open/seek/parse 的开销。
  /// 提速最关键的一步。
  ///
  /// 如果生成失败（极端情况），可能为 null，会回退到使用 normalizedM3u8Path
  final String? mergedTsPath;

  /// 临时目录（用于存放复制的 segment，转换完成后需清理）
  final Directory tempDir;

  /// 复制的 segment 数量
  final int copiedSegmentCount;

  const M3U8NormalizeResult({
    required this.normalizedM3u8Path,
    this.mergedTsPath,
    required this.tempDir,
    required this.copiedSegmentCount,
  });
}

class M3U8Normalizer {
  static const _logTag = 'M3U8Normalizer';

  /// 规范化本地 M3U8 文件
  ///
  /// [m3u8Path] 原始 M3U8 文件绝对路径
  ///
  /// 策略：无条件处理。把 M3U8 中所有本地 segment 引用都替换为
  /// 临时目录中 .ts 副本的绝对路径。即使所有 segment 都合规，
  /// 也统一改写，避免边角问题。
  ///
  /// 返回规范化结果。调用方在转换完成后应清理 tempDir。
  /// 如果不是 M3U8 文件，返回 null。
  static Future<M3U8NormalizeResult?> normalize(String m3u8Path) async {
    // 是否 M3U8 文件？按扩展名和文件名判断
    final ext = p.extension(m3u8Path).toLowerCase();
    final baseName = p.basename(m3u8Path).toLowerCase();
    final isM3u8Like = ext == '.m3u8' ||
        ext == '.m3u' ||
        ext == '.m3u8.txt' ||
        baseName.endsWith('.m3u8') ||
        baseName.endsWith('.m3u');
    if (!isM3u8Like) {
      AppLogger.d(_logTag, '非 M3U8 文件（ext=$ext），跳过规范化');
      return null;
    }

    final srcFile = File(m3u8Path);
    if (!await srcFile.exists()) {
      AppLogger.w(_logTag, 'M3U8 文件不存在：$m3u8Path');
      return null;
    }

    // 读取 M3U8 内容
    // 注意：必须先去掉 UTF-8 BOM（\uFEFF），否则首行无法匹配 #EXTM3U
    final rawBytes = await srcFile.readAsBytes();
    String rawContent;
    if (rawBytes.length >= 3 &&
        rawBytes[0] == 0xEF &&
        rawBytes[1] == 0xBB &&
        rawBytes[2] == 0xBF) {
      rawContent = utf8.decode(rawBytes.sublist(3));
      AppLogger.d(_logTag, '检测到 UTF-8 BOM，已剥离');
    } else {
      rawContent = utf8.decode(rawBytes);
    }
    final rawLines = const LineSplitter().convert(rawContent);
    final m3u8Dir = srcFile.parent.path;

    AppLogger.i(
      _logTag,
      '开始规范化 M3U8：$m3u8Path，${rawLines.length} 行',
    );

    // 调试：打印完整 M3U8 内容（提升到 info 级别，方便 logcat 看到）
    AppLogger.i(_logTag, '原始 M3U8 完整内容：\n  ${rawLines.join('\n  ')}');

    // 创建临时目录
    // v1.6.51+ 修复：使用 getApplicationCacheDirectory() 代替 Directory.systemTemp
    // 原因：Android 11+ 限制 FFmpeg 原生库访问 code_cache 目录，
    //   导致 "No such file or directory" 错误。
    //   getApplicationCacheDirectory() 返回的 cache 目录 FFmpeg 可以正常访问。
    final cacheDir = await getApplicationCacheDirectory();
    final tempDir = await cacheDir.createTemp(
      'm3u8_norm_${DateTime.now().millisecondsSinceEpoch}_',
    );
    final newM3u8Lines = <String>[];
    int copiedCount = 0;
    int urlCount = 0;
    int tagCount = 0;
    int emptyCount = 0;
    int missingCount = 0;
    int segIndex = 0;

    for (final raw in rawLines) {
      final line = raw.trim();

      // 空行：原样保留
      if (line.isEmpty) {
        emptyCount++;
        newM3u8Lines.add(line);
        continue;
      }

      // M3U8 tag / 注释：原样保留
      if (line.startsWith('#')) {
        tagCount++;
        newM3u8Lines.add(line);
        continue;
      }

      // 远程 URL：原样保留，让 FFmpeg 自己下载
      if (line.startsWith('http://') ||
          line.startsWith('https://') ||
          line.startsWith('ftp://') ||
          line.startsWith('file://')) {
        urlCount++;
        newM3u8Lines.add(line);
        continue;
      }

      // 解析为绝对路径
      String absPath;
      try {
        absPath = p.isAbsolute(line) ? line : p.join(m3u8Dir, line);
      } catch (e) {
        AppLogger.w(_logTag, '解析路径失败：$line ($e)');
        newM3u8Lines.add(line);
        continue;
      }

      final segFile = File(absPath);
      final exists = await segFile.exists();
      AppLogger.d(
        _logTag,
        'segment 行：line="$line" -> absPath="$absPath", exists=$exists',
      );
      if (!exists) {
        missingCount++;
        // 关键修复：segment 文件不存在时跳过，不写入规范化 M3U8
        // 旧版会保留原始行，导致 FFmpeg 尝试打开不存在的路径而报错
        AppLogger.w(
          _logTag,
          'segment 文件不存在，跳过：$absPath（规范化 M3U8 中将不包含此 segment）',
        );
        continue;
      }

      // 复制到临时目录，统一改为 .ts 后缀
      // 注意：对于嵌套引用的 .m3u8（variant playlist）也照搬，
      // 把它们当文件复制，FFmpeg 会自己去解析
      final newName = 'seg_${segIndex.toString().padLeft(6, '0')}.ts';
      final newPath = p.join(tempDir.path, newName);
      try {
        await segFile.copy(newPath);
        // 关键：把新路径写入 M3U8（不是原 line）
        newM3u8Lines.add(newPath);
        copiedCount++;
        segIndex++;
        AppLogger.i(
          _logTag,
          'segment[$segIndex]: "$line" -> "$absPath" -> "$newPath" ✓',
        );
      } catch (e) {
        // 关键修复：复制失败时跳过，不写入规范化 M3U8
        // 旧版会保留原始行，导致 FFmpeg 尝试打开不存在的路径而报错
        AppLogger.e(_logTag, '复制 segment 失败，跳过：$absPath -> $newPath', e);
      }
    }

    // 调试：列出 m3u8 所在目录里的所有文件（看 file_picker 把哪些文件放进了 cache）
    try {
      final srcDir = File(m3u8Path).parent;
      if (await srcDir.exists()) {
        final srcEntries = srcDir.listSync(recursive: true);
        final srcListing = srcEntries
            .map((e) => '${e.statSync().type == FileSystemEntityType.directory ? "[D]" : "[F]"} ${p.relative(e.path, from: srcDir.path)}')
            .join(', ');
        AppLogger.d(_logTag, '源目录 (${srcDir.path}) 内容：$srcListing');
      }
    } catch (e) {
      AppLogger.w(_logTag, '列源目录失败：$e');
    }

    // 写规范化后的 M3U8
    final newM3u8Path = p.join(tempDir.path, 'normalized.m3u8');
    await File(newM3u8Path).writeAsString(newM3u8Lines.join('\n'));

    // ----------------------------------------------------------------
    // v1.6.51+ 修复：禁用 merged.ts 字节拼接合并
    //
    // 原因：
    //   实际测试发现大量 M3U8 的 segment 不是标准 MPEG-TS 格式：
    //   - 有些 segment 开头是 0x83（加密或自定义格式）
    //   - 有些是 fMP4 格式（自带 ftyp box）
    //   字节拼接这些 segment 会产生无效的 merged.ts 文件，
    //   FFmpeg 报 "Invalid data found when processing input"。
    //
    // 方案：
    //   统一使用 normalized.m3u8 走 FFmpeg HLS demuxer，
    //   让 FFmpeg 自己处理各种 segment 格式。
    //   虽然比单文件输入慢一些，但兼容性 100%。
    // ----------------------------------------------------------------
    String? mergedTsPath;
    mergedTsPath = null; // 始终禁用合并，走 HLS demuxer

    // 调试：列出 temp 目录里的所有文件（提升到 info 级别）
    try {
      final entries = tempDir.listSync(recursive: true);
      final listing = entries
          .map((e) => '${e.statSync().type == FileSystemEntityType.directory ? "[D]" : "[F]"} ${p.relative(e.path, from: tempDir.path)}')
          .join(', ');
      AppLogger.i(_logTag, 'temp 目录内容：$listing');
    } catch (e) {
      AppLogger.w(_logTag, '列出 temp 目录失败：$e');
    }

    // 调试：打印规范化 M3U8 的完整内容（提升到 info 级别）
    final normalizedContent = await File(newM3u8Path).readAsString();
    AppLogger.i(_logTag, '规范化 M3U8 完整内容：\n  ${normalizedContent.replaceAll('\n', '\n  ')}');

    AppLogger.i(
      _logTag,
      'M3U8 规范化完成：copied=$copiedCount, url=$urlCount, '
      'tag=$tagCount, missing=$missingCount, empty=$emptyCount',
    );

    return M3U8NormalizeResult(
      normalizedM3u8Path: newM3u8Path,
      mergedTsPath: mergedTsPath,
      tempDir: tempDir,
      copiedSegmentCount: copiedCount,
    );
  }

  /// 清理临时目录
  static Future<void> cleanup(M3U8NormalizeResult? result) async {
    if (result == null) return;
    try {
      if (await result.tempDir.exists()) {
        await result.tempDir.delete(recursive: true);
        AppLogger.d(_logTag, '已清理临时目录：${result.tempDir.path}');
      }
    } catch (e) {
      AppLogger.w(_logTag, '清理临时目录失败：$e');
    }
  }
}
