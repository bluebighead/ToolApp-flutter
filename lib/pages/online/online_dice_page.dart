// 联机游戏页
// 与单人模式类似的掷骰子界面，增加联机模式标签、玩家状态列表、玩法选择、结果排行榜
// 房主可修改骰子参数和玩法，客人只能掷骰子
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/online_message.dart';
import '../../models/online_player.dart';
import '../../models/online_room.dart';
import '../../services/online_game_service.dart';
import '../../services/online_overlay_manager.dart';
import '../../utils/app_logger.dart';
import '../../utils/dice_history.dart';
import '../../widgets/dice_2d.dart';

class OnlineDicePage extends StatefulWidget {
  final OnlineGameService gameService;

  const OnlineDicePage({super.key, required this.gameService});

  @override
  State<OnlineDicePage> createState() => _OnlineDicePageState();
}

class _OnlineDicePageState extends State<OnlineDicePage>
    with WidgetsBindingObserver {
  static const String _logTag = 'OnlineDicePage';

  /// 当前房间状态
  OnlineRoom? _room;

  /// 是否正在掷骰子动画中
  bool _isRolling = false;

  /// 每个骰子的结果
  List<int?> _results = [];

  /// 是否显示结果排行榜
  bool _showRankings = false;

  /// 记录上一次房间状态，用于检测状态切换（仅在状态变化时重置骰子）
  RoomState? _previousState;

  /// 猜数字输入控制器
  final TextEditingController _guessController = TextEditingController();

  /// 当前玩家是否已确认猜数字
  bool get _hasGuessed {
    if (_room == null) return false;
    final myId = widget.gameService.myPlayerId;
    final me = _room!.players.where((p) => p.id == myId || (p.isHost && myId == 'host'));
    return me.isNotEmpty && me.first.guessNumber >= 0;
  }

  /// 猜数字范围：最小值（骰子个数 * 1）
  int get _guessMin => (_room?.diceCount ?? 1) * 1;

  /// 猜数字范围：最大值（骰子个数 * 骰子面数）
  int get _guessMax {
    if (_room == null) return 6;
    final diceType = DiceType.fromName(_room!.diceType);
    return _room!.diceCount * diceType.sides;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _room = widget.gameService.room;
    _previousState = _room?.state;
    // 根据当前房间状态恢复 UI：如果所有人都已掷完骰子，直接显示排行榜
    final players = _room?.players ?? [];
    final allFinished = players.isNotEmpty &&
        players.every((p) => p.status == PlayerStatus.finished);
    _showRankings = allFinished;
    // 恢复当前玩家的骰子结果（便于在返回页面后仍能看到自己掷出的点数）
    if (_showRankings || _room?.state == RoomState.finished) {
      final myId = widget.gameService.myPlayerId;
      final me = players.firstWhere(
        (p) => p.id == myId || (p.isHost && myId == 'host'),
        orElse: () => OnlinePlayer(id: '', name: ''),
      );
      if (me.results.isNotEmpty) {
        _results = List.from(me.results);
      } else {
        _results = List.filled(_room?.diceCount ?? 1, null);
      }
    } else {
      _results = List.filled(_room?.diceCount ?? 1, null);
    }
    widget.gameService.onRoomChanged = _onRoomChanged;
    widget.gameService.onRoomClosed = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('房主已关闭房间')),
      );
      OnlineOverlayManager().unregisterService();
      Navigator.of(context).popUntil((route) => route.isFirst);
    };
    // 掷骰动画同步回调（单人模式：非掷骰者收到 rollStart 时触发）
    widget.gameService.onRollStartSync = _onRollStartSync;
    // 注册到全局管理器
    OnlineOverlayManager().registerService(widget.gameService);
    OnlineOverlayManager().isInOnlinePage = true;
  }

  void _onRoomChanged(OnlineRoom room) {
    if (!mounted) return;
    AppLogger.d('_OnlineDicePageState',
        'onRoomChanged: state=${room.state}, diceType=${room.diceType}, diceCount=${room.diceCount}, players=${room.players.length}');

    // 检测状态是否发生变化
    final stateChanged = _previousState != room.state;

    setState(() {
      _room = room;

      // 如果骰子数量变了，重置结果
      if (_results.length != room.diceCount) {
        _results = List.filled(room.diceCount, null);
      }

      // 如果所有人都已完成，并且结果已经公布（state==finished），显示排行榜
      final allFinished =
          room.players.every((p) => p.status == PlayerStatus.finished);
      if (room.state == RoomState.finished && allFinished) {
        _showRankings = true;
        // 恢复当前玩家的骰子结果显示
        final myId = widget.gameService.myPlayerId;
        final me = room.players.firstWhere(
          (p) => p.id == myId || (p.isHost && myId == 'host'),
          orElse: () => OnlinePlayer(id: '', name: ''),
        );
        if (me.results.isNotEmpty) {
          _results = List.from(me.results);
        }
      } else if (stateChanged && room.state == RoomState.playing) {
        // 仅在状态切换到 playing 时（即新一轮开始），重置骰子为问号待抛状态
        // 避免在 playing 状态期间每次房间更新都清空已掷出的结果
        _showRankings = false;
        _results = List.filled(room.diceCount, null);
        _guessController.clear();
      }

      // 猜数字玩法：非掷骰者检测掷骰者的骰子结果，显示掷骰者的骰子
      // 仅在非动画状态且掷骰者已有结果时更新，避免覆盖正在播放的动画
      if (room.gameMode == GameMode.guessNumber &&
          room.state == RoomState.playing &&
          !_isRolling) {
        final isSingleMode = room.rollMode == RollMode.singlePlayer;
        final myId = widget.gameService.myPlayerId;
        final amRoller = room.rollerId == myId ||
            (myId == 'host' && room.rollerId == 'host');

        // 单人模式：非掷骰者显示掷骰者的骰子
        // 多人模式：非掷骰者不需要特殊处理（各自掷各自的）
        if (isSingleMode && !amRoller) {
          final roller = room.players
              .where((p) => p.id == room.rollerId)
              .firstOrNull;
          if (roller != null && roller.results.isNotEmpty) {
            _results = List.from(roller.results);
          }
        }
      }

      // 更新上一次状态
      _previousState = room.state;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _guessController.dispose();
    widget.gameService.onRoomChanged = null;
    widget.gameService.onRoomClosed = null;
    widget.gameService.onRollStartSync = null;
    // 离开页面时更新状态，用于显示悬浮按钮（如果房间仍存在）
    OnlineOverlayManager().isInOnlinePage = false;
    super.dispose();
  }

  /// 监听应用前后台切换
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    AppLogger.i(_logTag, '应用生命周期变化：$state');

    if (state == AppLifecycleState.paused) {
      // 应用进入后台：标记离开联机页面，显示悬浮按钮
      OnlineOverlayManager().isInOnlinePage = false;
      OnlineOverlayManager().tryShowFloatingButton();
    } else if (state == AppLifecycleState.resumed) {
      // 应用回到前台：如果当前页面仍在栈顶，标记回到联机页面
      if (mounted) {
        OnlineOverlayManager().isInOnlinePage = true;
      }
    }
  }

  /// 获取当前玩家的状态
  PlayerStatus get _myStatus {
    if (_room == null) return PlayerStatus.waiting;
    final myId = widget.gameService.myPlayerId;
    final me = _room!.players.where((p) => p.id == myId || (p.isHost && myId == 'host'));
    return me.isEmpty ? PlayerStatus.waiting : me.first.status;
  }

  /// 是否可以掷骰子
  /// 猜数字+单人模式：只有被选中的掷骰者且状态为 rolling 时可以掷骰子
  /// 猜数字+多人模式：所有人状态为 rolling 时都可以掷骰子
  /// 比大小玩法：所有人状态为 rolling 时都可以掷骰子
  bool get _canRoll {
    if (_isRolling || _room?.state != RoomState.playing) return false;
    if (_room!.gameMode == GameMode.guessNumber &&
        _room!.rollMode == RollMode.singlePlayer) {
      // 单人模式：只有被选中的掷骰者且状态为 rolling 才可以掷骰子
      // rollerId 为空表示还未选取掷骰者（猜数字阶段），不可掷骰
      if (_room!.rollerId.isEmpty) return false;
      final myId = widget.gameService.myPlayerId;
      final amRoller = _room!.rollerId == myId ||
          (myId == 'host' && _room!.rollerId == 'host');
      return amRoller && _myStatus == PlayerStatus.rolling;
    }
    return _myStatus == PlayerStatus.rolling;
  }

  /// 当前骰子类型
  DiceType get _currentDiceType {
    if (_room == null) return DiceType.d6;
    return DiceType.fromName(_room!.diceType);
  }

  /// 开始掷骰子
  Future<void> _rollDice() async {
    if (!_canRoll) return;

    // 猜数字+单人模式：掷骰者开始掷骰时，广播 rollStart 消息让其他玩家同步动画
    if (_room!.gameMode == GameMode.guessNumber &&
        _room!.rollMode == RollMode.singlePlayer) {
      final myId = widget.gameService.myPlayerId;
      final playerId = (myId == 'host') ? 'host' : myId!;
      // 通过 LanService 广播 rollStart
      widget.gameService.lan.broadcastToGuests(
        MessageBuilder.rollStart(playerId: playerId),
      );
    }

    setState(() {
      _isRolling = true;
      _results = List.filled(_room!.diceCount, null);
    });

    // 预计算每个骰子的结果
    final newResults = List.generate(
      _room!.diceCount,
      (_) => DiceHistory.roll(_currentDiceType),
    );

    // 等待动画完成
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    setState(() {
      _results = newResults;
      _isRolling = false;
    });

    final total = newResults.reduce((a, b) => a + b);

    // 提交结果
    if (widget.gameService.isHost) {
      widget.gameService.hostRoll(newResults, total);
    } else {
      widget.gameService.guestRoll(newResults, total);
    }

    AppLogger.i(_logTag, '掷骰子：${_currentDiceType.label} x${_room!.diceCount} -> $newResults (总计: $total)');
  }

  /// 掷骰动画同步回调（单人模式：非掷骰者收到 rollStart 时触发）
  /// 启动本地掷骰动画，但不提交结果（等待掷骰者的 rollResult）
  Future<void> _onRollStartSync() async {
    if (!mounted) return;

    setState(() {
      _isRolling = true;
      _results = List.filled(_room?.diceCount ?? 1, null);
    });

    // 等待动画完成（与掷骰者相同的动画时长）
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    // 动画结束后保持问号状态，等待掷骰者的实际结果
    setState(() {
      _isRolling = false;
    });
  }

  /// 提交猜数字
  void _submitGuess() {
    if (_room == null || _hasGuessed) return;
    final guess = int.tryParse(_guessController.text.trim());
    if (guess == null || guess < _guessMin || guess > _guessMax) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请输入 $_guessMin ~ $_guessMax 之间的数字')),
      );
      return;
    }

    // 提交猜数字
    if (widget.gameService.isHost) {
      widget.gameService.hostGuess(guess);
    } else {
      widget.gameService.guestGuess(guess);
    }

    AppLogger.i(_logTag, '猜数字：$guess');
  }

  /// 房主开始新一轮
  void _startNewRound() {
    widget.gameService.startRound();
    setState(() {
      _results = List.filled(_room?.diceCount ?? 1, null);
      _showRankings = false;
      _guessController.clear();
    });
  }

  /// 房主更新骰子类型
  void _updateDiceType(DiceType type) {
    AppLogger.d(_logTag, '房主修改骰子类型: ${type.label} (${type.name})');
    // 更新服务端参数并广播给客人
    widget.gameService.updateParams(diceType: type.name);
    // 直接从 game service 获取最新的 room 状态，确保房主端 UI 立即刷新
    setState(() {
      _room = widget.gameService.room;
      _results = List.filled(_room?.diceCount ?? 1, null);
      _showRankings = false;
    });
    AppLogger.d(_logTag, '骰子类型更新后, _room.diceType=${_room?.diceType}');
  }

  /// 房主更新骰子数量
  void _updateDiceCount(int count) {
    AppLogger.d(_logTag, '房主修改骰子数量: $count');
    // 更新服务端参数并广播给客人
    widget.gameService.updateParams(diceCount: count);
    // 直接从 game service 获取最新的 room 状态，确保房主端 UI 立即刷新
    setState(() {
      _room = widget.gameService.room;
      _results = List.filled(_room?.diceCount ?? 1, null);
      _showRankings = false;
    });
    AppLogger.d(_logTag, '骰子数量更新后, _room.diceCount=${_room?.diceCount}');
  }

  /// 房主更新玩法
  void _updateGameMode(GameMode mode) {
    AppLogger.d(_logTag, '房主修改玩法: ${mode.label} (${mode.value})');
    // 更新服务端参数并广播给客人
    widget.gameService.updateParams(gameMode: mode);
    // 直接从 game service 获取最新的 room 状态，确保房主端 UI 立即刷新
    setState(() {
      _room = widget.gameService.room;
      _results = List.filled(_room?.diceCount ?? 1, null);
      _showRankings = false;
    });
    AppLogger.d(_logTag, '玩法更新后, _room.gameMode=${_room?.gameMode.value}');
  }

  /// 房主更新掷骰模式
  void _updateRollMode(RollMode mode) {
    AppLogger.d(_logTag, '房主修改掷骰模式: ${mode.label} (${mode.value})');
    widget.gameService.updateParams(rollMode: mode);
    setState(() {
      _room = widget.gameService.room;
      _results = List.filled(_room?.diceCount ?? 1, null);
      _showRankings = false;
    });
  }

  /// 房主点击结束游戏
  Future<void> _onHostEndGame() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认结束游戏'),
        content: const Text('房间将被解散，所有玩家将被移出，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('结束游戏'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.gameService.closeRoom();
    OnlineOverlayManager().unregisterService();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// 客人点击退出房间
  Future<void> _onGuestLeave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退出房间'),
        content: const Text('退出后需要重新加入，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出房间'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.gameService.leaveRoom();
    OnlineOverlayManager().unregisterService();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHost = widget.gameService.isHost;

    if (_room == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 系统返回键触发：视为无意退出，仅导航离开，保留房间
        AppLogger.i(_logTag, '用户按返回键，导航离开但保留房间（后台化）');
        // 先标记即将离开联机页面，但延迟显示悬浮按钮，
        // 确保 Navigator.pop 完成后根 Overlay 可用
        OnlineOverlayManager().isInOnlinePage = false;
        Navigator.of(context).popUntil((route) => route.isFirst);
        // 等待下一帧确保路由切换完成后再尝试显示悬浮按钮
        WidgetsBinding.instance.addPostFrameCallback((_) {
          OnlineOverlayManager().tryShowFloatingButton();
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_room!.roomName),
              const SizedBox(width: 8),
              // 联机模式标签
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('联机模式',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          leading: IconButton(
            icon: Icon(isHost ? Icons.logout : Icons.exit_to_app),
            tooltip: isHost ? '结束游戏' : '退出房间',
            onPressed: isHost ? _onHostEndGame : _onGuestLeave,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isHost
                        ? Colors.orange.withValues(alpha: 0.15)
                        : Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isHost ? '房主' : '客人',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isHost ? Colors.orange : Colors.blue,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              // 参数区域（房主可修改）
              _buildParamsArea(),
              const SizedBox(height: 8),

              // 玩家状态列表
              _buildPlayerStatusList(),

              const SizedBox(height: 8),

              // 猜数字输入区域（仅在猜数字玩法 + 游戏进行中 + 有人还在猜数字阶段时显示）
              if (_room!.gameMode == GameMode.guessNumber &&
                  _room!.state == RoomState.playing &&
                  _room!.players.any((p) => p.status == PlayerStatus.guessing))
                _buildGuessInputArea(),

              // 骰子显示区域
              Expanded(
                child: _showRankings ? _buildRankings() : _buildDiceArea(),
              ),

              // 结果显示
              if (!_showRankings && _results.isNotEmpty && _results.every((r) => r != null) && !_isRolling)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '总计：${_results.whereType<int>().reduce((a, b) => a + b)} 点',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.primaryColor,
                    ),
                  ),
                ),

              // 底部按钮区域
              _buildBottomButtons(),

              // 底部提示
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '按返回键可将房间后台，再次进入可通过悬浮按钮',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建参数区域
  Widget _buildParamsArea() {
    final isHost = widget.gameService.isHost;
    final isGuessMode = _room!.gameMode == GameMode.guessNumber;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              // 骰子类型
              Expanded(
                child: _buildParamChip(
                  icon: Icons.category,
                  label: _currentDiceType.label,
                  onTap: isHost ? () => _showDiceTypePicker() : null,
                ),
              ),
              const SizedBox(width: 8),
              // 骰子数量
              Expanded(
                child: _buildParamChip(
                  icon: Icons.format_list_numbered,
                  label: '${_room!.diceCount}个',
                  onTap: isHost ? () => _showDiceCountPicker() : null,
                ),
              ),
              const SizedBox(width: 8),
              // 玩法
              Expanded(
                child: _buildParamChip(
                  icon: Icons.sports_esports,
                  label: _room!.gameMode.label,
                  onTap: isHost ? () => _showGameModePicker() : null,
                ),
              ),
              const SizedBox(width: 6),
              // 玩法说明按钮
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  onPressed: _showGameModeHelp,
                  icon: Icon(Icons.help_outline, size: 18, color: Colors.grey.shade600),
                  padding: EdgeInsets.zero,
                  tooltip: '玩法说明',
                ),
              ),
            ],
          ),
          // 掷骰模式（仅猜数字玩法显示）
          if (isGuessMode) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _buildParamChip(
                    icon: Icons.person_outline,
                    label: _room!.rollMode.label,
                    onTap: isHost ? () => _showRollModePicker() : null,
                  ),
                ),
                const SizedBox(width: 38), // 与上方对齐（帮助按钮的空间）
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 构建参数芯片
  Widget _buildParamChip({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 14, color: Colors.grey.shade400),
            ],
          ],
        ),
      ),
    );
  }

  /// 构建玩家状态列表
  Widget _buildPlayerStatusList() {
    final theme = Theme.of(context);
    final isGuessSingleMode = _room!.gameMode == GameMode.guessNumber &&
        _room!.rollMode == RollMode.singlePlayer;

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _room!.players.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, index) {
          final player = _room!.players[index];
          final isMe = player.id == widget.gameService.myPlayerId ||
              (player.isHost && widget.gameService.myPlayerId == 'host');
          final isRoller = isGuessSingleMode && player.id == _room!.rollerId;

          Color statusColor;
          IconData statusIcon;
          switch (player.status) {
            case PlayerStatus.waiting:
              statusColor = Colors.grey;
              statusIcon = Icons.hourglass_empty;
              break;
            case PlayerStatus.guessing:
              statusColor = player.guessNumber >= 0 ? Colors.green : Colors.purple;
              statusIcon = player.guessNumber >= 0 ? Icons.check_circle : Icons.edit;
              break;
            case PlayerStatus.rolling:
              statusColor = Colors.blue;
              statusIcon = Icons.casino;
              break;
            case PlayerStatus.finished:
              statusColor = Colors.green;
              statusIcon = Icons.check_circle;
              break;
          }

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isRoller
                  ? Colors.blue.withValues(alpha: 0.15)
                  : isMe
                      ? theme.primaryColor.withValues(alpha: 0.1)
                      : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(16),
              border: isRoller
                  ? Border.all(color: Colors.blue.withValues(alpha: 0.5))
                  : isMe
                      ? Border.all(color: theme.primaryColor.withValues(alpha: 0.3))
                      : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(statusIcon, size: 14, color: statusColor),
                const SizedBox(width: 4),
                Text(player.name,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: isMe || isRoller ? FontWeight.bold : FontWeight.normal)),
                if (player.isHost) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.star, size: 12, color: Colors.amber),
                ],
                // 单人掷骰模式：掷骰者标记
                if (isRoller) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.casino, size: 12, color: Colors.blue),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// 构建猜数字输入区域
  Widget _buildGuessInputArea() {
    final isGuessing = _myStatus == PlayerStatus.guessing && !_hasGuessed;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.purple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Icon(Icons.edit_note, size: 18, color: Colors.purple.shade700),
              const SizedBox(width: 6),
              Text(
                '猜数字',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.purple.shade700,
                ),
              ),
              const Spacer(),
              Text(
                '范围：$_guessMin ~ $_guessMax',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 输入行
          Row(
            children: [
              // 输入框
              Expanded(
                child: TextField(
                  controller: _guessController,
                  enabled: isGuessing,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: isGuessing ? '输入你猜的数字' : '已提交',
                    hintStyle: TextStyle(
                      color: isGuessing ? Colors.grey : Colors.green,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    suffixIcon: isGuessing
                        ? null
                        : Icon(Icons.check_circle, color: Colors.green, size: 20),
                  ),
                  onSubmitted: isGuessing ? (_) => _submitGuess() : null,
                ),
              ),
              const SizedBox(width: 8),
              // 确认按钮
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  onPressed: isGuessing ? _submitGuess : null,
                  icon: Icon(_hasGuessed ? Icons.check : Icons.send, size: 16),
                  label: Text(_hasGuessed ? '已确认' : '确认'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _hasGuessed ? Colors.green : Colors.purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // 已提交猜数字的玩家提示
          if (!_hasGuessed) ...[
            const SizedBox(height: 6),
            _buildGuessProgressHint(),
          ],
        ],
      ),
    );
  }

  /// 构建猜数字进度提示（显示已提交人数）
  Widget _buildGuessProgressHint() {
    final guessedCount = _room!.players.where((p) => p.guessNumber >= 0).length;
    final totalCount = _room!.players.length;
    return Text(
      '已提交：$guessedCount / $totalCount 人',
      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
    );
  }

  /// 构建骰子显示区域
  Widget _buildDiceArea() {
    final diceCount = _room!.diceCount;

    if (diceCount == 1) {
      return Center(
        child: SizedBox(
          width: 170,
          height: 170,
          child: Dice2D(
            diceType: _currentDiceType,
            result: _results.isNotEmpty ? _results[0] : null,
            isAnimating: _isRolling,
          ),
        ),
      );
    }

    final diceWidgets = List.generate(diceCount, (index) {
      return SizedBox(
        width: 85,
        height: 85,
        child: Dice2D(
          diceType: _currentDiceType,
          result: _results[index],
          isAnimating: _isRolling,
        ),
      );
    });

    const maxPerRow = 4;
    final rows = <Widget>[];
    for (int i = 0; i < diceWidgets.length; i += maxPerRow) {
      final end = (i + maxPerRow < diceWidgets.length)
          ? i + maxPerRow
          : diceWidgets.length;
      rows.add(
        Wrap(
          spacing: 14,
          runSpacing: 18,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: diceWidgets.sublist(i, end),
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: rows
              .expand((row) => [const SizedBox(height: 18), row])
              .skip(1)
              .toList(),
        ),
      ),
    );
  }

  /// 构建结果排行榜
  Widget _buildRankings() {
    final theme = Theme.of(context);
    final isGuessMode = _room!.gameMode == GameMode.guessNumber;

    // 猜数字玩法：按差距绝对值从小到大排序（差距最小者获胜）
    // 比大小玩法：按总点数从小到大排序
    final sorted = List<OnlinePlayer>.from(_room!.players);
    if (isGuessMode) {
      sorted.sort((a, b) {
        final diffA = (a.guessNumber - a.total).abs();
        final diffB = (b.guessNumber - b.total).abs();
        return diffA.compareTo(diffB);
      });
    } else {
      sorted.sort((a, b) => a.total.compareTo(b.total));
    }

    // 猜数字玩法：差距最小者获胜（排名第一）
    // 比大小玩法：点数最大者标绿，最小者标红
    final minTotal = sorted.first.total;
    final maxTotal = sorted.last.total;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本轮结果（第 ${_room!.roundNumber} 轮）',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: sorted.length,
              itemBuilder: (ctx, index) {
                final player = sorted[index];

                Color bgColor;
                IconData badgeIcon;
                String badgeText;
                if (isGuessMode) {
                  // 猜数字玩法：排名第一（差距最小）为胜者
                  if (index == 0) {
                    bgColor = Colors.green.withValues(alpha: 0.1);
                    badgeIcon = Icons.emoji_events;
                    badgeText = '胜者';
                  } else {
                    bgColor = Colors.grey.shade50;
                    badgeIcon = Icons.person;
                    badgeText = '';
                  }
                } else {
                  // 比大小玩法
                  final isMax = player.total == maxTotal && sorted.length > 1;
                  final isMin = player.total == minTotal && sorted.length > 1;
                  if (isMax) {
                    bgColor = Colors.green.withValues(alpha: 0.1);
                    badgeIcon = Icons.emoji_events;
                    badgeText = '最大';
                  } else if (isMin) {
                    bgColor = Colors.red.withValues(alpha: 0.1);
                    badgeIcon = Icons.remove_circle;
                    badgeText = '最小';
                  } else {
                    bgColor = Colors.grey.shade50;
                    badgeIcon = Icons.person;
                    badgeText = '';
                  }
                }

                final isWinner = isGuessMode && index == 0;

                return Card(
                  color: bgColor,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isWinner
                          ? Colors.green
                          : (badgeText == '最大'
                              ? Colors.green
                              : badgeText == '最小'
                                  ? Colors.red
                                  : Colors.grey.shade300),
                      child: Icon(badgeIcon,
                          color: Colors.white, size: 20),
                    ),
                    title: Row(
                      children: [
                        Text(player.name,
                            style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: isWinner
                                    ? Colors.green.shade800
                                    : (badgeText == '最大'
                                        ? Colors.green.shade800
                                        : badgeText == '最小'
                                            ? Colors.red.shade800
                                            : null))),
                        if (badgeText.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: isWinner
                                  ? Colors.green.withValues(alpha: 0.2)
                                  : (badgeText == '最大'
                                      ? Colors.green.withValues(alpha: 0.2)
                                      : Colors.red.withValues(alpha: 0.2)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(badgeText,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isWinner
                                        ? Colors.green.shade800
                                        : (badgeText == '最大'
                                            ? Colors.green.shade800
                                            : Colors.red.shade800))),
                          ),
                        ],
                      ],
                    ),
                    subtitle: isGuessMode
                        ? Text(
                            '猜：${player.guessNumber}  实际：${player.total}  差距：${(player.guessNumber - player.total).abs()}',
                            style: const TextStyle(fontSize: 12),
                          )
                        : Text(
                            '骰子：${player.results.join(', ')}',
                            style: const TextStyle(fontSize: 12),
                          ),
                    trailing: isGuessMode
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('差距',
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.grey.shade500)),
                              Text('${(player.guessNumber - player.total).abs()}',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: isWinner
                                          ? Colors.green.shade800
                                          : theme.primaryColor)),
                            ],
                          )
                        : Text('${player.total} 点',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: badgeText == '最大'
                                    ? Colors.green.shade800
                                    : badgeText == '最小'
                                        ? Colors.red.shade800
                                        : theme.primaryColor)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 构建底部按钮
  Widget _buildBottomButtons() {
    final isHost = widget.gameService.isHost;

    // 如果显示排行榜，房主显示"开始新一轮"按钮
    if (_showRankings) {
      if (isHost) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _startNewRound,
              icon: const Icon(Icons.refresh),
              label: const Text('开始新一轮', style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        );
      } else {
        return const Padding(
          padding: EdgeInsets.fromLTRB(32, 0, 32, 8),
          child: Text('等待房主开始新一轮...',
              style: TextStyle(color: Colors.grey)),
        );
      }
    }

    // 掷骰子按钮
    final isGuessMode = _room?.gameMode == GameMode.guessNumber;
    final isSingleMode = _room?.rollMode == RollMode.singlePlayer;
    final myId = widget.gameService.myPlayerId;
    final amRoller = _room?.rollerId == myId ||
        (myId == 'host' && _room?.rollerId == 'host');
    final isFinished = _room?.state == RoomState.finished;

    String buttonText;
    if (isFinished) {
      // 本轮已结束，判断谁可以开启下一轮
      if (isGuessMode && isSingleMode && amRoller) {
        // 猜数字+单人模式：掷骰者可以开启下一轮
        buttonText = '开始下一轮';
      } else if (isGuessMode && isSingleMode && !amRoller) {
        // 猜数字+单人模式：非掷骰者等待掷骰者开启下一轮
        final rollerName = _room!.players
            .where((p) => p.id == _room!.rollerId)
            .firstOrNull
            ?.name ?? '掷骰者';
        buttonText = '等待 $rollerName 开始下一轮...';
      } else if (isHost) {
        // 比大小或多人模式：房主开启下一轮
        buttonText = '开始下一轮';
      } else {
        buttonText = '等待房主开始下一轮...';
      }
    } else if (_room?.state != RoomState.playing) {
      // 首轮：房主可以开始游戏
      buttonText = isHost ? '开始游戏' : '等待房主开始...';
    } else if (_myStatus == PlayerStatus.guessing) {
      // 猜数字玩法：正在猜数字阶段
      buttonText = _hasGuessed ? '已猜数字，等待掷骰子...' : '请先输入猜测数字';
    } else if (isGuessMode && isSingleMode && _myStatus == PlayerStatus.waiting) {
      // 猜数字+单人模式：非掷骰者等待掷骰者掷骰子
      final rollerName = _room!.players
          .where((p) => p.id == _room!.rollerId)
          .firstOrNull
          ?.name ?? '掷骰者';
      buttonText = '等待 $rollerName 掷骰子...';
    } else if (_myStatus == PlayerStatus.finished) {
      buttonText = '已掷骰子，等待其他玩家...';
    } else {
      buttonText = '开始掷骰子';
    }

    // 判断按钮是否可点击
    final canPress = _canRoll ||
        (isHost && _room?.state != RoomState.playing && !isFinished) ||
        (isFinished && isGuessMode && isSingleMode && amRoller) ||
        (isFinished && !isGuessMode && isHost) ||
        (isFinished && isGuessMode && !isSingleMode && isHost);

    AppLogger.d('_OnlineDicePageState',
        '按钮状态: state=${_room?.state}, isHost=$isHost, myStatus=$_myStatus, canPress=$canPress, amRoller=$amRoller');

    // 按钮点击回调
    VoidCallback? onPressed;
    if (canPress) {
      if (isFinished) {
        // 本轮结束后的点击：开启下一轮
        if (isGuessMode && isSingleMode && amRoller && !isHost) {
          // 客人端掷骰者：发送请求给房主
          onPressed = () => widget.gameService.requestStartRound();
        } else {
          // 房主（任何模式）或单人模式房主是掷骰者：直接开始
          onPressed = () => widget.gameService.startRound();
        }
      } else if (isHost && _room?.state != RoomState.playing) {
        // 首轮开始
        onPressed = () => widget.gameService.startRound();
      } else if (_canRoll) {
        // 掷骰子
        onPressed = _rollDice;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(_isRolling ? Icons.hourglass_empty : Icons.casino),
          label: Text(buttonText, style: const TextStyle(fontSize: 18)),
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }

  /// 显示骰子类型选择器（房主）
  void _showDiceTypePicker() {
    // 临时变量存储用户的选择，点击确认才生效
    DiceType tempSelected = _currentDiceType;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('骰子类型',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    // 点击确认后才真正更新
                    _updateDiceType(tempSelected);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          // 选择器
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: DiceType.values.indexOf(_currentDiceType),
              ),
              onSelectedItemChanged: (index) {
                // 只记录临时选择，不立即更新
                tempSelected = DiceType.values[index];
              },
              children: DiceType.values
                  .map((t) => Center(
                      child: Text(t.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示骰子数量选择器（房主）
  void _showDiceCountPicker() {
    // 临时变量存储用户的选择，点击确认才生效
    int tempCount = _room!.diceCount;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('骰子数量',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    // 点击确认后才真正更新
                    _updateDiceCount(tempCount);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          // 选择器
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: _room!.diceCount - 1,
              ),
              onSelectedItemChanged: (index) {
                // 只记录临时选择，不立即更新
                tempCount = index + 1;
              },
              children: List.generate(
                20,
                (i) => Center(
                    child: Text('${i + 1}',
                        style: const TextStyle(fontSize: 20))),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示玩法选择器（房主）
  void _showGameModePicker() {
    // 临时变量存储用户的选择，点击确认才生效
    GameMode tempMode = _room!.gameMode;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('玩法',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    // 点击确认后才真正更新
                    _updateGameMode(tempMode);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          // 选择器
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: GameMode.values.indexOf(_room!.gameMode),
              ),
              onSelectedItemChanged: (index) {
                // 只记录临时选择，不立即更新
                tempMode = GameMode.values[index];
              },
              children: GameMode.values
                  .map((m) => Center(
                      child: Text(m.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示掷骰模式选择器（房主，仅猜数字玩法）
  void _showRollModePicker() {
    RollMode tempMode = _room!.rollMode;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('掷骰模式',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    _updateRollMode(tempMode);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          // 选择器
          SizedBox(
            height: 160,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: RollMode.values.indexOf(_room!.rollMode),
              ),
              onSelectedItemChanged: (index) {
                tempMode = RollMode.values[index];
              },
              children: RollMode.values
                  .map((m) => Center(
                      child: Text(m.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示当前玩法说明
  void _showGameModeHelp() {
    if (_room == null) return;

    final mode = _room!.gameMode;
    String title;
    String content;

    switch (mode) {
      case GameMode.compareSize:
        title = '比大小玩法';
        content = '所有玩家同时掷骰子，比较各自的总点数。\n\n'
            '规则：\n'
            '1. 房主点击"开始游戏"后，所有玩家进入掷骰子阶段\n'
            '2. 每位玩家点击"开始掷骰子"完成投掷\n'
            '3. 所有人掷完后显示排行榜\n'
            '4. 总点数最大的玩家为胜者，最小的玩家为败者';
        break;
      case GameMode.guessNumber:
        final isSingleMode = _room!.rollMode == RollMode.singlePlayer;
        title = '猜数字玩法';
        if (isSingleMode) {
          content = '每位玩家先猜测骰子的总点数，再由随机选中的\n'
              '一名玩家掷骰子，猜测与实际点数差距最小者获胜。\n\n'
              '规则：\n'
              '1. 房主点击"开始游戏"后，所有玩家进入猜数字阶段\n'
              '2. 每位玩家在输入框中输入猜测的数字\n'
              '   （范围：$_guessMin ~ $_guessMax）\n'
              '3. 所有人猜完后，系统随机选中一名玩家掷骰子\n'
              '   （被选中的玩家会有骰子图标标注）\n'
              '4. 其他玩家屏幕同步显示掷骰动画和结果\n'
              '5. 按猜测与实际点数的差距绝对值排名\n'
              '6. 差距最小的玩家为胜者';
        } else {
          content = '每位玩家先猜测骰子的总点数，再各自掷骰子，\n'
              '猜测与自己掷出的点数差距最小者获胜。\n\n'
              '规则：\n'
              '1. 房主点击"开始游戏"后，所有玩家进入猜数字阶段\n'
              '2. 每位玩家在输入框中输入猜测的数字\n'
              '   （范围：$_guessMin ~ $_guessMax）\n'
              '3. 所有人猜完后，所有玩家进入掷骰子阶段\n'
              '4. 每位玩家点击"开始掷骰子"完成投掷\n'
              '5. 按猜测与自己实际点数的差距绝对值排名\n'
              '6. 差距最小的玩家为胜者';
        }
        break;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.sports_esports, color: Theme.of(ctx).primaryColor, size: 22),
            const SizedBox(width: 8),
            Flexible(child: Text(title, style: const TextStyle(fontSize: 18))),
          ],
        ),
        content: Text(content, style: const TextStyle(fontSize: 14, height: 1.6)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
