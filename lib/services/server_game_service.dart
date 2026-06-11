// 服务器联机通信服务
// 通过WebSocket连接服务器，实现房间创建、加入、消息转发
// 替代LanService的局域网通信功能
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/online_message.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';

/// 服务器联机通信服务
class ServerGameService {
  static const String _logTag = 'ServerGameService';

  /// WebSocket连接
  WebSocketChannel? _channel;

  /// 连接是否活跃
  bool _isConnected = false;

  /// 当前玩家ID（服务器分配）
  String? _playerId;

  /// 当前房间号
  String? _roomCode;

  /// 是否为房主
  bool _isHost = false;

  // ---- 回调 ----

  /// 收到服务器消息
  void Function(OnlineMessage message)? onMessage;

  /// 连接断开回调
  VoidCallback? onDisconnected;

  /// 是否已连接
  bool get isConnected => _isConnected;

  /// 当前玩家ID
  String? get playerId => _playerId;

  /// 当前房间号
  String? get roomCode => _roomCode;

  /// 是否为房主
  bool get isHost => _isHost;

  /// 连接服务器
  Future<bool> connect() async {
    try {
      // 获取认证token
      final token = AuthService.instance.token;
      if (token == null) {
        AppLogger.e(_logTag, '未登录，无法连接服务器');
        return false;
      }

      // 构建WebSocket URL
      final serverUrl = appSettings.serverUrl;
      final parsedUrl = Uri.parse(serverUrl);
      
      // 手动构建WebSocket URL，避免Uri构造函数自动添加错误端口
      final wsScheme = serverUrl.startsWith('https') ? 'wss' : 'ws';
      final wsHost = parsedUrl.host;
      final wsPath = '/ws';
      
      // 仅在原始URL有明确非默认端口时才添加端口
      String wsUrl;
      if (parsedUrl.hasPort &&
          ((wsScheme == 'ws' && parsedUrl.port != 80) ||
           (wsScheme == 'wss' && parsedUrl.port != 443))) {
        wsUrl = '$wsScheme://$wsHost:${parsedUrl.port}$wsPath?token=$token';
      } else {
        wsUrl = '$wsScheme://$wsHost$wsPath?token=$token';
      }
      final uri = Uri.parse(wsUrl);

      AppLogger.i(_logTag, '连接WebSocket: $uri');

      _channel = WebSocketChannel.connect(uri);

      // 等待连接就绪（ready是Future，连接成功后完成，失败则抛出异常）
      try {
        await _channel!.ready.timeout(const Duration(seconds: 10));
      } catch (e) {
        AppLogger.e(_logTag, 'WebSocket连接超时或失败: $e');
        await _channel!.sink.close();
        _channel = null;
        _isConnected = false;
        return false;
      }

      _isConnected = true;

      // 监听消息
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      return true;
    } catch (e) {
      AppLogger.e(_logTag, 'WebSocket连接失败: $e');
      _isConnected = false;
      return false;
    }
  }

  /// 收到服务器消息
  void _onMessage(dynamic data) {
    try {
      final msgStr = data.toString().trim();
      if (msgStr.isEmpty) return;

      final msg = OnlineMessage.fromJsonString(msgStr);

      // 心跳消息不向上层传递
      if (msg.type == MessageType.heartbeat) {
        AppLogger.d(_logTag, '收到服务器心跳');
        return;
      }

      // 更新playerId（加入房间时服务器分配）
      if (msg.type == MessageType.joinResult) {
        final assignedId = msg.data['assignedPlayerId'] as String?;
        if (assignedId != null) {
          _playerId = assignedId;
        }
      }

      // 更新房间号（创建房间时服务器返回）
      if (msg.type == MessageType.roomCreated) {
        final roomInfo = msg.data['roomInfo'] as Map<String, dynamic>?;
        if (roomInfo != null) {
          _roomCode = roomInfo['roomCode'] as String?;
        }
      }

      onMessage?.call(msg);
    } catch (e) {
      AppLogger.w(_logTag, '解析服务器消息失败: $e');
    }
  }

  /// WebSocket错误
  void _onError(error) {
    AppLogger.e(_logTag, 'WebSocket错误: $error');
  }

  /// WebSocket连接关闭
  void _onDone() {
    AppLogger.i(_logTag, 'WebSocket连接已关闭');
    _isConnected = false;
    onDisconnected?.call();
  }

  /// 发送消息到服务器
  void sendMessage(OnlineMessage message) {
    if (!_isConnected || _channel == null) {
      AppLogger.w(_logTag, '未连接服务器，无法发送消息');
      return;
    }

    try {
      _channel!.sink.add('${message.toJsonString()}\n');
    } catch (e) {
      AppLogger.e(_logTag, '发送消息失败: $e');
    }
  }

  /// 创建房间
  void createRoom({
    required String roomName,
    required int maxPlayers,
    required String diceType,
    required int diceCount,
    required String gameMode,
    String rollMode = 'multi_player',
    String? preferredRoomCode, // 房主端建议的房间号
  }) {
    _isHost = true;
    sendMessage(MessageBuilder.createRoom(
      roomName: roomName,
      maxPlayers: maxPlayers,
      diceType: diceType,
      diceCount: diceCount,
      gameMode: gameMode,
      rollMode: rollMode,
      preferredRoomCode: preferredRoomCode,
    ));
  }

  /// 加入房间
  void joinRoom({
    required String roomCode,
    required String playerName,
  }) {
    _isHost = false;
    sendMessage(MessageBuilder.joinRoomRequest(
      roomCode: roomCode,
      playerName: playerName,
    ));
  }

  /// 离开房间
  void leaveRoom() {
    sendMessage(MessageBuilder.leaveRoomRequest());
    _roomCode = null;
    _playerId = null;
    _isHost = false;
  }

  /// 关闭房间（房主）
  void closeRoom() {
    sendMessage(MessageBuilder.closeRoomRequest());
    _roomCode = null;
    _playerId = null;
    _isHost = false;
  }

  /// 断开连接
  Future<void> disconnect() async {
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
    _roomCode = null;
    _playerId = null;
    _isHost = false;
  }

  /// 客人提交猜数字
  void guestGuess({required int guessNumber, required String playerId}) {
    sendMessage(MessageBuilder.guessSubmit(
      playerId: playerId,
      guessNumber: guessNumber,
    ));
  }

  /// 客人提交掷骰子结果
  void guestRoll({required List<int> results, required int total, required String playerId}) {
    sendMessage(MessageBuilder.rollResult(
      playerId: playerId,
      results: results,
      total: total,
    ));
  }

  /// 客人请求开始新一轮
  void requestStartRound({required String playerId}) {
    sendMessage(MessageBuilder.startRoundRequest(playerId: playerId));
  }
}
