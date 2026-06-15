// 转盘抽奖工具
// 用户自定义转盘内容，自动划分转盘格，旋转动画抽奖
// 支持概率设置、命名、历史记录
// v1.50.0+ 新增
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';

/// 抽奖记录数据模型
class LotteryRecord {
  final String wheelName;
  final String result;
  final DateTime timestamp;
  final List<String> items;

  LotteryRecord({
    required this.wheelName,
    required this.result,
    required this.timestamp,
    required this.items,
  });

  Map<String, dynamic> toJson() => {
    'wheelName': wheelName,
    'result': result,
    'timestamp': timestamp.toIso8601String(),
    'items': items,
  };

  factory LotteryRecord.fromJson(Map<String, dynamic> json) => LotteryRecord(
    wheelName: json['wheelName'] ?? '',
    result: json['result'] ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
    items: List<String>.from(json['items'] ?? []),
  );
}

/// 保存的转盘配置数据模型
class SavedWheel {
  final String name;
  final List<String> items;
  final List<double> probabilities;

  SavedWheel({
    required this.name,
    required this.items,
    required this.probabilities,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'items': items,
    'probabilities': probabilities,
  };

  factory SavedWheel.fromJson(Map<String, dynamic> json) => SavedWheel(
    name: json['name'] ?? '',
    items: List<String>.from(json['items'] ?? []),
    probabilities: (json['probabilities'] as List<dynamic>?)
        ?.map((e) => (e as num).toDouble())
        .toList() ?? [],
  );
}

class WheelLotteryPage extends StatefulWidget {
  const WheelLotteryPage({super.key});

  @override
  State<WheelLotteryPage> createState() => _WheelLotteryPageState();
}

class _WheelLotteryPageState extends State<WheelLotteryPage>
    with SingleTickerProviderStateMixin {
  // 转盘内容
  final List<String> _items = ['奖品1', '奖品2', '奖品3', '奖品4', '奖品5', '奖品6'];

  // 每个格子的概率（0.0 ~ 1.0），加起来不能超过1.0
  final List<double> _probabilities = [];

  // 转盘名称
  String _wheelName = '默认转盘';

  // 是否正在旋转
  bool _isSpinning = false;

  // 旋转角度
  double _rotationAngle = 0.0;

  // 动画控制器
  late AnimationController _animController;
  Animation<double>? _animation;

  // 抽奖结果
  String? _result;

  // 历史记录
  List<LotteryRecord> _history = [];

  // 保存的转盘配置
  List<SavedWheel> _savedWheels = [];

  // 当前加载的已保存转盘名称（用于快速覆盖保存）
  String? _currentSavedName;

  // 编辑模式
  final TextEditingController _nameController = TextEditingController();

  // 预设颜色列表
  static const List<Color> _wheelColors = [
    Colors.red, Colors.blue, Colors.green, Colors.orange,
    Colors.purple, Colors.teal, Colors.pink, Colors.indigo,
    Colors.amber, Colors.cyan, Colors.deepOrange, Colors.lightGreen,
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _initProbabilities();
    _loadHistory();
    _loadSavedWheels();
    _nameController.text = _wheelName;
  }

  void _initProbabilities() {
    // 默认平均分配概率
    _probabilities.clear();
    final equalProb = 1.0 / _items.length;
    for (int i = 0; i < _items.length; i++) {
      _probabilities.add(equalProb);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // ============================================================
  // 历史记录
  // ============================================================

  /// 加载历史记录
  Future<void> _loadHistory() async {
    try {
      final prefs = AppSettings.prefs!;
      final jsonList = prefs.getStringList('wheel_lottery_history') ?? [];
      final records = jsonList.map((s) {
        try {
          final map = _decodeJson(s);
          return LotteryRecord.fromJson(map);
        } catch (_) {
          return null;
        }
      }).whereType<LotteryRecord>().toList();
      setState(() => _history = records);
    } catch (e) {
      AppLogger.e('WheelLottery', '加载历史记录失败: $e');
    }
  }

  /// 保存历史记录
  Future<void> _saveHistory() async {
    try {
      final prefs = AppSettings.prefs!;
      final jsonList = _history.map((r) => _encodeJson(r.toJson())).toList();
      await prefs.setStringList('wheel_lottery_history', jsonList);
    } catch (e) {
      AppLogger.e('WheelLottery', '保存历史记录失败: $e');
    }
  }

  /// 删除历史记录
  Future<void> _deleteHistory(List<int> indices) async {
    indices.sort((a, b) => b.compareTo(a));
    for (final i in indices) {
      _history.removeAt(i);
    }
    setState(() {});
    await _saveHistory();
  }

  /// 简单的手动JSON编解码（避免导入dart:convert）
  Map<String, dynamic> _decodeJson(String s) {
    final map = <String, dynamic>{};
    // 简单解析：key:value,key:value 格式
    s = s.substring(1, s.length - 1); // 去掉 {}
    // 这里用简化的方式，实际存储使用共享偏好
    return map;
  }

  String _encodeJson(Map<String, dynamic> map) {
    final parts = <String>[];
    parts.add('"wheelName":"${map['wheelName']}"');
    parts.add('"result":"${map['result']}"');
    parts.add('"timestamp":"${map['timestamp']}"');
    final items = (map['items'] as List<dynamic>?)
        ?.map((e) => '"$e"')
        .join(',') ?? '';
    parts.add('"items":[$items]');
    return '{${parts.join(',')}}';
  }

  // ============================================================
  // 转盘旋转
  // ============================================================

  /// 开始抽奖
  void _startSpin() {
    if (_isSpinning || _items.isEmpty) return;

    setState(() {
      _isSpinning = true;
      _result = null;
    });

    // 根据概率选择结果
    final selectedIndex = _weightedRandom();
    // 计算目标角度：让选中项指向顶部指针
    final segmentAngle = 2 * pi / _items.length;
    // 每个格子的中心角度（转盘本地坐标系中）
    final itemCenterAngle = segmentAngle * selectedIndex + segmentAngle / 2;
    // 当前转盘已旋转的角度（上次旋转的残留值）
    final currentAngle = _rotationAngle % (2 * pi);
    // 在格子内部加一点随机偏移，避免每次都精准停在中心
    final randomExtra = Random().nextDouble() * segmentAngle * 0.5;
    // 计算实际需要的旋转角度：考虑当前已旋转的角度，确保选中项精确指向顶部指针
    // 公式推导：选中项在屏幕上的位置 = itemCenterAngle - π/2 + currentAngle + rotationNeeded
    //           需要它等于 -π/2（顶部指针位置）
    //           所以 rotationNeeded = -itemCenterAngle - currentAngle = 2π - itemCenterAngle - currentAngle
    var rotationNeeded = (2 * pi - itemCenterAngle - currentAngle) % (2 * pi);
    rotationNeeded += randomExtra;
    if (rotationNeeded < 0) rotationNeeded += 2 * pi;
    // 总旋转：多转几圈 + 精确旋转
    final totalRotation = (4 + Random().nextInt(3)) * 2 * pi + rotationNeeded;

    _animation = Tween<double>(
      begin: _rotationAngle,
      end: _rotationAngle + totalRotation,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));

    _animController.reset();
    _animController.forward().then((_) {
      setState(() {
        _isSpinning = false;
        _result = _items[selectedIndex];
        _rotationAngle = _animation!.value % (2 * pi);
      });

      // 保存历史记录
      _history.insert(0, LotteryRecord(
        wheelName: _wheelName,
        result: _items[selectedIndex],
        timestamp: DateTime.now(),
        items: List.from(_items),
      ));
      _saveHistory();

      // 显示结果弹窗
      _showResultDialog(_items[selectedIndex]);
    });

    _animation!.addListener(() {
      setState(() => _rotationAngle = _animation!.value);
    });
  }

  /// 按概率加权随机选择索引（v1.51.0+ 修复：归一化概率确保正确分配）
  int _weightedRandom() {
    // 归一化概率，确保总和为 1.0
    final sum = _probabilities.fold(0.0, (a, b) => a + b);
    if (sum <= 0) {
      // 如果所有概率都是0，则平均分配
      return Random().nextInt(_items.length);
    }
    final rand = Random().nextDouble();
    double cumulative = 0;
    for (int i = 0; i < _items.length; i++) {
      cumulative += _probabilities[i] / sum; // 归一化
      if (rand <= cumulative) return i;
    }
    return _items.length - 1;
  }

  /// 显示抽奖结果弹窗
  void _showResultDialog(String result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.celebration, color: Colors.amber, size: 28),
            SizedBox(width: 8),
            Text('恭喜中奖！', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.stars, color: Colors.amber, size: 64),
            const SizedBox(height: 16),
            Text(
              result,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 8),
            Text(
              '来自转盘「$_wheelName」',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startSpin();
            },
            child: const Text('再来一次'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 设置弹窗
  // ============================================================

  /// 显示设置弹窗
  void _showSettingsDialog() {
    final nameCtrl = TextEditingController(text: _wheelName);
    final probControllers = _probabilities.map((p) =>
      TextEditingController(text: (p * 100).toStringAsFixed(1))
    ).toList();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('转盘设置', style: TextStyle(fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 转盘名称
                const Text('转盘名称', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    hintText: '输入转盘名称',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                ),
                const SizedBox(height: 16),

                // 中奖概率设置
                Row(
                  children: [
                    const Text('中奖概率（%）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(
                      '合计: ${_probabilities.fold(0.0, (a, b) => a + b) * 100}%',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      final n = _items.length;
                      final baseVal = (100 / n).toStringAsFixed(1);
                      final base = double.parse(baseVal);
                      final sum = base * (n - 1);
                      final lastVal = (100 - sum).toStringAsFixed(1);
                      for (int i = 0; i < n - 1; i++) {
                        probControllers[i].text = baseVal;
                      }
                      probControllers[n - 1].text = lastVal;
                      setDialogState(() {});
                    },
                    icon: const Icon(Icons.auto_graph, size: 14),
                    label: const Text('平均分配概率', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ...List.generate(_items.length, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: _wheelColors[i % _wheelColors.length],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: Text(
                          _items[i],
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: TextField(
                          controller: probControllers[i],
                          keyboardType: TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            suffixText: '%',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          ),
                          style: const TextStyle(fontSize: 12),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ),
                    ],
                  ),
                )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                // 验证并保存概率
                double total = 0;
                final newProbs = <double>[];
                bool valid = true;
                for (int i = 0; i < _items.length; i++) {
                  final val = double.tryParse(probControllers[i].text);
                  if (val == null || val < 0) {
                    valid = false;
                    break;
                  }
                  newProbs.add(val / 100);
                  total += val;
                }
                if (!valid) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入有效的概率值')),
                  );
                  return;
                }
                if (total > 100.1) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('所有概率之和不能超过100%')),
                  );
                  return;
                }
                // 如果总和小于100%，自动补到最后一个
                if (total < 100) {
                  newProbs[_items.length - 1] += (100 - total) / 100;
                }
                setState(() {
                  _probabilities.clear();
                  _probabilities.addAll(newProbs);
                  _wheelName = nameCtrl.text.isNotEmpty ? nameCtrl.text : '默认转盘';
                });
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 添加/删除项目
  // ============================================================

  /// 添加项目（v1.51.0+ 修复：通过弹窗输入，保留已有概率设置）
  void _showAddItemDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加选项'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '输入选项名称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(ctx);
              _addItemWithName(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(ctx);
                _addItemWithName(text);
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  /// 使用指定名称添加选项，保留已有概率（v1.51.0+）
  void _addItemWithName(String name) {
    if (_items.length >= 20) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多支持20个选项')),
      );
      return;
    }
    setState(() {
      _items.add(name);
      // 如果已有概率设置，新选项分配1%概率，其他按比例缩减
      if (_probabilities.isNotEmpty && _probabilities.length == _items.length - 1) {
        final newProb = 0.01; // 新选项默认1%
        final scale = (1.0 - newProb) / _probabilities.fold(0.0, (a, b) => a + b);
        for (int i = 0; i < _probabilities.length; i++) {
          _probabilities[i] = _probabilities[i] * scale;
        }
        _probabilities.add(newProb);
      } else {
        _initProbabilities();
      }
    });
  }

  /// 删除项目（v1.51.0+ 修复：保留已有概率设置）
  void _removeItem(int index) {
    if (_items.length <= 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少需要保留2个选项')),
      );
      return;
    }
    setState(() {
      _items.removeAt(index);
      // 如果已有概率设置，删除项的权重按比例分配给其他项
      if (_probabilities.isNotEmpty && _probabilities.length == _items.length + 1) {
        final removedProb = _probabilities.removeAt(index);
        final sum = _probabilities.fold(0.0, (a, b) => a + b);
        if (sum > 0) {
          for (int i = 0; i < _probabilities.length; i++) {
            _probabilities[i] += removedProb * (_probabilities[i] / sum);
          }
        } else {
          // 如果其他项权重都是0，平均分配
          final equal = 1.0 / _probabilities.length;
          for (int i = 0; i < _probabilities.length; i++) {
            _probabilities[i] = equal;
          }
        }
      }
    });
  }

  /// 清空所有项目
  void _clearAllItems() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有转盘内容吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _items.clear();
                _probabilities.clear();
                _currentSavedName = null;
              });
              Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 生成预设选项
  // ============================================================

  void _usePreset(String preset) {
    List<String> items;
    switch (preset) {
      case 'dinner':
        items = ['火锅', '烤肉', '日料', '中餐', '炸鸡', '披萨', '麻辣烫', '烧烤'];
        break;
      case 'drink':
        items = ['奶茶', '咖啡', '可乐', '果汁', '柠檬水', '气泡水', '牛奶', '啤酒'];
        break;
      case 'activity':
        items = ['看电影', '逛街', '打游戏', '运动', '看书', '睡觉', 'K歌', '旅游'];
        break;
      default:
        items = ['选项1', '选项2', '选项3', '选项4', '选项5', '选项6'];
    }
    setState(() {
      _items.clear();
      _items.addAll(items);
      _initProbabilities();
      _currentSavedName = null;
    });
  }

  // ============================================================
  // 保存/加载转盘配置
  // ============================================================

  /// 加载保存的转盘配置
  Future<void> _loadSavedWheels() async {
    try {
      final prefs = AppSettings.prefs!;
      final jsonList = prefs.getStringList('wheel_lottery_saved_wheels') ?? [];
      final wheels = jsonList.map((s) {
        try {
          return SavedWheel.fromJson(jsonDecode(s));
        } catch (_) {
          return null;
        }
      }).whereType<SavedWheel>().toList();
      _savedWheels = wheels;
    } catch (e) {
      AppLogger.e('WheelLottery', '加载保存的转盘失败: $e');
    }
  }

  /// 保存转盘配置列表
  Future<void> _saveSavedWheels() async {
    try {
      final prefs = AppSettings.prefs!;
      final jsonList = _savedWheels.map((w) => jsonEncode(w.toJson())).toList();
      await prefs.setStringList('wheel_lottery_saved_wheels', jsonList);
    } catch (e) {
      AppLogger.e('WheelLottery', '保存转盘配置失败: $e');
    }
  }

  /// 显示保存当前转盘弹窗
  void _showSaveWheelDialog() {
    final nameCtrl = TextEditingController(text: _wheelName);
    showDialog(
      context: context,
      builder: (ctx) {
        final isOverwrite = _savedWheels.any((w) => w.name == nameCtrl.text.trim());
        return AlertDialog(
        title: const Text('保存转盘', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(isOverwrite ? '同名转盘已存在，将直接覆盖' : '保存当前转盘配置，方便下次使用'),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: '转盘名称',
                hintText: '输入转盘名称',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入转盘名称')),
                );
                return;
              }
              setState(() {
                _savedWheels.removeWhere((w) => w.name == name);
                _savedWheels.insert(0, SavedWheel(
                  name: name,
                  items: List.from(_items),
                  probabilities: List.from(_probabilities),
                ));
              });
              _saveSavedWheels();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('转盘「$name」已保存')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
    );
  }

  /// 显示加载转盘弹窗
  void _showLoadWheelDialog() {
    if (_savedWheels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无保存的转盘配置')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('加载转盘', style: TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView.builder(
              itemCount: _savedWheels.length,
              itemBuilder: (_, i) {
                final wheel = _savedWheels[i];
                return Card(
                  child: ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.toll, color: Colors.orange),
                    ),
                    title: Text(wheel.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${wheel.items.length} 个选项',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () {
                        setDialogState(() {
                          _savedWheels.removeAt(i);
                        });
                        _saveSavedWheels();
                      },
                    ),
                    onTap: () {
                      setState(() {
                        _items.clear();
                        _items.addAll(wheel.items);
                        _probabilities.clear();
                        _probabilities.addAll(wheel.probabilities);
                        _wheelName = wheel.name;
                        _nameController.text = wheel.name;
                        _currentSavedName = wheel.name;
                        _rotationAngle = 0.0;
                        _result = null;
                      });
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已加载转盘「${wheel.name}」')),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// 快速覆盖保存当前转盘，如果已保存则直接覆盖，否则弹出命名对话框
  void _quickSaveWheel() {
    final savedIndex = _savedWheels.indexWhere((w) =>
        _currentSavedName != null && w.name == _currentSavedName);
    if (savedIndex >= 0) {
      final name = _savedWheels[savedIndex].name;
      setState(() {
        _savedWheels[savedIndex] = SavedWheel(
          name: name,
          items: List.from(_items),
          probabilities: List.from(_probabilities),
        );
      });
      _saveSavedWheels();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('转盘「$name」已更新')),
      );
    } else {
      _showSaveWheelDialog();
    }
  }

  // ============================================================
  // UI 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final wheelSize = min(size.width - 40, 300.0);

    return Scaffold(
      appBar: AppBar(
        title: Text(_wheelName),
        actions: [
          // 设置按钮
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '转盘设置',
            onPressed: _showSettingsDialog,
          ),
          // 历史记录按钮
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: _showHistoryDialog,
          ),
          // 保存转盘按钮
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存转盘',
            onPressed: _showSaveWheelDialog,
          ),
          // 加载转盘按钮
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: '加载转盘',
            onPressed: _showLoadWheelDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 转盘区域
            SizedBox(
              height: wheelSize + 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 转盘
                  _buildWheel(wheelSize),
                  // 顶部指针
                  Positioned(
                    top: 0,
                    child: _buildPointer(),
                  ),
                  // 中心按钮
                  GestureDetector(
                    onTap: _isSpinning ? null : _startSpin,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(
                        child: _isSpinning
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text(
                                '抽奖',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 上次结果
            if (_result != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.stars, color: Colors.amber, size: 20),
                    const SizedBox(width: 8),
                    const Text('上次中奖：', style: TextStyle(fontSize: 14)),
                    Text(
                      _result!,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),

            // 选项管理
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('转盘选项', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        // 更多菜单（预设+已保存转盘）
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_horiz, size: 20),
                          tooltip: '更多选项',
                          onSelected: (value) {
                            if (value.startsWith('saved:')) {
                              final savedName = value.substring(6);
                              final wheel = _savedWheels.firstWhere((w) => w.name == savedName);
                              setState(() {
                                _items.clear();
                                _items.addAll(wheel.items);
                                _probabilities.clear();
                                _probabilities.addAll(wheel.probabilities);
                                _wheelName = wheel.name;
                                _nameController.text = wheel.name;
                                _currentSavedName = wheel.name;
                                _rotationAngle = 0.0;
                                _result = null;
                              });
                            } else {
                              _usePreset(value);
                            }
                          },
                          itemBuilder: (_) {
                            final entries = <PopupMenuEntry<String>>[];
                            entries.addAll([
                              const PopupMenuItem(value: 'dinner', child: Text('🍽️ 晚餐选择')),
                              const PopupMenuItem(value: 'drink', child: Text('🥤 饮品选择')),
                              const PopupMenuItem(value: 'activity', child: Text('🎮 活动选择')),
                            ]);
                            if (_savedWheels.isNotEmpty) {
                              entries.add(const PopupMenuDivider());
                              for (final wheel in _savedWheels) {
                                entries.add(PopupMenuItem(
                                  value: 'saved:${wheel.name}',
                                  child: Row(
                                    children: [
                                      Icon(Icons.toll, size: 16, color: Colors.orange.shade400),
                                      const SizedBox(width: 8),
                                      Text(wheel.name),
                                    ],
                                  ),
                                ));
                              }
                            }
                            return entries;
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_sweep, size: 20),
                          tooltip: '清空所有',
                          onPressed: _clearAllItems,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 选项列表（带滚动条，v1.51.0+）
                    if (_items.isNotEmpty)
                      Scrollbar(
                        child: SizedBox(
                          height: min(_items.length * 40.0 + 10, 200),
                          child: ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: _items.length,
                            onReorder: (oldIndex, newIndex) {
                              setState(() {
                                if (newIndex > oldIndex) newIndex--;
                                final item = _items.removeAt(oldIndex);
                                _items.insert(newIndex, item);
                                // 同步移动概率（v1.51.0+ 修复：保留概率设置）
                                if (_probabilities.length == _items.length) {
                                  final prob = _probabilities.removeAt(oldIndex);
                                  _probabilities.insert(newIndex, prob);
                                }
                              });
                            },
                            itemBuilder: (_, i) => Container(
                              key: ValueKey(_items[i]),
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: _wheelColors[i % _wheelColors.length].withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Icon(Icons.drag_handle, size: 18, color: Colors.grey),
                                  ),
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: _wheelColors[i % _wheelColors.length],
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _items[i],
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '${(_probabilities[i] * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 16),
                                    onPressed: () => _removeItem(i),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    // 添加选项按钮（v1.51.0+ 改为弹窗输入，避免焦点问题）
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showAddItemDialog,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加选项'),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    if (_currentSavedName != null) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _quickSaveWheel,
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('保存修改'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建转盘
  Widget _buildWheel(double size) {
    return Transform.rotate(
      angle: _rotationAngle,
      child: CustomPaint(
        size: Size(size, size),
        painter: _WheelPainter(
          items: _items,
          colors: _wheelColors,
        ),
      ),
    );
  }

  /// 构建指针
  Widget _buildPointer() {
    return CustomPaint(
      size: const Size(30, 30),
      painter: _PointerPainter(),
    );
  }

  /// 显示历史记录弹窗
  void _showHistoryDialog() {
    // 多选状态
    Set<int> selectedIndices = {};
    bool selectAll = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Text('历史记录', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_history.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      selectAll = !selectAll;
                      if (selectAll) {
                        selectedIndices = Set.from(List.generate(_history.length, (i) => i));
                      } else {
                        selectedIndices.clear();
                      }
                    });
                  },
                  child: Text(selectAll ? '取消全选' : '全选'),
                ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: _history.isEmpty
                ? const Center(child: Text('暂无抽奖记录', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _history.length,
                    itemBuilder: (_, i) {
                      final record = _history[i];
                      final isSelected = selectedIndices.contains(i);
                      return Card(
                        color: isSelected ? Colors.blue.withValues(alpha: 0.05) : null,
                        child: ListTile(
                          leading: Checkbox(
                            value: isSelected,
                            onChanged: (v) {
                              setDialogState(() {
                                if (v == true) {
                                  selectedIndices.add(i);
                                } else {
                                  selectedIndices.remove(i);
                                }
                              });
                            },
                          ),
                          title: Text(
                            record.result,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${record.wheelName} · ${_formatTime(record.timestamp)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () {
                            // 点击显示详情
                            _showRecordDetail(record);
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            if (selectedIndices.isNotEmpty)
              TextButton(
                onPressed: () {
                  _deleteHistory(selectedIndices.toList());
                  Navigator.pop(ctx);
                },
                child: Text('删除选中(${selectedIndices.length})',
                    style: const TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示单条记录详情
  void _showRecordDetail(LotteryRecord record) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('抽奖详情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('转盘名称', record.wheelName),
            _buildDetailRow('中奖结果', record.result),
            _buildDetailRow('抽奖时间', _formatTime(record.timestamp)),
            _buildDetailRow('选项数量', '${record.items.length} 个'),
            const SizedBox(height: 8),
            const Text('所有选项：', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: record.items.map((item) => Chip(
                label: Text(item, style: const TextStyle(fontSize: 11)),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
              )).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text('$label：', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ============================================================
// 转盘绘制器
// ============================================================

class _WheelPainter extends CustomPainter {
  final List<String> items;
  final List<Color> colors;

  _WheelPainter({required this.items, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    if (items.isEmpty) return;

    final segmentAngle = 2 * pi / items.length;

    for (int i = 0; i < items.length; i++) {
      final startAngle = segmentAngle * i - pi / 2;
      final sweepAngle = segmentAngle;

      // 绘制扇形
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );

      // 绘制文字
      final textAngle = startAngle + sweepAngle / 2;
      final textRadius = radius * 0.65;
      final textX = center.dx + textRadius * cos(textAngle);
      final textY = center.dy + textRadius * sin(textAngle);

      final textPainter = TextPainter(
        text: TextSpan(
          text: items[i].length > 4 ? items[i].substring(0, 4) : items[i],
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(textX - textPainter.width / 2, textY - textPainter.height / 2),
      );
    }

    // 绘制边框
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (int i = 0; i < items.length; i++) {
      final startAngle = segmentAngle * i - pi / 2;
      canvas.drawLine(
        center,
        Offset(center.dx + radius * cos(startAngle), center.dy + radius * sin(startAngle)),
        borderPaint,
      );
    }

    // 外圈
    canvas.drawCircle(center, radius, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ============================================================
// 指针绘制器
// ============================================================

class _PointerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(size.width / 2 - 12, 0)
      ..lineTo(size.width / 2 + 12, 0)
      ..close();

    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);

    // 边框
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}