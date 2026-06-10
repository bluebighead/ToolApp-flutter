// 麻将对局页面
// 核心页面：显示4人分数、排名、记分弹窗、局记录、分享战绩
import 'package:flutter/material.dart';

import '../utils/app_logger.dart';
import '../utils/mahjong_model.dart';
import 'mahjong_review_page.dart';

class MahjongGamePage extends StatefulWidget {
  /// 传入已有对局则编辑，null 则新建
  final MahjongGame? game;

  const MahjongGamePage({super.key, this.game});

  @override
  State<MahjongGamePage> createState() => _MahjongGamePageState();
}

class _MahjongGamePageState extends State<MahjongGamePage> {
  /// 是否为新建模式
  late bool _isNewGame;

  /// 对局 ID
  late String _gameId;

  /// 4位玩家名称
  late List<String> _playerNames;

  /// 初始分数
  late int _initialScore;

  /// 底分
  late int _baseScore;

  /// 对局记录
  late List<MahjongRound> _rounds;

  /// 创建时间
  late DateTime _createdAt;

  /// 是否已结束
  late bool _isFinished;

  /// 新建对局时：玩家名输入控制器
  final List<TextEditingController> _nameControllers = List.generate(
    4,
    (i) => TextEditingController(text: '玩家${i + 1}'),
  );

  /// 初始分数输入控制器
  final _initialScoreController = TextEditingController(text: '0');

  /// 底分输入控制器
  final _baseScoreController = TextEditingController(text: '1');

  /// 新建对局步骤：0=设置玩家数量，1=设置玩家名称，2=游戏中
  int _setupStep = 0;

  /// 玩家数量（1-4）
  int _playerCount = 4;

  @override
  void initState() {
    super.initState();
    _isNewGame = widget.game == null;

    if (_isNewGame) {
      _gameId = DateTime.now().millisecondsSinceEpoch.toString();
      _playerCount = 4;
      _playerNames = ['玩家1', '玩家2', '玩家3', '玩家4'];
      _initialScore = 0;
      _baseScore = 1;
      _rounds = [];
      _createdAt = DateTime.now();
      _isFinished = false;
      _setupStep = 0;
    } else {
      final g = widget.game!;
      _gameId = g.id;
      _playerCount = g.playerCount;
      // 确保 _playerNames 始终有4个元素，不足的用默认值填充
      _playerNames = List.generate(4, (i) => i < g.playerNames.length ? g.playerNames[i] : '玩家${i + 1}');
      _initialScore = g.initialScore;
      _baseScore = g.baseScore;
      _rounds = List.from(g.rounds);
      _createdAt = g.createdAt;
      _isFinished = g.isFinished;
      _setupStep = 2; // 已有对局直接进入游戏

      // 初始化控制器（只初始化实际玩家数量的控制器）
      for (int i = 0; i < _playerCount; i++) {
        _nameControllers[i].text = _playerNames[i];
      }
      _initialScoreController.text = _initialScore.toString();
      _baseScoreController.text = _baseScore.toString();
    }
  }

  @override
  void dispose() {
    for (final c in _nameControllers) {
      c.dispose();
    }
    _initialScoreController.dispose();
    _baseScoreController.dispose();
    super.dispose();
  }

  /// 获取当前对局对象
  MahjongGame get _currentGame => MahjongGame(
        id: _gameId,
        playerCount: _playerCount,
        playerNames: _playerNames.sublist(0, _playerCount),
        initialScore: _initialScore,
        baseScore: _baseScore,
        rounds: _rounds,
        createdAt: _createdAt,
        isFinished: _isFinished,
      );

  /// 计算当前分数
  List<int> get _scores => _currentGame.currentScores;

  /// 排名
  List<int> get _ranking => _currentGame.ranking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 新建对局：先设置玩家数量和详细信息
    if (_setupStep < 2) {
      return _buildSetupPage(theme);
    }

    // 游戏进行中
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 拦截返回键，保存当前对局数据后返回上一页
        Navigator.of(context).pop(_currentGame);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('第 ${_rounds.length + 1} 局'),
          actions: [
            // 右侧菜单
            if (!_isFinished)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'finish') {
                    _finishGame();
                  } else if (value == 'undo') {
                    _undoLastRound();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'undo',
                    child: Row(
                      children: [
                        Icon(Icons.undo, size: 18),
                        SizedBox(width: 8),
                        Text('撤销上一局'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'finish',
                    child: Row(
                      children: [
                        Icon(Icons.stop_circle, size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('结束对局', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: _buildGameBody(theme),
        // 底部记分按钮
        bottomNavigationBar: _isFinished ? null : _buildBottomButtons(theme),
      ),
    );
  }

  // ============================================================
  // 设置页面（新建对局时）
  // ============================================================

  Widget _buildSetupPage(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('新建对局'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 步骤0：选择玩家数量
            if (_setupStep == 0) ...[
              Text('玩家数量', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _playerCount,
                    isExpanded: true,
                    items: [1, 2, 3, 4].map((count) {
                      return DropdownMenuItem(
                        value: count,
                        child: Text('$count 人'),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setState(() {
                          _playerCount = v;
                          // 确保 _playerNames 有足够的元素
                          while (_playerNames.length < _playerCount) {
                            _playerNames.add('玩家${_playerNames.length + 1}');
                          }
                        });
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    setState(() => _setupStep = 1);
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('下一步', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
            // 步骤1：设置玩家名称和对局参数
            if (_setupStep == 1) ...[
              // 玩家名称设置
              Text('玩家名称', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              ...List.generate(_playerCount, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    // 东南西北标识
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _playerColor(i).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        ['东', '南', '西', '北'][i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: _playerColor(i),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _nameControllers[i],
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hintText: '输入名称',
                        ),
                        onChanged: (v) => _playerNames[i] = v.trim().isEmpty ? '玩家${i + 1}' : v.trim(),
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 16),
              // 初始分数
              Text('初始分数', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _initialScoreController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  hintText: '0',
                ),
                onChanged: (v) => _initialScore = int.tryParse(v) ?? 0,
              ),
              const SizedBox(height: 16),
              // 底分
              Text('底分（番数算分基础单位）', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _baseScoreController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  hintText: '1',
                ),
                onChanged: (v) => _baseScore = (int.tryParse(v) ?? 1).clamp(1, 100),
              ),
              const SizedBox(height: 24),
              // 开始按钮
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    // 更新玩家名
                    for (int i = 0; i < _playerCount; i++) {
                      _playerNames[i] = _nameControllers[i].text.trim().isEmpty
                          ? '玩家${i + 1}'
                          : _nameControllers[i].text.trim();
                    }
                    _initialScore = int.tryParse(_initialScoreController.text) ?? 0;
                    _baseScore = (int.tryParse(_baseScoreController.text) ?? 1).clamp(1, 100);
                    setState(() => _setupStep = 2);
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('开始对局', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 游戏主体
  // ============================================================

  Widget _buildGameBody(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // 4人分数卡片
          _buildScoreCards(theme),
          const SizedBox(height: 12),
          // 局记录列表
          if (_rounds.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('对局记录', style: theme.textTheme.titleSmall),
                Text(
                  '共 ${_rounds.length} 局',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ..._rounds.asMap().entries.map((entry) => _buildRoundItem(theme, entry.key, entry.value)),
          ],
        ],
      ),
    );
  }

  /// 玩家分数卡片
  Widget _buildScoreCards(ThemeData theme) {
    final scores = _scores;
    final ranking = _ranking;

    return Row(
      children: List.generate(_playerCount, (i) {
        final idx = ranking[i];
        final score = scores[idx];
        final color = _playerColor(idx);

        return Expanded(
          child: GestureDetector(
            onTap: () => _editPlayerName(idx),
            child: Card(
              elevation: i == 0 ? 3 : 1,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: i == 0
                    ? BorderSide(color: Colors.amber.shade400, width: 2)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                child: Column(
                  children: [
                    // 排名标识
                    if (i == 0)
                      Icon(Icons.emoji_events, size: 16, color: Colors.amber.shade600)
                    else
                      Text('${i + 1}', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    const SizedBox(height: 4),
                    // 方位
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        ['东', '南', '西', '北'][idx],
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 玩家名
                    Text(
                      _playerNames[idx],
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    // 分数
                    Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: score > 0
                            ? Colors.red
                            : score < 0
                                ? Colors.green
                                : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  /// 编辑玩家名称
  void _editPlayerName(int playerIndex) {
    final controller = TextEditingController(text: _playerNames[playerIndex]);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('修改玩家名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            hintText: '输入名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = controller.text.trim();
              controller.dispose();
              if (newName.isNotEmpty) {
                setState(() => _playerNames[playerIndex] = newName);
              }
              Navigator.pop(ctx);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  /// 局记录条目
  Widget _buildRoundItem(ThemeData theme, int index, MahjongRound round) {
    // 类型标签
    String typeLabel;
    Color typeColor;
    switch (round.type) {
      case RoundType.manual:
        typeLabel = '手动';
        typeColor = Colors.blue;
        break;
      case RoundType.selfDraw:
        typeLabel = '自摸';
        typeColor = Colors.orange;
        break;
      case RoundType.discard:
        typeLabel = '点炮';
        typeColor = Colors.purple;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：局号 + 类型
            Row(
              children: [
                Text(
                  '第 ${index + 1} 局',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: typeColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    typeLabel,
                    style: TextStyle(fontSize: 10, color: typeColor, fontWeight: FontWeight.w500),
                  ),
                ),
                const Spacer(),
                // 番数显示
                if (round.type != RoundType.manual && round.fans > 0)
                  Text(
                    '${round.fans}番',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 分差展示（带玩家名）
            Row(
              children: List.generate(_playerCount, (i) {
                final change = round.scoreChanges[i];
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        _playerNames[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        change == 0 ? '-' : '${change > 0 ? '+' : ''}$change',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: change > 0
                              ? Colors.red
                              : change < 0
                                  ? Colors.green
                                  : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部记分按钮
  Widget _buildBottomButtons(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // 手动记分
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _showManualScoreDialog,
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('手动记分'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 番数算分
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _showFanScoreDialog,
              icon: const Icon(Icons.calculate, size: 18),
              label: const Text('番数算分'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 手动记分弹窗
  // ============================================================

  void _showManualScoreDialog() {
    final controllers = List.generate(_playerCount, (_) => TextEditingController());
    // 记录每位玩家的正负状态：null=未选择，true=正，false=负
    final signStates = List<bool?>.filled(_playerCount, null);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('手动记分'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(_playerCount, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _playerNames[i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: _playerColor(i),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // 负号按钮
                          SizedBox(
                            width: 40,
                            child: OutlinedButton(
                              onPressed: () {
                                final current = controllers[i].text;
                                final num = int.tryParse(current) ?? 0;
                                controllers[i].text = (-num.abs()).toString();
                                setDialogState(() {
                                  signStates[i] = false;
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: signStates[i] == false ? Colors.green.shade100 : null,
                                foregroundColor: Colors.green,
                                side: BorderSide(
                                  color: signStates[i] == false ? Colors.green : Colors.green.shade300,
                                  width: signStates[i] == false ? 2 : 1,
                                ),
                              ),
                              child: const Text('−', style: TextStyle(fontSize: 18)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 输入框
                          Expanded(
                            child: TextField(
                              controller: controllers[i],
                              keyboardType: const TextInputType.numberWithOptions(signed: true),
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                hintText: '0',
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 正号按钮
                          SizedBox(
                            width: 40,
                            child: OutlinedButton(
                              onPressed: () {
                                final current = controllers[i].text;
                                final num = int.tryParse(current) ?? 0;
                                controllers[i].text = num.abs().toString();
                                setDialogState(() {
                                  signStates[i] = true;
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: signStates[i] == true ? Colors.red.shade50 : null,
                                foregroundColor: Colors.red,
                                side: BorderSide(
                                  color: signStates[i] == true ? Colors.red : Colors.red.shade300,
                                  width: signStates[i] == true ? 2 : 1,
                                ),
                              ),
                              child: const Text('+', style: TextStyle(fontSize: 18)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final c in controllers) {
                  c.dispose();
                }
                Navigator.pop(ctx);
              },
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final changes = List.generate(_playerCount, (i) {
                  return int.tryParse(controllers[i].text);
                });

                // 统计有多少玩家手动输入了分数
                final inputCount = changes.where((v) => v != null).length;

                List<int> finalChanges;

                if (inputCount == 0) {
                  // 没有输入任何分数，提示用户
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请至少输入一名玩家的分数')),
                  );
                  return;
                } else if (inputCount == 1) {
                  // 只输入了一个玩家的分数，其余玩家平均分摊
                  final winnerIdx = changes.indexWhere((v) => v != null);
                  final winnerScore = changes[winnerIdx]!;
                  // 输家需要分摊的总金额（与赢家分差相反）
                  final totalLoserAmount = -winnerScore;
                  final loserCount = _playerCount - 1;

                  if (loserCount == 0) {
                    // 只有1人，无法分摊
                    finalChanges = [winnerScore];
                  } else {
                    final loserScore = totalLoserAmount ~/ loserCount;
                    final remainder = totalLoserAmount % loserCount; // 余数处理

                    finalChanges = List<int>.filled(_playerCount, 0);
                    finalChanges[winnerIdx] = winnerScore;
                    int loserIdx = 0;
                    for (int i = 0; i < _playerCount; i++) {
                      if (i != winnerIdx) {
                        // 余数依次分配给前几个输家（每人最多分1，保证总和正确）
                        finalChanges[i] = loserScore + (loserIdx < remainder ? 1 : 0);
                        loserIdx++;
                      }
                    }
                  }
                } else {
                  // 输入了多个玩家的分数，校验总和是否为0
                  final filledChanges = changes.map((v) => v ?? 0).toList();
                  final sum = filledChanges.reduce((a, b) => a + b);
                  if (sum != 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('多人输入时，分差之和必须为0，当前为 $sum')),
                    );
                    return;
                  }
                  finalChanges = filledChanges;
                }

                _addRound(MahjongRound(
                  type: RoundType.manual,
                  scoreChanges: finalChanges,
                  time: DateTime.now(),
                ));
                for (final c in controllers) {
                  c.dispose();
                }
                Navigator.pop(ctx);
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 番数算分弹窗
  // ============================================================

  void _showFanScoreDialog() {
    int? winnerIndex;
    int? discarderIndex;
    int selectedFans = 1;
    bool isSelfDraw = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('番数算分'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 胡牌方式
                Text('胡牌方式', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('自摸'),
                      selected: isSelfDraw,
                      onSelected: (_) => setDialogState(() => isSelfDraw = true),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('点炮'),
                      selected: !isSelfDraw,
                      onSelected: (_) => setDialogState(() => isSelfDraw = false),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 胡牌者
                Text('胡牌者', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: List.generate(_playerCount, (i) => ChoiceChip(
                    label: Text(_playerNames[i]),
                    selected: winnerIndex == i,
                    onSelected: (_) => setDialogState(() => winnerIndex = i),
                  )),
                ),
                // 点炮者
                if (!isSelfDraw) ...[
                  const SizedBox(height: 12),
                  Text('点炮者', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: List.generate(_playerCount, (i) => ChoiceChip(
                      label: Text(_playerNames[i]),
                      selected: discarderIndex == i,
                      onSelected: i != winnerIndex
                          ? (_) => setDialogState(() => discarderIndex = i)
                          : null,
                    )),
                  ),
                ],
                const SizedBox(height: 12),
                // 番数选择
                Text('番数', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: kDefaultFanTypes.map((ft) => ChoiceChip(
                    label: Text(ft.name),
                    selected: selectedFans == ft.fans,
                    onSelected: (_) => setDialogState(() => selectedFans = ft.fans),
                  )).toList(),
                ),
                const SizedBox(height: 8),
                // 预览分差
                if (winnerIndex != null) ...[
                  const Divider(),
                  Text('预计分差：', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  ...List.generate(_playerCount, (i) {
                    List<int> preview;
                    if (isSelfDraw) {
                      preview = MahjongCalculator.selfDrawScore(
                        winnerIndex: winnerIndex!,
                        fans: selectedFans,
                        baseScore: _baseScore,
                        playerCount: _playerCount,
                      );
                    } else {
                      preview = MahjongCalculator.discardScore(
                        winnerIndex: winnerIndex!,
                        discarderIndex: discarderIndex ?? 0,
                        fans: selectedFans,
                        baseScore: _baseScore,
                        playerCount: _playerCount,
                      );
                    }
                    final change = preview[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          SizedBox(width: 60, child: Text(_playerNames[i], style: const TextStyle(fontSize: 13))),
                          Text(
                            change == 0 ? '-' : '${change > 0 ? '+' : ''}$change',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: change > 0 ? Colors.red : change < 0 ? Colors.green : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: winnerIndex == null || (!isSelfDraw && discarderIndex == null) || (!isSelfDraw && discarderIndex == winnerIndex)
                  ? null
                  : () {
                      List<int> changes;
                      if (isSelfDraw) {
                        changes = MahjongCalculator.selfDrawScore(
                          winnerIndex: winnerIndex!,
                          fans: selectedFans,
                          baseScore: _baseScore,
                          playerCount: _playerCount,
                        );
                      } else {
                        changes = MahjongCalculator.discardScore(
                          winnerIndex: winnerIndex!,
                          discarderIndex: discarderIndex!,
                          fans: selectedFans,
                          baseScore: _baseScore,
                          playerCount: _playerCount,
                        );
                      }
                      _addRound(MahjongRound(
                        type: isSelfDraw ? RoundType.selfDraw : RoundType.discard,
                        scoreChanges: changes,
                        fans: selectedFans,
                        winnerIndex: winnerIndex,
                        discarderIndex: isSelfDraw ? null : discarderIndex,
                        time: DateTime.now(),
                      ));
                      Navigator.pop(ctx);
                    },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 操作方法
  // ============================================================

  /// 添加一局记录
  void _addRound(MahjongRound round) {
    setState(() {
      _rounds.add(round);
    });
    // 每次添加局记录时自动持久化，防止App被杀死导致数据丢失
    MahjongStorage.saveGame(_currentGame);
    AppLogger.i('MahjongGame', '添加局记录：${round.type}, 分差=${round.scoreChanges}');
  }

  /// 撤销上一局
  void _undoLastRound() {
    if (_rounds.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销'),
        content: const Text('确定撤销上一局记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _rounds.removeLast());
              // 撤销后自动持久化
              MahjongStorage.saveGame(_currentGame);
              Navigator.pop(ctx);
            },
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
  }

  /// 结束对局
  void _finishGame() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束对局'),
        content: const Text('确定结束这场对局吗？结束后将跳转到复盘页面。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              setState(() => _isFinished = true);
              Navigator.pop(ctx);
              // 立即保存到存储
              await MahjongStorage.saveGame(_currentGame);
              AppLogger.i('MahjongGame', '对局已结束，已保存');
              // 跳转到复盘页面
              if (!mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => MahjongReviewPage(game: _currentGame),
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('结束'),
          ),
        ],
      ),
    );
  }

  /// 玩家颜色
  Color _playerColor(int index) {
    const colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
    ];
    return colors[index.clamp(0, 3)];
  }
}
