// 视频格式转换页面
// 彻底重构版（v1.5.0+）
//
// 上一版的实现问题：
//   1. 自行写了一大段 M3U8 预处理逻辑（重写 segment 文件名、补扩展名、
//      手工复制 segments 到工作目录等），过度工程，且在多种边界情况下
//      会失败（路径错误、字符编码、segment 命名规则不一致等）
//   2. 依赖 ffmpeg_kit_flutter_new 社区分支，稳定性不如 arthenica 官方原版
//   3. 只支持本地 M3U8 文件，缺少最常见的"网络 URL"入口
//
// 本版的成熟方案：
//   - 使用 arthenica 官方 ffmpeg_kit_flutter（Flutter 生态最成熟的 FFmpeg 绑定）
//   - 完全信任 FFmpeg 自带的 HLS demuxer：直接把 M3U8/视频 URL 喂给 FFmpeg，
//     segment 下载、拼接、解密（AES-128）全部由 FFmpeg 在原生层完成
//   - 两种输入模式：本地文件 + 网络 URL
//   - 多种输出格式：MP4 / MKV / MOV
//   - 多种质量档位：原画质（-c copy 极速转封装）/ 高画质 / 标准 / 高压缩
//   - 实时进度回调：基于 FFmpeg statistics
//   - 错误展示 + 完整日志查看
//   - 输出文件操作：打开 / 分享
//   - 自定义保存路径：用户在"设置"中可指定 SAF 目录（如 Download/Movies）
//   - 后台模式：转换中离开页面弹窗询问（继续前台 / 后台运行 / 取消）；
//               后台运行期间在系统通知栏展示实时进度 + 剩余时间，
//               转换完成切换为"完成"通知

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import '../utils/app_storage.dart';
import '../utils/batch_convert_coordinator.dart';
import '../utils/convert_coordinator.dart';
import '../utils/convert_resume_state.dart';
import '../utils/ffmpeg_service.dart';
import '../utils/convert_speed_settings.dart';
import '../utils/saf_directory_helper.dart';
import '../utils/video_save_settings.dart';
import 'batch_convert_page.dart';
import 'convert_history_page.dart';
import 'settings_page.dart';

/// 输入源类型
enum _InputMode {
  /// 本地文件（设备上的 M3U8、mp4、mov、mkv、avi、flv、ts 等）
  file,

  /// 网络 URL（http/https 形式的 M3U8 或视频直链）
  url,
}

/// 转换状态机
enum _ConvertStatus {
  /// 空闲：等待用户选择输入 + 配置参数 + 点击开始
  idle,

  /// 转换中：禁用页面交互
  running,

  /// 已暂停（v1.6.21+ 新增）：可继续，进度保留
  paused,

  /// 完成：可以打开/分享输出文件，或开始下一次转换
  done,
}

/// 离开页面对话框的用户选择
enum _LeaveAction {
  /// 留在前台：啥也不做
  stay,

  /// 后台运行：标记 _backgroundMode，pop 页面
  background,

  /// 取消转换：调用 _ffmpeg.cancel()，并 pop 页面
  cancel,
}

/// 单个 M3U8 的导入目录准备结果
///
/// [dir] 准备好的目录（缓存命中则指向缓存目录，未命中则指向新建的临时目录）
/// [cacheHit] 是否命中导入缓存
/// [copiedCount] 实际复制了多少个文件（缓存命中时为 0）
class _M3u8ImportPrepResult {
  final Directory dir;
  final bool cacheHit;
  final int copiedCount;

  const _M3u8ImportPrepResult({
    required this.dir,
    required this.cacheHit,
    required this.copiedCount,
  });
}

/// 导入缓存条目：单个 M3U8 文件对应的 import 目录
///
/// [treeUri] 来源 SAF tree URI（content://...）
/// [m3u8Rel] M3U8 相对路径（如 "测试视频.m3u8"）
/// [dir] 复制完成后的临时目录（包含 M3U8 + segments）
class _ImportCacheEntry {
  final String treeUri;
  final String m3u8Rel;
  final Directory dir;

  const _ImportCacheEntry({
    required this.treeUri,
    required this.m3u8Rel,
    required this.dir,
  });
}

/// 视频格式转换页
class VideoConvertPage extends StatefulWidget {
  const VideoConvertPage({super.key});

  @override
  State<VideoConvertPage> createState() => _VideoConvertPageState();
}

/// v1.6.53+ 新增：M3U8 文件夹选择持久化
///
/// 记住用户选择的 M3U8 所在目录（SAF treeUri），
/// 重启 App 或版本更新后不需要重新选择。
/// 只要用户没有手动更换目录，就一直记住。
class M3u8FolderPrefs {
  static const _kKeyTreeUri = 'm3u8_source_tree_uri';

  /// 保存用户选择的 M3U8 目录 treeUri
  static Future<void> save(String treeUri) async {
    final prefs = AppSettings.prefs!;
    await prefs.setString(_kKeyTreeUri, treeUri);
    AppLogger.i('M3u8FolderPrefs', '已保存 M3U8 目录：$treeUri');
  }

  /// 读取上次保存的 M3U8 目录 treeUri，不存在返回 null
  static Future<String?> load() async {
    final prefs = AppSettings.prefs!;
    final uri = prefs.getString(_kKeyTreeUri);
    if (uri != null && uri.isNotEmpty) {
      AppLogger.i('M3u8FolderPrefs', '恢复 M3U8 目录：$uri');
    }
    return (uri != null && uri.isNotEmpty) ? uri : null;
  }

  /// 清除保存的 M3U8 目录（用户手动更换目录时调用）
  static Future<void> clear() async {
    final prefs = AppSettings.prefs!;
    await prefs.remove(_kKeyTreeUri);
    AppLogger.i('M3u8FolderPrefs', '已清除 M3U8 目录记录');
  }
}

class _VideoConvertPageState extends State<VideoConvertPage> {
  /// 当前输入模式
  _InputMode _inputMode = _InputMode.file;

  /// 输入源显示名（如文件名、域名）
  String? _sourceName;

  /// 输入源传递给 FFmpeg 的值：
  ///   - 文件模式：本地绝对路径
  ///   - URL 模式：用户输入的 http(s):// 链接
  String? _sourceValue;

  /// 输入源大小（字节，仅文件模式有效）
  int? _sourceSize;

  /// URL 输入框的文本控制器
  final TextEditingController _urlController = TextEditingController();

  /// 选定的输出格式
  VideoFormat _format = VideoFormat.mp4;

  /// 选定的质量档位
  VideoQuality _quality = VideoQuality.standard;

  /// 转换状态
  _ConvertStatus _status = _ConvertStatus.idle;

  /// v1.6.28+ 新增（bug12 需求配套）：
  ///   用户要求"在开始转换时（running）以及暂停时（paused），
  ///   不能修改输出格式、输出质量、保存位置，只有重新开始才能修改"。
  ///   之前 _status == _ConvertStatus.running 是唯一判定，会让 paused
  ///   状态下这些控件还活着，用户能改但改了也没用（实际不生效，体验割裂）。
  ///   改成两个状态都视为"任务进行中"，所有相关控件都 disabled。
  bool get _isTaskInProgress =>
      _status == _ConvertStatus.running || _status == _ConvertStatus.paused;

  /// 进度 0.0~1.0
  double _progress = 0.0;

  /// 是否拿到了总时长（决定进度环是确定值还是不确定动画）
  bool _hasDuration = false;

  /// 实时码率显示
  String _bitrateDisplay = '';

  /// 已处理时长显示
  String _timeDisplay = '';

  /// 预估剩余时间（秒），null=未计算/不可用
  int? _etaSeconds;

  /// 本次转换的开始时间（用于日志/调试；历史记录由 Coordinator 写）
  DateTime? _convertStartTime;

  /// 源时长（毫秒）
  int? _sourceDurationMs;

  /// 源总码率（kbps，含音视频）
  /// 用于在输出质量卡片里预估各档位的输出体积
  int? _sourceBitrateKbps;

  /// 输出文件路径
  String? _outputPath;

  /// 输出文件大小
  int? _outputSize;

  /// 通过"选择 M3U8 所在目录"导入的临时目录（转换完成后清理）
  Directory? _importedTempDir;

  /// v1.6.22+ 新增：M3U8 来源 treeUri
  ///
  /// 当输入源是通过"添加 M3U8 源 -> 选择目录"流程导入的 M3U8 时，
  /// 记录该目录的 SAF treeUri，用于：
  ///   - 后续在输入源卡片中显示"列表"按钮，让用户快捷切换同目录下的其它 M3U8
  ///   - 切换时不需要重新授权目录，直接复用 treeUri
  ///
  /// 只在 M3U8 导入流程中赋值，切换到其它输入类型（URL / 本地视频）时清空。
  String? _m3u8SourceTreeUri;

  /// v1.6.22+ 新增：同目录下所有 M3U8 文件列表
  ///
  /// 只在以下条件**同时**满足时才有值：
  ///   1) 输入源是 M3U8（_m3u8SourceTreeUri 非空）
  ///   2) 该目录下 .m3u8 文件数量 > 1（=1 时不显示列表按钮）
  ///
  /// 用于在输入源卡片中显示"列表"按钮，弹出的列表展示这一组兄弟 M3U8。
  /// 切换其中任意一个都会触发同目录下的重新 import（缓存命中则秒切）。
  List<String>? _m3u8Siblings;

  /// 当前视频保存设置（每次页面进入时从 SharedPreferences 重读一次；
  /// 设置页改完返回后，didChangeDependencies 会触发重读）
  VideoSaveSettingsSnapshot _saveSettings = (
    mode: VideoSaveMode.defaultSandbox,
    customSafTreeUri: null,
    customDisplayName: null,
  );

  /// 用户在"离开页面"对话框中选了"后台运行"时为 true
  /// 此时页面 UI 仍然存活，但允许返回/切到其他页面；
  /// 转换进度同时通过 ConvertCoordinator 推送到系统通知栏
  /// (v1.6.18 留作扩展位；v1.6.19+ 后该字段仅作为 UI 提示位，
  ///  真正的后台运行由 ConvertCoordinator 持续跑 FFmpeg 实现)
  bool _backgroundMode = false;

  /// v1.6.29+ 新增（bug13 修复配套）：
  ///   标记"用户已请求取消转换，正在等待 FFmpeg 原生层收尾"。
  ///   旧版没有这个标志，用户点完取消按钮后：
  ///     - await ConvertCoordinator.instance.cancel() 会一直阻塞 5~30s
  ///     - 这期间用户看到按钮没反应，会反复点（甚至以为 App 卡死）
  ///   新版 Coordinator.cancel() 改为非阻塞（不 await FFmpegService.cancel()），
  ///   立即返回。这里配套加 _cancelling 标志：
  ///     - 用户点取消 → _cancelling = true，按钮立即变成"取消中..."且禁用
  ///     - 状态机收到 FFmpeg session 回调 → _emitState(cancelled)
  ///       Coordinator.cancelled 状态会触发 _syncFromCoordinatorSnapshot，
  ///       那里 _cancelling 应该被复位为 false（见 _syncFromCoordinatorSnapshot）
  ///   这样大体积文件取消时用户有即时视觉反馈，体感流畅。
  bool _cancelling = false;

  /// v1.6.29+ 新增（bug13 修复配套）：
  ///   同 _cancelling，标记"用户已请求暂停转换，正在等待 FFmpeg 收尾"。
  ///   暂停时也要走非阻塞流程（v1.6.29+ 把 pause() 也改成了 fire-and-forget），
  ///   所以也需要一个标志让按钮立即变"暂停中..."且禁用，避免用户重复点。
  bool _pausing = false;

  /// v1.6.29+ 新增（bug15 修复配套）：
  ///   标记"用户已请求继续转换（resume），正在等待 FFmpeg 启动"。
  ///   resume() 调用后 Coordinator 会立刻 _emitState(running)，
  ///   状态机会切到 running，UI 进入"准备中..."分支。
  ///   但大体积文件时 FFmpeg 启动 + input seek 可能要 5~10 秒才出第一帧，
  ///   这期间进度环停在"准备中..."会让用户以为卡死。
  ///   加 _resuming 标志后，UI 可以用"正在恢复..."替代"准备中..."，
  ///   让用户清楚知道系统在干活。
  ///   标志在第一次收到 _hasDuration=true 的进度事件时复位（见
  ///   _onCoordinatorEvent / ConvertProgressEvent 分支）。
  bool _resuming = false;

  /// v1.6.30+ 新增（bug16 修复配套）：
  ///   标记"FFmpeg 会话已创建，正在启动到出第一帧之间"。
  ///   跟 _resuming 的区别：
  ///     - _resuming：用户视角"点了继续转换"
  ///     - _ffmpegStarting：FFmpeg 视角"session 已建好，主线程在跑"
  ///   流程：
  ///     - 用户点继续 → _resuming=true
  ///     - Coordinator 发初始进度 → UI 收到（_resuming 不复位）
  ///     - FFmpegKit.executeWithArgumentsAsync 返回 session
  ///       → Coordinator 收到 onSessionStarting 回调
  ///       → 推 ConvertSessionStartingEvent(phase="starting-resume")
  ///       → UI 收到，_ffmpegStarting=true，按钮文字从
  ///         "正在恢复转换..." 切到 "FFmpeg 启动中..."
  ///     - 第一帧 statistics 到达 → ConvertProgressEvent(hasDuration=true)
  ///       → UI 收到，_resuming=false（已存在的逻辑）
  ///       → _ffmpegStarting=false（新增的复位逻辑）
  ///   没这个标志：用户会卡在"正在恢复转换..." 5~10 秒，
  ///   不知道系统在干啥。
  bool _ffmpegSessionStarting = false;

  /// 导入缓存：`treeUri + NUL + m3u8Rel` -> 缓存条目
  ///
  /// key 格式：`'$treeUri\u0000$m3u8Rel'`，用 NUL (U+0000) 做分隔符
  ///
  /// 为什么不直接用 Record 或自定义类做 key？
  ///   - Dart `Map` 的 key 需要实现 `==` 和 `hashCode`
  ///   - String + NUL 简单可靠，NUL 不会出现在合法 SAF URI 或文件名里
  ///
  /// 为什么按 (treeUri, m3u8Rel) 双键缓存（v1.6.11+ 重构）？
  ///   - 同一根目录下有多个 M3U8 时互不干扰
  ///   - 切到另一个 M3U8 不需要清掉当前 M3U8 的缓存
  ///   - 切到另一个根目录时通过 `_evictCachesForOtherTrees` 清理旧 root
  final Map<String, _ImportCacheEntry> _importCache = {};

  /// 错误信息
  String? _errorMessage;

  /// 完整 FFmpeg 日志（失败时用户可点击查看）
  String? _lastErrorLogs;

  /// Coordinator 事件订阅句柄
  ///
  /// 重要：dispose() 时**不**取消 FFmpeg 任务本身，只取消这个订阅。
  /// Coordinator 是全局单例，FFmpeg 由它独占持有，Page State 销毁不影响任务执行。
  StreamSubscription<ConvertEvent>? _coordSub;

  @override
  void initState() {
    super.initState();
    AppLogger.i('VideoConvertPage', '进入视频格式转换页 v1.6.19+（Coordinator 重构版）');
    // 注册 FFmpeg 全局日志回调（写入 AppLogger）
    FFmpegService.registerGlobalCallbacks();

    // 订阅 Coordinator 事件流，把 FFmpeg 进度/状态同步到 UI
    _coordSub = ConvertCoordinator.instance.subscribe(_onCoordinatorEvent);

    // v1.6.22+ 修复（bug1）：
    //   退出页面再重新进入时，如果 Coordinator 上还有任务在跑（running），
    //   必须立即把 Coordinator 的状态/进度/输入源信息投影到本地 UI，
    //   否则按钮会停留在"开始转换"的禁用态（因为 _canConvert 看到
    //   Coordinator 正在跑就判 false），且输入源/格式/质量等信息也会全部清空。
    //
    //   这里先调一次 _syncFromCoordinatorSnapshot(eventDriven: false)，
    //   后续再走 _tryBootstrapPausedTask 走"暂停任务从磁盘恢复"流程。
    //   两条路径互不冲突：running/paused 走前者；纯 paused（无运行时内存状态）
    //   走后者补充。
    _syncFromCoordinatorSnapshot();

    // v1.6.21+ 新增：检查磁盘上是否有上次未完成的暂停任务
    //   如果有，立即把状态机恢复为 paused（_syncFromCoordinatorSnapshot 会处理 UI 投影）
    unawaited(_tryBootstrapPausedTask());

    // v1.6.53+ 新增：自动恢复上次选择的 M3U8 目录
    //   如果用户之前选择过 M3U8 目录且没有手动更换，重启 App 后自动恢复
    unawaited(_tryRestoreM3u8Folder());
  }

  /// v1.6.21+ 新增：从磁盘加载上次未完成的暂停任务
  ///
  /// 调用时机：进入视频转换页时
  /// 行为：
  ///   - 如果磁盘上有暂停状态文件，Coordinator 自动切到 paused 状态
  ///   - 给用户一个 SnackBar 提示："发现上次未完成的转换"
  ///   - 用户可点"继续转换"或"取消恢复"（取消恢复 = 彻底清掉状态）
  Future<void> _tryBootstrapPausedTask() async {
    try {
      final resume = await ConvertCoordinator.instance.bootstrapFromDisk();
      if (resume == null) return;
      // 触发一次 UI 投影
      _syncFromCoordinatorSnapshot(eventDriven: true);
      if (!mounted) return;
      _showSnack(
        '发现上次未完成的转换（已编 ${(resume.encodedTimeMs / 1000).toStringAsFixed(1)} 秒），'
        '可继续转换',
      );
    } catch (e) {
      AppLogger.w('VideoConvertPage', '加载暂停任务失败：$e', e);
    }
  }

  /// v1.6.53+ 新增：自动恢复上次选择的 M3U8 目录
  ///
  /// 如果用户之前选择过 M3U8 目录（treeUri 已持久化到 SharedPreferences），
  /// 且当前没有正在进行的转换任务，则自动恢复该目录的 M3U8 列表。
  /// 这样用户重启 App 或版本更新后不需要重新选择目录。
  Future<void> _tryRestoreM3u8Folder() async {
    // 如果当前有任务在进行中，不恢复
    if (_isTaskInProgress) return;
    // 如果已经有输入源了，不覆盖
    if (_sourceValue != null && _sourceValue!.isNotEmpty) return;

    try {
      final savedTreeUri = await M3u8FolderPrefs.load();
      if (savedTreeUri == null || savedTreeUri.isEmpty) return;

      // 验证该 SAF 目录是否仍然可访问
      final m3u8List = await SafDirectoryHelper.listM3u8InDir(savedTreeUri);
      if (m3u8List.isEmpty) {
        AppLogger.i('VideoConvertPage', '上次保存的 M3U8 目录已无 .m3u8 文件，清除记录');
        await M3u8FolderPrefs.clear();
        return;
      }

      // 恢复 treeUri 和兄弟列表
      _m3u8SourceTreeUri = savedTreeUri;
      _m3u8Siblings = m3u8List.length > 1 ? List<String>.from(m3u8List) : null;
      AppLogger.i('VideoConvertPage',
          '自动恢复 M3U8 目录：$savedTreeUri，${m3u8List.length} 个文件');

      if (mounted) setState(() {});
    } catch (e) {
      AppLogger.w('VideoConvertPage', '恢复 M3U8 目录失败：$e');
      // 恢复失败时清除记录，避免下次继续尝试
      await M3u8FolderPrefs.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 从设置页返回时会触发本回调，
    // 重新读取"自定义保存路径"等设置，确保 UI 与最新偏好一致
    _reloadSaveSettings();
  }

  /// 把 Coordinator 当前的状态投影到本地 UI 字段
  ///
  /// 触发时机：
  ///   1) initState 末尾（如果进来时任务已经在跑，恢复 UI）
  ///   2) Coordinator 状态变化事件里（带 _eventDriven 标记）
  ///
  /// v1.6.22+ 修复（bug1）：
  ///   退出页面再重新进入时，需要把 Coordinator 里 `_config` 持有的
  ///   输入源信息（路径/URL、名称、模式、格式、质量）也恢复出来，
  ///   这样按钮区域会显示"暂停/取消"，输入源卡片也保持原来的信息。
  void _syncFromCoordinatorSnapshot({bool eventDriven = false}) {
    final coord = ConvertCoordinator.instance;
    if (coord.state == ConvertState.idle) {
      // 没有任何任务时，本地字段保持不变（避免重置正在填写的输入）
      return;
    }
    if (!mounted) return;
    setState(() {
      // 投影 Coordinator 持有的输出信息（done / failed 时）
      _outputPath = coord.outputPath;
      _outputSize = coord.outputSize;
      _sourceDurationMs = coord.sourceDurationMs;
      _errorMessage = coord.errorMessage;
      _lastErrorLogs = coord.lastErrorLogs;
      // 投影当前进度
      _progress = coord.progress.value;
      _hasDuration = coord.progress.hasDuration;
      _bitrateDisplay = coord.progress.bitrate;
      _timeDisplay = coord.progress.time;
      _etaSeconds = coord.progress.etaSeconds;
      // v1.6.22+ 修复（bug1）：
      //   恢复输入源信息（仅在本地字段为空时填，避免覆盖用户切换过的输入）
      final cfg = coord.currentConfig;
      if (cfg != null) {
        if (_sourceValue == null || _sourceValue!.isEmpty) {
          _inputMode = cfg.isNetwork ? _InputMode.url : _InputMode.file;
          _sourceName = cfg.sourceName;
          _sourceValue = cfg.input;
          // M3U8 复制目录来自 Coordinator（任务正在用，不能在 State 重建时清）
          if (cfg.importedTempDir != null) {
            _importedTempDir = cfg.importedTempDir;
          }
        }
        // 格式 / 质量：始终用 Coordinator 的，跟随当前任务的配置
        _format = cfg.format;
        _quality = cfg.quality;
        // 保存设置：跟随 Coordinator 的（用户去设置页改过不会回写到 Coordinator，
        // 这里只在本地空时填，避免覆盖"已经按 Coordinator 配置跑过"的设置）
        if (_saveSettings.mode != cfg.saveSettings.mode ||
            _saveSettings.customSafTreeUri != cfg.saveSettings.customSafTreeUri ||
            _saveSettings.customDisplayName != cfg.saveSettings.customDisplayName) {
          _saveSettings = cfg.saveSettings;
        }
      }
      // 映射状态
      switch (coord.state) {
        case ConvertState.running:
          _status = _ConvertStatus.running;
          _backgroundMode = false;
          break;
        case ConvertState.paused:
          // v1.6.21+ 新增：保留已编码的进度值，UI 提示"已暂停"
          _status = _ConvertStatus.paused;
          _backgroundMode = false;
          // v1.6.29+ bug13 配套：状态机从 running 切到 paused 时，
          //   说明 FFmpeg 已经收尾完成，_pausing 标志位使命结束，复位。
          //   复位时不需要单独弹 Snack（_onCoordinatorEvent 的 paused 分支会弹）。
          _pausing = false;
          // v1.6.36+ 修复（bug21 配套）：
          //   状态机从 running 切到 paused 时，也复位 _resuming 和 _ffmpegSessionStarting
          //   标志位，避免下次续转时 UI 一直显示"恢复中..."或"FFmpeg 启动中..."。
          _resuming = false;
          _ffmpegSessionStarting = false;
          break;
        case ConvertState.done:
          _status = _ConvertStatus.done;
          _progress = 1.0;
          _hasDuration = true;
          _etaSeconds = null;
          _backgroundMode = false;
          break;
        case ConvertState.failed:
          _status = _ConvertStatus.idle;
          _backgroundMode = false;
          break;
        case ConvertState.cancelled:
          // v1.6.31+ 修复（bug4 第三次升级）：
          //   v1.6.22+ 第一次：取消时清空输入源卡片（防"No such file or directory"）
          //   v1.6.30+ 第二次：取消时保留 _inputMode/_sourceValue/_sourceName 等
          //                    用户态数据，但清掉 _importedTempDir/_m3u8SourceTreeUri/_m3u8Siblings
          //   v1.6.31+ 第三次：用户再次反馈"列表按钮和列表内容都消失了，体验差"。
          //                    这次彻底保留输入源卡片的**所有**数据：
          //                      - _inputMode / _sourceValue / _sourceName / _sourceSize
          //                        / _sourceDurationMs / _bitrateDisplay / _timeDisplay
          //                        （用户手动选/输入的，下次点"开始转换"还能复用）
          //                      - _m3u8SourceTreeUri / _m3u8Siblings
          //                        （M3U8 列表按钮 + 列表内容，用户反馈必须保留）
          //                      - _importedTempDir
          //                        （指向被 Coordinator 删的 tempDir，引用失效但留
          //                          着不影响显示；如果用户从列表重新选 .m3u8，
          //                          _pickM3u8Folder 会重新创建并赋值）
          //                    关键点：如果用户用的是"本地 M3U8 文件"模式
          //                    （_inputMode=file 且 _sourceValue 指向 .m3u8），
          //                    点了"开始转换"后会重新走 M3U8Normalizer 规范化，
          //                    **自动**用 fresh tempDir，不需要用户再点 M3U8 列表按钮
          //                    清空触发条件：用户**主动**调 _pickM3u8Folder() 重新
          //                    选 M3U8 文件夹时，_evictCachesForOtherTrees() 会删
          //                    旧 cache + 重新扫描填充 _m3u8Siblings；
          //                    或者用户主动清空输入源（暂未提供此 UI）
          //   对"暂停"无影响：暂停走 paused 分支，不进这里
          _status = _ConvertStatus.idle;
          _backgroundMode = false;
          // v1.6.31+ 第三次升级：什么都不清！只重置输出状态。
          //   _importedTempDir 留着（指向已删的 tempDir，无害）；
          //   _m3u8SourceTreeUri / _m3u8Siblings 留着（列表按钮 + 列表内容）；
          //   _inputMode / _sourceValue / _sourceName / _sourceSize 留着（用户输入）。
          // 重置输出状态
          _resetOutputState();
          // v1.6.29+ bug13 配套：状态机切到 cancelled 时，FFmpeg 已经收尾完毕，
          //   取消流程走完，_cancelling 标志位使命结束，复位。
          _cancelling = false;
          break;
        case ConvertState.idle:
          break;
      }
    });
    if (eventDriven) {
      AppLogger.i('VideoConvertPage',
          'Coordinator 事件投影：state=${coord.state}, outputPath=${coord.outputPath}');
    } else {
      AppLogger.i('VideoConvertPage',
          '从 Coordinator 快照恢复：state=${coord.state}, outputPath=${coord.outputPath}');
    }
  }

  /// Coordinator 事件回调
  ///
  /// 重要：不在这里 setState 一律调用 _syncFromCoordinatorSnapshot
  /// 即可：内部读 coord.progress / coord.outputPath 等都是最新值。
  void _onCoordinatorEvent(ConvertEvent event) {
    if (event is ConvertProgressEvent) {
      if (!mounted) return;
      setState(() {
        _progress = event.progress.value;
        _hasDuration = event.progress.hasDuration;
        _bitrateDisplay = event.progress.bitrate;
        _timeDisplay = event.progress.time;
        _etaSeconds = event.progress.etaSeconds;
        // v1.6.29+ 修复（bug15 配套）：
        //   第一次收到 _hasDuration=true 的进度事件，说明 FFmpeg 已经出第一帧，
        //   "正在恢复..."的提示可以撤了，进度环开始显示真实进度。
        // v1.6.36+ 修复（bug22 配套）：
        //   续转时不再传 onSessionStarting 回调，UI 不会进入"FFmpeg 启动中"状态。
        //   _resuming 只在收到 hasDuration=true 的进度事件时才复位，
        //   确保"正在恢复转换..."一直显示到 FFmpeg 真正出第一帧。
        if (_resuming && event.progress.hasDuration) {
          _resuming = false;
        }
        // v1.6.30+ 修复（bug16 配套）：
        //   第一帧 statistics 到达同时也意味着 FFmpeg 启动阶段结束，
        //   复位 _ffmpegSessionStarting 标志，让 UI 从 "FFmpeg 启动中..."
        //   切回 "正在转换..." 文字。
        if (event.progress.hasDuration) {
          _ffmpegSessionStarting = false;
        }
      });
    } else if (event is ConvertSessionStartingEvent) {
      // v1.6.30+ 修复（bug16 配套）：
      //   收到 FFmpeg 会话启动事件，UI 切换文字为 "FFmpeg 启动中..."。
      //   此时进度条已经在 resumeProgressBase（如 30%），用户能看到
      //   "进度没动但系统在干活" 的状态。
      if (!mounted) return;
      setState(() {
        _ffmpegSessionStarting = true;
      });
    } else if (event is ConvertStateEvent) {
      // done / failed / cancelled 状态时 Coordinator 会更新 _outputPath /
      // _outputSize / _errorMessage / _lastErrorLogs 字段，
      // 把它们一起投影到 UI
      _syncFromCoordinatorSnapshot(eventDriven: true);

      // 状态切换时给用户一个 SnackBar 提示（仅 running -> 终态时弹一次）
      if (!mounted) return;
      switch (event.state) {
        case ConvertState.done:
          if (event.outputPath != null) {
            final name = p.basename(event.outputPath!);
            // 自定义目录模式：通知文案不同
            final isCustom = _saveSettings.mode == VideoSaveMode.customSaf &&
                _saveSettings.customSafTreeUri != null;
            _showSnack(isCustom
                ? '转换完成，已保存到自定义目录：$name'
                : '转换完成：$name');
          }
          break;
        case ConvertState.failed:
          _showSnack('转换失败：${event.errorMessage ?? "未知错误"}');
          break;
        case ConvertState.cancelled:
          _showSnack('已取消转换');
          break;
        case ConvertState.paused:
          // v1.6.21+ 新增：提示用户已暂停，可继续
          _showSnack('已暂停转换，随时可继续');
          break;
        case ConvertState.running:
        case ConvertState.idle:
          break;
      }
    }
  }

  /// 重新从 SharedPreferences 加载视频保存设置
  /// 只在 mode/uri/displayName 与当前不同时才 setState，避免多余刷新
  Future<void> _reloadSaveSettings() async {
    try {
      final s = await VideoSaveSettings.load();
      final changed = s.mode != _saveSettings.mode ||
          s.customSafTreeUri != _saveSettings.customSafTreeUri ||
          s.customDisplayName != _saveSettings.customDisplayName;
      if (!changed) return;
      if (!mounted) return;
      setState(() {
        _saveSettings = s;
      });
      AppLogger.i(
        'VideoConvertPage',
        '已重载视频保存设置：mode=${s.mode}, uri=${s.customSafTreeUri}, name=${s.customDisplayName}',
      );
    } catch (e) {
      AppLogger.w('VideoConvertPage', '重载保存设置失败：$e', e);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    // 关键（v1.6.19+）：dispose() 时**不**取消 FFmpeg 任务
    //   - FFmpeg 任务由 ConvertCoordinator 全局单例持有
    //   - 这里只解除 UI 订阅，让 Coordinator 继续在后台跑
    //   - 重新进入页面时，initState 里的 _syncFromCoordinatorSnapshot 会恢复 UI
    _coordSub?.cancel();
    _coordSub = null;
    // v1.6.40+ 修复（问题3配套）：
    //   清理 M3U8 缓存目录。被 Coordinator 选中的那个由 Coordinator 自行清理，
    //   这里清掉的是缓存里"用户没选中的备选 m3u8"。
    //   如果 Coordinator 没在运行，也清理 _importedTempDir（当前选中的目录）。
    _evictAllCaches();
    if (!ConvertCoordinator.instance.isRunning) {
      _cleanupImportedTempDir();
    }
    super.dispose();
  }

  // --------------------------------------------------------------------
  // 输入选择
  // --------------------------------------------------------------------

  /// 选择本地视频/M3U8 文件
  /// 支持的扩展名涵盖常见视频格式 + M3U8
  Future<void> _pickLocalFile() async {
    AppLogger.i('VideoConvertPage', '点击选择本地视频文件');
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          // 视频容器
          'mp4', 'm4v', 'mov', 'mkv', 'avi', 'flv', 'wmv', 'webm', 'ts', 'm2ts',
          '3gp', 'f4v', 'rmvb', 'rm', 'asf',
          // HLS 播放列表
          'm3u8', 'm3u',
        ],
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        AppLogger.i('VideoConvertPage', '用户取消选择文件');
        return;
      }
      final file = result.files.single;
      final path = file.path;
      if (path == null) {
        _showSnack('无法读取所选文件的路径');
        return;
      }
      int size = 0;
      try {
        size = await File(path).length();
      } catch (_) {}
      AppLogger.i('VideoConvertPage', '已选文件：${file.name}（$size bytes）');
      // v1.6.40+ 修复（问题3配套）：用户切换输入源时，清理旧的 M3U8 临时目录
      await _cleanupImportedTempDir();
      setState(() {
        _inputMode = _InputMode.file;
        _sourceName = file.name;
        _sourceValue = path;
        _sourceSize = size;
        // v1.6.22+ 修复：本地文件入口下清掉 M3U8 列表按钮的关联数据
        //   之前选 M3U8 后切到本地文件，"列表"按钮会一直挂着但点了也找不到 treeUri
        _m3u8SourceTreeUri = null;
        _m3u8Siblings = null;
        // 切换输入源后清空旧的输出/错误信息
        _resetOutputState();
      });
      _showSnack('已选择：${file.name}');
      // 异步探测时长 + 码率（用于输出质量卡片预估体积）
      // 不 await：探测期间 UI 不阻塞，UI 探测完了会通过 setState 刷新
      unawaited(_probeSourceMeta(path));
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '选择文件失败', e, st);
      _showSnack('选择文件失败：$e');
    }
  }

  /// 选择 M3U8 所在的根目录（v1.6.11+ 先扫后选 + 精准复制）
  ///
  /// 适用场景：M3U8 + segments 在同一根目录下，file_picker 单文件模式只复制 M3U8，
  /// segments 会丢失，导致 FFmpeg 找不到片段。
  ///
  /// 流程（v1.6.11+ 重构版，避免一开始就把整棵 root 都复制过来）：
  ///  1. SAF 选根目录 -> treeUri（不复制任何东西）
  ///  2. 浅扫根目录的 .m3u8 文件（毫秒级）
  ///  3. 0 个 -> 报错；1 个 -> 直接用；2+ 个 -> 弹选择对话框（单选）
  ///  4. 缓存检查（key = treeUri + NUL + m3u8Rel）
  ///  5. 命中 -> 复用之前的 import 目录
  ///  6. 未命中 -> 清理其他 treeUri 的旧缓存 + 建临时目录 + 弹 loading +
  ///               复制 M3U8 + 启发式/解析 segments + 注册新缓存
  ///  7. 走原有"找 M3U8 + setState"流程
  Future<void> _pickM3u8Folder() async {
    AppLogger.i('VideoConvertPage', '点击选择 M3U8 所在根目录');
    try {
      final treeUri = await SafDirectoryHelper.pickDirectory();
      if (treeUri == null || treeUri.isEmpty) {
        AppLogger.i('VideoConvertPage', '用户取消选择目录');
        return;
      }

      // ========== 浅扫根目录的 .m3u8（不复制任何东西） ==========
      final m3u8List = await SafDirectoryHelper.listM3u8InDir(treeUri);
      AppLogger.i('VideoConvertPage', '扫到 ${m3u8List.length} 个 .m3u8：$m3u8List');

      if (m3u8List.isEmpty) {
        _showSnack('所选目录中没有 .m3u8 文件');
        return;
      }

      // ========== v1.6.53+ 持久化用户选择的 M3U8 目录 ==========
      await M3u8FolderPrefs.save(treeUri);

      // ========== v1.6.22+ 新增：记录 treeUri + 兄弟 M3U8 列表 ==========
      _m3u8SourceTreeUri = treeUri;
      _m3u8Siblings = m3u8List.length > 1 ? List<String>.from(m3u8List) : null;
      AppLogger.i('VideoConvertPage',
          '记录 M3U8 来源：treeUri=$treeUri，siblings=${_m3u8Siblings?.length ?? 0}');

      // ========== v1.6.53+ 优化：直接显示多选列表，一步到位 ==========
      if (m3u8List.length == 1) {
        // 只有一个文件，直接导入
        await _importM3u8FromTree(treeUri, m3u8List.first);
      } else {
        // 多个文件：直接弹出多选列表
        if (!mounted) return;
        final selected = <String>{};
        final result = await showDialog<List<String>>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: Text('选择 M3U8（共 ${m3u8List.length} 个）'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: m3u8List.map((rel) {
                    final isSelected = selected.contains(rel);
                    return CheckboxListTile(
                      title: Text(rel, overflow: TextOverflow.ellipsis),
                      value: isSelected,
                      onChanged: (v) {
                        setDialogState(() {
                          if (v == true) {
                            selected.add(rel);
                          } else {
                            selected.remove(rel);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                // 只选了1个：直接导入该文件
                if (selected.length == 1)
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, ['__SINGLE__', selected.first]),
                    child: const Text('导入'),
                  ),
                // 选了多个：批量转换
                if (selected.length > 1)
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, selected.toList()),
                    child: Text('批量转换（${selected.length} 个）'),
                  ),
              ],
            ),
          ),
        );

        if (result == null || result.isEmpty) return;

        // 单选导入
        if (result.length == 2 && result.first == '__SINGLE__') {
          await _importM3u8FromTree(treeUri, result.last);
          return;
        }

        // 多选批量转换
        if (result.length > 1) {
          _navigateToBatchConvert(result);
          return;
        }
      }
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '选择 M3U8 目录失败', e, st);
      _showSnack('选择目录失败：$e');
    }
  }

  /// v1.6.22+ 新增：在已授权的 SAF tree 下导入指定 M3U8
  ///
  /// 复用 _pickM3u8Folder 流程里的"准备 import 目录 → 找 M3U8 → 注册 UI"那一段，
  /// 让"列表"按钮（已经知道 treeUri）的快捷切换不需要重新走目录选择。
  ///
  /// 调用前必须保证：
  ///   - treeUri 是当前用户已授权过的目录（_m3u8SourceTreeUri 里的）
  ///   - 目标 pickedRel 也在该目录下
  ///
  /// 行为：
  ///   - 缓存命中：秒切（复用 _importCache）
  ///   - 缓存未命中：弹 loading + 复制 + 注册新缓存
  ///   - 复制完成后调用 _probeSourceMeta 探测时长 / 码率
  Future<void> _importM3u8FromTree(String treeUri, String pickedRel) async {
    AppLogger.i(
        'VideoConvertPage', '_importM3u8FromTree: $treeUri/$pickedRel');

    // v1.6.31+ 修复（bug17 配套，针对续转"No such file or directory"问题）：
    //   用户主动选 M3U8 文件夹时，意味着要换输入源了。
    //   之前如果存在 paused 状态的 resume（磁盘上还有 convert_resume_state.json），
    //   resume state 里的 input 和 importedTempDirPath 还指向**旧**的 tempDir。
    //   但 _evictCachesForOtherTrees() / _importM3u8FromTree() 流程会删掉
    //   旧 cache（旧的 m3u8_import_* 目录），结果 resume state 变成"野指针"：
    //     - 用户看不到"继续转换"按钮（UI 没刷新，但 disk state 还在）
    //     - 理论上不会进入 resume 流程
    //     - 但如果有别的代码路径触发 resume，就会报"No such file or directory"
    //   修复：选 M3U8 文件夹时主动清掉旧的 resume state。
    //   语义合理：用户换输入源 = 旧的"从中断点恢复"语义已经失效
    //   （输入源都不一样了），提示用户重新开始一次转换更直接。
    final hadResume = await ConvertResumeStore.instance.load();
    if (hadResume != null) {
      AppLogger.i('VideoConvertPage',
          '选 M3U8 文件夹触发清旧 resume state：'
          'encodedTimeMs=${hadResume.encodedTimeMs}ms');
      await ConvertResumeStore.instance.clear();
    }

    // ========== 准备 import 目录（缓存命中 / 未命中走不同分支） ==========
    final prep = await _prepareImportDirForM3u8(treeUri, pickedRel);
    if (prep == null) return;
    final Directory destDir = prep.dir;
    final bool cacheHit = prep.cacheHit;
    final int copied = prep.copiedCount;

    // ========== 找 M3U8、注册到 UI ==========
    final m3u8Path = p.join(destDir.path, pickedRel);
    AppLogger.i('VideoConvertPage', '最终 M3U8：$m3u8Path');

    // 关键自检：路径真的存在吗？找不到时回退到递归扫描
    final existsDirectly = await File(m3u8Path).exists();
    AppLogger.i('VideoConvertPage',
        'm3u8Path.exists() = $existsDirectly  (destDir=${destDir.path}, pickedRel=$pickedRel)');

    String actualM3u8Path = m3u8Path;
    if (!existsDirectly) {
      AppLogger.w('VideoConvertPage',
          '按 pickedRel 找不到 m3u8，递归扫描 destDir 找同名 M3U8 …');
      final found = await _findM3u8Recursive(destDir.path);
      if (found.isEmpty) {
        _showSnack('复制完成但在 $pickedRel 位置找不到 M3U8（$destDir）');
        return;
      }
      if (found.length == 1) {
        actualM3u8Path = found.first;
        AppLogger.i('VideoConvertPage', '回退匹配到唯一 M3U8：$actualM3u8Path');
      } else {
        if (!mounted) return;
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('找到多个同名 M3U8，请选择实际文件'),
            children: found
                .map(
                  (full) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, full),
                    child: Text(
                      p.relative(full, from: destDir.path),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
          ),
        );
        if (picked == null) return;
        actualM3u8Path = picked;
      }
    }

    // ⚠️ 缓存命中时需要先临时把 _importedTempDir 置空，
    // 否则 _resetOutputState 会把"上一次"指向同一个缓存目录的引用清掉，
    // 缓存目录直接被删，下次选同一个 M3U8 就缓存 miss 了
    if (cacheHit) {
      _importedTempDir = null;
    }
    // v1.6.22+ 修复（bug2）：
    //   之前 _sourceSize 只读 M3U8 文件自身大小（几 KB），
    //   整个 destDir 里真正大头是 segments（几百 MB ~ 几 GB），
    //   这导致后续"输出质量卡片"按 _sourceSize 估算各档位输出体积时严重偏小。
    //   正确做法：递归累加 destDir 所有文件总字节数（M3U8 + segments）。
    final int size = await _dirSizeRecursive(destDir);
    AppLogger.i('VideoConvertPage',
        'M3U8 导入目录总大小：${_formatSize(size)}（$size bytes，$copied 个文件）');
    // v1.6.40+ 修复（问题3配套）：用户切换 M3U8 输入源时，清理旧的临时目录
    await _cleanupImportedTempDir();
    setState(() {
      _inputMode = _InputMode.file;
      _sourceName = pickedRel;
      _sourceValue = actualM3u8Path;
      _sourceSize = size;
      _resetOutputState();
    });
    // 缓存命中：不注册 _importedTempDir（缓存自己管生命周期，dispose / 切目录时清）
    // 缓存未命中：注册新的临时目录（让旧目录被清，但新的保留）
    if (!cacheHit) {
      _importedTempDir = destDir;
    }
    _showSnack(cacheHit
        ? '已命中缓存：$pickedRel（跳过复制）'
        : '已导入：$pickedRel（共 $copied 个文件）');
    // 异步探测时长 + 码率（用于输出质量卡片预估体积）
    unawaited(_probeSourceMeta(actualM3u8Path));
  }

  /// v1.6.22+ 新增：弹出"同目录其它 M3U8"列表供用户快捷切换
  ///
  /// 由输入源卡片右侧的"列表"按钮触发。
  /// 仅在 _m3u8SourceTreeUri 非空 && _m3u8Siblings 非空（=至少 2 个兄弟）时调用。
  ///
  /// v1.6.53+ 优化：直接显示多选列表，一步到位，不再需要先单选再点"多选"按钮
  Future<void> _showM3u8SiblingsDialog() async {
    final treeUri = _m3u8SourceTreeUri;
    final siblings = _m3u8Siblings;
    if (treeUri == null ||
        treeUri.isEmpty ||
        siblings == null ||
        siblings.isEmpty) {
      _showSnack('当前输入源没有可切换的兄弟 M3U8');
      return;
    }
    final currentName = _sourceName;
    AppLogger.i('VideoConvertPage',
        '弹出 M3U8 兄弟列表：${siblings.length} 个，当前=$currentName');

    if (!mounted) return;

    // v1.6.53+ 优化：直接使用多选列表，默认选中当前文件
    final selected = <String>{?currentName};

    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('选择 M3U8（共 ${siblings.length} 个）'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: siblings.map((rel) {
                final isSelected = selected.contains(rel);
                final isCurrent = rel == currentName;
                return CheckboxListTile(
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          rel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrent)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '当前',
                            style: TextStyle(fontSize: 10, color: Colors.blue),
                          ),
                        ),
                    ],
                  ),
                  value: isSelected,
                  onChanged: (v) {
                    setDialogState(() {
                      if (v == true) {
                        selected.add(rel);
                      } else {
                        selected.remove(rel);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            // 只选了1个：切换到该文件
            if (selected.length == 1)
              FilledButton(
                onPressed: selected.first != currentName
                    ? () => Navigator.pop(ctx, ['__SINGLE__', selected.first])
                    : null,
                child: const Text('切换'),
              ),
            // 选了多个：批量转换
            if (selected.length > 1)
              FilledButton(
                onPressed: () => Navigator.pop(ctx, selected.toList()),
                child: Text('批量转换（${selected.length} 个）'),
              ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    // 单选切换
    if (result.length == 2 && result.first == '__SINGLE__') {
      final picked = result.last;
      if (picked == currentName) {
        _showSnack('已是当前 M3U8：$picked');
        return;
      }
      AppLogger.i('VideoConvertPage', '切换 M3U8：$currentName -> $picked');
      await _importM3u8FromTree(treeUri, picked);
      return;
    }

    // 多选批量转换
    if (result.length > 1) {
      _navigateToBatchConvert(result);
      return;
    }

    // 只选了当前文件且点了切换（不应该到这里，但兜底）
    if (result.length == 1 && result.first != currentName) {
      await _importM3u8FromTree(treeUri, result.first);
    }
  }

  /// v1.6.43+ 新增：跳转到批量转换页面
  ///
  /// 根据选中的 M3U8 文件列表构造 BatchConvertTask 并跳转
  /// 
  /// 关键修复：当用户从兄弟列表多选多个 M3U8 时，_importedTempDir 只包含
  /// 当前单个 M3U8 及其 segments，其他兄弟文件不在该目录中。
  /// 因此需要把所有选中的 M3U8 都复制到一个新的批量临时目录中。
  Future<void> _navigateToBatchConvert(List<String> selectedFiles) async {
    final format = _format;
    final quality = _quality;

    // 获取保存路径
    // v1.6.52+ 修复：无论 SAF 还是沙盒模式，FFmpeg 都先写入 App 私有目录
    // SAF 模式下后续由原生层将文件从私有目录复制到 SAF 自定义目录
    // 旧版 SAF 模式下 outputPath 为空字符串，导致 FFmpeg 写入当前工作目录
    final saveDir = await AppStorage.getSubDirectory(
      '${AppStorage.videosSubFolder}/converted',
    );

    // 如果是从 SAF treeUri 导入的 M3U8，需要把所有选中的文件复制到新的临时目录
    Directory? batchTempDir;
    if (_m3u8SourceTreeUri != null && _m3u8SourceTreeUri!.isNotEmpty) {
      batchTempDir = await _prepareBatchImportDir(selectedFiles);
      if (batchTempDir == null) {
        if (!mounted) return;
        _showSnack('准备批量转换文件失败');
        return;
      }
    }

    final tasks = <BatchConvertTask>[];
    for (int i = 0; i < selectedFiles.length; i++) {
      final rel = selectedFiles[i];
      // 输入路径：优先用批量临时目录中的文件
      final inputPath = batchTempDir != null
          ? '${batchTempDir.path}/$rel'
          : rel;

      // 输出文件名：原名_序号.扩展名
      final baseName = p.basenameWithoutExtension(rel);
      final outputName = '${baseName}_${i + 1}.${format.name}';
      final outputPath = '${saveDir.path}/$outputName';

      tasks.add(BatchConvertTask(
        inputPath: inputPath,
        sourceName: rel,
        outputPath: outputPath,
        index: i + 1,
      ));
    }

    // v1.6.46+ 修复：把任务保存到协调器，实现记录持久化
    BatchConvertCoordinator.instance.tasksList = tasks;

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatchConvertPage(
          tasks: tasks,
          format: format,
          quality: quality,
          saveSettings: _saveSettings,
        ),
      ),
    );
  }

  /// v1.6.43+ 新增：为批量转换准备临时目录
  ///
  /// 把所有选中的 M3U8 文件及其 segments 复制到一个新的临时目录中
  Future<Directory?> _prepareBatchImportDir(List<String> selectedFiles) async {
    final treeUri = _m3u8SourceTreeUri;
    if (treeUri == null || treeUri.isEmpty) return null;

    // v1.6.52+ 修复：使用 getApplicationCacheDirectory() 代替 Directory.systemTemp
    // 原因：Android 11+ 限制 FFmpeg 原生库访问 systemTemp 目录，
    //   导致 "No such file or directory" 错误。
    //   getApplicationCacheDirectory() 返回的 cache 目录 FFmpeg 可以正常访问。
    final cacheDir = await getApplicationCacheDirectory();
    final batchDir = await cacheDir.createTemp(
      'm3u8_batch_${DateTime.now().millisecondsSinceEpoch}_',
    );
    AppLogger.i('VideoConvertPage', '批量转换临时目录：${batchDir.path}');

    // 显示进度对话框
    if (!mounted) return null;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ImportProgressDialog(destDirPath: batchDir.path),
    );

    // v1.6.46+ 优化：并行复制所有选中的 M3U8 文件及其 segments
    // 使用 Future.wait 同时发起所有复制任务，而非串行逐个复制
    final copyFutures = <Future<int>>[];
    for (int i = 0; i < selectedFiles.length; i++) {
      final rel = selectedFiles[i];
      copyFutures.add(
        SafDirectoryHelper.copyM3u8WithSegments(
          treeUri: treeUri,
          destDir: batchDir.path,
          m3u8Rel: rel,
        ).then((copied) {
          AppLogger.i('VideoConvertPage', '已复制 $rel：$copied 个文件');
          return copied;
        }).catchError((e) {
          AppLogger.e('VideoConvertPage', '复制 $rel 失败：$e');
          return 0;
        }),
      );
    }

    // 等待所有复制任务完成
    final results = await Future.wait(copyFutures);
    final totalCopied = results.fold<int>(0, (sum, count) => sum + count);

    // 关闭进度对话框
    if (!mounted) return null;
    Navigator.of(context, rootNavigator: true).pop();

    if (totalCopied == 0) {
      AppLogger.e('VideoConvertPage', '批量复制失败：没有文件被复制');
      return null;
    }

    AppLogger.i('VideoConvertPage', '批量复制完成：共 $totalCopied 个文件');
    return batchDir;
  }

  /// 为单个 M3U8 准备 import 目录：缓存命中直接复用；缓存未命中则精准复制
  ///
  /// 与旧的 `_prepareImportDir`（v1.6.10，按 treeUri 缓存整棵树）的区别：
  ///   - 按 (treeUri, m3u8Rel) 缓存，同一 root 下不同 M3U8 互不干扰
  ///   - 只复制 1 个 M3U8 + 它的 segments（不复制整棵 root 树）
  ///
  /// 返回 null 表示 0 个文件（应该走 SnackBar 报错并提前返回）
  Future<_M3u8ImportPrepResult?> _prepareImportDirForM3u8(
    String treeUri,
    String m3u8Rel,
  ) async {
    // ========== 缓存检查 ==========
    final cached = await _findCache(treeUri, m3u8Rel);
    if (cached != null) {
      AppLogger.i('VideoConvertPage',
          '命中导入缓存：$treeUri/$m3u8Rel -> ${cached.dir.path}（跳过复制）');
      return _M3u8ImportPrepResult(
        dir: cached.dir,
        cacheHit: true,
        copiedCount: 0,
      );
    }

    // ========== 缓存未命中：清理其他 treeUri 的旧缓存 + 精准复制 ==========
    // 切到新 root 时，旧 root 的缓存从磁盘清掉
    await _evictCachesForOtherTrees(treeUri, deleteDirs: true);

    // v1.6.52+ 修复：使用 getApplicationCacheDirectory() 代替 Directory.systemTemp
    // 原因：Android 11+ 限制 FFmpeg 原生库访问 systemTemp 目录，
    //   导致 "No such file or directory" 错误。
    final cacheDir = await getApplicationCacheDirectory();
    final newDir = await cacheDir.createTemp(
      'm3u8_import_${DateTime.now().millisecondsSinceEpoch}_',
    );
    AppLogger.i('VideoConvertPage', '精准复制到：${newDir.path}');

    if (!mounted) return null;
    // 带"已复制 N 个文件…"实时计数的 loading 对话框
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ImportProgressDialog(destDirPath: newDir.path),
    );
    AppLogger.i('VideoConvertPage', '已显示进度对话框');

    // Kotlin 后台线程跑，Dart 这边 await 不阻塞 UI
    final copied = await SafDirectoryHelper.copyM3u8WithSegments(
      treeUri: treeUri,
      destDir: newDir.path,
      m3u8Rel: m3u8Rel,
    );
    AppLogger.i('VideoConvertPage', '复制完成，共 $copied 个文件');

    if (copied <= 0) {
      if (mounted) Navigator.of(context).pop();
      await newDir.delete(recursive: true);
      _showSnack('复制失败：M3U8 文件不存在或无法访问');
      return null;
    }

    // 关 loading
    if (mounted) Navigator.of(context).pop();

    // 注册新缓存
    _registerCache(treeUri, m3u8Rel, newDir);

    return _M3u8ImportPrepResult(
      dir: newDir,
      cacheHit: false,
      copiedCount: copied,
    );
  }

  /// 在 [root] 下递归找所有 .m3u8 / .M3U8 文件的绝对路径
  Future<List<String>> _findM3u8Recursive(String root) async {
    final results = <String>[];
    final dir = Directory(root);
    if (!await dir.exists()) return results;
    await for (final ent
        in dir.list(recursive: true, followLinks: false)) {
      if (ent is File) {
        final name = p.basename(ent.path);
        if (name.toLowerCase().endsWith('.m3u8')) {
          results.add(ent.path);
        }
      }
    }
    results.sort();
    return results;
  }

  /// 清理导入的临时目录
  Future<void> _cleanupImportedTempDir() async {
    final dir = _importedTempDir;
    if (dir == null) return;
    _importedTempDir = null;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        AppLogger.i('VideoConvertPage', '已清理导入临时目录：${dir.path}');
      }
    } catch (e) {
      AppLogger.w('VideoConvertPage', '清理导入临时目录失败：$e');
    }
  }

  /// 拼 cache key：`treeUri + NUL + m3u8Rel`
  ///
  /// 用 NUL (U+0000) 做分隔符的原因：
  ///   - 合法 SAF content URI 不会包含 NUL（会被 percent-encode 成 %00）
  ///   - 合法文件名（POSIX/Android）禁止 NUL
  ///   - 比 "|" 更稳：URI 里有大量 "/"，"|" 不会撞但 NUL 绝对安全
  String _makeCacheKey(String treeUri, String m3u8Rel) =>
      '$treeUri$m3u8Rel';

  /// 在缓存里找 (treeUri, m3u8Rel) 对应的目录
  ///
  /// 命中后还会检查磁盘目录是否还存在（外部可能清掉了 temp 目录）；
  /// 不存在则清掉缓存条目并返回 null（让调用方走重新复制流程）
  Future<_ImportCacheEntry?> _findCache(String treeUri, String m3u8Rel) async {
    final key = _makeCacheKey(treeUri, m3u8Rel);
    final entry = _importCache[key];
    if (entry == null) return null;
    if (!await entry.dir.exists()) {
      AppLogger.w('VideoConvertPage', '缓存目录已不存在，清掉条目：${entry.dir.path}');
      _importCache.remove(key);
      return null;
    }
    return entry;
  }

  /// 注册新的缓存条目
  void _registerCache(String treeUri, String m3u8Rel, Directory dir) {
    _importCache[_makeCacheKey(treeUri, m3u8Rel)] = _ImportCacheEntry(
      treeUri: treeUri,
      m3u8Rel: m3u8Rel,
      dir: dir,
    );
  }

  /// 清掉所有 `treeUri != currentTreeUri` 的缓存
  ///
  /// 场景：用户从根目录 A 切到根目录 B，A 的缓存从磁盘删（避免占空间）
  ///
  /// [deleteDirs] 为 true 时同时把磁盘目录删掉；false 只清字段引用
  Future<void> _evictCachesForOtherTrees(
    String currentTreeUri, {
    bool deleteDirs = true,
  }) async {
    final toRemove = <String>[];
    for (final entry in _importCache.entries) {
      if (entry.value.treeUri != currentTreeUri) {
        toRemove.add(entry.key);
        if (deleteDirs) {
          try {
            if (await entry.value.dir.exists()) {
              await entry.value.dir.delete(recursive: true);
              AppLogger.i(
                'VideoConvertPage',
                '清理旧 treeUri 缓存目录：${entry.value.dir.path}',
              );
            }
          } catch (e) {
            AppLogger.w('VideoConvertPage', '清理旧 treeUri 缓存目录失败：$e');
          }
        }
      }
    }
    for (final k in toRemove) {
      _importCache.remove(k);
    }
  }

  /// 清掉所有缓存
  ///
  /// 场景：页面 dispose / 强制刷新
  ///
  /// [deleteDirs] 为 true 时同时把磁盘目录全删掉
  Future<void> _evictAllCaches({bool deleteDirs = true}) async {
    if (deleteDirs) {
      for (final entry in _importCache.values) {
        try {
          if (await entry.dir.exists()) {
            await entry.dir.delete(recursive: true);
          }
        } catch (e) {
          AppLogger.w('VideoConvertPage', '清理缓存目录失败：$e');
        }
      }
    }
    _importCache.clear();
  }

  /// 确认 URL 输入
  /// 简单校验后保存
  Future<void> _confirmUrl() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) {
      _showSnack('请输入 URL');
      return;
    }
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      _showSnack('URL 必须以 http:// 或 https:// 开头');
      return;
    }
    // 提取域名作为显示名
    String displayName = raw;
    try {
      final uri = Uri.parse(raw);
      displayName = uri.host.isNotEmpty ? uri.host : raw;
      if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
        displayName = '${uri.host}/${uri.pathSegments.last}';
      }
    } catch (_) {}
    AppLogger.i('VideoConvertPage', '已输入 URL：$raw');
    // v1.6.40+ 修复（问题3配套）：用户切换输入源时，清理旧的 M3U8 临时目录
    await _cleanupImportedTempDir();
    setState(() {
      _inputMode = _InputMode.url;
      _sourceName = displayName;
      _sourceValue = raw;
      _sourceSize = null; // URL 模式无法预知大小
      // v1.6.22+ 修复：URL 入口下也清掉 M3U8 列表按钮的关联数据，
      // 跟切到本地视频文件入口时一致
      _m3u8SourceTreeUri = null;
      _m3u8Siblings = null;
      _resetOutputState();
    });
    _showSnack('已输入 URL：$displayName');
    // 异步探测时长 + 码率（用于输出质量卡片预估体积）
    unawaited(_probeSourceMeta(raw));
  }

  /// 递归累加目录下所有文件的字节数（M3U8 + segments）
  ///
  /// v1.6.22+ 修复（bug2）：
  ///   之前 M3U8 导入后 _sourceSize 只统计了 M3U8 文件自身（几 KB），
  ///   没把 segments 的体积算进去，导致后续"输出质量卡片"按"相对源体积"
  ///   估算各档位输出体积时严重偏小（按一个几 KB 的 M3U8 算）。
  ///   正确做法：递归累加整个 destDir（含 M3U8 + segments 目录）的总字节数。
  ///
  /// 实现要点：
  ///   - 使用 Directory.list(recursive: true) 一把递归遍历
  ///   - 单个文件读不到 length() 时忽略（极少数情况下文件被并发写 / 句柄独占）
  ///   - 累加过程中遇到异常吞掉（不影响主流程，size 给个保守值即可）
  Future<int> _dirSizeRecursive(Directory dir) async {
    var total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is File) {
          try {
            total += await ent.length();
          } catch (_) {
            // 复制中可能瞬时读不到 size，忽略
          }
        }
      }
    } catch (e) {
      AppLogger.w('VideoConvertPage', '递归统计目录大小失败：$e');
    }
    return total;
  }

  /// 异步探测源时长 + 码率
  /// 用于"输出质量卡片"中预估每个画质档位的输出体积
  ///
  /// 注意：
  ///   - 不抛错：探测失败保持 _sourceBitrateKbps=null，UI 走"未识别"占位
  ///   - 不 await：探测期间 UI 不阻塞；探测完成后通过 setState 刷新质量卡片
  ///   - 用 unawaited 包裹避免 lint 警告
  Future<void> _probeSourceMeta(String input) async {
    try {
      final svc = FFmpegService();
      // 并行探测：duration 和 bitrate 独立，缩短总等待时间
      final results = await Future.wait<int?>([
        svc.probeDurationMs(input),
        svc.probeBitrateKbps(input),
      ]);
      final ms = results[0];
      final kbps = results[1];
      // 期间用户可能已经切换了别的输入，避免覆盖
      if (_sourceValue != input) {
        AppLogger.i('VideoConvertPage',
            '_probeSourceMeta: 期间输入源已变更，丢弃结果');
        return;
      }
      if (!mounted) return;
      setState(() {
        _sourceDurationMs = ms;
        _sourceBitrateKbps = kbps;
      });
      AppLogger.i('VideoConvertPage',
          '源 meta 探测完成：duration=${ms}ms, bitrate=${kbps}kbps');
    } catch (e) {
      AppLogger.w('VideoConvertPage', '源 meta 探测失败：$e');
    }
  }

  /// 重置输出相关状态（切换输入源、切换模式时调用）
  void _resetOutputState() {
    // v1.6.40+ 修复（问题3）：不再自动清理临时目录。
    //   旧版在 _resetOutputState() 中清理 _importedTempDir，
    //   导致取消转换后临时目录被删，重新开始时需要重新复制 M3U8 文件。
    //   新版保留临时目录，只在以下场景清理：
    //     1) 用户主动更换输入源（_pickLocalFile / _importM3u8FromTree 中处理）
    //     2) 转换成功完成（Coordinator 的 finally 块）
    //     3) Page dispose 时
    // if (!ConvertCoordinator.instance.isRunning) {
    //   _cleanupImportedTempDir();
    // }
    _outputPath = null;
    _outputSize = null;
    _errorMessage = null;
    _lastErrorLogs = null;
    _progress = 0.0;
    _hasDuration = false;
    _bitrateDisplay = '';
    _timeDisplay = '';
    _etaSeconds = null;
    _sourceDurationMs = null;
    _sourceBitrateKbps = null;
    _convertStartTime = null;
    if (_status == _ConvertStatus.done) {
      _status = _ConvertStatus.idle;
    }
  }

  // --------------------------------------------------------------------
  // 转换主流程
  // --------------------------------------------------------------------

  /// 当前是否满足开始转换的条件
  ///
  /// v1.6.19+ 修改：判断条件改用 Coordinator 状态，
  /// 这样即使 Page State 已被销毁、新 State 刚创建，也能正确识别
  /// "Coordinator 上是否还有任务在跑"，避免重复启动。
  ///
  /// v1.6.21+ 修改：paused 状态时，_canConvert 视为 false
  /// （继续转换走 _resumeConvert，不走 _onConvertPressed）
  bool get _canConvert =>
      _sourceValue != null &&
      _sourceValue!.isNotEmpty &&
      _status != _ConvertStatus.running &&
      _status != _ConvertStatus.paused &&
      !ConvertCoordinator.instance.isRunning;

  /// 点击转换按钮
  Future<void> _onConvertPressed() async {
    if (_status == _ConvertStatus.running) return;
    if (!_canConvert) {
      if (_sourceValue == null || _sourceValue!.isEmpty) {
        _showSnack('请先选择文件或输入 URL');
      } else {
        _showSnack('当前状态不可转换');
      }
      return;
    }
    await _startConvert();
  }

  /// 启动转换
  ///
  /// v1.6.19+ 重构：把转换主流程交给 [ConvertCoordinator] 全局单例。
  /// 本方法只负责：
  ///   1) 计算输出文件路径
  ///   2) 复位本地 UI 字段
  ///   3) 记录开始时间/输入源到本地（仅用于日志/调试）
  ///   4) 构造 [ConvertTaskConfig] 调 `coordinator.start()`（fire-and-forget）
  /// 真正的 FFmpeg 执行、进度回调、SAF 复制、通知、历史全部在 Coordinator 里。
  /// 这样 Page State dispose 时不会中断 FFmpeg，重新进入页面时由订阅恢复 UI。
  Future<void> _startConvert() async {
    var input = _sourceValue;
    if (input == null || input.isEmpty) return;

    // v1.6.40+ 修复（BUG-H + 问题3）：
    //   取消转换后不再删除临时目录（v1.6.40 修复），所以源文件通常仍存在。
    //   但作为兜底，如果文件确实不存在（如系统清理了缓存），尝试自动重新导入。
    if (_inputMode != _InputMode.url) {
      final inputFile = File(input);
      if (!await inputFile.exists()) {
        AppLogger.w('VideoConvertPage', '输入源文件已不存在：$input');
        // 尝试自动重新导入 M3U8（如果来源是 SAF 目录）
        final treeUri = _m3u8SourceTreeUri;
        final sourceName = _sourceName;
        if (treeUri != null && treeUri.isNotEmpty && sourceName != null) {
          AppLogger.i('VideoConvertPage', '尝试自动重新导入 M3U8：$treeUri/$sourceName');
          try {
            await _importM3u8FromTree(treeUri, sourceName);
            // 重新导入后更新 input 引用
            input = _sourceValue;
            if (input == null || input.isEmpty) {
              _showSnack('重新导入 M3U8 失败，请重新选择输入源');
              return;
            }
            // 再次检查文件是否存在
            if (!await File(input).exists()) {
              _showSnack('重新导入后文件仍不存在，请重新选择输入源');
              return;
            }
            AppLogger.i('VideoConvertPage', '自动重新导入 M3U8 成功：$input');
          } catch (e) {
            AppLogger.w('VideoConvertPage', '自动重新导入 M3U8 失败：$e');
            setState(() {
              _sourceValue = null;
              _sourceName = null;
              _sourceSize = null;
              _importedTempDir = null;
              _status = _ConvertStatus.idle;
            });
            _showSnack('输入源文件已被清理且重新导入失败，请重新选择输入源');
            return;
          }
        } else {
          // 非 M3U8 来源或缺少 treeUri，无法自动恢复
          setState(() {
            _sourceValue = null;
            _sourceName = null;
            _sourceSize = null;
            _importedTempDir = null;
            _status = _ConvertStatus.idle;
          });
          _showSnack('输入源文件已被清理，请重新选择输入源');
          return;
        }
      }
    }

    // 构造输出文件路径：
    //   - 默认模式：App 私有目录 ToolApp/videos/converted/output_<ts>.<ext>
    //   - 自定义模式：仍然先在 App 私有目录生成（FFmpeg 写入 SAF 兼容差），
    //     生成成功后再由 Coordinator 通过原生层 writeFileToSafTree 复制到 SAF 自定义目录
    String outPath;
    try {
      final tmpDir = await AppStorage.getSubDirectory(
        '${AppStorage.videosSubFolder}/converted',
      );
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = _formatExtension(_format);
      outPath = '${tmpDir.path}/output_$ts.$ext';
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '获取输出目录失败', e, st);
      setState(() {
        _status = _ConvertStatus.idle;
        _errorMessage = '获取输出目录失败：$e';
      });
      _showSnack('获取输出目录失败：$e');
      return;
    }

    // 复位本地 UI 字段
    setState(() {
      _status = _ConvertStatus.running;
      _progress = 0.0;
      _hasDuration = false;
      _bitrateDisplay = '';
      _timeDisplay = '';
      _etaSeconds = null;
      _outputPath = null;
      _outputSize = null;
      _errorMessage = null;
      _lastErrorLogs = null;
      _backgroundMode = false;
      // 记录开始时间（仅日志/调试用；历史记录由 Coordinator 写）
      _convertStartTime = DateTime.now();
    });

    // 把临时目录引用转给 Coordinator，任务结束由 Coordinator 清理
    // （注意：_importedTempDir 可能是 null，如本地文件 / URL 输入时）
    final tempDir = _importedTempDir;

    final sourceName = _sourceName ?? input;

    // 构造任务配置
    final config = ConvertTaskConfig(
      input: input,
      outputPath: outPath,
      format: _format,
      quality: _quality,
      sourceName: sourceName,
      isNetwork: _inputMode == _InputMode.url,
      saveSettings: _saveSettings,
      importedTempDir: tempDir,
      startTimeMs: _convertStartTime!.millisecondsSinceEpoch,
      startInput: input,
    );

    // 关键：fire-and-forget。Coordinator 内部异步跑转换，
    // 期间 Page State 可以被销毁（用户点"后台运行"时），
    // FFmpeg 任务仍由 Coordinator 持有并继续执行。
    // 进度/状态变化通过 _coordSub 流推回 UI。
    // v1.6.37+ 修复（BUG6）：捕获 Coordinator.start() 抛出的异常。
    //   旧版用 unawaited() 包裹，如果 Coordinator 检测到"已有任务在运行"
    //   抛 StateError，异常变成未处理的异步错误，UI 状态卡在 running。
    //   新版用 .catchError() 捕获，把 UI 状态复位到 idle。
    ConvertCoordinator.instance.start(config).catchError((e) {
      AppLogger.e('VideoConvertPage', 'Coordinator.start() 失败', e);
      if (mounted) {
        setState(() {
          _status = _ConvertStatus.idle;
          _errorMessage = '启动转换失败：$e';
        });
        _showSnack('启动转换失败：$e');
      }
    });

    AppLogger.i('VideoConvertPage',
        '任务已交给 Coordinator：input=$input, output=$outPath');
  }

  // --------------------------------------------------------------------
  // 输出文件操作
  // --------------------------------------------------------------------

  /// 取消正在进行的转换（v1.6.19+ 改为转发给 Coordinator）
  ///
  /// v1.6.21+ 升级：这是"彻底取消"——会清掉所有恢复状态。
  /// 临时暂停请改用 [_pauseConvert]。
  ///
  /// v1.6.29+ 修复（bug13，针对大体积文件取消卡顿）：
  ///   旧版 `await ConvertCoordinator.instance.cancel()` 会阻塞 5~30s，
  ///   这期间用户看到按钮无响应，体验非常差。
  ///   新版 Coordinator.cancel() 改为非阻塞，await 立即返回。
  ///   这里配套加 _cancelling 标志位：
  ///     - 点取消瞬间：_cancelling = true，按钮立即变"取消中..."且禁用
  ///     - Coordinator.cancel() 立即返回（不再卡 UI）
  ///     - FFmpeg session 回调到达后，_syncFromCoordinatorSnapshot 会把
  ///       _cancelling 复位为 false（见该方法）
  ///   这样大体积文件取消时用户有即时视觉反馈。
  Future<void> _cancelConvert() async {
    AppLogger.i('VideoConvertPage', '用户点击取消');
    if (_cancelling) {
      // 已经在取消流程中，重复点击直接忽略（按钮已禁用，理论上走不到这里）
      AppLogger.d('VideoConvertPage', '取消请求已在进行中，忽略重复点击');
      return;
    }
    setState(() {
      _cancelling = true;
    });
    _showSnack('正在取消...');
    // fire-and-forget：Coordinator.cancel() 内部不再 await FFmpeg 收尾，
    // 立即返回；状态机真正切到 cancelled 要等 FFmpeg session 回调
    unawaited(ConvertCoordinator.instance.cancel());
  }

  /// 暂停转换（v1.6.21+ 新增）
  ///
  /// 用户点击"暂停转换"按钮时调用。
  /// 行为：
  ///   - 立即调用 FFmpegService.cancel() 停止当前会话
  ///   - 把已编码的进度写入磁盘（ConvertResumeState）
  ///   - Coordinator 状态切换为 paused
  ///   - UI 仍保留当前进度，可随时点"继续转换"
  ///
  /// 与"取消"的关键区别：
  ///   - 取消：彻底清空，输出文件被删，下次需要重新选文件
  ///   - 暂停：进度保留，输出文件保留，下次可继续
  ///
  /// v1.6.29+ 修复（bug13 配套）：同 _cancelConvert 的非阻塞改造。
  Future<void> _pauseConvert() async {
    AppLogger.i('VideoConvertPage', '用户点击暂停');
    if (_pausing) {
      AppLogger.d('VideoConvertPage', '暂停请求已在进行中，忽略重复点击');
      return;
    }
    setState(() {
      _pausing = true;
    });
    _showSnack('正在暂停...');
    // fire-and-forget：Coordinator.pause() 内部不再 await FFmpeg 收尾
    unawaited(ConvertCoordinator.instance.pause());
  }

  /// 继续转换（v1.6.21+ 新增）
  ///
  /// 用户点击"继续转换"按钮时调用。
  /// 行为：
  ///   - 读取磁盘上的 ConvertResumeState
  ///   - 从中断点继续编码剩余段
  ///   - 拼接 partial + 新段 = 完整文件
  ///   - 完成后走正常的"done"流程（保存历史、通知、SAF 复制）
  ///
  /// v1.6.29+ 修复（bug15，针对大体积文件续转卡顿体验）：
  ///   旧版 _resumeConvert() 调 `await ConvertCoordinator.instance.resume()`，
  ///   resume() 内部 _emitState(running) + 立即发 progress 事件都没问题，
  ///   但 Coordinator.resume() 自己内部还走 convertResume() 的 await，
  ///   这个 await 才是真正卡住的地方（大文件 input seek + 启动要 5~10s）。
  ///   新版改为 fire-and-forget（让 Coordinator 后台跑）+ _resuming 标志位
  ///   让 UI 立即显示"正在恢复..."提示文字。
  Future<void> _resumeConvert() async {
    AppLogger.i('VideoConvertPage', '用户点击继续转换');
    if (_resuming) {
      AppLogger.d('VideoConvertPage', '恢复请求已在进行中，忽略重复点击');
      return;
    }
    setState(() {
      _resuming = true;
    });
    _showSnack('正在继续转换...');
    // fire-and-forget：Coordinator.resume() 内部 _emitState(running) 是同步的，
    //   立刻推 running 状态给 UI 订阅者，UI 立即切到"准备中/正在恢复"状态
    unawaited(ConvertCoordinator.instance.resume());
  }

  /// 放弃恢复（v1.6.21+ 新增）
  ///
  /// 用户在 paused 状态点"取消"时调用。
  /// 行为：
  ///   - 与"取消"一致：清掉恢复状态，删掉 partial 输出
  ///   - 状态回到 idle，可以重新选文件
  ///
  /// v1.6.29+ 修复（bug13 配套）：paused 状态下 cancel() 走的是
  /// "early return" 分支（_state != running 直接跳过 _ffmpeg.cancel()），
  /// 所以这个 await 不会卡 UI（paused 时 _state == paused，不是 running，
  /// cancel 内部检查 _state != running 会直接 return）。
  /// 但为了和其它取消流程风格统一，也改为 fire-and-forget。
  ///
  /// v1.6.32+ 修复（bug18 配套）：
  ///   Coordinator.cancel() 现在对 paused 状态会同步执行清理
  /// （清恢复状态 + 清临时目录 + 复位内部字段 + emit cancelled），
  /// 不再是 no-op。这里去掉"early return"那段过期注释，
  /// 并改用 await：paused 状态下没有 FFmpeg 在跑，cancel() 立即返回，
  /// 不会卡 UI。await 完成后 UI 已经被 cancelled 事件切回 idle，
  /// 不需要 fire-and-forget。
  Future<void> _discardResume() async {
    AppLogger.i('VideoConvertPage', '用户点击放弃恢复');
    _showSnack('正在放弃...');
    // paused 状态下 cancel() 走同步清理流程（v1.6.32+ bug18 修复）：
    //   - 清掉磁盘上的 resume state
    //   - 复位 _config / _progress / 输出字段
    //   - 清掉 M3U8 临时目录
    //   - emitState(cancelled) → UI 切回 idle
    // 整个过程瞬时完成，await 不会卡 UI。
    await ConvertCoordinator.instance.cancel();
  }

  /// 用系统播放器打开输出文件
  ///
  /// 使用 [OpenFilex.open] 而不是 [launchUrl] + `Uri.file` 的原因：
  ///   Android 7.0 (API 24) 起，App 之间传递 `file://` URI 会被系统拒绝，
  ///   抛出 `FileUriExposedException`。
  ///   open_filex 在原生层走 `FileProvider.getUriForFile()` 转成 `content://` URI，
  ///   再用 `ACTION_VIEW` 调起系统播放器 / 文件管理器，完全规避该异常。
  Future<void> _openOutput() async {
    final path = _outputPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _showSnack('输出文件不存在：$path');
      return;
    }
    try {
      // 显式指定 MIME 为 video/*，让系统能匹配到视频播放器
      final ext = _formatExtension(_format);
      final result = await OpenFilex.open(path, type: 'video/$ext');
      AppLogger.i(
        'VideoConvertPage',
        'OpenFilex.open 完成：type=${result.type}, message=${result.message}',
      );
      if (result.type != ResultType.done) {
        _showSnack('打开失败：${result.message}');
      }
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '打开文件失败', e, st);
      _showSnack('打开失败：$e');
    }
  }

  /// 一键打开输出文件所在目录
  ///
  /// 流程（v1.6.20+ 升级）：
  ///   1) 先调原生 [MethodChannel] 走多 mime + createChooser：
  ///      候选 App 包含"系统文件管理器 / 第三方文件管理器 / 视频播放器 / 图库"等
  ///   2) 如果原生侧**没有**任何 App 可处理（NO_HANDLER）：
  ///      a) 退回到 [OpenFilex.open] 直接打开文件（系统播放器/视频播放器）
  ///      b) 仍然失败时弹一个"引导安装文件管理器"对话框
  Future<void> _openContainingFolder() async {
    final path = _outputPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _showSnack('输出文件不存在：$path');
      return;
    }
    AppLogger.i('VideoConvertPage', '尝试打开文件所在目录：$path');
    try {
      const channel = MethodChannel('com.example.toolapp/storage');
      final ok = await channel.invokeMethod<bool>(
        'openContainingFolder',
        {'filePath': path},
      );
      if (ok == true) {
        AppLogger.i('VideoConvertPage', '已调起文件管理器');
        return;
      }
      // 原生没找到任何 App → 走兜底
      AppLogger.w('VideoConvertPage', '原生侧无 App 可处理，尝试 OpenFilex 兜底');
      await _openOutput();
    } on PlatformException catch (e) {
      AppLogger.w('VideoConvertPage', 'openContainingFolder 失败: ${e.code} ${e.message}');
      if (e.code == 'NO_HANDLER') {
        // 兜底：直接打开文件
        await _openOutput();
      } else {
        _showSnack('打开目录失败：${e.message ?? e.code}');
      }
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '打开目录异常', e, st);
      _showSnack('打开目录失败：$e');
    }
  }

  /// 把 ETA 秒数格式化为简短字符串
  String _formatEta(int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    if (seconds < 60) return '剩余约 $seconds 秒';
    if (seconds < 3600) {
      final m = seconds ~/ 60;
      final s = seconds % 60;
      return s > 0 ? '剩余约 $m 分 $s 秒' : '剩余约 $m 分钟';
    }
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return m > 0 ? '剩余约 $h 小时 $m 分' : '剩余约 $h 小时';
  }

  /// 分享输出文件
  Future<void> _shareOutput() async {
    final path = _outputPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _showSnack('输出文件不存在：$path');
      return;
    }
    try {
      final ext = _formatExtension(_format);
      // share_plus 10.x 的分享 API
      await Share.shareXFiles(
        [XFile(path, mimeType: 'video/$ext', name: 'converted.$ext')],
        text: '用 ToolApp 转换的视频',
      );
      AppLogger.i('VideoConvertPage', '已分享输出文件：$path');
    } catch (e, st) {
      AppLogger.e('VideoConvertPage', '分享失败', e, st);
      _showSnack('分享失败：$e');
    }
  }

  /// 复制输出文件路径到剪贴板
  Future<void> _copyOutputPath() async {
    final path = _outputPath;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    _showSnack('已复制路径到剪贴板');
    AppLogger.i('VideoConvertPage', '已复制输出路径：$path');
  }

  // --------------------------------------------------------------------
  // 辅助方法
  // --------------------------------------------------------------------

  /// 显示 SnackBar
  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 显示完整 FFmpeg 日志
  Future<void> _showFullLogs() async {
    final logs = _lastErrorLogs;
    if (logs == null || logs.isEmpty) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('FFmpeg 完整日志'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                logs,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: logs));
                Navigator.of(ctx).pop();
                _showSnack('已复制日志到剪贴板');
              },
              child: const Text('复制日志'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 视频格式枚举 → 文件扩展名
  String _formatExtension(VideoFormat format) {
    switch (format) {
      case VideoFormat.mp4:
        return 'mp4';
      case VideoFormat.mkv:
        return 'mkv';
      case VideoFormat.mov:
        return 'mov';
    }
  }

  /// 视频格式枚举 → 中文显示名
  String _formatDisplayName(VideoFormat format) {
    switch (format) {
      case VideoFormat.mp4:
        return 'MP4（兼容性最好）';
      case VideoFormat.mkv:
        return 'MKV（开源容器）';
      case VideoFormat.mov:
        return 'MOV（Apple 生态）';
    }
  }

  /// v1.6.44+ 新增：加速模式 → 中文显示名
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

  /// 质量档位 → 中文显示名
  String _qualityDisplayName(VideoQuality q) {
    switch (q) {
      case VideoQuality.original:
        return '原画质（极速转封装，体积基本不变）';
      case VideoQuality.high:
        return '高画质（CRF 18，画质损失极小）';
      case VideoQuality.standard:
        return '标准（CRF 23，画质与体积平衡）';
      case VideoQuality.low:
        return '高压缩（CRF 28，体积最小）';
    }
  }

  /// 质量档位 → 简短标签
  String _qualityShortName(VideoQuality q) {
    switch (q) {
      case VideoQuality.original:
        return '原画质';
      case VideoQuality.high:
        return '高画质';
      case VideoQuality.standard:
        return '标准';
      case VideoQuality.low:
        return '高压缩';
    }
  }

  /// 质量档位 → 在 UI 中显示的"预估输出体积"字符串
  ///
  /// 返回值示例：
  ///   - "≈ 24.6 MB"：根据源 duration + bitrate 按质量档位系数估算得到
  ///   - "≈ 100%" / "≈ 70%"：仅知道大小不知码率时退化为"相对源文件比例"
  ///   - "未识别"：源未探测，无法预估
  ///
  /// 估算系数（实测经验值，仅作参考）：
  ///   - original: 1.00（封装复制，体积基本不变）
  ///   - high:     0.65（CRF 18 + veryfast + 192k 音频）
  ///   - standard: 0.40（CRF 23 + veryfast + 128k 音频）
  ///   - low:      0.22（CRF 28 + veryfast + 96k 音频）
  String _qualitySizeEstimate(VideoQuality q) {
    final durationMs = _sourceDurationMs;
    final bitrateKbps = _sourceBitrateKbps;
    // 1) 优先用 "码率 + 时长" 算绝对体积
    if (durationMs != null && durationMs > 0 && bitrateKbps != null && bitrateKbps > 0) {
      final factor = _qualitySizeFactor(q);
      // bytes = (kbps * 1000 bits/s) * (ms/1000 s) / 8
      final bytes = (bitrateKbps * durationMs * factor / 8 / 1000).round();
      return '≈ ${_formatSize(bytes)}';
    }
    // 2) 退化到"相对源文件大小"的比例
    if (_sourceSize != null && _sourceSize! > 0) {
      final factor = _qualitySizeFactor(q);
      final bytes = (_sourceSize! * factor).round();
      return '≈ ${_formatSize(bytes)}（估）';
    }
    // 3) 都没有：未识别
    return '未识别';
  }

  /// 质量档位 → 输出体积相对源的比例系数
  ///
  /// v1.6.56+ 优化：不同格式的压缩效率不同，预估系数应随格式变化
  ///   - MP4 (H.264): 基准
  ///   - MKV (H.264): 容器开销略小，约 -2%
  ///   - MOV (H.264): 容器开销略大，约 +3%
  double _qualitySizeFactor(VideoQuality q) {
    // 基础系数（MP4 H.264）
    double base;
    switch (q) {
      case VideoQuality.original:
        base = 1.00;
      case VideoQuality.high:
        base = 0.65;
      case VideoQuality.standard:
        base = 0.40;
      case VideoQuality.low:
        base = 0.22;
    }
    // 根据输出格式微调
    switch (_format) {
      case VideoFormat.mp4:
        return base; // 基准
      case VideoFormat.mkv:
        // MKV 容器开销略小
        return q == VideoQuality.original ? base : base * 0.98;
      case VideoFormat.mov:
        // MOV 容器开销略大
        return q == VideoQuality.original ? base * 1.03 : base * 1.03;
    }
  }

  /// 格式化文件大小为可读字符串
  String _formatSize(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 格式化时长为 HH:MM:SS
  String _formatDuration(int? ms) {
    if (ms == null) return '-';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  // --------------------------------------------------------------------
  // UI 构建
  // --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 仅在"Coordinator 报告有任务在跑"时拦截返回/离开事件，
      // 状态机由 Coordinator 持有，Page State 销毁不影响判断
      canPop: !ConvertCoordinator.instance.isRunning,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        // 用户尝试离开 → 弹窗询问
        await _onLeaveAttempted();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('视频格式转换'),
              // 当任务在 Coordinator 中后台运行时，
              // 顶栏显示一个小角标提示用户"后台运行中"
              if (ConvertCoordinator.instance.isRunning && _backgroundMode)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Chip(
                    label: Text('后台运行', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Colors.amber,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          actions: [
            // v1.6.43+ 新增：批量转换入口
            IconButton(
              tooltip: '批量转换',
              icon: const Icon(Icons.playlist_play),
              onPressed: _openBatchConvertPage,
            ),
            // 顶栏历史记录入口
            IconButton(
              tooltip: '历史记录',
              icon: const Icon(Icons.history),
              onPressed: _openHistoryPage,
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildInputCard(),
                const SizedBox(height: 12),
                _buildFormatCard(),
                const SizedBox(height: 12),
                _buildQualityCard(),
                const SizedBox(height: 12),
                _buildSavePathCard(),
                const SizedBox(height: 16),
                _buildProgressArea(),
                const SizedBox(height: 16),
                _buildActionButtons(),
                const SizedBox(height: 12),
                if (_errorMessage != null) _buildErrorInfo(),
                if (_outputPath != null) _buildOutputInfo(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 用户尝试离开转换页面（在 PopScope 拦截时调用）
  /// 弹窗询问：继续前台 / 后台运行 / 取消转换
  Future<void> _onLeaveAttempted() async {
    AppLogger.i('VideoConvertPage', '用户尝试离开正在转换的页面');
    if (!mounted) return;
    final action = await showDialog<_LeaveAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('视频正在转换中'),
        content: const Text(
          '当前还有视频转换任务尚未完成。\n'
          '离开页面后您仍可继续使用其他功能，但请注意：\n'
          '• 选"后台运行"：转换继续，进度会显示在系统通知栏\n'
          '• 选"取消转换"：会立即停止当前任务并清理临时文件\n'
          '• 选"留在前台"：返回本页继续查看实时进度',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.cancel),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('取消转换'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.background),
            child: const Text('后台运行'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.stay),
            child: const Text('留在前台'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    AppLogger.i('VideoConvertPage', '用户离开弹窗选择：$action');
    switch (action) {
      case _LeaveAction.cancel:
        // 取消转换：v1.6.19+ 改为转发给 Coordinator
        //   - 通知由 Coordinator 切到 "cancelled"
        //   - FFmpeg cancel 由 Coordinator 调用
        //   - 历史记录由 Coordinator 写
        //   - 状态切换事件会推回本页订阅者，UI 自动同步
        await ConvertCoordinator.instance.cancel();
        if (mounted) {
          _showSnack('已取消转换');
        }
        // 延迟一帧让 cancel 的回调走完，再 pop 页面
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) {
          // ignore: use_build_context_synchronously
          Navigator.of(context).pop();
        }
        break;
      case _LeaveAction.background:
        // 切到后台（v1.6.19+）：不再依赖 _backgroundMode 字段做"是否在后台"
        //   - 真正的后台运行由 Coordinator 持有 FFmpeg 任务
        //   - Page dispose() 不会取消任务
        //   - 重新进入页面时订阅会恢复 UI（_syncFromCoordinatorSnapshot）
        setState(() {
          _backgroundMode = true;
        });
        _showSnack('已切换为后台运行，进度将在通知栏显示');
        // 主动 pop 页面（因为 PopScope 默认拦截了 pop）
        await Future.delayed(const Duration(milliseconds: 100));
        if (mounted) {
          // ignore: use_build_context_synchronously
          Navigator.of(context).pop();
        }
        break;
      case _LeaveAction.stay:
      case null:
        // 留在前台，啥也不做
        break;
    }
  }

  /// 输入源详情卡片（v1.6.20+ 重做：两个并列的"选择卡" + URL 备用输入框）
  ///
  /// 设计思路：用户要选输入源时，最先看到的应该是"我要加什么类型的源"，
  /// 而不是"本地 vs 网络"这个对绝大多数人没意义的二分法。
  /// 所以把"视频文件"和"M3U8"作为两个并排的"选择卡"放在最显眼的位置，
  /// URL 输入折叠到下面作为备用入口。
  Widget _buildInputCard() {
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
                const Icon(Icons.movie_creation_outlined, size: 20),
                const SizedBox(width: 6),
                const Text(
                  '选择输入源',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  _sourceValue == null ? '未选择' : '已就绪',
                  style: TextStyle(
                    fontSize: 12,
                    color: _sourceValue == null ? Colors.grey : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '点击下方对应卡片选择输入类型，文件模式与 M3U8 模式自动识别',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            // 视频文件 / M3U8 两个并排的"选择卡"
            _buildFileInputArea(),
            const SizedBox(height: 10),
            if (_sourceValue != null) ...[
              // v1.6.22+ 新增：
              //   "名称" 这一行右侧加一个"列表"小按钮，仅在
              //   _m3u8Siblings 非空（=至少 2 个兄弟 M3U8）时显示。
              //   点击后弹出同目录 M3U8 列表让用户快捷切换。
              //   =1 个 M3U8 时不显示（不增加视觉噪音）。
              _buildInfoRow(
                '名称',
                _sourceName ?? '-',
                trailing: _canShowM3u8List
                    ? _buildM3u8ListButton()
                    : null,
              ),
              const SizedBox(height: 4),
              if (_sourceSize != null) ...[
                _buildInfoRow('大小', _formatSize(_sourceSize)),
                const SizedBox(height: 4),
              ],
              if (_sourceDurationMs != null && _sourceDurationMs! > 0) ...[
                _buildInfoRow('时长', _formatDuration(_sourceDurationMs)),
                const SizedBox(height: 4),
              ],
              // 长 URL/路径截断展示
              _buildInfoRow(
                _inputMode == _InputMode.url ? 'URL' : '路径',
                _sourceValue!,
                maxLines: 3,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 文件模式输入区
  ///
  /// v1.6.20+ 重做：原来只是两个堆叠的按钮，文字简短，用户容易误触（M3U8 选成单文件 → segments 丢失）。
  /// 新版用两个并排的"选择卡"（choice card），每个都自带：
  ///   - 大图标（一眼分辨视频文件 / M3U8）
  ///   - 主标题 + 副标题
  ///   - "支持格式" 行
  ///   - 整个卡都是点击区，物理尺寸比按钮大 3~4 倍，几乎不会误触
  Widget _buildFileInputArea() {
    final disabled = _status == _ConvertStatus.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 卡片 1：添加视频媒体文件
              Expanded(
                child: _SourceChoiceCard(
                  icon: Icons.movie_filter_outlined,
                  iconBg: const Color(0xFFE3F2FD), // 浅蓝
                  iconFg: const Color(0xFF1976D2),
                  title: '添加视频文件',
                  subtitle: 'mp4 / mov / mkv / avi / flv / ts 等',
                  hint: '单文件转换',
                  onTap: disabled ? null : _pickLocalFile,
                ),
              ),
              const SizedBox(width: 10),
              // 卡片 2：添加 M3U8 直播/切片
              Expanded(
                child: _SourceChoiceCard(
                  icon: Icons.playlist_play_rounded,
                  iconBg: const Color(0xFFFFF3E0), // 浅橙
                  iconFg: const Color(0xFFE65100),
                  title: '添加 M3U8 源',
                  subtitle: '直播流 / 切片列表',
                  hint: '自动复制 segments',
                  onTap: disabled ? null : _pickM3u8Folder,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // URL 输入折叠到第二行：M3U8 也可以用 URL 形式
        TextField(
          controller: _urlController,
          enabled: !disabled,
          keyboardType: TextInputType.url,
          maxLines: 1,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.link, size: 18),
            hintText: '或直接粘贴 M3U8 / 视频 URL',
            hintStyle: const TextStyle(fontSize: 12),
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            suffixIcon: IconButton(
              tooltip: '确认 URL',
              icon: const Icon(Icons.check_circle, size: 20),
              onPressed: disabled ? null : _confirmUrl,
            ),
          ),
          onSubmitted: (_) => _confirmUrl(),
        ),
      ],
    );
  }

  /// 输出格式选择卡片
  Widget _buildFormatCard() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.video_file_outlined, size: 20),
                SizedBox(width: 6),
                Text(
                  '输出格式',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            // v1.6.28+ 新增（bug12 需求）：running / paused 时显示
            //   灰色提示条告诉用户"任务进行中不可改，要重新开始才能改"
            if (_isTaskInProgress) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline,
                        size: 14, color: Colors.amber.shade800),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '任务进行中，输出设置已锁定。'
                        '如需修改，请先取消转换重新开始。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            // 单选列表
            // v1.6.28+ 修复（bug12）：用 _isTaskInProgress 替代只判 running，
            //   这样 paused 时 RadioListTile 也是 disabled。
            ...VideoFormat.values.map((f) => RadioListTile<VideoFormat>(
                  value: f,
                  groupValue: _format,
                  onChanged: _isTaskInProgress
                      ? null
                      : (v) {
                          if (v != null) setState(() => _format = v);
                        },
                  title: Text(_formatDisplayName(f)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
          ],
        ),
      ),
    );
  }

  /// 质量档位选择卡片
  /// 输出质量选择卡片（v1.6.20+ 增加预估体积显示）
  ///
  /// 每行展示：
  ///   - 主标题：质量档位 + CRF 参数
  ///   - 副标题：根据源码率/时长/大小估算的输出体积（"≈ 24.6 MB"）
  ///   - 选中后右侧用 chip 醒目标出"已选"
  Widget _buildQualityCard() {
    final hasSource = _sourceValue != null;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.high_quality_outlined, size: 20),
                SizedBox(width: 6),
                Text(
                  '输出质量',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // v1.6.44+ 新增：显示当前加速模式
            FutureBuilder<ConvertSpeedMode>(
              future: ConvertSpeedSettings.load(),
              builder: (context, snapshot) {
                final mode = snapshot.data ?? ConvertSpeedMode.off;
                return Row(
                  children: [
                    Icon(Icons.speed, size: 14, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Text(
                      '加速模式：${_speedModeLabel(mode)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: mode == ConvertSpeedMode.off
                            ? Colors.grey.shade600
                            : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '（设置中可修改）',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              hasSource
                  ? '预估输出体积基于源码率/时长估算，仅作参考'
                  : '请先选择输入源，预估输出体积会自动显示',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            ...VideoQuality.values.map((q) => _buildQualityTile(q)),
          ],
        ),
      ),
    );
  }

  /// 单个质量档位的 RadioListTile
  /// 把"质量名 / 参数"放在主标题，"预估体积"放在副标题
  Widget _buildQualityTile(VideoQuality q) {
    final selected = _quality == q;
    // v1.6.28+ 修复（bug12）：paused 时也要 disable
    final disabled = _isTaskInProgress;
    return InkWell(
      onTap: disabled
          ? null
          : () {
              if (selected) return;
              setState(() => _quality = q);
            },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected
               ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
        ),
        child: Row(
          children: [
            // 单选图标
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade500,
            ),
            const SizedBox(width: 8),
            // 文案列（主标题 + 副标题预估体积）
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _qualityDisplayName(q),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      // 预估体积（核心诉求）
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: selected
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _qualitySizeEstimate(q),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey.shade800,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 倍率提示
                      Text(
                        _qualityFactorHint(q),
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 已选 chip
            if (selected)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '已选',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 质量档位 → 体积倍率的中文简短说明
  /// 用百分比 + 文字描述帮用户理解"这个画质大概能压到原文件的多少"
  String _qualityFactorHint(VideoQuality q) {
    switch (q) {
      case VideoQuality.original:
        return '体积≈源';
      case VideoQuality.high:
        return '约 65% 体积';
      case VideoQuality.standard:
        return '约 40% 体积';
      case VideoQuality.low:
        return '约 22% 体积';
    }
  }

  /// 保存路径卡片：展示当前保存位置 + 引导用户去设置页修改
  /// 只读展示，不在本页面内编辑（编辑入口在"设置"页，避免本页面过于拥挤）
  Widget _buildSavePathCard() {
    final isCustom = _saveSettings.mode == VideoSaveMode.customSaf &&
        _saveSettings.customSafTreeUri != null;
    final displayName = isCustom
        ? (_saveSettings.customDisplayName ?? '已选自定义目录')
        : 'App 私有目录 (ToolApp/videos/converted/)';
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isCustom ? Icons.folder_special_outlined : Icons.folder_outlined,
            color: theme.colorScheme.primary,
          ),
        ),
        title: const Text(
          '保存位置',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        trailing: TextButton(
          // v1.6.28+ 修复（bug12）：paused 时也要 disable（running + paused 都不能改保存位置）
          onPressed: _isTaskInProgress
              ? null
              : () {
                  // 引导用户去设置页修改保存路径
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
                },
          child: const Text('去设置'),
        ),
      ),
    );
  }

  /// 进度显示区
  ///
  /// v1.6.21+ 新增：状态为 paused 时，在卡片顶部加一条"已暂停"提示条，
  /// 提示用户可以继续转换。
  Widget _buildProgressArea() {
    final percent = (_progress * 100).clamp(0, 100).toInt();
    final isRunning = _status == _ConvertStatus.running;
    final isPaused = _status == _ConvertStatus.paused;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // v1.6.21+ 新增：暂停状态横幅
            if (isPaused) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border.all(color: Colors.amber.shade300, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.pause_circle_filled,
                      size: 18,
                      color: Colors.amber.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '已暂停（$percent%）· 进度已保留，可继续转换',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Row(
              children: [
                Icon(Icons.timer_outlined, size: 20),
                SizedBox(width: 6),
                Text(
                  '转换进度',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: CircularPercentIndicator(
                radius: 60,
                lineWidth: 10,
                percent: _hasDuration ? _progress : 0,
                animation: true,
                animateFromLastPercent: true,
                animationDuration: 300,
                // 不确定式进度：环上转圈
                circularStrokeCap: CircularStrokeCap.round,
                progressColor: Theme.of(context).colorScheme.primary,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.12),
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_status == _ConvertStatus.running && !_hasDuration) ...[
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '准备中...',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ] else if (_status == _ConvertStatus.done) ...[
                      const Icon(Icons.check_circle,
                          color: Colors.green, size: 28),
                      const SizedBox(height: 4),
                      Text(
                        '完成',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ] else ...[
                      Text(
                        '$percent%',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_timeDisplay.isNotEmpty)
                        Text(
                          _timeDisplay,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.grey,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (isRunning || _status == _ConvertStatus.done || isPaused) ...[
              const SizedBox(height: 10),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // v1.6.29+ 修复（bug15 配套，针对大体积文件续转卡顿体验）：
                    //   旧版在 _hasDuration=false 时只显示"正在转换..."，
                    //   对大体积文件而言，FFmpeg 启动 + input seek 出第一帧
                    //   可能要 5~10 秒，这期间进度环不动 + 文字不变，
                    //   用户体感就是"卡在准备中"。
                    //   新版：
                    //     - _resuming=true 时显示"正在恢复转换..."（提示用户这是续转）
                    //     - _ffmpegSessionStarting=true 时显示"FFmpeg 启动中..."
                    //       （v1.6.30+ bug16 新增，FFmpeg 会话已建好但还没出帧）
                    //     - _hasDuration=false 且以上都为 false 时显示
                    //       "正在启动转换..." + 额外加一行小字"准备中，请稍候..."
                    //       让用户知道系统在干活
                    //     - 正常 _hasDuration=true 时保持原样
                    //   进度环的状态切换由 _onCoordinatorEvent 推动
                    //   （第一次 hasDuration=true 时 _resuming/_ffmpegSessionStarting 复位）。
                    Text(
                      isRunning
                          ? (_hasDuration
                              ? '正在转换... $_bitrateDisplay'
                              : (_ffmpegSessionStarting
                                  ? 'FFmpeg 启动中...'
                                  : (_resuming
                                      ? '正在恢复转换...'
                                      : '正在启动转换...')))
                          : isPaused
                              ? '已暂停 · 等待继续'
                              : '转换完成',
                      style: TextStyle(
                        fontSize: 13,
                        color: isRunning
                            ? (_ffmpegSessionStarting
                                ? Colors.deepPurple
                                : Colors.blue)
                            : isPaused
                                ? Colors.amber.shade800
                                : Colors.green.shade700,
                      ),
                    ),
                    // v1.6.29+ bug15 配套：未拿到 duration 时的二级提示
                    //   让用户知道系统在工作中（不是死锁了），并带上活动指示器
                    if (isRunning && !_hasDuration) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _resuming ? '准备中，请稍候...' : '准备中...',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                    // 预估剩余时间（仅 running 状态 + 有 ETA 时显示）
                    if (isRunning &&
                        _hasDuration &&
                        _etaSeconds != null &&
                        _etaSeconds! > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hourglass_top,
                              size: 13, color: Colors.orange),
                          const SizedBox(width: 4),
                          Text(
                            _formatEta(_etaSeconds),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.orange,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 底部操作按钮
  ///
  /// v1.6.21+ 重做：3 种状态对应 3 套按钮
  ///   - **running**：左边【暂停转换】+ 右边【取消转换】（并排）
  ///   - **paused**：左边【继续转换】+ 右边【取消】（并排，"取消"代表放弃恢复）
  ///   - **idle / done**：单个【开始转换】按钮
  ///
  /// 设计要点：
  ///   - 并排时用 Expanded 让两按钮等宽，gap 8px
  ///   - 暂停按钮用主题色的 tonal 变体（中性，不警告）
  ///   - 取消按钮用红色 tonal 警示色
  ///   - 继续转换按钮用主题色实心（鼓励用户继续）
  Widget _buildActionButtons() {
    final isRunning = _status == _ConvertStatus.running;
    final isPaused = _status == _ConvertStatus.paused;
    if (isRunning) {
      // 转换中：【暂停转换】+【取消转换】并排
      //
      // v1.6.29+ bug13 修复（UI 配套）：
      //   旧版两个按钮的 onPressed 在大文件取消/暂停时虽然有"立即返回"的逻辑，
      //   但用户视觉上还是没反馈。点完按钮后：
      //     - 暂停按钮还是显示"暂停转换"，用户以为没点中
      //     - 取消按钮还是显示"取消转换"，用户以为 App 卡死
      //   现在根据 _cancelling / _pausing 标志位切换按钮文案 + 禁用，
      //   提供即时视觉反馈：
      //     - _pausing=true → 暂停按钮显示"暂停中..."、禁用；取消按钮也禁用
      //     - _cancelling=true → 取消按钮显示"取消中..."、禁用；暂停按钮也禁用
      // v1.6.36+ 优化（bug22 配套）：
      //   续转准备期间（_ffmpegSessionStarting=true 或 _resuming=true），
      //   暂停按钮不可点击，必须等正式开始转换后才能暂停。
      //   取消按钮不受限制，随时可以取消。
      final preparing = _ffmpegSessionStarting || _resuming;
      return Row(
        children: [
          // 暂停按钮：主题色 tonal，不警告
          // 准备期间禁用（等 FFmpeg 出第一帧后才可暂停）
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.tonalIcon(
                onPressed: (_pausing || _cancelling || preparing) ? null : _pauseConvert,
                icon: _pausing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.pause_circle_outline),
                label: Text(_pausing ? '暂停中...' : '暂停转换'),
                style: FilledButton.styleFrom(
                  // 使用主题的 secondaryContainer 背景（柔和的中性色）
                  backgroundColor:
                      Theme.of(context).colorScheme.secondaryContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 取消按钮：红色 tonal 警示
          // 随时可以取消，不受准备期间限制
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.tonalIcon(
                onPressed: (_cancelling || _pausing) ? null : _cancelConvert,
                icon: _cancelling
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.red),
                        ),
                      )
                    : const Icon(Icons.cancel_outlined),
                label: Text(_cancelling ? '取消中...' : '取消转换'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red.shade700,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (isPaused) {
      // 已暂停：【继续转换】+【取消】并排
      // "取消"在暂停态的含义是"放弃恢复"，与"暂停前的取消"行为一致
      //
      // v1.6.29+ bug15 修复（UI 配套）：
      //   旧版点"继续转换"后按钮文案不变，用户以为 App 卡死。
      //   现在 _resuming=true 时按钮显示"恢复中..."并禁用，
      //   标志位在 _onCoordinatorEvent 收到第一个 hasDuration=true 的进度
      //   事件时复位（见 _onCoordinatorEvent 注释）。
      return Row(
        children: [
          // 继续转换按钮：主题色实心（鼓励用户继续）
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _resuming ? null : _resumeConvert,
                icon: _resuming
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_resuming ? '恢复中...' : '继续转换'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 取消（放弃）按钮：红色 tonal 警示
          // v1.6.36+ 优化（bug22 配套）：
          //   恢复中（_resuming=true）时取消按钮仍然可点击，
          //   用户随时可以取消，不需要等恢复完成。
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.tonalIcon(
                onPressed: _discardResume,
                icon: const Icon(Icons.delete_outline),
                label: const Text('取消'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red.shade700,
                ),
              ),
            ),
          ),
        ],
      );
    }
    // 空闲 / 完成：显示开始转换按钮
    final canConvert = _canConvert;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        onPressed: canConvert ? _onConvertPressed : null,
        icon: const Icon(Icons.play_arrow),
        label: const Text('开始转换'),
      ),
    );
  }

  /// 错误信息卡片
  Widget _buildErrorInfo() {
    return Card(
      elevation: 1,
      color: Colors.red.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                const SizedBox(width: 6),
                Text(
                  '转换失败',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              _errorMessage ?? '未知错误',
              style: TextStyle(fontSize: 13, color: Colors.red.shade900),
            ),
            if (_lastErrorLogs != null && _lastErrorLogs!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _showFullLogs,
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('查看完整日志'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 输出文件信息卡片
  Widget _buildOutputInfo() {
    return Card(
      elevation: 1,
      color: Colors.green.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green.shade700, size: 20),
                const SizedBox(width: 6),
                Text(
                  '转换成功',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildInfoRow('文件', _outputPath ?? '-', maxLines: 3),
            const SizedBox(height: 4),
            _buildInfoRow('大小', _formatSize(_outputSize)),
            const SizedBox(height: 4),
            _buildInfoRow(
              '格式',
              '${_formatExtension(_format).toUpperCase()} / ${_qualityShortName(_quality)}',
            ),
            const SizedBox(height: 12),
            // 操作按钮（第一行）
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openOutput,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('打开'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openContainingFolder,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('打开目录'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _shareOutput,
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('分享'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 第二行：复制路径 + 历史记录
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _copyOutputPath,
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制路径'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openHistoryPage,
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('历史记录'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 打开历史记录页
  Future<void> _openHistoryPage() async {
    AppLogger.i('VideoConvertPage', '打开历史记录页');
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ConvertHistoryPage(),
      ),
    );
  }

  /// v1.6.43+ 新增：打开批量转换页面
  ///
  /// v1.6.46+ 修复：从协调器获取已保存的任务列表，实现记录持久化
  Future<void> _openBatchConvertPage() async {
    AppLogger.i('VideoConvertPage', '打开批量转换页面');
    final savedTasks = BatchConvertCoordinator.instance.mutableTasks;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatchConvertPage(
          tasks: savedTasks,
          format: _format,
          quality: _quality,
          saveSettings: _saveSettings,
        ),
      ),
    );
  }

  /// 通用：键值对信息行
  ///
  /// v1.6.22+ 新增 [trailing] 槽位：可选地放一个控件在行的最右侧（值文本之后）。
  ///   - 不传 trailing：行为跟 v1.6.22 之前完全一致
  ///   - 传 trailing：常用于"名称"行后面挂个快捷操作按钮（如 M3U8 列表按钮），
  ///     不影响 SelectableText 的可复制性
  Widget _buildInfoRow(
    String label,
    String value, {
    int maxLines = 1,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        // v1.6.22+：可选的右侧槽位（M3U8 列表按钮等）
        if (trailing != null) ...[
          const SizedBox(width: 4),
          trailing,
        ],
      ],
    );
  }

  /// v1.6.22+ 新增：是否可以显示 M3U8 列表按钮
  ///
  /// 显示条件（**同时**满足）：
  ///   1) _m3u8SourceTreeUri 非空（即当前源是从某个 SAF 目录导入的 M3U8）
  ///   2) _m3u8Siblings 非空且 >= 2（=1 时不显示，避免视觉噪音）
  bool get _canShowM3u8List {
    final siblings = _m3u8Siblings;
    final treeUri = _m3u8SourceTreeUri;
    return treeUri != null &&
        treeUri.isNotEmpty &&
        siblings != null &&
        siblings.length >= 2;
  }

  /// v1.6.22+ 新增：M3U8 列表按钮（"名称"行右侧的"列表"小按钮）
  ///
  /// 点击后弹 _showM3u8SiblingsDialog 列出同目录所有 M3U8。
  ///   - 仅在 _canShowM3u8List = true 时调用方才会渲染这个按钮
  ///   - 任务正在跑（running / paused）时按钮禁用，防止切到一半 M3U8
  Widget _buildM3u8ListButton() {
    final siblings = _m3u8Siblings ?? const <String>[];
    final disabled = _status == _ConvertStatus.running ||
        _status == _ConvertStatus.paused;
    return TextButton.icon(
      onPressed: disabled ? null : _showM3u8SiblingsDialog,
      icon: const Icon(Icons.playlist_play_rounded, size: 16),
      label: Text('列表（${siblings.length}）'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12),
        foregroundColor: Colors.blue.shade700,
      ),
    );
  }
}

/// 输入源"选择卡"私有组件
///
/// 用一个 70~90dp 高的卡片同时承载：
///   - 顶部圆形图标（带彩色背景，区分视频文件 vs M3U8）
///   - 中部主标题 + 副标题（支持格式）
///   - 底部 hint（操作提示，如"单文件转换" / "自动复制 segments"）
///
/// 整个卡是点击区，比纯按钮大 3~4 倍，且自带视觉差异，
/// 用户一眼能区分两种输入源，几乎不会误触。
class _SourceChoiceCard extends StatelessWidget {
  /// 主图标（如 Icons.movie_filter_outlined）
  final IconData icon;
  /// 图标圆形背景
  final Color iconBg;
  /// 图标前景色
  final Color iconFg;
  /// 主标题（如"添加视频文件"）
  final String title;
  /// 副标题/支持格式说明
  final String subtitle;
  /// 底部 hint（如"单文件转换"）
  final String hint;
  /// 点击回调；null 时表示禁用
  final VoidCallback? onTap;

  const _SourceChoiceCard({
    required this.icon,
    required this.iconBg,
    required this.iconFg,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Colors.grey.shade200,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: enabled
                  ? Theme.of(context).colorScheme.outlineVariant
                  : Colors.grey.shade300,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          foregroundDecoration: enabled
              ? null
              : BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 圆形彩色图标
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: iconBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 20, color: iconFg),
                ),
                const SizedBox(height: 8),
                // 主标题
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // 副标题（支持格式）
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                    height: 1.25,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                // 底部 hint
                Row(
                  children: [
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 12,
                      color: enabled
                          ? Colors.grey.shade600
                          : Colors.grey.shade400,
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        hint,
                        style: TextStyle(
                          fontSize: 11,
                          color: enabled
                              ? Colors.grey.shade600
                              : Colors.grey.shade400,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ),
    );
  }
}

/// 导入进度对话框：监听 Kotlin 端 EventChannel 推送的实时进度，
/// 显示"已复制 N 个文件（X MB）…"，避免用户在长时间复制时误以为卡死。
/// v1.6.41+ 修复：旧版每 300ms 轮询 dir.list(recursive: true) 导致大目录卡顿，
///   新版改为 Kotlin 端主动推送（每 10 个文件或 5MB 上报一次），UI 不再阻塞。
class _ImportProgressDialog extends StatefulWidget {
  const _ImportProgressDialog({required this.destDirPath});

  final String destDirPath;

  @override
  State<_ImportProgressDialog> createState() => _ImportProgressDialogState();
}

class _ImportProgressDialogState extends State<_ImportProgressDialog> {
  // 实时统计的目标目录里的文件总数（由 Kotlin 端 EventChannel 推送）
  int _fileCount = 0;
  // 累计复制的字节数（由 Kotlin 端 EventChannel 推送）
  int _byteCount = 0;
  StreamSubscription<CopyProgress>? _subscription;

  @override
  void initState() {
    super.initState();
    // 监听 Kotlin 端推送的实时进度，不再轮询文件系统
    _subscription = SafDirectoryHelper.copyProgressStream.listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _fileCount = progress.fileCount;
          _byteCount = progress.byteCount;
        });
      },
      onError: (error) {
        AppLogger.w('VideoConvertPage', '复制进度流异常：$error');
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正在复制 M3U8 与 segments…'),
                const SizedBox(height: 6),
                Text(
                  '已复制 $_fileCount 个文件（${_formatBytes(_byteCount)}）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
