// 联机掷骰子房间数据模型
// 表示一个游戏房间及其参数和玩家列表
import 'online_player.dart';

/// 游戏玩法枚举
enum GameMode {
  compareSize('compare_size', '比大小'),
  guessNumber('guess_number', '猜数字');

  final String value;
  final String label;
  const GameMode(this.value, this.label);

  /// 从字符串值解析玩法
  static GameMode fromValue(String value) {
    return GameMode.values.firstWhere(
      (e) => e.value == value,
      orElse: () => GameMode.compareSize,
    );
  }
}

/// 掷骰模式枚举（仅猜数字玩法使用）
enum RollMode {
  multiPlayer('multi_player', '多人掷骰'),
  singlePlayer('single_player', '单人掷骰');

  final String value;
  final String label;
  const RollMode(this.value, this.label);

  /// 从字符串值解析掷骰模式
  static RollMode fromValue(String value) {
    return RollMode.values.firstWhere(
      (e) => e.value == value,
      orElse: () => RollMode.multiPlayer,
    );
  }
}

/// 房间状态
enum RoomState {
  waiting('等待加入'),
  ready('准备就绪'),
  playing('游戏中'),
  finished('本轮结束'),
  ;

  final String label;
  const RoomState(this.label);
}

/// 房间数据模型
class OnlineRoom {
  /// 房间配对码（4位数字）
  final String roomCode;

  /// 房间名称
  final String roomName;

  /// 最大玩家数
  final int maxPlayers;

  /// 骰子类型（如 'd6', 'd20'）
  final String diceType;

  /// 骰子数量
  final int diceCount;

  /// 游戏玩法
  final GameMode gameMode;

  /// 掷骰模式（仅猜数字玩法使用）
  final RollMode rollMode;

  /// 掷骰者 ID（猜数字单人模式：被随机选中的玩家 ID）
  final String rollerId;

  /// 房间状态
  final RoomState state;

  /// 玩家列表
  final List<OnlinePlayer> players;

  /// 房主 IP
  final String hostIp;

  /// 房主 TCP 端口
  final int hostPort;

  /// 当前轮次
  final int roundNumber;

  const OnlineRoom({
    required this.roomCode,
    required this.roomName,
    this.maxPlayers = 2,
    this.diceType = 'd6',
    this.diceCount = 1,
    this.gameMode = GameMode.compareSize,
    this.rollMode = RollMode.multiPlayer,
    this.rollerId = '',
    this.state = RoomState.waiting,
    this.players = const [],
    this.hostIp = '',
    this.hostPort = 19876,
    this.roundNumber = 0,
  });

  /// 当前玩家数
  int get currentPlayers => players.length;

  /// 是否满员
  bool get isFull => currentPlayers >= maxPlayers;

  /// 创建副本并修改指定字段
  OnlineRoom copyWith({
    String? roomCode,
    String? roomName,
    int? maxPlayers,
    String? diceType,
    int? diceCount,
    GameMode? gameMode,
    RollMode? rollMode,
    String? rollerId,
    RoomState? state,
    List<OnlinePlayer>? players,
    String? hostIp,
    int? hostPort,
    int? roundNumber,
  }) {
    return OnlineRoom(
      roomCode: roomCode ?? this.roomCode,
      roomName: roomName ?? this.roomName,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      diceType: diceType ?? this.diceType,
      diceCount: diceCount ?? this.diceCount,
      gameMode: gameMode ?? this.gameMode,
      rollMode: rollMode ?? this.rollMode,
      rollerId: rollerId ?? this.rollerId,
      state: state ?? this.state,
      players: players ?? this.players,
      hostIp: hostIp ?? this.hostIp,
      hostPort: hostPort ?? this.hostPort,
      roundNumber: roundNumber ?? this.roundNumber,
    );
  }

  /// 从 JSON 反序列化
  factory OnlineRoom.fromJson(Map<String, dynamic> json) {
    return OnlineRoom(
      roomCode: json['roomCode'] as String? ?? '',
      roomName: json['roomName'] as String? ?? '',
      maxPlayers: json['maxPlayers'] as int? ?? 2,
      diceType: json['diceType'] as String? ?? 'd6',
      diceCount: json['diceCount'] as int? ?? 1,
      gameMode:
          GameMode.fromValue(json['gameMode'] as String? ?? 'compare_size'),
      rollMode:
          RollMode.fromValue(json['rollMode'] as String? ?? 'multi_player'),
      rollerId: json['rollerId'] as String? ?? '',
      state: RoomState.values.firstWhere(
        (e) => e.name == (json['state'] as String? ?? 'waiting'),
        orElse: () => RoomState.waiting,
      ),
      players: (json['players'] as List<dynamic>?)
              ?.map((e) => OnlinePlayer.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      hostIp: json['hostIp'] as String? ?? '',
      hostPort: json['hostPort'] as int? ?? 19876,
      roundNumber: json['roundNumber'] as int? ?? 0,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'roomCode': roomCode,
        'roomName': roomName,
        'maxPlayers': maxPlayers,
        'diceType': diceType,
        'diceCount': diceCount,
        'gameMode': gameMode.value,
        'rollMode': rollMode.value,
        'rollerId': rollerId,
        'state': state.name,
        'players': players.map((e) => e.toJson()).toList(),
        'hostIp': hostIp,
        'hostPort': hostPort,
        'roundNumber': roundNumber,
      };
}
