// 等待页
// 房主创建房间后显示配对码和已加入玩家列表
// 满员后自动进入联机游戏页
import 'package:flutter/material.dart';

import '../../models/online_room.dart';
import '../../services/lan_service.dart';
import '../../services/online_game_service.dart';
import '../../services/online_overlay_manager.dart';
import '../../utils/app_logger.dart';
import 'online_dice_page.dart';

class WaitingRoomPage extends StatefulWidget {
  final OnlineGameService gameService;

  const WaitingRoomPage({super.key, required this.gameService});

  @override
  State<WaitingRoomPage> createState() => _WaitingRoomPageState();
}

class _WaitingRoomPageState extends State<WaitingRoomPage>
    with WidgetsBindingObserver {
  static const String _logTag = 'WaitingRoomPage';

  OnlineRoom? _room;
  String _wifiSsid = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _room = widget.gameService.room;
    widget.gameService.onRoomChanged = _onRoomChanged;
    // 注册到全局管理器
    OnlineOverlayManager().registerService(widget.gameService);
    OnlineOverlayManager().isInOnlinePage = true;
    _loadWifiSsid();
  }

  /// 加载 WiFi SSID
  Future<void> _loadWifiSsid() async {
    final ssid = await LanService.getWifiSsid();
    if (mounted) {
      setState(() => _wifiSsid = ssid);
    }
  }

  // 标记是否因跳转到游戏页而 dispose（避免错误设置 isInOnlinePage=false）
  bool _isNavigatingToGame = false;

  void _onRoomChanged(OnlineRoom room) {
    if (!mounted) return;
    setState(() => _room = room);

    // 满员后或游戏已开始时，自动进入联机游戏页
    if (room.isFull || room.state == RoomState.playing || room.state == RoomState.finished) {
      _isNavigatingToGame = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OnlineDicePage(gameService: widget.gameService),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 仅在非跳转到游戏页时才清空回调和更新状态
    // 跳转到游戏页时，新页面的 initState 会先设置新的回调，
    // 此时本页面 dispose 不应覆盖新页面的回调
    if (!_isNavigatingToGame) {
      widget.gameService.onRoomChanged = null;
      OnlineOverlayManager().isInOnlinePage = false;
    }
    super.dispose();
  }

  /// 监听应用前后台切换
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    AppLogger.i(_logTag, '应用生命周期变化：$state');

    if (state == AppLifecycleState.paused) {
      OnlineOverlayManager().isInOnlinePage = false;
      OnlineOverlayManager().tryShowFloatingButton();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) {
        OnlineOverlayManager().isInOnlinePage = true;
      }
    }
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
          title: const Text('等待玩家加入'),
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
        body: _room == null
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    // 当前 WiFi 网络名称
                    if (_wifiSsid.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.wifi,
                                size: 14, color: theme.primaryColor),
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
                    if (_wifiSsid.isNotEmpty) const SizedBox(height: 16),

                    // 已加入人数
                    Text(
                      '${_room!.currentPlayers} / ${_room!.maxPlayers}',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.primaryColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已加入 / 总人数',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 32),

                    // 配对码
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: theme.primaryColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.primaryColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text('配对码',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.grey.shade600)),
                          const SizedBox(height: 8),
                          Text(
                            _room!.roomCode,
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 12,
                              color: theme.primaryColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text('告诉朋友输入此配对码加入房间',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 已加入玩家列表
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('已加入的玩家',
                          style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade700)),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _room!.players.length,
                        itemBuilder: (ctx, index) {
                          final player = _room!.players[index];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: player.isHost
                                  ? theme.primaryColor
                                  : Colors.grey.shade300,
                              child: Icon(
                                player.isHost ? Icons.star : Icons.person,
                                color: player.isHost
                                    ? Colors.white
                                    : Colors.grey.shade700,
                                size: 20,
                              ),
                            ),
                            title: Text(player.name),
                            trailing: player.isHost
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: theme.primaryColor
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text('房主',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: theme.primaryColor,
                                          fontWeight: FontWeight.bold,
                                        )),
                                  )
                                : null,
                          );
                        },
                      ),
                    ),

                    // 底部提示
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        isHost
                            ? '按返回键可将房间后台，再次进入可通过悬浮按钮'
                            : '按返回键可将房间后台，再次进入可通过悬浮按钮',
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
}
