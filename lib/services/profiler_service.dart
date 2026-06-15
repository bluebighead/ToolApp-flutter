// Android Profiler 数据采集服务
// 通过 MethodChannel 与原生 ProfilerHelper 通信，定时轮询采集 CPU/内存/网络/电量数据
// v1.54.0+ 新增
import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

// ==================== 数据模型 ====================

/// CPU 采样数据
class CpuSample {
  /// 总 CPU 使用率 0-100%
  final double totalUsage;
  /// 每核使用率
  final List<double> coreUsages;
  /// 每核频率 MHz
  final List<int> coreFreqs;
  /// CPU 温度 ℃
  final double temperature;
  /// 本 App CPU 使用率
  final double appCpuUsage;
  /// 采样时间
  final DateTime timestamp;

  CpuSample({
    required this.totalUsage,
    required this.coreUsages,
    required this.coreFreqs,
    required this.temperature,
    required this.appCpuUsage,
    required this.timestamp,
  });
}

/// 内存采样数据
class MemorySample {
  /// 总内存 MB
  final int totalMb;
  /// 可用内存 MB
  final int availableMb;
  /// 已用内存 MB
  final int usedMb;
  /// 本 App 占用 MB
  final int appUsedMb;
  /// 内存压力等级 low/medium/high
  final String pressureLevel;
  /// 采样时间
  final DateTime timestamp;

  MemorySample({
    required this.totalMb,
    required this.availableMb,
    required this.usedMb,
    required this.appUsedMb,
    required this.pressureLevel,
    required this.timestamp,
  });
}

/// 网络采样数据
class NetworkSample {
  /// 下行速率 Kbps
  final double downloadSpeedKbps;
  /// 上行速率 Kbps
  final double uploadSpeedKbps;
  /// 累计下载 KB
  final int totalDownloadKb;
  /// 累计上传 KB
  final int totalUploadKb;
  /// 网络类型 WiFi/Mobile/None
  final String networkType;
  /// 采样时间
  final DateTime timestamp;

  NetworkSample({
    required this.downloadSpeedKbps,
    required this.uploadSpeedKbps,
    required this.totalDownloadKb,
    required this.totalUploadKb,
    required this.networkType,
    required this.timestamp,
  });
}

/// 电量采样数据
class BatterySample {
  /// 电量 0-100
  final int level;
  /// 是否充电
  final bool isCharging;
  /// 充电类型 AC/USB/Wireless/None
  final String chargeType;
  /// 电池温度 ℃
  final double temperature;
  /// 电压 mV
  final int voltage;
  /// 电流 mA（负值=放电）
  final int currentMa;
  /// 耗电速率 %/h
  final double drainRate;
  /// 采样时间
  final DateTime timestamp;

  BatterySample({
    required this.level,
    required this.isCharging,
    required this.chargeType,
    required this.temperature,
    required this.voltage,
    required this.currentMa,
    required this.drainRate,
    required this.timestamp,
  });
}

/// 进程排行条目
class ProcessInfo {
  /// 包名
  final String packageName;
  /// 应用名
  final String appName;
  /// CPU 占用 %
  final double cpuUsage;
  /// 内存占用 MB
  final int memoryMb;
  /// 前台时间秒
  final int foregroundTime;

  ProcessInfo({
    required this.packageName,
    required this.appName,
    required this.cpuUsage,
    required this.memoryMb,
    required this.foregroundTime,
  });
}

/// 耗电分析报告
class BatteryReport {
  /// 平均耗电速率 %/h
  final double avgDrainRate;
  /// 峰值耗电速率 %/h
  final double peakDrainRate;
  /// 耗电排行
  final List<ProcessInfo> topConsumers;
  /// 省电建议
  final List<String> suggestions;
  /// 监控时长
  final Duration monitoringDuration;
  /// CPU 平均使用率
  final double avgCpuUsage;
  /// 内存平均使用率
  final double avgMemoryUsage;
  /// 累计下载 KB
  final int totalDownloadKb;
  /// 累计上传 KB
  final int totalUploadKb;

  BatteryReport({
    required this.avgDrainRate,
    required this.peakDrainRate,
    required this.topConsumers,
    required this.suggestions,
    required this.monitoringDuration,
    required this.avgCpuUsage,
    required this.avgMemoryUsage,
    required this.totalDownloadKb,
    required this.totalUploadKb,
  });

  /// 转换为纯文本报告（用于复制到剪贴板）
  String toPlainText() {
    final buf = StringBuffer();
    buf.writeln('=== Android Profiler 耗电分析报告 ===');
    buf.writeln('监控时长: ${_formatDuration(monitoringDuration)}');
    buf.writeln();
    buf.writeln('--- 关键指标 ---');
    buf.writeln('平均耗电速率: ${avgDrainRate.toStringAsFixed(1)} %/h');
    buf.writeln('峰值耗电速率: ${peakDrainRate.toStringAsFixed(1)} %/h');
    buf.writeln('平均 CPU 使用率: ${avgCpuUsage.toStringAsFixed(1)} %');
    buf.writeln('平均内存使用率: ${avgMemoryUsage.toStringAsFixed(1)} %');
    buf.writeln('累计下载: ${_formatKb(totalDownloadKb)}');
    buf.writeln('累计上传: ${_formatKb(totalUploadKb)}');
    buf.writeln();
    if (topConsumers.isNotEmpty) {
      buf.writeln('--- 耗电排行 Top ${topConsumers.length} ---');
      for (var i = 0; i < topConsumers.length; i++) {
        final p = topConsumers[i];
        buf.writeln('${i + 1}. ${p.appName} (${p.packageName}) - 前台 ${p.foregroundTime}s');
      }
      buf.writeln();
    }
    if (suggestions.isNotEmpty) {
      buf.writeln('--- 省电建议 ---');
      for (final s in suggestions) {
        buf.writeln('• $s');
      }
    }
    return buf.toString();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h小时${m}分${s}秒';
    if (m > 0) return '$m分${s}秒';
    return '$s秒';
  }

  String _formatKb(int kb) {
    if (kb < 1024) return '$kb KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }
}

// ==================== 采集服务 ====================

/// Android Profiler 数据采集服务
/// 通过 MethodChannel 与原生 ProfilerHelper 通信，定时轮询采集数据
class ProfilerService {
  // 单例
  static final ProfilerService instance = ProfilerService._();
  ProfilerService._();

  // MethodChannel 通道
  static const _channel = MethodChannel('com.example.toolapp/profiler');

  // 轮询定时器
  Timer? _pollTimer;

  // 轮询间隔
  static const _pollInterval = Duration(seconds: 2);

  // 是否正在监控
  bool _isMonitoring = false;
  bool get isMonitoring => _isMonitoring;

  // 监控开始时间
  DateTime? _monitorStartTime;

  // ==================== 实时数据（最新采样） ====================

  CpuSample? _latestCpu;
  MemorySample? _latestMemory;
  NetworkSample? _latestNetwork;
  BatterySample? _latestBattery;
  List<ProcessInfo> _processList = [];
  List<ProcessInfo> _batteryUsageList = [];

  CpuSample? get latestCpu => _latestCpu;
  MemorySample? get latestMemory => _latestMemory;
  NetworkSample? get latestNetwork => _latestNetwork;
  BatterySample? get latestBattery => _latestBattery;
  List<ProcessInfo> get processList => _processList;
  List<ProcessInfo> get batteryUsageList => _batteryUsageList;

  // ==================== 历史数据（用于绘制曲线） ====================

  // 保留最近 60s 的采样数据（2s 间隔 = 最多 30 条）
  static const _maxHistoryLength = 30;

  final List<CpuSample> _cpuHistory = [];
  final List<MemorySample> _memoryHistory = [];
  final List<NetworkSample> _networkHistory = [];
  final List<BatterySample> _batteryHistory = [];

  List<CpuSample> get cpuHistory => List.unmodifiable(_cpuHistory);
  List<MemorySample> get memoryHistory => List.unmodifiable(_memoryHistory);
  List<NetworkSample> get networkHistory => List.unmodifiable(_networkHistory);
  List<BatterySample> get batteryHistory => List.unmodifiable(_batteryHistory);

  // ==================== 变更通知 ====================

  // 数据更新回调
  final List<VoidCallback> _listeners = [];

  /// 添加数据更新监听
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// 移除数据更新监听
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  // ==================== 权限相关 ====================

  /// 检查是否有 USAGE_STATS 权限
  Future<bool> isUsageStatsGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isUsageStatsGranted') ?? false;
    } on PlatformException catch (e) {
      AppLogger.e('ProfilerService', '检查权限失败: ${e.message}');
      return false;
    }
  }

  /// 打开 USAGE_STATS 权限设置页
  Future<void> openUsageStatsSettings() async {
    try {
      await _channel.invokeMethod<bool>('openUsageStatsSettings');
    } on PlatformException catch (e) {
      AppLogger.e('ProfilerService', '打开设置失败: ${e.message}');
    }
  }

  // ==================== 监控控制 ====================

  /// 开始监控
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;
    _monitorStartTime = DateTime.now();
    _cpuHistory.clear();
    _memoryHistory.clear();
    _networkHistory.clear();
    _batteryHistory.clear();
    AppLogger.i('ProfilerService', '开始监控');
    _pollData();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollData());
  }

  /// 停止监控
  void stopMonitoring() {
    if (!_isMonitoring) return;
    _isMonitoring = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    AppLogger.i('ProfilerService', '停止监控');
    _notifyListeners();
  }

  /// 采集一次数据
  Future<void> _pollData() async {
    try {
      final results = await Future.wait([
        _channel.invokeMethod<Map>('getCpuInfo'),
        _channel.invokeMethod<Map>('getMemoryInfo'),
        _channel.invokeMethod<Map>('getNetworkInfo'),
        _channel.invokeMethod<Map>('getBatteryInfo'),
      ]);

      final cpuMap = results[0] as Map?;
      final memMap = results[1] as Map?;
      final netMap = results[2] as Map?;
      final batMap = results[3] as Map?;

      final now = DateTime.now();

      // 解析 CPU 数据
      if (cpuMap != null) {
        _latestCpu = CpuSample(
          totalUsage: (cpuMap['totalUsage'] as num?)?.toDouble() ?? 0,
          coreUsages: [],
          coreFreqs: (cpuMap['coreFreqs'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [],
          temperature: (cpuMap['temperature'] as num?)?.toDouble() ?? 0,
          appCpuUsage: (cpuMap['appCpuUsage'] as num?)?.toDouble() ?? 0,
          timestamp: now,
        );
        _cpuHistory.add(_latestCpu!);
        if (_cpuHistory.length > _maxHistoryLength) _cpuHistory.removeAt(0);
      }

      // 解析内存数据
      if (memMap != null) {
        _latestMemory = MemorySample(
          totalMb: (memMap['totalMb'] as num?)?.toInt() ?? 0,
          availableMb: (memMap['availableMb'] as num?)?.toInt() ?? 0,
          usedMb: (memMap['usedMb'] as num?)?.toInt() ?? 0,
          appUsedMb: (memMap['appUsedMb'] as num?)?.toInt() ?? 0,
          pressureLevel: (memMap['pressureLevel'] as String?) ?? 'low',
          timestamp: now,
        );
        _memoryHistory.add(_latestMemory!);
        if (_memoryHistory.length > _maxHistoryLength) _memoryHistory.removeAt(0);
      }

      // 解析网络数据
      if (netMap != null) {
        _latestNetwork = NetworkSample(
          downloadSpeedKbps: (netMap['downloadSpeedKbps'] as num?)?.toDouble() ?? 0,
          uploadSpeedKbps: (netMap['uploadSpeedKbps'] as num?)?.toDouble() ?? 0,
          totalDownloadKb: (netMap['totalDownloadKb'] as num?)?.toInt() ?? 0,
          totalUploadKb: (netMap['totalUploadKb'] as num?)?.toInt() ?? 0,
          networkType: (netMap['networkType'] as String?) ?? 'None',
          timestamp: now,
        );
        _networkHistory.add(_latestNetwork!);
        if (_networkHistory.length > _maxHistoryLength) _networkHistory.removeAt(0);
      }

      // 解析电量数据
      if (batMap != null) {
        final level = (batMap['level'] as num?)?.toInt() ?? 0;
        final isCharging = (batMap['isCharging'] as bool?) ?? false;
        // 计算耗电速率
        double drainRate = 0;
        if (_batteryHistory.isNotEmpty && !isCharging) {
          final prev = _batteryHistory.last;
          final elapsed = now.difference(prev.timestamp).inSeconds;
          if (elapsed > 0) {
            final diff = prev.level - level;
            drainRate = (diff / elapsed * 3600).abs();
          }
        }
        _latestBattery = BatterySample(
          level: level,
          isCharging: isCharging,
          chargeType: (batMap['chargeType'] as String?) ?? 'None',
          temperature: (batMap['temperature'] as num?)?.toDouble() ?? 0,
          voltage: (batMap['voltage'] as num?)?.toInt() ?? 0,
          currentMa: (batMap['currentMa'] as num?)?.toInt() ?? 0,
          drainRate: drainRate,
          timestamp: now,
        );
        _batteryHistory.add(_latestBattery!);
        if (_batteryHistory.length > _maxHistoryLength) _batteryHistory.removeAt(0);
      }

      // 异步获取进程排行（降低频率，每 5 次轮询刷新一次）
      if (_cpuHistory.length % 5 == 1) {
        _fetchProcessList();
        _fetchBatteryUsage();
      }

      _notifyListeners();
    } catch (e) {
      AppLogger.e('ProfilerService', '采集数据失败: $e');
    }
  }

  /// 获取进程排行
  Future<void> _fetchProcessList() async {
    try {
      final list = await _channel.invokeMethod<List>('getProcessList');
      if (list != null) {
        _processList = list.map((e) {
          final m = e as Map;
          return ProcessInfo(
            packageName: (m['packageName'] as String?) ?? '',
            appName: (m['appName'] as String?) ?? '',
            cpuUsage: (m['cpuUsage'] as num?)?.toDouble() ?? 0,
            memoryMb: (m['memoryMb'] as num?)?.toInt() ?? -1,
            foregroundTime: (m['foregroundTime'] as num?)?.toInt() ?? 0,
          );
        }).toList();
      }
    } on PlatformException {
      _processList = [];
    }
  }

  /// 获取 App 耗电排行
  Future<void> _fetchBatteryUsage() async {
    try {
      final list = await _channel.invokeMethod<List>('getAppBatteryUsage');
      if (list != null) {
        _batteryUsageList = list.map((e) {
          final m = e as Map;
          return ProcessInfo(
            packageName: (m['packageName'] as String?) ?? '',
            appName: (m['appName'] as String?) ?? '',
            cpuUsage: 0,
            memoryMb: 0,
            foregroundTime: (m['foregroundTime'] as num?)?.toInt() ?? 0,
          );
        }).toList();
      }
    } on PlatformException {
      _batteryUsageList = [];
    }
  }

  // ==================== 报告生成 ====================

  /// 生成耗电分析报告
  BatteryReport generateReport() {
    // 平均耗电速率
    double avgDrain = 0;
    double peakDrain = 0;
    final drainRates = _batteryHistory
        .where((s) => s.drainRate > 0)
        .map((s) => s.drainRate)
        .toList();
    if (drainRates.isNotEmpty) {
      avgDrain = drainRates.reduce((a, b) => a + b) / drainRates.length;
      peakDrain = drainRates.reduce((a, b) => a > b ? a : b);
    }

    // 平均 CPU 使用率
    double avgCpu = 0;
    if (_cpuHistory.isNotEmpty) {
      avgCpu = _cpuHistory.map((s) => s.totalUsage).reduce((a, b) => a + b) / _cpuHistory.length;
    }

    // 平均内存使用率
    double avgMem = 0;
    if (_memoryHistory.isNotEmpty) {
      avgMem = _memoryHistory.map((s) => s.usedMb / s.totalMb * 100).reduce((a, b) => a + b) / _memoryHistory.length;
    }

    // 累计流量
    int totalDown = 0;
    int totalUp = 0;
    if (_networkHistory.isNotEmpty) {
      totalDown = _networkHistory.last.totalDownloadKb;
      totalUp = _networkHistory.last.totalUploadKb;
    }

    // 监控时长
    final duration = _monitorStartTime != null
        ? DateTime.now().difference(_monitorStartTime!)
        : Duration.zero;

    // 生成省电建议
    final suggestions = _generateSuggestions(avgDrain, avgCpu, avgMem);

    return BatteryReport(
      avgDrainRate: avgDrain,
      peakDrainRate: peakDrain,
      topConsumers: _batteryUsageList.take(5).toList(),
      suggestions: suggestions,
      monitoringDuration: duration,
      avgCpuUsage: avgCpu,
      avgMemoryUsage: avgMem,
      totalDownloadKb: totalDown,
      totalUploadKb: totalUp,
    );
  }

  /// 根据监控数据生成省电建议
  List<String> _generateSuggestions(double avgDrain, double avgCpu, double avgMem) {
    final suggestions = <String>[];

    // 耗电速率过高
    if (avgDrain > 10) {
      suggestions.add('当前耗电较快（${avgDrain.toStringAsFixed(1)}%/h），建议关闭后台高耗电应用');
    }

    // CPU 持续高负载
    final highCpuCount = _cpuHistory.where((s) => s.totalUsage > 80).length;
    if (highCpuCount > _cpuHistory.length * 0.3) {
      suggestions.add('CPU 持续高负载，检查是否有异常进程');
    }

    // 设备温度偏高
    final highTempCount = _batteryHistory.where((s) => s.temperature > 40).length;
    if (highTempCount > 0) {
      suggestions.add('设备温度偏高（>40℃），建议暂停高负载操作');
    }

    // 移动网络大流量
    final mobileHighSpeed = _networkHistory
        .where((s) => s.networkType == 'Mobile' && s.downloadSpeedKbps > 1000)
        .length;
    if (mobileHighSpeed > _networkHistory.length * 0.3) {
      suggestions.add('移动网络持续大数据传输，建议切换 WiFi');
    }

    // 内存压力大
    final highPressure = _memoryHistory.where((s) => s.pressureLevel == 'high').length;
    if (highPressure > 0) {
      suggestions.add('内存压力大，建议关闭不必要的应用');
    }

    // 无建议时给默认提示
    if (suggestions.isEmpty) {
      suggestions.add('设备运行状态良好，暂无省电建议');
    }

    return suggestions;
  }

  /// 释放资源
  void dispose() {
    stopMonitoring();
    _listeners.clear();
  }
}
