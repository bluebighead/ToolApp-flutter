// Android Profiler 主页面
// 实时监控 CPU/内存/网络/电量，生成 Battery Historian 风格耗电分析报告
// v1.54.0+ 新增
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/profiler_service.dart';
import '../../widgets/profiler_cpu_chart.dart';
import '../../widgets/profiler_memory_chart.dart';
import '../../widgets/profiler_network_chart.dart';
import '../../widgets/profiler_battery_chart.dart';

class ProfilerPage extends StatefulWidget {
  const ProfilerPage({super.key});

  @override
  State<ProfilerPage> createState() => _ProfilerPageState();
}

class _ProfilerPageState extends State<ProfilerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final ProfilerService _service = ProfilerService.instance;

  // USAGE_STATS 权限状态
  bool _hasUsageStatsPermission = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _service.addListener(_onDataUpdate);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_onDataUpdate);
    _service.stopMonitoring();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台时暂停监控，前台时恢复
    if (state == AppLifecycleState.paused) {
      _service.stopMonitoring();
    } else if (state == AppLifecycleState.resumed && _service.isMonitoring) {
      _service.startMonitoring();
    }
  }

  // 数据更新回调
  void _onDataUpdate() {
    if (mounted) setState(() {});
  }

  // 检查权限
  Future<void> _checkPermission() async {
    final granted = await _service.isUsageStatsGranted();
    if (mounted) {
      setState(() => _hasUsageStatsPermission = granted);
    }
  }

  // 请求权限（跳转系统设置）
  Future<void> _requestPermission() async {
    await _service.openUsageStatsSettings();
    // 延迟检查权限（用户从设置返回后）
    await Future.delayed(const Duration(seconds: 1));
    _checkPermission();
  }

  // 切换监控状态
  void _toggleMonitoring() {
    if (_service.isMonitoring) {
      _service.stopMonitoring();
    } else {
      _service.startMonitoring();
    }
  }

  // 生成报告
  void _generateReport() {
    if (_service.batteryHistory.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('数据不足，请至少监控 6 秒后再生成报告')),
      );
      return;
    }

    final report = _service.generateReport();
    _showReportDialog(report);
  }

  // 显示报告对话框
  void _showReportDialog(BatteryReport report) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('耗电分析报告'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 监控时长
              _buildReportRow('监控时长', _formatDuration(report.monitoringDuration)),
              const Divider(height: 16),

              // 关键指标
              _buildReportRow('平均耗电速率', '${report.avgDrainRate.toStringAsFixed(1)} %/h'),
              _buildReportRow('峰值耗电速率', '${report.peakDrainRate.toStringAsFixed(1)} %/h'),
              _buildReportRow('平均 CPU 使用率', '${report.avgCpuUsage.toStringAsFixed(1)} %'),
              _buildReportRow('平均内存使用率', '${report.avgMemoryUsage.toStringAsFixed(1)} %'),
              _buildReportRow('累计下载', _formatKb(report.totalDownloadKb)),
              _buildReportRow('累计上传', _formatKb(report.totalUploadKb)),
              const Divider(height: 16),

              // 耗电排行
              if (report.topConsumers.isNotEmpty) ...[
                const Text('耗电排行', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (var i = 0; i < report.topConsumers.length; i++)
                  Text('${i + 1}. ${report.topConsumers[i].appName} - 前台 ${report.topConsumers[i].foregroundTime}s'),
                const Divider(height: 16),
              ],

              // 省电建议
              const Text('省电建议', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final s in report.suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('• $s'),
                ),
            ],
          ),
        ),
        actions: [
          // 复制报告
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report.toPlainText()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('报告已复制到剪贴板')),
              );
              Navigator.pop(ctx);
            },
            child: const Text('复制报告'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildReportRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '$m分${s}秒';
  }

  String _formatKb(int kb) {
    if (kb < 1024) return '$kb KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double kbps) {
    if (kbps < 1000) return '${kbps.toStringAsFixed(0)} Kbps';
    return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Android Profiler'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.memory), text: 'CPU'),
            Tab(icon: Icon(Icons.storage), text: '内存'),
            Tab(icon: Icon(Icons.wifi), text: '网络'),
            Tab(icon: Icon(Icons.battery_std), text: '电量'),
          ],
        ),
      ),
      body: Column(
        children: [
          // 权限引导卡片
          if (!_hasUsageStatsPermission) _buildPermissionCard(),

          // Tab 内容
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCpuTab(),
                _buildMemoryTab(),
                _buildNetworkTab(),
                _buildBatteryTab(),
              ],
            ),
          ),

          // 底部操作栏
          _buildBottomBar(),
        ],
      ),
    );
  }

  // ==================== 权限引导卡片 ====================

  Widget _buildPermissionCard() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.orange),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '需要"使用情况访问"权限才能查看进程排行和耗电排行',
              style: TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: _requestPermission,
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  // ==================== CPU Tab ====================

  Widget _buildCpuTab() {
    final cpu = _service.latestCpu;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 概览面板
          _buildOverviewPanel(
            children: [
              _buildBigValue('${cpu?.totalUsage.toStringAsFixed(1) ?? '--'}%', 'CPU 使用率', Colors.blue),
              _buildBigValue('${cpu?.temperature.toStringAsFixed(0) ?? '--'}℃', '温度',
                  cpu != null && cpu.temperature > 40 ? Colors.red : Colors.blue),
              _buildBigValue('${cpu?.coreFreqs.length ?? '--'}', '核心数', Colors.blue),
            ],
          ),
          const SizedBox(height: 12),

          // 实时曲线
          const Text('实时趋势', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ProfilerCpuChart(samples: _service.cpuHistory),
          const SizedBox(height: 12),

          // 进程排行
          const Text('进程 CPU 排行', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _buildProcessList(_service.processList, (p) => '${p.cpuUsage.toStringAsFixed(1)}%'),
        ],
      ),
    );
  }

  // ==================== 内存 Tab ====================

  Widget _buildMemoryTab() {
    final mem = _service.latestMemory;
    final usedPercent = mem != null && mem.totalMb > 0
        ? (mem.usedMb / mem.totalMb * 100).toStringAsFixed(1)
        : '--';
    final pressureColor = mem?.pressureLevel == 'high'
        ? Colors.red
        : mem?.pressureLevel == 'medium'
            ? Colors.orange
            : Colors.green;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 概览面板
          _buildOverviewPanel(
            children: [
              _buildBigValue('$usedPercent%', '内存使用率', Colors.deepPurple),
              _buildBigValue('${mem?.appUsedMb ?? '--'} MB', 'App 占用', Colors.deepPurple),
              _buildBigValue(mem?.pressureLevel ?? '--', '压力等级', pressureColor),
            ],
          ),
          const SizedBox(height: 12),

          // 实时曲线
          const Text('实时趋势', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ProfilerMemoryChart(samples: _service.memoryHistory),
          const SizedBox(height: 12),

          // 进程排行
          const Text('进程内存排行', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _buildProcessList(_service.processList, (p) => p.memoryMb >= 0 ? '${p.memoryMb} MB' : 'N/A'),
        ],
      ),
    );
  }

  // ==================== 网络 Tab ====================

  Widget _buildNetworkTab() {
    final net = _service.latestNetwork;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 概览面板
          _buildOverviewPanel(
            children: [
              _buildBigValue(_formatSpeed(net?.downloadSpeedKbps ?? 0), '下行速率', Colors.teal),
              _buildBigValue(_formatSpeed(net?.uploadSpeedKbps ?? 0), '上行速率', Colors.orange),
              _buildBigValue(net?.networkType ?? '--', '网络类型', Colors.teal),
            ],
          ),
          const SizedBox(height: 12),

          // 累计流量
          if (net != null) ...[
            Row(
              children: [
                _buildSmallStat('累计下载', _formatKb(net.totalDownloadKb)),
                const SizedBox(width: 16),
                _buildSmallStat('累计上传', _formatKb(net.totalUploadKb)),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // 实时曲线
          const Text('实时趋势', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          // 图例
          Row(
            children: [
              _buildLegend(Colors.teal, '下行'),
              const SizedBox(width: 12),
              _buildLegend(Colors.orange, '上行'),
            ],
          ),
          const SizedBox(height: 8),
          ProfilerNetworkChart(samples: _service.networkHistory),
        ],
      ),
    );
  }

  // ==================== 电量 Tab ====================

  Widget _buildBatteryTab() {
    final bat = _service.latestBattery;
    final levelColor = bat != null
        ? (bat.level > 50 ? Colors.green : bat.level > 20 ? Colors.orange : Colors.red)
        : Colors.green;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 概览面板
          _buildOverviewPanel(
            children: [
              _buildBigValue('${bat?.level ?? '--'}%', '电量', levelColor),
              _buildBigValue(bat?.isCharging == true ? '充电中' : '放电中', '状态',
                  bat?.isCharging == true ? Colors.orange : Colors.grey),
              _buildBigValue('${bat?.temperature.toStringAsFixed(0) ?? '--'}℃', '温度',
                  bat != null && bat.temperature > 40 ? Colors.red : Colors.green),
            ],
          ),
          const SizedBox(height: 12),

          // 详细信息
          if (bat != null) ...[
            Row(
              children: [
                _buildSmallStat('充电类型', bat.chargeType),
                const SizedBox(width: 16),
                _buildSmallStat('电压', '${bat.voltage} mV'),
                const SizedBox(width: 16),
                _buildSmallStat('电流', '${bat.currentMa} mA'),
              ],
            ),
            if (bat.drainRate > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _buildSmallStat('耗电速率', '${bat.drainRate.toStringAsFixed(1)} %/h'),
              ),
            const SizedBox(height: 12),
          ],

          // 实时曲线
          const Text('实时趋势', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ProfilerBatteryChart(samples: _service.batteryHistory),
          const SizedBox(height: 12),

          // 耗电排行
          const Text('耗电排行', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _buildBatteryUsageList(_service.batteryUsageList),
        ],
      ),
    );
  }

  // ==================== 通用 UI 组件 ====================

  /// 概览面板
  Widget _buildOverviewPanel({required List<Widget> children}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: children,
    );
  }

  /// 大数值卡片
  Widget _buildBigValue(String value, String label, Color color) {
    return Expanded(
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
        ),
      ),
    );
  }

  /// 小统计项
  Widget _buildSmallStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// 图例
  Widget _buildLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 3, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }

  /// 进程排行列表
  Widget _buildProcessList(List<ProcessInfo> processes, String Function(ProcessInfo) valueBuilder) {
    if (processes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: Text('暂无数据（需要使用情况访问权限）', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return Column(
      children: processes.take(5).map((p) => ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: Colors.grey.shade200,
          child: Text(p.appName.isNotEmpty ? p.appName[0] : '?',
              style: const TextStyle(fontSize: 14)),
        ),
        title: Text(p.appName, style: const TextStyle(fontSize: 13)),
        subtitle: Text(p.packageName, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
        trailing: Text(valueBuilder(p), style: const TextStyle(fontSize: 12)),
      )).toList(),
    );
  }

  /// 耗电排行列表
  Widget _buildBatteryUsageList(List<ProcessInfo> processes) {
    if (processes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: Text('暂无数据（需要使用情况访问权限）', style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return Column(
      children: processes.take(5).map((p) => ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: Colors.grey.shade200,
          child: Text(p.appName.isNotEmpty ? p.appName[0] : '?',
              style: const TextStyle(fontSize: 14)),
        ),
        title: Text(p.appName, style: const TextStyle(fontSize: 13)),
        subtitle: Text(p.packageName, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
        trailing: Text('前台 ${p.foregroundTime}s', style: const TextStyle(fontSize: 12)),
      )).toList(),
    );
  }

  /// 底部操作栏
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          // 开始/停止监控按钮
          Expanded(
            child: FilledButton.icon(
              onPressed: _toggleMonitoring,
              icon: Icon(_service.isMonitoring ? Icons.stop : Icons.play_arrow),
              label: Text(_service.isMonitoring ? '停止监控' : '开始监控'),
              style: FilledButton.styleFrom(
                backgroundColor: _service.isMonitoring ? Colors.red : Colors.green,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // 生成报告按钮
          OutlinedButton.icon(
            onPressed: _service.isMonitoring ? _generateReport : null,
            icon: const Icon(Icons.assessment),
            label: const Text('生成报告'),
          ),
        ],
      ),
    );
  }
}
