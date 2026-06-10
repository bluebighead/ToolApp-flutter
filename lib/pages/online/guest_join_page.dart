// 客人入口页
// 提供配对码输入和局域网搜索两种加入方式
// 首次进入时需要输入玩家名称
// 检测到活跃房间时提示用户先退出
import 'package:flutter/material.dart';

import '../../models/online_message.dart';
import '../../models/online_room.dart';
import '../../services/lan_service.dart';
import '../../services/online_game_service.dart';
import '../../services/online_overlay_manager.dart';
import 'online_dice_page.dart';
import 'waiting_room_page.dart';

class GuestJoinPage extends StatefulWidget {
  const GuestJoinPage({super.key});

  @override
  State<GuestJoinPage> createState() => _GuestJoinPageState();
}

class _GuestJoinPageState extends State<GuestJoinPage> {
  static const String _logTag = 'GuestJoinPage';

  /// 4 位配对码输入控制器
  final List<TextEditingController> _codeControllers = List.generate(
    4,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _codeFocusNodes = List.generate(4, (_) => FocusNode());

  /// 玩家名称
  String _playerName = '';

  /// 是否正在加入
  bool _isJoining = false;

  /// 是否正在搜索
  bool _isSearching = false;

  /// 搜索到的房间列表
  final Map<String, _RoomInfo> _foundRooms = {};

  /// OnlineGameService 实例（搜索时使用）
  OnlineGameService? _searchService;

  /// 当前 WiFi SSID
  String _wifiSsid = '';

  /// 是否有活跃房间
  bool _hasActiveRoom = false;
  String _activeRoomName = '';

  @override
  void initState() {
    super.initState();
    _loadPlayerName();
    _loadWifiSsid();
    _checkActiveRoom();
  }

  /// 检查是否有活跃房间
  void _checkActiveRoom() {
    final manager = OnlineOverlayManager();
    if (manager.hasActiveService) {
      setState(() {
        _hasActiveRoom = true;
        _activeRoomName = manager.activeService?.room?.roomName ?? '联机房间';
      });
    }
  }

  /// 加载 WiFi SSID
  Future<void> _loadWifiSsid() async {
    final ssid = await LanService.getWifiSsid();
    if (mounted) {
      setState(() => _wifiSsid = ssid);
    }
  }

  @override
  void dispose() {
    for (final c in _codeControllers) {
      c.dispose();
    }
    for (final f in _codeFocusNodes) {
      f.dispose();
    }
    // 释放搜索服务资源
    _searchService?.stopSearching();
    _searchService = null;
    super.dispose();
  }

  /// 加载玩家名称
  Future<void> _loadPlayerName() async {
    final name = await OnlineGameService.getPlayerName();
    if (name.isEmpty && mounted) {
      // 首次进入，弹出名称输入对话框
      _showNameDialog();
    } else {
      setState(() => _playerName = name);
    }
  }

  /// 显示玩家名称输入对话框
  Future<void> _showNameDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('输入玩家名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入你的名称',
            border: OutlineInputBorder(),
          ),
          maxLength: 10,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(ctx).pop(name);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await OnlineGameService.savePlayerName(result);
      if (mounted) setState(() => _playerName = result);
    }
  }

  /// 获取完整配对码
  String get _roomCode =>
      _codeControllers.map((c) => c.text).join();

  /// 配对码是否输入完整
  bool get _isCodeComplete => _roomCode.length == 4;

  /// 检查活跃房间并显示提示
  Future<bool> _checkActiveRoomAndPrompt() async {
    if (OnlineOverlayManager().hasActiveService) {
      final roomName = OnlineOverlayManager().activeService?.room?.roomName ?? '联机房间';
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('检测到活跃房间'),
          content: Text(
            '你当前还在房间「$roomName」中。\n\n'
            '请先返回房间或退出房间后再加入新房间。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                OnlineOverlayManager().navigateToRoomPage(context);
              },
              child: const Text('返回房间'),
            ),
            ElevatedButton(
              onPressed: () async {
                // 退出当前房间
                Navigator.of(ctx).pop(true);
                final service = OnlineOverlayManager().activeService;
                if (service != null) {
                  if (service.isHost) {
                    await service.closeRoom();
                  } else {
                    await service.leaveRoom();
                  }
                  OnlineOverlayManager().unregisterService();
                }
              },
              child: const Text('退出房间'),
            ),
          ],
        ),
      );
      return result == true;
    }
    return true;
  }

  /// 通过配对码加入
  Future<void> _joinByCode() async {
    if (!_isCodeComplete || _isJoining) return;

    // 检查活跃房间
    final canProceed = await _checkActiveRoomAndPrompt();
    if (!canProceed) return;

    // 检查玩家名称
    if (_playerName.isEmpty) {
      await _showNameDialog();
      if (_playerName.isEmpty) return;
    }

    setState(() => _isJoining = true);

    final service = OnlineGameService();
    service.onRoomChanged = (room) {
      if (!mounted) return;
      // 加入成功后跳转：如果房间已满或游戏已开始，直接进入游戏页
      if (room.isFull || room.state == RoomState.playing || room.state == RoomState.finished) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OnlineDicePage(gameService: service),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => WaitingRoomPage(gameService: service),
          ),
        );
      }
    };

    final success = await service.joinByCode(_roomCode, _playerName);

    if (!mounted) return;

    if (!success) {
      setState(() => _isJoining = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到该配对码的房间，请检查后重试')),
      );
    } else {
      // 注册到全局管理器
      OnlineOverlayManager().registerService(service);
      OnlineOverlayManager().isInOnlinePage = true;
    }
  }

  /// 开始搜索局域网房间
  Future<void> _startSearch() async {
    if (_isSearching) return;

    // 检查活跃房间
    final canProceed = await _checkActiveRoomAndPrompt();
    if (!canProceed) return;

    setState(() {
      _isSearching = true;
      _foundRooms.clear();
    });

    _searchService = OnlineGameService();
    await _searchService!.searchRooms(
      onRoomFound: (OnlineMessage message, String fromIp) {
        if (!mounted) return;
        final roomCode = message.data['roomCode'] as String? ?? '';
        final roomName = message.data['roomName'] as String? ?? '';
        final currentPlayers = message.data['currentPlayers'] as int? ?? 0;
        final maxPlayers = message.data['maxPlayers'] as int? ?? 0;
        final diceType = message.data['diceType'] as String? ?? '';
        final diceCount = message.data['diceCount'] as int? ?? 0;
        final hostIp = message.data['hostIp'] as String? ?? '';
        final hostPort = message.data['hostPort'] as int? ?? 19876;

        setState(() {
          _foundRooms[roomCode] = _RoomInfo(
            roomCode: roomCode,
            roomName: roomName,
            currentPlayers: currentPlayers,
            maxPlayers: maxPlayers,
            diceType: diceType,
            diceCount: diceCount,
            hostIp: hostIp,
            hostPort: hostPort,
          );
        });
      },
    );

    // 5 秒后停止搜索
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isSearching = false);
        _searchService?.stopSearching();
      }
    });
  }

  /// 通过搜索结果加入房间
  Future<void> _joinBySearch(_RoomInfo roomInfo) async {
    // 检查活跃房间
    final canProceed = await _checkActiveRoomAndPrompt();
    if (!canProceed) return;

    // 检查玩家名称
    if (_playerName.isEmpty) {
      await _showNameDialog();
      if (_playerName.isEmpty) return;
    }

    // 先停止搜索并释放搜索服务资源
    _searchService?.stopSearching();
    _searchService = null;

    setState(() => _isJoining = true);

    final service = OnlineGameService();
    service.onRoomChanged = (room) {
      if (!mounted) return;
      // 加入成功后跳转：如果房间已满或游戏已开始，直接进入游戏页
      if (room.isFull || room.state == RoomState.playing || room.state == RoomState.finished) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OnlineDicePage(gameService: service),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => WaitingRoomPage(gameService: service),
          ),
        );
      }
    };

    final success = await service.joinBySearch(
      roomInfo.hostIp,
      roomInfo.hostPort,
      _playerName,
    );

    if (!mounted) return;

    if (!success) {
      setState(() => _isJoining = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加入房间失败')),
      );
    } else {
      // 注册到全局管理器
      OnlineOverlayManager().registerService(service);
      OnlineOverlayManager().isInOnlinePage = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('加入房间')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 活跃房间提示横幅
            if (_hasActiveRoom) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info, color: Colors.orange.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '你当前还在房间「$_activeRoomName」中',
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        OnlineOverlayManager().navigateToRoomPage(context);
                      },
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 玩家名称显示
            if (_playerName.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.person, color: theme.primaryColor, size: 20),
                    const SizedBox(width: 8),
                    Text('玩家：$_playerName',
                        style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: theme.primaryColor)),
                    const Spacer(),
                    GestureDetector(
                      onTap: _showNameDialog,
                      child: Text('修改',
                          style: TextStyle(
                              color: theme.primaryColor, fontSize: 12)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // 当前 WiFi 网络名称
            if (_wifiSsid.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi, size: 14, color: theme.primaryColor),
                    const SizedBox(width: 4),
                    Text(
                      '当前网络：$_wifiSsid',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            if (_wifiSsid.isNotEmpty) const SizedBox(height: 12),

            // 配对码输入
            Text('输入配对码',
                style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 16,
                    color: Colors.grey.shade700)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (index) {
                return Container(
                  width: 56,
                  height: 64,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  child: TextField(
                    controller: _codeControllers[index],
                    focusNode: _codeFocusNodes[index],
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    maxLength: 1,
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      counterText: '',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onChanged: (value) {
                      if (value.isNotEmpty && index < 3) {
                        _codeFocusNodes[index + 1].requestFocus();
                      }
                      setState(() {});
                    },
                  ),
                );
              }),
            ),
            const SizedBox(height: 20),

            // 加入按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isCodeComplete && !_isJoining ? _joinByCode : null,
                icon: _isJoining
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.login),
                label: Text(_isJoining ? '加入中...' : '加入房间'),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // 分隔线
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('或者',
                      style: TextStyle(color: Colors.grey.shade500)),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 24),

            // 搜索房间按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _isSearching ? null : _startSearch,
                icon: _isSearching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: Text(_isSearching ? '搜索中...' : '搜索局域网房间'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

            // 搜索结果列表
            if (_foundRooms.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('发现的房间',
                  style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 8),
              ..._foundRooms.values.map((room) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.meeting_room),
                      title: Text(room.roomName),
                      subtitle: Text(
                          '${room.currentPlayers}/${room.maxPlayers} 人 · ${room.diceType.toUpperCase()} x${room.diceCount}'),
                      trailing: Text(room.roomCode,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.primaryColor,
                              letterSpacing: 2)),
                      onTap: room.currentPlayers < room.maxPlayers
                          ? () => _joinBySearch(room)
                          : null,
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

/// 搜索到的房间信息
class _RoomInfo {
  final String roomCode;
  final String roomName;
  final int currentPlayers;
  final int maxPlayers;
  final String diceType;
  final int diceCount;
  final String hostIp;
  final int hostPort;

  const _RoomInfo({
    required this.roomCode,
    required this.roomName,
    required this.currentPlayers,
    required this.maxPlayers,
    required this.diceType,
    required this.diceCount,
    required this.hostIp,
    required this.hostPort,
  });
}
