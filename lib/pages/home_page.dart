// 工具箱 App 首页
// 采用 GridView 展示所有可用工具
// 后续添加新工具时只需在 _toolList 列表中追加 ToolItem
// 左上角提供三明治菜单按钮，点击后从左向右滑出抽屉
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/tool_item.dart';
import '../services/auth_service.dart';
import '../services/session_tracker.dart';
import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../widgets/tool_card.dart';
import 'about_page.dart';
import 'decibel_page.dart';
import 'network_speed_page.dart';
import 'settings_page.dart';
import 'video_convert_page.dart';
import 'heart_rate_page.dart';
import 'fun_tools_page.dart';

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
    ToolItem(
      name: '心率广播接收器',
      icon: Icons.favorite,
      color: Colors.red,
      pageBuilder: (_) => const HeartRatePage(),
    ),
    ToolItem(
      name: '趣味工具',
      icon: Icons.toys,
      color: Colors.deepPurple,
      pageBuilder: (_) => const FunToolsPage(),
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
    final isLoggedIn = AuthService.instance.isLoggedIn;
    final isGuest = AuthService.instance.isGuestMode;

    // 根据登录状态显示不同的用户信息
    final displayEmail = isLoggedIn
        ? (AuthService.instance.userEmail ?? '已登录')
        : (isGuest ? '游客模式' : 'ToolApp');
    final displayHint = isLoggedIn
        ? '登录状态：已登录'
        : (isGuest ? '数据仅保存在本地' : '');

    return Drawer(
      // 抽屉整体背景色
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抽屉顶部：应用 Logo + 名称 + 用户信息
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
                    child: Icon(
                      isGuest
                          ? Icons.person_outline
                          : Icons.handyman_outlined,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 应用名称 + 用户邮箱/游客标识
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
                          displayEmail,
                          style: TextStyle(
                            fontSize: 12,
                            color: isGuest
                                ? Colors.orange.shade700
                                : Colors.grey.shade600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (displayHint.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Text(
                            displayHint,
                            style: TextStyle(
                              fontSize: 10,
                              color: isGuest
                                  ? Colors.orange.shade600
                                  : Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 游客模式下显示"登录账号"入口
            if (isGuest)
              ListTile(
                leading: Icon(
                  Icons.login,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('登录账号'),
                subtitle: const Text('登录后数据可同步到服务器'),
                onTap: () {
                  AppLogger.i('HomePage', '点击菜单 -> 登录账号');
                  Navigator.pop(context);
                  // 退出游客模式，回到登录页
                  AuthService.instance.exitGuestMode();
                },
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
            // 菜单项：分享应用
            ListTile(
              leading: Icon(
                Icons.share_outlined,
                color: theme.colorScheme.primary,
              ),
              title: const Text('分享应用'),
              subtitle: const Text('生成二维码，邀请朋友下载'),
              onTap: () {
                AppLogger.i('HomePage', '点击菜单 -> 分享应用');
                Navigator.pop(context);
                _showShareDialog(context);
              },
            ),
            // 分割线
            const Divider(height: 1),
            // 菜单项：官网链接（小字但明显）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: InkWell(
                onTap: () => _openOfficialWebsite(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.public,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '访问官网 · ${appSettings.serverUrl.replaceFirst('http://', '').replaceFirst('https://', '')}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 菜单项：版本信息（仅展示）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                // 记录页面访问活动
                SessionTracker.instance.logPageView(tool.name);
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

  // 显示分享应用对话框：包含二维码 + 复制链接按钮
  void _showShareDialog(BuildContext context) {
    final theme = Theme.of(context);
    final serverUrl = appSettings.serverUrl;

    // 防御性：空 URL 时给出明确提示
    if (serverUrl.isEmpty) {
      AppLogger.w('HomePage', '分享应用 - serverUrl 为空');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务器地址未配置，请先在设置中填写')),
      );
      return;
    }

    // 使用 Uri 规范化拼接，避免双斜杠或缺少斜杠的问题
    String downloadUrl;
    try {
      final baseUri = Uri.parse(serverUrl);
      // 确保 path 规范化
      final basePath = baseUri.path.endsWith('/')
          ? baseUri.path.substring(0, baseUri.path.length - 1)
          : baseUri.path;
      downloadUrl = baseUri
          .replace(
            path: '$basePath/downloads/${AppInfo.apkFileName}',
          )
          .toString();
    } catch (e) {
      AppLogger.e('HomePage', '分享应用 - URL 解析异常: $e');
      downloadUrl = '${serverUrl.replaceAll(RegExp(r'/$'), '')}/downloads/${AppInfo.apkFileName}';
    }

    AppLogger.d('HomePage', '分享应用 - 下载链接: $downloadUrl');

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.share_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            const Text('分享应用'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '扫描二维码或复制链接，邀请朋友下载 ToolApp',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            // 二维码容器
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: QrImageView(
                data: downloadUrl,
                version: QrVersions.auto,
                size: 180,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF1d1d1f),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF1d1d1f),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                downloadUrl,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _copyLink(context, downloadUrl);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制链接'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _shareViaSystem(context, downloadUrl);
            },
            icon: const Icon(Icons.share, size: 18),
            label: const Text('系统分享'),
          ),
        ],
      ),
    );
  }

  // 复制下载链接到剪贴板
  void _copyLink(BuildContext context, String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('链接已复制到剪贴板'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: '知道了',
              onPressed: () {},
            ),
          ),
        );
      }
      AppLogger.i('HomePage', '下载链接已复制: $url');
    } catch (e) {
      AppLogger.e('HomePage', '复制链接失败: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('复制失败: $e')),
        );
      }
    }
  }

  // 通过系统分享功能分享下载链接
  void _shareViaSystem(BuildContext context, String url) async {
    try {
      await Share.share(
        'ToolApp 实用工具箱，下载地址：$url',
        subject: 'ToolApp 实用工具箱 · 免费下载',
      );
      AppLogger.i('HomePage', '已通过系统分享功能分享: $url');
    } catch (e) {
      AppLogger.e('HomePage', '系统分享失败: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }

  // 打开官网链接
  void _openOfficialWebsite(BuildContext context) async {
    final url = appSettings.serverUrl;
    AppLogger.i('HomePage', '打开官网: $url');

    if (url.isEmpty) {
      AppLogger.w('HomePage', '官网地址为空');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务器地址未配置，请先在设置中填写')),
        );
      }
      return;
    }

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        if (context.mounted) {
          _copyLink(context, url);
        }
      }
    } catch (e) {
      AppLogger.e('HomePage', '打开官网失败: $e');
      if (context.mounted) {
        _copyLink(context, url);
      }
    }
  }
}
