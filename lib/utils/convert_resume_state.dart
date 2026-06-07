// 视频转换"暂停/恢复"状态持久化模型
//
// 背景（v1.6.21+ 引入）：
//   用户要求把"取消"拆成"暂停"和"取消"两种语义：
//     - 暂停：临时中断，进度保留，随时可继续；哪怕关闭界面、退出 App、
//       杀后台，下次进入 App 仍能从中断点继续
//     - 取消：彻底中断，进度清零，输入和输出都还原
//   FFmpegKit 没有真正的"pause" API，只能通过 cancel() 终止会话，
//   然后在恢复时用 -ss seek 到中断点继续编码，再用 concat 把两段拼起来。
//   跨进程存活必须把状态序列化到磁盘（App 私有目录）。
//
// 持久化位置：<app_docs>/convert_resume_state.json
//   - app_docs 路径：getApplicationDocumentsDirectory()
//   - 系统设置里"清除数据"会清掉，普通后台被杀不会
//   - 文件非常小（< 1KB），重写频率低
//
// 字段含义：
//   - input：FFmpeg 输入源（本地绝对路径 / http(s) URL / m3u8 URL）
//   - outputPath：最终输出文件绝对路径
//   - encodedTimeMs：中断时已编码完成的媒体时长（毫秒）
//   - totalDurationMs：源媒体总时长（毫秒，可选；用于 UI 进度展示）
//   - 其余字段：完整复刻启动时所用的 ConvertTaskConfig，
//               确保恢复时用的是同一份配置

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'ffmpeg_service.dart' show VideoFormat, VideoQuality;
import 'video_save_settings.dart';

/// 暂停时的转换状态（可序列化到磁盘）
class ConvertResumeState {
  /// FFmpeg 输入源
  final String input;

  /// 输出文件绝对路径
  final String outputPath;

  /// 输出容器格式
  final VideoFormat format;

  /// 质量档位
  final VideoQuality quality;

  /// 输入源显示名（用于通知 / 历史）
  final String sourceName;

  /// 是否是网络 URL
  final bool isNetwork;

  /// 视频保存设置（恢复时用同一份判断是否复制到 SAF）
  final VideoSaveSettingsSnapshot saveSettings;

  /// M3U8 导入的临时目录路径（恢复时不能清，需继续给 FFmpeg 读）
  final String? importedTempDirPath;

  /// 历史记录用：转换开始时间（毫秒）
  final int startTimeMs;

  /// 历史记录用：输入源字符串
  final String startInput;

  /// 已编码完成的媒体时长（毫秒）
  final int encodedTimeMs;

  /// 源媒体总时长（毫秒），失败时为 0
  final int totalDurationMs;

  /// 暂停时的墙钟时间（毫秒），仅供调试 / 显示
  final int pausedAtMs;

  const ConvertResumeState({
    required this.input,
    required this.outputPath,
    required this.format,
    required this.quality,
    required this.sourceName,
    required this.isNetwork,
    required this.saveSettings,
    required this.startTimeMs,
    required this.startInput,
    required this.encodedTimeMs,
    required this.totalDurationMs,
    required this.pausedAtMs,
    this.importedTempDirPath,
  });

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'input': input,
        'outputPath': outputPath,
        'format': format.name,
        'quality': quality.name,
        'sourceName': sourceName,
        'isNetwork': isNetwork,
        'saveSettings': saveSettings.toJson(),
        'importedTempDirPath': importedTempDirPath,
        'startTimeMs': startTimeMs,
        'startInput': startInput,
        'encodedTimeMs': encodedTimeMs,
        'totalDurationMs': totalDurationMs,
        'pausedAtMs': pausedAtMs,
      };

  /// 从 JSON 反序列化
  factory ConvertResumeState.fromJson(Map<String, dynamic> json) {
    return ConvertResumeState(
      input: json['input'] as String,
      outputPath: json['outputPath'] as String,
      format: VideoFormat.values.firstWhere(
        (e) => e.name == json['format'],
        orElse: () => VideoFormat.mp4,
      ),
      quality: VideoQuality.values.firstWhere(
        (e) => e.name == json['quality'],
        orElse: () => VideoQuality.standard,
      ),
      sourceName: json['sourceName'] as String? ?? 'video',
      isNetwork: json['isNetwork'] as bool? ?? false,
      saveSettings: VideoSaveSettingsSnapshotJson.fromJson(
        Map<String, dynamic>.from(json['saveSettings'] as Map? ?? {}),
      ),
      importedTempDirPath: json['importedTempDirPath'] as String?,
      startTimeMs: (json['startTimeMs'] as num?)?.toInt() ?? 0,
      startInput: json['startInput'] as String? ?? '',
      encodedTimeMs: (json['encodedTimeMs'] as num?)?.toInt() ?? 0,
      totalDurationMs: (json['totalDurationMs'] as num?)?.toInt() ?? 0,
      pausedAtMs: (json['pausedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 持久化管理器（单例）
class ConvertResumeStore {
  ConvertResumeStore._();
  static final ConvertResumeStore instance = ConvertResumeStore._();

  static const String _logTag = 'ConvertResumeStore';
  static const String _fileName = 'convert_resume_state.json';

  /// 内存缓存（启动时 lazy load）
  ConvertResumeState? _cached;

  /// 当前是否有可恢复的暂停任务
  bool get hasPending => _cached != null;

  /// 获取当前缓存的暂停状态（不读盘）
  ConvertResumeState? get current => _cached;

  /// 返回状态文件路径（不保证存在）
  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// 启动时 / 进入页面时调用，从磁盘加载
  ///
  /// 加载失败一律返回 null（不抛异常），避免影响正常流程。
  Future<ConvertResumeState?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cached = null;
        return null;
      }
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) {
        _cached = null;
        return null;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final s = ConvertResumeState.fromJson(json);
      // 进一步校验：输出文件必须还存在（如果源文件都被用户手动清了，
      // 那 resume 也没有意义）
      final outFile = File(s.outputPath);
      if (!await outFile.exists()) {
        AppLogger.w(_logTag, '状态文件存在但输出文件已不存在，丢弃');
        await clear();
        return null;
      }
      _cached = s;
      return s;
    } catch (e, st) {
      AppLogger.e(_logTag, '加载暂停状态失败：$e', e, st);
      _cached = null;
      return null;
    }
  }

  /// 保存（覆盖写）
  Future<void> save(ConvertResumeState state) async {
    try {
      final f = await _file();
      // 原子写：先写 .tmp 再 rename，避免写入中途异常导致文件半截
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(state.toJson()));
      await tmp.rename(f.path);
      _cached = state;
      AppLogger.i(
        _logTag,
        '已保存暂停状态：encodedTimeMs=${state.encodedTimeMs}'
        '/total=${state.totalDurationMs}ms',
      );
    } catch (e, st) {
      AppLogger.e(_logTag, '保存暂停状态失败：$e', e, st);
    }
  }

  /// 清除状态文件 + 内存缓存
  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        await f.delete();
        AppLogger.i(_logTag, '已删除暂停状态文件');
      }
    } catch (e) {
      AppLogger.w(_logTag, '删除暂停状态文件失败：$e');
    }
    _cached = null;
  }
}
