// 经期宝数据模型、存储逻辑和预测算法
// 支持经期记录、排卵日标记、日历法预测
// 使用 SharedPreferences + JSON 持久化数据
// 同时使用文件备份防止版本更新时数据丢失
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'user_data_manager.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

// ============================================================
// 数据模型
// ============================================================

/// 经期记录
class PeriodRecord {
  /// 唯一ID（时间戳字符串）
  final String id;

  /// 经期开始日期
  final DateTime startDate;

  /// 经期结束日期（null表示进行中）
  final DateTime? endDate;

  /// 经量等级：1=少 2=中 3=多
  final int flowLevel;

  /// 症状标签列表
  final List<String> symptoms;

  /// 备注
  final String notes;

  /// 记录模式：'precise'=精确模式（有结束日期），'fuzzy'=模糊模式（无结束日期）
  final String mode;

  const PeriodRecord({
    required this.id,
    required this.startDate,
    this.endDate,
    this.flowLevel = 2,
    this.symptoms = const [],
    this.notes = '',
    this.mode = 'precise',
  });

  /// 经期持续天数（含开始日和结束日）
  int get durationDays {
    if (endDate == null) return 1;
    return endDate!.difference(startDate).inDays + 1;
  }

  PeriodRecord copyWith({
    String? id,
    DateTime? startDate,
    DateTime? endDate,
    bool clearEndDate = false,
    int? flowLevel,
    List<String>? symptoms,
    String? notes,
    String? mode,
  }) {
    return PeriodRecord(
      id: id ?? this.id,
      startDate: startDate ?? this.startDate,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      flowLevel: flowLevel ?? this.flowLevel,
      symptoms: symptoms ?? this.symptoms,
      notes: notes ?? this.notes,
      mode: mode ?? this.mode,
    );
  }

  /// 从 JSON 反序列化
  factory PeriodRecord.fromJson(Map<String, dynamic> json) {
    return PeriodRecord(
      id: json['id'] as String? ?? '',
      startDate: json['startDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['startDate'] as int)
          : DateTime.now(),
      endDate: json['endDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['endDate'] as int)
          : null,
      flowLevel: (json['flowLevel'] as int? ?? 2).clamp(1, 3),
      symptoms: (json['symptoms'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
      notes: json['notes'] as String? ?? '',
      mode: json['mode'] as String? ?? 'precise',
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'startDate': startDate.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
        'flowLevel': flowLevel,
        'symptoms': symptoms,
        'notes': notes,
        'mode': mode,
      };
}

/// 排卵日标记
class OvulationMark {
  /// 标记的排卵日
  final DateTime date;

  /// 备注
  final String notes;

  const OvulationMark({
    required this.date,
    this.notes = '',
  });

  /// 从 JSON 反序列化
  factory OvulationMark.fromJson(Map<String, dynamic> json) {
    return OvulationMark(
      date: json['date'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['date'] as int)
          : DateTime.now(),
      notes: json['notes'] as String? ?? '',
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'date': date.millisecondsSinceEpoch,
        'notes': notes,
      };
}

/// 用户设置
class PeriodSettings {
  /// 平均周期天数
  final int averageCycleLength;

  /// 平均经期天数
  final int averagePeriodLength;

  /// 黄体期天数（用于推算排卵日）
  final int lutealPhaseLength;

  /// 智能模式：开启后自动根据历史记录计算参数，手动设置不可用
  final bool smartMode;

  const PeriodSettings({
    this.averageCycleLength = 28,
    this.averagePeriodLength = 5,
    this.lutealPhaseLength = 14,
    this.smartMode = false,
  });

  PeriodSettings copyWith({
    int? averageCycleLength,
    int? averagePeriodLength,
    int? lutealPhaseLength,
    bool? smartMode,
  }) {
    return PeriodSettings(
      averageCycleLength: averageCycleLength ?? this.averageCycleLength,
      averagePeriodLength: averagePeriodLength ?? this.averagePeriodLength,
      lutealPhaseLength: lutealPhaseLength ?? this.lutealPhaseLength,
      smartMode: smartMode ?? this.smartMode,
    );
  }

  factory PeriodSettings.fromJson(Map<String, dynamic> json) {
    return PeriodSettings(
      averageCycleLength:
          (json['averageCycleLength'] as int? ?? 28).clamp(20, 45),
      averagePeriodLength:
          (json['averagePeriodLength'] as int? ?? 5).clamp(1, 10),
      lutealPhaseLength:
          (json['lutealPhaseLength'] as int? ?? 14).clamp(10, 16),
      smartMode: json['smartMode'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'averageCycleLength': averageCycleLength,
        'averagePeriodLength': averagePeriodLength,
        'lutealPhaseLength': lutealPhaseLength,
        'smartMode': smartMode,
      };
}

// ============================================================
// 预测算法
// ============================================================

/// 日期类型枚举（用于日历标注）
enum DayType {
  /// 普通日
  none,

  /// 经期（已记录）
  period,

  /// 预测经期
  periodPredicted,

  /// 排卵日（预测）
  ovulation,

  /// 排卵日（手动标记）
  ovulationMarked,

  /// 排卵期
  ovulationPhase,

  /// 安全期
  safe,
}

/// 日期范围（简化版，避免依赖 Flutter UI 层）
class DateRange {
  final DateTime start;
  final DateTime end;

  const DateRange({required this.start, required this.end});
}

/// 预测结果
class PeriodPrediction {
  /// 下次经期预测开始日
  final DateTime? nextPeriodStart;

  /// 下次经期预测结束日
  final DateTime? nextPeriodEnd;

  /// 排卵日预测
  final DateTime? ovulationDay;

  /// 排卵期范围
  final DateRange? ovulationPhase;

  /// 安全期范围
  final DateRange? safePhase;

  /// 计算出的平均周期天数
  final int calculatedCycleLength;

  const PeriodPrediction({
    this.nextPeriodStart,
    this.nextPeriodEnd,
    this.ovulationDay,
    this.ovulationPhase,
    this.safePhase,
    this.calculatedCycleLength = 28,
  });
}

/// 经期预测计算器
class PeriodCalculator {
  /// 根据经期记录和设置计算预测结果
  static PeriodPrediction predict({
    required List<PeriodRecord> records,
    required PeriodSettings settings,
    required List<OvulationMark> ovulationMarks,
  }) {
    if (records.isEmpty) {
      return const PeriodPrediction(
        calculatedCycleLength: 28,
      );
    }

    // 按开始日期排序（从早到晚）
    final sorted = List<PeriodRecord>.from(records)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));

    // 计算平均周期
    int cycleLength = settings.averageCycleLength;
    int periodLength = settings.averagePeriodLength;
    int lutealLength = settings.lutealPhaseLength;

    // 智能模式：根据历史记录自动计算参数
    if (settings.smartMode && sorted.length >= 2) {
      // 取最近6次记录计算平均周期
      final recentCount = sorted.length.clamp(2, 6);
      final recent = sorted.sublist(sorted.length - recentCount);
      int totalDays = 0;
      int intervals = 0;
      for (int i = 1; i < recent.length; i++) {
        totalDays += recent[i]
            .startDate
            .difference(recent[i - 1].startDate)
            .inDays;
        intervals++;
      }
      if (intervals > 0) {
        cycleLength = (totalDays / intervals).round().clamp(20, 45);
      }
      // 平均经期天数
      final recentPeriods = sorted.sublist(sorted.length - recentCount);
      final totalPeriodDays =
          recentPeriods.map((r) => r.durationDays).reduce((a, b) => a + b);
      periodLength = (totalPeriodDays / recentPeriods.length).round().clamp(1, 10);
    } else if (sorted.length >= 2) {
      // 非智能模式但有记录时，仍取最近6次计算周期
      final recentCount = sorted.length.clamp(2, 6);
      final recent = sorted.sublist(sorted.length - recentCount);
      int totalDays = 0;
      int intervals = 0;
      for (int i = 1; i < recent.length; i++) {
        totalDays += recent[i]
            .startDate
            .difference(recent[i - 1].startDate)
            .inDays;
        intervals++;
      }
      if (intervals > 0) {
        cycleLength = (totalDays / intervals).round().clamp(20, 45);
      }
    }

    final lastPeriod = sorted.last;
    final lastPeriodStart = lastPeriod.startDate;

    // 下次经期预测
    final nextPeriodStart =
        lastPeriodStart.add(Duration(days: cycleLength));
    final nextPeriodEnd = nextPeriodStart
        .add(Duration(days: periodLength - 1));

    // 排卵日预测：下次经期前黄体期天数
    DateTime? ovulationDay = nextPeriodStart
        .subtract(Duration(days: lutealLength));

    // 检查是否有手动排卵标记覆盖
    // 如果手动标记的排卵日在当前周期范围内，使用手动标记
    for (final mark in ovulationMarks) {
      final markDate =
          DateTime(mark.date.year, mark.date.month, mark.date.day);
      // 手动标记日在上次经期之后、下次经期之前
      if (markDate.isAfter(lastPeriodStart) &&
          markDate.isBefore(nextPeriodStart)) {
        ovulationDay = markDate;
        break;
      }
    }

    // 排卵期：排卵日前5天 ~ 排卵日后1天（共7天）
    final ovulationPhase = DateRange(
      start: ovulationDay!.subtract(const Duration(days: 5)),
      end: ovulationDay.add(const Duration(days: 1)),
    );

    // 安全期：经期结束后 ~ 排卵期前3天
    final periodEnd = lastPeriod.endDate ??
        lastPeriodStart
            .add(Duration(days: settings.averagePeriodLength - 1));
    final safePhaseEnd = ovulationDay.subtract(const Duration(days: 6));
    DateRange? safePhase;
    if (safePhaseEnd.isAfter(periodEnd)) {
      safePhase = DateRange(
        start: periodEnd.add(const Duration(days: 1)),
        end: safePhaseEnd,
      );
    }

    return PeriodPrediction(
      nextPeriodStart: nextPeriodStart,
      nextPeriodEnd: nextPeriodEnd,
      ovulationDay: ovulationDay,
      ovulationPhase: ovulationPhase,
      safePhase: safePhase,
      calculatedCycleLength: cycleLength,
    );
  }

  /// 判断某一天的类型（用于日历标注）
  static DayType getDayType({
    required DateTime date,
    required List<PeriodRecord> records,
    required PeriodPrediction prediction,
    required List<OvulationMark> ovulationMarks,
  }) {
    final d = DateTime(date.year, date.month, date.day);

    // 1. 检查是否为手动标记的排卵日
    for (final mark in ovulationMarks) {
      final markDate =
          DateTime(mark.date.year, mark.date.month, mark.date.day);
      if (d == markDate) return DayType.ovulationMarked;
    }

    // 2. 检查是否为已记录的经期
    for (final record in records) {
      final start = DateTime(record.startDate.year,
          record.startDate.month, record.startDate.day);
      if (d.isBefore(start)) continue;
      if (record.endDate != null) {
        final end = DateTime(record.endDate!.year,
            record.endDate!.month, record.endDate!.day);
        if (!d.isAfter(end)) return DayType.period;
      } else {
        // 经期进行中（无结束日期），只标记开始日当天
        if (d == start) return DayType.period;
      }
    }

    // 3. 检查预测结果
    if (prediction.nextPeriodStart != null &&
        prediction.nextPeriodEnd != null) {
      final ps = DateTime(
          prediction.nextPeriodStart!.year,
          prediction.nextPeriodStart!.month,
          prediction.nextPeriodStart!.day);
      final pe = DateTime(
          prediction.nextPeriodEnd!.year,
          prediction.nextPeriodEnd!.month,
          prediction.nextPeriodEnd!.day);
      if (!d.isBefore(ps) && !d.isAfter(pe)) {
        return DayType.periodPredicted;
      }
    }

    // 4. 检查排卵日
    if (prediction.ovulationDay != null) {
      final od = DateTime(prediction.ovulationDay!.year,
          prediction.ovulationDay!.month, prediction.ovulationDay!.day);
      if (d == od) return DayType.ovulation;
    }

    // 5. 检查排卵期
    if (prediction.ovulationPhase != null) {
      if (!d.isBefore(prediction.ovulationPhase!.start) &&
          !d.isAfter(prediction.ovulationPhase!.end)) {
        return DayType.ovulationPhase;
      }
    }

    // 6. 检查安全期
    if (prediction.safePhase != null) {
      if (!d.isBefore(prediction.safePhase!.start) &&
          !d.isAfter(prediction.safePhase!.end)) {
        return DayType.safe;
      }
    }

    return DayType.none;
  }

  /// 计算周期统计信息
  static PeriodStats calculateStats(List<PeriodRecord> records) {
    if (records.isEmpty) {
      return const PeriodStats(
        averageCycle: 28,
        averagePeriodLength: 5,
        shortestCycle: 0,
        longestCycle: 0,
        cycleLengths: [],
      );
    }

    final sorted = List<PeriodRecord>.from(records)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));

    final cycleLengths = <int>[];
    for (int i = 1; i < sorted.length; i++) {
      cycleLengths.add(sorted[i]
          .startDate
          .difference(sorted[i - 1].startDate)
          .inDays);
    }

    final periodLengths = sorted.map((r) => r.durationDays).toList();

    return PeriodStats(
      averageCycle: cycleLengths.isEmpty
          ? 28
          : (cycleLengths.reduce((a, b) => a + b) / cycleLengths.length)
              .round(),
      averagePeriodLength:
          (periodLengths.reduce((a, b) => a + b) / periodLengths.length)
              .round(),
      shortestCycle:
          cycleLengths.isEmpty ? 0 : cycleLengths.reduce((a, b) => a < b ? a : b),
      longestCycle:
          cycleLengths.isEmpty ? 0 : cycleLengths.reduce((a, b) => a > b ? a : b),
      cycleLengths: cycleLengths,
    );
  }
}

/// 周期统计信息
class PeriodStats {
  final int averageCycle;
  final int averagePeriodLength;
  final int shortestCycle;
  final int longestCycle;
  final List<int> cycleLengths;

  const PeriodStats({
    required this.averageCycle,
    required this.averagePeriodLength,
    required this.shortestCycle,
    required this.longestCycle,
    required this.cycleLengths,
  });
}

// ============================================================
// 存储逻辑
// ============================================================

/// 经期宝存储工具
/// 使用 SharedPreferences 作为主存储，同时自动备份到文件防止数据丢失
class PeriodStorage {
  static const String _kBaseRecordsKey = 'period_records';
  static const String _kBaseOvulationMarksKey = 'period_ovulation_marks';
  static const String _kBaseSettingsKey = 'period_settings';

  // 文件备份路径
  static const String _kBackupFileName = 'period_backup.json';

  /// 获取当前用户的 SharedPreferences key
  static String get _kRecordsKey => UserDataManager.instance.prefsKey(_kBaseRecordsKey);
  static String get _kOvulationMarksKey => UserDataManager.instance.prefsKey(_kBaseOvulationMarksKey);
  static String get _kSettingsKey => UserDataManager.instance.prefsKey(_kBaseSettingsKey);

  /// 获取备份文件目录
  static Future<Directory> _getBackupDir() async {
    return getApplicationDocumentsDirectory();
  }

  /// 获取备份文件完整路径
  static Future<String> _getBackupFilePath() async {
    final dir = await _getBackupDir();
    return '${dir.path}/$_kBackupFileName';
  }

  /// 写入文件备份（所有数据合并到一个 JSON 文件）
  static Future<void> _writeBackup({
    List<PeriodRecord>? records,
    List<OvulationMark>? ovulationMarks,
    PeriodSettings? settings,
  }) async {
    try {
      final path = await _getBackupFilePath();
      final file = File(path);

      // 如果部分数据未提供，先读取现有备份
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

  /// 从文件备份恢复数据
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
      final data = jsonDecode(content) as Map<String, dynamic>;
      return data;
    } catch (e) {
      AppLogger.e('PeriodStorage', '读取文件备份失败：$e');
      // 备份文件损坏时自动删除，避免下次继续出错
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

  /// 加载经期记录（优先从 SharedPreferences，失败时从文件备份恢复）
  static Future<List<PeriodRecord>> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kRecordsKey);

    // SharedPreferences 有数据
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
        // 同步到文件备份
        _writeBackup(records: records);
        return records;
      } catch (e) {
        AppLogger.e('PeriodStorage', '加载经期记录失败：$e');
        // 数据损坏时清除 SharedPreferences，避免下次继续报错
        try {
          await prefs.remove(_kRecordsKey);
          AppLogger.i('PeriodStorage', '已清除损坏的经期记录缓存');
        } catch (_) {}
      }
    }

    // SharedPreferences 无数据，尝试从文件备份恢复
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
        // 恢复到 SharedPreferences
        await saveRecords(records);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复 ${records.length} 条经期记录');
        return records;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复经期记录失败：$e');
      }
    }

    return [];
  }

  /// 保存经期记录（同时写入 SharedPreferences 和文件备份）
  static Future<void> saveRecords(List<PeriodRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(records.map((e) => e.toJson()).toList());
    await prefs.setString(_kRecordsKey, jsonStr);
    // 同步文件备份
    _writeBackup(records: records);
  }

  /// 添加经期记录
  static Future<void> addRecord(PeriodRecord record) async {
    final records = await loadRecords();
    records.add(record);
    // 按开始日期排序
    records.sort((a, b) => a.startDate.compareTo(b.startDate));
    await saveRecords(records);
    // 后台同步到服务器
    _triggerSync();
  }

  /// 更新经期记录
  static Future<void> updateRecord(PeriodRecord record) async {
    final records = await loadRecords();
    final index = records.indexWhere((r) => r.id == record.id);
    if (index >= 0) {
      records[index] = record;
      records.sort((a, b) => a.startDate.compareTo(b.startDate));
      await saveRecords(records);
      // 后台同步到服务器
      _triggerSync();
    }
  }

  /// 删除经期记录
  static Future<void> deleteRecord(String recordId) async {
    final records = await loadRecords();
    records.removeWhere((r) => r.id == recordId);
    await saveRecords(records);
  }

  /// 合并服务器下载的数据（去重：以 id 为准，本地已有的不覆盖）
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

  /// 加载排卵日标记（优先从 SharedPreferences，失败时从文件备份恢复）
  static Future<List<OvulationMark>> loadOvulationMarks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kOvulationMarksKey);

    // SharedPreferences 有数据
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
        // 同步到文件备份
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

    // SharedPreferences 无数据，尝试从文件备份恢复
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
        // 恢复到 SharedPreferences
        await saveOvulationMarks(marks);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复 ${marks.length} 条排卵日标记');
        return marks;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复排卵日标记失败：$e');
      }
    }

    return [];
  }

  /// 保存排卵日标记（同时写入 SharedPreferences 和文件备份）
  static Future<void> saveOvulationMarks(List<OvulationMark> marks) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(marks.map((e) => e.toJson()).toList());
    await prefs.setString(_kOvulationMarksKey, jsonStr);
    // 同步文件备份
    _writeBackup(ovulationMarks: marks);
  }

  /// 添加排卵日标记
  static Future<void> addOvulationMark(OvulationMark mark) async {
    final marks = await loadOvulationMarks();
    // 去重：同一天只保留一个标记
    marks.removeWhere((m) =>
        m.date.year == mark.date.year &&
        m.date.month == mark.date.month &&
        m.date.day == mark.date.day);
    marks.add(mark);
    marks.sort((a, b) => a.date.compareTo(b.date));
    await saveOvulationMarks(marks);
  }

  /// 删除排卵日标记
  static Future<void> deleteOvulationMark(DateTime date) async {
    final marks = await loadOvulationMarks();
    marks.removeWhere((m) =>
        m.date.year == date.year &&
        m.date.month == date.month &&
        m.date.day == date.day);
    await saveOvulationMarks(marks);
  }

  /// 加载设置（优先从 SharedPreferences，失败时从文件备份恢复）
  static Future<PeriodSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kSettingsKey);

    // SharedPreferences 有数据
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final settings = PeriodSettings.fromJson(
            jsonDecode(jsonStr) as Map<String, dynamic>);
        // 同步到文件备份
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

    // SharedPreferences 无数据，尝试从文件备份恢复
    AppLogger.w('PeriodStorage', 'SharedPreferences 无设置，尝试从文件备份恢复');
    final backup = await _readBackup();
    if (backup != null && backup['settings'] != null) {
      try {
        final settings = PeriodSettings.fromJson(
            Map<String, dynamic>.from(backup['settings'] as Map));
        // 恢复到 SharedPreferences
        await saveSettings(settings);
        AppLogger.i('PeriodStorage', '从文件备份成功恢复设置');
        return settings;
      } catch (e) {
        AppLogger.e('PeriodStorage', '从文件备份恢复设置失败：$e');
      }
    }

    return const PeriodSettings();
  }

  /// 保存设置（同时写入 SharedPreferences 和文件备份）
  static Future<void> saveSettings(PeriodSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSettingsKey, jsonEncode(settings.toJson()));
    // 同步文件备份
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

/// 预置症状标签
const List<String> kSymptomOptions = [
  '痛经',
  '头痛',
  '腰酸',
  '乏力',
  '情绪波动',
  '腹胀',
  '胸胀',
  '失眠',
  '长痘',
  '食欲增加',
];
