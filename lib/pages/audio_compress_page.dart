// 音频压缩页面
// 支持预设模式和高级模式两种压缩方式
// 预设模式提供 快速压缩 / 均衡 / 高质量 三个档位
// 高级模式允许用户手动调节比特率、采样率等参数
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/compress_history.dart';
import '../services/compressor_service.dart';
import '../services/compress_history_service.dart';
import '../utils/app_logger.dart';
import '../utils/saf_helper.dart';
import '../utils/saf_path_memory.dart';
import '../widgets/debug_log_view.dart';

class AudioCompressPage extends StatefulWidget {
  const AudioCompressPage({super.key});

  @override
  State<AudioCompressPage> createState() => _AudioCompressPageState();
}

class _AudioCompressPageState extends State<AudioCompressPage> {
  // 选择的输入文件路径
  String? _inputPath;
  // 输入文件大小（字节）
  int? _inputSize;

  // 预设模式（默认快速压缩）
  CompressPreset _preset = CompressPreset.fast;

  // 是否启用高级模式
  bool _advancedMode = false;
  // 高级模式参数
  int _bitrate = 128;
  int _sampleRate = 44100;

  // 输出路径（默认自动生成）
  String? _outputPath;

  // 压缩状态
  bool _isCompressing = false;
  double _progress = 0;
  String _progressInfo = '';

  // 压缩结果
  CompressResult? _result;
  String? _error;

  // 安全输出目录（应用内部文档目录，Android 11+ 始终可写）
  String _safeOutputDir = '';

  // SAF 自定义输出目录 URI（用户通过 SAF 选择的目录，如 content://...）
  String? _safTreeUri;
  // SAF 自定义输出目录的显示名称
  String? _safDirDisplayName;

  @override
  void initState() {
    super.initState();
    _initSafeOutputDir();
  }

  // 初始化安全输出目录，并加载上次保存的 SAF 自定义路径
  Future<void> _initSafeOutputDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final compressedDir = Directory(p.join(docsDir.path, 'compressed'));
    if (!await compressedDir.exists()) {
      await compressedDir.create(recursive: true);
    }
    // 加载上次保存的 SAF 自定义路径记忆
    final saved = await SafPathMemory.load('audio');
    if (mounted) {
      setState(() {
        _safeOutputDir = compressedDir.path;
        if (saved != null) {
          _safTreeUri = saved['treeUri'];
          _safDirDisplayName = saved['dirDisplayName'];
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音频压缩'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 选择文件区域
            _buildFileSelector(),
            const SizedBox(height: 20),

            // 预设模式选择
            if (!_advancedMode) ...[
              _buildPresetSelector(),
              const SizedBox(height: 16),
            ],

            // 高级模式开关
            _buildAdvancedModeToggle(),
            const SizedBox(height: 16),

            // 高级模式参数
            if (_advancedMode) ...[
              _buildAdvancedParams(),
              const SizedBox(height: 16),
            ],

            // 预估大小
            _buildEstimatedSize(),
            const SizedBox(height: 16),

            // 输出路径
            _buildOutputPathSelector(),
            const SizedBox(height: 20),

            // 压缩按钮
            _buildCompressButton(),
            const SizedBox(height: 20),

            // 进度指示
            if (_isCompressing) _buildProgress(),
            if (_error != null) _buildError(),
            if (_result != null) _buildResult(),
          ],
        ),
      ),
    );
  }

  // 构建文件选择区域
  Widget _buildFileSelector() {
    return Card(
      child: InkWell(
        onTap: _isCompressing ? null : _pickFile,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child:
                    const Icon(Icons.audiotrack, color: Colors.orange, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _inputPath != null
                          ? p.basename(_inputPath!)
                          : '点击选择音频文件',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_inputSize != null)
                      Text(
                        _formatFileSize(_inputSize!),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                  ],
                ),
              ),
              if (_inputPath != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _isCompressing
                      ? null
                      : () => setState(() {
                            _inputPath = null;
                            _inputSize = null;
                            _outputPath = null;
                            _safTreeUri = null;
                            _safDirDisplayName = null;
                            _result = null;
                            _error = null;
                          }),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建预设模式选择器
  Widget _buildPresetSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '压缩模式',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildPresetOption(
              '快速压缩',
              '体积最小',
              CompressPreset.fast,
              Icons.flash_on,
            ),
            const SizedBox(width: 8),
            _buildPresetOption(
              '均衡',
              '音质与体积平衡',
              CompressPreset.balanced,
              Icons.balance,
            ),
            const SizedBox(width: 8),
            _buildPresetOption(
              '高质量',
              '保留较高音质',
              CompressPreset.highQuality,
              Icons.high_quality,
            ),
          ],
        ),
      ],
    );
  }

  // 构建单个预设选项按钮
  Widget _buildPresetOption(
      String label, String subtitle, CompressPreset preset, IconData icon) {
    final isSelected = _preset == preset;
    return Expanded(
      child: GestureDetector(
        onTap: _isCompressing ? null : () => setState(() => _preset = preset),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.orange.withValues(alpha: 0.1)
                : Colors.grey.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? Colors.orange : Colors.grey.shade300,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 24,
                color: isSelected ? Colors.orange : Colors.grey.shade600,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.orange : Colors.grey.shade700,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.grey.shade500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建高级模式开关
  Widget _buildAdvancedModeToggle() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.tune, size: 20, color: Colors.grey),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '高级模式（手动调节参数）',
                style: TextStyle(fontSize: 14),
              ),
            ),
            Switch(
              value: _advancedMode,
              onChanged: _isCompressing
                  ? null
                  : (v) => setState(() => _advancedMode = v),
            ),
          ],
        ),
      ),
    );
  }

  // 构建高级模式参数调节面板
  Widget _buildAdvancedParams() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '手动参数设置',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            // 比特率滑块
            Row(
              children: [
                const SizedBox(
                    width: 80,
                    child: Text('比特率', style: TextStyle(fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: _bitrate.toDouble(),
                    min: 32,
                    max: 320,
                    divisions: 9,
                    label: '${_bitrate}kbps',
                    onChanged: _isCompressing
                        ? null
                        : (v) => setState(() => _bitrate = v.round()),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text('${_bitrate}k',
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
            // 采样率下拉选择
            Row(
              children: [
                const SizedBox(
                    width: 80,
                    child: Text('采样率', style: TextStyle(fontSize: 13))),
                Expanded(
                  child: DropdownButton<int>(
                    value: _sampleRate,
                    isExpanded: true,
                    underline: const SizedBox(),
                    onChanged: _isCompressing
                        ? null
                        : (v) => setState(() => _sampleRate = v ?? 44100),
                    items: [22050, 44100, 48000]
                        .map((rate) => DropdownMenuItem(
                              value: rate,
                              child: Text('${rate ~/ 1000}kHz',
                                  style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 构建预估大小显示
  Widget _buildEstimatedSize() {
    final ratio = _getEstimatedCompressionRatio();
    if (_inputSize == null || ratio == null) return const SizedBox.shrink();
    final estimated = (_inputSize! * ratio).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.auto_graph, size: 20, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '预估压缩后大小：${_formatFileSize(estimated)}（仅供参考）',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建输出路径选择区域
  Widget _buildOutputPathSelector() {
    // SAF 自定义目录优先显示
    String displayPath;
    if (_safTreeUri != null && _safDirDisplayName != null) {
      displayPath = '$_safDirDisplayName/${_getOutputFileName()}';
    } else {
      displayPath = _outputPath ?? _getDefaultOutputPath('m4a');
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              _safTreeUri != null ? Icons.folder_special : Icons.folder_outlined,
              size: 20,
              color: _safTreeUri != null ? Colors.orange : Colors.grey,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('输出路径', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text(
                    displayPath,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _isCompressing ? null : _pickOutputPath,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
              ),
              child: const Text('修改', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  // 获取输出文件名
  String _getOutputFileName() {
    final baseName =
        _inputPath != null ? p.basenameWithoutExtension(_inputPath!) : 'audio';
    return '${baseName}_compressed.m4a';
  }

  // 构建压缩按钮
  Widget _buildCompressButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: _isCompressing || _inputPath == null ? null : _startCompress,
        icon: _isCompressing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.compress),
        label: Text(_isCompressing ? '压缩中...' : '开始压缩'),
      ),
    );
  }

  // 构建进度条
  Widget _buildProgress() {
    return Column(
      children: [
        LinearProgressIndicator(value: _progress),
        const SizedBox(height: 8),
        Text(
          '${(_progress * 100).toStringAsFixed(0)}%${_progressInfo.isNotEmpty ? ' · $_progressInfo' : ''}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  // 构建错误信息
  Widget _buildError() {
    return Column(
      children: [
        Card(
          color: Colors.red.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 压缩失败时显示调试日志，方便排查问题
        DebugLogView(title: '压缩调试日志'),
      ],
    );
  }

  // 构建压缩结果展示
  Widget _buildResult() {
    if (_result == null) return const SizedBox.shrink();
    final r = _result!;
    return Column(
      children: [
        Card(
          color: Colors.green.shade50,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Text('压缩完成',
                        style:
                            TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                _buildResultRow('原始大小', _formatFileSize(r.originalSize)),
                _buildResultRow('压缩后大小', _formatFileSize(r.compressedSize)),
                _buildResultRow('压缩率', '${r.compressionRatio.toStringAsFixed(1)}%'),
                _buildResultRow('输出路径', r.outputPath),
                if (r.durationMs > 0)
                  _buildResultRow('耗时', _formatDuration(r.durationMs)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 压缩完成后显示调试日志，提供复制功能
        DebugLogView(title: '压缩调试日志'),
      ],
    );
  }

  Widget _buildResultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // 选择音频文件
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        if (path != null) {
          final file = File(path);
          final size = await file.length();
          setState(() {
            _inputPath = path;
            _inputSize = size;
            _outputPath = null;
            _result = null;
            _error = null;
          });
        }
      }
    } catch (e) {
      AppLogger.e('AudioCompressPage', '选择文件失败：$e');
    }
  }

  // 选择输出路径（使用 SAF 选择目录，兼容 Android 11+ Scoped Storage）
  Future<void> _pickOutputPath() async {
    try {
      // 使用 SAF 让用户选择输出目录
      final treeUri = await SafHelper.pickDirectory(
        initialUri: SafInitialUris.guessFromFsPath(_inputPath),
      );
      if (treeUri != null) {
        // 从 URI 中提取目录名用于显示
        String dirName = '自定义目录';
        try {
          final lastSegment = Uri.parse(treeUri).pathSegments.lastOrNull;
          if (lastSegment != null) {
            dirName = Uri.decodeComponent(lastSegment.split(':').last);
          }
        } catch (_) {}
        setState(() {
          _safTreeUri = treeUri;
          _safDirDisplayName = dirName;
          _outputPath = null;
        });
        // 持久化保存 SAF 路径记忆
        SafPathMemory.save(type: 'audio', treeUri: treeUri, dirDisplayName: dirName);
      }
    } on PlatformException catch (e) {
      AppLogger.e('AudioCompressPage', 'SAF 选择目录失败：${e.message}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择目录失败：${e.message ?? "未知错误"}')),
        );
      }
    } catch (e) {
      AppLogger.e('AudioCompressPage', '选择输出路径失败：$e');
    }
  }

  // 获取默认输出路径（使用应用内部文档目录，Android 11+ 始终可写）
  String _getDefaultOutputPath(String ext) {
    // 如果安全目录尚未初始化，降级使用系统临时目录
    final home = _safeOutputDir.isNotEmpty ? _safeOutputDir : Directory.systemTemp.path;
    final baseName =
        _inputPath != null ? p.basenameWithoutExtension(_inputPath!) : 'audio';
    return p.join(home, '${baseName}_compressed.$ext');
  }

  // 获取预估压缩率（基于预设或参数）
  double? _getEstimatedCompressionRatio() {
    if (_advancedMode) {
      // 高级模式下根据比特率估算：64k≈0.3, 128k≈0.5, 192k≈0.7, 320k≈0.9
      return 0.1 + _bitrate * 0.0028;
    } else {
      switch (_preset) {
        case CompressPreset.fast:
          return 0.35;
        case CompressPreset.balanced:
          return 0.55;
        case CompressPreset.highQuality:
          return 0.75;
      }
    }
  }

  // 开始压缩
  Future<void> _startCompress() async {
    if (_inputPath == null) return;

    setState(() {
      _isCompressing = true;
      _progress = 0;
      _progressInfo = '';
      _result = null;
      _error = null;
    });

    try {
      // 压缩始终使用应用内部安全目录作为临时输出路径
      final tempOutputPath = _getDefaultOutputPath('m4a');

      // 确定压缩参数
      final params = _advancedMode
          ? AudioCompressParams(
              bitrateK: _bitrate,
              sampleRate: _sampleRate,
            )
          : AudioCompressParams.fromPreset(_preset);

      // 执行压缩（压缩到临时目录）
      final result = await CompressorService.compressAudio(
        inputPath: _inputPath!,
        outputPath: tempOutputPath,
        params: params,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress.value;
              _progressInfo = progress.info;
            });
          }
        },
      );

      // 如果用户选择了 SAF 自定义目录，将压缩后的文件写入 SAF 目录
      String finalOutputPath = result.outputPath;
      if (_safTreeUri != null) {
        try {
          final fileName = _getOutputFileName();
          final safUri = await _writeToSafDirectory(
            _safTreeUri!, fileName, result.outputPath, 'audio/mp4',
          );
          finalOutputPath = '$_safDirDisplayName/$fileName';
          AppLogger.i('AudioCompressPage', '文件已写入 SAF 目录: $safUri');
        } catch (e) {
          AppLogger.e('AudioCompressPage', '写入 SAF 目录失败，使用默认路径：$e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('写入自定义目录失败，文件已保存到应用内部目录')),
            );
          }
        }
      }

      if (mounted) {
        // 更新结果中的输出路径为最终路径
        final finalResult = CompressResult(
          outputPath: finalOutputPath,
          originalSize: result.originalSize,
          compressedSize: result.compressedSize,
          durationMs: result.durationMs,
        );
        setState(() {
          _result = finalResult;
          _isCompressing = false;
          _progress = 1.0;
        });
        // 记录压缩历史
        _recordHistory(finalResult, params);
      }
    } catch (e) {
      AppLogger.e('AudioCompressPage', '压缩失败：$e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isCompressing = false;
        });
      }
    }
  }

  // 通过 SAF 将文件写入用户选择的自定义目录
  Future<String> _writeToSafDirectory(
    String treeUri, String fileName, String srcPath, String mimeType,
  ) async {
    const channel = MethodChannel('com.example.toolapp/storage');
    return await channel.invokeMethod<String>('writeFileToSafTree', {
      'treeUri': treeUri,
      'fileName': fileName,
      'srcPath': srcPath,
      'mimeType': mimeType,
    }) ?? '';
  }

  // 格式化文件大小
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // 格式化耗时
  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}秒';
    final minutes = seconds / 60;
    final secs = seconds % 60;
    return '${minutes.toStringAsFixed(0)}分${secs.toStringAsFixed(0)}秒';
  }

  // 记录压缩历史
  Future<void> _recordHistory(CompressResult result, AudioCompressParams params) async {
    try {
      final presetLabel = _advancedMode ? '高级模式' : _preset.name;
      final paramsStr = _advancedMode
          ? '比特率=$_bitrate kbps, 采样率=$_sampleRate Hz'
          : '${_preset.name}模式';
      final history = CompressHistory(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        type: 'audio',
        inputPath: _inputPath!,
        outputPath: result.outputPath,
        originalSize: result.originalSize,
        compressedSize: result.compressedSize,
        durationMs: result.durationMs,
        preset: presetLabel,
        params: paramsStr,
      );
      await CompressHistoryService.add(history);
    } catch (e) {
      AppLogger.e('AudioCompressPage', '保存历史记录失败：$e');
    }
  }
}
