// 麻将计分器主页面
// 显示对局列表，支持新建对局、查看历史、删除对局、复盘已结束对局、批量删除
import 'package:flutter/material.dart';

import '../utils/mahjong_model.dart';
import 'mahjong_game_page.dart';
import 'mahjong_review_page.dart';

class MahjongPage extends StatefulWidget {
  const MahjongPage({super.key});

  @override
  State<MahjongPage> createState() => _MahjongPageState();
}

class _MahjongPageState extends State<MahjongPage> {
  List<MahjongGame> _games = [];
  bool _isLoading = true;

  // 批量操作相关状态
  bool _isBatchMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadGames();
  }

  /// 页面恢复时刷新（从复盘页返回等场景）
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次加载时 initState 已处理，后续恢复时刷新
    // 使用 mounted 和 _isLoading 标志避免重复加载
    if (!_isLoading && mounted) {
      _loadGames();
    }
  }

  Future<void> _loadGames() async {
    final games = await MahjongStorage.loadGames();
    if (!mounted) return;
    setState(() {
      _games = games;
      _isLoading = false;
    });
  }

  /// 下拉刷新
  Future<void> _onRefresh() async {
    await _loadGames();
  }

  /// 进入/退出批量模式
  void _toggleBatchMode() {
    setState(() {
      _isBatchMode = !_isBatchMode;
      if (!_isBatchMode) {
        _selectedIds.clear();
      }
    });
  }

  /// 全选/取消全选
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _games.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_games.map((g) => g.id));
      }
    });
  }

  /// 切换单个选中状态
  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// 批量删除
  void _batchDelete() {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要删除的记录')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除选中的 ${_selectedIds.length} 条对局记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // 使用批量删除，一次IO操作完成
              await MahjongStorage.deleteGames(_selectedIds);
              _selectedIds.clear();
              _loadGames();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('删除成功')),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 新建对局
  void _createNewGame() async {
    final result = await Navigator.push<MahjongGame>(
      context,
      MaterialPageRoute(
        builder: (_) => const MahjongGamePage(),
      ),
    );
    if (result != null) {
      await MahjongStorage.addGame(result);
      _loadGames();
    }
  }

  /// 打开已有对局
  void _openGame(MahjongGame game) async {
    final result = await Navigator.push<MahjongGame>(
      context,
      MaterialPageRoute(
        builder: (_) => MahjongGamePage(game: game),
      ),
    );
    if (result != null) {
      await MahjongStorage.updateGame(result);
      _loadGames();
    }
  }

  /// 删除对局
  void _deleteGame(MahjongGame game) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对局'),
        content: Text('确定删除这场对局吗？\n玩家：${game.playerNames.join("、")}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await MahjongStorage.deleteGame(game.id);
              _loadGames();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _isBatchMode
            ? Text('已选 ${_selectedIds.length} 项')
            : const Text('麻将计分器'),
        leading: _isBatchMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出批量操作',
                onPressed: _toggleBatchMode,
              )
            : null,
        actions: [
          if (_isBatchMode) ...[
            // 全选/取消全选
            IconButton(
              icon: Icon(
                _selectedIds.length == _games.length && _games.isNotEmpty
                    ? Icons.select_all
                    : Icons.deselect,
              ),
              tooltip: _selectedIds.length == _games.length ? '取消全选' : '全选',
              onPressed: _toggleSelectAll,
            ),
            // 批量删除
            IconButton(
              icon: const Icon(Icons.delete),
              tooltip: '删除选中',
              onPressed: _batchDelete,
            ),
          ] else ...[
            // 批量操作按钮
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '批量操作',
              onPressed: _toggleBatchMode,
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _games.isEmpty
                ? _buildEmptyState(theme)
                : _buildGameList(theme),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isBatchMode ? null : _createNewGame,
        tooltip: '新建对局',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 空状态提示
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.casino_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            '暂无对局记录',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角 + 开始新对局',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  /// 对局列表
  Widget _buildGameList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _games.length,
      itemBuilder: (context, index) {
        final game = _games[index];
        final scores = game.currentScores;
        final ranking = game.ranking;
        final isFinished = game.isFinished;
        final isSelected = _selectedIds.contains(game.id);

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            onTap: () {
              if (_isBatchMode) {
                _toggleSelect(game.id);
              } else {
                if (isFinished) {
                  // 已结束的对局：打开复盘页面
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MahjongReviewPage(game: game),
                    ),
                  );
                } else {
                  // 进行中的对局：打开对局页面继续
                  _openGame(game);
                }
              }
            },
            onLongPress: _isBatchMode ? null : () => _deleteGame(game),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部：复选框/时间 + 状态
                  Row(
                    children: [
                      if (_isBatchMode) ...[
                        Checkbox(
                          value: isSelected,
                          onChanged: (_) => _toggleSelect(game.id),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          _formatTime(game.createdAt),
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isFinished
                                  ? Colors.grey.shade200
                                  : Colors.green.shade50,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isFinished ? '已结束' : '进行中',
                              style: TextStyle(
                                fontSize: 11,
                                color: isFinished
                                    ? Colors.grey.shade600
                                    : Colors.green.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (isFinished) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.bar_chart, size: 14, color: Colors.blue),
                          ],
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 玩家分数展示（按排名）
                  ...ranking.map((idx) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            // 排名
                            SizedBox(
                              width: 20,
                              child: Text(
                                '${ranking.indexOf(idx) + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: ranking.indexOf(idx) == 0
                                      ? Colors.amber.shade700
                                      : Colors.grey,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 玩家名
                            SizedBox(
                              width: 60,
                              child: Text(
                                game.playerNames[idx],
                                style: const TextStyle(fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Spacer(),
                            // 分数
                            Text(
                              '${scores[idx]}',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: scores[idx] > 0
                                    ? Colors.red
                                    : scores[idx] < 0
                                        ? Colors.green
                                        : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      )),
                  // 底部：局数
                  const SizedBox(height: 6),
                  Text(
                    '共 ${game.rounds.length} 局',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
