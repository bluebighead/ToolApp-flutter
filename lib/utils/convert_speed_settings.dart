// 转换加速模式设置
// 持久化用户的"转换加速模式"选择，用于 FFmpeg 编码参数生成
// 同时缓存编解码器检测结果，避免每次打开设置页都重新检测
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'codec_detector.dart';

/// 转换加速模式
enum ConvertSpeedMode {
  /// 关闭：使用 veryfast preset + 软件编码（默认）
  off,

  /// 硬件编码：使用 Android MediaCodec 硬件加速
  hardware,

  /// ultrafast：使用 ultrafast preset（速度更快但文件更大）
  ultrafast,
}

/// 转换加速设置读写工具
class ConvertSpeedSettings {
  static const String _kKey = 'convert_speed_mode';

  // 编解码器检测结果缓存的 key
  static const String _kCodecHwKey = 'codec_hw_supported';
  static const String _kCodecUltrafastKey = 'codec_ultrafast_supported';
  static const String _kCodecFfmpegMediacodecKey = 'codec_ffmpeg_mediacodec';
  static const String _kCodecFfmpegLibx264Key = 'codec_ffmpeg_libx264';
  static const String _kCodecAndroidH264Key = 'codec_android_h264';
  static const String _kCodecDetectedKey = 'codec_detected'; // 是否已检测过

  /// 从 SharedPreferences 读取加速模式
  static Future<ConvertSpeedMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_kKey) ?? ConvertSpeedMode.off.index;
    return ConvertSpeedMode.values[
        index.clamp(0, ConvertSpeedMode.values.length - 1)];
  }

  /// 写入加速模式
  static Future<void> save(ConvertSpeedMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKey, mode.index);
    AppLogger.i('ConvertSpeedSettings', '加速模式 -> ${mode.name}');
  }

  /// 缓存编解码器检测结果到 SharedPreferences
  static Future<void> saveCodecCapability(CodecCapability capability) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCodecDetectedKey, true);
    await prefs.setBool(_kCodecHwKey, capability.supportsHardwareEncoding);
    await prefs.setBool(_kCodecUltrafastKey, capability.supportsUltrafast);
    await prefs.setBool(_kCodecFfmpegMediacodecKey, capability.ffmpegHasMediacodec);
    await prefs.setBool(_kCodecFfmpegLibx264Key, capability.ffmpegHasLibx264);
    await prefs.setBool(_kCodecAndroidH264Key, capability.androidHasH264Encoder);
    AppLogger.i('ConvertSpeedSettings', '编解码器检测结果已缓存');
  }

  /// 从 SharedPreferences 读取缓存的编解码器检测结果
  /// 返回 null 表示尚未检测过
  static Future<CodecCapability?> loadCodecCapability() async {
    final prefs = await SharedPreferences.getInstance();
    final detected = prefs.getBool(_kCodecDetectedKey) ?? false;
    if (!detected) return null;

    return CodecCapability(
      supportsHardwareEncoding: prefs.getBool(_kCodecHwKey) ?? false,
      supportsUltrafast: prefs.getBool(_kCodecUltrafastKey) ?? false,
      ffmpegHasMediacodec: prefs.getBool(_kCodecFfmpegMediacodecKey) ?? false,
      ffmpegHasLibx264: prefs.getBool(_kCodecFfmpegLibx264Key) ?? false,
      androidHasH264Encoder: prefs.getBool(_kCodecAndroidH264Key) ?? false,
      cpuInfo: {}, // 缓存中不保存 cpuInfo，如需查看可重新检测
    );
  }

  /// 清除缓存的编解码器检测结果
  static Future<void> clearCodecCapability() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCodecDetectedKey);
    await prefs.remove(_kCodecHwKey);
    await prefs.remove(_kCodecUltrafastKey);
    await prefs.remove(_kCodecFfmpegMediacodecKey);
    await prefs.remove(_kCodecFfmpegLibx264Key);
    await prefs.remove(_kCodecAndroidH264Key);
    AppLogger.i('ConvertSpeedSettings', '编解码器检测结果缓存已清除');
  }
}

/// 批量并行数量设置
class BatchParallelSettings {
  static const String _kKey = 'batch_parallel_count';
  static const int _kDefault = 2;
  static const int _kMax = 5;
  static const int _kMin = 1;

  /// 读取并行数量
  static Future<int> load() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_kKey) ?? _kDefault;
    return count.clamp(_kMin, _kMax);
  }

  /// 写入并行数量
  static Future<void> save(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final clamped = count.clamp(_kMin, _kMax);
    await prefs.setInt(_kKey, clamped);
    AppLogger.i('BatchParallelSettings', '并行数量 -> $clamped');
  }
}
