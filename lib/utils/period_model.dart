// 经期宝数据模型、存储逻辑和预测算法
//
// v1.52.8+ 重构：数据模型拆分到 period_record.dart，算法拆分到 period_calculator.dart
// 本文件保持向后兼容，重新导出所有公开类型

export 'period_record.dart';
export 'period_calculator.dart';

import 'period_record.dart';
import 'period_calculator.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'app_settings.dart';
import 'user_data_manager.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

// ============================================================
// 存储逻辑
// ============================================================

/// 经期宝存储工具
/// 使用 SharedPreferences 作为主存储，同时自动备份到文件防止数据丢失
class PeriodStorage {
  static const String _kBaseRecordsKey = 'period_records';
  static const String _kBaseOvulationMarksKey = 'period_ovulation_marks';
  static const String _kBaseSettingsKey = 'period_settings';

  static const String _kBackupFileName = 'period_backup.json';

  static String get _kRecordsKey => UserDataManager.instance.prefsKey(_kBaseRecordsKey);
  static String get _kOvulationMarksKey => UserDataManager.instance.prefsKey(_kBaseOvulationMarksKey);
  static String get _kSettingsKey => UserDataManager.instance.prefsKey(_kBaseSettingsKey);

  static Future<Directory> _getBackupDir() async {
    return getApplicationDocumentsDirectory();
  }

  static Future<String> _getBackupFilePath() async {
    final dir = await _getBackupDir();
    return '${dir.path}/$_kBackupFileName';
  }

  static Future<void> _writeBackup({
    List<PeriodRecord>? records,
    List<OvulationMark>? ovulationMarks,
    PeriodSettings? settings,
  }) async {
    try {
      final path = await _getBackupFilePath();
      final file = File(path);
      Map<String, dynamic> existingData = {};
      if (records == null || ovulationMarks == null || settings == null) {
        if (await file.exists()) {
          final content = await file.readAsString();
          existingData = Map<String, dynamic>.from(jsonDecode(content));
        }
      }
      final backupData = <String, dynamic>{
        'version': 1,
        'backupTime': DateTime.now().toIso8601String(),
        'records': records?.map((e) => e.toJson()).toList()
            ?? existingData['records']
            ?? [],
        'ovulationMarks': ovulationMarks?.map((e) => e.toJson()).toList()
            ?? existingData['ovulationMarks']
            ?? [],
        'settings': settings?.toJson()
            ?? existingData['settings']
            ?? const PeriodSettings().toJson(),
      };
      await file.writeAsString(jsonEncode(backupData));
    } catch (e) {
      AppLogger.e('PeriodStorage', '写入文件备份失败：$e');
    }
  }

  static Future<Map<String, dynamic>?> _readBackup() async {
    try {
      final path = await _getBackupFilePath();
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        AppLogger.w('PeriodStorage', '备份文件为空');
        return null;
      }
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      AppLogger.e('PeriodStorage', '读取文件备份失败：$e');
      try {
        final path = await _getBackupFilePath();
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          AppLogger.i('PeriodStorage', '已删除损坏的备份文件');
        }
      } catch (_) {}
      return null;
    }
  }

  static Future<List<PeriodRecord>> loadRecords() async {
    final prefs = AppSettings.prefs!;
    final jsonStr = prefs.getString(_kRecordsKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final records = <PeriodRecord>[];
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            try {
              records.add(PeriodRecord.fromJson(item));
            } catch (e) {
              AppLogger.w('PeriodStorage', '单条记录解析失败，跳过：$e');
            }
          }
        }
        _writeBackup(records: records);
        return records;
      } catch (e) {
        AppLogger.e('PeriodStorage', '加载经期记录失败：$e');
        try {
          await prefs.remove(_kRecordsKey);
          AppLogger.i('PeriodStorage', '已清除损坏的经期记录缓存');
        } catch (_) {}
      }
    }
    AppLogger.w('PeriodStorage', 'SharedPreferences 无记录，尝试从文件备份恢复');
    final backup = await _readBackup();
    if (backup != null && backup['records'] != null) {
      try {
        final List<dynamic> jsonList = backup['records'] as List<dynamic>;
        final records = <PeriodRecord>[];
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            try {
              records.add(PeriodRecord.fromJson(item));
            } catch (e) {
              AppLogger.w('PeriodStorage', '备份单条记录解析失败，跳过：$e');
            }
          }
        }
        await saveRecords(records);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复 ${records.length} 条经期记录');
        return records;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复经期记录失败：$e');
      }
    }
    return [];
  }

  static Future<void> saveRecords(List<PeriodRecord> records) async {
    final prefs = AppSettings.prefs!;
    final jsonStr = jsonEncode(records.map((e) => e.toJson()).toList());
    await prefs.setString(_kRecordsKey, jsonStr);
    _writeBackup(records: records);
  }

  static Future<void> addRecord(PeriodRecord record) async {
    final records = await loadRecords();
    records.add(record);
    records.sort((a, b) => a.startDate.compareTo(b.startDate));
    await saveRecords(records);
    _triggerSync();
  }

  static Future<void> updateRecord(PeriodRecord record) async {
    final records = await loadRecords();
    final index = records.indexWhere((r) => r.id == record.id);
    if (index >= 0) {
      records[index] = record;
      records.sort((a, b) => a.startDate.compareTo(b.startDate));
      await saveRecords(records);
      _triggerSync();
    }
  }

  static Future<void> deleteRecord(String recordId) async {
    final records = await loadRecords();
    records.removeWhere((r) => r.id == recordId);
    await saveRecords(records);
  }

  static Future<int> mergeRecordsFromServer(List<PeriodRecord> serverRecords) async {
    final localList = await loadRecords();
    final localIds = localList.map((e) => e.id).toSet();
    final newRecords = serverRecords.where((r) => !localIds.contains(r.id)).toList();
    if (newRecords.isEmpty) return 0;
    localList.addAll(newRecords);
    localList.sort((a, b) => a.startDate.compareTo(b.startDate));
    await saveRecords(localList);
    AppLogger.i('PeriodStorage', '从服务器合并经期记录 ${newRecords.length} 条');
    return newRecords.length;
  }

  static Future<List<OvulationMark>> loadOvulationMarks() async {
    final prefs = AppSettings.prefs!;
    final jsonStr = prefs.getString(_kOvulationMarksKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final marks = <OvulationMark>[];
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            try {
              marks.add(OvulationMark.fromJson(item));
            } catch (e) {
              AppLogger.w('PeriodStorage', '单条排卵日标记解析失败，跳过：$e');
            }
          }
        }
        _writeBackup(ovulationMarks: marks);
        return marks;
      } catch (e) {
        AppLogger.e('PeriodStorage', '加载排卵日标记失败：$e');
        try {
          await prefs.remove(_kOvulationMarksKey);
          AppLogger.i('PeriodStorage', '已清除损坏的排卵日标记缓存');
        } catch (_) {}
      }
    }
    AppLogger.w('PeriodStorage', 'SharedPreferences 无标记，尝试从文件备份恢复');
    final backup = await _readBackup();
    if (backup != null && backup['ovulationMarks'] != null) {
      try {
        final List<dynamic> jsonList = backup['ovulationMarks'] as List<dynamic>;
        final marks = <OvulationMark>[];
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            try {
              marks.add(OvulationMark.fromJson(item));
            } catch (e) {
              AppLogger.w('PeriodStorage', '备份单条排卵日标记解析失败，跳过：$e');
            }
          }
        }
        await saveOvulationMarks(marks);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复 ${marks.length} 条排卵日标记');
        return marks;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复排卵日标记失败：$e');
      }
    }
    return [];
  }

  static Future<void> saveOvulationMarks(List<OvulationMark> marks) async {
    final prefs = AppSettings.prefs!;
    final jsonStr = jsonEncode(marks.map((e) => e.toJson()).toList());
    await prefs.setString(_kOvulationMarksKey, jsonStr);
    _writeBackup(ovulationMarks: marks);
  }

  static Future<void> addOvulationMark(OvulationMark mark) async {
    final marks = await loadOvulationMarks();
    marks.removeWhere((m) =>
        m.date.year == mark.date.year &&
        m.date.month == mark.date.month &&
        m.date.day == mark.date.day);
    marks.add(mark);
    marks.sort((a, b) => a.date.compareTo(b.date));
    await saveOvulationMarks(marks);
  }

  static Future<void> deleteOvulationMark(DateTime date) async {
    final marks = await loadOvulationMarks();
    marks.removeWhere((m) =>
        m.date.year == date.year &&
        m.date.month == date.month &&
        m.date.day == date.day);
    await saveOvulationMarks(marks);
  }

  static Future<PeriodSettings> loadSettings() async {
    final prefs = AppSettings.prefs!;
    final jsonStr = prefs.getString(_kSettingsKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final settings = PeriodSettings.fromJson(
            jsonDecode(jsonStr) as Map<String, dynamic>);
        _writeBackup(settings: settings);
        return settings;
      } catch (e) {
        AppLogger.e('PeriodStorage', '加载设置失败：$e');
        try {
          await prefs.remove(_kSettingsKey);
          AppLogger.i('PeriodStorage', '已清除损坏的设置缓存');
        } catch (_) {}
      }
    }
    AppLogger.w('PeriodStorage', 'SharedPreferences 无设置，尝试从文件备份恢复');
    final backup = await _readBackup();
    if (backup != null && backup['settings'] != null) {
      try {
        final settings = PeriodSettings.fromJson(
            Map<String, dynamic>.from(backup['settings'] as Map));
        await saveSettings(settings);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复设置');
        return settings;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复设置失败：$e');
      }
    }
    return const PeriodSettings();
  }

  static Future<void> saveSettings(PeriodSettings settings) async {
    final prefs = AppSettings.prefs!;
    await prefs.setString(_kSettingsKey, jsonEncode(settings.toJson()));
    _writeBackup(settings: settings);
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
