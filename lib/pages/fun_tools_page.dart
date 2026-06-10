// 趣味工具页面
// 作为趣味工具大类的二级入口，展示所有趣味小工具
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'dice_page.dart';
import 'mahjong_page.dart';
import 'period_page.dart';

class FunToolsPage extends StatelessWidget {
  const FunToolsPage({super.key});

  // 趣味工具列表
  static final List<ToolItem> _funTools = [
    ToolItem(
      name: '掷骰子',
      icon: Icons.casino,
      color: Colors.deepPurple,
      pageBuilder: (_) => const DicePage(),
    ),
    ToolItem(
      name: '麻将计分器',
      icon: Icons.grid_on,
      color: Colors.teal,
      pageBuilder: (_) => const MahjongPage(),
    ),
    ToolItem(
      name: '经期宝',
      icon: Icons.favorite,
      color: Colors.pink,
      pageBuilder: (_) => const PeriodPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppLogger.d('FunToolsPage', '趣味工具页面 build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('趣味工具'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: _funTools.length,
          itemBuilder: (context, index) {
            final tool = _funTools[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                AppLogger.i('FunToolsPage', '点击趣味工具：${tool.name}');
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: tool.pageBuilder),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
