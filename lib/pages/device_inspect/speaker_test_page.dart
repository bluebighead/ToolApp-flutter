// 扬声器检测页面
// 检测设备扬声器是否正常工作
// 功能：播放不同频率的测试音调、左右声道检测
// v1.35.0+ 新增
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

class SpeakerTestPage extends StatefulWidget {
  const SpeakerTestPage({super.key});

  @override
  State<SpeakerTestPage> createState() => _SpeakerTestPageState();
}

class _SpeakerTestPageState extends State<SpeakerTestPage> {
  final AudioPlayer _player = AudioPlayer();

  // 当前播放的频率
  int _currentFrequency = 440;
  bool _isPlaying = false;

  // 声道选择
  String _selectedChannel = 'stereo'; // 'left', 'right', 'stereo'

  // 当前生成的WAV文件路径
  String? _wavPath;

  // 检测状态
  String _statusText = '选择测试频率，点击播放开始扬声器检测';

  // 测试结果
  final Map<String, bool> _testResults = {
    '低频 (200Hz)': false,
    '中频 (440Hz)': false,
    '高频 (1000Hz)': false,
    '左声道': false,
    '右声道': false,
    '立体声': false,
  };

  @override
  void dispose() {
    _player.dispose();
    _cleanupWav();
    super.dispose();
  }

  /// 清理临时 WAV 文件
  Future<void> _cleanupWav() async {
    if (_wavPath != null) {
      try {
        final file = File(_wavPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// 生成 WAV 音频数据
  /// [frequency] 音频频率（Hz）
  /// [durationMs] 持续时间（毫秒）
  /// [channel] 声道：'left'/'right'/'stereo'
  Future<String> _generateWav({
    required int frequency,
    int durationMs = 2000,
    String channel = 'stereo',
    double volume = 0.8,
  }) async {
    final sampleRate = 44100;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final data = Int16List(numSamples * 2); // stereo 16-bit

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final sample = (volume * 32767 * sin(2 * pi * frequency * t)).round();

      if (channel == 'left') {
        data[i * 2] = sample; // 左声道
        data[i * 2 + 1] = 0; // 右声道静音
      } else if (channel == 'right') {
        data[i * 2] = 0; // 左声道静音
        data[i * 2 + 1] = sample; // 右声道
      } else {
        data[i * 2] = sample;
        data[i * 2 + 1] = sample;
      }
    }

    // WAV 文件头
    final byteData = ByteData(44 + data.length * 2);
    final dataBytes = data.buffer.asUint8List();

    // RIFF header
    byteData.setUint8(0, 0x52); // R
    byteData.setUint8(1, 0x49); // I
    byteData.setUint8(2, 0x46); // F
    byteData.setUint8(3, 0x46); // F
    byteData.setUint32(4, 36 + dataBytes.length, Endian.little);
    byteData.setUint8(8, 0x57); // W
    byteData.setUint8(9, 0x41); // A
    byteData.setUint8(10, 0x56); // V
    byteData.setUint8(11, 0x45); // E

    // fmt chunk
    byteData.setUint8(12, 0x66); // f
    byteData.setUint8(13, 0x6D); // m
    byteData.setUint8(14, 0x74); // t
    byteData.setUint8(15, 0x20); // space
    byteData.setUint32(16, 16, Endian.little); // chunk size
    byteData.setUint16(20, 1, Endian.little); // PCM
    byteData.setUint16(22, 2, Endian.little); // stereo
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 4, Endian.little); // byte rate
    byteData.setUint16(32, 4, Endian.little); // block align
    byteData.setUint16(34, 16, Endian.little); // bits per sample

    // data chunk
    byteData.setUint8(36, 0x64); // d
    byteData.setUint8(37, 0x61); // a
    byteData.setUint8(38, 0x74); // t
    byteData.setUint8(39, 0x61); // a
    byteData.setUint32(40, dataBytes.length, Endian.little);

    // 复制音频数据
    for (int i = 0; i < dataBytes.length; i++) {
      byteData.setUint8(44 + i, dataBytes[i]);
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/speaker_test_${frequency}hz_$channel.wav';
    final file = File(path);
    await file.writeAsBytes(byteData.buffer.asUint8List());
    return path;
  }

  /// 播放测试音
  Future<void> _playTestTone(int frequency, String channel) async {
    try {
      // 先停止当前播放
      await _player.stop();
      await _cleanupWav();

      setState(() {
        _currentFrequency = frequency;
        _selectedChannel = channel;
        _isPlaying = true;
        _statusText = '正在播放 ${frequency}Hz';
        if (channel == 'left') {
          _statusText += ' (仅左声道)';
        } else if (channel == 'right') {
          _statusText += ' (仅右声道)';
        }
      });

      _wavPath = await _generateWav(
        frequency: frequency,
        channel: channel,
        durationMs: 2500,
      );

      _player.onPlayerComplete.listen((_) async {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _statusText = '播放完成';
          });
          await _cleanupWav();
        }
      });

      await _player.play(DeviceFileSource(_wavPath!));
      AppLogger.i('SpeakerTest', '播放 ${frequency}Hz 测试音 ($channel)');
    } catch (e) {
      AppLogger.e('SpeakerTest', '播放测试音失败: $e');
      setState(() {
        _isPlaying = false;
        _statusText = '播放失败：$e';
      });
    }
  }

  /// 停止播放
  Future<void> _stopPlayback() async {
    await _player.stop();
    await _cleanupWav();
    setState(() {
      _isPlaying = false;
      _statusText = '播放已停止';
    });
  }

  /// 标记测试通过
  void _markTestPassed(String key) {
    setState(() {
      _testResults[key] = true;
      _statusText = '$key 检测通过！';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('扬声器检测'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 状态卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      _isPlaying ? Icons.volume_up : Icons.speaker,
                      size: 64,
                      color: _isPlaying ? Colors.orange : theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '扬声器检测',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 频率测试区域
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '频率测试',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '点击下方按钮播放不同频率的测试音，检查扬声器是否能正常发声',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 12),
                    // 频率按钮
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildFrequencyButton(200, '低频'),
                        _buildFrequencyButton(440, '中频 (A4)'),
                        _buildFrequencyButton(1000, '高频'),
                        _buildFrequencyButton(3000, '超高频'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 停止播放按钮
                    if (_isPlaying)
                      Center(
                        child: TextButton.icon(
                          onPressed: _stopPlayback,
                          icon: const Icon(Icons.stop),
                          label: const Text('停止播放'),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 声道测试区域
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '声道测试',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '分别测试左右声道，确保两个扬声器（如有）均正常工作',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildChannelButton('左声道', 'left', Icons.headphones),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildChannelButton('右声道', 'right', Icons.headset),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildChannelButton('立体声', 'stereo', Icons.surround_sound),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 检测结果
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '检测结果',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 12),
                    ..._testResults.entries.map((entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Icon(
                                entry.value
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                size: 18,
                                color: entry.value ? Colors.green : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                entry.key,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: entry.value ? Colors.black87 : Colors.grey,
                                ),
                              ),
                              if (entry.value) ...[
                                const SizedBox(width: 8),
                                const Text(
                                  '✓ 通过',
                                  style: TextStyle(color: Colors.green, fontSize: 12),
                                ),
                              ],
                            ],
                          ),
                        )),
                    const SizedBox(height: 8),
                    // 一键标记全部通过
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          for (final key in _testResults.keys) {
                            _testResults[key] = true;
                          }
                          _statusText = '所有检测项目已标记为通过';
                        });
                      },
                      icon: const Icon(Icons.done_all, size: 16),
                      label: const Text('全部标记通过'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建频率测试按钮
  Widget _buildFrequencyButton(int frequency, String label) {
    final isCurrent = _isPlaying && _currentFrequency == frequency;
    return OutlinedButton.icon(
      onPressed: _isPlaying ? null : () {
        _playTestTone(frequency, _selectedChannel);
        final key = frequency == 200
            ? '低频 (200Hz)'
            : frequency == 440
                ? '中频 (440Hz)'
                : frequency == 1000
                    ? '高频 (1000Hz)'
                    : '超高频';
        _markTestPassed(key);
      },
      icon: Icon(
        _isPlaying && isCurrent ? Icons.volume_up : Icons.play_arrow,
        size: 16,
      ),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        backgroundColor: isCurrent ? Colors.orange.withValues(alpha: 0.1) : null,
        side: BorderSide(
          color: isCurrent ? Colors.orange : Colors.grey.shade300,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  /// 构建声道测试按钮
  Widget _buildChannelButton(String label, String channel, IconData icon) {
    final isCurrent = _isPlaying && _selectedChannel == channel;
    return OutlinedButton.icon(
      onPressed: _isPlaying ? null : () {
        _playTestTone(440, channel);
        final key = channel == 'left'
            ? '左声道'
            : channel == 'right'
                ? '右声道'
                : '立体声';
        _markTestPassed(key);
      },
      icon: Icon(
        icon,
        size: 16,
        color: isCurrent ? Colors.orange : null,
      ),
      label: Text(
        label,
        style: TextStyle(fontSize: 12),
      ),
      style: OutlinedButton.styleFrom(
        backgroundColor: isCurrent ? Colors.orange.withValues(alpha: 0.1) : null,
        side: BorderSide(
          color: isCurrent ? Colors.orange : Colors.grey.shade300,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
    );
  }
}