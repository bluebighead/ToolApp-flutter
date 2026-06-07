// 日志查看页面
// 展示应用最近产生的日志，方便开发/测试人员锁定问题。
// 数据来源：AppLogger 内存缓存（仅在 App 运行期间存在）。
// 提供导出按钮：将当前内存日志写入 AppStorage 管理的 ToolApp/logs 目录，
// 方便在手机上长期保存或分享给开发者。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/app_storage.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  @override
  void initState() {
    super.initState();
    // 进入日志页时记录一条 Info 日志
    AppLogger.i('LogsPage', '进入日志查看页面');
  }

  /// 颜色：根据日志级别返回对应颜色
  Color _colorFor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
    }
  }

  /// 复制全部日志到剪贴板
  Future<void> _copyAll() async {
    final text = AppLogger.buffer.map((e) => e.format()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppLogger.i('LogsPage', '已复制全部日志到剪贴板，共 ${AppLogger.buffer.length} 条');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制到剪贴板')),
    );
  }

  /// 清空内存日志缓存
  void _clear() {
    AppLogger.clear();
    AppLogger.i('LogsPage', '已清空内存日志缓存');
    setState(() {});
  }

  /// 导出当前内存日志到文件
  /// 文件会写入 AppStorage.getLogsDirectory() 管理的目录中，
  /// 文件名形如：logs_20260607_153012_123.txt
  Future<void> _exportLogs() async {
    final logs = AppLogger.buffer;
    if (logs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有日志可导出')),
      );
      return;
    }
    AppLogger.i('LogsPage', '开始导出日志，共 ${logs.length} 条');
    try {
      // 通过 AppStorage 拿到 App 在手机上的日志目录
      final dir = await AppStorage.getLogsDirectory();
      // 构造文件名：logs_yyyyMMdd_HHmmss_mmm.txt，方便排序和识别
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      String three(int v) => v.toString().padLeft(3, '0');
      final fileName =
          'logs_${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
          '${three(now.millisecond)}.txt';
      final file = File('${dir.path}/$fileName');

      // 文件头部附加一些元信息，便于阅读
      final buffer = StringBuffer();
      buffer.writeln('# ToolApp 调试日志导出');
      buffer.writeln('# 导出时间: ${now.toIso8601String()}');
      buffer.writeln('# 日志条数: ${logs.length}');
      buffer.writeln('# ----------------------------------------');
      for (final entry in logs) {
        buffer.writeln(entry.format());
      }
      await file.writeAsString(buffer.toString(), flush: true);
      AppLogger.i('LogsPage', '日志已导出到：${file.path}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出 ${logs.length} 条日志\n${file.path}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      AppLogger.e('LogsPage', '导出日志失败', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = AppLogger.buffer;
    return Scaffold(
      appBar: AppBar(
        title: const Text('调试日志'),
        actions: [
          // 导出全部日志到文件（写入 AppStorage 管理的 ToolApp/logs 目录）
          IconButton(
            tooltip: '导出日志',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: logs.isEmpty ? null : _exportLogs,
          ),
          // 复制全部日志
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all),
            onPressed: logs.isEmpty ? null : _copyAll,
          ),
          // 清空日志
          IconButton(
            tooltip: '清空日志',
            icon: const Icon(Icons.delete_outline),
            onPressed: logs.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(
              child: Text(
                '暂无日志',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : ListView.separated(
              // 倒序展示，最新日志在最上面
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: logs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                // 反向索引：列表底部为最早日志，顶部为最新日志
                final entry = logs[logs.length - 1 - index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    entry.format(),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: _colorFor(entry.level),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
