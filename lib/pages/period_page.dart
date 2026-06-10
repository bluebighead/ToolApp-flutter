// 经期宝主页面
// 3个Tab：日历、记录、统计
import 'package:flutter/material.dart';

import '../utils/period_model.dart';
import 'period_calendar_tab.dart';
import 'period_record_tab.dart';
import 'period_stats_tab.dart';

class PeriodPage extends StatefulWidget {
  const PeriodPage({super.key});

  @override
  State<PeriodPage> createState() => _PeriodPageState();
}

class _PeriodPageState extends State<PeriodPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 经期记录列表
  List<PeriodRecord> _records = [];
  // 排卵日标记列表
  List<OvulationMark> _ovulationMarks = [];
  // 用户设置
  PeriodSettings _settings = const PeriodSettings();
  // 是否加载中
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 加载所有数据
  Future<void> _loadData() async {
    final results = await Future.wait([
      PeriodStorage.loadRecords(),
      PeriodStorage.loadOvulationMarks(),
      PeriodStorage.loadSettings(),
    ]);
    if (!mounted) return;
    setState(() {
      _records = results[0] as List<PeriodRecord>;
      _ovulationMarks = results[1] as List<OvulationMark>;
      _settings = results[2] as PeriodSettings;
      _isLoading = false;
    });
  }

  /// 刷新数据（子页面调用）
  Future<void> _refreshData() async {
    await _loadData();
  }

  /// 更新设置
  Future<void> _updateSettings(PeriodSettings settings) async {
    await PeriodStorage.saveSettings(settings);
    setState(() => _settings = settings);
  }

  /// 计算当前预测结果
  PeriodPrediction get _prediction => PeriodCalculator.predict(
        records: _records,
        settings: _settings,
        ovulationMarks: _ovulationMarks,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('经期宝'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.calendar_today), text: '日历'),
            Tab(icon: Icon(Icons.edit_note), text: '记录'),
            Tab(icon: Icon(Icons.bar_chart), text: '统计'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // 日历Tab
                PeriodCalendarTab(
                  records: _records,
                  ovulationMarks: _ovulationMarks,
                  settings: _settings,
                  prediction: _prediction,
                  onRefresh: _refreshData,
                ),
                // 记录Tab
                PeriodRecordTab(
                  records: _records,
                  ovulationMarks: _ovulationMarks,
                  settings: _settings,
                  onRefresh: _refreshData,
                ),
                // 统计Tab
                PeriodStatsTab(
                  records: _records,
                  prediction: _prediction,
                  settings: _settings,
                  onUpdateSettings: _updateSettings,
                  ovulationMarks: _ovulationMarks,
                ),
              ],
            ),
    );
  }
}
