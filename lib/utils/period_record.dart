// 经期宝数据模型
// 纯数据模型层，不含业务逻辑和持久化

import 'dart:convert';

/// 经期记录
class PeriodRecord {
  final String id;
  final DateTime startDate;
  final DateTime? endDate;
  final int flowLevel;
  final List<String> symptoms;
  final String notes;
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
  final DateTime date;
  final String notes;

  const OvulationMark({
    required this.date,
    this.notes = '',
  });

  factory OvulationMark.fromJson(Map<String, dynamic> json) {
    return OvulationMark(
      date: json['date'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['date'] as int)
          : DateTime.now(),
      notes: json['notes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date.millisecondsSinceEpoch,
        'notes': notes,
      };
}

/// 用户设置
class PeriodSettings {
  final int averageCycleLength;
  final int averagePeriodLength;
  final int lutealPhaseLength;
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
