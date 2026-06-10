// 掷骰子页面
// 包含骰子类型选择器、骰子数量选择器、2D骰子动画、开始按钮、历史记录入口
import 'package:flutter/material.dart';

import '../utils/app_logger.dart';
import '../utils/dice_history.dart';
import '../widgets/dice_2d.dart';
import 'dice_history_page.dart';
import 'online/online_lobby_page.dart';

class DicePage extends StatefulWidget {
  const DicePage({super.key});

  @override
  State<DicePage> createState() => _DicePageState();
}

class _DicePageState extends State<DicePage> {
  static const String _logTag = 'DicePage';

  /// 当前选择的骰子类型
  DiceType _selectedDice = DiceType.d6;

  /// 当前骰子数量（1~10）
  int _diceCount = 1;

  /// 每个骰子的结果（索引对应骰子序号）
  List<int?> _results = [];

  /// 是否正在动画中
  bool _isRolling = false;

  @override
  void initState() {
    super.initState();
    _results = List.filled(_diceCount, null);
  }

  /// 开始掷骰子
  Future<void> _rollDice() async {
    if (_isRolling) return;

    setState(() {
      _isRolling = true;
      _results = List.filled(_diceCount, null);
    });

    // 预计算每个骰子的结果
    final newResults = List.generate(_diceCount, (_) => DiceHistory.roll(_selectedDice));

    // 等待动画完成（1.5秒）
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    setState(() {
      _results = newResults;
      _isRolling = false;
    });

    // 保存每条历史记录
    for (int i = 0; i < _diceCount; i++) {
      final record = DiceRecord(
        id: DateTime.now().millisecondsSinceEpoch + i,
        diceType: _selectedDice,
        result: newResults[i],
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      await DiceHistory.add(record);
    }

    final total = newResults.reduce((a, b) => a + b);
    AppLogger.i(_logTag, '掷骰子：${_selectedDice.label} x$_diceCount -> $newResults (总计: $total)');
  }

  /// 打开历史记录页面
  void _openHistory() async {
    AppLogger.i(_logTag, '打开掷骰子历史记录');
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DiceHistoryPage()),
    );
  }

  /// 计算总点数
  int? get _totalResult {
    if (_results.isEmpty || _results.any((r) => r == null)) return null;
    return _results.whereType<int>().reduce((a, b) => a + b);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('掷骰子'),
        actions: [
          // 联机按钮
          IconButton(
            icon: const Icon(Icons.wifi),
            tooltip: '联机',
            onPressed: () {
              AppLogger.i(_logTag, '打开联机入口');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OnlineLobbyPage()),
              );
            },
          ),
          // 右上角历史记录按钮
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: _openHistory,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            // 骰子类型选择器
            _buildDiceSelector(),
            const SizedBox(height: 12),
            // 骰子数量选择器
            _buildDiceCountSelector(),
            const SizedBox(height: 16),
            // 2D骰子区域
            Expanded(
              child: _buildDiceArea(),
            ),
            // 结果展示
            if (_totalResult != null && !_isRolling)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _diceCount == 1
                      ? '结果：$_totalResult 点'
                      : '总计：$_totalResult 点',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                ),
              ),
            // 开始按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isRolling ? null : _rollDice,
                  icon: Icon(_isRolling ? Icons.hourglass_empty : Icons.casino),
                  label: Text(
                    _isRolling ? '掷骰子中...' : '开始掷骰子',
                    style: const TextStyle(fontSize: 18),
                  ),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建骰子类型选择器
  Widget _buildDiceSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.category, size: 20),
          const SizedBox(width: 8),
          const Text('骰子类型：'),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<DiceType>(
              initialValue: _selectedDice,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              items: DiceType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type.label),
                );
              }).toList(),
              onChanged: _isRolling
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedDice = value);
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  /// 构建骰子数量选择器
  Widget _buildDiceCountSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.format_list_numbered, size: 20),
          const SizedBox(width: 8),
          const Text('骰子数量：'),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _diceCount,
              menuMaxHeight: 240,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              items: List.generate(20, (i) => i + 1).map((count) {
                return DropdownMenuItem(
                  value: count,
                  child: Text('$count 个'),
                );
              }).toList(),
              onChanged: _isRolling
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _diceCount = value;
                          _results = List.filled(_diceCount, null);
                        });
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }

  /// 构建骰子显示区域
  Widget _buildDiceArea() {
    // 单个骰子时居中显示，限制大小
    if (_diceCount == 1) {
      return Center(
        child: SizedBox(
          width: 170,
          height: 170,
          child: Dice2D(
            diceType: _selectedDice,
            result: _results.isNotEmpty ? _results[0] : null,
            isAnimating: _isRolling,
          ),
        ),
      );
    }

    // 多个骰子时以中心点向两边扩散排布，每行最多4个
    // 将骰子按每行4个分组，每组居中显示
    final diceWidgets = List.generate(_diceCount, (index) {
      return SizedBox(
        width: 85,
        height: 85,
        child: Dice2D(
          diceType: _selectedDice,
          result: _results[index],
          isAnimating: _isRolling,
        ),
      );
    });

    // 每行最多4个骰子
    const maxPerRow = 4;
    final rows = <Widget>[];
    for (int i = 0; i < diceWidgets.length; i += maxPerRow) {
      final end = (i + maxPerRow < diceWidgets.length) ? i + maxPerRow : diceWidgets.length;
      rows.add(
        Wrap(
          spacing: 14,
          runSpacing: 18,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: diceWidgets.sublist(i, end),
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: rows
              .expand((row) => [SizedBox(height: 18), row])
              .skip(1)
              .toList(),
        ),
      ),
    );
  }
}
