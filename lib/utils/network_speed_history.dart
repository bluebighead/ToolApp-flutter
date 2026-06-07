// 网速测试历史记录工具
// 负责 PingRecord 的 JSON 序列化、SharedPreferences 持久化、容量裁剪、统计计算
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

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
    final raw = (json['samples'] as List).cast<dynamic>();
    return PingRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      server: json['server'] as String,
      samples: raw.map((e) => e == null ? null : e as int).toList(),
      min: json['min'] as int,
      avg: json['avg'] as int,
      max: json['max'] as int,
      jitter: json['jitter'] as int,
      lossRate: (json['lossRate'] as num).toDouble(),
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
  /// SharedPreferences 键名
  static const String _key = 'network_speed_history';

  /// 最大保存条数
  static const int _maxRecords = 20;

  /// 保存一条记录：序列化、追加、裁剪、写回
  static Future<void> save(PingRecord record) async {
    final prefs = await SharedPreferences.getInstance();
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
  }

  /// 读取全部记录：按 timestamp 倒序（最新在前）
  static Future<List<PingRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_key);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((e) => PingRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 解析失败视为空
      return [];
    }
  }

  /// 清空全部记录
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
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
