import 'package:flutter/material.dart';
import '../../services/steering_settings.dart';

class SteeringAdjustPanel extends StatefulWidget {
  final SteeringSettings settings;
  final VoidCallback? onChanged;

  const SteeringAdjustPanel({super.key, required this.settings, this.onChanged});

  static Future<void> show(BuildContext context, {required SteeringSettings settings, VoidCallback? onChanged}) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, anim1, anim2) {
        return SteeringAdjustPanel(settings: settings, onChanged: onChanged);
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(anim),
          child: child,
        );
      },
    );
  }

  @override
  State<SteeringAdjustPanel> createState() => _SteeringAdjustPanelState();
}

class _SteeringAdjustPanelState extends State<SteeringAdjustPanel> {
  late double _leftOffset;
  late double _rightOffset;
  late double _leftSize;
  late double _rightSize;
  late double _panelOpacity;
  late double _upBtn;
  late double _downBtn;
  late double _leftBtn;
  late double _rightBtn;
  late double _centerBtn;
  late double _btnSpacing;
  late double _displayHeight;
  late double _displayWidthPct;
  late double _displayOffsetPct;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _leftOffset = s.leftOffsetRatio;
    _rightOffset = s.rightOffsetRatio;
    _leftSize = s.leftSizeScale;
    _rightSize = s.rightSizeScale;
    _panelOpacity = s.panelOpacity;
    _upBtn = s.upBtnScale;
    _downBtn = s.downBtnScale;
    _leftBtn = s.leftBtnScale;
    _rightBtn = s.rightBtnScale;
    _centerBtn = s.centerBtnScale;
    _btnSpacing = s.btnSpacing;
    _displayHeight = s.displayHeight;
    _displayWidthPct = s.displayWidthPct;
    _displayOffsetPct = s.displayOffsetPct;
  }

  void _push() {
    final s = widget.settings;
    s.leftOffsetRatio = _leftOffset;
    s.rightOffsetRatio = _rightOffset;
    s.leftSizeScale = _leftSize;
    s.rightSizeScale = _rightSize;
    s.panelOpacity = _panelOpacity;
    s.upBtnScale = _upBtn;
    s.downBtnScale = _downBtn;
    s.leftBtnScale = _leftBtn;
    s.rightBtnScale = _rightBtn;
    s.centerBtnScale = _centerBtn;
    s.btnSpacing = _btnSpacing;
    s.displayHeight = _displayHeight;
    s.displayWidthPct = _displayWidthPct;
    s.displayOffsetPct = _displayOffsetPct;
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final panelW = screenW * 0.48;
    return Material(
      color: Colors.transparent,
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          width: panelW.clamp(260, 400),
          height: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E).withValues(alpha: _panelOpacity),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), bottomLeft: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.tune, color: Colors.white70, size: 20),
                      const SizedBox(width: 8),
                      const Text('控制器调整', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white54, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Color(0xFF2A2A4E), height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildButtonSection(
                        title: '左侧方向键', icon: Icons.gamepad,
                        offset: _leftOffset, size: _leftSize,
                        onOffsetChanged: (v) { _leftOffset = v; _push(); setState(() {}); },
                        onSizeChanged: (v) { _leftSize = v; _push(); setState(() {}); },
                        extra: _buildBtnGrid(),
                      ),
                      const SizedBox(height: 14),
                      _buildButtonSection(
                        title: '右侧摇杆', icon: Icons.radio_button_checked,
                        offset: _rightOffset, size: _rightSize,
                        onOffsetChanged: (v) { _rightOffset = v; _push(); setState(() {}); },
                        onSizeChanged: (v) { _rightSize = v; _push(); setState(() {}); },
                      ),
                      const SizedBox(height: 14),
                      _buildPanelOpacityCard(),
                      const SizedBox(height: 14),
                      _buildDisplayCard(),
                      const SizedBox(height: 16),
                      _buildStatusDisplay(),
                      const SizedBox(height: 16),
                      _buildSaveButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBtnGrid() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          const Text('单个按钮大小', style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 4),
          _btnSlider('上', _upBtn, (v) { _upBtn = v; _push(); setState(() {}); }),
          _btnSlider('下', _downBtn, (v) { _downBtn = v; _push(); setState(() {}); }),
          _btnSlider('左', _leftBtn, (v) { _leftBtn = v; _push(); setState(() {}); }),
          _btnSlider('右', _rightBtn, (v) { _rightBtn = v; _push(); setState(() {}); }),
          _btnSlider('停', _centerBtn, (v) { _centerBtn = v; _push(); setState(() {}); }),
          const SizedBox(height: 4),
          _spacingSlider(),
        ],
      ),
    );
  }

  Widget _btnSlider(String label, double val, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 20, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11))),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                activeTrackColor: const Color(0xFFE94560),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                thumbColor: Colors.white,
              ),
              child: Slider(value: val, min: 0.5, max: 1.5, onChanged: onChanged),
            ),
          ),
          SizedBox(width: 34, child: Text('${(val * 100).round()}%', style: const TextStyle(color: Colors.white54, fontSize: 10))),
        ],
      ),
    );
  }

  Widget _spacingSlider() {
    return Row(
      children: [
        const Icon(Icons.space_bar, color: Colors.white54, size: 14),
        const SizedBox(width: 4),
        const Text('间隔', style: TextStyle(color: Colors.white54, fontSize: 11)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              activeTrackColor: const Color(0xFF00BCD4),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
              thumbColor: Colors.white,
            ),
            child: Slider(value: _btnSpacing, min: 0.05, max: 6.0, onChanged: (v) { _btnSpacing = v; _push(); setState(() {}); }),
          ),
        ),
        SizedBox(width: 34, child: Text('${(_btnSpacing * 100).round()}%', style: const TextStyle(color: Colors.white54, fontSize: 10))),
      ],
    );
  }

  Widget _buildButtonSection({
    required String title, required IconData icon,
    required double offset, required double size,
    required ValueChanged<double> onOffsetChanged, required ValueChanged<double> onSizeChanged,
    Widget? extra,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white54, size: 16),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 10),
          _sliderRow('位置', offset, 0.0, 1.0, const Color(0xFF1A73E8), onOffsetChanged),
          const SizedBox(height: 4),
          _sliderRow('大小', size, 0.5, 1.5, const Color(0xFFE94560), onSizeChanged),
          if (extra != null) extra,
        ],
      ),
    );
  }

  Widget _buildPanelOpacityCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.opacity, color: Colors.white54, size: 16),
              const SizedBox(width: 6),
              const Text('面板透明度', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 6),
          _sliderRow('透明', _panelOpacity, 0.15, 1.0, const Color(0xFF9C27B0), (v) { _panelOpacity = v; _push(); setState(() {}); }),
        ],
      ),
    );
  }

  Widget _buildDisplayCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, color: Colors.white54, size: 16),
              const SizedBox(width: 6),
              const Text('指令显示区', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 6),
          _sliderRow('高度', _displayHeight, 16, 200, const Color(0xFF00BCD4), (v) { _displayHeight = v; _push(); setState(() {}); }),
          const SizedBox(height: 4),
          _pctSliderRow('宽度', _displayWidthPct, 20, 100, const Color(0xFF7C4DFF), (v) { _displayWidthPct = v; _push(); setState(() {}); }),
          const SizedBox(height: 4),
          _pctSliderRow('横向', _displayOffsetPct, 0, 20000, const Color(0xFFFF9800), (v) { _displayOffsetPct = v; _push(); setState(() {}); }),
        ],
      ),
    );
  }

  Widget _buildStatusDisplay() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '左: ${(_leftOffset * 100).round()}% 大小: ${(_leftSize * 100).round()}%\n'
        '右: ${(_rightOffset * 100).round()}% 大小: ${(_rightSize * 100).round()}%\n'
        '透明: ${(_panelOpacity * 100).round()}%  显示区: ${_displayHeight.round()}px\n'
        '宽: ${_displayWidthPct.round()}%  横向: ${_displayOffsetPct.round()}%',
        style: const TextStyle(color: Color(0xFF00E676), fontSize: 11, fontFamily: 'monospace', height: 1.5),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () async {
          _push();
          await widget.settings.save();
          widget.onChanged?.call();
          if (context.mounted) Navigator.pop(context);
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A73E8),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: const Text('确认保存', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max, Color color, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 28, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11))),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              activeTrackColor: color,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
              thumbColor: Colors.white,
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
        SizedBox(width: 38, child: Text('${(value * 100).round()}%', style: const TextStyle(color: Colors.white54, fontSize: 10))),
      ],
    );
  }

  Widget _pctSliderRow(String label, double value, double min, double max, Color color, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 28, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11))),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              activeTrackColor: color,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
              thumbColor: Colors.white,
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
        SizedBox(width: 58, child: Text('${value.round()}%', style: const TextStyle(color: Colors.white54, fontSize: 10))),
      ],
    );
  }
}
