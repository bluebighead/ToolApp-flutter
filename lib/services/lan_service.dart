// 局域网通信服务
// 提供 UDP 广播（房间发现/配对码查询）和 TCP 通信（房主服务端/客人客户端）
//
// 架构：
//   - UDP 端口 19875：房间广播和配对码查询
//   - TCP 端口 19876：房主服务端，客人连接
//   - 消息格式：JSON + 换行符分隔
//
// 关键修复：
//   1. Android 必须获取 MulticastLock 才能接收 UDP 广播/多播
//   2. 配对码查询响应需发送到查询者的源端口（而非固定端口）
//   3. 广播目标需包含子网定向广播地址（如 192.168.1.255），
//      因为很多 Android 设备/路由器不支持 255.255.255.255 广播
//   4. 配对码查询需多次重发，提高可靠性
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/online_message.dart';
import '../utils/app_logger.dart';

/// 局域网通信服务
class LanService {
  static const String _logTag = 'LanService';
  static const int _udpPort = 19875;
  static const int _tcpPort = 19876;
  static const Duration _broadcastInterval = Duration(seconds: 2);
  // 心跳间隔：5 秒发送一次
  static const Duration _heartbeatInterval = Duration(seconds: 5);
  // 心跳超时：60 秒未收到心跳视为断开（增大超时避免应用切后台时误判断开）
  static const Duration _heartbeatTimeout = Duration(seconds: 60);

  // WiFi 辅助 MethodChannel
  static const MethodChannel _wifiChannel =
      MethodChannel('com.example.toolapp/wifi_helper');

  // ---- UDP 广播 ----
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;

  // 广播消息生成回调（房主用，每次广播时调用获取最新消息）
  OnlineMessage Function()? _broadcastMessageBuilder;

  // ---- TCP 服务端（房主用） ----
  ServerSocket? _serverSocket;
  // 玩家 ID -> Socket 映射
  final Map<String, Socket> _clientSockets = {};
  // 玩家 ID -> 最后心跳时间
  final Map<String, DateTime> _clientLastHeartbeat = {};
  // 房主端心跳检测定时器
  Timer? _hostHeartbeatTimer;

  // ---- TCP 客户端（客人用） ----
  Socket? _guestSocket;
  // 客人心跳发送定时器
  Timer? _guestHeartbeatTimer;
  // 客人的 playerId（房主分配的唯一标识，用于心跳消息携带）
  String? _guestPlayerId;

  // ---- MulticastLock 状态 ----
  bool _multicastLockAcquired = false;

  // ---- 回调 ----
  /// 收到 UDP 消息（房主收到配对码查询时使用）
  /// 参数：消息、来源 IP、来源端口
  void Function(OnlineMessage message, String fromIp, int fromPort)?
      onUdpMessage;

  /// 收到 TCP 消息（房主收到客人消息）
  void Function(OnlineMessage message, String playerId)? onHostTcpMessage;

  /// 收到 TCP 消息（客人收到房主消息）
  void Function(OnlineMessage message)? onGuestTcpMessage;

  /// 客人连接断开（房主端）
  void Function(String playerId)? onClientDisconnected;

  /// 与房主的连接断开（客人端）
  VoidCallback? onHostDisconnected;

  /// 获取 TCP 端口
  int get tcpPort => _tcpPort;

  /// 是否正在广播
  bool get isBroadcasting => _broadcastTimer != null && _udpSocket != null;

  // ==================== 工具方法 ====================

  /// 获取本机所有 IPv4 地址
  static Future<List<String>> getLocalIps() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      AppLogger.e(_logTag, '获取本机 IP 失败：$e');
    }
    return ips;
  }

  /// 根据 IP 地址推断子网定向广播地址
  /// 例如 192.168.1.100 -> 192.168.1.255
  static String _getSubnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      parts[3] = '255';
      return parts.join('.');
    }
    return '255.255.255.255';
  }

  /// 向所有可能的广播地址发送 UDP 数据
  /// 包括：255.255.255.255、224.0.0.1、以及本机各网卡的子网定向广播地址
  Future<void> _sendUdpBroadcast(Uint8List data, int port) async {
    // 1. 有限广播地址（最通用）
    _udpSocket?.send(data, InternetAddress('255.255.255.255'), port);

    // 2. 多播地址
    _udpSocket?.send(data, InternetAddress('224.0.0.1'), port);

    // 3. 子网定向广播地址（最可靠）
    final localIps = await getLocalIps();
    for (final ip in localIps) {
      final subnetBroadcast = _getSubnetBroadcast(ip);
      if (subnetBroadcast != '255.255.255.255') {
        try {
          _udpSocket
              ?.send(data, InternetAddress(subnetBroadcast), port);
          AppLogger.d(_logTag, '发送子网广播到 $subnetBroadcast:$port');
        } catch (e) {
          AppLogger.w(_logTag, '发送子网广播失败 $subnetBroadcast:$port - $e');
        }
      }
    }
  }

  /// 向所有可能的广播地址发送 UDP 数据（使用指定 socket）
  Future<void> _sendUdpBroadcastWith(
      RawDatagramSocket socket, Uint8List data, int port) async {
    socket.send(data, InternetAddress('255.255.255.255'), port);
    socket.send(data, InternetAddress('224.0.0.1'), port);

    final localIps = await getLocalIps();
    for (final ip in localIps) {
      final subnetBroadcast = _getSubnetBroadcast(ip);
      if (subnetBroadcast != '255.255.255.255') {
        try {
          socket.send(data, InternetAddress(subnetBroadcast), port);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  // ==================== MulticastLock 管理 ====================

  /// 获取 Android WiFi 多播锁
  /// Android 默认过滤 UDP 多播/广播包，必须获取锁才能接收
  Future<void> acquireMulticastLock() async {
    if (_multicastLockAcquired) return;
    try {
      await _wifiChannel.invokeMethod<bool>('acquireMulticastLock');
      _multicastLockAcquired = true;
      AppLogger.i(_logTag, 'MulticastLock 已获取');
    } catch (e) {
      AppLogger.w(_logTag, '获取 MulticastLock 失败：$e');
    }
  }

  /// 释放 Android WiFi 多播锁
  Future<void> releaseMulticastLock() async {
    if (!_multicastLockAcquired) return;
    try {
      await _wifiChannel.invokeMethod<bool>('releaseMulticastLock');
      _multicastLockAcquired = false;
      AppLogger.i(_logTag, 'MulticastLock 已释放');
    } catch (e) {
      AppLogger.w(_logTag, '释放 MulticastLock 失败：$e');
    }
  }

  /// 获取当前 WiFi SSID（网络名称）
  static Future<String> getWifiSsid() async {
    try {
      final ssid = await _wifiChannel.invokeMethod<String>('getWifiSsid');
      return ssid ?? '';
    } catch (e) {
      AppLogger.w(_logTag, '获取 WiFi SSID 失败：$e');
      return '';
    }
  }

  // ==================== 房主：TCP 服务端 ====================

  /// 启动 TCP 服务端（房主创建房间后调用）
  Future<bool> startServer() async {
    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _tcpPort,
      );
      AppLogger.i(_logTag,
          'TCP 服务端已启动，端口：$_tcpPort，地址：${_serverSocket!.address.address}');

      _serverSocket!.listen(
        _onClientConnected,
        onError: (e) {
          AppLogger.e(_logTag, 'TCP 服务端错误：$e');
        },
        onDone: () {
          AppLogger.i(_logTag, 'TCP 服务端关闭');
        },
      );

      // 启动心跳检测定时器（每隔 5 秒检查一次客户端心跳是否超时）
      _hostHeartbeatTimer?.cancel();
      _hostHeartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
        _checkClientHeartbeats();
      });
      AppLogger.i(_logTag, '房主端心跳检测已启动，间隔=$_heartbeatInterval，超时=$_heartbeatTimeout');

      return true;
    } catch (e) {
      AppLogger.e(_logTag, 'TCP 服务端启动失败（端口$_tcpPort）：$e');
      return false;
    }
  }

  /// 检查所有客户端的心跳是否超时，超时则移除
  void _checkClientHeartbeats() {
    if (_clientSockets.isEmpty) return;

    final now = DateTime.now();
    final timedOutPlayers = <String>[];

    // 找出超时的客户端
    for (final entry in _clientLastHeartbeat.entries) {
      final lastBeat = entry.value;
      final elapsed = now.difference(lastBeat);
      if (elapsed >= _heartbeatTimeout) {
        timedOutPlayers.add(entry.key);
        AppLogger.w(_logTag, '客户端 ${entry.key} 心跳超时：${elapsed.inSeconds}秒未收到消息');
      }
    }

    // 移除超时客户端
    for (final playerId in timedOutPlayers) {
      final socket = _clientSockets[playerId];
      if (socket != null) {
        _removeClientSocket(playerId, socket);
      }
    }
  }

  /// 客户端连接处理
  void _onClientConnected(Socket socket) {
    final clientIp = socket.remoteAddress.address;
    final tempId = '$clientIp:${socket.remotePort}';
    AppLogger.i(_logTag, '客户端连接：$tempId');

    // 临时分配 playerId（等收到 joinRoom 消息后更新）
    _clientSockets[tempId] = socket;
    // 记录初始心跳时间
    _clientLastHeartbeat[tempId] = DateTime.now();

    // 当前客户端的正式 playerId（收到 joinRoom 后更新）
    String currentPlayerId = tempId;

    // TCP 粘包处理缓冲区
    String buffer = '';

    socket.listen(
      (data) {
        buffer += utf8.decode(data, allowMalformed: true);
        // 按换行符分割消息
        while (buffer.contains('\n')) {
          final idx = buffer.indexOf('\n');
          final line = buffer.substring(0, idx).trim();
          buffer = buffer.substring(idx + 1);
          if (line.isEmpty) continue;
          try {
            final msg = OnlineMessage.fromJsonString(line);
            // 如果是 joinRoom 消息，用 playerName 替换 tempId
            if (msg.type == MessageType.joinRoom) {
              final playerId = msg.data['playerName'] as String? ?? tempId;
              // 更新 socket 映射和心跳记录
              _clientSockets.remove(currentPlayerId);
              _clientLastHeartbeat.remove(currentPlayerId);
              _clientSockets[playerId] = socket;
              _clientLastHeartbeat[playerId] = DateTime.now();
              currentPlayerId = playerId;
              AppLogger.i(_logTag, '客户端 $tempId 正式注册为 playerId=$playerId');
              onHostTcpMessage?.call(msg, playerId);
            } else {
              // 优先从消息中提取 playerId，否则使用当前已注册的 playerId
              final msgPlayerId = msg.data['playerId'] as String?;
              final effectivePlayerId =
                  (msgPlayerId != null && _clientSockets.containsKey(msgPlayerId))
                      ? msgPlayerId
                      : currentPlayerId;

              // 收到任何消息都更新心跳时间（通过 socket 匹配更可靠）
              _updateClientHeartbeat(socket, effectivePlayerId);

              // 心跳消息不需要向上层处理
              if (msg.type == MessageType.heartbeat) {
                AppLogger.d(_logTag, '收到客户端 $effectivePlayerId 心跳');
              } else {
                onHostTcpMessage?.call(msg, effectivePlayerId);
              }
            }
          } catch (e) {
            AppLogger.w(_logTag, '解析 TCP 消息失败：$e');
          }
        }
      },
      onError: (e) {
        AppLogger.e(_logTag, '客户端连接错误：$currentPlayerId - $e');
        _removeClientSocket(currentPlayerId, socket);
      },
      onDone: () {
        AppLogger.i(_logTag, '客户端断开：$currentPlayerId');
        _removeClientSocket(currentPlayerId, socket);
      },
    );
  }

  /// 通过 socket 实例或 playerId 更新客户端心跳时间（双重保险）
  void _updateClientHeartbeat(Socket socket, String fallbackId) {
    // 方法1：优先通过 socket 实例匹配（最可靠，无论 key 是否被重命名）
    String? matchedKey;
    for (final entry in _clientSockets.entries) {
      if (entry.value == socket) {
        matchedKey = entry.key;
        break;
      }
    }
    if (matchedKey != null) {
      _clientLastHeartbeat[matchedKey] = DateTime.now();
      return;
    }
    // 方法2：如果 socket 匹配失败，使用传入的 fallbackId
    if (_clientSockets.containsKey(fallbackId)) {
      _clientLastHeartbeat[fallbackId] = DateTime.now();
    }
  }

  /// 移除客户端 Socket 并通知
  /// 关键改进：优先通过 socket 实例匹配，其次通过 id 匹配
  /// 避免因 id 被重命名（如 renameClientKey 调用）导致无法正确识别
  void _removeClientSocket(String tempId, Socket socket) {
    // 方法1：通过 socket 实例匹配（最可靠，无论 key 是否被重命名）
    String? actualId;
    for (final entry in _clientSockets.entries) {
      if (entry.value == socket) {
        actualId = entry.key;
        break;
      }
    }

    // 方法2：如果 socket 匹配失败，尝试通过 tempId 直接匹配
    if (actualId == null && _clientSockets.containsKey(tempId)) {
      actualId = tempId;
    }

    if (actualId != null) {
      _clientSockets.remove(actualId);
      _clientLastHeartbeat.remove(actualId);
      AppLogger.i(_logTag, '客户端断开连接：$actualId (tempId=$tempId)，剩余 ${_clientSockets.length} 个连接');
      onClientDisconnected?.call(actualId);
    } else {
      AppLogger.w(_logTag, '客户端断开连接，但未找到匹配的 socket：tempId=$tempId，当前 sockets=${_clientSockets.keys.toList()}');
    }
    socket.destroy();
  }

  /// 更新客户端 Socket 映射的 key（如从 tempId 改为实际 playerId）
  /// 同时更新心跳记录的 key，确保心跳检测能正确匹配
  void renameClientKey(String oldKey, String newKey) {
    final socket = _clientSockets.remove(oldKey);
    if (socket != null) {
      _clientSockets[newKey] = socket;
    }
    // 同步更新心跳记录的 key
    final lastHeartbeat = _clientLastHeartbeat.remove(oldKey);
    if (lastHeartbeat != null) {
      _clientLastHeartbeat[newKey] = lastHeartbeat;
    }
  }

  /// 向指定玩家发送 TCP 消息
  void sendToPlayer(String playerId, OnlineMessage message) {
    final socket = _clientSockets[playerId];
    if (socket != null) {
      _sendTcp(socket, message);
    } else {
      AppLogger.w(_logTag, '玩家 $playerId 的 Socket 不存在');
    }
  }

  /// 向所有客人广播 TCP 消息
  void broadcastToGuests(OnlineMessage message) {
    for (final socket in _clientSockets.values) {
      _sendTcp(socket, message);
    }
  }

  /// 向除指定玩家外的所有客人广播 TCP 消息
  /// [excludePlayerId] 不发送此消息的玩家 ID
  void broadcastToGuestsExcept(
      String excludePlayerId, OnlineMessage message) {
    for (final entry in _clientSockets.entries) {
      if (entry.key != excludePlayerId) {
        _sendTcp(entry.value, message);
      }
    }
  }

  // ==================== 客人：TCP 客户端 ====================

  /// 客人连接到房主
  /// [playerId] 客人的 playerId，用于心跳消息携带
  Future<bool> connectToHost(String hostIp, {int port = _tcpPort, String? playerId}) async {
    try {
      AppLogger.i(_logTag, 'TCP 连接中: $hostIp:$port, playerId=$playerId');
      _guestSocket = await Socket.connect(
        hostIp,
        port,
        timeout: const Duration(seconds: 5),
      );
      _guestPlayerId = playerId;
      AppLogger.i(_logTag,
          '已连接到房主：$hostIp:$port，本地端口：${_guestSocket!.port}');

      // 启动心跳发送定时器（每隔 5 秒发送心跳保持连接）
      _guestHeartbeatTimer?.cancel();
      _guestHeartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
        _sendHeartbeat();
      });
      AppLogger.i(_logTag, '客人心跳发送已启动，间隔=${_heartbeatInterval.inSeconds}秒');

      // TCP 粘包处理缓冲区
      var guestBuffer = '';
      bool connectionClosed = false;

      _guestSocket!.listen(
        (data) {
          guestBuffer += utf8.decode(data, allowMalformed: true);
          while (guestBuffer.contains('\n')) {
            final idx = guestBuffer.indexOf('\n');
            final line = guestBuffer.substring(0, idx).trim();
            guestBuffer = guestBuffer.substring(idx + 1);
            if (line.isEmpty) continue;
            try {
              final msg = OnlineMessage.fromJsonString(line);
              // 心跳消息不需要向上层传递
              if (msg.type != MessageType.heartbeat) {
                onGuestTcpMessage?.call(msg);
              }
            } catch (e) {
              AppLogger.w(_logTag, '解析房主消息失败：$e');
            }
          }
        },
        onError: (e) {
          AppLogger.e(_logTag, '房主连接错误：$e');
          if (!connectionClosed) {
            connectionClosed = true;
            _stopGuestHeartbeat();
            onHostDisconnected?.call();
          }
        },
        onDone: () {
          AppLogger.i(_logTag, '与房主断开连接');
          if (!connectionClosed) {
            connectionClosed = true;
            _stopGuestHeartbeat();
            onHostDisconnected?.call();
          }
        },
      );
      return true;
    } catch (e) {
      AppLogger.e(_logTag, '连接房主失败：$e');
      return false;
    }
  }

  /// 发送心跳消息（保持 TCP 连接活跃）
  void _sendHeartbeat() {
    if (_guestSocket != null) {
      try {
        // 心跳消息中必须携带 playerId，房主端才能正确关联到哪个客户端
        final msg = MessageBuilder.heartbeat(playerId: _guestPlayerId);
        _guestSocket!.write('${msg.toJsonString()}\n');
      } catch (e) {
        AppLogger.w(_logTag, '发送心跳失败：$e');
      }
    }
  }

  /// 停止客人心跳发送
  void _stopGuestHeartbeat() {
    _guestHeartbeatTimer?.cancel();
    _guestHeartbeatTimer = null;
  }

  /// 更新客人的 playerId（房主分配的唯一标识）
  /// 收到 joinResult 后调用，确保后续心跳消息携带正确的 playerId
  void updateGuestPlayerId(String? playerId) {
    _guestPlayerId = playerId;
    AppLogger.i(_logTag, '客人 playerId 已更新为: $playerId');
  }

  /// 客人向房主发送 TCP 消息
  void sendToHost(OnlineMessage message) {
    if (_guestSocket != null) {
      _sendTcp(_guestSocket!, message);
    }
  }

  /// 发送 TCP 消息的通用方法
  void _sendTcp(Socket socket, OnlineMessage message) {
    try {
      socket.write('${message.toJsonString()}\n');
    } catch (e) {
      AppLogger.e(_logTag, '发送 TCP 消息失败：$e');
    }
  }

  // ==================== UDP 广播 ====================

  /// 启动 UDP 广播（房主用，定期广播房间信息）
  /// [messageBuilder] 消息生成回调，每次广播时调用以获取最新房间信息
  Future<void> startBroadcasting(
      OnlineMessage Function() messageBuilder) async {
    // 先获取 MulticastLock
    await acquireMulticastLock();

    _broadcastMessageBuilder = messageBuilder;

    try {
      _udpSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, _udpPort);
      _udpSocket!.broadcastEnabled = true;

      _broadcastTimer = Timer.periodic(_broadcastInterval, (_) async {
        // 每次广播时获取最新消息
        final broadcastMessage = _broadcastMessageBuilder!();
        final data = utf8.encode(broadcastMessage.toJsonString());
        // 向所有广播地址发送
        await _sendUdpBroadcast(data, _udpPort);
        AppLogger.d(_logTag, '房间广播已发送');
      });

      // 同时监听配对码查询
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            AppLogger.d(
                _logTag, '房主收到 UDP 数据：来自 ${datagram.address.address}:${datagram.port}，长度=${datagram.data.length}');
            final msgStr = utf8.decode(datagram.data, allowMalformed: true);
            try {
              final msg = OnlineMessage.fromJsonString(msgStr);
              AppLogger.d(_logTag, '房主收到 UDP 消息类型：${msg.type}');
              if (msg.type == MessageType.codeQuery) {
                // 传递来源 IP 和端口，以便响应到正确端口
                onUdpMessage?.call(
                    msg, datagram.address.address, datagram.port);
              }
            } catch (e) {
              AppLogger.w(_logTag, '房主解析 UDP 消息失败：$e');
            }
          }
        }
      });

      AppLogger.i(_logTag, 'UDP 广播已启动，端口：$_udpPort');
    } catch (e) {
      AppLogger.e(_logTag, 'UDP 广播启动失败：$e');
    }
  }

  /// 搜索局域网房间（客人用，监听 UDP 广播）
  Future<void> startSearching({
    required void Function(OnlineMessage message, String fromIp) onRoomFound,
  }) async {
    // 先获取 MulticastLock
    await acquireMulticastLock();

    try {
      _udpSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, _udpPort);
      // 客人端也设置 broadcastEnabled，某些设备需要
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            AppLogger.d(
                _logTag, '客人收到 UDP 数据：来自 ${datagram.address.address}:${datagram.port}，长度=${datagram.data.length}');
            final msgStr = utf8.decode(datagram.data, allowMalformed: true);
            try {
              final msg = OnlineMessage.fromJsonString(msgStr);
              AppLogger.d(_logTag, '客人收到 UDP 消息类型：${msg.type}');
              if (msg.type == MessageType.roomBroadcast) {
                onRoomFound(msg, datagram.address.address);
              }
            } catch (e) {
              AppLogger.w(_logTag, '客人解析 UDP 消息失败：$e');
            }
          }
        }
      });

      AppLogger.i(_logTag, '开始搜索局域网房间，端口：$_udpPort');
    } catch (e) {
      AppLogger.e(_logTag, '搜索房间启动失败：$e');
    }
  }

  /// 通过配对码查询房主地址（客人用）
  /// 返回 ({String hostIp, int hostPort})?，查询失败返回 null
  Future<({String hostIp, int hostPort})?> queryByCode(String roomCode) async {
    // 先获取 MulticastLock
    await acquireMulticastLock();

    RawDatagramSocket? querySocket;
    try {
      // 使用随机端口，避免与搜索功能的 UDP Socket 冲突
      querySocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      querySocket.broadcastEnabled = true;

      final queryMsg = MessageBuilder.codeQuery(roomCode: roomCode);
      final data = utf8.encode(queryMsg.toJsonString());

      // 等待房主回应
      final completer = Completer<({String hostIp, int hostPort})?>();

      querySocket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = querySocket!.receive();
          if (datagram != null) {
            try {
              final msgStr = utf8.decode(datagram.data, allowMalformed: true);
              final msg = OnlineMessage.fromJsonString(msgStr);
              AppLogger.d(
                  _logTag, '配对码查询收到回应：类型=${msg.type}，来自 ${datagram.address.address}');
              if (msg.type == MessageType.codeResponse &&
                  msg.data['roomCode'] == roomCode) {
                final hostIp = msg.data['hostIp'] as String?;
                final hostPort = msg.data['hostPort'] as int? ?? _tcpPort;
                if (!completer.isCompleted && hostIp != null) {
                  completer.complete((hostIp: hostIp, hostPort: hostPort));
                }
              }
            } catch (e) {
              AppLogger.w(_logTag, '配对码查询解析回应失败：$e');
            }
          }
        }
      });

      // 多次重发查询，提高可靠性
      // 立即发送一次
      await _sendUdpBroadcastWith(querySocket, data, _udpPort);
      AppLogger.i(_logTag, '配对码查询已发送：$roomCode');

      // 500ms 后重发
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!completer.isCompleted) {
          _sendUdpBroadcastWith(querySocket!, data, _udpPort);
          AppLogger.d(_logTag, '配对码查询重发第 1 次');
        }
      });

      // 1s 后重发
      Future.delayed(const Duration(seconds: 1), () {
        if (!completer.isCompleted) {
          _sendUdpBroadcastWith(querySocket!, data, _udpPort);
          AppLogger.d(_logTag, '配对码查询重发第 2 次');
        }
      });

      // 超时处理（5 秒，给重发留足时间）
      Future.delayed(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final result = await completer.future;
      return result;
    } catch (e) {
      AppLogger.e(_logTag, '配对码查询失败：$e');
      return null;
    } finally {
      // 确保 socket 在任何情况下都被关闭，防止资源泄漏
      querySocket?.close();
    }
  }

  /// 发送配对码回应（房主端，通过 UDP 回应查询者）
  /// [targetIp] 查询者的 IP
  /// [targetPort] 查询者的源端口（关键：必须响应到查询者的源端口）
  Future<void> sendCodeResponse(
      String targetIp, int targetPort, OnlineMessage response) async {
    try {
      final socket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final data = utf8.encode(response.toJsonString());

      // 1. 直接发送到查询者的 IP 和源端口（最可靠）
      socket.send(data, InternetAddress(targetIp), targetPort);
      AppLogger.i(_logTag, '配对码回应已发送到 $targetIp:$targetPort');

      // 2. 同时发送到查询者所在子网的广播地址
      final subnetBroadcast = _getSubnetBroadcast(targetIp);
      if (subnetBroadcast != '255.255.255.255') {
        socket.send(
            data, InternetAddress(subnetBroadcast), targetPort);
        AppLogger.d(
            _logTag, '配对码回应子网广播到 $subnetBroadcast:$targetPort');
      }

      // 3. 全网广播兜底
      socket.send(data, InternetAddress('255.255.255.255'), targetPort);

      // 短暂延迟确保数据发送完成后再关闭
      await Future.delayed(const Duration(milliseconds: 100));
      socket.close();
    } catch (e) {
      AppLogger.e(_logTag, '发送配对码回应失败：$e');
    }
  }

  /// 停止 UDP 广播
  void stopBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    AppLogger.i(_logTag, 'UDP 广播已停止');
  }

  /// 停止搜索
  /// 注意：如果正在广播（房主模式），不应关闭共享的 UDP socket
  void stopSearching() {
    // 仅在未广播时关闭 UDP socket（广播和搜索共享同一 socket）
    if (_broadcastTimer == null) {
      _udpSocket?.close();
      _udpSocket = null;
    }
    AppLogger.i(_logTag, '搜索已停止');
  }

  // ==================== 清理 ====================

  /// 关闭所有连接（房主端）
  Future<void> closeServer() async {
    stopBroadcasting();
    // 停止心跳检测
    _hostHeartbeatTimer?.cancel();
    _hostHeartbeatTimer = null;
    _clientLastHeartbeat.clear();
    // 关闭所有客户端 socket
    for (final socket in _clientSockets.values) {
      socket.destroy();
    }
    _clientSockets.clear();
    await _serverSocket?.close();
    _serverSocket = null;
    await releaseMulticastLock();
    AppLogger.i(_logTag, 'TCP 服务端已关闭');
  }

  /// 关闭客人连接
  Future<void> closeGuest() async {
    stopSearching();
    // 停止心跳发送
    _stopGuestHeartbeat();
    _guestSocket?.destroy();
    _guestSocket = null;
    await releaseMulticastLock();
    AppLogger.i(_logTag, '客人连接已关闭');
  }
}
