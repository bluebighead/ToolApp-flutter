// 房主设置页
// 设置房间参数：参与人数、房间名称、骰子类型、骰子数量、玩法
// 所有必填项完成后"创建房间"按钮才可点击
// 检测到活跃房间时提示用户先退出
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/online_room.dart';
import '../../services/online_game_service.dart';
import '../../services/online_overlay_manager.dart';
import '../../utils/app_logger.dart';
import '../../utils/dice_history.dart';
import 'waiting_room_page.dart';

class HostSetupPage extends StatefulWidget {
  const HostSetupPage({super.key});

  @override
  State<HostSetupPage> createState() => _HostSetupPageState();
}

class _HostSetupPageState extends State<HostSetupPage> {
  static const String _logTag = 'HostSetupPage';

  /// 房间名称控制器
  final TextEditingController _roomNameController = TextEditingController();

  /// 参与人数（2~10）
  int _maxPlayers = 2;

  /// 骰子类型
  DiceType _diceType = DiceType.d6;

  /// 骰子数量
  int _diceCount = 1;

  /// 玩法
  GameMode _gameMode = GameMode.compareSize;

  /// 掷骰模式（仅猜数字玩法使用）
  RollMode _rollMode = RollMode.multiPlayer;

  /// 是否正在创建
  bool _isCreating = false;

  /// 所有必填项是否完成
  bool get _isFormValid => _roomNameController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _roomNameController.dispose();
    super.dispose();
  }

  /// 创建房间
  Future<void> _createRoom() async {
    if (!_isFormValid || _isCreating) return;

    // 检查是否已有活跃房间（双重保障）
    if (OnlineOverlayManager().hasActiveService) {
      _showActiveRoomDialog();
      return;
    }

    setState(() => _isCreating = true);

    final service = OnlineGameService();
    final success = await service.createRoom(
      roomName: _roomNameController.text.trim(),
      maxPlayers: _maxPlayers,
      diceType: _diceType.name,
      diceCount: _diceCount,
      gameMode: _gameMode,
      rollMode: _rollMode,
    );

    if (!mounted) return;

    setState(() => _isCreating = false);

    if (success) {
      AppLogger.i(_logTag, '房间创建成功');
      // 注册到全局管理器（用于悬浮按钮）
      OnlineOverlayManager().registerService(service);
      OnlineOverlayManager().isInOnlinePage = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => WaitingRoomPage(gameService: service),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('创建房间失败，请检查网络权限')),
      );
    }
  }

  /// 显示活跃房间提示
  void _showActiveRoomDialog() {
    final roomName = OnlineOverlayManager().activeService?.room?.roomName ?? '联机房间';
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检测到活跃房间'),
        content: Text(
          '你当前还在房间「$roomName」中。\n\n'
          '请先返回房间或退出房间后再创建新房间。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(false);
              OnlineOverlayManager().navigateToRoomPage(context);
            },
            child: const Text('返回房间'),
          ),
          ElevatedButton(
            onPressed: () async {
              // 退出当前房间
              Navigator.of(ctx).pop(true);
              final service = OnlineOverlayManager().activeService;
              if (service != null) {
                if (service.isHost) {
                  await service.closeRoom();
                } else {
                  await service.leaveRoom();
                }
                OnlineOverlayManager().unregisterService();
              }
              AppLogger.i(_logTag, '用户选择退出房间后再创建');
            },
            child: const Text('退出房间'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('创建房间')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 房间名称
            Text('房间名称',
                style: TextStyle(
                    fontWeight: FontWeight.w500, color: theme.primaryColor)),
            const SizedBox(height: 8),
            TextField(
              controller: _roomNameController,
              decoration: InputDecoration(
                hintText: '请输入房间名称',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.label),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),

            // 参与人数
            _buildSelector(
              icon: Icons.people,
              label: '参与人数',
              value: '$_maxPlayers 人',
              onTap: () => _showNumberPicker(
                title: '参与人数',
                minValue: 2,
                maxValue: 10,
                currentValue: _maxPlayers,
                onChanged: (v) => setState(() => _maxPlayers = v),
              ),
            ),
            const SizedBox(height: 12),

            // 骰子类型
            _buildSelector(
              icon: Icons.category,
              label: '骰子类型',
              value: _diceType.label,
              onTap: () => _showDiceTypePicker(),
            ),
            const SizedBox(height: 12),

            // 骰子数量
            _buildSelector(
              icon: Icons.format_list_numbered,
              label: '骰子数量',
              value: '$_diceCount 个',
              onTap: () => _showNumberPicker(
                title: '骰子数量',
                minValue: 1,
                maxValue: 20,
                currentValue: _diceCount,
                onChanged: (v) => setState(() => _diceCount = v),
              ),
            ),
            const SizedBox(height: 12),

            // 玩法
            _buildSelector(
              icon: Icons.sports_esports,
              label: '玩法',
              value: _gameMode.label,
              onTap: () => _showGameModePicker(),
            ),

            // 掷骰模式（仅猜数字玩法显示）
            if (_gameMode == GameMode.guessNumber) ...[
              const SizedBox(height: 12),
              _buildSelector(
                icon: Icons.person_outline,
                label: '掷骰模式',
                value: _rollMode.label,
                onTap: () => _showRollModePicker(),
              ),
            ],
            const SizedBox(height: 32),

            // 创建房间按钮
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _isFormValid && !_isCreating ? _createRoom : null,
                icon: _isCreating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.add_home),
                label: Text(
                  _isCreating ? '创建中...' : '创建房间',
                  style: const TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建选择器行
  Widget _buildSelector({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          prefixIcon: Icon(icon),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).primaryColor)),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 显示数字选择器（带确认/取消按钮）
  void _showNumberPicker({
    required String title,
    required int minValue,
    required int maxValue,
    required int currentValue,
    required ValueChanged<int> onChanged,
  }) {
    int tempValue = currentValue;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏（带确认/取消按钮）
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                Text(title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    onChanged(tempValue);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: currentValue - minValue,
              ),
              onSelectedItemChanged: (index) => tempValue = minValue + index,
              children: List.generate(
                maxValue - minValue + 1,
                (i) => Center(
                    child: Text('${minValue + i}',
                        style: const TextStyle(fontSize: 20))),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示骰子类型选择器（带确认/取消按钮）
  void _showDiceTypePicker() {
    DiceType tempType = _diceType;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('骰子类型',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    setState(() => _diceType = tempType);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController: FixedExtentScrollController(
                initialItem: DiceType.values.indexOf(_diceType),
              ),
              onSelectedItemChanged: (index) => tempType = DiceType.values[index],
              children: DiceType.values
                  .map((t) => Center(
                      child: Text(t.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示玩法选择器（带确认/取消按钮）
  void _showGameModePicker() {
    GameMode tempMode = _gameMode;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('玩法',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    setState(() => _gameMode = tempMode);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController:
                  FixedExtentScrollController(initialItem: GameMode.values.indexOf(_gameMode)),
              onSelectedItemChanged: (index) => tempMode = GameMode.values[index],
              children: GameMode.values
                  .map((m) => Center(
                      child: Text(m.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示掷骰模式选择器（带确认/取消按钮，仅猜数字玩法）
  void _showRollModePicker() {
    RollMode tempMode = _rollMode;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(fontSize: 16, color: Colors.grey)),
                ),
                const Text('掷骰模式',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                TextButton(
                  onPressed: () {
                    setState(() => _rollMode = tempMode);
                    Navigator.pop(ctx);
                  },
                  child: const Text('确认', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 160,
            child: CupertinoPicker(
              itemExtent: 40,
              scrollController:
                  FixedExtentScrollController(initialItem: RollMode.values.indexOf(_rollMode)),
              onSelectedItemChanged: (index) => tempMode = RollMode.values[index],
              children: RollMode.values
                  .map((m) => Center(
                      child: Text(m.label,
                          style: const TextStyle(fontSize: 20))))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
