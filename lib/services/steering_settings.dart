import 'package:shared_preferences/shared_preferences.dart';

class SteeringSettings {
  double leftOffsetRatio = 0.5;
  double rightOffsetRatio = 0.5;
  double leftSizeScale = 1.0;
  double rightSizeScale = 1.0;
  double panelOpacity = 0.9;
  double upBtnScale = 1.0;
  double downBtnScale = 1.0;
  double leftBtnScale = 1.0;
  double rightBtnScale = 1.0;
  double centerBtnScale = 1.0;
  double btnSpacing = 1.0;
  double displayHeight = 52;
  double displayWidthPct = 100;
  double displayOffsetPct = 10000;

  static const _kLo = 'steering_left_offset';
  static const _kRo = 'steering_right_offset';
  static const _kLs = 'steering_left_size';
  static const _kRs = 'steering_right_size';
  static const _kPo = 'steering_panel_opacity';
  static const _kUp = 'steering_btn_up';
  static const _kDn = 'steering_btn_down';
  static const _kLf = 'steering_btn_left';
  static const _kRg = 'steering_btn_right';
  static const _kCt = 'steering_btn_center';
  static const _kBs = 'steering_btn_spacing';
  static const _kDh = 'steering_disp_h';
  static const _kDw = 'steering_disp_w';
  static const _kDx = 'steering_disp_x';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    leftOffsetRatio = p.getDouble(_kLo) ?? 0.5;
    rightOffsetRatio = p.getDouble(_kRo) ?? 0.5;
    leftSizeScale = p.getDouble(_kLs) ?? 1.0;
    rightSizeScale = p.getDouble(_kRs) ?? 1.0;
    panelOpacity = p.getDouble(_kPo) ?? 0.9;
    upBtnScale = p.getDouble(_kUp) ?? 1.0;
    downBtnScale = p.getDouble(_kDn) ?? 1.0;
    leftBtnScale = p.getDouble(_kLf) ?? 1.0;
    rightBtnScale = p.getDouble(_kRg) ?? 1.0;
    centerBtnScale = p.getDouble(_kCt) ?? 1.0;
    btnSpacing = p.getDouble(_kBs) ?? 1.0;
    displayHeight = p.getDouble(_kDh) ?? 52;
    displayWidthPct = p.getDouble(_kDw) ?? 100;
    displayOffsetPct = p.getDouble(_kDx) ?? 10000;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kLo, leftOffsetRatio);
    await p.setDouble(_kRo, rightOffsetRatio);
    await p.setDouble(_kLs, leftSizeScale);
    await p.setDouble(_kRs, rightSizeScale);
    await p.setDouble(_kPo, panelOpacity);
    await p.setDouble(_kUp, upBtnScale);
    await p.setDouble(_kDn, downBtnScale);
    await p.setDouble(_kLf, leftBtnScale);
    await p.setDouble(_kRg, rightBtnScale);
    await p.setDouble(_kCt, centerBtnScale);
    await p.setDouble(_kBs, btnSpacing);
    await p.setDouble(_kDh, displayHeight);
    await p.setDouble(_kDw, displayWidthPct);
    await p.setDouble(_kDx, displayOffsetPct);
  }
}
