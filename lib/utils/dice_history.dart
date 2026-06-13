// 掷骰子历史记录模块
// 持久化保存每一次掷骰子结果到 SharedPreferences（JSON 列表）
//
// 设计：
//   - 单 key 存整个 JSON 列表
//   - 容量上限 50 条：超出后自动删最旧的
//   - 列表按 timestamp 倒序（最新的在前）
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'user_data_manager.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

/// 支持的骰子类型
enum DiceType {
  d4('D4', 4),
  d6('D6', 6),
  d8('D8', 8),
  d10('D10', 10),
  d12('D12', 12),
  d20('D20', 20);

  final String label;    // 显示名称
  final int sides;       // 面数

  const DiceType(this.label, this.sides);

  /// 根据名称字符串解析 DiceType
  static DiceType fromName(String name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return d6; // 默认 D6
  }
}

/// 单条掷骰子历史记录
class DiceRecord {
  /// 唯一 ID（用时间戳）
  final int id;

  /// 骰子类型
  final DiceType diceType;

  /// 掷出结果（1 ~ sides）
  final int result;

  /// 掷骰子时间（毫秒）
  final int timestamp;

  const DiceRecord({
    required this.id,
    required this.diceType,
    required this.result,
    required this.timestamp,
  });

  /// 格式化时间字符串
  String get timeText {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// 相对时间显示
  String get relativeTimeText {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': diceType.name,
        'result': result,
        'time': timestamp,
      };

  factory DiceRecord.fromJson(Map<String, dynamic> j) {
    return DiceRecord(
      id: (j['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      diceType: DiceType.fromName(j['type'] as String? ?? 'd6'),
      result: (j['result'] as num?)?.toInt() ?? 1,
      timestamp: (j['time'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 掷骰子历史记录存储 / 读取服务
class DiceHistory {
  static const String _logTag = 'DiceHistory';
  static const String _basePrefsKey = 'dice_history_v1';
  static const int maxEntries = 50; // 容量上限：50条

  /// 获取当前用户的 SharedPreferences key
  static String get _prefsKey => UserDataManager.instance.prefsKey(_basePrefsKey);

  /// 内存缓存
  static List<DiceRecord>? _cache;

  /// 清除内存缓存（用户切换时调用）
  static void clearCache() => _cache = null;

  /// 加载所有历史（按时间倒序）
  static Future<List<DiceRecord>> loadAll() async {
    if (_cache != null) return List.of(_cache!);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        _cache = [];
        return [];
      }
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => DiceRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      // 按时间倒序
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      _cache = list;
      AppLogger.i(_logTag, '加载掷骰子历史 ${list.length} 条');
      return List.of(list);
    } catch (e, st) {
      AppLogger.e(_logTag, '加载掷骰子历史失败', e, st);
      _cache = [];
      return [];
    }
  }

  /// 添加一条历史记录（超出容量自动删旧）
  static Future<void> add(DiceRecord record) async {
    final list = await loadAll();
    list.insert(0, record); // 最新的在前
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    _cache = list;
    await _persist(list);
    AppLogger.i(
      _logTag,
      '添加掷骰子历史：${record.diceType.label} -> ${record.result}',
    );
    // 后台同步到服务器
    _triggerSync();
  }

  /// 清空所有历史
  static Future<void> clear() async {
    _cache = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    AppLogger.i(_logTag, '清空所有掷骰子历史');
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
    AppLogger.i(_logTag, '批量删除掷骰子历史 ${ids.length} 条');
  }

  /// 合并服务器下载的数据（去重：以 id 为准，本地已有的不覆盖）
  static Future<int> mergeFromServer(List<DiceRecord> serverRecords) async {
    final localList = await loadAll();
    final localIds = localList.map((e) => e.id).toSet();
    final newRecords = serverRecords.where((r) => !localIds.contains(r.id)).toList();
    if (newRecords.isEmpty) return 0;
    localList.addAll(newRecords);
    localList.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (localList.length > maxEntries) {
      localList.removeRange(maxEntries, localList.length);
    }
    _cache = localList;
    await _persist(localList);
    AppLogger.i(_logTag, '从服务器合并骰子历史 ${newRecords.length} 条');
    return newRecords.length;
  }

  /// 随机掷骰子
  static int roll(DiceType type) {
    return 1 + Random().nextInt(type.sides);
  }

  /// 持久化到 SharedPreferences
  static Future<void> _persist(List<DiceRecord> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(list.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsKey, raw);
    } catch (e, st) {
      AppLogger.e(_logTag, '持久化掷骰子历史失败', e, st);
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
