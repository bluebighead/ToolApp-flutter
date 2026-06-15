// LRC 歌词解析器
// 解析 LRC 格式歌词文件，支持时间标签和逐行解析
// 提供根据播放进度获取当前歌词行的功能
import 'dart:io';

/// 单行歌词
class LyricLine {
  /// 时间戳（毫秒）
  final int timestamp;
  /// 歌词文本
  final String text;

  LyricLine({required this.timestamp, required this.text});

  @override
  String toString() => '[$timestamp] $text';
}

/// LRC 歌词解析结果
class ParsedLyrics {
  /// 按时间排序的歌词行列表
  final List<LyricLine> lines;

  ParsedLyrics(this.lines);

  /// 是否为空歌词
  bool get isEmpty => lines.isEmpty;
  /// 是否有歌词
  bool get isNotEmpty => lines.isNotEmpty;

  /// 根据播放进度（毫秒）获取当前歌词行索引
  /// 返回当前应高亮显示的行索引，-1 表示无匹配
  int getCurrentIndex(int positionMs) {
    if (isEmpty) return -1;

    // 二分查找：找到最后一个 timestamp <= positionMs 的行
    int left = 0;
    int right = lines.length - 1;
    int result = -1;

    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (lines[mid].timestamp <= positionMs) {
        result = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return result;
  }

  /// 根据播放进度获取当前歌词文本
  String getCurrentText(int positionMs) {
    final index = getCurrentIndex(positionMs);
    if (index < 0) return '';
    return lines[index].text;
  }
}

/// LRC 歌词解析工具类
class LrcParser {
  /// 时间标签正则：[00:12.34] 或 [00:12.345] 或 [00:12]
  static final _timeRegex = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]');

  /// 解析 LRC 格式歌词文本
  /// 支持多时间标签行：[00:12.34][00:45.67]歌词文本
  static ParsedLyrics parse(String lrcText) {
    final List<LyricLine> lines = [];

    for (final rawLine in lrcText.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;

      // 提取所有时间标签
      final matches = _timeRegex.allMatches(trimmed);
      if (matches.isEmpty) continue;

      // 提取歌词文本（去掉所有时间标签后的内容）
      final text = trimmed.replaceAll(_timeRegex, '').trim();
      if (text.isEmpty) continue;

      // 为每个时间标签创建一行歌词
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final msStr = match.group(3) ?? '0';
        // 处理 2 位或 3 位毫秒
        final milliseconds = msStr.length == 2
            ? int.parse(msStr) * 10
            : int.parse(msStr);

        final timestamp = minutes * 60000 + seconds * 1000 + milliseconds;
        lines.add(LyricLine(timestamp: timestamp, text: text));
      }
    }

    // 按时间排序
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return ParsedLyrics(lines);
  }

  /// 从本地文件读取并解析歌词
  /// [audioPath] 音频文件路径，自动查找同名 .lrc 文件
  static Future<ParsedLyrics> fromLocalFile(String audioPath) async {
    try {
      final dotIndex = audioPath.lastIndexOf('.');
      if (dotIndex < 0) return ParsedLyrics([]);

      final lrcPath = '${audioPath.substring(0, dotIndex)}.lrc';
      final file = File(lrcPath);
      if (!await file.exists()) return ParsedLyrics([]);

      final content = await file.readAsString();
      return parse(content);
    } catch (_) {
      return ParsedLyrics([]);
    }
  }
}
