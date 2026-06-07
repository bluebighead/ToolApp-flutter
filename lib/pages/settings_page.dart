// 应用设置页面
// 提供多项开关/选项：
//   - 屏幕旋转、暗色模式（基础偏好）
//   - 视频保存位置（自定义 SAF 目录）
// 入口：首页左侧抽屉菜单 -> "设置"
import 'package:flutter/material.dart';

import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/saf_directory_helper.dart';
import '../utils/video_save_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 当前视频保存设置（页面打开时重读一次）
  VideoSaveSettingsSnapshot _videoSave = (
    mode: VideoSaveMode.defaultSandbox,
    customSafTreeUri: null,
    customDisplayName: null,
  );

  @override
  void initState() {
    super.initState();
    _reloadVideoSave();
  }

  /// 从 SharedPreferences 加载视频保存设置
  Future<void> _reloadVideoSave() async {
    final s = await VideoSaveSettings.load();
    if (!mounted) return;
    setState(() {
      _videoSave = s;
    });
  }

  // 单个设置项的卡片样式
  // icon: 设置项图标；title: 标题；subtitle: 描述；value: 当前值；onChanged: 切换回调
  Widget _settingTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        // 左侧图标
        secondary: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: theme.colorScheme.primary),
        ),
        // 标题
        title: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        // 副标题：说明该设置项的作用
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        // 当前值
        value: value,
        // 切换回调
        onChanged: onChanged,
      ),
    );
  }

  /// 视频保存位置卡片：展示当前模式 + 选择 / 重置按钮
  Widget _buildVideoSaveCard(BuildContext context) {
    final theme = Theme.of(context);
    final isCustom = _videoSave.mode == VideoSaveMode.customSaf &&
        _videoSave.customSafTreeUri != null;
    final displayName = isCustom
        ? (_videoSave.customDisplayName ?? '已选自定义目录')
        : 'App 私有目录（ToolApp/videos/converted/）';
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isCustom
                        ? Icons.folder_special_outlined
                        : Icons.folder_outlined,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '视频保存位置',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 当前路径展示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    isCustom ? Icons.folder_open : Icons.lock_outline,
                    size: 16,
                    color: Colors.grey.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isCustom
                  ? '视频转换完成后会自动复制一份到该目录。'
                  : '视频只保存在 App 私有目录，卸载 App 时会一并删除。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _onPickCustomDir(),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: Text(isCustom ? '重新选择' : '选择目录'),
                  ),
                ),
                if (isCustom) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => _onResetCustomDir(),
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('恢复默认'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 用户点击"选择目录"：调起 SAF 选目录
  Future<void> _onPickCustomDir() async {
    AppLogger.i('SettingsPage', '点击选择自定义视频保存目录');
    try {
      // 引导 SAF 选目录时优先定位到 Download（用户最常用的目录）
      final treeUri = await SafDirectoryHelper.pickDirectory(
        initialUri: SafInitialUris.primaryDownload.contentUri,
      );
      if (treeUri == null || treeUri.isEmpty) {
        AppLogger.i('SettingsPage', '用户取消选择目录');
        return;
      }
      AppLogger.i('SettingsPage', '已选目录：$treeUri');
      // 解析目录显示名（用 URI 末段做兜底展示）
      final displayName = _extractDirDisplayName(treeUri);
      await VideoSaveSettings.save(
        mode: VideoSaveMode.customSaf,
        customSafTreeUri: treeUri,
        customDisplayName: displayName,
      );
      await _reloadVideoSave();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已设置自定义目录：$displayName')),
      );
    } catch (e, st) {
      AppLogger.e('SettingsPage', '选择自定义目录失败：$e', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择失败：$e')),
      );
    }
  }

  /// 恢复默认（清空自定义）
  Future<void> _onResetCustomDir() async {
    AppLogger.i('SettingsPage', '恢复默认视频保存目录');
    await VideoSaveSettings.clearCustom();
    await _reloadVideoSave();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认：App 私有目录')),
    );
  }

  /// 从 SAF tree URI 中尽量提取友好的目录名
  /// 例如：
  ///   content://.../tree/primary%3ADownload/child%3AToolApp
  ///   → "Download/ToolApp"
  String _extractDirDisplayName(String treeUri) {
    try {
      // 截取 /tree/ 之后的内容，URL decode 后用 / 拼接
      final idx = treeUri.indexOf('/tree/');
      if (idx < 0) return treeUri;
      final tail = treeUri.substring(idx + '/tree/'.length);
      // 把 %3A 还原为 :
      final decoded = Uri.decodeComponent(tail);
      return decoded.replaceAll(':', '/');
    } catch (_) {
      return treeUri;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 进入设置页面时记录日志
    AppLogger.i('SettingsPage', '进入设置页面');
    // 通过 ListenableBuilder 监听设置变化
    // 当用户在页面内切换开关时，无需 setState 即可刷新 UI
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appSettings,
          builder: (context, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 分组标题：通用
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Text(
                      '通用',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  // 1. 屏幕旋转开关
                  // 关闭时仅允许竖屏；开启后允许横屏/竖屏自由切换
                  _settingTile(
                    context,
                    icon: Icons.screen_rotation,
                    title: '屏幕旋转',
                    subtitle: '开启后允许应用随屏幕方向旋转（默认关闭：仅竖屏）',
                    value: appSettings.allowRotation,
                    onChanged: (v) {
                      AppLogger.i('SettingsPage', '切换屏幕旋转 -> $v');
                      appSettings.setAllowRotation(v);
                    },
                  ),
                  const SizedBox(height: 8),
                  // 2. 暗色模式开关
                  // 开启后整个 App 切换为暗色主题；关闭则使用亮色主题
                  _settingTile(
                    context,
                    icon: Icons.dark_mode_outlined,
                    title: '暗色模式',
                    subtitle: '开启后整个 App 切换为暗色主题（默认关闭：亮色主题）',
                    value: appSettings.darkMode,
                    onChanged: (v) {
                      AppLogger.i('SettingsPage', '切换暗色模式 -> $v');
                      appSettings.setDarkMode(v);
                    },
                  ),
                  const SizedBox(height: 20),
                  // 分组标题：视频转换
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Text(
                      '视频转换',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  // 3. 视频保存位置
                  _buildVideoSaveCard(context),
                  const SizedBox(height: 16),
                  // 提示信息
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '设置项会自动保存到本地，下次打开 App 时仍然生效。\n'
                            '视频转换运行中也可切换到后台，进度会显示在系统通知栏。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// 全局可访问的 AppSettings 实例（单例）
// 方便在任意位置通过 appSettings 访问/修改设置
final AppSettings appSettings = AppSettings();
