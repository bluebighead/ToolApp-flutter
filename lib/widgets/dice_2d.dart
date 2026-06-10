// 2D骰子组件
// 使用 AnimationController 实现弹跳+旋转动画
// 通过 CustomPaint 绘制骰子点数
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/dice_history.dart';

/// 2D骰子组件
class Dice2D extends StatefulWidget {
  /// 骰子类型
  final DiceType diceType;

  /// 当前结果（1 ~ sides），为 null 时显示问号
  final int? result;

  /// 是否正在动画中
  final bool isAnimating;

  /// 动画完成回调
  final VoidCallback? onAnimationEnd;

  const Dice2D({
    super.key,
    required this.diceType,
    this.result,
    this.isAnimating = false,
    this.onAnimationEnd,
  });

  @override
  State<Dice2D> createState() => _Dice2DState();
}

class _Dice2DState extends State<Dice2D> with TickerProviderStateMixin {
  late AnimationController _bounceController;
  late Animation<double> _bounceY; // 弹跳高度
  late Animation<double> _rotateZ; // 平面旋转
  late Animation<double> _scale; // 缩放

  // 当前显示的结果（动画结束后更新）
  int? _displayResult;

  @override
  void initState() {
    super.initState();
    _displayResult = widget.result;

    _bounceController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _bounceY = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.easeInOut),
    );
    _rotateZ = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.easeInOut),
    );
    _scale = Tween<double>(begin: 1, end: 1).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.easeInOut),
    );

    _bounceController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onAnimationEnd?.call();
      }
    });
  }

  @override
  void didUpdateWidget(Dice2D oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当外部触发动画时
    if (widget.isAnimating && !oldWidget.isAnimating) {
      _startAnimation();
    }
    // 当结果变化时更新显示
    if (!widget.isAnimating && widget.result != null) {
      _displayResult = widget.result;
    }
  }

  /// 开始掷骰子动画
  void _startAnimation() {
    final random = math.Random();
    // 生成随机旋转角度（多圈）
    final endRotate = (random.nextDouble() * 6 + 4) * math.pi;

    _bounceY = TweenSequence<double>([
      // 弹跳序列：多次弹跳，高度递减
      TweenSequenceItem(tween: Tween(begin: 0, end: -80), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -80, end: 0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0, end: -50), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -50, end: 0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0, end: -25), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -25, end: 0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _bounceController,
      curve: Curves.easeInOut,
    ));

    _rotateZ = Tween<double>(begin: 0, end: endRotate).animate(
      CurvedAnimation(parent: _bounceController, curve: Curves.easeOut),
    );

    _scale = TweenSequence<double>([
      // 缩放序列：弹起时缩小，落地时恢复
      TweenSequenceItem(tween: Tween(begin: 1, end: 0.85), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.85, end: 1.1), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.1, end: 0.9), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.05), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 0.95), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.02), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.02, end: 0.98), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.98, end: 1), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _bounceController,
      curve: Curves.easeInOut,
    ));

    _displayResult = null; // 动画期间清除显示
    _bounceController.forward(from: 0);
  }

  @override
  void dispose() {
    _bounceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bounceController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _bounceY.value),
          child: Transform.rotate(
            angle: _rotateZ.value,
            child: Transform.scale(
              scale: _scale.value,
              child: _DiceFace(
                diceType: widget.diceType,
                result: _displayResult,
                isAnimating: widget.isAnimating,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 骰子面绘制组件
class _DiceFace extends StatelessWidget {
  final DiceType diceType;
  final int? result;
  final bool isAnimating;

  const _DiceFace({
    required this.diceType,
    required this.result,
    required this.isAnimating,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 根据可用空间自适应骰子大小
        final size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 200,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 200,
        );
        return CustomPaint(
          size: size,
          painter: _DicePainter(
            diceType: diceType,
            result: result,
            isAnimating: isAnimating,
            diceSize: size,
          ),
        );
      },
    );
  }
}

/// 骰子绘制器
class _DicePainter extends CustomPainter {
  final DiceType diceType;
  final int? result;
  final bool isAnimating;
  final Size diceSize; // 骰子实际尺寸

  _DicePainter({
    required this.diceType,
    required this.result,
    required this.isAnimating,
    required this.diceSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 绘制骰子背景（圆角矩形）
    final bgPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final cornerRadius = size.width * 0.12; // 圆角半径按比例缩放
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(cornerRadius),
    );
    canvas.drawRRect(rect, bgPaint);

    // 绘制边框
    final borderPaint = Paint()
      ..color = Colors.grey.shade300
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(rect, borderPaint);

    // 绘制点数
    if (result != null && !isAnimating) {
      _drawDots(canvas, size, result!);
    } else if (isAnimating) {
      // 动画中显示随机点数（模拟快速变化）
      _drawDots(canvas, size, (math.Random().nextInt(diceType.sides) + 1));
    } else {
      // 没有结果时显示问号
      _drawQuestionMark(canvas, center);
    }
  }

  /// 绘制点数
  void _drawDots(Canvas canvas, Size size, int count) {
    final dotRadius = size.width / 14.0;
    final dotPaint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.fill;

    // D8+ 骰子只显示数字
    if (count > 6) {
      _drawNumber(canvas, size, count);
      return;
    }

    // 获取点数位置
    final positions = _getDotPositions(count, size);
    for (final pos in positions) {
      canvas.drawCircle(pos, dotRadius, dotPaint);
    }
  }

  /// 获取点数位置（标准骰子布局）
  List<Offset> _getDotPositions(int count, Size size) {
    final w = size.width;
    final h = size.height;
    final offset = w * 0.22; // 点偏离中心的距离
    final center = Offset(w / 2, h / 2);

    switch (count) {
      case 1:
        return [center];
      case 2:
        return [
          Offset(center.dx - offset, center.dy - offset),
          Offset(center.dx + offset, center.dy + offset),
        ];
      case 3:
        return [
          Offset(center.dx - offset, center.dy - offset),
          center,
          Offset(center.dx + offset, center.dy + offset),
        ];
      case 4:
        return [
          Offset(center.dx - offset, center.dy - offset),
          Offset(center.dx + offset, center.dy - offset),
          Offset(center.dx - offset, center.dy + offset),
          Offset(center.dx + offset, center.dy + offset),
        ];
      case 5:
        return [
          Offset(center.dx - offset, center.dy - offset),
          Offset(center.dx + offset, center.dy - offset),
          center,
          Offset(center.dx - offset, center.dy + offset),
          Offset(center.dx + offset, center.dy + offset),
        ];
      case 6:
        return [
          Offset(center.dx - offset, center.dy - offset),
          Offset(center.dx + offset, center.dy - offset),
          Offset(center.dx - offset, center.dy),
          Offset(center.dx + offset, center.dy),
          Offset(center.dx - offset, center.dy + offset),
          Offset(center.dx + offset, center.dy + offset),
        ];
      default:
        return [];
    }
  }

  /// 绘制数字（用于D8+骰子）
  void _drawNumber(Canvas canvas, Size size, int number) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          fontSize: 72,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        size.width / 2 - textPainter.width / 2,
        size.height / 2 - textPainter.height / 2,
      ),
    );
  }

  /// 绘制问号
  void _drawQuestionMark(Canvas canvas, Offset center) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: '?',
        style: TextStyle(
          fontSize: 80,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade400,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _DicePainter oldDelegate) {
    return oldDelegate.result != result ||
        oldDelegate.isAnimating != isAnimating ||
        oldDelegate.diceSize != diceSize;
  }
}
