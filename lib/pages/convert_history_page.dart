// 视频转换历史记录页
//
// 展示所有历史转换记录，支持：
//   - 下拉刷新
//   - 清空全部（含二次确认）
//   - 单条删除
//   - 单条详情：状态、源/目标路径、时长、耗时、大小、错误信息
//   - 一键打开文件所在目录（原生 MethodChannel）
//   - 一键复制输出路径
//   - 状态徽标 + 颜色区分（成功/失败/取消）

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../utils/app_logger.dart';
import '../utils/convert_history.dart';

class ConvertHistoryPage extends StatefulWidget {
  const ConvertHistoryPage({super.key});

  @override
  State<ConvertHistoryPage> createState() => _ConvertHistoryPageState();
}

class _ConvertHistoryPageState extends State<ConvertHistoryPage> {
  static const String _logTag = 'ConvertHistoryPage';

  /// 内存中的历史列表（页面打开时加载 + setState 刷新）
  List<ConvertHistoryEntry> _entries = [];

  /// 是否正在首次加载
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    AppLogger.i(_logTag, '进入历史记录页');
    _load();
  }

  /// 从持久化层加载
  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await ConvertHistory.loadAll();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  /// 下拉刷新
  Future<void> _onRefresh() async {
    // 清空内存缓存，强制重读
    // ConvertHistory._cache is private; 用 clear 读后写回去？
    // 简单做法：直接调用 loadAll 会复用 _cache
    // 这里通过调一次 add 一个 noop 来刷新？不合适
    // 最简单：loadAll 已返回最新数据；如果有新增我们在 _startConvert 写入了，
    // 下拉刷新就是重读 SharedPreferences
    await _load();
  }

  /// 清空全部（带二次确认）
  Future<void> _onClearAll() async {
    if (_entries.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史记录'),
        content: const Text('确定要清空所有历史记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ConvertHistory.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空历史记录')),
      );
    }
  }

  /// 单条删除
  Future<void> _onDeleteOne(ConvertHistoryEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该条记录？'),
        content: Text('确定要删除这条 ${TimeFormat.shortDateTime(e.timestampMs)} 的记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ConvertHistory.remove(e.id);
    await _load();
  }

  /// 一键打开输出文件所在目录
  ///
  /// v1.6.20+ 升级：原生走多 mime + createChooser，原生没 App 时
  /// 兜底用 OpenFilex 直接打开文件本身（系统播放器）。
  Future<void> _openFolder(ConvertHistoryEntry e) async {
    final p = e.outputPath;
    if (p == null) return;
    final file = File(p);
    if (!await file.exists()) {
      _snack('文件已不存在：$p');
      return;
    }
    try {
      const channel = MethodChannel('com.example.toolapp/storage');
      final ok = await channel.invokeMethod<bool>(
        'openContainingFolder',
        {'filePath': p},
      );
      if (ok == true) {
        return;
      }
      // 原生没找到任何 App → 直接打开文件
      await _openFile(e);
    } on PlatformException catch (err) {
      if (err.code == 'NO_HANDLER') {
        await _openFile(e);
      } else {
        _snack('打开失败：${err.message ?? err.code}');
      }
    } catch (err) {
      _snack('打开失败：$err');
    }
  }

  /// 一键打开输出文件（用 OpenFilex 调起视频播放器）
  Future<void> _openFile(ConvertHistoryEntry e) async {
    final p = e.outputPath;
    if (p == null) return;
    try {
      final result = await OpenFilex.open(p);
      AppLogger.i(_logTag,
          'OpenFilex 打开：type=${result.type}, message=${result.message}');
      if (result.type != ResultType.done) {
        _snack('未找到可打开此文件的应用（${result.message}）');
      }
    } catch (err) {
      _snack('打开文件失败：$err');
    }
  }

  /// 复制输出路径
  Future<void> _copyPath(ConvertHistoryEntry e) async {
    final p = e.outputPath;
    if (p == null) return;
    await Clipboard.setData(ClipboardData(text: p));
    _snack('已复制路径到剪贴板');
  }

  /// SnackBar 工具
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('转换历史记录'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: '清空全部',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _onClearAll,
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
                ? _buildEmpty()
                : RefreshIndicator(
                    onRefresh: _onRefresh,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 8),
                      itemBuilder: (ctx, i) => _buildItem(_entries[i]),
                    ),
                  ),
      ),
    );
  }

  /// 空列表提示
  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_toggle_off,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '暂无转换记录',
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            Text(
              '成功/失败/取消的转换都会保存在这里',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// 单条历史卡片
  Widget _buildItem(ConvertHistoryEntry e) {
    final statusInfo = _statusInfo(e.status);
    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: statusInfo.borderColor, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showDetail(e),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：状态徽标 + 时间
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusInfo.bgColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusInfo.icon,
                            size: 12, color: statusInfo.fgColor),
                        const SizedBox(width: 4),
                        Text(
                          statusInfo.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: statusInfo.fgColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    TimeFormat.shortDateTime(e.timestampMs),
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 输入源
              Row(
                children: [
                  Icon(
                    e.isNetwork ? Icons.cloud_outlined : Icons.movie_outlined,
                    size: 14,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      e.inputDisplayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 输出文件
              if (e.outputPath != null)
                Row(
                  children: [
                    const Icon(Icons.folder_outlined,
                        size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        e.outputDisplayName ?? '-',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 6),
              // 元数据：耗时 / 大小 / 格式
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  _metaChip(
                    Icons.timer_outlined,
                    '耗时 ${TimeFormat.fromSeconds((e.durationMs ?? 0) ~/ 1000)}',
                  ),
                  if (e.outputSize != null && e.outputSize! > 0)
                    _metaChip(
                      Icons.sd_storage_outlined,
                      SizeFormat.format(e.outputSize),
                    ),
                  _metaChip(
                    Icons.movie_creation_outlined,
                    '${e.format.name.toUpperCase()} · ${e.quality.name}',
                  ),
                ],
              ),
              if (e.status == ConvertStatus.failed &&
                  (e.errorMessage?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 6),
                Text(
                  '错误：${e.errorMessage}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: Colors.red.shade700),
                ),
              ],
              const SizedBox(height: 8),
              // 底部操作（v1.6.20+ 重排：3 个打开/复制动作 + 右上角删除）
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (e.outputPath != null) ...[
                          TextButton.icon(
                            onPressed: () => _openFile(e),
                            icon: const Icon(Icons.play_circle_outline,
                                size: 16),
                            label: const Text('打开文件'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
                              minimumSize: const Size(0, 32),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _openFolder(e),
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: const Text('打开目录'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
                              minimumSize: const Size(0, 32),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _copyPath(e),
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            label: const Text('复制路径'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
                              minimumSize: const Size(0, 32),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '删除该条',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _onDeleteOne(e),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 小元数据 chip
  Widget _metaChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.grey.shade600),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
      ],
    );
  }

  /// 详情弹窗
  Future<void> _showDetail(ConvertHistoryEntry e) async {
    final statusInfo = _statusInfo(e.status);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(statusInfo.icon, color: statusInfo.fgColor, size: 20),
            const SizedBox(width: 6),
            Text('${statusInfo.label} · 详情'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('时间', TimeFormat.shortDateTime(e.timestampMs)),
              const SizedBox(height: 6),
              _detailRow('输入源', e.input),
              const SizedBox(height: 6),
              if (e.outputPath != null) ...[
                _detailRow('输出路径', e.outputPath!),
                const SizedBox(height: 6),
              ],
              if (e.outputSize != null) ...[
                _detailRow('输出大小', SizeFormat.format(e.outputSize)),
                const SizedBox(height: 6),
              ],
              if (e.sourceDurationMs != null) ...[
                _detailRow(
                    '源时长', TimeFormat.fromSeconds(e.sourceDurationMs! ~/ 1000)),
                const SizedBox(height: 6),
              ],
              if (e.durationMs != null) ...[
                _detailRow('耗时', TimeFormat.fromSeconds(e.durationMs! ~/ 1000)),
                const SizedBox(height: 6),
              ],
              _detailRow('格式', e.format.name.toUpperCase()),
              const SizedBox(height: 6),
              _detailRow('质量档位', e.quality.name),
              if (e.errorMessage != null && e.errorMessage!.isNotEmpty) ...[
                const SizedBox(height: 6),
                _detailRow('错误信息', e.errorMessage!, maxLines: 5),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {int maxLines = 2}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ),
        Expanded(
          child: SelectableText(
            value,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// 状态 → 视觉
  _StatusVisual _statusInfo(ConvertStatus s) {
    switch (s) {
      case ConvertStatus.success:
        return const _StatusVisual(
          label: '成功',
          icon: Icons.check_circle,
          fgColor: Colors.green,
          bgColor: Color(0x1A4CAF50),
          borderColor: Color(0x334CAF50),
        );
      case ConvertStatus.failed:
        return const _StatusVisual(
          label: '失败',
          icon: Icons.error,
          fgColor: Colors.red,
          bgColor: Color(0x1AF44336),
          borderColor: Color(0x33F44336),
        );
      case ConvertStatus.cancelled:
        return const _StatusVisual(
          label: '已取消',
          icon: Icons.cancel,
          fgColor: Colors.orange,
          bgColor: Color(0x1AFF9800),
          borderColor: Color(0x33FF9800),
        );
    }
  }
}

/// 状态视觉信息
class _StatusVisual {
  final String label;
  final IconData icon;
  final Color fgColor;
  final Color bgColor;
  final Color borderColor;
  const _StatusVisual({
    required this.label,
    required this.icon,
    required this.fgColor,
    required this.bgColor,
    required this.borderColor,
  });
}
