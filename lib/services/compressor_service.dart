// 压缩服务层
// 封装视频压缩、音频压缩、图片压缩的统一调用接口
// 视频和音频压缩使用 ffmpeg_kit_flutter_new
// 图片压缩使用 flutter_image_compress
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// 压缩预设模式
/// fast：快速压缩，体积最小，速度最快
/// balanced：均衡模式，画质/音质与体积平衡
/// highQuality：高质量模式，保留较高画质/音质
enum CompressPreset {
  fast,
  balanced,
  highQuality,
}

/// 视频压缩参数
class VideoCompressParams {
  final int crf; // CRF值（18~28，数值越小画质越好）
  final String preset; // FFmpeg preset（ultrafast/veryfast/fast/medium/slow）
  final int audioBitrateK; // 音频比特率（kbps）

  const VideoCompressParams({
    required this.crf,
    required this.preset,
    required this.audioBitrateK,
  });

  /// 根据预设模式生成对应的压缩参数
  factory VideoCompressParams.fromPreset(CompressPreset preset) {
    switch (preset) {
      case CompressPreset.fast:
        return const VideoCompressParams(
            crf: 28, preset: 'veryfast', audioBitrateK: 96);
      case CompressPreset.balanced:
        return const VideoCompressParams(
            crf: 23, preset: 'medium', audioBitrateK: 128);
      case CompressPreset.highQuality:
        return const VideoCompressParams(
            crf: 18, preset: 'slow', audioBitrateK: 192);
    }
  }
}

/// 音频压缩参数
class AudioCompressParams {
  final int bitrateK; // 音频比特率（kbps）
  final int sampleRate; // 采样率（Hz）
  final String codec; // 音频编码器（aac/mp3/libopus）

  const AudioCompressParams({
    required this.bitrateK,
    required this.sampleRate,
    this.codec = 'aac',
  });

  /// 根据预设模式生成对应的压缩参数
  factory AudioCompressParams.fromPreset(CompressPreset preset) {
    switch (preset) {
      case CompressPreset.fast:
        return const AudioCompressParams(
            bitrateK: 64, sampleRate: 22050, codec: 'aac');
      case CompressPreset.balanced:
        return const AudioCompressParams(
            bitrateK: 128, sampleRate: 44100, codec: 'aac');
      case CompressPreset.highQuality:
        return const AudioCompressParams(
            bitrateK: 192, sampleRate: 48000, codec: 'aac');
    }
  }
}

/// 图片压缩参数
class ImageCompressParams {
  final int quality; // 压缩质量（0~100，数值越高画质越好）
  final int? maxWidth; // 最大宽度限制
  final int? maxHeight; // 最大高度限制

  const ImageCompressParams({
    this.quality = 60,
    this.maxWidth,
    this.maxHeight,
  });

  /// 根据预设模式生成对应的压缩参数
  factory ImageCompressParams.fromPreset(CompressPreset preset) {
    switch (preset) {
      case CompressPreset.fast:
        return const ImageCompressParams(
            quality: 30, maxWidth: 1280, maxHeight: 1280);
      case CompressPreset.balanced:
        return const ImageCompressParams(
            quality: 60, maxWidth: 1920, maxHeight: 1920);
      case CompressPreset.highQuality:
        return const ImageCompressParams(
            quality: 85, maxWidth: 2560, maxHeight: 2560);
    }
  }
}

/// 压缩进度回调信息
class CompressProgress {
  /// 0.0 ~ 1.0
  final double value;

  /// 当前状态描述文字
  final String info;

  const CompressProgress({required this.value, this.info = ''});
}

/// 压缩结果
class CompressResult {
  /// 输出文件路径
  final String outputPath;

  /// 原始文件大小（字节）
  final int originalSize;

  /// 压缩后文件大小（字节）
  final int compressedSize;

  /// 压缩耗时（毫秒）
  final int durationMs;

  const CompressResult({
    required this.outputPath,
    required this.originalSize,
    required this.compressedSize,
    this.durationMs = 0,
  });

  /// 压缩率百分比
  double get compressionRatio =>
      originalSize > 0 ? (1 - compressedSize / originalSize) * 100 : 0.0;
}

/// 压缩服务异常
class CompressException implements Exception {
  final String message;
  const CompressException(this.message);

  @override
  String toString() => message;
}

/// 压缩服务
/// 提供视频、音频、图片三种文件类型的压缩功能
class CompressorService {
  /// 日志标签
  static const String _tag = 'CompressorService';

  /// 获取应用安全输出目录（应用内部文档目录，Android 11+ Scoped Storage 下始终可写）
  /// 返回压缩文件专用的子目录路径
  static Future<Directory> _getSafeOutputDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final compressedDir = Directory(p.join(docsDir.path, 'compressed'));
    if (!await compressedDir.exists()) {
      await compressedDir.create(recursive: true);
    }
    return compressedDir;
  }

  /// 获取一个安全的临时输出路径（在系统临时目录下）
  /// 先压缩到临时目录，再复制到用户指定的目标路径，
  /// 避免 Android 11+ Scoped Storage 对直接写入外部存储的限制
  static String _getTempOutputPath(String originalOutputPath) {
    final ext = p.extension(originalOutputPath);
    final baseName = p.basenameWithoutExtension(originalOutputPath);
    final tempDir = Directory.systemTemp;
    // 使用唯一时间戳生成临时路径，避免并发冲突
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(tempDir.path, '${baseName}_tmp_$timestamp$ext');
  }

  /// 将文件从临时路径移动到目标路径（v1.52.0+ 优化：优先使用rename避免重复复制）
  /// 返回实际保存的文件路径（如果目标路径在外部存储不可写，会自动降级到应用内部存储）
  /// 确保目标目录存在，支持覆盖已有文件
  static Future<String> _copyToTarget(String tempPath, String targetPath) async {
    AppLogger.i(_tag, '将临时文件移动到目标路径: $targetPath');
    try {
      final targetDir = Directory(p.dirname(targetPath));
      if (!await targetDir.exists()) {
        AppLogger.i(_tag, '创建目标目录: ${targetDir.path}');
        await targetDir.create(recursive: true);
      }
      // 如果目标文件已存在，先删除
      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      // v1.52.0+ 优先尝试rename（零拷贝，同文件系统下瞬时完成）
      try {
        await File(tempPath).rename(targetPath);
        AppLogger.i(_tag, '移动完成，保存到: $targetPath');
        return targetPath;
      } catch (_) {
        // rename失败（跨文件系统），回退到copy+delete
        await File(tempPath).copy(targetPath);
        AppLogger.i(_tag, '复制完成（跨文件系统），保存到: $targetPath');
        return targetPath;
      }
    } on PathAccessException catch (e) {
      // Android 11+ Scoped Storage 限制：无法直接写入外部共享存储路径
      // 降级保存到应用内部文档目录
      AppLogger.w(_tag, '目标路径不可写（Scoped Storage 限制）: $targetPath, 错误: $e');
      AppLogger.i(_tag, '降级保存到应用内部存储...');
      final safeDir = await _getSafeOutputDir();
      final fileName = p.basename(targetPath);
      final fallbackPath = p.join(safeDir.path, fileName);
      // 确保降级路径不存在冲突
      final fallbackFile = File(fallbackPath);
      if (await fallbackFile.exists()) {
        await fallbackFile.delete();
      }
      // 优先rename，失败则copy
      try {
        await File(tempPath).rename(fallbackPath);
        AppLogger.i(_tag, '已降级移动到: $fallbackPath');
      } catch (_) {
        await File(tempPath).copy(fallbackPath);
        AppLogger.i(_tag, '已降级复制到: $fallbackPath');
      }
      return fallbackPath;
    }
  }

  /// 压缩视频文件
  /// [inputPath] 输入文件路径
  /// [outputPath] 输出文件路径（需以 .mp4 结尾）
  /// [params] 压缩参数
  /// [onProgress] 进度回调
  /// 返回压缩结果
  static Future<CompressResult> compressVideo({
    required String inputPath,
    required String outputPath,
    required VideoCompressParams params,
    required void Function(CompressProgress) onProgress,
  }) async {
    AppLogger.i(_tag, '========== 开始视频压缩 ==========');
    AppLogger.i(_tag, '输入文件: $inputPath');
    AppLogger.i(_tag, '输出文件: $outputPath');
    AppLogger.i(_tag, '参数: CRF=${params.crf}, preset=${params.preset}, 音频码率=${params.audioBitrateK}kbps');

    // 获取原始文件大小
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      AppLogger.e(_tag, '输入文件不存在：$inputPath');
      throw CompressException('输入文件不存在：$inputPath');
    }
    final originalSize = await inputFile.length();
    AppLogger.i(_tag, '输入文件大小: $originalSize 字节');

    // 使用临时路径进行FFmpeg压缩，避免外部存储权限问题
    final tempOutputPath = _getTempOutputPath(outputPath);
    AppLogger.i(_tag, '临时输出路径: $tempOutputPath');

    // 确保临时输出目录存在
    final tempDir = Directory(p.dirname(tempOutputPath));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }

    // 构造 FFmpeg 压缩命令
    // -i 输入文件
    // -c:v libx264 使用 H.264 编码视频
    // -preset 编码速度/压缩率平衡
    // -crf 质量参数（数值越小质量越好）
    // -c:a aac 音频编码为 AAC
    // -b:a 音频比特率
    // -movflags +faststart 优化 MP4 网络播放
    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel', 'info',
      '-stats',
      '-i', inputPath,
      '-c:v', 'libx264',
      '-preset', params.preset,
      '-crf', '${params.crf}',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '${params.audioBitrateK}k',
      '-movflags', '+faststart',
      tempOutputPath,
    ];

    AppLogger.i(_tag, 'FFmpeg 命令参数: ${args.join(' ')}');

    final startMs = DateTime.now().millisecondsSinceEpoch;
    final completer = Completer<CompressResult>();

    // 执行 FFmpeg 命令
    AppLogger.i(_tag, '开始执行 FFmpeg...');
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (completedSession) async {
        final endMs = DateTime.now().millisecondsSinceEpoch;
        final duration = endMs - startMs;
        final returnCode = await completedSession.getReturnCode();
        AppLogger.i(_tag, 'FFmpeg 执行完成, 耗时: ${duration}ms, 返回码: $returnCode');

        if (ReturnCode.isSuccess(returnCode)) {
          // 先检查临时文件是否存在
          final tempFile = File(tempOutputPath);
          if (!await tempFile.exists()) {
            AppLogger.e(_tag, '临时输出文件不存在！路径: $tempOutputPath');
            completer.completeError(
                const CompressException('视频压缩失败：临时输出文件不存在'));
            return;
          }
          var compressedSize = await tempFile.length();

          // 压缩后体积反而增大：保留原始文件，避免输出比输入更大的文件
          if (compressedSize >= originalSize) {
            AppLogger.w(_tag, '压缩后体积增大($compressedSize >= $originalSize)，保留原始文件');
            // 清理临时压缩文件
            try { await tempFile.delete(); } catch (_) {}
            // 将原始文件复制到目标路径
            final finalOutputPath = await _copyToTarget(inputPath, outputPath);
            compressedSize = originalSize;
            AppLogger.i(_tag, '已保留原始文件到: $finalOutputPath');
            completer.complete(CompressResult(
              outputPath: finalOutputPath,
              originalSize: originalSize,
              compressedSize: compressedSize,
              durationMs: duration,
            ));
            return;
          }

          // 将结果复制到用户指定的目标路径（在 Android 11+ 上目标不可写时会自动降级到应用内部存储）
          final finalOutputPath = await _copyToTarget(tempOutputPath, outputPath);

          // 清理临时文件
          try {
            await tempFile.delete();
          } catch (_) {}

          AppLogger.i(_tag, '压缩成功! 原始大小: $originalSize -> 压缩后: $compressedSize');
          completer.complete(CompressResult(
            outputPath: finalOutputPath,
            originalSize: originalSize,
            compressedSize: compressedSize,
            durationMs: duration,
          ));
        } else if (ReturnCode.isCancel(returnCode)) {
          AppLogger.w(_tag, '用户已取消压缩');
          completer.completeError(
              const CompressException('用户已取消压缩'));
        } else {
          final logs =
              await completedSession.getAllLogsAsString() ?? '';
          AppLogger.e(_tag, '视频压缩失败，FFmpeg 日志:\n$logs');
          completer.completeError(
              CompressException('视频压缩失败：$logs'));
        }
      },
      (log) {
        // 日志回调，用于调试时记录 FFmpeg 内部日志
        AppLogger.d(_tag, '[FFmpeg] ${log.getMessage()}');
      },
      (statistics) {
        // 进度回调：根据已处理时间估算进度
        final timeMs = statistics.getTime();
        if (timeMs > 0) {
          // 使用对数方式估算进度（因为不知道总时长）
          // 30s 约 0.3，60s 约 0.5，120s 约 0.65
          final progress =
              (0.1 + 0.85 * (1 - 1 / (1 + timeMs / 90000.0)))
                  .clamp(0.0, 0.95);
          final bitrate = statistics.getBitrate();
          final info = bitrate > 0
              ? '${bitrate.toStringAsFixed(0)} kbps'
              : '';
          onProgress(CompressProgress(
              value: progress, info: info));
        }
      },
    );

    return completer.future;
  }

  /// 压缩音频文件
  /// [inputPath] 输入文件路径
  /// [outputPath] 输出文件路径（建议以 .m4a 或 .mp3 结尾）
  /// [params] 压缩参数
  /// [onProgress] 进度回调
  /// 返回压缩结果
  static Future<CompressResult> compressAudio({
    required String inputPath,
    required String outputPath,
    required AudioCompressParams params,
    required void Function(CompressProgress) onProgress,
  }) async {
    AppLogger.i(_tag, '========== 开始音频压缩 ==========');
    AppLogger.i(_tag, '输入文件: $inputPath');
    AppLogger.i(_tag, '输出文件: $outputPath');
    AppLogger.i(_tag, '参数: 比特率=${params.bitrateK}kbps, 采样率=${params.sampleRate}Hz, 编码器=${params.codec}');

    // 获取原始文件大小
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      AppLogger.e(_tag, '输入文件不存在：$inputPath');
      throw CompressException('输入文件不存在：$inputPath');
    }
    final originalSize = await inputFile.length();
    AppLogger.i(_tag, '输入文件大小: $originalSize 字节');

    // 使用临时路径进行FFmpeg压缩，避免外部存储权限问题
    final tempOutputPath = _getTempOutputPath(outputPath);
    AppLogger.i(_tag, '临时输出路径: $tempOutputPath');

    // 确保临时输出目录存在
    final tempDir = Directory(p.dirname(tempOutputPath));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }

    // 构造 FFmpeg 音频压缩命令
    // -i 输入文件
    // -vn 跳过视频流（纯音频文件兼容）
    // -c:a 音频编码器
    // -b:a 音频比特率
    // -ar 采样率
    // -strict experimental 启用实验性编码器（部分 FFmpeg 构建中 AAC 需要）
    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel', 'info',
      '-stats',
      '-i', inputPath,
      '-vn',
      '-c:a', params.codec,
      '-strict', 'experimental',
      '-b:a', '${params.bitrateK}k',
      '-ar', '${params.sampleRate}',
      tempOutputPath,
    ];

    AppLogger.i(_tag, 'FFmpeg 命令参数: ${args.join(' ')}');

    final startMs = DateTime.now().millisecondsSinceEpoch;
    final completer = Completer<CompressResult>();

    AppLogger.i(_tag, '开始执行 FFmpeg...');
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (completedSession) async {
        final endMs = DateTime.now().millisecondsSinceEpoch;
        final duration = endMs - startMs;
        final returnCode = await completedSession.getReturnCode();
        AppLogger.i(_tag, 'FFmpeg 执行完成, 耗时: ${duration}ms, 返回码: $returnCode');

        if (ReturnCode.isSuccess(returnCode)) {
          // 先检查临时文件是否存在
          final tempFile = File(tempOutputPath);
          if (!await tempFile.exists()) {
            AppLogger.e(_tag, '临时输出文件不存在！路径: $tempOutputPath');
            completer.completeError(
                const CompressException('音频压缩失败：临时输出文件不存在'));
            return;
          }
          var compressedSize = await tempFile.length();

          // 压缩后体积反而增大：保留原始文件，避免输出比输入更大的文件
          if (compressedSize >= originalSize) {
            AppLogger.w(_tag, '压缩后体积增大($compressedSize >= $originalSize)，保留原始文件');
            try { await tempFile.delete(); } catch (_) {}
            final finalOutputPath = await _copyToTarget(inputPath, outputPath);
            compressedSize = originalSize;
            AppLogger.i(_tag, '已保留原始文件到: $finalOutputPath');
            completer.complete(CompressResult(
              outputPath: finalOutputPath,
              originalSize: originalSize,
              compressedSize: compressedSize,
              durationMs: duration,
            ));
            return;
          }

          // 将结果复制到用户指定的目标路径（在 Android 11+ 上目标不可写时会自动降级到应用内部存储）
          final finalOutputPath = await _copyToTarget(tempOutputPath, outputPath);

          // 清理临时文件
          try {
            await tempFile.delete();
          } catch (_) {}

          AppLogger.i(_tag, '压缩成功! 原始大小: $originalSize -> 压缩后: $compressedSize');
          completer.complete(CompressResult(
            outputPath: finalOutputPath,
            originalSize: originalSize,
            compressedSize: compressedSize,
            durationMs: duration,
          ));
        } else if (ReturnCode.isCancel(returnCode)) {
          AppLogger.w(_tag, '用户已取消压缩');
          completer.completeError(
              const CompressException('用户已取消压缩'));
        } else {
          final logs =
              await completedSession.getAllLogsAsString() ?? '';
          AppLogger.e(_tag, '音频压缩失败，FFmpeg 日志:\n$logs');
          completer.completeError(
              CompressException('音频压缩失败：$logs'));
        }
      },
      (log) {
        // 日志回调，用于调试时记录 FFmpeg 内部日志
        AppLogger.d(_tag, '[FFmpeg] ${log.getMessage()}');
      },
      (statistics) {
        // 进度回调
        final timeMs = statistics.getTime();
        if (timeMs > 0) {
          final progress =
              (0.1 + 0.85 * (1 - 1 / (1 + timeMs / 60000.0)))
                  .clamp(0.0, 0.95);
          onProgress(
              CompressProgress(value: progress, info: ''));
        }
      },
    );

    return completer.future;
  }

  /// 压缩图片文件
  /// [inputPath] 输入文件路径
  /// [outputPath] 输出文件路径
  /// [params] 压缩参数
  /// [onProgress] 进度回调
  /// 返回压缩结果
  static Future<CompressResult> compressImage({
    required String inputPath,
    required String outputPath,
    required ImageCompressParams params,
    required void Function(CompressProgress) onProgress,
  }) async {
    AppLogger.i(_tag, '========== 开始图片压缩 ==========');
    AppLogger.i(_tag, '输入文件: $inputPath');
    AppLogger.i(_tag, '输出文件: $outputPath');
    AppLogger.i(_tag, '参数: quality=${params.quality}, maxWidth=${params.maxWidth}, maxHeight=${params.maxHeight}');

    // 获取原始文件大小
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      AppLogger.e(_tag, '输入文件不存在：$inputPath');
      throw CompressException('输入文件不存在：$inputPath');
    }
    final originalSize = await inputFile.length();
    AppLogger.i(_tag, '输入文件大小: $originalSize 字节');

    // 使用临时路径进行压缩，避免外部存储权限问题
    // flutter_image_compress 在 Android 11+ 上写入外部存储可能失败
    final tempOutputPath = _getTempOutputPath(outputPath);
    AppLogger.i(_tag, '临时输出路径: $tempOutputPath');

    // 确保临时输出目录存在
    final tempDir = Directory(p.dirname(tempOutputPath));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }

    // 报告开始
    onProgress(const CompressProgress(value: 0.1, info: '正在压缩图片...'));
    AppLogger.i(_tag, '调用 FlutterImageCompress.compressAndGetFile...');

    // 使用 flutter_image_compress 进行压缩
    // minWidth/minHeight: 当原图大于此尺寸时会缩小到此尺寸（相当于最大尺寸限制）
    final result = await FlutterImageCompress.compressAndGetFile(
      inputPath,
      tempOutputPath,
      quality: params.quality,
      minWidth: params.maxWidth ?? 1920,
      minHeight: params.maxHeight ?? 1920,
    );

    if (result == null) {
      AppLogger.e(_tag, '图片压缩失败：未生成输出文件（返回 null）');
      throw CompressException('图片压缩失败：未生成输出文件');
    }

    AppLogger.i(_tag, '临时压缩完成，路径: ${result.path}');

    // 报告完成
    onProgress(const CompressProgress(value: 1.0, info: '压缩完成'));

    // 检查临时文件是否存在
    final compressedTempFile = File(result.path);
    if (!await compressedTempFile.exists()) {
      AppLogger.e(_tag, '临时压缩文件不存在！路径: ${result.path}');
      throw CompressException('图片压缩失败：输出文件不存在');
    }
    final compressedSize = await compressedTempFile.length();

    // 压缩后体积反而增大：保留原始文件
    if (compressedSize >= originalSize) {
      AppLogger.w(_tag, '压缩后体积增大($compressedSize >= $originalSize)，保留原始文件');
      try { await compressedTempFile.delete(); } catch (_) {}
      final finalOutputPath = await _copyToTarget(inputPath, outputPath);
      AppLogger.i(_tag, '已保留原始文件到: $finalOutputPath');
      return CompressResult(
        outputPath: finalOutputPath,
        originalSize: originalSize,
        compressedSize: originalSize,
        durationMs: 0,
      );
    }

    // 将结果复制到用户指定的目标路径（在 Android 11+ 上目标不可写时会自动降级到应用内部存储）
    final finalOutputPath = await _copyToTarget(result.path, outputPath);

    // 清理临时文件
    try {
      await compressedTempFile.delete();
    } catch (_) {}

    AppLogger.i(_tag, '压缩成功! 原始大小: $originalSize -> 压缩后: $compressedSize');

    return CompressResult(
      outputPath: finalOutputPath,
      originalSize: originalSize,
      compressedSize: compressedSize,
      durationMs: 0, // flutter_image_compress 不提供耗时，记 0
    );
  }
}
