// 心率历史记录模块
// 持久化保存每一次心率测量会话的统计数据到 SharedPreferences（JSON 列表）
//
// 设计：
//   - 单 key 存整个 JSON 列表，简单可靠（历史不会很大，几百条内）
//   - 容量上限 [maxEntries]：超出后自动删最旧的，避免无限增长
//   - 列表按 timestamp 倒序（最新的在前）
//   - 每次会话（从"开始接收"到"停止接收"）生成一条记录
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'user_data_manager.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

/// 连接方式（与 heart_rate_page.dart 中的 ConnectionMode 对应）
enum HeartRateConnectionMode {
  ble,  // BLE蓝牙低功耗
  udp,  // WiFi UDP
}

/// 单条心率历史记录
class HeartRateRecord {
  /// 唯一 ID（用时间戳）
  final int id;

  /// 会话开始时间（毫秒）
  final int startTimeMs;

  /// 会话结束时间（毫秒）
  final int endTimeMs;

  /// 最高心率（BPM）
  final int maxBpm;

  /// 最低心率（BPM）
  final int minBpm;

  /// 平均心率（BPM，四舍五入）
  final int avgBpm;

  /// 采样点数量
  final int samples;

  /// 连接方式
  final HeartRateConnectionMode connectionMode;

  const HeartRateRecord({
    required this.id,
    required this.startTimeMs,
    required this.endTimeMs,
    required this.maxBpm,
    required this.minBpm,
    required this.avgBpm,
    required this.samples,
    required this.connectionMode,
  });

  /// 测量时长（毫秒）
  int get durationMs => endTimeMs - startTimeMs;

  /// 测量时长格式化字符串
  String get durationText {
    final sec = durationMs ~/ 1000;
    if (sec < 60) return '$sec 秒';
    if (sec < 3600) {
      final m = sec ~/ 60;
      final s = sec % 60;
      return s > 0 ? '$m 分 $s 秒' : '$m 分';
    }
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '$h 小时 $m 分' : '$h 小时';
  }

  /// 连接方式显示文本
  String get connectionModeText {
    switch (connectionMode) {
      case HeartRateConnectionMode.ble:
        return 'BLE蓝牙';
      case HeartRateConnectionMode.udp:
        return 'WiFi UDP';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': startTimeMs,
        'end': endTimeMs,
        'max': maxBpm,
        'min': minBpm,
        'avg': avgBpm,
        'samples': samples,
        'mode': connectionMode.name,
      };

  factory HeartRateRecord.fromJson(Map<String, dynamic> j) {
    return HeartRateRecord(
      id: (j['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      startTimeMs: (j['start'] as num?)?.toInt() ?? 0,
      endTimeMs: (j['end'] as num?)?.toInt() ?? 0,
      maxBpm: (j['max'] as num?)?.toInt() ?? 0,
      minBpm: (j['min'] as num?)?.toInt() ?? 0,
      avgBpm: (j['avg'] as num?)?.toInt() ?? 0,
      samples: (j['samples'] as num?)?.toInt() ?? 0,
      connectionMode: _parseMode(j['mode'] as String?),
    );
  }

  static HeartRateConnectionMode _parseMode(String? s) {
    for (final v in HeartRateConnectionMode.values) {
      if (v.name == s) return v;
    }
    return HeartRateConnectionMode.ble;
  }
}

/// 心率历史记录存储 / 读取服务
class HeartRateHistory {
  static const String _logTag = 'HeartRateHistory';
  static const String _basePrefsKey = 'heart_rate_history_v1';
  static const int maxEntries = 100; // 容量上限

  /// 获取当前用户的 SharedPreferences key
  static String get _prefsKey => UserDataManager.instance.prefsKey(_basePrefsKey);

  /// 内存缓存
  static List<HeartRateRecord>? _cache;

  /// 清除内存缓存（用户切换时调用）
  static void clearCache() => _cache = null;

  /// 加载所有历史（按时间倒序）
  static Future<List<HeartRateRecord>> loadAll() async {
    if (_cache != null) return List.of(_cache!);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _cache = [];
        return [];
      }
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => HeartRateRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      // 按时间倒序
      list.sort((a, b) => b.startTimeMs.compareTo(a.startTimeMs));
      _cache = list;
      AppLogger.i(_logTag, '加载心率历史 ${list.length} 条');
      return List.of(list);
    } catch (e, st) {
      AppLogger.e(_logTag, '加载心率历史失败', e, st);
      _cache = [];
      return [];
    }
  }

  /// 添加一条历史（超出容量自动删旧）
  static Future<void> add(HeartRateRecord record) async {
    final list = await loadAll();
    list.insert(0, record); // 最新的在前
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    _cache = list;
    await _persist(list);
    AppLogger.i(
      _logTag,
      '添加心率历史：avg=${record.avgBpm} samples=${record.samples} duration=${record.durationText}',
    );
    // 后台同步到服务器（不阻塞本地操作）
    _triggerSync();
  }

  /// 清空所有历史
  static Future<void> clear() async {
    _cache = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    AppLogger.i(_logTag, '清空所有心率历史');
  }

  /// 删除单条
  static Future<void> remove(int id) async {
    final list = await loadAll();
    list.removeWhere((e) => e.id == id);
    _cache = list;
    await _persist(list);
  }

  /// 批量删除
  static Future<void> removeBatch(List<int> ids) async {
    final idSet = ids.toSet();
    final list = await loadAll();
    list.removeWhere((e) => idSet.contains(e.id));
    _cache = list;
    await _persist(list);
    AppLogger.i(_logTag, '批量删除心率历史 ${ids.length} 条');
  }

  /// 合并服务器下载的数据（去重：以 id 为准，本地已有的不覆盖）
  static Future<int> mergeFromServer(List<HeartRateRecord> serverRecords) async {
    final localList = await loadAll();
    final localIds = localList.map((e) => e.id).toSet();
    final newRecords = serverRecords.where((r) => !localIds.contains(r.id)).toList();
    if (newRecords.isEmpty) return 0;
    localList.addAll(newRecords);
    localList.sort((a, b) => b.startTimeMs.compareTo(a.startTimeMs));
    if (localList.length > maxEntries) {
      localList.removeRange(maxEntries, localList.length);
    }
    _cache = localList;
    await _persist(localList);
    AppLogger.i(_logTag, '从服务器合并心率历史 ${newRecords.length} 条');
    return newRecords.length;
  }

  /// 持久化到 SharedPreferences
  static Future<void> _persist(List<HeartRateRecord> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(list.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsKey, raw);
    } catch (e, st) {
      AppLogger.e(_logTag, '持久化心率历史失败', e, st);
    }
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
