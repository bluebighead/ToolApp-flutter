// 设备参数采集服务：采集用户手机详细参数并同步到服务器
// 采集内容包括：设备型号、系统版本、屏幕尺寸、内存、存储、CPU 等
// 供开发者针对不同设备进行优化
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';

/// 设备详细信息数据结构
class DeviceDetailedInfo {
  final String? deviceToken;
  final String platform;
  final String model;
  final String brand;
  final String osVersion;
  final int? sdkVersion;
  final int? screenWidth;
  final int? screenHeight;
  final String cpuArch;
  final bool isPhysicalDevice;
  final String appVersion;

  DeviceDetailedInfo({
    this.deviceToken,
    required this.platform,
    required this.model,
    required this.brand,
    required this.osVersion,
    this.sdkVersion,
    this.screenWidth,
    this.screenHeight,
    required this.cpuArch,
    required this.isPhysicalDevice,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'deviceToken': deviceToken,
        'platform': platform,
        'model': model,
        'brand': brand,
        'osVersion': osVersion,
        'sdkVersion': sdkVersion,
        'screenWidth': screenWidth,
        'screenHeight': screenHeight,
        'cpuArch': cpuArch,
        'isPhysicalDevice': isPhysicalDevice,
        'appVersion': appVersion,
      };
}

class DeviceInfoService {
  // 全局单例
  static final DeviceInfoService instance = DeviceInfoService._();
  DeviceInfoService._();

  // 服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  // 认证请求头
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${AuthService.instance.token}',
      };

  // SharedPreferences key：记录上次成功上传时间（毫秒时间戳）
  static const String _kLastUploadTsKey = 'device_info_last_upload_ts';
  // 最小上传间隔（毫秒），默认 24 小时
  static const int _minUploadIntervalMs = 24 * 60 * 60 * 1000;

  // 防止同时触发多次上传
  bool _isUploading = false;

  /// 采集设备详细参数
  Future<DeviceDetailedInfo> collectDeviceInfo({BuildContext? context}) async {
    final deviceInfo = DeviceInfoPlugin();
    final appVersion = AppInfo.fullVersion;
    final deviceToken = AuthService.instance.deviceToken;

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      final mediaSize = context != null
          ? MediaQuery.sizeOf(context)
          : null;

      return DeviceDetailedInfo(
        deviceToken: deviceToken,
        platform: 'Android',
        model: android.model,
        brand: android.brand,
        osVersion: android.version.release,
        sdkVersion: android.version.sdkInt,
        screenWidth: mediaSize != null ? mediaSize.width.toInt() : null,
        screenHeight: mediaSize != null ? mediaSize.height.toInt() : null,
        cpuArch: android.supportedAbis.isNotEmpty
            ? android.supportedAbis.first
            : 'unknown',
        isPhysicalDevice: android.isPhysicalDevice,
        appVersion: appVersion,
      );
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      final mediaSize = context != null
          ? MediaQuery.sizeOf(context)
          : null;

      return DeviceDetailedInfo(
        deviceToken: deviceToken,
        platform: 'iOS',
        model: ios.model,
        brand: 'Apple',
        osVersion: ios.systemVersion,
        sdkVersion: null,
        screenWidth: mediaSize != null ? mediaSize.width.toInt() : null,
        screenHeight: mediaSize != null ? mediaSize.height.toInt() : null,
        cpuArch: ios.utsname.machine,
        isPhysicalDevice: ios.isPhysicalDevice,
        appVersion: appVersion,
      );
    }

    // 其他平台回退
    return DeviceDetailedInfo(
      deviceToken: deviceToken,
      platform: Platform.operatingSystem,
      model: 'Unknown',
      brand: 'Unknown',
      osVersion: Platform.operatingSystemVersion,
      sdkVersion: null,
      screenWidth: null,
      screenHeight: null,
      cpuArch: 'unknown',
      isPhysicalDevice: true,
      appVersion: appVersion,
    );
  }

  /// 读取上次上传时间（毫秒时间戳）
  Future<int?> _getLastUploadTs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_kLastUploadTsKey);
    } catch (_) {
      return null;
    }
  }

  /// 写入本次上传时间
  Future<void> _setLastUploadTs(int ts) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastUploadTsKey, ts);
    } catch (_) {}
  }

  /// 是否需要上传（距离上次超过 _minUploadIntervalMs）
  Future<bool> shouldUpload() async {
    final last = await _getLastUploadTs();
    if (last == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - last) > _minUploadIntervalMs;
  }

  /// 上传设备参数到服务器
  /// [force] 设为 true 时忽略最小间隔限制（默认 false）
  Future<bool> uploadDeviceInfo({BuildContext? context, bool force = false}) async {
    if (!AuthService.instance.isLoggedIn) {
      AppLogger.w('DeviceInfoService', '未登录，跳过设备参数上传');
      return false;
    }

    // 检查最小间隔
    if (!force) {
      final need = await shouldUpload();
      if (!need) {
        AppLogger.i('DeviceInfoService',
            '距上次上传不足 24 小时，无需重复上传（force=false）');
        return false;
      }
    }

    // 防止并发上传
    if (_isUploading) {
      AppLogger.i('DeviceInfoService', '已有上传任务在进行中，跳过本次');
      return false;
    }
    _isUploading = true;

    try {
      final info = await collectDeviceInfo(context: context);
      AppLogger.i('DeviceInfoService',
          '上传设备参数 - ${info.platform} ${info.model} (${info.osVersion})${force ? '（强制）' : ''}');

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/device-info'),
            headers: _authHeaders,
            body: jsonEncode(info.toJson()),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        AppLogger.i('DeviceInfoService',
            '设备参数上传成功 - 操作: ${data['action']}');
        // 记录上传时间
        await _setLastUploadTs(DateTime.now().millisecondsSinceEpoch);
        return true;
      } else {
        AppLogger.e('DeviceInfoService',
            '设备参数上传失败: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      AppLogger.e('DeviceInfoService', '设备参数上传异常: $e');
      return false;
    } finally {
      _isUploading = false;
    }
  }
}
