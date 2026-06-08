// 工具箱 App 首页
// 采用 GridView 展示所有可用工具
// 后续添加新工具时只需在 _toolList 列表中追加 ToolItem
// 左上角提供三明治菜单按钮，点击后从左向右滑出抽屉
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'about_page.dart';
import 'decibel_page.dart';
import 'network_speed_page.dart';
import 'settings_page.dart';
import 'video_convert_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  // 工具列表：第一期仅含分贝测试仪
  // 后续添加新工具只需在此处追加一项
  static final List<ToolItem> _toolList = [
    ToolItem(
      name: '分贝测试仪',
      icon: Icons.graphic_eq,
      color: Colors.indigo,
      pageBuilder: (_) => const DecibelPage(),
    ),
    ToolItem(
      name: '网速测试',
      icon: Icons.network_check,
      color: Colors.teal,
      pageBuilder: (_) => const NetworkSpeedPage(),
    ),
    ToolItem(
      name: '视频格式转换',
      icon: Icons.video_settings,
      color: Colors.deepOrange,
      // v1.6.34+ 标记为 Beta：视频格式转换功能还在实验室阶段，
      //   暂停/取消/状态机还存在一些边界场景未完全收敛，
      //   标 Beta 提示用户该功能尚未完全稳定
      isBeta: true,
      pageBuilder: (_) => const VideoConvertPage(),
    ),
  ];

  // 构建右上角"软件说明"按钮：圆形背景 + 问号图标
  Widget _buildAboutButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Material(
        // 按钮整体使用灰色系：浅灰圆形底 + 深灰问号图标
        color: Colors.grey.shade200,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            // 点击"软件说明"按钮：跳转到关于页
            AppLogger.i('HomePage', '点击软件说明按钮');
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutPage()),
            );
          },
          child: const SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Icon(
                Icons.help_outline,
                size: 22,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 构建左侧抽屉：菜单头部 + 菜单项列表
  // 默认从左向右滑出（Flutter Drawer 内置动画即为从左滑入/滑出）
  Widget _buildDrawer(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      // 抽屉整体背景色
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抽屉顶部：应用 Logo + 名称
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                border: Border(
                  bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // 应用 Logo
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.handyman_outlined,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 应用名称
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '实用工具箱',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ToolApp',
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
            ),
            // 菜单项：设置
            ListTile(
              leading: Icon(
                Icons.settings_outlined,
                color: theme.colorScheme.primary,
              ),
              title: const Text('设置'),
              subtitle: const Text('屏幕旋转、暗色模式等'),
              onTap: () {
                AppLogger.i('HomePage', '点击菜单 -> 设置');
                // 关闭抽屉后再跳转，避免返回时抽屉仍打开
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
              },
            ),
            // 菜单项：软件说明
            ListTile(
              leading: Icon(
                Icons.info_outline,
                color: theme.colorScheme.primary,
              ),
              title: const Text('软件说明'),
              onTap: () {
                AppLogger.i('HomePage', '点击菜单 -> 软件说明');
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutPage()),
                );
              },
            ),
            // 分割线
            const Divider(height: 1),
            // 菜单项：版本信息（仅展示）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '更多功能持续开发中…',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLogger.d('HomePage', '首页 build');
    return Scaffold(
      // 左侧抽屉：菜单从左向右滑出
      drawer: _buildDrawer(context),
      // 顶部应用栏
      appBar: AppBar(
        // 左上角：三明治菜单按钮（Flutter 在指定了 drawer 时自动渲染）
        // 这里显式指定为三明治图标样式
        leading: Builder(
          builder: (innerContext) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '菜单',
            onPressed: () {
              AppLogger.i('HomePage', '点击左上角三明治菜单');
              Scaffold.of(innerContext).openDrawer();
            },
          ),
        ),
        title: const Text('实用工具箱'),
        actions: [
          // 右上角：软件说明（圆形问号按钮）
          _buildAboutButton(context),
        ],
      ),
      // 主体：工具网格视图
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          // 每行显示 3 个工具
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: _toolList.length,
          itemBuilder: (context, index) {
            final tool = _toolList[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                // 点击工具卡片：跳转到对应页面
                AppLogger.i('HomePage', '点击工具：${tool.name}');
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
