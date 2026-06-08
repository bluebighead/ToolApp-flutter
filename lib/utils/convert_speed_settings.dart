// 转换加速模式设置
// 持久化用户的"转换加速模式"选择，用于 FFmpeg 编码参数生成
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

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
