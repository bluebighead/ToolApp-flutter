// 数据同步服务：将本地数据上传到自建服务器
// 替代 Supabase SDK，使用 HTTP + JWT 调用自建轻量服务器接口
// 登录后自动同步各模块的历史数据
// 采用"全量覆盖"策略：每次同步将本地所有数据上传，覆盖服务端数据
// 适用于小范围使用场景，简单可靠
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/convert_history.dart';
import '../utils/dice_history.dart';
import '../utils/heart_rate_history.dart';
import '../utils/network_speed_history.dart';
import '../utils/period_model.dart';
import 'auth_service.dart';

class SyncService {
  // 全局单例
  static final SyncService instance = SyncService._();
  SyncService._();

  // 是否正在同步中
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  // 服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  // 构建认证请求头
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };

  /// 同步所有本地数据到服务器
  /// 返回同步结果摘要
  Future<SyncResult> syncAll() async {
    if (_isSyncing) {
      AppLogger.i('SyncService', '同步正在进行中，跳过');
      return SyncResult(skipped: true);
    }

    if (!AuthService.instance.isLoggedIn) {
      AppLogger.w('SyncService', '未登录，无法同步');
      return SyncResult(error: '未登录');
    }

    _isSyncing = true;
    int uploaded = 0;
    int failed = 0;
    final errors = <String>[];

    try {
      AppLogger.i('SyncService', '开始全量同步...');

      // 1. 同步心率历史
      final hrResult = await _syncHeartRate();
      uploaded += hrResult.uploaded;
      failed += hrResult.failed;
      if (hrResult.error != null) errors.add('心率: ${hrResult.error}');

      // 2. 同步网速历史
      final nsResult = await _syncNetworkSpeed();
      uploaded += nsResult.uploaded;
      failed += nsResult.failed;
      if (nsResult.error != null) errors.add('网速: ${nsResult.error}');

      // 3. 同步转换历史
      final cvResult = await _syncConvertHistory();
      uploaded += cvResult.uploaded;
      failed += cvResult.failed;
      if (cvResult.error != null) errors.add('转换: ${cvResult.error}');

      // 4. 同步骰子历史
      final dcResult = await _syncDiceHistory();
      uploaded += dcResult.uploaded;
      failed += dcResult.failed;
      if (dcResult.error != null) errors.add('骰子: ${dcResult.error}');

      // 5. 同步经期记录
      final pdResult = await _syncPeriodRecords();
      uploaded += pdResult.uploaded;
      failed += pdResult.failed;
      if (pdResult.error != null) errors.add('经期: ${pdResult.error}');

      AppLogger.i('SyncService', '同步完成 - 上传: $uploaded, 失败: $failed');
      return SyncResult(
        uploaded: uploaded,
        failed: failed,
        errors: errors,
      );
    } catch (e) {
      AppLogger.e('SyncService', '同步异常: $e');
      return SyncResult(error: e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  // 通用上传方法：将数据行上传到指定表
  Future<_TableSyncResult> _uploadTable(String table, List<Map<String, dynamic>> rows) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/sync/$table'),
        headers: _authHeaders,
        body: jsonEncode({'rows': rows}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return _TableSyncResult(uploaded: data['uploaded'] as int? ?? 0);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _TableSyncResult(failed: 1, error: data['error'] as String? ?? '同步失败');
    } catch (e) {
      AppLogger.e('SyncService', '$table 同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 心率历史同步
  // ============================================================
  Future<_TableSyncResult> _syncHeartRate() async {
    try {
      final records = await HeartRateHistory.loadAll();
      if (records.isEmpty) return _TableSyncResult(uploaded: 0);

      // 转换为服务端格式
      final rows = records.map((r) => {
            'start_time': DateTime.fromMillisecondsSinceEpoch(r.startTimeMs)
                .toUtc()
                .toIso8601String(),
            'end_time': DateTime.fromMillisecondsSinceEpoch(r.endTimeMs)
                .toUtc()
                .toIso8601String(),
            'max_hr': r.maxBpm,
            'min_hr': r.minBpm,
            'avg_hr': r.avgBpm,
            'samples': r.samples,
            'connection_mode': r.connectionMode.name,
          }).toList();

      return _uploadTable('heart_rate_sessions', rows);
    } catch (e) {
      AppLogger.e('SyncService', '心率同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 网速历史同步
  // ============================================================
  Future<_TableSyncResult> _syncNetworkSpeed() async {
    try {
      final records = await NetworkSpeedHistory.loadAll();
      if (records.isEmpty) return _TableSyncResult(uploaded: 0);

      final rows = records.map((r) => {
            'test_time': r.timestamp.toUtc().toIso8601String(),
            'server_url': r.server,
            'min_latency': r.min,
            'avg_latency': r.avg,
            'max_latency': r.max,
            'jitter': r.jitter,
            'loss_rate': r.lossRate,
          }).toList();

      return _uploadTable('network_speed_records', rows);
    } catch (e) {
      AppLogger.e('SyncService', '网速同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 转换历史同步
  // ============================================================
  Future<_TableSyncResult> _syncConvertHistory() async {
    try {
      final records = await ConvertHistory.loadAll();
      if (records.isEmpty) return _TableSyncResult(uploaded: 0);

      final rows = records.map((r) => {
            'input_file': r.input,
            'output_file': r.outputPath,
            'output_size': r.outputSize,
            'format': r.format.name,
            'quality': r.quality.name,
            'status': r.status.name,
            'timestamp_ms': r.timestampMs,
          }).toList();

      return _uploadTable('convert_history', rows);
    } catch (e) {
      AppLogger.e('SyncService', '转换历史同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 骰子历史同步
  // ============================================================
  Future<_TableSyncResult> _syncDiceHistory() async {
    try {
      final records = await DiceHistory.loadAll();
      if (records.isEmpty) return _TableSyncResult(uploaded: 0);

      final rows = records.map((r) => {
            'dice_type': r.diceType.name,
            'result': r.result,
            'timestamp_ms': r.timestamp,
          }).toList();

      return _uploadTable('dice_records', rows);
    } catch (e) {
      AppLogger.e('SyncService', '骰子同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 经期记录同步
  // ============================================================
  Future<_TableSyncResult> _syncPeriodRecords() async {
    try {
      final records = await PeriodStorage.loadRecords();
      if (records.isEmpty) return _TableSyncResult(uploaded: 0);

      final rows = records.map((r) => {
            'start_date': r.startDate.toIso8601String().substring(0, 10),
            'end_date': r.endDate?.toIso8601String().substring(0, 10),
            'record_mode': r.mode,
            'flow_level': r.flowLevel,
            'symptoms': r.symptoms,
            'notes': r.notes,
            'local_id': r.id,
          }).toList();

      return _uploadTable('period_records', rows);
    } catch (e) {
      AppLogger.e('SyncService', '经期同步失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }
}

/// 同步结果
class SyncResult {
  final int uploaded;
  final int failed;
  final List<String> errors;
  final String? error;
  final bool skipped;

  const SyncResult({
    this.uploaded = 0,
    this.failed = 0,
    this.errors = const [],
    this.error,
    this.skipped = false,
  });

  bool get isSuccess => error == null && !skipped;
  String get summary {
    if (skipped) return '同步被跳过';
    if (error != null) return '同步失败: $error';
    return '同步完成: 上传 $uploaded 条${failed > 0 ? ", 失败 $failed 项" : ""}';
  }
}

/// 单表同步结果（内部使用）
class _TableSyncResult {
  final int uploaded;
  final int failed;
  final String? error;

  const _TableSyncResult({
    this.uploaded = 0,
    this.failed = 0,
    this.error,
  });
}
