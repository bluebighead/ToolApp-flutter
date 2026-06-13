// 数据同步服务：将本地数据上传到自建服务器
// 替代 Supabase SDK，使用 HTTP + JWT 调用自建轻量服务器接口
// 登录后自动同步各模块的历史数据
// 采用"全量覆盖"策略：每次同步将本地所有数据上传，覆盖服务端数据
// 适用于小范围使用场景，简单可靠
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/convert_history.dart';
import '../utils/dice_history.dart';
import '../utils/heart_rate_history.dart';
import '../utils/network_speed_history.dart';
import '../utils/period_model.dart';
import '../utils/ffmpeg_service.dart' show VideoFormat, VideoQuality;
import 'auth_service.dart';

class SyncService {
  // 全局单例
  static final SyncService instance = SyncService._();
  SyncService._();

  // 是否正在同步中
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  // 自动同步定时器
  Timer? _autoSyncTimer;

  // 上次自动同步时间
  DateTime? _lastAutoSyncTime;
  DateTime? get lastAutoSyncTime => _lastAutoSyncTime;

  // 服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  // 构建认证请求头
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };

  // 启动/重启自动同步定时器
  // intervalMinutes: 同步间隔（分钟），0 表示关闭自动同步
  void startAutoSync([int? intervalMinutes]) {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;

    final minutes = intervalMinutes ?? appSettings.autoSyncInterval;
    if (minutes <= 0) {
      AppLogger.i('SyncService', '自动同步已关闭');
      return;
    }

    AppLogger.i('SyncService', '启动自动同步，间隔: $minutes 分钟');
    _autoSyncTimer = Timer.periodic(Duration(minutes: minutes), (_) async {
      if (!AuthService.instance.isLoggedIn || _isSyncing) return;
      AppLogger.i('SyncService', '自动同步触发');
      final result = await syncAll();
      _lastAutoSyncTime = DateTime.now();
      if (result.isSuccess) {
        AppLogger.i('SyncService', '自动同步成功: ${result.summary}');
      } else {
        AppLogger.w('SyncService', '自动同步失败: ${result.summary}');
      }
    });
  }

  // 停止自动同步定时器
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    AppLogger.i('SyncService', '自动同步已停止');
  }

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
      if (hrResult.error != null) {
        errors.add('心率: ${hrResult.error}');
        AppLogger.e('SyncService', '心率同步错误: ${hrResult.error}');
      }

      // 2. 同步网速历史
      final nsResult = await _syncNetworkSpeed();
      uploaded += nsResult.uploaded;
      failed += nsResult.failed;
      if (nsResult.error != null) {
        errors.add('网速: ${nsResult.error}');
        AppLogger.e('SyncService', '网速同步错误: ${nsResult.error}');
      }

      // 3. 同步转换历史
      final cvResult = await _syncConvertHistory();
      uploaded += cvResult.uploaded;
      failed += cvResult.failed;
      if (cvResult.error != null) {
        errors.add('转换: ${cvResult.error}');
        AppLogger.e('SyncService', '转换同步错误: ${cvResult.error}');
      }

      // 4. 同步骰子历史
      final dcResult = await _syncDiceHistory();
      uploaded += dcResult.uploaded;
      failed += dcResult.failed;
      if (dcResult.error != null) {
        errors.add('骰子: ${dcResult.error}');
        AppLogger.e('SyncService', '骰子同步错误: ${dcResult.error}');
      }

      // 5. 同步经期记录
      final pdResult = await _syncPeriodRecords();
      uploaded += pdResult.uploaded;
      failed += pdResult.failed;
      if (pdResult.error != null) {
        errors.add('经期: ${pdResult.error}');
        AppLogger.e('SyncService', '经期同步错误: ${pdResult.error}');
      }

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

  /// 从服务器下载所有数据并合并到本地
  /// 登录后调用，将服务器上的数据拉取到本地
  Future<SyncResult> downloadAll() async {
    if (!AuthService.instance.isLoggedIn) {
      AppLogger.w('SyncService', '未登录，无法下载数据');
      return SyncResult(error: '未登录');
    }

    _isSyncing = true;
    int downloaded = 0;
    int failed = 0;
    final errors = <String>[];

    try {
      AppLogger.i('SyncService', '开始从服务器下载数据...');

      // 1. 下载心率历史
      final hrResult = await _downloadHeartRate();
      downloaded += hrResult.uploaded;
      failed += hrResult.failed;
      if (hrResult.error != null) errors.add('心率: ${hrResult.error}');

      // 2. 下载网速历史
      final nsResult = await _downloadNetworkSpeed();
      downloaded += nsResult.uploaded;
      failed += nsResult.failed;
      if (nsResult.error != null) errors.add('网速: ${nsResult.error}');

      // 3. 下载转换历史
      final cvResult = await _downloadConvertHistory();
      downloaded += cvResult.uploaded;
      failed += cvResult.failed;
      if (cvResult.error != null) errors.add('转换: ${cvResult.error}');

      // 4. 下载骰子历史
      final dcResult = await _downloadDiceHistory();
      downloaded += dcResult.uploaded;
      failed += dcResult.failed;
      if (dcResult.error != null) errors.add('骰子: ${dcResult.error}');

      // 5. 下载经期记录
      final pdResult = await _downloadPeriodRecords();
      downloaded += pdResult.uploaded;
      failed += pdResult.failed;
      if (pdResult.error != null) errors.add('经期: ${pdResult.error}');

      AppLogger.i('SyncService', '下载完成 - 新增: $downloaded, 失败: $failed');
      return SyncResult(
        uploaded: downloaded,
        failed: failed,
        errors: errors,
      );
    } catch (e) {
      AppLogger.e('SyncService', '下载异常: $e');
      return SyncResult(error: e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  // 通用下载方法：从服务器获取指定表的数据
  Future<List<Map<String, dynamic>>> _downloadTable(String table) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/sync/$table'),
        headers: _authHeaders,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['rows'] as List<dynamic>?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
      AppLogger.e('SyncService', '下载 $table 失败: HTTP ${response.statusCode}');
      return [];
    } catch (e) {
      AppLogger.e('SyncService', '下载 $table 异常: $e');
      return [];
    }
  }

  // ============================================================
  // 心率历史下载
  // ============================================================
  Future<_TableSyncResult> _downloadHeartRate() async {
    try {
      final rows = await _downloadTable('heart_rate_sessions');
      if (rows.isEmpty) return _TableSyncResult(uploaded: 0);
      final records = rows.map((r) => HeartRateRecord(
        id: (r['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        startTimeMs: _parseTimeToMs(r['start_time']),
        endTimeMs: _parseTimeToMs(r['end_time']),
        maxBpm: (r['max_hr'] as num?)?.toInt() ?? 0,
        minBpm: (r['min_hr'] as num?)?.toInt() ?? 0,
        avgBpm: (r['avg_hr'] as num?)?.toInt() ?? 0,
        samples: (r['samples'] as num?)?.toInt() ?? 0,
        connectionMode: _parseHeartRateMode(r['connection_mode'] as String?),
      )).toList();
      final merged = await HeartRateHistory.mergeFromServer(records);
      return _TableSyncResult(uploaded: merged);
    } catch (e) {
      AppLogger.e('SyncService', '心率下载失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 网速历史下载
  // ============================================================
  Future<_TableSyncResult> _downloadNetworkSpeed() async {
    try {
      final rows = await _downloadTable('network_speed_records');
      if (rows.isEmpty) return _TableSyncResult(uploaded: 0);
      final records = rows.map((r) => PingRecord(
        timestamp: DateTime.tryParse(r['test_time'] as String? ?? '') ?? DateTime.now(),
        server: r['server_url'] as String? ?? '',
        samples: const [],
        min: (r['min_latency'] as num?)?.toInt() ?? 0,
        avg: (r['avg_latency'] as num?)?.toInt() ?? 0,
        max: (r['max_latency'] as num?)?.toInt() ?? 0,
        jitter: (r['jitter'] as num?)?.toInt() ?? 0,
        lossRate: (r['loss_rate'] as num?)?.toDouble() ?? 0,
      )).toList();
      final merged = await NetworkSpeedHistory.mergeFromServer(records);
      return _TableSyncResult(uploaded: merged);
    } catch (e) {
      AppLogger.e('SyncService', '网速下载失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 转换历史下载
  // ============================================================
  Future<_TableSyncResult> _downloadConvertHistory() async {
    try {
      final rows = await _downloadTable('convert_history');
      if (rows.isEmpty) return _TableSyncResult(uploaded: 0);
      final records = rows.map((r) => ConvertHistoryEntry(
        id: (r['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        timestampMs: (r['timestamp_ms'] as num?)?.toInt() ?? 0,
        input: r['input_file'] as String? ?? '',
        isNetwork: false,
        outputPath: r['output_file'] as String?,
        outputSize: (r['output_size'] as num?)?.toInt(),
        format: _parseConvertFormat(r['format'] as String?),
        quality: _parseConvertQuality(r['quality'] as String?),
        status: _parseConvertStatus(r['status'] as String?),
      )).toList();
      final merged = await ConvertHistory.mergeFromServer(records);
      return _TableSyncResult(uploaded: merged);
    } catch (e) {
      AppLogger.e('SyncService', '转换历史下载失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 骰子历史下载
  // ============================================================
  Future<_TableSyncResult> _downloadDiceHistory() async {
    try {
      final rows = await _downloadTable('dice_records');
      if (rows.isEmpty) return _TableSyncResult(uploaded: 0);
      final records = rows.map((r) => DiceRecord(
        id: (r['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        diceType: DiceType.fromName(r['dice_type'] as String? ?? 'd6'),
        result: (r['result'] as num?)?.toInt() ?? 1,
        timestamp: (r['timestamp_ms'] as num?)?.toInt() ?? 0,
      )).toList();
      final merged = await DiceHistory.mergeFromServer(records);
      return _TableSyncResult(uploaded: merged);
    } catch (e) {
      AppLogger.e('SyncService', '骰子下载失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 经期记录下载
  // ============================================================
  Future<_TableSyncResult> _downloadPeriodRecords() async {
    try {
      final rows = await _downloadTable('period_records');
      if (rows.isEmpty) return _TableSyncResult(uploaded: 0);
      final records = rows.map((r) {
        // symptoms 字段：服务器存的是逗号分隔字符串，需要转为 List<String>
        final symptomsRaw = r['symptoms'];
        List<String> symptoms = [];
        if (symptomsRaw is String && symptomsRaw.isNotEmpty) {
          symptoms = symptomsRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        } else if (symptomsRaw is List) {
          symptoms = symptomsRaw.map((s) => s.toString()).toList();
        }
        return PeriodRecord(
          id: r['local_id'] as String? ?? '',
          startDate: DateTime.tryParse(r['start_date'] as String? ?? '') ?? DateTime.now(),
          endDate: r['end_date'] != null ? DateTime.tryParse(r['end_date'] as String) : null,
          mode: r['record_mode'] as String? ?? 'period',
          flowLevel: (r['flow_level'] as num?)?.toInt() ?? 2,
          symptoms: symptoms,
          notes: r['notes'] as String? ?? '',
        );
      }).toList();
      final merged = await PeriodStorage.mergeRecordsFromServer(records);
      return _TableSyncResult(uploaded: merged);
    } catch (e) {
      AppLogger.e('SyncService', '经期下载失败: $e');
      return _TableSyncResult(failed: 1, error: e.toString());
    }
  }

  // ============================================================
  // 辅助解析方法
  // ============================================================

  // 将 ISO8601 时间字符串转为毫秒时间戳
  static int _parseTimeToMs(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    if (value is String) {
      final dt = DateTime.tryParse(value);
      return dt?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  // 解析心率连接方式
  static HeartRateConnectionMode _parseHeartRateMode(String? s) {
    switch (s) {
      case 'ble': return HeartRateConnectionMode.ble;
      case 'udp': return HeartRateConnectionMode.udp;
      default: return HeartRateConnectionMode.ble;
    }
  }

  // 解析转换格式
  static VideoFormat _parseConvertFormat(String? s) {
    switch (s) {
      case 'mp4': return VideoFormat.mp4;
      case 'mkv': return VideoFormat.mkv;
      case 'mov': return VideoFormat.mov;
      default: return VideoFormat.mp4;
    }
  }

  // 解析转换质量
  static VideoQuality _parseConvertQuality(String? s) {
    switch (s) {
      case 'original': return VideoQuality.original;
      case 'high': return VideoQuality.high;
      case 'standard': return VideoQuality.standard;
      case 'low': return VideoQuality.low;
      default: return VideoQuality.standard;
    }
  }

  // 解析转换状态
  static ConvertStatus _parseConvertStatus(String? s) {
    switch (s) {
      case 'success': return ConvertStatus.success;
      case 'failed': return ConvertStatus.failed;
      case 'cancelled': return ConvertStatus.cancelled;
      default: return ConvertStatus.success;
    }
  }

  // 通用上传方法：将数据行上传到指定表
  Future<_TableSyncResult> _uploadTable(String table, List<Map<String, dynamic>> rows) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/sync/$table'),
        headers: _authHeaders,
        body: jsonEncode({'rows': rows}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return _TableSyncResult(uploaded: data['uploaded'] as int? ?? 0);
      }

      // 解析错误信息
      String errorMsg;
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        errorMsg = data['error'] as String? ?? 'HTTP ${response.statusCode}';
      } catch (_) {
        errorMsg = 'HTTP ${response.statusCode}: ${response.body.substring(0, (response.body.length > 200 ? 200 : response.body.length))}';
      }
      AppLogger.e('SyncService', '$table 同步失败: $errorMsg');
      return _TableSyncResult(failed: 1, error: errorMsg);
    } catch (e) {
      AppLogger.e('SyncService', '$table 同步异常: $e');
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

  bool get isSuccess => error == null && !skipped && failed == 0;
  String get summary {
    if (skipped) return '同步被跳过';
    if (error != null) return '同步失败: $error';
    if (uploaded == 0 && failed == 0) return '同步完成: 暂无新数据需要上传';
    if (failed > 0) return '同步完成: 上传 $uploaded 条, 失败 $failed 项\n${errors.join("; ")}';
    return '同步完成: 上传 $uploaded 条';
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
