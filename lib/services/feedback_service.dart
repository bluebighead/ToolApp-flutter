// 用户反馈服务
// 负责收集用户的意见和建议，提交到服务器
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';
import 'device_info_service.dart';

/// 反馈提交结果
class FeedbackResult {
  final bool success;
  final String message;

  FeedbackResult({
    required this.success,
    required this.message,
  });
}

class FeedbackService {
  static const String _logTag = 'FeedbackService';

  // 单例模式
  static final FeedbackService instance = FeedbackService._();
  FeedbackService._();

  // 认证请求头
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };

  /// 提交用户反馈（已登录用户）
  Future<FeedbackResult> submitFeedback({
    required String content,
    String? contact,
  }) async {
    try {
      final serverUrl = appSettings.serverUrl;
      if (serverUrl.isEmpty) {
        AppLogger.w(_logTag, '服务器地址未配置，无法提交反馈');
        return FeedbackResult(success: false, message: '服务器地址未配置');
      }

      // 采集设备信息（简要描述，用于分析问题）
      String deviceInfo = '';
      try {
        final device = await DeviceInfoService.instance.collectDeviceInfo();
        deviceInfo = '${device.platform}/${device.model} (${device.osVersion}) - ${device.appVersion}';
      } catch (e) {
        deviceInfo = 'Android/${AppInfo.fullVersion}';
      }

      final body = jsonEncode({
        'content': content.trim(),
        'contact': contact?.trim() ?? '',
        'deviceInfo': deviceInfo,
      });

      AppLogger.i(_logTag, '提交反馈: ${content.trim().substring(0, content.trim().length > 50 ? 50 : content.trim().length)}...');

      final url = Uri.parse('$serverUrl/api/feedback/submit');
      final response = await http
          .post(
            url,
            headers: _authHeaders,
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = _parseJson(response.body);
        final success = json?['success'] ?? false;
        final message = json?['message'] ?? '提交成功';
        AppLogger.i(_logTag, '反馈提交${success ? '成功' : '失败'}: $message');
        return FeedbackResult(success: success, message: message);
      } else if (response.statusCode == 400) {
        final json = _parseJson(response.body);
        final message = json?['error'] ?? '反馈内容无效';
        AppLogger.w(_logTag, '反馈提交失败(400): $message');
        return FeedbackResult(success: false, message: message);
      }

      AppLogger.w(_logTag, '反馈提交失败: HTTP ${response.statusCode}');
      return FeedbackResult(success: false, message: '提交失败，请稍后重试');
    } catch (e) {
      AppLogger.e(_logTag, '反馈提交异常: $e');
      return FeedbackResult(success: false, message: '网络连接失败');
    }
  }

  /// 解析 JSON 响应（安全处理）
  Map<String, dynamic>? _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}
