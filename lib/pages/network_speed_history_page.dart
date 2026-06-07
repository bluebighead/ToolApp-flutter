// 网速测试历史列表页
// 从 SharedPreferences 读取历史记录，按时间倒序展示
// 点击行弹底部弹层显示完整详情
// 设计文档：docs/superpowers/specs/2026-06-06-toolapp-networkspeed-design.md
import 'package:flutter/material.dart';
import '../utils/app_logger.dart';
import '../utils/network_speed_history.dart';

class NetworkSpeedHistoryPage extends StatefulWidget {
  const NetworkSpeedHistoryPage({super.key});

  @override
  State<NetworkSpeedHistoryPage> createState() =>
      _NetworkSpeedHistoryPageState();
}

class _NetworkSpeedHistoryPageState extends State<NetworkSpeedHistoryPage> {
  late Future<List<PingRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = NetworkSpeedHistory.loadAll();
  }

  /// 重新加载
  void _reload() {
    setState(() {
      _future = NetworkSpeedHistory.loadAll();
    });
  }

  /// 清空确认
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定要清空所有测速历史吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkSpeedHistory.clear();
      AppLogger.i('NetworkSpeedHistoryPage', '已清空历史');
      _reload();
    }
  }

  /// 弹出详情
  void _showDetail(PingRecord record) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PingDetailSheet(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('测速历史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: FutureBuilder<List<PingRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = snapshot.data ?? [];
          if (records.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 12),
                  Text(
                    '暂无测速记录',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '完成一次测速即可查看历史',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = records[index];
              return ListTile(
                leading: const Icon(Icons.network_check),
                title: Text(_formatTime(r.timestamp)),
                subtitle: Text(_hostOf(r.server)),
                trailing: Text(
                  '${r.avg}ms · ${(r.lossRate * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () => _showDetail(r),
              );
            },
          );
        },
      ),
    );
  }

  /// 时间格式：yyyy-MM-dd HH:mm
  String _formatTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 提取 URL 主机部分
  String _hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isEmpty ? url : uri.host;
    } catch (_) {
      return url;
    }
  }
}

/// 详情底部弹层
class _PingDetailSheet extends StatelessWidget {
  final PingRecord record;

  const _PingDetailSheet({required this.record});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '测速详情',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _detailRow('时间', record.timestamp.toIso8601String().substring(0, 19)),
            _detailRow('服务器', record.server),
            const Divider(),
            const SizedBox(height: 8),
            _detailRow('最小', '${record.min} ms'),
            _detailRow('平均', '${record.avg} ms'),
            _detailRow('最大', '${record.max} ms'),
            _detailRow('抖动', '${record.jitter} ms'),
            _detailRow('丢包', '${(record.lossRate * 100).round()} %'),
            const SizedBox(height: 12),
            const Text(
              '原始样本',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: record.samples
                  .map((s) => Chip(
                        label: Text(s == null ? '--' : '${s}ms'),
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
