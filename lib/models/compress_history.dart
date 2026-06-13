// 压缩历史记录模型
// 记录每次压缩任务的完整信息，包括耗时、压缩前后大小、压缩参数等
class CompressHistory {
  /// 唯一标识
  final String id;

  /// 压缩时间
  final DateTime timestamp;

  /// 压缩类型：video / audio / image
  final String type;

  /// 输入文件路径
  final String inputPath;

  /// 输出文件路径
  final String outputPath;

  /// 原始文件大小（字节）
  final int originalSize;

  /// 压缩后文件大小（字节）
  final int compressedSize;

  /// 压缩耗时（毫秒）
  final int durationMs;

  /// 预设模式名称
  final String preset;

  /// 压缩参数字符串（如 "CRF=23, preset=medium"）
  final String params;

  const CompressHistory({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.inputPath,
    required this.outputPath,
    required this.originalSize,
    required this.compressedSize,
    required this.durationMs,
    required this.preset,
    required this.params,
  });

  /// 压缩率百分比
  double get compressionRatio =>
      originalSize > 0 ? (1 - compressedSize / originalSize) * 100 : 0.0;

  /// 输入文件名
  String get inputFileName => inputPath.split('/').last.split('\\').last;

  /// 输出文件名
  String get outputFileName => outputPath.split('/').last.split('\\').last;

  /// 序列化为 Map
  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'type': type,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'originalSize': originalSize,
        'compressedSize': compressedSize,
        'durationMs': durationMs,
        'preset': preset,
        'params': params,
      };

  /// 从 Map 反序列化
  factory CompressHistory.fromJson(Map<String, dynamic> json) =>
      CompressHistory(
        id: json['id'] as String,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        type: json['type'] as String,
        inputPath: json['inputPath'] as String,
        outputPath: json['outputPath'] as String,
        originalSize: json['originalSize'] as int,
        compressedSize: json['compressedSize'] as int,
        durationMs: json['durationMs'] as int,
        preset: json['preset'] as String,
        params: json['params'] as String,
      );

  /// 格式化类型显示
  String get typeLabel {
    switch (type) {
      case 'video':
        return '视频';
      case 'audio':
        return '音频';
      case 'image':
        return '图片';
      default:
        return type;
    }
  }
}
