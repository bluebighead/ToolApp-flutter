// 联机掷骰子消息协议模型
// 所有 TCP/UDP 通信消息的序列化与反序列化
// 消息格式：JSON + 换行符分隔（TCP）
import 'dart:convert';

import '../utils/app_logger.dart';

/// 消息类型枚举
enum MessageType {
  // UDP 广播消息（已废弃，保留兼容）
  roomBroadcast('room_broadcast'),   // 房主广播房间信息
  codeQuery('code_query'),           // 客人查询配对码
  codeResponse('code_response'),     // 房主回应配对码查询

  // TCP/WebSocket 消息
  joinRoom('join_room'),             // 客人请求加入房间
  joinResult('join_result'),         // 房主/服务器返回加入结果
  playerJoined('player_joined'),     // 房主/服务器通知有新玩家加入
  playerLeft('player_left'),         // 房主/服务器通知有玩家离开
  paramsUpdate('params_update'),     // 房主更新游戏参数
  startRound('start_round'),         // 房主开始新一轮
  startRoundRequest('start_round_request'), // 客人请求开始新一轮（单人模式掷骰者）
  rollResult('roll_result'),         // 玩家提交掷骰子结果
  rollStart('roll_start'),           // 掷骰者开始掷骰子（同步动画用）
  guessSubmit('guess_submit'),       // 玩家提交猜数字
  guessConfirmed('guess_confirmed'), // 房主确认猜数字已收到
  allResults('all_results'),         // 房主广播所有结果
  kickPlayer('kick_player'),         // 房主踢出玩家
  leaveRoom('leave_room'),           // 玩家主动离开
  roomClosed('room_closed'),         // 房主/服务器关闭房间
  hostMigrated('host_migrated'),     // 房主迁移给客人
  heartbeat('heartbeat'),            // 心跳保活消息

  // 服务器专用消息（WebSocket模式）
  createRoom('create_room'),         // 客户端请求服务器创建房间
  closeRoom('close_room'),           // 房主请求服务器关闭房间
  roomCreated('room_created'),       // 服务器返回房间创建成功
  error('error');                    // 服务器返回错误

  final String value;
  const MessageType(this.value);

  /// 从字符串解析消息类型
  /// 未知类型返回 null，避免将非法消息误解析为 roomBroadcast
  static MessageType? tryFromString(String value) {
    for (final type in MessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }

  /// 从字符串解析消息类型
  /// 未知类型记录警告并返回 null，调用方应处理 null 情况
  static MessageType fromString(String value) {
    final result = tryFromString(value);
    if (result == null) {
      AppLogger.w('MessageType', '未知的消息类型：$value');
    }
    // 保持向后兼容：未知类型默认返回 heartbeat（最无害的消息类型）
    // 心跳消息不会触发任何业务逻辑处理
    return result ?? MessageType.heartbeat;
  }
}

/// 通信消息
class OnlineMessage {
  /// 消息类型
  final MessageType type;

  /// 消息数据
  final Map<String, dynamic> data;

  const OnlineMessage({required this.type, required this.data});

  /// 从 JSON 字符串解析消息
  factory OnlineMessage.fromJsonString(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return OnlineMessage(
      type: MessageType.fromString(map['type'] as String? ?? ''),
      data: Map<String, dynamic>.from(map['data'] as Map? ?? {}),
    );
  }

  /// 序列化为 JSON 字符串
  String toJsonString() {
    return jsonEncode({'type': type.value, 'data': data});
  }

  @override
  String toString() => toJsonString();
}

/// 消息构建工具
class MessageBuilder {
  /// 房主广播房间信息（UDP）
  static OnlineMessage roomBroadcast({
    required String roomCode,
    required String roomName,
    required int currentPlayers,
    required int maxPlayers,
    required String diceType,
    required int diceCount,
    required String gameMode,
    required String hostIp,
    required int hostPort,
  }) {
    return OnlineMessage(
      type: MessageType.roomBroadcast,
      data: {
        'roomCode': roomCode,
        'roomName': roomName,
        'currentPlayers': currentPlayers,
        'maxPlayers': maxPlayers,
        'diceType': diceType,
        'diceCount': diceCount,
        'gameMode': gameMode,
        'hostIp': hostIp,
        'hostPort': hostPort,
      },
    );
  }

  /// 客人查询配对码（UDP）
  static OnlineMessage codeQuery({required String roomCode}) {
    return OnlineMessage(
      type: MessageType.codeQuery,
      data: {'roomCode': roomCode},
    );
  }

  /// 房主回应配对码查询（UDP 单播）
  static OnlineMessage codeResponse({
    required String roomCode,
    required String hostIp,
    required int hostPort,
  }) {
    return OnlineMessage(
      type: MessageType.codeResponse,
      data: {
        'roomCode': roomCode,
        'hostIp': hostIp,
        'hostPort': hostPort,
      },
    );
  }

  /// 客人请求加入房间（TCP）
  static OnlineMessage joinRoom({required String playerName}) {
    return OnlineMessage(
      type: MessageType.joinRoom,
      data: {'playerName': playerName},
    );
  }

  /// 房主返回加入结果（TCP）
  static OnlineMessage joinResult({
    required bool success,
    required String message,
    required Map<String, dynamic> roomInfo,
    required List<Map<String, dynamic>> players,
    String? assignedPlayerId,
  }) {
    final data = <String, dynamic>{
      'success': success,
      'message': message,
      'roomInfo': roomInfo,
      'players': players,
    };
    if (assignedPlayerId != null) {
      data['assignedPlayerId'] = assignedPlayerId;
    }
    return OnlineMessage(type: MessageType.joinResult, data: data);
  }

  /// 房主通知有新玩家加入（TCP 广播）
  static OnlineMessage playerJoined({
    required String playerId,
    required String playerName,
    required int currentPlayers,
  }) {
    return OnlineMessage(
      type: MessageType.playerJoined,
      data: {
        'playerId': playerId,
        'playerName': playerName,
        'currentPlayers': currentPlayers,
      },
    );
  }

  /// 房主通知有玩家离开（TCP 广播）
  static OnlineMessage playerLeft({
    required String playerId,
    required int currentPlayers,
  }) {
    return OnlineMessage(
      type: MessageType.playerLeft,
      data: {
        'playerId': playerId,
        'currentPlayers': currentPlayers,
      },
    );
  }

  /// 房主更新游戏参数（TCP 广播）
  static OnlineMessage paramsUpdate({
    required String diceType,
    required int diceCount,
    required String gameMode,
    String rollMode = 'multi_player',
  }) {
    return OnlineMessage(
      type: MessageType.paramsUpdate,
      data: {
        'diceType': diceType,
        'diceCount': diceCount,
        'gameMode': gameMode,
        'rollMode': rollMode,
      },
    );
  }

  /// 房主开始新一轮（TCP 广播）
  static OnlineMessage startRound({required int roundNumber}) {
    return OnlineMessage(
      type: MessageType.startRound,
      data: {'roundNumber': roundNumber},
    );
  }

  /// 客人请求开始新一轮（单人模式掷骰者发起）
  static OnlineMessage startRoundRequest({required String playerId}) {
    return OnlineMessage(
      type: MessageType.startRoundRequest,
      data: {'playerId': playerId},
    );
  }

  /// 玩家提交掷骰子结果（TCP）
  static OnlineMessage rollResult({
    required String playerId,
    required List<int> results,
    required int total,
  }) {
    return OnlineMessage(
      type: MessageType.rollResult,
      data: {
        'playerId': playerId,
        'results': results,
        'total': total,
      },
    );
  }

  /// 掷骰者开始掷骰子（TCP 广播，用于同步动画）
  static OnlineMessage rollStart({
    required String playerId,
  }) {
    return OnlineMessage(
      type: MessageType.rollStart,
      data: {
        'playerId': playerId,
      },
    );
  }

  /// 玩家提交猜数字（TCP）
  static OnlineMessage guessSubmit({
    required String playerId,
    required int guessNumber,
  }) {
    return OnlineMessage(
      type: MessageType.guessSubmit,
      data: {
        'playerId': playerId,
        'guessNumber': guessNumber,
      },
    );
  }

  /// 房主确认猜数字已收到（TCP 广播）
  static OnlineMessage guessConfirmed({
    required List<Map<String, dynamic>> players,
  }) {
    return OnlineMessage(
      type: MessageType.guessConfirmed,
      data: {'players': players},
    );
  }

  /// 房主广播所有结果（TCP 广播）
  static OnlineMessage allResults({
    required List<Map<String, dynamic>> rankings,
  }) {
    return OnlineMessage(
      type: MessageType.allResults,
      data: {'rankings': rankings},
    );
  }

  /// 玩家主动离开（TCP）
  static OnlineMessage leaveRoom() {
    return const OnlineMessage(type: MessageType.leaveRoom, data: {});
  }

  /// 房主关闭房间（TCP 广播）
  static OnlineMessage roomClosed() {
    return const OnlineMessage(type: MessageType.roomClosed, data: {});
  }

  /// 房主迁移给客人（TCP 广播）
  /// 通知所有客人新房主是谁，以及更新后的玩家列表
  static OnlineMessage hostMigrated({
    required String newHostId,
    required List<Map<String, dynamic>> players,
  }) {
    return OnlineMessage(
      type: MessageType.hostMigrated,
      data: {
        'newHostId': newHostId,
        'players': players,
      },
    );
  }

  /// 心跳保活消息
  static OnlineMessage heartbeat({String? playerId}) {
    return OnlineMessage(
      type: MessageType.heartbeat,
      data: {
        'playerId': playerId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  // ============================================================
  // 服务器专用消息构建器（WebSocket模式）
  // ============================================================

  /// 创建房间请求（发送到服务器）
  static OnlineMessage createRoom({
    required String roomName,
    required int maxPlayers,
    required String diceType,
    required int diceCount,
    required String gameMode,
    String rollMode = 'multi_player',
    String? preferredRoomCode, // 房主端建议的房间号（4位数字）
  }) {
    return OnlineMessage(
      type: MessageType.createRoom, // 正确的类型：create_room，与服务器端匹配
      data: {
        'roomName': roomName,
        'maxPlayers': maxPlayers,
        'diceType': diceType,
        'diceCount': diceCount,
        'gameMode': gameMode,
        'rollMode': rollMode,
        'preferredRoomCode': preferredRoomCode,
      },
    );
  }

  /// 加入房间请求（发送到服务器）
  static OnlineMessage joinRoomRequest({
    required String roomCode,
    required String playerName,
  }) {
    return OnlineMessage(
      type: MessageType.joinRoom,
      data: {
        'roomCode': roomCode,
        'playerName': playerName,
      },
    );
  }

  /// 关闭房间请求（房主发送到服务器）
  static OnlineMessage closeRoomRequest() {
    return const OnlineMessage(
      type: MessageType.closeRoom, // 正确的类型：close_room，与服务器端匹配
      data: {},
    );
  }

  /// 离开房间请求（发送到服务器）
  static OnlineMessage leaveRoomRequest() {
    return const OnlineMessage(
      type: MessageType.leaveRoom,
      data: {},
    );
  }
}
