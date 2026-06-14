import 'dart:convert';
import 'package:flutter/material.dart';
import '../pages/device_inspect/nfc_reader_page.dart';
import '../pages/compressor_entry_page.dart';
import '../pages/decibel_page.dart';
import '../pages/network_speed_page.dart';
import '../pages/fun_tools_page.dart';
import '../pages/video_convert_page.dart';
import '../pages/heart_rate_page.dart';
import '../pages/device_inspect_page.dart';
import '../pages/encryptor_page.dart';
import '../pages/device_inspect/package_viewer_page.dart';
import '../pages/device_inspect/electronic_calc_page.dart';
import '../pages/encryptor/url_parser_page.dart';
import '../pages/device_inspect/bluetooth_debug_page.dart';
import '../pages/settings_page.dart';
import '../pages/about_page.dart';

class AiToolExecutor {
  static String getToolsDescription() {
    return '''
1. NFC读写器 - 读取NFC标签信息、写入NDEF数据、MIFARE扇区认证、全卡克隆
2. 压缩器 - 包含视频压缩、音频压缩、图片压缩、查看压缩历史
3. 分贝测试仪 - 使用麦克风实时测量环境噪音分贝值
4. 网速测试 - 测试网络下载速度和上传速度
5. 趣味工具 - 包含掷骰子、麻将计分器、经期宝、转盘抽奖、计分板、一本正经阅读器
6. 视频格式转换 - 将视频文件转换为MP4等格式
7. 心率广播接收器 - 通过蓝牙接收心率广播数据
8. 设备检修工具 - 摄像头检测、屏幕坏点检测、麦克风检测、扬声器检测、指纹检测、GPS检测
9. 加解密工具 - 摩斯电码编解码、扫码传信、二维码解码
10. 安装包免压查看 - 查看APK安装包内容（无需解压）
11. 电子元件计算 - 计算电阻、电容等电子元件参数
12. 网址解析 - 解析URL参数
13. 蓝牙调试器 - 扫描和调试蓝牙设备
14. 设置 - 应用设置页面
15. 软件说明 - 版本信息和软件说明
''';
  }

  static void navigateToTool(String toolName, BuildContext context) {
    final page = _getPage(toolName);
    if (page != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    }
  }

  static Widget? _getPage(String toolName) {
    switch (toolName) {
      case 'NFC读写器':
        return const NfcReaderPage();
      case '压缩器':
        return const CompressorEntryPage();
      case '分贝测试仪':
        return const DecibelPage();
      case '网速测试':
        return const NetworkSpeedPage();
      case '趣味工具':
        return const FunToolsPage();
      case '视频格式转换':
        return const VideoConvertPage();
      case '心率广播接收器':
        return const HeartRatePage();
      case '设备检修工具':
        return const DeviceInspectPage();
      case '加解密工具':
        return const EncryptorPage();
      case '安装包免压查看':
        return const PackageViewerPage();
      case '电子元件计算':
        return const ElectronicCalcPage();
      case '网址解析':
        return const UrlParserPage();
      case '蓝牙调试器':
        return const BluetoothDebugPage();
      case '设置':
        return const SettingsPage();
      case '软件说明':
        return const AboutPage();
      default:
        return null;
    }
  }

  static Future<String> processAiResponse(String response, BuildContext context) async {
    try {
      final trimmed = response.trim();
      // Try to extract JSON from response (handle both pure JSON and text+JSON)
      var jsonStr = trimmed;
      final jsonStart = trimmed.indexOf('{');
      final jsonEnd = trimmed.lastIndexOf('}');
      if (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart) {
        jsonStr = trimmed.substring(jsonStart, jsonEnd + 1);
      }

      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = data['action'] as String?;

      switch (action) {
        case 'navigate':
          final target = data['target'] as String?;
          if (target != null && context.mounted) {
            navigateToTool(target, context);
            return '正在打开: $target';
          }
          return '未指定目标工具';
        case 'info':
          return data['message'] as String? ?? '';
        case 'chat':
          return data['message'] as String? ?? '';
        default:
          return data['message'] as String? ?? response;
      }
    } catch (_) {
      // If not valid JSON, return as plain text
      return response;
    }
  }
}
