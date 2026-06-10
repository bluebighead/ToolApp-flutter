// 联机掷骰子入口页
// 提供房主/客人两个入口按钮
// 显示当前连接的 WiFi 网络名称
// 检测到活跃房间时提示用户返回
import 'package:flutter/material.dart';

import '../../services/lan_service.dart';
import '../../services/online_overlay_manager.dart';
import '../../utils/app_logger.dart';
import 'guest_join_page.dart';
import 'host_setup_page.dart';

class OnlineLobbyPage extends StatefulWidget {
  const OnlineLobbyPage({super.key});

  @override
  State<OnlineLobbyPage> createState() => _OnlineLobbyPageState();
}

class _OnlineLobbyPageState extends State<OnlineLobbyPage> {
  static const String _logTag = 'OnlineLobbyPage';

  /// 当前 WiFi SSID
  String _wifiSsid = '';

  /// 是否有活跃房间（用于 UI 显示）
  bool _hasActiveRoom = false;

  /// 活跃房间名称
  String _activeRoomName = '';

  @override
  void initState() {
    super.initState();
    _loadWifiSsid();
    _checkActiveRoom();
  }

  /// 加载 WiFi SSID
  Future<void> _loadWifiSsid() async {
    final ssid = await LanService.getWifiSsid();
    if (mounted) {
      setState(() => _wifiSsid = ssid);
    }
  }

  /// 检查是否有活跃房间
  void _checkActiveRoom() {
    final manager = OnlineOverlayManager();
    if (manager.hasActiveService) {
      setState(() {
        _hasActiveRoom = true;
        _activeRoomName = manager.activeService?.room?.roomName ?? '联机房间';
      });
      AppLogger.i(_logTag, '检测到活跃房间：$_activeRoomName');
    }
  }

  /// 点击房主按钮
  void _onHostPressed() {
    if (OnlineOverlayManager().hasActiveService) {
      // 有活跃房间，提示用户
      _showActiveRoomDialog('创建新房间');
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HostSetupPage()),
      );
    }
  }

  /// 点击客人按钮
  void _onGuestPressed() {
    if (OnlineOverlayManager().hasActiveService) {
      // 有活跃房间，提示用户
      _showActiveRoomDialog('加入新房间');
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GuestJoinPage()),
      );
    }
  }

  /// 显示活跃房间提示对话框
  void _showActiveRoomDialog(String actionName) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检测到活跃房间'),
        content: Text(
          '你当前还在房间「$_activeRoomName」中。\n\n'
          '返回现有房间还是退出房间后$actionName？',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(false);
              // 返回现有房间
              OnlineOverlayManager().navigateToRoomPage(context);
            },
            child: const Text('返回房间'),
          ),
          TextButton(
            onPressed: () {
              // 退出当前房间，然后继续操作
              Navigator.of(ctx).pop(true);
              _leaveAndProceed(actionName);
            },
            child: const Text('退出后继续'),
          ),
        ],
      ),
    );
  }

  /// 退出房间后继续操作
  Future<void> _leaveAndProceed(String actionName) async {
    final service = OnlineOverlayManager().activeService;
    if (service != null) {
      // 退出房间（房主关闭/客人离开）
      if (service.isHost) {
        await service.closeRoom();
      } else {
        await service.leaveRoom();
      }
      OnlineOverlayManager().unregisterService();
      AppLogger.i(_logTag, '用户选择退出房间后$actionName');
    }

    setState(() {
      _hasActiveRoom = false;
      _activeRoomName = '';
    });

    // 跳转至相应页面
    if (actionName == '创建新房间') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HostSetupPage()),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GuestJoinPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('联机掷骰子')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
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

              // 标题图标
              Icon(Icons.wifi, size: 64, color: theme.primaryColor),
              const SizedBox(height: 16),
              Text(
                '联机掷骰子',
                style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              // 当前 WiFi 网络名称
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi, size: 16, color: theme.primaryColor),
                    const SizedBox(width: 6),
                    Text(
                      _wifiSsid.isNotEmpty
                          ? '当前网络：$_wifiSsid'
                          : '未检测到 WiFi 网络',
                      style: TextStyle(
                        fontSize: 13,
                        color: _wifiSsid.isNotEmpty
                            ? theme.primaryColor
                            : Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              // 房主按钮
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _onHostPressed,
                  icon: const Icon(Icons.admin_panel_settings),
                  label: const Text('我是房主', style: TextStyle(fontSize: 18)),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 客人按钮
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _onGuestPressed,
                  icon: const Icon(Icons.login),
                  label: const Text('我是客人', style: TextStyle(fontSize: 18)),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
