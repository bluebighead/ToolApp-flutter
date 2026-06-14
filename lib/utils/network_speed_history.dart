// 网速测试历史记录工具
// 负责 PingRecord 的 JSON 序列化、SharedPreferences 持久化、容量裁剪、统计计算
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'dart:convert';

import 'app_logger.dart';
import 'user_data_manager.dart';
import 'app_settings.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

/// 单次测速记录
class PingRecord {
  /// 测速时间（本地时区）
  final DateTime timestamp;

  /// 测速服务器 URL
  final String server;

  /// 原始样本（毫秒），null 表示丢包
  final List<int?> samples;

  /// 最小有效延迟（毫秒）
  final int min;

  /// 平均有效延迟（毫秒）
  final int avg;

  /// 最大有效延迟（毫秒）
  final int max;

  /// 相邻样本差绝对值的平均（毫秒）
  final int jitter;

  /// 丢包率 0.0 ~ 1.0
  final double lossRate;

  PingRecord({
    required this.timestamp,
    required this.server,
    required this.samples,
    required this.min,
    required this.avg,
    required this.max,
    required this.jitter,
    required this.lossRate,
  });

  /// 序列化为 JSON Map
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'server': server,
        'samples': samples.map((s) => s).toList(),
        'min': min,
        'avg': avg,
        'max': max,
        'jitter': jitter,
        'lossRate': lossRate,
      };

  /// 从 JSON Map 反序列化
  factory PingRecord.fromJson(Map<String, dynamic> json) {
    // samples 字段可能为 null、非列表或包含非 int 数据
    final samplesRaw = json['samples'];
    final samplesList = <int?>[];
    if (samplesRaw is List) {
      for (final s in samplesRaw) {
        if (s == null) {
          samplesList.add(null);
        } else if (s is num) {
          samplesList.add(s.toInt());
        } else {
          // 非法类型，忽略（但保留一个占位 null，保持条数大致一致）
          samplesList.add(null);
        }
      }
    }

    // 安全地取其他字段
    DateTime timestamp;
    try {
      timestamp = DateTime.parse(json['timestamp'] as String? ??
          DateTime.now().toIso8601String());
    } catch (_) {
      timestamp = DateTime.now();
    }

    final server = json['server'] as String? ?? '';
    final min = (json['min'] as num?)?.toInt() ?? 0;
    final avg = (json['avg'] as num?)?.toInt() ?? 0;
    final max = (json['max'] as num?)?.toInt() ?? 0;
    final jitter = (json['jitter'] as num?)?.toInt() ?? 0;
    final lossRate = (json['lossRate'] as num?)?.toDouble() ?? 0.0;

    return PingRecord(
      timestamp: timestamp,
      server: server,
      samples: samplesList,
      min: min,
      avg: avg,
      max: max,
      jitter: jitter,
      lossRate: lossRate,
    );
  }
}

/// 统计指标聚合
class PingRecordStats {
  final int min;
  final int avg;
  final int max;
  final int jitter;
  final double lossRate;

  const PingRecordStats({
    required this.min,
    required this.avg,
    required this.max,
    required this.jitter,
    required this.lossRate,
  });
}

/// 历史记录读写工具
class NetworkSpeedHistory {
  /// SharedPreferences 键名基础部分
  static const String _baseKey = 'network_speed_history';

  /// 获取当前用户的 SharedPreferences key
  static String get _key => UserDataManager.instance.prefsKey(_baseKey);

  /// 最大保存条数
  static const int _maxRecords = 20;

  /// 保存一条记录：序列化、追加、裁剪、写回
  static Future<void> save(PingRecord record) async {
    final prefs = AppSettings.prefs!;
    // 读取现有记录
    final existing = await loadAll();
    // 追加新记录
    existing.insert(0, record);
    // 裁剪到 _maxRecords 条
    final trimmed = existing.take(_maxRecords).toList();
    // 序列化为 JSON 字符串
    final jsonList = trimmed.map((r) => r.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    // 写回 SharedPreferences
    await prefs.setString(_key, jsonString);
    // 后台同步到服务器
    _triggerSync();
  }

  /// 读取全部记录：按 timestamp 倒序（最新在前）
  static Future<List<PingRecord>> loadAll() async {
    final prefs = AppSettings.prefs!;
    final jsonString = prefs.getString(_key);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      final records = <PingRecord>[];
      for (final item in jsonList) {
        if (item is Map<String, dynamic>) {
          try {
            records.add(PingRecord.fromJson(item));
          } catch (e) {
            AppLogger.w('NetworkSpeedHistory', '单条测速记录解析失败，跳过：$e');
          }
        }
      }
      return records;
    } catch (e) {
      AppLogger.e('NetworkSpeedHistory', '解析测速历史失败，清除损坏缓存：$e');
      try {
        await prefs.remove(_key);
      } catch (_) {}
      return [];
    }
  }

  /// 清空全部记录
  static Future<void> clear() async {
    final prefs = AppSettings.prefs!;
    await prefs.remove(_key);
  }

  /// 合并服务器下载的数据（去重：以 timestamp 为准，本地已有的不覆盖）
  static Future<int> mergeFromServer(List<PingRecord> serverRecords) async {
    final localList = await loadAll();
    final localTimestamps = localList.map((e) => e.timestamp.toIso8601String()).toSet();
    final newRecords = serverRecords.where((r) => !localTimestamps.contains(r.timestamp.toIso8601String())).toList();
    if (newRecords.isEmpty) return 0;
    localList.addAll(newRecords);
    localList.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final trimmed = localList.take(_maxRecords).toList();
    final prefs = AppSettings.prefs!;
    final jsonList = trimmed.map((r) => r.toJson()).toList();
    await prefs.setString(_key, jsonEncode(jsonList));
    AppLogger.i('NetworkSpeedHistory', '从服务器合并网速历史 ${newRecords.length} 条');
    return newRecords.length;
  }

  /// 从原始样本计算统计指标
  /// 返回 (min, avg, max, jitter, lossRate)
  /// 全部为 null 时所有统计项均返回 0，lossRate 返回 1.0
  static PingRecordStats computeStats(List<int?> samples) {
    if (samples.isEmpty) {
      return PingRecordStats(min: 0, avg: 0, max: 0, jitter: 0, lossRate: 1.0);
    }
    final valid = samples.whereType<int>().toList();
    final loss = (samples.length - valid.length) / samples.length;
    if (valid.isEmpty) {
      return PingRecordStats(min: 0, avg: 0, max: 0, jitter: 0, lossRate: loss);
    }
    final min = valid.reduce((a, b) => a < b ? a : b);
    final max = valid.reduce((a, b) => a > b ? a : b);
    final sum = valid.reduce((a, b) => a + b);
    final avg = (sum / valid.length).round();
    // 抖动：相邻样本差绝对值的平均
    int jitter = 0;
    if (valid.length >= 2) {
      var jitterSum = 0;
      for (var i = 1; i < valid.length; i++) {
        jitterSum += (valid[i] - valid[i - 1]).abs();
      }
      jitter = (jitterSum / (valid.length - 1)).round();
    }
    return PingRecordStats(
      min: min,
      avg: avg,
      max: max,
      jitter: jitter,
      lossRate: loss,
    );
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
