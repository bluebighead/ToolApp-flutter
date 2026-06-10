// 应用设置页面
// 提供多项开关/选项：
//   - 屏幕旋转、暗色模式（基础偏好）
//   - 视频保存位置（自定义 SAF 目录）
//   - 转换加速模式、批量并行数量、更换默认打开方式（v1.6.43+ 新增）
// 入口：首页左侧抽屉菜单 -> "设置"
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/app_storage.dart';
import '../utils/batch_convert_coordinator.dart';
import '../utils/codec_detector.dart';
import '../utils/convert_speed_settings.dart';
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

  // v1.6.58+ 优化：使用 StorageDetailInfo 替代分散的状态变量
  StorageDetailInfo? _storageInfo;
  bool _isCalculating = false;
  bool _userDataExpanded = false; // 用户数据详情展开状态

  // 编解码器检测结果（null 表示尚未检测）
  CodecCapability? _codecCapability;
  bool _isDetecting = false; // 是否正在检测中

  @override
  void initState() {
    super.initState();
    _reloadVideoSave();
    _loadStorageInfo();
    _loadCachedCodecCapability();
  }

  /// 加载缓存的编解码器检测结果
  Future<void> _loadCachedCodecCapability() async {
    final cached = await ConvertSpeedSettings.loadCodecCapability();
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _codecCapability = cached;
      });
      AppLogger.i('SettingsPage', '已加载缓存的编解码器检测结果');
    }
  }

  /// 从 SharedPreferences 加载视频保存设置
  Future<void> _reloadVideoSave() async {
    final s = await VideoSaveSettings.load();
    if (!mounted) return;
    setState(() {
      _videoSave = s;
    });
  }

  /// v1.6.58+ 优化：加载存储空间详细信息
  Future<void> _loadStorageInfo() async {
    if (_isCalculating) return;
    setState(() => _isCalculating = true);
    try {
      final info = await AppStorage.getStorageDetailInfo();
      if (!mounted) return;
      setState(() {
        _storageInfo = info;
        _isCalculating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCalculating = false);
      AppLogger.e('SettingsPage', '加载存储信息失败：$e');
    }
  }

  /// v1.6.55+ 新增：检查当前是否有转换任务正在进行
  ///
  /// 如果有任务在进行中，视频输出相关设置（加速模式、保存位置、并行数量等）
  /// 应该被锁定，防止转换过程中修改参数导致不可控的 bug
  bool get _isConverting {
    final coord = BatchConvertCoordinator.instance;
    final state = coord.state;
    return state == BatchConvertState.running;
  }

  /// v1.6.55+ 新增：构建"转换中，设置已锁定"的提示条
  Widget _buildLockedBanner() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '视频正在转换中，输出设置已锁定。转换完成后可修改。',
              style: TextStyle(
                fontSize: 12,
                color: Colors.orange.shade800,
              ),
            ),
          ),
        ],
      ),
    );
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
    final locked = _isConverting;
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
                    locked
                        ? Icons.lock
                        : (isCustom
                            ? Icons.folder_special_outlined
                            : Icons.folder_outlined),
                    color: locked ? Colors.grey : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '视频保存位置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: locked ? Colors.grey : null,
                    ),
                  ),
                ),
              ],
            ),
            if (locked) ...[
              const SizedBox(height: 8),
              _buildLockedBanner(),
            ],
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
                    // v1.6.55+ 修复：转换进行中禁止修改保存位置
                    onPressed: locked ? null : () => _onPickCustomDir(),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: Text(isCustom ? '重新选择' : '选择目录'),
                  ),
                ),
                if (isCustom) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: locked ? null : () => _onResetCustomDir(),
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

  // ------------------------------------------------------------------
  // v1.6.43+ 新增：转换加速模式卡片
  // ------------------------------------------------------------------

  /// 转换加速模式设置卡片
  Widget _buildConvertSpeedCard(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _isConverting;
    // 根据检测结果判断各选项是否可选
    // 未检测前，硬件编码和 ultrafast 均不可选；检测通过后才开放
    final hasDetected = _codecCapability != null;
    final hwSupported = _codecCapability?.supportsHardwareEncoding ?? false;
    final ultrafastSupported = _codecCapability?.supportsUltrafast ?? false;

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
                    locked ? Icons.lock : Icons.speed,
                    color: locked ? Colors.grey : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '转换加速模式',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: locked ? Colors.grey : null,
                    ),
                  ),
                ),
                // 检测按钮
                SizedBox(
                  height: 32,
                  child: OutlinedButton.icon(
                    onPressed: locked || _isDetecting ? null : _runCodecDetection,
                    icon: _isDetecting
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.primary,
                            ),
                          )
                        : Icon(
                            Icons.search,
                            size: 16,
                            color: hasDetected
                                ? (hwSupported && ultrafastSupported
                                    ? Colors.green
                                    : Colors.orange)
                                : null,
                          ),
                    label: Text(
                      _isDetecting
                          ? '检测中'
                          : (hasDetected ? '已检测' : '检测'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                    ),
                  ),
                ),
              ],
            ),
            if (locked) ...[
              const SizedBox(height: 8),
              _buildLockedBanner(),
            ],
            // 未检测时的提示
            if (!hasDetected && !locked) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '请先点击"检测"按钮，检测设备支持的加速模式',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // 检测结果提示：硬件编码不支持
            if (hasDetected && !hwSupported) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _codecCapability!.ffmpegHasMediacodec
                            ? 'FFmpeg 支持硬件编码，但当前设备无 H.264 硬件编码器'
                            : '当前设备不支持硬件编码',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // 检测结果提示：ultrafast 不支持
            if (hasDetected && !ultrafastSupported) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '当前 FFmpeg 未编译 libx264，不支持 ultrafast',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            FutureBuilder<ConvertSpeedMode>(
              future: ConvertSpeedSettings.load(),
              builder: (context, snapshot) {
                final mode = snapshot.data ?? ConvertSpeedMode.off;
                return Column(
                  children: ConvertSpeedMode.values.map((m) {
                    // 判断该选项是否可选
                    // 核心逻辑：硬件编码和 ultrafast 必须检测通过才可选
                    bool isDisabled = locked;
                    String? disabledHint;
                    if (!locked) {
                      if (m == ConvertSpeedMode.hardware) {
                        if (!hasDetected) {
                          isDisabled = true;
                          disabledHint = '未检测';
                        } else if (!hwSupported) {
                          isDisabled = true;
                          disabledHint = '设备不支持';
                        }
                      }
                      if (m == ConvertSpeedMode.ultrafast) {
                        if (!hasDetected) {
                          isDisabled = true;
                          disabledHint = '未检测';
                        } else if (!ultrafastSupported) {
                          isDisabled = true;
                          disabledHint = 'FFmpeg 不支持';
                        }
                      }
                    }
                    return RadioListTile<ConvertSpeedMode>(
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_speedModeLabel(m)),
                          if (disabledHint != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                disabledHint,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(_speedModeDesc(m)),
                      value: m,
                      groupValue: mode,
                      onChanged: isDisabled
                          ? null
                          : (v) {
                              if (v != null) {
                                ConvertSpeedSettings.save(v);
                                setState(() {});
                              }
                            },
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 执行编解码器能力检测
  Future<void> _runCodecDetection() async {
    setState(() => _isDetecting = true);
    try {
      final capability = await CodecDetector.detect();
      if (!mounted) return;
      setState(() {
        _codecCapability = capability;
        _isDetecting = false;
      });

      // 缓存检测结果到 SharedPreferences，下次打开设置页无需重新检测
      await ConvertSpeedSettings.saveCodecCapability(capability);

      // 如果当前选中的模式不再支持，自动回退到"关闭"
      if (capability != null) {
        final currentMode = await ConvertSpeedSettings.load();
        bool needFallback = false;
        if (currentMode == ConvertSpeedMode.hardware &&
            !capability.supportsHardwareEncoding) {
          needFallback = true;
        }
        if (currentMode == ConvertSpeedMode.ultrafast &&
            !capability.supportsUltrafast) {
          needFallback = true;
        }
        if (needFallback && mounted) {
          await ConvertSpeedSettings.save(ConvertSpeedMode.off);
          setState(() {});
        }
      }

      // 检测完成后弹出结果提示框
      if (mounted && capability != null) {
        _showDetectionResultDialog(capability);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDetecting = false);
      AppLogger.e('SettingsPage', '编解码器检测失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检测失败：$e')),
        );
      }
    }
  }

  /// 显示检测结果提示框
  void _showDetectionResultDialog(CodecCapability capability) {
    // 构建检测结果内容
    final List<Widget> items = [];

    // 硬件编码检测结果
    items.add(_buildDetectionItem(
      icon: Icons.memory,
      title: '硬件编码（h264_mediacodec）',
      supported: capability.supportsHardwareEncoding,
      detail: capability.supportsHardwareEncoding
          ? '设备支持 H.264 硬件编码，可使用硬件加速模式'
          : (capability.ffmpegHasMediacodec
              ? 'FFmpeg 已编译 mediacodec，但设备无 H.264 硬件编码器'
              : '当前设备不支持硬件编码'),
    ));

    // ultrafast 检测结果
    items.add(_buildDetectionItem(
      icon: Icons.bolt,
      title: 'Ultrafast 预设（libx264）',
      supported: capability.supportsUltrafast,
      detail: capability.supportsUltrafast
          ? 'FFmpeg 已编译 libx264，可使用 ultrafast 预设'
          : '当前 FFmpeg 未编译 libx264，不支持 ultrafast',
    ));

    // 芯片信息区域
    if (capability.cpuInfo.isNotEmpty) {
      items.add(const Divider(height: 24, thickness: 0.5));
      items.add(Row(
        children: [
          const Icon(Icons.developer_board, size: 18, color: Colors.grey),
          const SizedBox(width: 6),
          Text('芯片信息', style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey.shade700,
          )),
        ],
      ));
      items.add(const SizedBox(height: 6));
      // 按优先级排序显示芯片信息
      final orderedKeys = [
        'SoC制造商', 'SoC型号', '设备制造商', '设备型号',
        'CPU架构', 'CPU核心数', '逻辑核心数',
        'CPU硬件名称', 'CPU核心型号',
        '最大频率', '最小频率', '硬件平台',
      ];
      for (final key in orderedKeys) {
        final value = capability.cpuInfo[key];
        if (value != null && value != '未知' && value.isNotEmpty) {
          items.add(_buildCpuInfoRow(key, value));
        }
      }
      // 显示剩余未在排序列表中的信息
      for (final entry in capability.cpuInfo.entries) {
        if (!orderedKeys.contains(entry.key) &&
            entry.value != '未知' &&
            entry.value.isNotEmpty) {
          items.add(_buildCpuInfoRow(entry.key, entry.value));
        }
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              capability.supportsHardwareEncoding &&
                      capability.supportsUltrafast
                  ? Icons.check_circle
                  : Icons.info,
              color: capability.supportsHardwareEncoding &&
                      capability.supportsUltrafast
                  ? Colors.green
                  : Colors.orange,
              size: 24,
            ),
            const SizedBox(width: 8),
            const Text('检测结果', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: items,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 构建芯片信息行
  Widget _buildCpuInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            )),
          ),
          Expanded(
            child: Text(value, style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w500,
            )),
          ),
        ],
      ),
    );
  }

  /// 构建单个检测项
  Widget _buildDetectionItem({
    required IconData icon,
    required String title,
    required bool supported,
    required String detail,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20,
              color: supported ? Colors.green : Colors.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: supported
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        supported ? '可用' : '不可用',
                        style: TextStyle(
                          fontSize: 10,
                          color: supported ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(detail, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _speedModeLabel(ConvertSpeedMode mode) {
    switch (mode) {
      case ConvertSpeedMode.off:
        return '关闭（默认）';
      case ConvertSpeedMode.hardware:
        return '硬件编码';
      case ConvertSpeedMode.ultrafast:
        return 'ultrafast';
    }
  }

  String _speedModeDesc(ConvertSpeedMode mode) {
    switch (mode) {
      case ConvertSpeedMode.off:
        return '使用 veryfast preset + 软件编码，画质好速度适中';
      case ConvertSpeedMode.hardware:
        return '使用硬件编码，速度最快但画质略低';
      case ConvertSpeedMode.ultrafast:
        return '使用 ultrafast preset，速度快但文件体积更大';
    }
  }

  // ------------------------------------------------------------------
  // v1.6.43+ 新增：批量并行数量卡片
  // ------------------------------------------------------------------

  /// 批量并行数量设置卡片
  Widget _buildBatchParallelCard(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _isConverting;
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
                    locked ? Icons.lock : Icons.layers,
                    color: locked ? Colors.grey : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '批量并行数量',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: locked ? Colors.grey : null,
                    ),
                  ),
                ),
              ],
            ),
            if (locked) ...[
              const SizedBox(height: 8),
              _buildLockedBanner(),
            ],
            const SizedBox(height: 10),
            FutureBuilder<int>(
              future: BatchParallelSettings.load(),
              builder: (context, snapshot) {
                final count = snapshot.data ?? 2;
                return TextField(
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(text: '$count'),
                  enabled: !locked,
                  decoration: InputDecoration(
                    labelText: '并行数量（1-5）',
                    border: const OutlineInputBorder(),
                    // v1.6.55+ 修复：转换进行中禁止修改并行数量
                    disabledBorder: const OutlineInputBorder(),
                  ),
                  onChanged: locked
                      ? null
                      : (v) {
                          final n = int.tryParse(v);
                          if (n != null && n >= 1 && n <= 5) {
                            BatchParallelSettings.save(n);
                          }
                        },
                );
              },
            ),
            const SizedBox(height: 6),
            Text(
              '批量转换时同时进行的任务数量，越多越快但可能卡顿（默认 2）',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // v1.6.56+ 新增：存储空间管理卡片
  // ------------------------------------------------------------------

  /// 存储空间管理卡片
  /// v1.6.58+ 优化：显示详细分类、用户数据可展开、软件整体体积
  Widget _buildStorageCard(BuildContext context) {
    final theme = Theme.of(context);
    final info = _storageInfo;
    final isLoading = _isCalculating || info == null;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
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
                    Icons.storage,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '存储空间管理',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
                // 刷新按钮
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '刷新',
                  onPressed: _loadStorageInfo,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 存储占用详情
            if (isLoading)
              const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ))
            else ...[
              // 软件整体体积
              _buildStorageRow(
                icon: Icons.apps,
                label: '软件整体体积',
                size: info.overallSize,
                color: theme.colorScheme.primary,
                badge: 'APK + 数据 + 缓存',
              ),
              const SizedBox(height: 4),
              // 整体体积细分条
              Padding(
                padding: const EdgeInsets.only(left: 28, right: 4),
                child: _buildSizeBar(info),
              ),
              const Divider(height: 24),

              // 用户数据（可展开）
              _buildExpandableStorageRow(
                icon: Icons.folder,
                label: '用户数据',
                size: info.totalDataSize,
                color: Colors.blue,
                expanded: _userDataExpanded,
                onTap: () => setState(() => _userDataExpanded = !_userDataExpanded),
              ),
              // 用户数据详情（展开时显示）
              if (_userDataExpanded) ...[
                const SizedBox(height: 4),
                _buildSubStorageRow(
                  icon: Icons.video_file,
                  label: '视频输出文件',
                  size: info.videosSize,
                  color: Colors.purple,
                  description: '转换后保存的视频文件',
                ),
                _buildSubStorageRow(
                  icon: Icons.content_copy,
                  label: 'M3U8 复制内容',
                  size: info.m3u8CopySize,
                  color: Colors.indigo,
                  description: '转换前复制的 M3U8 源文件及分片',
                ),
                _buildSubStorageRow(
                  icon: Icons.save_outlined,
                  label: '断点续转状态',
                  size: info.resumeStateSize,
                  color: Colors.cyan,
                  description: '用于恢复中断转换的进度文件',
                ),
                _buildSubStorageRow(
                  icon: Icons.description,
                  label: '日志文件',
                  size: info.logsSize,
                  color: Colors.teal,
                  description: '调试日志导出文件',
                ),
                if (info.otherDataSize > 0)
                  _buildSubStorageRow(
                    icon: Icons.help_outline,
                    label: '其他数据',
                    size: info.otherDataSize,
                    color: Colors.grey,
                    description: '其他业务数据文件',
                  ),
              ],
              const SizedBox(height: 8),

              // 缓存
              _buildStorageRow(
                icon: Icons.cached,
                label: '缓存',
                size: info.cacheSize,
                color: Colors.orange,
              ),
              const SizedBox(height: 8),

              // App 本体
              _buildStorageRow(
                icon: Icons.android,
                label: 'App 本体',
                size: info.apkSize,
                color: Colors.green,
                badge: 'APK 安装包',
              ),
              const SizedBox(height: 16),

              // 操作按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _onClearCache,
                      icon: const Icon(Icons.cleaning_services, size: 18),
                      label: const Text('清理缓存'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _onClearJunkData,
                      icon: const Icon(Icons.delete_sweep, size: 18),
                      label: const Text('清理用户数据'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '清理用户数据会删除视频输出、日志和缓存文件，但不会影响软件设置和配置。',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 存储行：图标 + 标签 + 大小（带可选 badge）
  Widget _buildStorageRow({
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    String? badge,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(label, style: const TextStyle(fontSize: 14)),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ],
          ),
        ),
        Text(
          AppStorage.formatBytes(size),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: size > 100 * 1024 * 1024 // 超过 100MB 用红色警示
                ? Colors.red.shade700
                : Colors.black87,
          ),
        ),
      ],
    );
  }

  /// 可展开的存储行：点击可展开/折叠子项
  Widget _buildExpandableStorageRow({
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 14)),
            ),
            Text(
              AppStorage.formatBytes(size),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: size > 100 * 1024 * 1024
                    ? Colors.red.shade700
                    : Colors.black87,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: Colors.grey.shade600,
            ),
          ],
        ),
      ),
    );
  }

  /// 用户数据子项行：缩进显示，带描述
  Widget _buildSubStorageRow({
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 28),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                Text(
                  description,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Text(
            AppStorage.formatBytes(size),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: size > 100 * 1024 * 1024
                  ? Colors.red.shade700
                  : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  /// 整体体积细分条：按 APK / 用户数据 / 缓存 的比例着色
  Widget _buildSizeBar(StorageDetailInfo info) {
    final total = info.overallSize;
    if (total <= 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                _sizeBarSegment(info.apkSize, total, Colors.green),
                _sizeBarSegment(info.totalDataSize, total, Colors.blue),
                _sizeBarSegment(info.cacheSize, total, Colors.orange),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _sizeBarLegend(Colors.green, 'APK'),
            const SizedBox(width: 12),
            _sizeBarLegend(Colors.blue, '用户数据'),
            const SizedBox(width: 12),
            _sizeBarLegend(Colors.orange, '缓存'),
          ],
        ),
      ],
    );
  }

  /// 细分条中的一段
  Widget _sizeBarSegment(int size, int total, Color color) {
    if (size <= 0 || total <= 0) return const SizedBox.shrink();
    final ratio = (size / total).clamp(0.0, 1.0);
    if (ratio < 0.01) return const SizedBox.shrink(); // 太小不显示
    return Expanded(
      flex: (ratio * 100).round().clamp(1, 100),
      child: Container(color: color),
    );
  }

  /// 细分条图例
  Widget _sizeBarLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  /// 清理缓存
  Future<void> _onClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: Text(
          '当前缓存占用 ${AppStorage.formatBytes(_storageInfo?.cacheSize ?? 0)}，'
          '确认清理吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final cleaned = await AppStorage.clearCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清理缓存 ${AppStorage.formatBytes(cleaned)}')),
      );
      await _loadStorageInfo();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理缓存失败：$e')),
      );
    }
  }

  /// 清理用户数据（视频输出、日志、缓存，保留配置）
  Future<void> _onClearJunkData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理用户数据'),
        content: const Text(
          '将删除视频输出文件、日志文件和缓存，但不会影响软件设置和配置参数。\n\n'
          '此操作不可撤销，确认清理吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final cleaned = await AppStorage.clearJunkData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清理 ${AppStorage.formatBytes(cleaned)} 数据')),
      );
      await _loadStorageInfo();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理数据失败：$e')),
      );
    }
  }

  // ------------------------------------------------------------------
  // v1.6.43+ 新增：更换默认打开方式卡片
  // ------------------------------------------------------------------

  /// 更换默认打开方式设置卡片
  Widget _buildOpenWithCard(BuildContext context) {
    final theme = Theme.of(context);
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
                  child: Icon(Icons.open_in_new, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '更换默认打开方式',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 标注提示
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, size: 18, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '此设置仅改变本 App 内视频的打开方式，与其他工具的打开方式设置无关',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.amber.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () async {
                // v1.6.55+ 修复：使用原生 Intent.createChooser 弹出播放器选择器
                // 之前用 OpenFilex.open('/dev/null') 在 Android 上无效
                try {
                  const channel = MethodChannel('com.example.toolapp/storage');
                  await channel.invokeMethod<bool>('showVideoPlayerChooser');
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('未找到可播放视频的应用：$e')),
                  );
                }
              },
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('选择打开方式'),
            ),
            const SizedBox(height: 6),
            Text(
              '点击后弹出系统选择器，每次打开视频时都会弹出选择',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // v1.23.0+ 新增：账号与同步相关卡片
  // ============================================================

  /// 服务器地址设置卡片
  Widget _buildServerUrlCard(BuildContext context) {
    final theme = Theme.of(context);
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
                    Icons.dns_outlined,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '服务器地址',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.link, size: 16, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      appSettings.serverUrl,
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '修改后需重启 App 生效',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _showEditServerUrlDialog(context),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('修改服务器地址'),
                  ),
                ),
                const SizedBox(width: 8),
                // 重置为默认地址按钮
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await appSettings.setServerUrl(AppSettings.defaultServerUrl);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已重置为默认地址: ${AppSettings.defaultServerUrl}')),
                      );
                    }
                  },
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('重置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 同步数据卡片
  Widget _buildSyncCard(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = AuthService.instance.isLoggedIn;
    final isGuest = AuthService.instance.isGuestMode;
    final isSyncing = SyncService.instance.isSyncing;

    // 游客模式下显示提示
    if (isGuest) {
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
                      color: Colors.orange.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.cloud_off_outlined, color: Colors.orange),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '数据同步',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '游客模式下数据仅保存在本地，登录账号后可同步到服务器',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => _onGuestLogin(),
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('登录账号'),
                ),
              ),
            ],
          ),
        ),
      );
    }

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
                    Icons.cloud_sync_outlined,
                    color: isLoggedIn
                        ? theme.colorScheme.primary
                        : Colors.grey,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '数据同步',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isLoggedIn
                  ? '将本地数据上传到服务器（全量覆盖）'
                  : '请先登录后再同步数据',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: (!isLoggedIn || isSyncing)
                    ? null
                    : () => _onSyncData(),
                icon: isSyncing
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : const Icon(Icons.upload_outlined, size: 18),
                label: Text(isSyncing ? '同步中...' : '立即同步'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 登出按钮卡片
  Widget _buildLogoutCard(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = AuthService.instance.isLoggedIn;
    final isGuest = AuthService.instance.isGuestMode;

    // 游客模式下显示登录入口
    if (isGuest) {
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
                      color: Colors.orange.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_outline, color: Colors.orange),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '游客模式',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                        Text(
                          '数据仅保存在本地，登录后可同步到服务器',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _onGuestLogin(),
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('登录账号'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!isLoggedIn) {
      return Card(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.person_off_outlined, color: Colors.grey),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '未登录',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      '登录后可同步数据到服务器',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

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
                    Icons.person_outline,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AuthService.instance.userEmail ?? '已登录',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      Text(
                        '登录状态：已登录',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _onLogout(),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('退出登录'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 修改服务器地址弹窗
  void _showEditServerUrlDialog(BuildContext context) {
    final controller = TextEditingController(text: appSettings.serverUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改服务器地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '服务器 URL',
            hintText: 'http://192.168.x.x:8000',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                await appSettings.setServerUrl(url);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('服务器地址已更新，请重启 App 生效')),
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 执行同步
  Future<void> _onSyncData() async {
    final result = await SyncService.instance.syncAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.summary)),
    );
  }

  /// 执行登出
  Future<void> _onLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退出登录'),
        content: const Text('退出后本地数据仍保留，但无法同步到服务器。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AuthService.instance.signOut();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已退出登录')),
        );
      }
    }
  }

  /// 游客模式下点击"登录账号"
  /// 退出游客模式，回到登录页
  Future<void> _onGuestLogin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登录账号'),
        content: const Text('登录后，本地数据将自动同步到服务器。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AuthService.instance.exitGuestMode();
      // AuthWrapper 会自动检测状态切换到登录页
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
          listenable: Listenable.merge([appSettings, AuthService.instance]),
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
                  const SizedBox(height: 8),
                  // v1.6.43+ 新增：4. 转换加速模式
                  _buildConvertSpeedCard(context),
                  const SizedBox(height: 8),
                  // v1.6.43+ 新增：5. 批量并行数量
                  _buildBatchParallelCard(context),
                  const SizedBox(height: 8),
                  // v1.6.43+ 新增：6. 更换默认打开方式
                  _buildOpenWithCard(context),
                  const SizedBox(height: 8),
                  // v1.6.56+ 新增：7. 存储空间管理
                  _buildStorageCard(context),
                  const SizedBox(height: 20),
                  // 分组标题：账号与同步
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    child: Text(
                      '账号与同步',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  // 8. 服务器地址
                  _buildServerUrlCard(context),
                  const SizedBox(height: 8),
                  // 9. 同步数据
                  _buildSyncCard(context),
                  const SizedBox(height: 8),
                  // 10. 登出按钮
                  _buildLogoutCard(context),
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
