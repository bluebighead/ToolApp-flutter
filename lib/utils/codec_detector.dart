// 编解码器能力检测工具
// 提供两层检测机制，判断设备是否支持硬件编码（h264_mediacodec）和 ultrafast preset：
//   1. FFmpeg 层：通过 FFmpegKit 执行 -encoders 命令，检测 FFmpeg 编译时是否包含
//      h264_mediacodec 和 libx264 编码器
//   2. Android 原生层：通过 MethodChannel 调用 MediaCodecList API，
//      检测设备硬件是否真正支持 H.264 编码
// 两层检测组合使用，确保结果真实可靠
// 同时获取设备芯片信息（型号、核心数、频率等），用于检测结果展示
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 编解码器能力检测结果
class CodecCapability {
  /// 是否支持硬件编码（h264_mediacodec）
  /// 需要 FFmpeg 编译了 mediacodec 且设备有 H.264 硬件编码器
  final bool supportsHardwareEncoding;

  /// 是否支持 ultrafast preset（libx264）
  /// 只要 FFmpeg 编译了 libx264 就支持
  final bool supportsUltrafast;

  /// FFmpeg 层是否检测到 h264_mediacodec 编码器
  final bool ffmpegHasMediacodec;

  /// FFmpeg 层是否检测到 libx264 编码器
  final bool ffmpegHasLibx264;

  /// Android 原生层是否检测到 H.264 硬件编码器
  final bool androidHasH264Encoder;

  /// 设备芯片信息（键值对，来自 Android 原生层）
  final Map<String, String> cpuInfo;

  /// 检测过程中的错误信息（如有）
  final String? error;

  const CodecCapability({
    required this.supportsHardwareEncoding,
    required this.supportsUltrafast,
    required this.ffmpegHasMediacodec,
    required this.ffmpegHasLibx264,
    required this.androidHasH264Encoder,
    required this.cpuInfo,
    this.error,
  });

  @override
  String toString() {
    return 'CodecCapability('
        'hardware=$supportsHardwareEncoding, '
        'ultrafast=$supportsUltrafast, '
        'ffmpegMediacodec=$ffmpegHasMediacodec, '
        'ffmpegLibx264=$ffmpegHasLibx264, '
        'androidH264=$androidHasH264Encoder, '
        'cpuInfo=$cpuInfo'
        '${error != null ? ", error=$error" : ""})';
  }
}

/// 编解码器能力检测器
/// 组合 FFmpeg 编码器列表检测和 Android MediaCodecList 原生检测
class CodecDetector {
  /// MethodChannel 名称，与 Android 端 MainActivity 中注册的通道对应
  static const String _channelName = 'com.example.toolapp/codec_detector';

  /// 执行完整的编解码器能力检测
  ///
  /// 检测流程：
  ///   1. 通过 FFmpegKit 执行 -encoders 命令，解析输出中是否包含
  ///      h264_mediacodec 和 libx264
  ///   2. 通过 MethodChannel 调用 Android MediaCodecList API，
  ///      检测设备是否真正支持 H.264 硬件编码
  ///   3. 通过 MethodChannel 获取设备芯片信息
  ///   4. 组合两层结果：硬件编码需要两层都通过，ultrafast 只需 FFmpeg 层通过
  static Future<CodecCapability> detect() async {
    bool ffmpegHasMediacodec = false;
    bool ffmpegHasLibx264 = false;
    bool androidHasH264Encoder = false;
    Map<String, String> cpuInfo = {};
    String? error;

    // 第一层：FFmpeg 编码器列表检测
    try {
      final ffmpegResult = await _detectFFmpegEncoders();
      ffmpegHasMediacodec = ffmpegResult['h264_mediacodec'] ?? false;
      ffmpegHasLibx264 = ffmpegResult['libx264'] ?? false;
      AppLogger.i('CodecDetector',
          'FFmpeg 层检测：h264_mediacodec=$ffmpegHasMediacodec, libx264=$ffmpegHasLibx264');
    } catch (e) {
      AppLogger.e('CodecDetector', 'FFmpeg 编码器检测失败', e);
      error = 'FFmpeg 检测失败：$e';
    }

    // 第二层：Android 原生检测（仅 Android 平台）
    if (Platform.isAndroid) {
      try {
        androidHasH264Encoder = await _detectAndroidMediaCodec();
        AppLogger.i('CodecDetector',
            'Android 原生层检测：H.264 硬件编码器=$androidHasH264Encoder');
      } catch (e) {
        AppLogger.e('CodecDetector', 'Android MediaCodec 检测失败', e);
        error = (error != null ? '$error; ' : '') + 'Android 检测失败：$e';
      }

      // 获取芯片信息
      try {
        cpuInfo = await _getCpuInfo();
        AppLogger.i('CodecDetector', '芯片信息：$cpuInfo');
      } catch (e) {
        AppLogger.e('CodecDetector', '芯片信息获取失败', e);
        error = (error != null ? '$error; ' : '') + '芯片信息获取失败：$e';
      }
    } else {
      // 非 Android 平台默认不支持硬件编码
      androidHasH264Encoder = false;
    }

    // 组合检测结果
    // 硬件编码：FFmpeg 编译了 mediacodec 且设备有 H.264 硬件编码器
    final supportsHardwareEncoding =
        ffmpegHasMediacodec && androidHasH264Encoder;
    // ultrafast：FFmpeg 编译了 libx264 即可
    final supportsUltrafast = ffmpegHasLibx264;

    final capability = CodecCapability(
      supportsHardwareEncoding: supportsHardwareEncoding,
      supportsUltrafast: supportsUltrafast,
      ffmpegHasMediacodec: ffmpegHasMediacodec,
      ffmpegHasLibx264: ffmpegHasLibx264,
      androidHasH264Encoder: androidHasH264Encoder,
      cpuInfo: cpuInfo,
      error: error,
    );

    AppLogger.i('CodecDetector', '检测完成：$capability');
    return capability;
  }

  /// 第一层检测：通过 FFmpeg -encoders 命令检测编码器
  ///
  /// 执行 `ffmpeg -hide_banner -encoders` 命令，
  /// 解析输出中是否包含目标编码器名称
  /// 返回 Map<编码器名称, 是否支持>
  static Future<Map<String, bool>> _detectFFmpegEncoders() async {
    final session = await FFmpegKit.execute('-hide_banner -encoders');
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      AppLogger.w('CodecDetector', 'FFmpeg -encoders 返回非成功码：$returnCode');
      return {};
    }

    final output = await session.getOutput();
    if (output == null || output.isEmpty) {
      AppLogger.w('CodecDetector', 'FFmpeg -encoders 输出为空');
      return {};
    }

    // 解析输出，查找目标编码器
    // FFmpeg -encoders 输出格式示例：
    //  V..... h264_mediacodec   Android MediaCodec H.264 encoder (codec h264)
    //  V..... libx264           libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
    final result = <String, bool>{};
    result['h264_mediacodec'] =
        output.contains('h264_mediacodec');
    result['libx264'] = output.contains('libx264');

    return result;
  }

  /// 第二层检测：通过 MethodChannel 调用 Android MediaCodecList API
  ///
  /// 遍历设备所有编解码器，检查是否存在支持 H.264 编码的硬件编码器
  /// 返回 true 表示设备支持 H.264 硬件编码
  static Future<bool> _detectAndroidMediaCodec() async {
    const platform = MethodChannel(_channelName);
    try {
      final result = await platform.invokeMethod<bool>('checkH264Encoder');
      return result ?? false;
    } on PlatformException catch (e) {
      AppLogger.e('CodecDetector', 'MethodChannel 调用失败：${e.message}');
      return false;
    }
  }

  /// 获取设备芯片信息
  ///
  /// 通过 MethodChannel 调用 Android 原生层获取，
  /// 原生层综合使用 Build 类、/proc/cpuinfo、cpufreq 等标准接口
  static Future<Map<String, String>> _getCpuInfo() async {
    const platform = MethodChannel(_channelName);
    try {
      final result = await platform.invokeMethod<Map>('getCpuInfo');
      if (result == null) return {};
      // 将 Map<Object?, Object?> 转为 Map<String, String>
      return result.map((k, v) => MapEntry(k.toString(), v.toString()));
    } on PlatformException catch (e) {
      AppLogger.e('CodecDetector', '获取芯片信息失败：${e.message}');
      return {};
    }
  }
}
