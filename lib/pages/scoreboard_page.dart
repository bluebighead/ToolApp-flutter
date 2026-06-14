// 计分板小工具
// 支持全屏显示，全屏模式下也支持加减分功能
// v1.50.0+ 新增
// v1.51.0+ 新增删除玩家（至少保留2名）和历史记录功能
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';

class ScoreboardPage extends StatefulWidget {
  const ScoreboardPage({super.key});

  @override
  State<ScoreboardPage> createState() => _ScoreboardPageState();
}

class _ScoreboardPageState extends State<ScoreboardPage> {
  // 计分数据
  final List<ScoreEntry> _entries = [
    ScoreEntry(name: '玩家 1', score: 0, color: Colors.blue),
    ScoreEntry(name: '玩家 2', score: 0, color: Colors.red),
  ];

  // 分数步长
  int _step = 1;

  // 是否全屏
  bool _isFullscreen = false;

  // 历史记录（v1.51.0+）
  List<ScoreHistoryRecord> _history = [];

  // 编辑玩家名称
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ============================================================
  // 历史记录（v1.51.0+）
  // ============================================================

  /// 加载历史记录
  Future<void> _loadHistory() async {
    try {
      final prefs = AppSettings.prefs!;
      final jsonList = prefs.getStringList('scoreboard_history') ?? [];
      final records = jsonList
          .map((s) {
            try {
              final map = jsonDecode(s) as Map<String, dynamic>;
              return ScoreHistoryRecord.fromJson(map);
            } catch (_) {
              return null;
            }
          })
          .whereType<ScoreHistoryRecord>()
          .toList();
      setState(() => _history = records);
    } catch (e) {
      AppLogger.e('Scoreboard', '加载历史记录失败: $e');
    }
  }

  /// 保存当前分数到历史记录
  Future<void> _saveCurrentToHistory() async {
    try {
      final record = ScoreHistoryRecord(
        timestamp: DateTime.now(),
        players: _entries.map((e) => PlayerSnapshot(name: e.name, score: e.score)).toList(),
      );
      _history.insert(0, record);
      if (_history.length > 50) {
        _history = _history.sublist(0, 50); // 最多保存50条
      }

      final prefs = AppSettings.prefs!;
      final jsonList = _history.map((r) => jsonEncode(r.toJson())).toList();
      await prefs.setStringList('scoreboard_history', jsonList);
    } catch (e) {
      AppLogger.e('Scoreboard', '保存历史记录失败: $e');
    }
  }

  /// 删除历史记录
  Future<void> _deleteHistory(List<int> indices) async {
    indices.sort((a, b) => b.compareTo(a));
    for (final i in indices) {
      _history.removeAt(i);
    }
    setState(() {});

    final prefs = AppSettings.prefs!;
    final jsonList = _history.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList('scoreboard_history', jsonList);
  }

  /// 显示历史记录弹窗（v1.51.2+ 修复：选择逻辑移至外部状态）
  void _showHistoryDialog() {
    if (_history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无历史记录')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => _ScoreHistoryDialog(
        history: _history,
        onDelete: (indices) {
          _deleteHistory(indices);
        },
      ),
    );
  }

  /// 显示历史记录详细信息（v1.51.0+）
  void _showHistoryDetailDialog(BuildContext parentCtx, ScoreHistoryRecord record) {
    showDialog(
      context: parentCtx,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.history, size: 20),
            const SizedBox(width: 8),
            Text(
              '${record.timestamp.year}/${record.timestamp.month}/${record.timestamp.day} ${record.timestamp.hour}:${record.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('玩家数量: ${record.players.length}', style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            ...record.players.map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.person, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(p.name, style: const TextStyle(fontSize: 14))),
                      Text(
                        '${p.score > 0 ? '+' : ''}${p.score}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: p.score >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 切换全屏
  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// 添加玩家
  void _addPlayer() {
    _nameController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加玩家'),
        content: TextField(
          controller: _nameController,
          decoration: InputDecoration(
            hintText: '输入玩家名称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) {
              _doAddPlayer(v.trim());
              Navigator.pop(ctx);
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final name = _nameController.text.trim();
              if (name.isNotEmpty) {
                _doAddPlayer(name);
                Navigator.pop(ctx);
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _doAddPlayer(String name) {
    final colors = [
      Colors.blue, Colors.red, Colors.green, Colors.orange,
      Colors.purple, Colors.teal, Colors.pink, Colors.indigo,
    ];
    setState(() {
      _entries.add(ScoreEntry(
        name: name,
        score: 0,
        color: colors[_entries.length % colors.length],
      ));
    });
  }

  /// 删除玩家（v1.51.0+ 至少保留2名玩家）
  void _removePlayer(int index) {
    if (_entries.length <= 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少需要保留2名玩家')),
      );
      return;
    }
    setState(() => _entries.removeAt(index));
  }

  /// 编辑玩家名称
  void _editPlayerName(int index) {
    _nameController.text = _entries[index].name;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改名称'),
        content: TextField(
          controller: _nameController,
          decoration: InputDecoration(
            hintText: '输入新名称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) {
              setState(() => _entries[index].name = v.trim());
              Navigator.pop(ctx);
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final name = _nameController.text.trim();
              if (name.isNotEmpty) {
                setState(() => _entries[index].name = name);
                Navigator.pop(ctx);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 重置所有分数
  void _resetAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置分数'),
        content: const Text('确定要将所有玩家分数重置为0吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              _saveCurrentToHistory(); // v1.51.0+ 保存当前分数到历史
              setState(() {
                for (final e in _entries) {
                  e.score = 0;
                }
              });
              Navigator.pop(ctx);
            },
            child: const Text('重置'),
          ),
        ],
      ),
    );
  }

  /// 设置步长
  void _setStep(int step) {
    setState(() => _step = step);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: _isFullscreen
          ? null
          : AppBar(
              title: const Text('计分板'),
              actions: [
                // 历史记录
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '历史记录',
                  onPressed: _showHistoryDialog,
                ),
                // 步长设置
                PopupMenuButton<int>(
                  icon: const Icon(Icons.tune),
                  tooltip: '设置步长',
                  onSelected: _setStep,
                  itemBuilder: (_) => [1, 5, 10, 100].map((s) => PopupMenuItem(
                    value: s,
                    child: Text('步长: $s'),
                  )).toList(),
                ),
                // 添加玩家
                IconButton(
                  icon: const Icon(Icons.person_add),
                  tooltip: '添加玩家',
                  onPressed: _addPlayer,
                ),
                // 重置
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '重置分数',
                  onPressed: _resetAll,
                ),
                // 全屏按钮
                IconButton(
                  icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                  tooltip: _isFullscreen ? '退出全屏' : '全屏',
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
      body: _buildScoreboard(theme),
    );
  }

  Widget _buildScoreboard(ThemeData theme) {
    return Column(
      children: [
        // 计分区域
        Expanded(
          child: _entries.isEmpty
              ? const Center(child: Text('请添加玩家', style: TextStyle(color: Colors.grey, fontSize: 16)))
              : Padding(
                  padding: EdgeInsets.all(_isFullscreen ? 8.0 : 16.0),
                  child: Column(
                    children: List.generate(_entries.length, (i) {
                      final entry = _entries[i];
                      return Expanded(
                        child: _buildScoreCard(entry, i, theme),
                      );
                    }),
                  ),
                ),
        ),

        // 全屏模式下的底部工具栏
        if (_isFullscreen)
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.black87,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildMiniButton(Icons.person_add, '添加', () => _addPlayer()),
                  _buildMiniButton(Icons.refresh, '重置', () => _resetAll()),
                  _buildMiniButton(Icons.fullscreen_exit, '退出', _toggleFullscreen),
                  // 步长切换
                  ChoiceChip(
                    label: Text('${_step}分', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    selected: true,
                    selectedColor: Colors.blue,
                    onSelected: (_) {
                      final steps = [1, 5, 10, 100];
                      final idx = steps.indexOf(_step);
                      setState(() => _step = steps[(idx + 1) % steps.length]);
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMiniButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 20),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCard(ScoreEntry entry, int index, ThemeData theme) {
    final isPositive = entry.score >= 0;
    final scoreColor = entry.score == 0
        ? Colors.grey
        : (isPositive ? Colors.green : Colors.red);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: entry.color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: entry.color.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.all(_isFullscreen ? 8.0 : 12.0),
        child: Stack(
          children: [
            Row(
              children: [
                // 玩家信息
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    onTap: _isFullscreen ? null : () => _editPlayerName(index),
                onLongPress: () => _editPlayerName(index),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: _isFullscreen ? 36 : 44,
                      height: _isFullscreen ? 36 : 44,
                      decoration: BoxDecoration(
                        color: entry.color,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          entry.name.isNotEmpty ? entry.name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.name,
                      style: TextStyle(
                        fontSize: _isFullscreen ? 12 : 14,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),

            // 减分按钮
            _buildScoreButton(
              Icons.remove,
              entry.color,
              false,
              _isFullscreen ? 44 : 52,
              () => setState(() => entry.score -= _step),
            ),

            const SizedBox(width: 8),

            // 分数显示
            Container(
              constraints: BoxConstraints(
                minWidth: _isFullscreen ? 80 : 100,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scoreColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${entry.score}',
                style: TextStyle(
                  fontSize: _isFullscreen ? 28 : 36,
                  fontWeight: FontWeight.bold,
                  color: scoreColor,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(width: 8),

            // 加分按钮
            _buildScoreButton(
              Icons.add,
              entry.color,
              true,
              _isFullscreen ? 44 : 52,
              () => setState(() => entry.score += _step),
            ),
          ],
        ),
            // "..." 菜单按钮（v1.51.2+ 卡片右上角）
            Positioned(
              top: 0,
              right: 0,
              child: PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, size: 18, color: Colors.grey.shade500),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onSelected: (action) {
                  if (action == 'edit') {
                    _editPlayerName(index);
                  } else if (action == 'delete') {
                    _removePlayer(index);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('修改名称', style: TextStyle(fontSize: 13))),
                  if (_entries.length > 2)
                    const PopupMenuItem(value: 'delete', child: Text('删除玩家', style: TextStyle(fontSize: 13, color: Colors.red))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreButton(
    IconData icon,
    Color color,
    bool isAdd,
    double size,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (_) {
        // 长按连续加减分
        _longPressTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
          onTap();
        });
      },
      onLongPressEnd: (_) {
        _longPressTimer?.cancel();
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isAdd ? Colors.green.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isAdd ? Colors.green.withValues(alpha: 0.4) : Colors.red.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            color: isAdd ? Colors.green : Colors.red,
            size: size * 0.55,
          ),
        ),
      ),
    );
  }

  Timer? _longPressTimer;
}

/// 计分历史记录弹窗组件（v1.51.2+ 提取为独立 StatefulWidget）
class _ScoreHistoryDialog extends StatefulWidget {
  final List<ScoreHistoryRecord> history;
  final Function(List<int> indices) onDelete;

  const _ScoreHistoryDialog({required this.history, required this.onDelete});

  @override
  State<_ScoreHistoryDialog> createState() => _ScoreHistoryDialogState();
}

class _ScoreHistoryDialogState extends State<_ScoreHistoryDialog> {
  final Set<int> _selectedIndices = {};
  bool _selectAllMode = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('历史记录', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
            onPressed: () {
              setState(() {
                if (_selectAllMode) {
                  _selectedIndices.clear();
                  _selectAllMode = false;
                } else {
                  for (int i = 0; i < widget.history.length; i++) {
                    _selectedIndices.add(i);
                  }
                  _selectAllMode = true;
                }
              });
            },
            child: Text(
              _selectAllMode ? '取消全选' : '全选',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: widget.history.length,
                itemBuilder: (_, i) {
                  final record = widget.history[i];
                  final isSelected = _selectedIndices.contains(i);
                  return Card(
                    color: isSelected ? Colors.blue.withValues(alpha: 0.1) : null,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedIndices.remove(i);
                            _selectAllMode = false;
                          } else {
                            _selectedIndices.add(i);
                            if (_selectedIndices.length == widget.history.length) {
                              _selectAllMode = true;
                            }
                          }
                        });
                      },
                      onLongPress: () {
                        final scoreboardState = context.findAncestorStateOfType<_ScoreboardPageState>();
                        if (scoreboardState != null) {
                          scoreboardState._showHistoryDetailDialog(context, record);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (isSelected)
                                  const Icon(Icons.check_circle, size: 16, color: Colors.blue)
                                else
                                  const Icon(Icons.radio_button_unchecked, size: 16, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text(
                                  '${record.timestamp.month}/${record.timestamp.day} ${record.timestamp.hour}:${record.timestamp.minute.toString().padLeft(2, '0')}',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                                const Spacer(),
                                Text(
                                  '${record.players.length}名玩家',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ...record.players.map((p) => Padding(
                                  padding: const EdgeInsets.only(left: 28),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.person, size: 14, color: Colors.grey),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(p.name, style: const TextStyle(fontSize: 13)),
                                      ),
                                      Text(
                                        '${p.score > 0 ? '+' : ''}${p.score}',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: p.score >= 0 ? Colors.green : Colors.red,
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 删除按钮（始终显示，选中项时可用）
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ElevatedButton.icon(
                onPressed: _selectedIndices.isNotEmpty
                    ? () {
                        widget.onDelete(_selectedIndices.toList());
                        setState(() {
                          _selectedIndices.clear();
                          _selectAllMode = false;
                        });
                      }
                    : null,
                icon: const Icon(Icons.delete, size: 18),
                label: Text(
                  _selectedIndices.isNotEmpty
                      ? '删除选中 (${_selectedIndices.length})'
                      : '选择记录后删除',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 计分条目
class ScoreEntry {
  String name;
  int score;
  Color color;

  ScoreEntry({
    required this.name,
    required this.score,
    required this.color,
  });
}

/// 玩家快照（用于历史记录，v1.51.0+）
class PlayerSnapshot {
  final String name;
  final int score;

  PlayerSnapshot({required this.name, required this.score});

  Map<String, dynamic> toJson() => {'name': name, 'score': score};

  factory PlayerSnapshot.fromJson(Map<String, dynamic> json) {
    return PlayerSnapshot(
      name: json['name'] as String? ?? '',
      score: json['score'] as int? ?? 0,
    );
  }
}

/// 计分历史记录（v1.51.0+）
class ScoreHistoryRecord {
  final DateTime timestamp;
  final List<PlayerSnapshot> players;

  ScoreHistoryRecord({required this.timestamp, required this.players});

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'players': players.map((p) => p.toJson()).toList(),
      };

  factory ScoreHistoryRecord.fromJson(Map<String, dynamic> json) {
    final playersList = (json['players'] as List<dynamic>?)
            ?.map((e) => PlayerSnapshot.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return ScoreHistoryRecord(
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      players: playersList,
    );
  }
}