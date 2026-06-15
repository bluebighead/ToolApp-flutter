// 顶部浮动提示工具
// 在屏幕顶部显示短暂的浮动提示，不遮挡底部操作区域
// 使用 Overlay 实现，无需依赖第三方库
// 支持成功/错误/信息三种类型，自动消失
import 'dart:async';

import 'package:flutter/material.dart';

// 提示类型枚举
enum ToastType { success, error, info, warning }

class TopToast {
  // 当前显示的 OverlayEntry，用于防止重复弹出
  static OverlayEntry? _currentEntry;
  // 自动关闭的定时器
  static Timer? _timer;

  // 显示顶部浮动提示
  // [context] BuildContext，用于获取 Overlay
  // [message] 提示文字
  // [type] 提示类型（成功/错误/信息），影响颜色和图标
  // [duration] 显示时长，默认 2 秒
  static void show(
    BuildContext context, {
    required String message,
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    // 先关闭已有的提示
    dismiss();

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        type: type,
        onClose: dismiss,
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    // 设置自动关闭定时器
    _timer = Timer(duration, dismiss);
  }

  // 手动关闭提示
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

// 提示组件
class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final VoidCallback onClose;

  const _ToastWidget({
    required this.message,
    required this.type,
    required this.onClose,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  // 入场/出场动画控制器
  late AnimationController _controller;
  // 滑动 + 淡入淡出动画
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    // 动画时长 250ms
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    // 从顶部滑入
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    // 淡入
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // 启动入场动画
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 获取提示类型对应的颜色
  Color get _backgroundColor {
    switch (widget.type) {
      case ToastType.success:
        return Colors.green.shade600;
      case ToastType.error:
        return Colors.red.shade600;
      case ToastType.info:
        return Colors.blue.shade600;
      case ToastType.warning:
        return Colors.orange.shade600;
    }
  }

  // 获取提示类型对应的图标
  IconData get _icon {
    switch (widget.type) {
      case ToastType.success:
        return Icons.check_circle_outline;
      case ToastType.error:
        return Icons.error_outline;
      case ToastType.info:
        return Icons.info_outline;
      case ToastType.warning:
        return Icons.warning_amber_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 获取状态栏高度，确保提示在状态栏下方
    final statusBarHeight = MediaQuery.of(context).padding.top;

    return Positioned(
      top: statusBarHeight + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _backgroundColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  // 类型图标
                  Icon(_icon, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  // 提示文字
                  Expanded(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // 关闭按钮
                  GestureDetector(
                    onTap: widget.onClose,
                    child: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
