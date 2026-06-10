// 联机模式全局悬浮按钮管理器
// 负责管理活跃的游戏服务和悬浮按钮显示
// 当用户无意退出房间界面时，显示悬浮按钮以便随时返回
import 'package:flutter/material.dart';

import 'online_game_service.dart';
import '../pages/online/waiting_room_page.dart';
import '../pages/online/online_dice_page.dart';
import '../utils/app_logger.dart';

/// 悬浮按钮管理器
class OnlineOverlayManager {
  static final OnlineOverlayManager _instance =
      OnlineOverlayManager._internal();

  factory OnlineOverlayManager() => _instance;
  OnlineOverlayManager._internal();

  static const String _logTag = 'OnlineOverlayManager';

  /// 当前活跃的游戏服务
  OnlineGameService? _activeService;

  /// 当前悬浮按钮的 OverlayEntry
  OverlayEntry? _overlayEntry;

  /// 当前是否在联机页面内（用于判断是否显示悬浮按钮）
  bool _isInOnlinePage = false;

  /// 用于获取根 Navigator 的 GlobalKey
  GlobalKey<NavigatorState>? _navigatorKey;

  /// 设置根 Navigator 的 GlobalKey（用于更可靠地获取上下文）
  set navigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
  }

  /// 获取当前活跃的游戏服务
  OnlineGameService? get activeService => _activeService;

  /// 是否有活跃的游戏服务
  bool get hasActiveService => _activeService?.room != null;

  /// 当前是否在联机页面内
  bool get isInOnlinePage => _isInOnlinePage;

  /// 当前是否显示悬浮按钮
  bool get isFloatingButtonVisible => _overlayEntry != null;

  /// 设置是否在联机页面内
  set isInOnlinePage(bool value) {
    if (_isInOnlinePage == value) {
      // 值没有变化，无需做任何操作
      return;
    }
    _isInOnlinePage = value;
    AppLogger.i(_logTag, '设置 isInOnlinePage=$value, hasActiveService=$hasActiveService');
    if (value) {
      // 进入联机页面，隐藏悬浮按钮
      hideFloatingButton();
    } else if (hasActiveService) {
      // 离开联机页面但有活跃房间，显示悬浮按钮
      _showFloatingButton();
    }
  }

  /// 尝试显示悬浮按钮（给外部调用的一个便捷方法）
  void tryShowFloatingButton() {
    if (!_isInOnlinePage && hasActiveService) {
      _showFloatingButton();
    }
  }

  /// 注册活跃的游戏服务（进入房间时调用）
  void registerService(OnlineGameService service) {
    _activeService = service;
    AppLogger.i(_logTag, '注册游戏服务：${service.room?.roomName}');
  }

  /// 取消注册游戏服务（真正退出房间时调用）
  void unregisterService() {
    final wasActive = _activeService != null;
    _activeService = null;
    hideFloatingButton();
    if (wasActive) {
      AppLogger.i(_logTag, '取消注册游戏服务');
    }
  }

  /// 获取可用的 BuildContext
  BuildContext? _getContext() {
    // 优先使用 NavigatorKey 的上下文（最可靠）
    final navigatorState = _navigatorKey?.currentState;
    if (navigatorState != null) {
      return navigatorState.context;
    }

    // 其次使用 NavigatorKey 的当前 context
    final keyContext = _navigatorKey?.currentContext;
    if (keyContext != null) {
      return keyContext;
    }

    AppLogger.w(_logTag, '无法获取可用的上下文');
    return null;
  }

  /// 导航回房间页面（从悬浮按钮点击调用）
  void navigateToRoomPage(BuildContext? context) {
    if (_activeService == null) return;
    final room = _activeService!.room;
    if (room == null) return;

    // 防止重复导航：如果已经在联机页面内，不重复 push
    if (_isInOnlinePage) {
      AppLogger.w(_logTag, '已在联机页面内，忽略重复导航');
      return;
    }

    AppLogger.i(_logTag, '从悬浮按钮返回房间，状态=${room.state}');

    final targetContext = context ?? _getContext();
    if (targetContext == null) {
      AppLogger.w(_logTag, '无法获取上下文，导航失败');
      return;
    }

    final isWaitingState = (room.state.name == 'waiting' ||
        room.state.name == 'ready');
    final page = isWaitingState
        ? WaitingRoomPage(gameService: _activeService!)
        : OnlineDicePage(gameService: _activeService!);

    // 标记即将进入联机页面（在 push 之前设置，防止快速双击重复 push）
    _isInOnlinePage = true;
    hideFloatingButton();

    try {
      Navigator.of(targetContext, rootNavigator: true).push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => page,
          transitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (_, anim, __, child) {
            return FadeTransition(opacity: anim, child: child);
          },
        ),
      );
    } catch (e) {
      AppLogger.w(_logTag, '导航失败，尝试使用根 Navigator: $e');
      // 再次尝试使用根 Navigator
      try {
        Navigator.of(targetContext).push(
          MaterialPageRoute(builder: (_) => page),
        );
      } catch (e2) {
        AppLogger.e(_logTag, '导航完全失败: $e2');
        _isInOnlinePage = false;
        _showFloatingButton();
      }
    }
  }

  /// 获取可用的 OverlayState
  OverlayState? _getOverlay() {
    // 方案1：优先通过 NavigatorKey 获取根 Navigator 的 overlay（最可靠）
    final navigatorState = _navigatorKey?.currentState;
    if (navigatorState != null) {
      try {
        // NavigatorState 内部有 overlay 属性，但该属性是 protected 的。
        // 因此尝试通过 context 获取根级别的 Overlay。
        final ctx = navigatorState.context;
        final overlay = Overlay.maybeOf(ctx, rootOverlay: true);
        if (overlay != null) {
          AppLogger.d(_logTag, '通过 NavigatorKey.context 获取 Overlay 成功');
          return overlay;
        }
      } catch (e) {
        AppLogger.w(_logTag, '通过 NavigatorKey.context 获取 Overlay 异常: $e');
      }
    }

    // 方案2：使用 NavigatorKey 的 currentContext
    final keyContext = _navigatorKey?.currentContext;
    if (keyContext != null) {
      try {
        final overlay = Overlay.maybeOf(keyContext, rootOverlay: true);
        if (overlay != null) {
          AppLogger.d(_logTag, '通过 currentContext 获取 Overlay 成功');
          return overlay;
        }
      } catch (e) {
        AppLogger.w(_logTag, '通过 currentContext 获取 Overlay 异常: $e');
      }
    }

    AppLogger.w(_logTag, '无法获取 Overlay，navigatorKey=${_navigatorKey != null ? '已设置' : '未设置'}');
    return null;
  }

  /// 显示悬浮按钮
  void _showFloatingButton() {
    if (_overlayEntry != null) {
      AppLogger.i(_logTag, '悬浮按钮已显示，跳过');
      return;
    }

    if (_isInOnlinePage) {
      AppLogger.i(_logTag, '当前在联机页面内，不显示悬浮按钮');
      return;
    }

    final overlay = _getOverlay();
    if (overlay == null) {
      AppLogger.w(_logTag, '显示悬浮按钮失败：无法获取 Overlay');
      return;
    }

    try {
      _overlayEntry = OverlayEntry(
        builder: (ctx) => _FloatingRoomButton(
          onTap: () => navigateToRoomPage(ctx),
        ),
      );

      overlay.insert(_overlayEntry!);
      AppLogger.i(_logTag, '显示悬浮按钮成功');
    } catch (e) {
      AppLogger.e(_logTag, '显示悬浮按钮异常: $e');
      _overlayEntry = null;
    }
  }

  /// 隐藏悬浮按钮
  void hideFloatingButton() {
    try {
      _overlayEntry?.remove();
    } catch (e) {
      AppLogger.w(_logTag, '移除悬浮按钮异常: $e');
    }
    _overlayEntry = null;
    AppLogger.i(_logTag, '悬浮按钮已隐藏');
  }
}

/// 悬浮按钮组件
class _FloatingRoomButton extends StatefulWidget {
  final VoidCallback onTap;

  const _FloatingRoomButton({required this.onTap});

  @override
  State<_FloatingRoomButton> createState() => _FloatingRoomButtonState();
}

class _FloatingRoomButtonState extends State<_FloatingRoomButton> {
  double _top = 120;
  double _left = 16;
  bool _isDragging = false;
  bool _isDraggable = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 确保按钮位置在屏幕范围内
    final size = MediaQuery.of(context).size;
    _left = _left.clamp(0.0, size.width - 72.0);
    _top = _top.clamp(60.0, size.height - 120.0);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    const btnSize = 56.0;
    const btnWithPadding = 72.0;

    return Positioned(
      top: _top,
      left: _left,
      child: GestureDetector(
        onPanStart: (_) {
          if (_isDraggable) {
            setState(() => _isDragging = true);
          }
        },
        onPanEnd: (_) {
          if (_isDragging) {
            setState(() => _isDragging = false);
            // 自动吸附到左边或右边
            final screenWidth = screenSize.width;
            setState(() {
              if (_left + btnSize / 2 < screenWidth / 2) {
                _left = 16.0;
              } else {
                _left = screenWidth - btnWithPadding;
              }
            });
          }
        },
        onPanUpdate: (details) {
          if (!_isDraggable) return;
          setState(() {
            _top = (details.globalPosition.dy - btnSize / 2).clamp(
              60.0,
              screenSize.height - btnSize - 100,
            );
            _left = (details.globalPosition.dx - btnSize / 2).clamp(
              0.0,
              screenSize.width - btnWithPadding,
            );
          });
        },
        child: AnimatedScale(
          scale: _isDragging ? 1.15 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: btnSize,
                height: btnSize,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).primaryColor,
                      Theme.of(context)
                          .primaryColor
                          .withValues(alpha: 0.75),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: _isDragging ? 20 : 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.casino,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
