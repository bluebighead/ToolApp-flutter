// 视频转换后台进度通知
//
// 用途：转换过程中通过 [flutter_local_notifications] 在系统通知栏
//       持续展示"实时进度 + 剩余时间"，并在完成时切到"转换完成"提示。
//
// 设计要点：
//  1) 单一 ID：所有转换进度共用 notificationId=1001，避免通知栏堆叠
//  2) 持续更新：进度回调里调用 [updateProgress] 直接覆盖上一条通知
//  3) 完成后切到 "big-picture" 完成态：标题、文本更新；不再 ongoing
//  4) 取消时调 [cancel] 把通知从通知栏移除
//  5) Android 13+ 必须先请求 POST_NOTIFICATIONS 权限，否则通知不显示
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_logger.dart';
import 'ffmpeg_service.dart';

/// 视频转换进度通知服务（单例）
class ConvertNotification {
  ConvertNotification._();
  static final ConvertNotification instance = ConvertNotification._();

  static const String _logTag = 'ConvertNotification';

  /// 通知 ID：固定 1001，复用同一条通知
  static const int _notifyId = 1001;

  /// 通知 channel id（Android 8+ 强制要求）
  static const String _channelId = 'video_convert_progress';

  /// 通知 channel 名称（系统设置里显示给用户看）
  static const String _channelName = '视频转换进度';

  /// 通知 channel 描述
  static const String _channelDesc = '展示视频转换的实时进度和剩余时间';

  /// 通知插件 wrapper（用于 initialize、cancel）
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 是否已初始化
  bool _initialized = false;

  /// 通知是否已显示
  bool _shown = false;

  /// 初始化（在 main() 启动时调用一次）
  Future<void> init() async {
    if (_initialized) return;
    try {
      // Android 初始化配置
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(initSettings);
      // Android 8+ 必须显式创建 channel
      final androidPlugin = _resolveAndroid();
      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.low, // 低优先级：不弹横幅、不响铃，但仍展示在通知栏
            showBadge: false,
          ),
        );
      }
      _initialized = true;
      AppLogger.i(_logTag, '通知服务初始化完成');
    } catch (e) {
      AppLogger.e(_logTag, '通知服务初始化失败：$e', e);
    }
  }

  /// 请求通知权限（Android 13+ 必须）
  /// 用户拒绝时不阻塞主流程，只是通知不显示
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      // flutter_local_notifications 自身也提供 requestPermission
      final androidPlugin = _resolveAndroid();
      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        AppLogger.i(_logTag, 'flutter_local_notifications 通知权限：$granted');
        if (granted == true) return true;
      }
      // 兜底：再调一次 permission_handler
      final status = await Permission.notification.request();
      AppLogger.i(_logTag, 'permission_handler 通知权限：$status');
      return status.isGranted || status.isLimited;
    } catch (e) {
      AppLogger.w(_logTag, '请求通知权限异常：$e', e);
      return false;
    }
  }

  /// 显示"开始转换"的初始通知（持续 ongoing 模式）
  /// [sourceName] 输入源显示名（用于副标题）
  Future<void> showStart({required String sourceName}) async {
    if (!_initialized) await init();
    if (!await _ensurePermission()) return;
    try {
      await _showOnAndroid(
        title: '视频转换中…',
        body: '源：$sourceName',
        details: _buildOngoingDetails(
          progress: 0,
          progressText: '0%',
          etaText: '准备中…',
        ),
      );
      _shown = true;
      AppLogger.i(_logTag, '已展示初始通知：$sourceName');
    } catch (e) {
      AppLogger.w(_logTag, '展示初始通知失败：$e', e);
    }
  }

  /// 更新进度
  /// [p] FFmpeg 进度回调
  Future<void> updateProgress(ConvertProgress p) async {
    if (!_initialized) await init();
    if (!_shown) return;
    try {
      final percent = (p.value * 100).clamp(0, 100).toInt();
      final etaText = _formatEta(p.etaSeconds);
      final subtitle = StringBuffer('进度 ${p.time.isNotEmpty ? p.time : '-'}');
      if (p.bitrate.isNotEmpty) subtitle.write(' · ${p.bitrate}');
      if (etaText.isNotEmpty) subtitle.write(' · $etaText');
      await _showOnAndroid(
        title: '视频转换中…  $percent%',
        body: subtitle.toString(),
        details: _buildOngoingDetails(
          progress: percent,
          progressText: '$percent%',
          etaText: etaText.isEmpty ? '剩余时间计算中…' : etaText,
        ),
      );
    } catch (e) {
      AppLogger.w(_logTag, '更新进度通知失败：$e', e);
    }
  }

  /// 切到"完成"通知（不再 ongoing，可被系统清理）
  /// [outputName] 输出文件名
  Future<void> showCompleted({required String outputName}) async {
    if (!_initialized) await init();
    try {
      await _showOnAndroid(
        title: '视频转换完成',
        body: '$outputName 已就绪',
        details: _buildCompletedDetails(),
      );
      _shown = false;
      AppLogger.i(_logTag, '已展示完成通知：$outputName');
    } catch (e) {
      AppLogger.w(_logTag, '展示完成通知失败：$e', e);
    }
  }

  /// 切到"失败"通知
  Future<void> showFailed({required String reason}) async {
    if (!_initialized) await init();
    try {
      await _showOnAndroid(
        title: '视频转换失败',
        body: reason,
        details: _buildFailedDetails(),
      );
      _shown = false;
      AppLogger.i(_logTag, '已展示失败通知：$reason');
    } catch (e) {
      AppLogger.w(_logTag, '展示失败通知失败：$e', e);
    }
  }

  /// 切到"已取消"通知
  Future<void> showCancelled() async {
    if (!_initialized) await init();
    try {
      await _showOnAndroid(
        title: '视频转换已取消',
        body: '已停止当前转换任务',
        details: _buildCancelledDetails(),
      );
      _shown = false;
      AppLogger.i(_logTag, '已展示取消通知');
    } catch (e) {
      AppLogger.w(_logTag, '展示取消通知失败：$e', e);
    }
  }

  /// 切到"已暂停"通知（v1.6.21+ 新增）
  ///
  /// 用户在转换过程中点了"暂停"按钮后调用。
  /// - 通知栏的进度条停在当前进度
  /// - 提示用户"已暂停，回到 App 可继续"
  /// - 不再 ongoing（可手动滑掉），但保留显示
  Future<void> showPaused({
    required String sourceName,
    required double progressPct,
  }) async {
    if (!_initialized) await init();
    try {
      final percent = (progressPct * 100).clamp(0, 100).toInt();
      await _showOnAndroid(
        title: '视频转换已暂停 · $percent%',
        body: '源：$sourceName · 回到 App 可继续',
        details: _buildPausedDetails(progress: percent, progressText: '$percent%'),
      );
      _shown = false;
      AppLogger.i(_logTag, '已展示暂停通知：$sourceName ($percent%)');
    } catch (e) {
      AppLogger.w(_logTag, '展示暂停通知失败：$e', e);
    }
  }

  /// 切到"继续转换"通知（v1.6.21+ 新增）
  ///
  /// 用户点了"继续转换"后调用，通知重新进入 ongoing 模式。
  Future<void> showResumed({required String sourceName}) async {
    if (!_initialized) await init();
    try {
      await _showOnAndroid(
        title: '视频转换中…',
        body: '源：$sourceName（从暂停点继续）',
        details: _buildOngoingDetails(
          progress: 0,
          progressText: '0%',
          etaText: '重新连接…',
        ),
      );
      _shown = true;
      AppLogger.i(_logTag, '已展示继续通知：$sourceName');
    } catch (e) {
      AppLogger.w(_logTag, '展示继续通知失败：$e', e);
    }
  }

  /// 取消通知（用户主动取消转换时调用）
  Future<void> cancel() async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(_notifyId);
      _shown = false;
      AppLogger.i(_logTag, '已取消通知');
    } catch (e) {
      AppLogger.w(_logTag, '取消通知失败：$e', e);
    }
  }

  // ----------------- 内部工具 -----------------

  /// 解析 Android 平台实现
  AndroidFlutterLocalNotificationsPlugin? _resolveAndroid() {
    return _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
  }

  /// 统一的"展示通知"内部方法
  ///
  /// 直接走 [AndroidFlutterLocalNotificationsPlugin.show]，绕开 wrapper 在
  /// 不同版本下签名与 IDE 类型推导不一致的问题（曾报 "Too many positional arguments"）。
  /// 3 个命名参数：
  ///   - title/body: 显示文本
  ///   - details: 完整的 Android 通知详情（channel、importance、style 等）
  Future<void> _showOnAndroid({
    required String title,
    required String body,
    required AndroidNotificationDetails details,
  }) async {
    final android = _resolveAndroid();
    if (android != null) {
      // Android 签名：3 positional + 1 named (notificationDetails, payload)
      await android.show(_notifyId, title, body, notificationDetails: details);
      return;
    }
    // 兜底：走 wrapper（4 positional）
    await _plugin.show(
      _notifyId,
      title,
      body,
      NotificationDetails(android: details),
    );
  }

  /// 构造"进行中"通知的 details（含进度条 + 不可滑动关闭）
  AndroidNotificationDetails _buildOngoingDetails({
    required int progress,
    required String progressText,
    required String etaText,
  }) {
    return AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true, // 不可滑动清除
      autoCancel: false,
      onlyAlertOnce: true, // 后续更新不响铃不震动
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      enableVibration: false,
      playSound: false,
      subText: etaText,
      styleInformation: BigTextStyleInformation(
        '进度 $progressText · $etaText',
        contentTitle: '视频转换中…',
      ),
    );
  }

  /// 构造"完成"通知的 details
  AndroidNotificationDetails _buildCompletedDetails() {
    return const AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      ticker: '视频转换完成',
      styleInformation: BigTextStyleInformation(
        '视频已转换完成。点击查看详情。',
        contentTitle: '视频转换完成',
        summaryText: 'ToolApp',
      ),
    );
  }

  /// 构造"失败"通知的 details
  AndroidNotificationDetails _buildFailedDetails() {
    return const AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
    );
  }

  /// 构造"已取消"通知的 details
  AndroidNotificationDetails _buildCancelledDetails() {
    return const AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: false,
      autoCancel: true,
    );
  }

  /// 构造"已暂停"通知的 details（v1.6.21+ 新增）
  ///
  /// 与"进行中"通知的区别：
  ///   - ongoing: false（可滑掉，但默认仍显示在通知栏）
  ///   - importance: default（点了会有反应，不像 low 那样静默）
  ///   - 进度条仍显示当前百分比
  AndroidNotificationDetails _buildPausedDetails({
    required int progress,
    required String progressText,
  }) {
    return AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false, // 暂停后可手动滑掉
      autoCancel: false,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      enableVibration: false,
      playSound: false,
      ticker: '视频转换已暂停',
      styleInformation: BigTextStyleInformation(
        '进度 $progressText · 回到 App 点"继续转换"',
        contentTitle: '视频转换已暂停',
        summaryText: 'ToolApp',
      ),
    );
  }

  /// 确保有通知权限；首次会主动请求
  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    final androidPlugin = _resolveAndroid();
    if (androidPlugin == null) return true;
    try {
      final granted = await androidPlugin.areNotificationsEnabled() ?? false;
      if (granted) return true;
      return await requestPermission();
    } catch (e) {
      if (kDebugMode) {
        AppLogger.w(_logTag, '_ensurePermission 异常：$e', e);
      }
      return false;
    }
  }

  /// 把 ETA 秒数格式化为简短字符串（与 video_convert_page 同步）
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
}
