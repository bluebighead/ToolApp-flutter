// 视频转换历史记录模块
// 持久化保存每一次成功/失败的转换记录到 SharedPreferences（JSON 列表）
//
// 设计：
//   - 单 key 存整个 JSON 列表，简单可靠（历史不会很大，单 App 几百条内）
//   - 容量上限 [maxEntries]：超出后自动删最旧的，避免无限增长
//   - 列表按 timestamp 倒序（最新的在前）
//   - 输入源是文件路径或 URL；URL 历史用 [isNetwork] 区分显示
//   - 失败记录也保存，方便用户复盘
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'user_data_manager.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import 'ffmpeg_service.dart' show VideoFormat, VideoQuality;

/// 转换状态
enum ConvertStatus {
  /// 成功
  success,

  /// 失败
  failed,

  /// 用户取消
  cancelled,
}

/// 单条转换历史记录
class ConvertHistoryEntry {
  /// 唯一 ID（用时间戳即可，无需 GUID）
  final int id;

  /// 转换发起时间（毫秒）
  final int timestampMs;

  /// 输入源：本地文件绝对路径 或 http(s):// URL
  final String input;

  /// 是否是网络输入（影响列表显示）
  final bool isNetwork;

  /// 输出文件绝对路径（成功时）
  final String? outputPath;

  /// 输出文件大小（字节，成功时）
  final int? outputSize;

  /// 源时长（毫秒，可能为 null）
  final int? sourceDurationMs;

  /// 转换耗时（毫秒，endTime - startTime）
  final int? durationMs;

  /// 输出格式
  final VideoFormat format;

  /// 质量档位
  final VideoQuality quality;

  /// 转换结果
  final ConvertStatus status;

  /// 错误信息（失败时）
  final String? errorMessage;

  const ConvertHistoryEntry({
    required this.id,
    required this.timestampMs,
    required this.input,
    required this.isNetwork,
    this.outputPath,
    this.outputSize,
    this.sourceDurationMs,
    this.durationMs,
    required this.format,
    required this.quality,
    required this.status,
    this.errorMessage,
  });

  /// 输入源短显示名（路径取 basename，URL 取 host + path）
  String get inputDisplayName {
    if (isNetwork) {
      try {
        final u = Uri.parse(input);
        final path = u.pathSegments.isNotEmpty ? '/${u.pathSegments.last}' : '';
        return '${u.host}$path';
      } catch (_) {
        return input;
      }
    }
    // 本地文件：取 basename
    final i = input.lastIndexOf(RegExp(r'[/\\]'));
    return i >= 0 ? input.substring(i + 1) : input;
  }

  /// 输出文件短显示名
  String? get outputDisplayName {
    final p = outputPath;
    if (p == null) return null;
    final i = p.lastIndexOf(RegExp(r'[/\\]'));
    return i >= 0 ? p.substring(i + 1) : p;
  }

  /// 输出文件所在目录的路径
  String? get outputDirPath {
    final p = outputPath;
    if (p == null) return null;
    final i = p.lastIndexOf(RegExp(r'[/\\]'));
    return i >= 0 ? p.substring(0, i) : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': timestampMs,
        'input': input,
        'isNet': isNetwork,
        'out': outputPath,
        'outSize': outputSize,
        'srcDur': sourceDurationMs,
        'dur': durationMs,
        'fmt': format.name,
        'qual': quality.name,
        'status': status.name,
        'err': errorMessage,
      };

  factory ConvertHistoryEntry.fromJson(Map<String, dynamic> j) {
    // 兼容老数据 / 字段缺失
    return ConvertHistoryEntry(
      id: (j['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      timestampMs:
          (j['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      input: j['input'] as String? ?? '',
      isNetwork: j['isNet'] as bool? ?? false,
      outputPath: j['out'] as String?,
      outputSize: (j['outSize'] as num?)?.toInt(),
      sourceDurationMs: (j['srcDur'] as num?)?.toInt(),
      durationMs: (j['dur'] as num?)?.toInt(),
      format: _parseFormat(j['fmt'] as String?),
      quality: _parseQuality(j['qual'] as String?),
      status: _parseStatus(j['status'] as String?),
      errorMessage: j['err'] as String?,
    );
  }

  static VideoFormat _parseFormat(String? s) {
    for (final v in VideoFormat.values) {
      if (v.name == s) return v;
    }
    return VideoFormat.mp4;
  }

  static VideoQuality _parseQuality(String? s) {
    for (final v in VideoQuality.values) {
      if (v.name == s) return v;
    }
    return VideoQuality.standard;
  }

  static ConvertStatus _parseStatus(String? s) {
    for (final v in ConvertStatus.values) {
      if (v.name == s) return v;
    }
    return ConvertStatus.failed;
  }
}

/// 历史记录存储 / 读取服务
class ConvertHistory {
  static const String _logTag = 'ConvertHistory';
  static const String _basePrefsKey = 'convert_history_v1';
  static const int maxEntries = 100; // 容量上限

  /// 获取当前用户的 SharedPreferences key
  static String get _prefsKey => UserDataManager.instance.prefsKey(_basePrefsKey);

  /// 内存缓存：避免每次都从 SharedPreferences 读
  static List<ConvertHistoryEntry>? _cache;

  /// 清除内存缓存（用户切换时调用）
  static void clearCache() => _cache = null;

  /// 加载所有历史（按时间倒序）
  static Future<List<ConvertHistoryEntry>> loadAll() async {
    if (_cache != null) return List.of(_cache!);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _cache = [];
        return [];
      }
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => ConvertHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // 兜底：再次按时间倒序
      list.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
      _cache = list;
      AppLogger.i(_logTag, '加载历史 ${list.length} 条');
      return List.of(list);
    } catch (e, st) {
      AppLogger.e(_logTag, '加载历史失败', e, st);
      _cache = [];
      return [];
    }
  }

  /// 添加一条历史（超出容量自动删旧）
  static Future<void> add(ConvertHistoryEntry entry) async {
    final list = await loadAll();
    list.insert(0, entry); // 最新的在前
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    _cache = list;
    await _persist(list);
    AppLogger.i(
      _logTag,
      '添加历史：id=${entry.id} status=${entry.status.name} input=${entry.inputDisplayName}',
    );
    // 后台同步到服务器
    _triggerSync();
  }

  /// 清空所有历史
  static Future<void> clear() async {
    _cache = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    AppLogger.i(_logTag, '清空所有历史');
  }

  /// 删除单条
  static Future<void> remove(int id) async {
    final list = await loadAll();
    list.removeWhere((e) => e.id == id);
    _cache = list;
    await _persist(list);
  }

  /// 持久化到 SharedPreferences
  static Future<void> _persist(List<ConvertHistoryEntry> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(list.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsKey, raw);
    } catch (e, st) {
      AppLogger.e(_logTag, '持久化历史失败', e, st);
    }
  }
}

/// 时间格式工具（历史页用）
class TimeFormat {
  /// 简短格式：今天 HH:mm / 昨天 HH:mm / 本年 MM-dd / 其它 yyyy-MM-dd
  static String shortDateTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    final hm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (dt.year == now.year) {
      return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hm';
    }
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hm';
  }

  /// 把"秒数"格式化为"1 分 23 秒" / "1 小时 23 分" / "12 秒"
  static String fromSeconds(int totalSec) {
    if (totalSec < 0) return '-';
    if (totalSec < 60) return '$totalSec 秒';
    if (totalSec < 3600) {
      final m = totalSec ~/ 60;
      final s = totalSec % 60;
      return s > 0 ? '$m 分 $s 秒' : '$m 分';
    }
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    return m > 0 ? '$h 小时 $m 分' : '$h 小时';
  }
}

/// 字节大小格式化
class SizeFormat {
  static String format(int? bytes) {
    if (bytes == null || bytes <= 0) return '-';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 后台同步辅助：登录状态下触发全量数据同步（fire-and-forget）
void _triggerSync() {
  Future.microtask(() async {
    try {
      if (AuthService.instance.isLoggedIn && !SyncService.instance.isSyncing) {
        await SyncService.instance.syncAll();
      }
    } catch (_) {}
  });
}
