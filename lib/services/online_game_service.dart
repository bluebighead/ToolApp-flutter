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
import 'server_game_service.dart';

/// 游戏服务角色
enum GameRole { host, guest }

/// 房间状态变更回调
typedef OnRoomChanged = void Function(OnlineRoom room);

/// 联机游戏服务
class OnlineGameService {
  static const String _logTag = 'OnlineGameService';
  static const String _playerNameKey = 'online_player_name';

  /// 通信服务
  final ServerGameService _server = ServerGameService();

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

  /// 加入房间等待器（用于等待服务器响应）
  Completer<bool>? _joinCompleter;

  /// 最后一次加入错误消息
  String _lastJoinError = '';
  String get lastJoinError => _lastJoinError;

  /// 获取当前房间
  OnlineRoom? get room => _room;

  /// 获取当前角色
  GameRole? get role => _role;

  /// 获取当前玩家 ID
  String? get myPlayerId => _myPlayerId;

  /// 是否为房主
  bool get isHost => _role == GameRole.host;

  /// 获取通信服务（用于发送消息等）
  ServerGameService get server => _server;

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

  /// 房主创建房间（服务器模式）
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

    // 先清理可能残留的旧连接
    _server.disconnect();

    // 连接服务器
    final connected = await _server.connect();
    if (!connected) return false;

    // 生成4位数字配对码（本地显示用，实际房间号由服务器生成）
    final random = Random();
    final roomCode = List.generate(4, (_) => random.nextInt(10)).join();

    // 创建本地房间对象
    _room = OnlineRoom(
      roomCode: roomCode,
      roomName: roomName,
      maxPlayers: maxPlayers,
      diceType: diceType,
      diceCount: diceCount,
      gameMode: gameMode,
      rollMode: rollMode,
      hostIp: 'server',
      hostPort: 3000,
      players: [
        OnlinePlayer(
          id: _myPlayerId!,
          name: '房主',
          isHost: true,
        ),
      ],
    );

    // 设置消息回调
    _server.onMessage = _onServerMessage;
    _server.onDisconnected = () {
      if (_room != null) {
        onRoomClosed?.call();
      }
    };

    // 发送创建房间请求（将本地生成的4位配对码发送给服务器，让服务器优先使用）
    _server.createRoom(
      roomName: roomName,
      maxPlayers: maxPlayers,
      diceType: diceType,
      diceCount: diceCount,
      gameMode: gameMode.value,
      rollMode: rollMode.value,
      preferredRoomCode: roomCode, // 传递房主本地生成的房间号
    );

    AppLogger.i(_logTag, '房间创建请求已发送，建议房间号：$roomCode');
    onRoomChanged?.call(_room!);
    return true;
  }

  /// 处理服务器消息
  void _onServerMessage(OnlineMessage message) {
    AppLogger.i(_logTag, '收到服务器消息：${message.type}');

    switch (message.type) {
      case MessageType.roomCreated:
        // 服务器返回房间创建成功
        _handleRoomCreated(message);
        break;
      case MessageType.joinResult:
        // 处理加入结果（成功或失败）
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
      case MessageType.rollResult:
        _handleRollResult(message);
        break;
      case MessageType.rollStart:
        _handleRollStart(message);
        break;
      case MessageType.guessSubmit:
        _handleGuessSubmit(message);
        break;
      case MessageType.guessConfirmed:
        _handleGuessConfirmed(message);
        break;
      case MessageType.allResults:
        _handleAllResults(message);
        break;
      case MessageType.startRoundRequest:
        // 处理客人请求开始新一轮（单人模式下掷骰者发起）
        _handleStartRoundRequest(message);
        break;
      case MessageType.roomClosed:
        onRoomClosed?.call();
        break;
      case MessageType.error:
        AppLogger.e(_logTag, '服务器错误：${message.data['message']}');
        break;
      default:
        AppLogger.d(_logTag, '忽略未处理的消息类型：${message.type}');
        break;
    }
  }

  /// 处理房间创建成功
  void _handleRoomCreated(OnlineMessage message) {
    final roomInfo = message.data['roomInfo'] as Map<String, dynamic>? ?? {};
    final playersList = message.data['players'] as List<dynamic>? ?? [];
    final assignedId = message.data['assignedPlayerId'] as String?;

    if (assignedId != null) {
      _myPlayerId = assignedId;
    }

    final players = playersList
        .map((e) => OnlinePlayer.fromJson(e as Map<String, dynamic>))
        .toList();

    _room = OnlineRoom.fromJson(roomInfo).copyWith(players: players);

    AppLogger.i(_logTag, '房间创建成功：${_room!.roomCode}');
    onRoomChanged?.call(_room!);
  }

  /// 处理加入房间结果（客人端）
  void _handleJoinResult(OnlineMessage message) {
    final success = message.data['success'] as bool? ?? false;
    
    if (success) {
      final roomInfo = message.data['roomInfo'] as Map<String, dynamic>? ?? {};
      final playersList = message.data['players'] as List<dynamic>? ?? [];
      final assignedId = message.data['assignedPlayerId'] as String?;

      if (assignedId != null) {
        _myPlayerId = assignedId;
      }

      final players = playersList
          .map((e) => OnlinePlayer.fromJson(e as Map<String, dynamic>))
          .toList();

      _room = OnlineRoom.fromJson(roomInfo).copyWith(players: players);

      AppLogger.i(_logTag, '加入房间成功');
      onRoomChanged?.call(_room!);
      
      // 完成等待器
      _joinCompleter?.complete(true);
    } else {
      final errorMsg = message.data['message'] as String? ?? '加入失败';
      _lastJoinError = errorMsg;
      AppLogger.w(_logTag, '加入房间失败：$errorMsg');
      
      // 清理本地状态
      _room = null;
      _role = null;
      _myPlayerId = null;
      
      // 完成等待器
      _joinCompleter?.complete(false);
    }
  }

  /// 处理新玩家加入
  void _handlePlayerJoined(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final playerName = message.data['playerName'] as String? ?? '未知';
    final currentPlayers = message.data['currentPlayers'] as int? ?? 0;

    final newPlayer = OnlinePlayer(
      id: playerId,
      name: playerName,
      isHost: false,
    );

    final updatedPlayers = [..._room!.players, newPlayer];
    _room = _room!.copyWith(players: updatedPlayers);

    AppLogger.i(_logTag, '玩家 $playerName 加入，当前 $currentPlayers 人');
    onRoomChanged?.call(_room!);
  }

  /// 处理玩家离开
  void _handlePlayerLeft(OnlineMessage message) {
    if (_room == null) return;
    final playerId = message.data['playerId'] as String? ?? '';
    final currentPlayers = message.data['currentPlayers'] as int? ?? 0;

    final updatedPlayers =
        _room!.players.where((p) => p.id != playerId).toList();
    _room = _room!.copyWith(players: updatedPlayers);

    AppLogger.i(_logTag, '玩家离开，当前 $currentPlayers 人');
    onRoomChanged?.call(_room!);
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

    final oldRollMode = _room!.rollMode;
    _room = _room!.copyWith(
      diceType: diceType ?? _room!.diceType,
      diceCount: diceCount ?? _room!.diceCount,
      gameMode: newGameMode,
      rollMode: newRollMode,
    );

    // 掷骰模式发生变化时，在任何状态下都重置 rollerId（防止 finished 状态下切换模式后卡住）
    final rollModeChanged = oldRollMode != newRollMode;
    if (rollModeChanged) {
      _room = _room!.copyWith(rollerId: '');
    }

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
    _server.sendMessage(
      MessageBuilder.paramsUpdate(
        diceType: _room!.diceType,
        diceCount: _room!.diceCount,
        gameMode: _room!.gameMode.value,
        rollMode: _room!.rollMode.value,
      ),
    );

    // 如果游戏中切换了玩法，还需要广播玩家状态重置
    if (_room!.state == RoomState.playing) {
      _server.sendMessage(
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
    _server.sendMessage(
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
      // 服务器会自动转发给其他玩家，无需手动广播
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
      // 房主端：服务器会自动转发给其他客人
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
    _server.sendMessage(
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
    _server.sendMessage(
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
    _server.sendMessage(
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
    _server.sendMessage(
      MessageBuilder.guessConfirmed(
        players: _room!.players.map((e) => e.toJson()).toList(),
      ),
    );
  }

  /// 客人提交猜数字
  void guestGuess(int guessNumber) {
    if (_room == null || isHost || _myPlayerId == null) return;
    _server.guestGuess(guessNumber: guessNumber, playerId: _myPlayerId!);

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

    _server.sendMessage(MessageBuilder.allResults(rankings: rankings));
    onRoomChanged?.call(_room!);
  }

  /// 关闭房间（房主）
  Future<void> closeRoom() async {
    if (_room != null && isHost) {
      // 通知服务器关闭房间
      _server.closeRoom();
      await _server.disconnect();
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

  /// 客人通过房间号加入房间（服务器模式）
  Future<bool> joinByCode(String roomCode, String playerName) async {
    _role = GameRole.guest;
    _myPlayerId = playerName;

    // 先清理可能残留的旧连接
    _server.disconnect();

    // 连接服务器
    final connected = await _server.connect();
    if (!connected) {
      AppLogger.w(_logTag, '连接服务器失败');
      return false;
    }

    // 设置消息回调
    _server.onMessage = _onServerMessage;
    _server.onDisconnected = () {
      if (_room != null) {
        onRoomClosed?.call();
      }
    };

    // 创建等待器
    _joinCompleter = Completer<bool>();

    // 发送加入房间请求
    _server.joinRoom(roomCode: roomCode, playerName: playerName);

    AppLogger.i(_logTag, '加入房间请求已发送：$roomCode');

    // 等待服务器响应（最多等待10秒）
    try {
      final result = await _joinCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          AppLogger.w(_logTag, '加入房间超时');
          return false;
        },
      );
      _joinCompleter = null;
      return result;
    } catch (e) {
      AppLogger.e(_logTag, '等待加入结果异常：$e');
      _joinCompleter = null;
      return false;
    }
  }

  /// 客人通过搜索结果加入房间（已废弃，服务器模式不再需要）
  Future<bool> joinBySearch(
      String hostIp, int hostPort, String playerName) async {
    AppLogger.w(_logTag, '服务器模式下不再支持搜索加入');
    return false;
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

    final oldRollMode = _room!.rollMode;
    _room = _room!.copyWith(
      diceType: newDiceType,
      diceCount: newDiceCount,
      gameMode: newGameMode,
      rollMode: newRollMode,
    );

    // 掷骰模式发生变化时，在任何状态下都重置 rollerId（防止 finished 状态下切换模式后卡住）
    final rollModeChanged = oldRollMode != newRollMode;
    if (rollModeChanged) {
      _room = _room!.copyWith(rollerId: '');
    }

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
    _server.guestRoll(results: results, total: total, playerId: _myPlayerId!);

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
    _server.requestStartRound(playerId: _myPlayerId!);
  }

  /// 客人离开房间
  Future<void> leaveRoom() async {
    if (_room != null && !isHost) {
      _server.leaveRoom();
    }
    await _server.disconnect();
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

  /// 搜索局域网房间（已废弃，服务器模式不再需要）
  Future<void> searchRooms({
    required void Function(OnlineMessage message, String fromIp) onRoomFound,
  }) async {
    AppLogger.w(_logTag, '服务器模式下不再支持搜索房间');
  }

  /// 停止搜索（已废弃，服务器模式不再需要）
  void stopSearching() {
    // 服务器模式下无需搜索
  }
}
