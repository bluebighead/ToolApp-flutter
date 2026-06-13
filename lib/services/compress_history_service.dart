// 压缩历史记录持久化服务
// 使用 shared_preferences 存储历史记录列表（JSON 格式）
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/compress_history.dart';

class CompressHistoryService {
  static const String _key = 'compress_history_list';
  static const int _maxRecords = 200; // 最大保留 200 条记录

  /// 加载所有历史记录（按时间倒序）
  static Future<List<CompressHistory>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) =>
              CompressHistory.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      return [];
    }
  }

  /// 添加一条记录
  static Future<void> add(CompressHistory record) async {
    final list = await loadAll();
    list.insert(0, record);
    // 限制最大条数
    if (list.length > _maxRecords) {
      list.removeRange(_maxRecords, list.length);
    }
    await _save(list);
  }

  /// 删除指定记录
  static Future<void> delete(List<String> ids) async {
    final list = await loadAll();
    list.removeWhere((r) => ids.contains(r.id));
    await _save(list);
  }

  /// 清空所有记录
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// 保存列表到 SharedPreferences
  static Future<void> _save(List<CompressHistory> list) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr =
        jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_key, jsonStr);
  }
}
