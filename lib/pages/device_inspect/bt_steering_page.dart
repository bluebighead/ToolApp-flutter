import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/bluetooth_debugger.dart';
import '../../services/steering_settings.dart';
import 'steering_adjust_dialog.dart';

class BtSteeringPage extends StatefulWidget {
  final BluetoothDebugger debugger;

  const BtSteeringPage({super.key, required this.debugger});

  @override
  State<BtSteeringPage> createState() => _BtSteeringPageState();
}

class _BtSteeringPageState extends State<BtSteeringPage> {
  final List<String> _commandLog = [];
  String? _selectedServiceUuid;
  String? _selectedCharUuid;
  Offset _joystickOffset = Offset.zero;
  final SteeringSettings _steerSettings = SteeringSettings();

  @override
  void initState() {
    super.initState();
    _autoSelectCharacteristic();
    _steerSettings.load();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _autoSelectCharacteristic() {
    final services = widget.debugger.services;
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (ch.isWritableWithoutResponse || ch.isWritableWithResponse) {
          _selectedServiceUuid = svc.uuid;
          _selectedCharUuid = ch.uuid;
          return;
        }
      }
    }
  }

  Future<void> _sendCommand(String label, List<int> data) async {
    if (_selectedServiceUuid == null || _selectedCharUuid == null) {
      _addLog('❌ 未选择可写入的特征值');
      return;
    }
    final ok = await widget.debugger.writeWithoutResponse(
      _selectedServiceUuid!,
      _selectedCharUuid!,
      data,
    );
    if (ok) {
      _addLog('$label → ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    } else {
      _addLog('❌ $label 发送失败');
    }
  }

  void _addLog(String msg) {
    setState(() {
      _commandLog.insert(0, '[${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}] $msg');
      if (_commandLog.length > 50) _commandLog.removeLast();
    });
  }

  void _showCharacteristicPicker() {
    final services = widget.debugger.services;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text('选择写入特征值', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            for (final svc in services)
              ...svc.characteristics.where((c) => c.isWritableWithoutResponse || c.isWritableWithResponse).map((ch) {
                final isSelected = ch.uuid == _selectedCharUuid;
                return ListTile(
                  selected: isSelected,
                  title: Text(ch.uuid, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  subtitle: Text('${svc.uuid.substring(0, 8)}… | ${ch.isWritableWithoutResponse ? "无响应" : "有响应"}'),
                  trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF1A73E8)) : null,
                  onTap: () {
                    setState(() {
                      _selectedServiceUuid = svc.uuid;
                      _selectedCharUuid = ch.uuid;
                    });
                    Navigator.pop(ctx);
                  },
                );
              }),
          ],
        );
      },
    );
  }

  void _showMenu() {
    // 侧边栏菜单，支持上下滑动
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '菜单',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: const Color(0xFF16213E),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              bottomLeft: Radius.circular(16),
            ),
            child: Container(
              width: 220,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            const Text('菜单', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => Navigator.pop(ctx),
                              child: Icon(Icons.close, color: Colors.white.withValues(alpha: 0.5), size: 20),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: Colors.white12, height: 1),
                      // 调整控制器
                      ListTile(
                        leading: const Icon(Icons.tune, color: Colors.white70),
                        title: const Text('调整控制器', style: TextStyle(color: Colors.white)),
                        subtitle: Text(
                          '左${(_steerSettings.leftSizeScale * 100).round()}% 右${(_steerSettings.rightSizeScale * 100).round()}% 透明${(_steerSettings.panelOpacity * 100).round()}%',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await SteeringAdjustPanel.show(context, settings: _steerSettings, onChanged: () => setState(() {}));
                        },
                      ),
                      // 切换特征值
                      ListTile(
                        leading: const Icon(Icons.settings, color: Colors.white70),
                        title: const Text('切换特征值', style: TextStyle(color: Colors.white)),
                        subtitle: Text(_selectedCharUuid ?? '未选择', style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace')),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showCharacteristicPicker();
                        },
                      ),
                      // 断开连接
                      if (widget.debugger.isConnected)
                        ListTile(
                          leading: const Icon(Icons.link_off, color: Colors.orangeAccent),
                          title: const Text('断开连接', style: TextStyle(color: Colors.white)),
                          onTap: () {
                            widget.debugger.disconnect();
                            Navigator.pop(ctx);
                            Navigator.pop(context);
                          },
                        ),
                      // 退出方向盘
                      ListTile(
                        leading: const Icon(Icons.logout, color: Colors.redAccent),
                        title: const Text('退出方向盘', style: TextStyle(color: Colors.white)),
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim1, anim2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: _steerSettings.displayHeight,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availW = constraints.maxWidth;
                      final areaW = availW * _steerSettings.displayWidthPct / 100.0;
                      final centerX = availW * _steerSettings.displayOffsetPct / 20000.0;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            top: 0,
                            left: centerX - areaW / 2,
                            child: Container(
                              width: areaW,
                              height: _steerSettings.displayHeight,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                              ),
                              child: _commandLog.isEmpty
                                  ? const Center(child: Text('操作指令将在此显示', style: TextStyle(color: Colors.white30, fontSize: 11)))
                                  : ListView.builder(
                                      reverse: true,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      itemCount: _commandLog.length,
                                      itemBuilder: (_, i) => Text(
                                        _commandLog[i],
                                        style: const TextStyle(color: Color(0xFF00E676), fontSize: 10, fontFamily: 'monospace', height: 1.3),
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final h = constraints.maxHeight;
                      final w = constraints.maxWidth;
                      final baseSize = math.min(h * 0.82, w * 0.32);
                      final leftSize = baseSize * _steerSettings.leftSizeScale;
                      final rightSize = baseSize * _steerSettings.rightSizeScale;
                      final totalW = leftSize + rightSize;
                      final gap = (w - totalW) / 1.5;
                      final leftOffset = gap * _steerSettings.leftOffsetRatio + (w - leftSize) * (_steerSettings.leftOffsetRatio * 0.3);
                      final rightOffset = gap * _steerSettings.rightOffsetRatio + (w - rightSize) * (_steerSettings.rightOffsetRatio * 0.3);
                      return Stack(
                        children: [
                          Positioned(
                            left: leftOffset.clamp(8, w - leftSize - 8),
                            top: (h - leftSize) / 2,
                            child: SizedBox(width: leftSize, height: leftSize, child: _buildDPad(leftSize)),
                          ),
                          Positioned(
                            right: rightOffset.clamp(8, w - rightSize - 8),
                            top: (h - rightSize) / 2,
                            child: SizedBox(width: rightSize, height: rightSize, child: _buildJoystick(rightSize)),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            right: 12,
            child: GestureDetector(
              onTap: _showMenu,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                ),
                child: const Icon(Icons.more_horiz, color: Colors.white70, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDPad(double size) {
    final b = size * 0.27;
    final upS = b * _steerSettings.upBtnScale;
    final dnS = b * _steerSettings.downBtnScale;
    final lfS = b * _steerSettings.leftBtnScale;
    final rgS = b * _steerSettings.rightBtnScale;
    final ctS = b * _steerSettings.centerBtnScale;
    final halfUp = upS / 2;
    final halfDn = dnS / 2;
    final halfLf = lfS / 2;
    final halfRg = rgS / 2;
    final halfCt = ctS / 2;
    final gap = 14 * _steerSettings.btnSpacing;
    final gridW = halfLf + halfRg + ctS + gap;
    final gridH = halfUp + halfDn + ctS + gap;
    final ctLeft = (gridW - ctS) / 2;
    final ctTop = (gridH - ctS) / 2;
    return Center(
      child: SizedBox(
        width: gridW,
        height: gridH,
        child: Stack(
          children: [
            Positioned(left: ctLeft, top: 0, child: _dirButton(Icons.keyboard_arrow_up, upS, () => _sendCommand('前进', [0x01]))),
            Positioned(left: ctLeft, bottom: 0, child: _dirButton(Icons.keyboard_arrow_down, dnS, () => _sendCommand('后退', [0x02]))),
            Positioned(left: 0, top: ctTop, child: _dirButton(Icons.keyboard_arrow_left, lfS, () => _sendCommand('左转', [0x03]))),
            Positioned(right: 0, top: ctTop, child: _dirButton(Icons.keyboard_arrow_right, rgS, () => _sendCommand('右转', [0x04]))),
            Positioned(left: ctLeft, top: ctTop, child: _centerBtn(ctS, () => _sendCommand('停止', [0x00]))),
          ],
        ),
      ),
    );
  }

  Widget _dirButton(IconData icon, double size, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF0F3460),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF533483), width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      ),
    );
  }

  Widget _centerBtn(double size, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFE94560),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Icon(Icons.stop, color: Colors.white, size: size * 0.48),
      ),
    );
  }

  Widget _buildJoystick(double size) {
    final knobRadius = size * 0.15;
    final maxDist = size * 0.35;
    return Center(
      child: GestureDetector(
        onPanStart: (details) {
          final center = Offset(size / 2, size / 2);
          final dx = details.localPosition.dx - center.dx;
          final dy = details.localPosition.dy - center.dy;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > maxDist) return;
          setState(() => _joystickOffset = Offset(dx, dy));
          _sendJoystickCommand(dx, dy, size);
        },
        onPanUpdate: (details) {
          final center = Offset(size / 2, size / 2);
          final dx = details.localPosition.dx - center.dx;
          final dy = details.localPosition.dy - center.dy;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist > maxDist) return;
          setState(() => _joystickOffset = Offset(dx, dy));
          _sendJoystickCommand(dx, dy, size);
        },
        onPanEnd: (_) {
          setState(() => _joystickOffset = Offset.zero);
          _sendCommand('摇杆归中', [0x10, 0, 0]);
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(colors: [Color(0xFF16213E), Color(0xFF0F3460)]),
            border: Border.all(color: const Color(0xFF533483), width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: CustomPaint(
            painter: _JoystickGridPainter(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 60),
              transform: Matrix4.translationValues(_joystickOffset.dx, _joystickOffset.dy, 0),
              child: Center(
                child: Container(
                  width: knobRadius * 2,
                  height: knobRadius * 2,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE94560),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _sendJoystickCommand(double dx, double dy, double size) {
    final maxDist = size * 0.35;
    final dist = math.sqrt(dx * dx + dy * dy);
    final angle = (math.atan2(dy, dx) * 180 / math.pi + 90).round().clamp(0, 359);
    final speed = (dist / maxDist * 255).round().clamp(0, 255);
    _sendCommand('摇杆 ${angle}°', [0x10, angle, speed]);
  }
}

class _JoystickGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), paint);
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
    for (double r = size.width * 0.15; r <= size.width * 0.4; r += size.width * 0.1) {
      canvas.drawCircle(center, r, paint);
    }
    final lp = Paint()..color = Colors.white.withValues(alpha: 0.15);
    for (final a in [-90.0, 90.0, 180.0, 0.0]) {
      final rad = a * math.pi / 180;
      canvas.drawCircle(Offset(center.dx + size.width * 0.4 * math.cos(rad), center.dy + size.height * 0.4 * math.sin(rad)), 2, lp);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
