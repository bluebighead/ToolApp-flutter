// 屏幕坏点检测页面
// 通过显示纯色全屏画面来检测屏幕是否存在坏点、亮点或暗点
// 成熟方案参考：遍历多种纯色（红/绿/蓝/白/黑/黄/青/品红），
//   用户点击屏幕切换颜色，仔细观察是否有异常像素点
//   黑色画面检测亮点，白色画面检测暗点，彩色画面检测色彩异常
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';

class ScreenDeadPixelPage extends StatefulWidget {
  const ScreenDeadPixelPage({super.key});

  @override
  State<ScreenDeadPixelPage> createState() => _ScreenDeadPixelPageState();
}

class _ScreenDeadPixelPageState extends State<ScreenDeadPixelPage> {
  // 检测颜色列表
  static const List<_ColorItem> _colors = [
    _ColorItem('红色', Colors.red, '检测红色子像素是否正常'),
    _ColorItem('绿色', Colors.green, '检测绿色子像素是否正常'),
    _ColorItem('蓝色', Colors.blue, '检测蓝色子像素是否正常'),
    _ColorItem('白色', Colors.white, '检测暗点（黑点）'),
    _ColorItem('黑色', Colors.black, '检测亮点（白点）'),
    _ColorItem('黄色', Colors.yellow, '检测红+绿子像素组合'),
    _ColorItem('青色', Colors.cyan, '检测绿+蓝子像素组合'),
    _ColorItem('品红', Colors.pink, '检测红+蓝子像素组合'),
  ];

  // 当前颜色索引
  int _currentIndex = 0;

  // 是否全屏模式
  bool _isFullscreen = false;

  // 获取当前颜色
  _ColorItem get _current => _colors[_currentIndex];

  @override
  Widget build(BuildContext context) {
    // 全屏模式：隐藏状态栏和导航栏
    if (_isFullscreen) {
      return _buildFullscreen();
    }

    // 普通模式
    return Scaffold(
      appBar: AppBar(
        title: const Text('屏幕坏点检测'),
      ),
      body: Column(
        children: [
          // 颜色预览区域
          Expanded(
            child: GestureDetector(
              onTap: _nextColor,
              child: Container(
                color: _current.color,
                width: double.infinity,
                child: _current.color == Colors.black
                    ? const Center(
                        child: Text(
                          '黑色画面 - 点击切换\n观察是否有白色亮点',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 16),
                        ),
                      )
                    : null,
              ),
            ),
          ),

          // 控制面板
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 当前颜色信息
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _current.color,
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _current.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _current.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // 进度指示
                Text(
                  '${_currentIndex + 1} / ${_colors.length}',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (_currentIndex + 1) / _colors.length,
                ),

                const SizedBox(height: 16),

                // 操作按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 上一个颜色
                    OutlinedButton.icon(
                      onPressed:
                          _currentIndex > 0 ? _prevColor : null,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('上一个'),
                    ),
                    // 全屏检测
                    ElevatedButton.icon(
                      onPressed: _enterFullscreen,
                      icon: const Icon(Icons.fullscreen),
                      label: const Text('全屏检测'),
                    ),
                    // 下一个颜色
                    OutlinedButton.icon(
                      onPressed:
                          _currentIndex < _colors.length - 1 ? _nextColor : null,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('下一个'),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // 使用说明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: Colors.blue),
                          SizedBox(width: 4),
                          Text(
                            '使用说明',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 4),
                      Text(
                        '• 仔细观察屏幕上是否有与背景色不一致的像素点\n'
                        '• 黑色画面下出现的白色点为亮点\n'
                        '• 白色画面下出现的黑色点为暗点\n'
                        '• 彩色画面下出现的异常色点为子像素损坏\n'
                        '• 点击预览区域或全屏模式可切换颜色',
                        style: TextStyle(fontSize: 12, color: Colors.black87),
                      ),
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

  // 全屏模式
  Widget _buildFullscreen() {
    // 设置全屏沉浸模式
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    return GestureDetector(
      onTap: _nextColor,
      onLongPress: _exitFullscreen,
      child: Container(
        color: _current.color,
        width: double.infinity,
        height: double.infinity,
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 顶部提示
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  '${_current.name} (${_currentIndex + 1}/${_colors.length})',
                  style: TextStyle(
                    color: _current.color == Colors.black
                        ? Colors.white38
                        : Colors.black26,
                    fontSize: 14,
                  ),
                ),
              ),

              // 中间操作提示
              Text(
                '点击切换颜色\n长按退出全屏',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _current.color == Colors.black
                      ? Colors.white24
                      : Colors.black12,
                  fontSize: 16,
                ),
              ),

              // 底部留白
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // 下一个颜色
  void _nextColor() {
    setState(() {
      _currentIndex = (_currentIndex + 1) % _colors.length;
    });
    AppLogger.d('ScreenDeadPixelPage', '切换到: ${_current.name}');
  }

  // 上一个颜色
  void _prevColor() {
    setState(() {
      _currentIndex = (_currentIndex - 1 + _colors.length) % _colors.length;
    });
  }

  // 进入全屏
  void _enterFullscreen() {
    setState(() => _isFullscreen = true);
    // 锁定竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // 退出全屏
  void _exitFullscreen() {
    // 恢复系统 UI
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    SystemChrome.setPreferredOrientations([]);
    setState(() => _isFullscreen = false);
  }
}

// 颜色项数据
class _ColorItem {
  final String name;
  final Color color;
  final String description;

  const _ColorItem(this.name, this.color, this.description);
}
