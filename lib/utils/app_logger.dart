// 应用日志工具
// 统一封装日志记录接口：
// 1) 通过 dart:developer 输出到 IDE 调试控制台与 Android Logcat；
// 2) 同时把日志写入内存环形缓存，方便在 App 内查看最近日志、定位问题。
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// 日志级别
enum LogLevel { debug, info, warning, error }

/// 单条日志记录
class LogEntry {
  /// 日志产生时间
  final DateTime time;
  /// 日志级别
  final LogLevel level;
  /// 日志标签（一般填写产生日志的模块名）
  final String tag;
  /// 日志正文
  final String message;
  /// 关联的错误对象（可选）
  final Object? error;
  /// 关联的堆栈信息（可选）
  final StackTrace? stackTrace;

  LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// 格式化为单行可读字符串，方便复制/分享
  String format() {
    final timeStr = time.toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(7);
    final base = '[$timeStr] [$levelStr] [$tag] $message';
    if (error == null) return base;
    return '$base | error: $error';
  }
}

/// 应用日志器
class AppLogger {
  // Flutter 日志中显示的根名称，便于在 Logcat 中过滤
  static const String _appName = 'ToolApp';

  // 内存中最多缓存的日志条数，超出后丢弃最早的日志
  static const int _maxBufferSize = 500;

  // 内存日志缓存（外部不可直接修改）
  static final List<LogEntry> _buffer = <LogEntry>[];

  /// 对外暴露的只读日志列表
  static List<LogEntry> get buffer => List.unmodifiable(_buffer);

  /// 清空内存日志缓存
  static void clear() {
    _buffer.clear();
  }

  /// 通用写入方法：先写内存缓存，再输出到开发者控制台
  static void _add(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    _buffer.add(entry);
    // 超出容量上限则丢弃最早日志
    if (_buffer.length > _maxBufferSize) {
      _buffer.removeRange(0, _buffer.length - _maxBufferSize);
    }

    // 输出到 dart:developer，便于在 IDE 调试控制台与 Android Logcat 中查看
    developer.log(
      message,
      name: '$_appName/$tag',
      level: _levelToInt(level),
      error: error,
      stackTrace: stackTrace,
    );

    // Release 模式下也通过 debugPrint 输出，避免日志在 release 构建中被完全剥离
    // v1.6.49+ 调试：始终输出到 debugPrint，确保 logcat 能看到
    debugPrint(entry.format());
  }

  /// 把日志级别映射为 dart:developer 使用的整型
  static int _levelToInt(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warning:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }

  /// Debug 级别日志：用于开发期的详细流程记录
  static void d(String tag, String message) =>
      _add(LogLevel.debug, tag, message);

  /// Info 级别日志：用于关键流程节点（如页面进入、操作完成）
  static void i(String tag, String message) =>
      _add(LogLevel.info, tag, message);

  /// Warning 级别日志：用于非致命异常、可恢复的异常分支
  static void w(String tag, String message, [Object? error]) =>
      _add(LogLevel.warning, tag, message, error);

  /// Error 级别日志：用于致命异常、关键功能失败
  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) =>
      _add(LogLevel.error, tag, message, error, stackTrace);
}
