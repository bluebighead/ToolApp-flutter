// 联机掷骰子游戏逻辑服务
// 管理房间状态、玩家列表、游戏流程
// 分为房主逻辑和客人逻辑两个模式
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/online_message.dart';
import '../models/online_player.dart';
import '../models/online_room.dart';
import '../utils/app_logger.dart';
import 'lan_service.dart';

/// 游戏服务角色
enum GameRole { host, guest }

/// 房间状态变更回调
typedef OnRoomChanged = void Function(OnlineRoom room);

/// 联机游戏服务
class OnlineGameService {
  static const String _logTag = 'OnlineGameService';
  static const String _playerNameKey = 'online_player_name';

  /// 通信服务
  final LanService _lan = LanService();

  /// 当前角色
  GameRole? _role;

  /// 当前房间状态
  OnlineRoom? _room;

  /// 当前玩家 ID
  String? _myPlayerId;

  /// 房间状态变更回调
  OnRoomChanged? onRoomChanged;

  /// 掷骰动画同步回调（单人模式：非掷骰者收到 rollStart 时触发）
  VoidCallback? onRollStartSync;

  /// 被踢出回调
  VoidCallback? onKicked;

  /// 房间关闭回调
  VoidCallback? onRoomClosed;

  /// 获取当前房间
  OnlineRoom? get room => _room;

  /// 获取当前角色
  GameRole? get role => _role;

  /// 获取当前玩家 ID
  String? get myPlayerId => _myPlayerId;

  /// 是否为房主
  bool get isHost => _role == GameRole.host;

  /// 获取通信服务（用于发送配对码回应等）
  LanService get lan => _lan;

  /// 获取玩家名称（从 SharedPreferences）
  static Future<String> getPlayerName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_playerNameKey) ?? '';
  }

  /// 保存玩家名称
  static Future<void> savePlayerName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playerNameKey, name);
  }

  // ==================== 房主逻辑 ====================

  /// 房主创建房间
  Future<bool> createRoom({
    required String roomName,
    required int maxPlayers,
    required String diceType,
    required int diceCount,
    required GameMode gameMode,
    RollMode rollMode = RollMode.multiPlayer,
  }) async {
    _role = GameRole.host;
    _myPlayerId = 'host';

    // 先清理可能残留的旧房间资源（防止旧 UDP 广播仍在运行）
    await _lan.closeServer();

    // 生成 4 位数字配对码
    final random = Random();
    final roomCode = List.generate(4, (_) => random.nextInt(10)).join();

    // 获取本机 IP
    final hostIp = await _getLocalIp();

    // 创建房间
    _room = OnlineRoom(
      roomCode: roomCode,
      roomName: roomName,
      maxPlayers: maxPlayers,
      diceType: diceType,
      diceCount: diceCount,
      gameMode: gameMode,
      rollMode: rollMode,
      hostIp: hostIp,
      hostPort: _lan.tcpPort,
      players: [
        OnlinePlayer(
          id: _myPlayerId!,
          name: '房主',
          isHost: true,
        ),
      ],
    );

    // 启动 TCP 服务端
    final serverOk = await _lan.startServer();
    if (!serverOk) return false;

    // 设置房主端消息回调
    _lan.onHostTcpMessage = _onHostReceivedMessage;
    _lan.onClientDisconnected = _onClientDisconnected;

    // 启动 UDP 广播
    _startRoomBroadcast();

    AppLogger.i(_logTag, '房间已创建：$roomCode, 房间名：$roomName');
    onRoomChanged?.call(_room!);
    return true;
  }

  /// 启动房间广播
  void _startRoomBroadcast() {
    if (_room == null) return;

    // 先设置 UDP 消息回调，再启动广播
    // 确保回调在 UDP socket 开始监听前就设置好
    _lan.onUdpMessage = (msg, fromIp, fromPort) {
      if (msg.type == MessageType.codeQuery) {
        final queryCode = msg.data['roomCode'] as String? ?? '';
        if (queryCode == _room!.roomCode) {
          // 回应配对码查询（发送到查询者的源端口）
          final response = MessageBuilder.codeResponse(
            roomCode: _room!.roomCode,
            hostIp: _room!.hostIp,
            hostPort: _room!.hostPort,
          );
          _lan.sendCodeResponse(fromIp, fromPort, response);
        }
      }
    };

    // 使用消息生成回调，每次广播时获取最新房间信息
    _lan.startBroadcasting(() {
      if (_room == null) {
        return MessageBuilder.roomBroadcast(
          roomCode: '',
          roomName: '',
          currentPlayers: 0,
          maxPlayers: 0,
          diceType: '',
          diceCount: 0,
          gameMode: '',
          hostIp: '',
          hostPort: 0,
        );
      }
      return MessageBuilder.roomBroadcast(
        roomCode: _room!.roomCode,
        roomName: _room!.roomName,
        currentPlayers: _room!.currentPlayers,
        maxPlayers: _room!.maxPlayers,
        diceType: _room!.diceType,
        diceCount: _room!.diceCount,
        gameMode: _room!.gameMode.value,
        hostIp: _room!.hostIp,
        hostPort: _room!.hostPort,
      );
    });
  }

  /// 房主收到客人消息
  void _onHostReceivedMessage(OnlineMessage message, String playerId) {
    AppLogger.i(_logTag, '房主收到消息：${message.type} 来自 $playerId');

    switch (message.type) {
      case MessageType.joinRoom:
        _handleJoinRoom(playerId, message);
        break;
      case MessageType.rollResult:
        _handleRollResult(message);
        break;
      case MessageType.rollStart:
        _handleRollStart(message);
        break;
      case MessageType.guessSubmit:
        _handleGuessSubmit(message);
        break;
      case MessageType.leaveRoom:
        _removePlayer(playerId);
        break;
      default:
        AppLogger.d(_logTag, '房主忽略未处理的消息类型：${message.type} 来自 $playerId');
        break;
    }
  }

  /// 处理客人加入请求
  void _handleJoinRoom(String playerId, OnlineMessage message) {
    if (_room == null) return;
    final playerName = message.data['playerName'] as String? ?? '未知';

    if (_room!.isFull) {
      _lan.sendToPlayer(
        playerId,
        MessageBuilder.joinResult(
          success: false,
          message: '房间已满',
          roomInfo: {},
          players: [],
        ),
      );
      return;
    }

    // 检查同名玩家，若重名则添加后缀
    var uniqueName = playerName;
    var suffix = 2;
    while (_room!.players.any((p) => p.name == uniqueName)) {
      uniqueName = '$playerName$suffix';
      suffix++;
    }

    // 使用唯一名称作为 playerId，避免 Socket 映射冲突
    // 如果游戏正在进行中，新加入的玩家也可以掷骰子
    final newPlayer = OnlinePlayer(
      id: uniqueName,
      name: uniqueName,
      isHost: false,
      status: _room!.state == RoomState.playing
          ? PlayerStatus.rolling
          : PlayerStatus.waiting,
    );
    final updatedPlayers = [..._room!.players, newPlayer];
    // 仅在游戏未开始时更新房间状态（避免覆盖 playing/finished 状态）
    RoomState newState = _room!.state;
    if (_room!.state == RoomState.waiting || _room!.state == RoomState.ready) {
      newState = updatedPlayers.length >= _room!.maxPlayers
          ? RoomState.ready
          : RoomState.waiting;
    }
    _room = _room!.copyWith(
      players: updatedPlayers,
      state: newState,
    );

    // 发送加入成功消息给该客人（包含分配的 playerId）
    _lan.sendToPlayer(
      playerId,
      MessageBuilder.joinResult(
        success: true,
        message: '加入成功',
        roomInfo: _room!.toJson(),
        players: _room!.players.map((e) => e.toJson()).toList(),
        assignedPlayerId: uniqueName,
      ),
    );

    // 更新 Socket 映射：将 tempId 替换为 uniqueName
    _lan.renameClientKey(playerId, uniqueName);

    // 广播新玩家加入消息给其他客人（排除刚加入的客人，其已通过 joinResult 获知房间信息）
    _lan.broadcastToGuestsExcept(
      uniqueName,
      MessageBuilder.playerJoined(
        playerId: uniqueName,
        playerName: uniqueName,
        currentPlayers: _room!.currentPlayers,
      ),
    );

    // 更新广播消息
    _updateBroadcast();

    AppLogger.i(_logTag,
        '玩家 $playerName 加入房间，当前 ${_room!.currentPlayers}/${_room!.maxPlayers}');
    onRoomChanged?.call(_room!);
  }

  /// 客人断开连接
  void _onClientDisconnected(String playerId) {
    AppLogger.i(_logTag, '玩家 $playerId 断开连接');
    _removePlayer(playerId);
  }

  /// 移除玩家
  void _removePlayer(String playerId) {
    if (_room == null) return;
    final updatedPlayers =
        _room!.players.where((p) => p.id != playerId).toList();

    // 根据当前游戏状态决定新状态：
    // - 游戏进行中/本轮结束时，保持当前状态不变（避免游戏被意外重置）
    // - 等待/就绪状态时，根据人数更新
    RoomState newState = _room!.state;
    if (_room!.state == RoomState.waiting || _room!.state == RoomState.ready) {
      newState = updatedPlayers.length >= _room!.maxPlayers
          ? RoomState.ready
          : RoomState.waiting;
    }

    _room = _room!.copyWith(
      players: updatedPlayers,
      state: newState,
    );

    // 通知其他客人
    _lan.broadcastToGuests(
      MessageBuilder.playerLeft(
        playerId: playerId,
        currentPlayers: _room!.currentPlayers,
      ),
    );

    _updateBroadcast();
    onRoomChanged?.call(_room!);
  }

  /// 更新 UDP 广播消息
  /// 游戏开始后停止广播，本轮结束后重启广播（让新玩家能发现房间）
  void _updateBroadcast() {
    if (_room == null) return;
    if (_room!.state == RoomState.playing) {
      _lan.stopBroadcasting();
    } else if (_room!.state == RoomState.finished ||
        _room!.state == RoomState.waiting ||
        _room!.state == RoomState.ready) {
      // 非游戏中状态，确保广播正在运行（本轮结束后重启广播）
      if (!_lan.isBroadcasting) {
        _startRoomBroadcast();
      }
    }
  }

  /// 房主更新游戏参数
  void updateParams({
    String? diceType,
    int? diceCount,
    GameMode? gameMode,
    RollMode? rollMode,
  }) {
    if (_room == null || !isHost) {
      AppLogger.w(_logTag, 'updateParams 失败：_room为空或不是房主');
      return;
    }
    final oldDiceType = _room!.diceType;
    final oldDiceCount = _room!.diceCount;
    final oldGameMode = _room!.gameMode.value;
    final newGameMode = gameMode ?? _room!.gameMode;
    final newRollMode = rollMode ?? _room!.rollMode;

    _room = _room!.copyWith(
      diceType: diceType ?? _room!.diceType,
      diceCount: diceCount ?? _room!.diceCount,
      gameMode: newGameMode,
      rollMode: newRollMode,
    );

    // 游戏进行中切换玩法时，需要重置玩家状态以匹配新玩法
    if (_room!.state == RoomState.playing) {
      final isGuessMode = newGameMode == GameMode.guessNumber;
      final initialStatus = isGuessMode ? PlayerStatus.guessing : PlayerStatus.rolling;

      final resetPlayers = _room!.players
          .map((p) => p.copyWith(
                status: initialStatus,
                results: [],
                total: 0,
                guessNumber: -1,
              ))
          .toList();

      _room = _room!.copyWith(
        players: resetPlayers,
        rollerId: '', // 切换玩法时重置掷骰者
      );
    }

    AppLogger.i(_logTag,
        '参数更新：骰子类型 $oldDiceType -> ${_room!.diceType}, 数量 $oldDiceCount -> ${_room!.diceCount}, 玩法 $oldGameMode -> ${_room!.gameMode.value}, 掷骰模式 ${_room!.rollMode.value}');

    // 广播参数更新（包含玩家状态重置）
    _lan.broadcastToGuests(
      MessageBuilder.paramsUpdate(
        diceType: _room!.diceType,
        diceCount: _room!.diceCount,
        gameMode: _room!.gameMode.value,
        rollMode: _room!.rollMode.value,
      ),
    );

    // 如果游戏中切换了玩法，还需要广播玩家状态重置
    if (_room!.state == RoomState.playing) {
      _lan.broadcastToGuests(
        MessageBuilder.guessConfirmed(
          players: _room!.players.map((e) => e.toJson()).toList(),
        ),
      );
    }

    AppLogger.i(_logTag, '参数更新已广播，onRoomChanged回调：${onRoomChanged != null ? '有' : '无'}');
    onRoomChanged?.call(_room!);
  }

  /// 房主开始新一轮（人数未满也可以开始）
  void startRound() {
    if (_room == null || !isHost) {
      AppLogger.w(_logTag, 'startRound 失败：_room为空或不是房主');
      return;
    }

    // 仅在非游戏中状态允许开始新一轮，防止重复开始导致数据丢失
    if (_room!.state == RoomState.playing) {
      AppLogger.w(_logTag, 'startRound 失败：当前正在游戏中，不能重复开始');
      return;
    }

    AppLogger.i(_logTag, '开始新一轮，当前玩家数：${_room!.currentPlayers}，状态：${_room!.state}');

    // 猜数字玩法：初始状态为 guessing（猜数字中），比大小玩法：初始状态为 rolling（掷骰子中）
    final isGuessMode = _room!.gameMode == GameMode.guessNumber;
    final initialStatus = isGuessMode ? PlayerStatus.guessing : PlayerStatus.rolling;

    // 重置所有玩家状态
    final resetPlayers = _room!.players
        .map((p) => p.copyWith(
              status: initialStatus,
              results: [],
              total: 0,
              guessNumber: -1,
            ))
        .toList();

    _room = _room!.copyWith(
      players: resetPlayers,
      state: RoomState.playing,
      roundNumber: _room!.roundNumber + 1,
      rollerId: '', // 重置掷骰者 ID，等待猜数字阶段结束后重新随机选取
    );

    // 广播开始新一轮
    _lan.broadcastToGuests(
      MessageBuilder.startRound(roundNumber: _room!.roundNumber),
    );

    AppLogger.i(_logTag,
        '新一轮开始，roundNumber=${_room!.roundNumber}, 已广播，onRoomChanged回调：${onRoomChanged != null ? '有' : '无'}');
    onRoomChanged?.call(_room!);
  }

  /// 处理玩家掷骰子结果
  /// 房主端：更新客人状态，转发给其他客人，检查是否所有人完成
  /// 客人端：更新房主状态，仅刷新 UI
  void _handleRollResult(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final results =
        (message.data['results'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [];
    final total = message.data['total'] as int? ?? 0;

    // 检查 playerId 是否在玩家列表中
    final playerExists = _room!.players.any((p) => p.id == playerId);
    if (!playerExists) {
      AppLogger.w(_logTag, '收到未知玩家 $playerId 的掷骰结果，当前玩家列表：${_room!.players.map((p) => p.id).toList()}');
      return;
    }

    final isGuessMode = _room!.gameMode == GameMode.guessNumber;
    final isSingleMode = _room!.rollMode == RollMode.singlePlayer;

    // 更新玩家状态
    final updatedPlayers = _room!.players.map((p) {
      if (p.id == playerId) {
        return p.copyWith(
          status: PlayerStatus.finished,
          results: results,
          total: total,
        );
      }
      // 猜数字+单人模式：非掷骰者收到掷骰结果时，同步掷骰者的结果并标记为已完成
      if (isGuessMode && isSingleMode && p.id != playerId) {
        return p.copyWith(
          status: PlayerStatus.finished,
          results: results,
          total: total,
        );
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);

    // 房主端：转发给其他客人，并检查是否所有人完成
    if (isHost) {
      // 转发给除发送者外的其他客人，让所有客人都能看到完成标记
      _lan.broadcastToGuestsExcept(playerId, message);

      // 猜数字+单人模式：掷骰者掷完后直接广播结果
      if (isGuessMode && isSingleMode) {
        _broadcastResults();
      } else {
        final allFinished =
            _room!.players.every((p) => p.status == PlayerStatus.finished);
        if (allFinished) {
          _broadcastResults();
        }
      }
    }

    onRoomChanged?.call(_room!);
  }

  /// 处理掷骰动画同步消息（房主端转发+自身触发，客人端触发动画）
  void _handleRollStart(OnlineMessage message) {
    final playerId = message.data['playerId'] as String? ?? '';
    AppLogger.i(_logTag, '收到掷骰动画同步：玩家 $playerId 开始掷骰子');

    if (isHost) {
      // 房主端：转发给其他客人（排除掷骰者自己）
      _lan.broadcastToGuestsExcept(playerId, message);
      // 房主端：如果自己不是掷骰者，也需要触发同步动画
      if (_room != null && _room!.rollerId != 'host') {
        onRollStartSync?.call();
      }
    } else {
      // 客人端：触发同步动画
      onRollStartSync?.call();
    }
  }

  /// 房主自己掷骰子
  /// 猜数字+单人模式：房主掷骰子后，所有玩家直接标记为已完成
  /// 猜数字+多人模式：仅房主标记为已完成，客人各自掷骰子
  /// 比大小玩法：仅房主标记为已完成，客人各自掷骰子
  void hostRoll(List<int> results, int total) {
    if (_room == null || !isHost) return;

    final isGuessMode = _room!.gameMode == GameMode.guessNumber;
    final isSingleMode = _room!.rollMode == RollMode.singlePlayer;

    final updatedPlayers = _room!.players.map((p) {
      if (p.isHost) {
        return p.copyWith(
          status: PlayerStatus.finished,
          results: results,
          total: total,
        );
      }
      // 猜数字+单人模式+房主是掷骰者：非掷骰者客人同步掷骰结果并标记为已完成
      if (isGuessMode && isSingleMode && _room!.rollerId == 'host') {
        return p.copyWith(
          status: PlayerStatus.finished,
          results: results,
          total: total,
        );
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);

    // 通知客人房主已完成掷骰子，让客人端能显示房主的完成标记
    _lan.broadcastToGuests(
      MessageBuilder.rollResult(
        playerId: 'host',
        results: results,
        total: total,
      ),
    );

    // 猜数字+单人模式且房主是掷骰者：房主掷完后直接广播结果
    // 其他情况：检查是否所有玩家都完成了
    if (isGuessMode && isSingleMode && _room!.rollerId == 'host') {
      _broadcastResults();
    } else {
      final allFinished =
          _room!.players.every((p) => p.status == PlayerStatus.finished);
      if (allFinished) {
        _broadcastResults();
      }
    }

    onRoomChanged?.call(_room!);
  }

  /// 处理玩家提交猜数字（房主端）
  void _handleGuessSubmit(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final guessNumber = message.data['guessNumber'] as int? ?? -1;

    AppLogger.i(_logTag, '收到猜数字：玩家 $playerId 猜 $guessNumber');

    // 更新玩家猜数字
    final updatedPlayers = _room!.players.map((p) {
      if (p.id == playerId) {
        return p.copyWith(guessNumber: guessNumber);
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);

    // 广播猜数字确认（让所有玩家看到谁已提交）
    _lan.broadcastToGuests(
      MessageBuilder.guessConfirmed(
        players: _room!.players.map((e) => e.toJson()).toList(),
      ),
    );

    // 检查是否所有人都已猜数字，如果是则自动切换到掷骰子阶段
    _checkAllGuessed();

    onRoomChanged?.call(_room!);
  }

  /// 房主提交猜数字
  void hostGuess(int guessNumber) {
    if (_room == null || !isHost) return;

    final updatedPlayers = _room!.players.map((p) {
      if (p.isHost) {
        return p.copyWith(guessNumber: guessNumber);
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);

    // 广播猜数字确认（让所有玩家看到谁已提交）
    _lan.broadcastToGuests(
      MessageBuilder.guessConfirmed(
        players: _room!.players.map((e) => e.toJson()).toList(),
      ),
    );

    // 检查是否所有人都已猜数字，如果是则自动切换到掷骰子阶段
    _checkAllGuessed();

    onRoomChanged?.call(_room!);
  }

  /// 检查是否所有人都已猜数字，如果是则自动切换到掷骰子阶段
  /// 多人掷骰模式：所有玩家进入掷骰子阶段
  /// 单人掷骰模式：随机选一名玩家掷骰子，其余玩家等待
  void _checkAllGuessed() {
    if (_room == null) return;
    final allGuessed = _room!.players.every((p) => p.guessNumber >= 0);
    if (!allGuessed) return;

    final isSingleMode = _room!.rollMode == RollMode.singlePlayer;

    if (isSingleMode) {
      // 单人掷骰模式：随机选择一名玩家掷骰子
      final random = Random();
      final rollerIndex = random.nextInt(_room!.players.length);
      final roller = _room!.players[rollerIndex];
      AppLogger.i(_logTag, '单人掷骰模式：随机选中玩家 ${roller.name}（${roller.id}）掷骰子');

      final updatedPlayers = _room!.players.map((p) {
        if (p.id == roller.id) {
          return p.copyWith(status: PlayerStatus.rolling);
        } else {
          return p.copyWith(status: PlayerStatus.waiting);
        }
      }).toList();
      _room = _room!.copyWith(players: updatedPlayers, rollerId: roller.id);
    } else {
      // 多人掷骰模式：所有玩家进入掷骰子阶段
      AppLogger.i(_logTag, '多人掷骰模式：所有玩家进入掷骰子阶段');

      final updatedPlayers = _room!.players
          .map((p) => p.copyWith(status: PlayerStatus.rolling))
          .toList();
      _room = _room!.copyWith(players: updatedPlayers, rollerId: '');
    }

    // 广播状态切换（通过 guessConfirmed 消息携带更新后的玩家列表）
    _lan.broadcastToGuests(
      MessageBuilder.guessConfirmed(
        players: _room!.players.map((e) => e.toJson()).toList(),
      ),
    );
  }

  /// 客人提交猜数字
  void guestGuess(int guessNumber) {
    if (_room == null || isHost || _myPlayerId == null) return;
    _lan.sendToHost(
      MessageBuilder.guessSubmit(
        playerId: _myPlayerId!,
        guessNumber: guessNumber,
      ),
    );

    // 更新本地状态
    final updatedPlayers = _room!.players.map((p) {
      if (p.id == _myPlayerId) {
        return p.copyWith(guessNumber: guessNumber);
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);
    onRoomChanged?.call(_room!);
  }

  /// 广播所有结果（排行榜）
  void _broadcastResults() {
    if (_room == null) return;

    // 将房间状态标记为"本轮结束"，便于 UI 判断显示排行榜
    _room = _room!.copyWith(state: RoomState.finished);

    // 猜数字+单人模式：所有玩家使用掷骰者的实际点数进行比较
    if (_room!.gameMode == GameMode.guessNumber &&
        _room!.rollMode == RollMode.singlePlayer) {
      final roller = _room!.players.firstWhere(
        (p) => p.id == _room!.rollerId,
        orElse: () => _room!.players.first,
      );
      // 将掷骰者的结果同步给所有玩家
      final updatedPlayers = _room!.players.map((p) {
        return p.copyWith(
          results: roller.results,
          total: roller.total,
        );
      }).toList();
      _room = _room!.copyWith(players: updatedPlayers);
    }

    // 猜数字玩法：按猜测与实际点数的差距绝对值从小到大排序（差距最小者获胜）
    // 比大小玩法：按总点数从大到小排序（点数大的排名靠前）
    final sorted = List<OnlinePlayer>.from(_room!.players);
    if (_room!.gameMode == GameMode.guessNumber) {
      sorted.sort((a, b) {
        final diffA = (a.guessNumber - a.total).abs();
        final diffB = (b.guessNumber - b.total).abs();
        return diffA.compareTo(diffB);
      });
    } else {
      sorted.sort((a, b) => b.total.compareTo(a.total));
    }

    final rankings = sorted.asMap().entries.map((entry) {
      final map = <String, dynamic>{
        'rank': entry.key + 1,
        'playerId': entry.value.id,
        'playerName': entry.value.name,
        'results': entry.value.results,
        'total': entry.value.total,
      };
      // 猜数字玩法额外携带猜测数和差距
      if (_room!.gameMode == GameMode.guessNumber) {
        map['guessNumber'] = entry.value.guessNumber;
        map['diff'] = (entry.value.guessNumber - entry.value.total).abs();
      }
      return map;
    }).toList();

    _lan.broadcastToGuests(MessageBuilder.allResults(rankings: rankings));
    onRoomChanged?.call(_room!);
  }

  /// 关闭房间（房主）
  /// 房主退出时直接关闭房间，通知所有客人房间已关闭
  /// 注：房主迁移功能在当前 P2P 架构下不可靠（其他客人无法自动重连到新房主），
  /// 因此采用直接关闭房间的方案，确保行为可预测
  Future<void> closeRoom() async {
    if (_room != null && isHost) {
      // 通知所有客人房间关闭
      _lan.broadcastToGuests(MessageBuilder.roomClosed());
      await _lan.closeServer();
      _room = null;
      _role = null;
      _myPlayerId = null;
      // 清理回调，防止引用已销毁的 Widget
      onRoomChanged = null;
      onRoomClosed = null;
      onKicked = null;
      AppLogger.i(_logTag, '房间已关闭');
    }
  }

  // ==================== 客人逻辑 ====================

  /// 客人通过配对码加入房间
  Future<bool> joinByCode(String roomCode, String playerName) async {
    _role = GameRole.guest;
    _myPlayerId = playerName;

    // 通过 UDP 查询房主地址（IP + 端口）
    final hostAddr = await _lan.queryByCode(roomCode);
    if (hostAddr == null) {
      AppLogger.w(_logTag, '配对码 $roomCode 未找到房间');
      return false;
    }

    return _connectAndJoin(hostAddr.hostIp, playerName, hostPort: hostAddr.hostPort);
  }

  /// 客人通过搜索结果加入房间
  Future<bool> joinBySearch(
      String hostIp, int hostPort, String playerName) async {
    _role = GameRole.guest;
    _myPlayerId = playerName;
    return _connectAndJoin(hostIp, playerName, hostPort: hostPort);
  }

  /// 连接房主并加入房间
  /// [hostPort] 指定房主 TCP 端口，默认 19876
  Future<bool> _connectAndJoin(
    String hostIp,
    String playerName, {
    int hostPort = 19876,
  }) async {
    AppLogger.i(_logTag, '尝试连接房主 TCP: $hostIp:$hostPort');
    // 首次连接时暂时使用 playerName 作为心跳 playerId，
    // 收到 joinResult 的 assignedPlayerId 后会更新（见下方处理）
    final connected = await _lan.connectToHost(hostIp, port: hostPort, playerId: playerName);
    if (!connected) return false;

    // 使用 Completer 等待 joinResult
    final completer = Completer<bool>();

    // 设置客人端消息回调
    _lan.onGuestTcpMessage = (message) {
      if (message.type == MessageType.joinResult && !completer.isCompleted) {
        final success = message.data['success'] as bool? ?? false;
        if (success) {
          // 处理加入成功（同时会更新 _myPlayerId 为房主分配的 assignedPlayerId）
          _onGuestReceivedMessage(message);
          // 关键：更新 lan_service 的 guestPlayerId，后续心跳携带正确的 playerId
          _lan.updateGuestPlayerId(_myPlayerId);
          completer.complete(true);
        } else {
          completer.complete(false);
        }
        return;
      }
      _onGuestReceivedMessage(message);
    };

    _lan.onHostDisconnected = () {
      if (!completer.isCompleted) {
        // 加入过程中断开：完成 completer 并返回 false
        completer.complete(false);
      } else {
        // 加入成功后断开：触发房间关闭回调
        onRoomClosed?.call();
      }
    };

    // 发送加入请求
    _lan.sendToHost(MessageBuilder.joinRoom(playerName: playerName));

    // 超时处理
    Future.delayed(const Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    return completer.future;
  }

  /// 客人收到房主消息
  void _onGuestReceivedMessage(OnlineMessage message) {
    AppLogger.i(_logTag, '客人收到消息：${message.type}');

    switch (message.type) {
      case MessageType.joinResult:
        _handleJoinResult(message);
        break;
      case MessageType.playerJoined:
        _handlePlayerJoined(message);
        break;
      case MessageType.playerLeft:
        _handlePlayerLeft(message);
        break;
      case MessageType.paramsUpdate:
        _handleParamsUpdate(message);
        break;
      case MessageType.startRound:
        _handleStartRound(message);
        break;
      case MessageType.startRoundRequest:
        _handleStartRoundRequest(message);
        break;
      case MessageType.rollResult:
        _handleRollResult(message);
        break;
      case MessageType.rollStart:
        _handleRollStart(message);
        break;
      case MessageType.guessConfirmed:
        _handleGuessConfirmed(message);
        break;
      case MessageType.allResults:
        _handleAllResults(message);
        break;
      case MessageType.roomClosed:
        onRoomClosed?.call();
        break;
      case MessageType.hostMigrated:
        // 房主迁移功能已移除，收到此消息视为房间关闭
        AppLogger.w(_logTag, '收到房主迁移消息，但迁移功能已移除，视为房间关闭');
        _room = null;
        _role = null;
        _myPlayerId = null;
        onRoomClosed?.call();
        break;
      case MessageType.kickPlayer:
        // 被踢出后清理本地状态
        _room = null;
        _role = null;
        _myPlayerId = null;
        onKicked?.call();
        break;
      default:
        AppLogger.d(_logTag, '客人忽略未处理的消息类型：${message.type}');
        break;
    }
  }

  /// 处理加入结果
  void _handleJoinResult(OnlineMessage message) {
    final success = message.data['success'] as bool? ?? false;
    if (success) {
      // 更新为房主分配的实际 playerId（可能因重名而添加后缀）
      final assignedId = message.data['assignedPlayerId'] as String?;
      if (assignedId != null) {
        _myPlayerId = assignedId;
      }

      final roomInfo =
          message.data['roomInfo'] as Map<String, dynamic>? ?? {};
      final playersList = message.data['players'] as List<dynamic>? ?? [];
      final players = playersList
          .map((e) => OnlinePlayer.fromJson(e as Map<String, dynamic>))
          .toList();

      _room = OnlineRoom.fromJson(roomInfo).copyWith(players: players);
      onRoomChanged?.call(_room!);
      AppLogger.i(_logTag, '加入房间成功：${_room?.roomName}，分配 ID：$_myPlayerId');
    } else {
      AppLogger.w(_logTag, '加入房间失败：${message.data['message']}');
      // 加入失败时清理本地状态（不应调用 onRoomClosed，因为从未真正加入房间）
      _room = null;
      _role = null;
      _myPlayerId = null;
    }
  }

  /// 处理新玩家加入通知
  void _handlePlayerJoined(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final playerName = message.data['playerName'] as String? ?? '';

    // 避免重复添加
    if (!_room!.players.any((p) => p.id == playerId)) {
      final newPlayer = OnlinePlayer(id: playerId, name: playerName);
      final updatedPlayers = [..._room!.players, newPlayer];

      // 更新房间状态：等待/就绪状态下根据人数切换
      RoomState newState = _room!.state;
      if (_room!.state == RoomState.waiting || _room!.state == RoomState.ready) {
        newState = updatedPlayers.length >= _room!.maxPlayers
            ? RoomState.ready
            : RoomState.waiting;
      }

      _room = _room!.copyWith(players: updatedPlayers, state: newState);
    }
    onRoomChanged?.call(_room!);
  }

  /// 处理玩家离开通知
  void _handlePlayerLeft(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final updatedPlayers =
        _room!.players.where((p) => p.id != playerId).toList();

    // 更新房间状态：等待/就绪状态下根据人数切换（与 _handlePlayerJoined 对称）
    RoomState newState = _room!.state;
    if (_room!.state == RoomState.waiting || _room!.state == RoomState.ready) {
      newState = updatedPlayers.length >= _room!.maxPlayers
          ? RoomState.ready
          : RoomState.waiting;
    }

    _room = _room!.copyWith(players: updatedPlayers, state: newState);
    onRoomChanged?.call(_room!);
  }

  /// 处理参数更新
  void _handleParamsUpdate(OnlineMessage message) {
    if (_room == null) {
      AppLogger.w(_logTag, '_handleParamsUpdate：_room 为空，忽略');
      return;
    }
    final newDiceType = message.data['diceType'] as String? ?? _room!.diceType;
    final newDiceCount = message.data['diceCount'] as int? ?? _room!.diceCount;
    final newGameMode = GameMode.fromValue(
        message.data['gameMode'] as String? ?? 'compare_size');
    final newRollMode = RollMode.fromValue(
        message.data['rollMode'] as String? ?? 'multi_player');

    AppLogger.i(_logTag,
        '客人收到参数更新：骰子类型 $newDiceType, 数量 $newDiceCount, 玩法 ${newGameMode.value}, 掷骰模式 ${newRollMode.value}');

    _room = _room!.copyWith(
      diceType: newDiceType,
      diceCount: newDiceCount,
      gameMode: newGameMode,
      rollMode: newRollMode,
    );

    // 游戏进行中切换玩法时，需要重置玩家状态以匹配新玩法
    // 房主会随后通过 guessConfirmed 消息广播重置后的玩家状态
    // 这里先根据新玩法预置玩家状态，避免 UI 显示不一致
    if (_room!.state == RoomState.playing) {
      final isGuessMode = newGameMode == GameMode.guessNumber;
      final initialStatus = isGuessMode ? PlayerStatus.guessing : PlayerStatus.rolling;

      final resetPlayers = _room!.players
          .map((p) => p.copyWith(
                status: initialStatus,
                results: [],
                total: 0,
                guessNumber: -1,
              ))
          .toList();

      _room = _room!.copyWith(
        players: resetPlayers,
        rollerId: '',
      );
    }

    onRoomChanged?.call(_room!);
  }

  /// 处理开始新一轮
  void _handleStartRound(OnlineMessage message) {
    if (_room == null) {
      AppLogger.w(_logTag, '_handleStartRound：_room 为空，忽略');
      return;
    }
    final roundNumber = message.data['roundNumber'] as int? ?? 0;
    AppLogger.i(_logTag, '客人收到开始新一轮：roundNumber=$roundNumber');

    // 猜数字玩法：初始状态为 guessing，比大小玩法：初始状态为 rolling
    final isGuessMode = _room!.gameMode == GameMode.guessNumber;
    final initialStatus = isGuessMode ? PlayerStatus.guessing : PlayerStatus.rolling;

    final resetPlayers = _room!.players
        .map((p) => p.copyWith(
              status: initialStatus,
              results: [],
              total: 0,
              guessNumber: -1,
            ))
        .toList();
    _room = _room!.copyWith(
      players: resetPlayers,
      state: RoomState.playing,
      roundNumber: roundNumber,
      rollerId: '', // 重置掷骰者 ID，等待猜数字阶段结束后重新随机选取
    );

    AppLogger.i(_logTag,
        '客人端房间状态已更新：state=${_room!.state}, roundNumber=${_room!.roundNumber}, 玩家数=${_room!.players.length}');
    onRoomChanged?.call(_room!);
  }

  /// 处理客人请求开始新一轮（单人模式掷骰者发起）
  /// 房主端验证请求者是否为上一轮的掷骰者，验证通过则开始新一轮
  void _handleStartRoundRequest(OnlineMessage message) {
    if (_room == null || !isHost) return;

    final playerId = message.data['playerId'] as String? ?? '';
    AppLogger.i(_logTag, '收到客人请求开始新一轮：playerId=$playerId, 当前rollerId=${_room!.rollerId}');

    // 验证请求者是否为上一轮的掷骰者
    if (_room!.rollerId != playerId) {
      AppLogger.w(_logTag, '拒绝开始新一轮请求：$playerId 不是上一轮掷骰者');
      return;
    }

    // 验证当前是否为结束状态
    if (_room!.state != RoomState.finished) {
      AppLogger.w(_logTag, '拒绝开始新一轮请求：当前状态不是 finished（${_room!.state}）');
      return;
    }

    AppLogger.i(_logTag, '验证通过，由掷骰者 $playerId 发起开始新一轮');
    startRound();
  }

  /// 处理猜数字确认（客人端）
  void _handleGuessConfirmed(OnlineMessage message) {
    if (_room == null) return;
    final playersList = message.data['players'] as List<dynamic>? ?? [];
    final updatedPlayers = playersList
        .map((e) => OnlinePlayer.fromJson(e as Map<String, dynamic>))
        .toList();

    // 从玩家状态推断 rollerId：单人模式下 status 为 rolling 的玩家就是掷骰者
    String rollerId = _room!.rollerId;
    if (_room!.gameMode == GameMode.guessNumber &&
        _room!.rollMode == RollMode.singlePlayer) {
      final roller = updatedPlayers.where((p) => p.status == PlayerStatus.rolling).firstOrNull;
      if (roller != null) {
        rollerId = roller.id;
      }
    }

    _room = _room!.copyWith(players: updatedPlayers, rollerId: rollerId);
    onRoomChanged?.call(_room!);
  }

  /// 处理所有结果
  void _handleAllResults(OnlineMessage message) {
    if (_room == null) return;
    final rankings = message.data['rankings'] as List<dynamic>? ?? [];

    // 更新玩家结果
    final updatedPlayers = _room!.players.map((p) {
      for (final r in rankings) {
        final rMap = r as Map<String, dynamic>;
        if (rMap['playerId'] == p.id) {
          return p.copyWith(
            status: PlayerStatus.finished,
            results: (rMap['results'] as List<dynamic>?)
                    ?.map((e) => e as int)
                    .toList() ??
                [],
            total: rMap['total'] as int? ?? 0,
            guessNumber: rMap['guessNumber'] as int? ?? p.guessNumber,
          );
        }
      }
      return p;
    }).toList();

    // 将房间状态标记为"本轮结束"
    _room = _room!.copyWith(
      players: updatedPlayers,
      state: RoomState.finished,
    );
    onRoomChanged?.call(_room!);
  }

  /// 客人提交掷骰子结果
  void guestRoll(List<int> results, int total) {
    if (_room == null || isHost || _myPlayerId == null) return;
    _lan.sendToHost(
      MessageBuilder.rollResult(
        playerId: _myPlayerId!,
        results: results,
        total: total,
      ),
    );

    // 更新本地状态
    final updatedPlayers = _room!.players.map((p) {
      if (p.id == _myPlayerId) {
        return p.copyWith(
          status: PlayerStatus.finished,
          results: results,
          total: total,
        );
      }
      return p;
    }).toList();
    _room = _room!.copyWith(players: updatedPlayers);
    onRoomChanged?.call(_room!);
  }

  /// 客人请求开始新一轮（单人模式掷骰者发起）
  void requestStartRound() {
    if (_room == null || isHost || _myPlayerId == null) return;
    AppLogger.i(_logTag, '客人请求开始新一轮：playerId=$_myPlayerId');
    _lan.sendToHost(
      MessageBuilder.startRoundRequest(playerId: _myPlayerId!),
    );
  }

  /// 客人离开房间
  Future<void> leaveRoom() async {
    if (_room != null && !isHost) {
      _lan.sendToHost(MessageBuilder.leaveRoom());
    }
    await _lan.closeGuest();
    _room = null;
    _role = null;
    _myPlayerId = null;
    // 清理回调，防止引用已销毁的 Widget
    onRoomChanged = null;
    onRoomClosed = null;
    onKicked = null;
    AppLogger.i(_logTag, '已离开房间');
  }

  // ==================== 工具方法 ====================

  /// 获取本机局域网 IP
  /// 在 Android 多接口环境下优先选择 WiFi 接口（192.168.x.x / 10.x.x.x / 172.16-31.x.x）
  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      String? wifiIp;     // WiFi 网段地址
      String? firstIp;    // 第一个非环回地址

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final ip = addr.address;
          AppLogger.d(_logTag, '发现网络接口: ${iface.name} - $ip');
          firstIp ??= ip;

          // 匹配私有局域网网段
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            wifiIp = ip;
          }
        }
      }

      final result = wifiIp ?? firstIp ?? '127.0.0.1';
      AppLogger.i(_logTag, '使用本机 IP: $result (WiFi=$wifiIp, first=$firstIp)');
      return result;
    } catch (e) {
      AppLogger.e(_logTag, '获取本机 IP 失败：$e');
      return '127.0.0.1';
    }
  }

  /// 检查是否为 172.16-31.x.x 私有网段
  bool _is172Private(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  /// 搜索局域网房间
  Future<void> searchRooms({
    required void Function(OnlineMessage message, String fromIp) onRoomFound,
  }) async {
    await _lan.startSearching(onRoomFound: onRoomFound);
  }

  /// 停止搜索
  void stopSearching() {
    _lan.stopSearching();
  }
}
