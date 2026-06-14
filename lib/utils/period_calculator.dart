// 经期宝预测算法
// 包含周期计算、日历标注、统计信息
import 'period_record.dart';

/// 日期类型枚举（用于日历标注）
enum DayType {
  none,
  period,
  periodPredicted,
  ovulation,
  ovulationMarked,
  ovulationPhase,
  safe,
}

/// 日期范围
class DateRange {
  final DateTime start;
  final DateTime end;
  const DateRange({required this.start, required this.end});
}

/// 预测结果
class PeriodPrediction {
  final DateTime? nextPeriodStart;
  final DateTime? nextPeriodEnd;
  final DateTime? ovulationDay;
  final DateRange? ovulationPhase;
  final DateRange? safePhase;
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

/// 经期预测计算器
class PeriodCalculator {
  static PeriodPrediction predict({
    required List<PeriodRecord> records,
    required PeriodSettings settings,
    required List<OvulationMark> ovulationMarks,
  }) {
    if (records.isEmpty) {
      return const PeriodPrediction(calculatedCycleLength: 28);
    }

    final sorted = List<PeriodRecord>.from(records)
      ..sort((a, b) => a.startDate.compareTo(b.startDate));

    int cycleLength = settings.averageCycleLength;
    int periodLength = settings.averagePeriodLength;
    int lutealLength = settings.lutealPhaseLength;

    if (settings.smartMode && sorted.length >= 2) {
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
      final recentPeriods = sorted.sublist(sorted.length - recentCount);
      final totalPeriodDays =
          recentPeriods.map((r) => r.durationDays).reduce((a, b) => a + b);
      periodLength = (totalPeriodDays / recentPeriods.length).round().clamp(1, 10);
    } else if (sorted.length >= 2) {
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

    final nextPeriodStart = lastPeriodStart.add(Duration(days: cycleLength));
    final nextPeriodEnd = nextPeriodStart.add(Duration(days: periodLength - 1));

    DateTime? ovulationDay = nextPeriodStart.subtract(Duration(days: lutealLength));

    for (final mark in ovulationMarks) {
      final markDate = DateTime(mark.date.year, mark.date.month, mark.date.day);
      if (markDate.isAfter(lastPeriodStart) && markDate.isBefore(nextPeriodStart)) {
        ovulationDay = markDate;
        break;
      }
    }

    final ovulationPhase = DateRange(
      start: ovulationDay!.subtract(const Duration(days: 5)),
      end: ovulationDay.add(const Duration(days: 1)),
    );

    final periodEnd = lastPeriod.endDate ??
        lastPeriodStart.add(Duration(days: settings.averagePeriodLength - 1));
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

  static DayType getDayType({
    required DateTime date,
    required List<PeriodRecord> records,
    required PeriodPrediction prediction,
    required List<OvulationMark> ovulationMarks,
  }) {
    final d = DateTime(date.year, date.month, date.day);

    for (final mark in ovulationMarks) {
      final markDate = DateTime(mark.date.year, mark.date.month, mark.date.day);
      if (d == markDate) return DayType.ovulationMarked;
    }

    for (final record in records) {
      final start =
          DateTime(record.startDate.year, record.startDate.month, record.startDate.day);
      if (d.isBefore(start)) continue;
      if (record.endDate != null) {
        final end =
            DateTime(record.endDate!.year, record.endDate!.month, record.endDate!.day);
        if (!d.isAfter(end)) return DayType.period;
      } else {
        if (d == start) return DayType.period;
      }
    }

    if (prediction.nextPeriodStart != null && prediction.nextPeriodEnd != null) {
      final ps = DateTime(prediction.nextPeriodStart!.year,
          prediction.nextPeriodStart!.month, prediction.nextPeriodStart!.day);
      final pe = DateTime(prediction.nextPeriodEnd!.year,
          prediction.nextPeriodEnd!.month, prediction.nextPeriodEnd!.day);
      if (!d.isBefore(ps) && !d.isAfter(pe)) return DayType.periodPredicted;
    }

    if (prediction.ovulationDay != null) {
      final od = DateTime(prediction.ovulationDay!.year,
          prediction.ovulationDay!.month, prediction.ovulationDay!.day);
      if (d == od) return DayType.ovulation;
    }

    if (prediction.ovulationPhase != null) {
      if (!d.isBefore(prediction.ovulationPhase!.start) &&
          !d.isAfter(prediction.ovulationPhase!.end)) {
        return DayType.ovulationPhase;
      }
    }

    if (prediction.safePhase != null) {
      if (!d.isBefore(prediction.safePhase!.start) &&
          !d.isAfter(prediction.safePhase!.end)) {
        return DayType.safe;
      }
    }

    return DayType.none;
  }

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
      cycleLengths.add(
          sorted[i].startDate.difference(sorted[i - 1].startDate).inDays);
    }

    final periodLengths = sorted.map((r) => r.durationDays).toList();

    return PeriodStats(
      averageCycle: cycleLengths.isEmpty
          ? 28
          : (cycleLengths.reduce((a, b) => a + b) / cycleLengths.length).round(),
      averagePeriodLength:
          (periodLengths.reduce((a, b) => a + b) / periodLengths.length).round(),
      shortestCycle:
          cycleLengths.isEmpty ? 0 : cycleLengths.reduce((a, b) => a < b ? a : b),
      longestCycle:
          cycleLengths.isEmpty ? 0 : cycleLengths.reduce((a, b) => a > b ? a : b),
      cycleLengths: cycleLengths,
    );
  }
}
