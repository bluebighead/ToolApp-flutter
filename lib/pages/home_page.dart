// 工具箱 App 首页
// 采用 GridView 展示所有可用工具
// 后续添加新工具时只需在 _dailyTools 或 _geekTools 列表中追加 ToolItem
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
import 'account/account_page.dart';
import '../utils/app_settings.dart';
import '../widgets/tool_card.dart';
import 'about_page.dart';
import 'decibel_page.dart';
import 'network_speed_page.dart';
import 'settings_page.dart';
import 'video_convert_page.dart';
import 'heart_rate_page.dart';
import 'fun_tools_page.dart';
import 'device_inspect_page.dart';
import 'device_inspect/package_viewer_page.dart';
import 'device_inspect/electronic_calc_page.dart';
import 'device_inspect/bluetooth_debug_page.dart';
import 'device_inspect/nfc_reader_page.dart';
import 'encryptor_page.dart';
import 'encryptor/url_parser_page.dart';
import 'compressor_entry_page.dart';
import 'music/music_player_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 跟踪水平手势起始位置，用于全屏左滑打开 Drawer
  double _dragStartX = 0;
  bool _isDragging = false;

  // 日常小白区工具列表
  // 面向普通用户的日常工具，开箱即用
  static final List<ToolItem> _dailyTools = [
    // 压缩器入口（包含视频、音频、图片压缩）
    ToolItem(
      name: '压缩器',
      icon: Icons.compress,
      color: Colors.cyan,
      category: ToolCategory.daily,
      subtitle: '视频 · 音频 · 图片',
      pageBuilder: (_) => const CompressorEntryPage(),
    ),
    ToolItem(
      name: '分贝测试仪',
      icon: Icons.graphic_eq,
      color: Colors.indigo,
      category: ToolCategory.daily,
      pageBuilder: (_) => const DecibelPage(),
    ),
    ToolItem(
      name: '网速测试',
      icon: Icons.network_check,
      color: Colors.teal,
      category: ToolCategory.daily,
      pageBuilder: (_) => const NetworkSpeedPage(),
    ),
    ToolItem(
      name: '趣味工具',
      icon: Icons.toys,
      color: Colors.deepPurple,
      category: ToolCategory.daily,
      subtitle: '骰子 · 麻将 · 经期',
      pageBuilder: (_) => const FunToolsPage(),
    ),
    // 从极客区迁移过来的工具
    ToolItem(
      name: '视频格式转换',
      icon: Icons.video_settings,
      color: Colors.deepOrange,
      category: ToolCategory.daily,
      isBeta: true,
      pageBuilder: (_) => const VideoConvertPage(),
    ),
    ToolItem(
      name: '心率广播接收器',
      icon: Icons.favorite,
      color: Colors.red,
      category: ToolCategory.daily,
      pageBuilder: (_) => const HeartRatePage(),
    ),
    // v1.55.0+ 音乐播放器
    ToolItem(
      name: '音乐播放器',
      icon: Icons.music_note,
      color: Colors.purple,
      category: ToolCategory.daily,
      subtitle: '本地 · 云音乐',
      pageBuilder: (_) => const MusicPlayerPage(),
    ),
  ];

  // 极客区工具列表
  // 面向专业/极客用户的高级工具
  // v1.35.0+ 新增：安装包免压查看器
  // v1.52.3+ 新增：网址解析工具
  static final List<ToolItem> _geekTools = [
    ToolItem(
      name: '设备检修工具',
      icon: Icons.build,
      color: Colors.blueGrey,
      category: ToolCategory.geek,
      subtitle: '摄像头 · 坏点 · 指纹',
      pageBuilder: (_) => const DeviceInspectPage(),
    ),
    ToolItem(
      name: '加解密工具',
      icon: Icons.enhanced_encryption,
      color: Colors.amber,
      category: ToolCategory.geek,
      subtitle: '摩斯电码 · 扫码传信 · 解码',
      pageBuilder: (_) => const EncryptorPage(),
    ),
    ToolItem(
      name: '安装包免压查看',
      icon: Icons.archive,
      color: Colors.deepPurple,
      category: ToolCategory.geek,
      subtitle: 'ZIP · APK · 7z',
      pageBuilder: (_) => const PackageViewerPage(),
    ),
    ToolItem(
      name: '电子元件计算',
      icon: Icons.electrical_services,
      color: Colors.brown,
      category: ToolCategory.geek,
      subtitle: '色环电阻 · 贴片 · 电容',
      pageBuilder: (_) => const ElectronicCalcPage(),
    ),
    ToolItem(
      name: '网址解析',
      icon: Icons.web,
      color: Colors.blue,
      category: ToolCategory.geek,
      subtitle: '爬取 · 提取 · 分析',
      pageBuilder: (_) => const UrlParserPage(),
    ),
    ToolItem(
      name: '蓝牙调试器',
      icon: Icons.bluetooth,
      color: Colors.lightBlue,
      category: ToolCategory.geek,
      isBeta: true,
      subtitle: '扫描 · 服务 · 特征值',
      pageBuilder: (_) => const BluetoothDebugPage(),
    ),
    ToolItem(
      name: 'NFC读写器',
      icon: Icons.nfc,
      color: Colors.indigo,
      category: ToolCategory.geek,
      subtitle: '读取 · 写入 · 识别',
      pageBuilder: (_) => const NfcReaderPage(),
    ),
  ];

  // 构建区块：标题行 + 工具网格
  // accentColor 为区块标识色，用于标题左侧竖线和文字着色
  Widget _buildZone({
    required BuildContext context,
    required String title,
    required String subtitle,
    required Color accentColor,
    required List<ToolItem> tools,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 区块标题行：左侧彩色竖线 + 标题 + 副标题
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              // 左侧彩色竖线标识
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              // 区块标题
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: accentColor,
                ),
              ),
              const SizedBox(width: 8),
              // 副标题描述
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
        // 工具卡片网格
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: tools.length,
          itemBuilder: (context, index) {
            final tool = tools[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                AppLogger.i('HomePage', '点击工具：${tool.name}');
                SessionTracker.instance.logPageView(tool.name);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: tool.pageBuilder),
                );
              },
            );
          },
        ),
      ],
    );
  }

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
            // 抽屉顶部：应用 Logo + 名称 + 用户信息（点击进入账号设置）
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
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  AppLogger.i('HomePage', '点击侧边栏顶部 -> 账号设置');
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AccountPage()),
                  );
                },
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
    return Scaffold(
      // 左侧抽屉：菜单从左向右滑出
      drawer: _buildDrawer(context),
      // 禁用内置边缘滑动手势，改用全屏手势检测
      drawerEnableOpenDragGesture: false,
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
      // 主体：双区块布局 — 日常小白区 + 极客区
      // 使用 Listener 监听原始指针事件，绕过手势竞技场冲突
      // 外层 Builder 确保 context 是 Scaffold 的后代
      body: Builder(
        builder: (bodyContext) => Listener(
          onPointerDown: (event) {
            _dragStartX = event.position.dx;
            _isDragging = true;
          },
          onPointerMove: (event) {
            if (!_isDragging) return;
            final delta = event.position.dx - _dragStartX;
            // 滑动超过 100px 时触发打开 Drawer
            if (delta > 100) {
              _isDragging = false;
              Scaffold.of(bodyContext).openDrawer();
            }
          },
          onPointerUp: (_) {
            _isDragging = false;
          },
          onPointerCancel: (_) {
            _isDragging = false;
          },
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 日常小白区
                _buildZone(
                  context: bodyContext,
                  title: '日常小白区',
                  subtitle: '简单好用，开箱即用',
                  accentColor: const Color(0xFF6750A4),
                  tools: _dailyTools,
                ),
                const SizedBox(height: 24),
                // 极客区
                _buildZone(
                  context: bodyContext,
                  title: '极客区',
                  subtitle: '专业工具，硬核玩家',
                  accentColor: const Color(0xFFFF6D00),
                  tools: _geekTools,
                ),
              ],
            ),
          ),
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
