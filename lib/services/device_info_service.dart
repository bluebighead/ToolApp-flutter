// 设备参数采集服务：采集用户手机详细参数并同步到服务器
// 采集内容包括：设备型号、系统版本、屏幕尺寸、内存、存储、CPU 等
// 供开发者针对不同设备进行优化
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';
import 'auth_service.dart';

/// 设备详细信息数据结构（v1.51.2+ 增加 totalMemory/totalStorage/screenInches/deviceName）
class DeviceDetailedInfo {
  final String? deviceToken;
  final String platform;
  final String model;
  final String brand;
  final String? deviceName; // 设备名称（用户自定义名称）
  final String? manufacturer; // 制造商
  final String osVersion;
  final int? sdkVersion;
  final int? screenWidth;
  final int? screenHeight;
  final double? screenInches; // 屏幕对角线尺寸（英寸）
  final String cpuArch;
  final int? cpuCores; // CPU 核心数
  final bool isPhysicalDevice;
  final int? totalMemory; // 总内存 (MB)
  final int? totalStorage; // 总存储 (MB)
  final String appVersion;

  DeviceDetailedInfo({
    this.deviceToken,
    required this.platform,
    required this.model,
    required this.brand,
    this.deviceName,
    this.manufacturer,
    required this.osVersion,
    this.sdkVersion,
    this.screenWidth,
    this.screenHeight,
    this.screenInches,
    required this.cpuArch,
    this.cpuCores,
    required this.isPhysicalDevice,
    this.totalMemory,
    this.totalStorage,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'deviceToken': deviceToken,
        'platform': platform,
        'model': model,
        'brand': brand,
        'deviceName': deviceName,
        'manufacturer': manufacturer,
        'osVersion': osVersion,
        'sdkVersion': sdkVersion,
        'screenWidth': screenWidth,
        'screenHeight': screenHeight,
        'screenInches': screenInches,
        'cpuArch': cpuArch,
        'cpuCores': cpuCores,
        'isPhysicalDevice': isPhysicalDevice,
        'totalMemory': totalMemory,
        'totalStorage': totalStorage,
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

  /// 采集设备详细参数（v1.51.2+ 增加总内存/总存储/屏幕尺寸/CPU核心数/设备名称）
  Future<DeviceDetailedInfo> collectDeviceInfo({BuildContext? context}) async {
    final deviceInfo = DeviceInfoPlugin();
    final appVersion = AppInfo.fullVersion;
    final deviceToken = AuthService.instance.deviceToken;

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      final mediaSize = context != null ? MediaQuery.sizeOf(context) : null;

      // 通过平台通道获取硬件信息（总内存/总存储/CPU核心数/屏幕尺寸）
      int? totalMemory;
      int? totalStorage;
      int? cpuCores;
      double? screenInches;
      try {
        final channel = MethodChannel('com.example.toolapp/device_info');
        totalMemory = await channel.invokeMethod<int>('getTotalMemory');
        totalStorage = await channel.invokeMethod<int>('getTotalStorage');
        cpuCores = await channel.invokeMethod<int>('getCpuCores');
        screenInches = await channel.invokeMethod<double>('getScreenInches');
      } catch (_) {}

      // fallback：使用 MediaQuery 估算屏幕英寸（不含调起源码时的上下文，无法获取精确 DPI）
      if (screenInches == null && mediaSize != null && context != null) {
        final pixelRatio = MediaQuery.of(context!).devicePixelRatio;
        final dpWidth = mediaSize.width;
        final dpHeight = mediaSize.height;
        // 粗略估算：假设 mdpi (160) 基准，实际值根据 pixelRatio 调整
        // 通常 pixelRatio 2.0 -> 320dpi, 3.0 -> 480dpi
        final estimate = math.sqrt(dpWidth * dpWidth + dpHeight * dpHeight);
        screenInches = double.parse((estimate / 160).toStringAsFixed(1));
      }

      return DeviceDetailedInfo(
        deviceToken: deviceToken,
        platform: 'Android',
        model: android.model,
        brand: android.brand,
        deviceName: android.model,
        manufacturer: android.manufacturer,
        osVersion: android.version.release,
        sdkVersion: android.version.sdkInt,
        screenWidth: mediaSize?.width.toInt(),
        screenHeight: mediaSize?.height.toInt(),
        screenInches: screenInches,
        cpuArch: android.supportedAbis.isNotEmpty ? android.supportedAbis.first : 'unknown',
        cpuCores: cpuCores,
        isPhysicalDevice: android.isPhysicalDevice,
        totalMemory: totalMemory,
        totalStorage: totalStorage,
        appVersion: appVersion,
      );
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      final mediaSize = context != null ? MediaQuery.sizeOf(context) : null;

      return DeviceDetailedInfo(
        deviceToken: deviceToken,
        platform: 'iOS',
        model: ios.model,
        brand: 'Apple',
        deviceName: ios.name,
        manufacturer: 'Apple',
        osVersion: ios.systemVersion,
        sdkVersion: null,
        screenWidth: mediaSize?.width.toInt(),
        screenHeight: mediaSize?.height.toInt(),
        screenInches: null,
        cpuArch: ios.utsname.machine,
        cpuCores: null,
        isPhysicalDevice: ios.isPhysicalDevice,
        totalMemory: null,
        totalStorage: null,
        appVersion: appVersion,
      );
    }

    // 其他平台回退
    return DeviceDetailedInfo(
      deviceToken: deviceToken,
      platform: Platform.operatingSystem,
      model: 'Unknown',
      brand: 'Unknown',
      deviceName: null,
      manufacturer: null,
      osVersion: Platform.operatingSystemVersion,
      sdkVersion: null,
      screenWidth: null,
      screenHeight: null,
      screenInches: null,
      cpuArch: 'unknown',
      cpuCores: null,
      isPhysicalDevice: true,
      totalMemory: null,
      totalStorage: null,
      appVersion: appVersion,
    );
  }

  /// 读取上次上传时间（毫秒时间戳）
  Future<int?> _getLastUploadTs() async {
    try {
      final prefs = AppSettings.prefs!;
      return prefs.getInt(_kLastUploadTsKey);
    } catch (_) {
      return null;
    }
  }

  /// 写入本次上传时间
  Future<void> _setLastUploadTs(int ts) async {
    try {
      final prefs = AppSettings.prefs!;
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
