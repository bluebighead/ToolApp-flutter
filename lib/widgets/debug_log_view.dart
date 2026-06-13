// 调试日志展示组件
// 用于在压缩页面中展示详细调试日志，并提供复制日志到剪贴板的功能
// 方便用户排查压缩失败等问题时提供完整的上下文信息
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// 调试日志展示组件
/// 显示最近与指定标签匹配的 AppLogger 日志，并提供复制按钮
class DebugLogView extends StatefulWidget {
  /// 要筛选的标签列表（只显示这些标签的日志）
  final List<String> filterTags;

  /// 最大显示日志条数
  final int maxEntries;

  /// 标题
  final String title;

  const DebugLogView({
    super.key,
    this.filterTags = const ['CompressorService'],
    this.maxEntries = 100,
    this.title = '调试日志',
  });

  @override
  State<DebugLogView> createState() => _DebugLogViewState();
}

class _DebugLogViewState extends State<DebugLogView> {
  bool _expanded = false;

  /// 获取筛选后的日志文本
  String _getFilteredLogText() {
    final entries = AppLogger.buffer
        .where((e) => widget.filterTags.contains(e.tag))
        .toList()
        .reversed
        .take(widget.maxEntries)
        .toList()
        .reversed;
    return entries.map((e) => e.format()).join('\n');
  }

  /// 获取筛选后的日志条目数
  int _getFilteredCount() {
    return AppLogger.buffer
        .where((e) => widget.filterTags.contains(e.tag))
        .length;
  }

  /// 复制日志到剪贴板
  Future<void> _copyLogs() async {
    final logText = _getFilteredLogText();
    if (logText.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无日志可复制')),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: logText));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制 ${logText.split('\n').length} 行日志到剪贴板'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _getFilteredCount();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏：点击可展开/收起
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.bug_report,
                    size: 18,
                    color: Colors.orange.shade700,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count 条',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // 复制按钮始终可见
                  SizedBox(
                    height: 30,
                    child: TextButton.icon(
                      onPressed: _copyLogs,
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('复制日志', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        foregroundColor: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 展开后的日志内容
          if (_expanded) ...[
            const Divider(height: 1),
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ShaderMask(
                shaderCallback: (bounds) {
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black,
                      Colors.black,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.85, 0.95, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _getFilteredLogText().isEmpty
                        ? '暂无日志'
                        : _getFilteredLogText(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.grey.shade800,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 12, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text(
                    '可选中文本复制，或点击上方"复制日志"按钮',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
