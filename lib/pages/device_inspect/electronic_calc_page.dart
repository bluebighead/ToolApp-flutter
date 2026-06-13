// 电子元件计算工具
// 功能：色环电阻阻值计算、贴片电阻读数、电容单位换算、电感色码计算
// v1.50.0+ 新增
import 'package:flutter/material.dart';

/// 色环颜色定义
class ResistorColor {
  final String name;  // 颜色名称（中文）
  final Color color;  // 显示颜色
  final int digit;    // 数字值（-1 表示无/特殊）
  final int multiplier; // 乘数（10的幂次）
  final double tolerance; // 容差百分比（-1 表示无）
  final int tempCoeff; // 温度系数（-1 表示无）

  const ResistorColor({
    required this.name,
    required this.color,
    required this.digit,
    required this.multiplier,
    this.tolerance = -1,
    this.tempCoeff = -1,
  });

  // 两/三位有效数字的环
  static const List<ResistorColor> digitRings = [
    ResistorColor(name: '黑色', color: Colors.black, digit: 0, multiplier: 0),
    ResistorColor(name: '棕色', color: Colors.brown, digit: 1, multiplier: 1, tolerance: 1),
    ResistorColor(name: '红色', color: Colors.red, digit: 2, multiplier: 2, tolerance: 2),
    ResistorColor(name: '橙色', color: Colors.orange, digit: 3, multiplier: 3),
    ResistorColor(name: '黄色', color: Colors.yellow, digit: 4, multiplier: 4),
    ResistorColor(name: '绿色', color: Colors.green, digit: 5, multiplier: 5, tolerance: 0.5),
    ResistorColor(name: '蓝色', color: Colors.blue, digit: 6, multiplier: 6, tolerance: 0.25),
    ResistorColor(name: '紫色', color: Colors.purple, digit: 7, multiplier: 7, tolerance: 0.1),
    ResistorColor(name: '灰色', color: Colors.grey, digit: 8, multiplier: 8, tolerance: 0.05),
    ResistorColor(name: '白色', color: Color(0xFFF5F5F5), digit: 9, multiplier: 9),
  ];

  // 乘数环（第三环/第四环）
  static const List<ResistorColor> multiplierRings = [
    ResistorColor(name: '黑色', color: Colors.black, digit: 0, multiplier: 0),
    ResistorColor(name: '棕色', color: Colors.brown, digit: 1, multiplier: 1),
    ResistorColor(name: '红色', color: Colors.red, digit: 2, multiplier: 2),
    ResistorColor(name: '橙色', color: Colors.orange, digit: 3, multiplier: 3),
    ResistorColor(name: '黄色', color: Colors.yellow, digit: 4, multiplier: 4),
    ResistorColor(name: '绿色', color: Colors.green, digit: 5, multiplier: 5),
    ResistorColor(name: '蓝色', color: Colors.blue, digit: 6, multiplier: 6),
    ResistorColor(name: '紫色', color: Colors.purple, digit: 7, multiplier: 7),
    ResistorColor(name: '灰色', color: Colors.grey, digit: 8, multiplier: 8),
    ResistorColor(name: '白色', color: Color(0xFFF5F5F5), digit: 9, multiplier: 9),
    ResistorColor(name: '金色', color: Color(0xFFFFD700), digit: -1, multiplier: -1, tolerance: 5),
    ResistorColor(name: '银色', color: Color(0xFFC0C0C0), digit: -1, multiplier: -2, tolerance: 10),
  ];

  // 容差环
  static const List<ResistorColor> toleranceRings = [
    ResistorColor(name: '棕色', color: Colors.brown, digit: -1, multiplier: -1, tolerance: 1),
    ResistorColor(name: '红色', color: Colors.red, digit: -1, multiplier: -1, tolerance: 2),
    ResistorColor(name: '绿色', color: Colors.green, digit: -1, multiplier: -1, tolerance: 0.5),
    ResistorColor(name: '蓝色', color: Colors.blue, digit: -1, multiplier: -1, tolerance: 0.25),
    ResistorColor(name: '紫色', color: Colors.purple, digit: -1, multiplier: -1, tolerance: 0.1),
    ResistorColor(name: '灰色', color: Colors.grey, digit: -1, multiplier: -1, tolerance: 0.05),
    ResistorColor(name: '金色', color: Color(0xFFFFD700), digit: -1, multiplier: -1, tolerance: 5),
    ResistorColor(name: '银色', color: Color(0xFFC0C0C0), digit: -1, multiplier: -1, tolerance: 10),
  ];

  // 温度系数环（六环电阻）
  static const List<ResistorColor> tempCoeffRings = [
    ResistorColor(name: '棕色', color: Colors.brown, digit: -1, multiplier: -1, tempCoeff: 100),
    ResistorColor(name: '红色', color: Colors.red, digit: -1, multiplier: -1, tempCoeff: 50),
    ResistorColor(name: '橙色', color: Colors.orange, digit: -1, multiplier: -1, tempCoeff: 15),
    ResistorColor(name: '黄色', color: Colors.yellow, digit: -1, multiplier: -1, tempCoeff: 25),
    ResistorColor(name: '蓝色', color: Colors.blue, digit: -1, multiplier: -1, tempCoeff: 10),
    ResistorColor(name: '紫色', color: Colors.purple, digit: -1, multiplier: -1, tempCoeff: 5),
  ];
}

/// 电感色码颜色定义
class InductorColor {
  final String name;
  final Color color;
  final int digit;
  final int multiplier;

  const InductorColor({
    required this.name,
    required this.color,
    required this.digit,
    required this.multiplier,
  });

  static const List<InductorColor> values = [
    InductorColor(name: '黑色', color: Colors.black, digit: 0, multiplier: 1),
    InductorColor(name: '棕色', color: Colors.brown, digit: 1, multiplier: 10),
    InductorColor(name: '红色', color: Colors.red, digit: 2, multiplier: 100),
    InductorColor(name: '橙色', color: Colors.orange, digit: 3, multiplier: 1000),
    InductorColor(name: '黄色', color: Colors.yellow, digit: 4, multiplier: 10000),
    InductorColor(name: '绿色', color: Colors.green, digit: 5, multiplier: 100000),
    InductorColor(name: '蓝色', color: Colors.blue, digit: 6, multiplier: 1000000),
    InductorColor(name: '紫色', color: Colors.purple, digit: 7, multiplier: 10000000),
    InductorColor(name: '灰色', color: Colors.grey, digit: 8, multiplier: 100000000),
    InductorColor(name: '白色', color: Color(0xFFF5F5F5), digit: 9, multiplier: 1000000000),
  ];

  static const List<InductorColor> tolerances = [
    InductorColor(name: '金色', color: Color(0xFFFFD700), digit: -1, multiplier: -1),
    InductorColor(name: '银色', color: Color(0xFFC0C0C0), digit: -1, multiplier: -1),
  ];
}

class ElectronicCalcPage extends StatefulWidget {
  const ElectronicCalcPage({super.key});

  @override
  State<ElectronicCalcPage> createState() => _ElectronicCalcPageState();
}

class _ElectronicCalcPageState extends State<ElectronicCalcPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 色环电阻状态
  int _ringCount = 4; // 4色环 / 5色环 / 6色环
  List<ResistorColor?> _selectedRings = List.filled(6, null);
  String _resistorResult = '';
  bool _showRingTable = false;

  // 贴片电阻状态
  final TextEditingController _smdController = TextEditingController();
  String _smdResult = '';

  // 电容换算状态
  final TextEditingController _capValueController = TextEditingController();
  String _capFromUnit = 'pF';
  double? _capValue;
  bool _capCalculated = false;

  // 电感色码状态
  List<InductorColor?> _selectedInductorRings = List.filled(4, null);
  String _inductorResult = '';

  static const List<String> _capUnits = ['pF', 'nF', 'µF', 'mF', 'F'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initCapUnitMultipliers();
  }

  /// 电容单位换算表（以pF为基准）
  final Map<String, double> _capMultipliers = {};

  void _initCapUnitMultipliers() {
    _capMultipliers['pF'] = 1;
    _capMultipliers['nF'] = 1000;
    _capMultipliers['µF'] = 1000000;
    _capMultipliers['mF'] = 1000000000;
    _capMultipliers['F'] = 1000000000000;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _smdController.dispose();
    _capValueController.dispose();
    super.dispose();
  }

  // ============================================================
  // 色环电阻计算
  // ============================================================

  /// 计算色环电阻阻值
  void _calculateResistor() {
    if (_ringCount == 4) {
      final r1 = _selectedRings[0];
      final r2 = _selectedRings[1];
      final m = _selectedRings[2];
      final t = _selectedRings[3];
      if (r1 == null || r2 == null || m == null) {
        setState(() => _resistorResult = '请选择完整的色环颜色');
        return;
      }
      final value = (r1.digit * 10 + r2.digit) * (m.multiplier >= 0
          ? _pow10(m.multiplier)
          : (m.multiplier == -1 ? 0.1 : 0.01));
      final tolerance = t?.tolerance;
      setState(() {
        _resistorResult = '${_formatResistance(value)}'
            '${tolerance != null && tolerance > 0 ? ' ±$tolerance%' : ''}';
      });
    } else if (_ringCount == 5) {
      final r1 = _selectedRings[0];
      final r2 = _selectedRings[1];
      final r3 = _selectedRings[2];
      final m = _selectedRings[3];
      final t = _selectedRings[4];
      if (r1 == null || r2 == null || r3 == null || m == null) {
        setState(() => _resistorResult = '请选择完整的色环颜色');
        return;
      }
      final value = (r1.digit * 100 + r2.digit * 10 + r3.digit) *
          (m.multiplier >= 0 ? _pow10(m.multiplier) : (m.multiplier == -1 ? 0.1 : 0.01));
      final tolerance = t?.tolerance;
      setState(() {
        _resistorResult = '${_formatResistance(value)}'
            '${tolerance != null && tolerance > 0 ? ' ±$tolerance%' : ''}';
      });
    } else if (_ringCount == 6) {
      final r1 = _selectedRings[0];
      final r2 = _selectedRings[1];
      final r3 = _selectedRings[2];
      final m = _selectedRings[3];
      final t = _selectedRings[4];
      final tc = _selectedRings[5];
      if (r1 == null || r2 == null || r3 == null || m == null) {
        setState(() => _resistorResult = '请选择完整的色环颜色');
        return;
      }
      final value = (r1.digit * 100 + r2.digit * 10 + r3.digit) *
          (m.multiplier >= 0 ? _pow10(m.multiplier) : (m.multiplier == -1 ? 0.1 : 0.01));
      final tolerance = t?.tolerance;
      final tempCoeff = tc?.tempCoeff;
      setState(() {
        _resistorResult = '${_formatResistance(value)}'
            '${tolerance != null && tolerance > 0 ? ' ±$tolerance%' : ''}'
            '${tempCoeff != null && tempCoeff > 0 ? ' ${tempCoeff}ppm/°C' : ''}';
      });
    }
  }

  double _pow10(int n) {
    double result = 1;
    for (int i = 0; i < n; i++) result *= 10;
    return result;
  }

  /// 格式化电阻值
  String _formatResistance(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)} MΩ';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(2)} KΩ';
    } else {
      return '${value.toStringAsFixed(2)} Ω';
    }
  }

  /// 重置色环选择
  void _resetResistor() {
    setState(() {
      _selectedRings = List.filled(6, null);
      _resistorResult = '';
    });
  }

  /// 获取第N环可选的颜色列表
  List<ResistorColor> _getAvailableColors(int ringIndex) {
    if (_ringCount == 4) {
      if (ringIndex < 2) return ResistorColor.digitRings;
      if (ringIndex == 2) return ResistorColor.multiplierRings;
      return ResistorColor.toleranceRings;
    } else if (_ringCount == 5) {
      if (ringIndex < 3) return ResistorColor.digitRings;
      if (ringIndex == 3) return ResistorColor.multiplierRings;
      return ResistorColor.toleranceRings;
    } else {
      // 6 环
      if (ringIndex < 3) return ResistorColor.digitRings;
      if (ringIndex == 3) return ResistorColor.multiplierRings;
      if (ringIndex == 4) return ResistorColor.toleranceRings;
      return ResistorColor.tempCoeffRings;
    }
  }

  /// 获取第N环的标签
  String _getRingLabel(int ringIndex) {
    if (_ringCount == 4) {
      return ['第1环\n(十位)', '第2环\n(个位)', '第3环\n(乘数)', '第4环\n(容差)'][ringIndex];
    } else if (_ringCount == 5) {
      return ['第1环\n(百位)', '第2环\n(十位)', '第3环\n(个位)', '第4环\n(乘数)', '第5环\n(容差)'][ringIndex];
    } else {
      return ['第1环\n(百位)', '第2环\n(十位)', '第3环\n(个位)', '第4环\n(乘数)', '第5环\n(容差)', '第6环\n(温度系数)'][ringIndex];
    }
  }

  // ============================================================
  // 贴片电阻计算
  // ============================================================

  /// 计算贴片电阻值（3位/4位/EIA-96编码）
  void _calculateSMD() {
    final code = _smdController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _smdResult = '请输入贴片电阻编码');
      return;
    }

    // EIA-96 编码表
    const eia96Values = {
      '01': 100, '02': 102, '03': 105, '04': 107, '05': 110,
      '06': 113, '07': 115, '08': 118, '09': 121, '10': 124,
      '11': 127, '12': 130, '13': 133, '14': 137, '15': 140,
      '16': 143, '17': 147, '18': 150, '19': 154, '20': 158,
      '21': 162, '22': 165, '23': 169, '24': 174, '25': 178,
      '26': 182, '27': 187, '28': 191, '29': 196, '30': 200,
      '31': 205, '32': 210, '33': 215, '34': 221, '35': 226,
      '36': 232, '37': 237, '38': 243, '39': 249, '40': 255,
      '41': 261, '42': 267, '43': 274, '44': 280, '45': 287,
      '46': 294, '47': 301, '48': 309, '49': 316, '50': 324,
      '51': 332, '52': 340, '53': 348, '54': 357, '55': 365,
      '56': 374, '57': 383, '58': 392, '59': 402, '60': 412,
      '61': 422, '62': 432, '63': 442, '64': 453, '65': 464,
      '66': 475, '67': 487, '68': 499, '69': 511, '70': 523,
      '71': 536, '72': 549, '73': 562, '74': 576, '75': 590,
      '76': 604, '77': 619, '78': 634, '79': 649, '80': 665,
      '81': 681, '82': 698, '83': 715, '84': 732, '85': 750,
      '86': 768, '87': 787, '88': 806, '89': 825, '90': 845,
      '91': 866, '92': 887, '93': 909, '94': 931, '95': 953,
      '96': 976,
    };
    const eia96Multipliers = {
      'Z': 0.001, 'Y': 0.01, 'R': 0.01, 'X': 0.1, 'S': 0.1,
      'A': 1, 'B': 10, 'C': 100, 'D': 1000, 'E': 10000, 'F': 100000,
    };

    // 3位编码：前两位是有效数字，第三位是乘数（10的幂次）
    if (code.length == 3 && RegExp(r'^\d{3}$').hasMatch(code)) {
      final value = int.parse(code.substring(0, 2)) * _pow10(int.parse(code[2]));
      setState(() => _smdResult = _formatResistance(value.toDouble()));
      return;
    }

    // 4位编码：前三位是有效数字，第四位是乘数
    if (code.length == 4 && RegExp(r'^\d{4}$').hasMatch(code)) {
      final value = int.parse(code.substring(0, 3)) * _pow10(int.parse(code[3]));
      setState(() => _smdResult = _formatResistance(value.toDouble()));
      return;
    }

    // 带R的编码：R表示小数点，如 4R7 = 4.7Ω, R10 = 0.1Ω
    if (code.contains('R') && code.length <= 4) {
      final parts = code.split('R');
      if (parts.length == 2) {
        final before = parts[0].isEmpty ? 0 : int.tryParse(parts[0]) ?? 0;
        final after = parts[1].isEmpty ? 0 : int.tryParse(parts[1]) ?? 0;
        final value = before + after / _pow10(parts[1].length);
        setState(() => _smdResult = '${value.toStringAsFixed(3)} Ω');
        return;
      }
    }

    // EIA-96编码：两位数字 + 一位字母
    if (code.length == 3 && RegExp(r'^\d{2}[A-Z]$').hasMatch(code)) {
      final digits = code.substring(0, 2);
      final letter = code[2];
      if (eia96Values.containsKey(digits) && eia96Multipliers.containsKey(letter)) {
        final value = eia96Values[digits]! * eia96Multipliers[letter]!;
        setState(() => _smdResult = _formatResistance(value.toDouble()));
        return;
      }
    }

    setState(() => _smdResult = '无法识别的编码格式');
  }

  // ============================================================
  // 电容单位换算
  // ============================================================

  /// 计算电容单位换算
  void _calculateCapacitor() {
    final text = _capValueController.text.trim();
    if (text.isEmpty) {
      setState(() => _capCalculated = false);
      return;
    }
    final value = double.tryParse(text);
    if (value == null) {
      setState(() => _capCalculated = false);
      return;
    }
    setState(() {
      _capValue = value;
      _capCalculated = true;
    });
  }

  /// 获取换算结果
  String _getConvertedCapValue(String toUnit) {
    if (_capValue == null) return '-';
    final fromMultiplier = _capMultipliers[_capFromUnit] ?? 1;
    final toMultiplier = _capMultipliers[toUnit] ?? 1;
    final converted = _capValue! * fromMultiplier / toMultiplier;
    return converted.toStringAsFixed(4);
  }

  // ============================================================
  // 电感色码计算
  // ============================================================

  /// 计算电感色码值
  void _calculateInductor() {
    final r1 = _selectedInductorRings[0];
    final r2 = _selectedInductorRings[1];
    final m = _selectedInductorRings[2];
    if (r1 == null || r2 == null || m == null) {
      setState(() => _inductorResult = '请选择完整的色码颜色');
      return;
    }
    final value = (r1.digit * 10 + r2.digit) * m.multiplier.toDouble();
    setState(() {
      if (value >= 1000000) {
        _inductorResult = '${(value / 1000000).toStringAsFixed(2)} H';
      } else if (value >= 1000) {
        _inductorResult = '${(value / 1000).toStringAsFixed(2)} mH';
      } else {
        _inductorResult = '$value µH';
      }
    });
  }

  /// 重置电感色码
  void _resetInductor() {
    setState(() {
      _selectedInductorRings = List.filled(4, null);
      _inductorResult = '';
    });
  }

  // ============================================================
  // UI 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('电子元件计算'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: false,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: '色环电阻'),
            Tab(text: '贴片电阻'),
            Tab(text: '电容换算'),
            Tab(text: '电感色码'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildResistorTab(theme),
          _buildSMDTab(theme),
          _buildCapacitorTab(theme),
          _buildInductorTab(theme),
        ],
      ),
    );
  }

  // ============================================================
  // 色环电阻 Tab
  // ============================================================

  Widget _buildResistorTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 色环数量选择
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('色环数量', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 4, label: Text('4 环')),
                      ButtonSegment(value: 5, label: Text('5 环')),
                      ButtonSegment(value: 6, label: Text('6 环')),
                    ],
                    selected: {_ringCount},
                    onSelectionChanged: (v) {
                      setState(() {
                        _ringCount = v.first;
                        _selectedRings = List.filled(6, null);
                        _resistorResult = '';
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 色环选择区域
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('选择色环颜色', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  // 色环选择行
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(_ringCount, (i) {
                      final selected = _selectedRings[i];
                      return GestureDetector(
                        onTap: () => _showColorPicker(i),
                        child: Column(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: selected?.color ?? Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: selected != null ? theme.colorScheme.primary : Colors.grey.shade400,
                                  width: 2,
                                ),
                              ),
                              child: selected == null
                                  ? Icon(Icons.add, size: 18, color: Colors.grey.shade500)
                                  : (selected.color == Colors.black || selected.color == Colors.brown || selected.color == Colors.blue || selected.color == Colors.purple || selected.color == Colors.grey
                                      ? Icon(Icons.circle, size: 22, color: selected.color == Colors.black ? Colors.white : null)
                                      : null),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _getRingLabel(i),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 9, height: 1.2),
                            ),
                            Text(
                              selected?.name ?? '未选',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),
                  // 结果显示
                  if (_resistorResult.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          const Text('计算结果', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(
                            _resistorResult,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 按钮行
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _calculateResistor,
                  icon: const Icon(Icons.calculate, size: 18),
                  label: const Text('计算阻值'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetResistor,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重置'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 色环对照表（可折叠）
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              initiallyExpanded: _showRingTable,
              onExpansionChanged: (v) => setState(() => _showRingTable = v),
              title: const Text('色环电阻对照表', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              leading: const Icon(Icons.table_chart),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: DataTable(
                    columnSpacing: 16,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 40,
                    headingRowHeight: 40,
                    columns: const [
                      DataColumn(label: Text('颜色', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('数字', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('乘数', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('容差', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('温度系数', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    ],
                    rows: [
                      _buildTableRow('黑色', Colors.black, '0', '×1', '-', '-'),
                      _buildTableRow('棕色', Colors.brown, '1', '×10', '±1%', '100ppm'),
                      _buildTableRow('红色', Colors.red, '2', '×100', '±2%', '50ppm'),
                      _buildTableRow('橙色', Colors.orange, '3', '×1K', '-', '15ppm'),
                      _buildTableRow('黄色', Colors.yellow, '4', '×10K', '-', '25ppm'),
                      _buildTableRow('绿色', Colors.green, '5', '×100K', '±0.5%', '-'),
                      _buildTableRow('蓝色', Colors.blue, '6', '×1M', '±0.25%', '10ppm'),
                      _buildTableRow('紫色', Colors.purple, '7', '×10M', '±0.1%', '5ppm'),
                      _buildTableRow('灰色', Colors.grey, '8', '×100M', '±0.05%', '-'),
                      _buildTableRow('白色', Color(0xFFF5F5F5), '9', '×1G', '-', '-'),
                      _buildTableRow('金色', Color(0xFFFFD700), '-', '×0.1', '±5%', '-'),
                      _buildTableRow('银色', Color(0xFFC0C0C0), '-', '×0.01', '±10%', '-'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  DataRow _buildTableRow(String name, Color color, String digit, String mult, String tol, String temp) {
    return DataRow(cells: [
      DataCell(Row(children: [
        Container(width: 16, height: 16, decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: color == Color(0xFFF5F5F5) ? Border.all(color: Colors.grey.shade300) : null,
        )),
        const SizedBox(width: 6),
        Text(name, style: const TextStyle(fontSize: 12)),
      ])),
      DataCell(Text(digit, style: const TextStyle(fontSize: 12))),
      DataCell(Text(mult, style: const TextStyle(fontSize: 11))),
      DataCell(Text(tol, style: const TextStyle(fontSize: 11))),
      DataCell(Text(temp, style: const TextStyle(fontSize: 11))),
    ]);
  }

  /// 显示颜色选择器弹窗
  void _showColorPicker(int ringIndex) {
    final colors = _getAvailableColors(ringIndex);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择 ${_getRingLabel(ringIndex).replaceAll('\n', '')} 颜色',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: colors.map((c) => GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedRings[ringIndex] = c;
                    _resistorResult = '';
                  });
                  Navigator.pop(ctx);
                },
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.color,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _selectedRings[ringIndex]?.name == c.name
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          width: _selectedRings[ringIndex]?.name == c.name ? 3 : 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(c.name, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 贴片电阻 Tab
  // ============================================================

  Widget _buildSMDTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('贴片电阻编码', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '支持 3位/4位数字编码、带R编码、EIA-96编码',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _smdController,
                    decoration: InputDecoration(
                      hintText: '例如: 103, 1002, 4R7, 01C',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    onChanged: (_) => _calculateSMD(),
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 12),
                  // 结果
                  if (_smdResult.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _smdResult.contains('无法') || _smdResult.contains('请输入')
                            ? Colors.orange.withValues(alpha: 0.1)
                            : Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _smdResult.contains('无法') || _smdResult.contains('请输入')
                              ? Colors.orange.withValues(alpha: 0.3)
                              : Colors.green.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _smdResult,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 编码规则说明
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              title: const Text('编码规则说明', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              leading: const Icon(Icons.info_outline),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildRuleItem('3位编码', '前两位有效数字 × 10^第三位。例：103 = 10 × 10³ = 10KΩ'),
                      _buildRuleItem('4位编码', '前三位有效数字 × 10^第四位。例：1002 = 100 × 10² = 10KΩ'),
                      _buildRuleItem('带R编码', 'R表示小数点。例：4R7 = 4.7Ω, R10 = 0.1Ω'),
                      _buildRuleItem('EIA-96编码', '两位数字查表值 × 字母乘数。例：01C = 100 × 100 = 10KΩ'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleItem(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(desc, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  // ============================================================
  // 电容换算 Tab
  // ============================================================

  Widget _buildCapacitorTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('电容单位换算', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  // 输入行
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _capValueController,
                          keyboardType: TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            hintText: '输入数值',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          onChanged: (_) => _calculateCapacitor(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          value: _capFromUnit,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: _capUnits.map((u) => DropdownMenuItem(
                            value: u,
                            child: Text(u, style: const TextStyle(fontSize: 14)),
                          )).toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => _capFromUnit = v);
                              _calculateCapacitor();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 换算结果
                  if (_capCalculated && _capValue != null) ...[
                    const Divider(),
                    const Text('换算结果', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    ..._capUnits.map((unit) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text(unit, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                          const Text(' = ', style: TextStyle(fontSize: 13)),
                          Expanded(
                            child: Text(
                              _getConvertedCapValue(unit),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: unit == _capFromUnit ? theme.colorScheme.primary : null,
                              ),
                            ),
                          ),
                          Text(unit, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                        ],
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 单位换算关系
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('单位换算关系', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _buildCapRelation('1 F', '= 1,000 mF', '= 1,000,000 µF'),
                  _buildCapRelation('1 mF', '= 1,000 µF', '= 1,000,000 nF'),
                  _buildCapRelation('1 µF', '= 1,000 nF', '= 1,000,000 pF'),
                  _buildCapRelation('1 nF', '= 1,000 pF', ''),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCapRelation(String base, String eq1, String eq2) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(base, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(eq1, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          if (eq2.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(eq2, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // 电感色码 Tab
  // ============================================================

  Widget _buildInductorTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('电感色码（4环）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '标准电感色码：第1环+第2环有效数字 × 第3环乘数，结果单位 µH',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  // 色环选择
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(3, (i) {
                      final selected = _selectedInductorRings[i];
                      return GestureDetector(
                        onTap: () => _showInductorColorPicker(i),
                        child: Column(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: selected?.color ?? Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: selected != null ? theme.colorScheme.primary : Colors.grey.shade400,
                                  width: 2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ['第1环', '第2环', '第3环\n(乘数)'][i],
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10, height: 1.3),
                            ),
                            Text(
                              selected?.name ?? '未选',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),
                  if (_inductorResult.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          const Text('计算结果', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(
                            _inductorResult,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _calculateInductor,
                  icon: const Icon(Icons.calculate, size: 18),
                  label: const Text('计算电感值'),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetInductor,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重置'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 电感色码对照表
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              title: const Text('电感色码对照表', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              leading: const Icon(Icons.table_chart),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: DataTable(
                    columnSpacing: 20,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 36,
                    columns: const [
                      DataColumn(label: Text('颜色', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('数字', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                      DataColumn(label: Text('乘数', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                    ],
                    rows: InductorColor.values.map((c) => DataRow(cells: [
                      DataCell(Row(children: [
                        Container(width: 14, height: 14, decoration: BoxDecoration(
                          color: c.color, borderRadius: BorderRadius.circular(7),
                          border: c.color == Color(0xFFF5F5F5) ? Border.all(color: Colors.grey.shade300) : null,
                        )),
                        const SizedBox(width: 6),
                        Text(c.name, style: const TextStyle(fontSize: 11)),
                      ])),
                      DataCell(Text('${c.digit}', style: const TextStyle(fontSize: 11))),
                      DataCell(Text('×${c.multiplier}', style: const TextStyle(fontSize: 11))),
                    ])).toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showInductorColorPicker(int ringIndex) {
    final colors = InductorColor.values;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择第${ringIndex + 1}环颜色',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: colors.map((c) => GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedInductorRings[ringIndex] = c;
                    _inductorResult = '';
                  });
                  Navigator.pop(ctx);
                },
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.color,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _selectedInductorRings[ringIndex]?.name == c.name
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          width: _selectedInductorRings[ringIndex]?.name == c.name ? 3 : 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(c.name, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}