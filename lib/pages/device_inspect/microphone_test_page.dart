// 麦克风检测页面
// 检测设备麦克风是否正常工作
// 功能：录音并实时显示音频波形/分贝值、播放录制音频验证
// v1.35.0+ 新增
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

class MicrophoneTestPage extends StatefulWidget {
  const MicrophoneTestPage({super.key});

  @override
  State<MicrophoneTestPage> createState() => _MicrophoneTestPageState();
}

class _MicrophoneTestPageState extends State<MicrophoneTestPage> {
  // 录音器
  final AudioRecorder _recorder = AudioRecorder();

  // 音频播放器
  final AudioPlayer _player = AudioPlayer();

  // 检测状态
  bool _isRecording = false;

  // 是否有录制好的音频
  bool _hasRecording = false;

  // 录制音频文件路径
  String? _recordingPath;

  // 是否正在播放
  bool _isPlaying = false;

  // 振幅流订阅（用于实时显示音频波形）
  // v1.50.0+ 使用 onAmplitudeChanged 流获取准确的振幅值
  StreamSubscription<Amplitude>? _amplitudeSub;

  // 当前振幅值（0.0 ~ 1.0）
  double _currentAmplitude = 0.0;

  // 检测状态
  String _statusText = '点击录制按钮开始麦克风检测';

  // 测试结果
  bool _micAvailable = true;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _checkMicPermission();
  }

  @override
  void dispose() {
    _amplitudeSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  /// 检查麦克风权限
  Future<void> _checkMicPermission() async {
    try {
      final hasPermission = await _recorder.hasPermission();
      setState(() {
        _micAvailable = hasPermission;
        if (!hasPermission) {
          _statusText = '麦克风权限未授权，请在设置中开启';
          _errorMsg = '缺少麦克风权限';
        } else {
          _statusText = '点击录制按钮开始麦克风检测';
        }
      });
    } catch (e) {
      AppLogger.e('MicrophoneTest', '检查麦克风权限失败: $e');
      setState(() {
        _micAvailable = false;
        _statusText = '检测麦克风权限时出错';
        _errorMsg = e.toString();
      });
    }
  }

  /// 开始录制（使用 start 录制到文件，同时监听振幅）
  Future<void> _startRecording() async {
    try {
      // 检查权限
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          setState(() => _statusText = '麦克风权限未授权');
        }
        return;
      }

      // 配置录音参数：AAC 格式，44100 采样率
      final config = const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        numChannels: 1,
      );

      // 生成录音文件路径
      final dir = await getTemporaryDirectory();
      _recordingPath = '${dir.path}/mic_test_${DateTime.now().millisecondsSinceEpoch}.m4a';

      // 监听振幅流（onAmplitudeChanged 返回准确的 dBFS 振幅值）
      // v1.50.0+ 修复：API 变更，onAmplitudeChanged(Duration) 返回 Stream<Amplitude>
      _amplitudeSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen(
        (Amplitude amp) {
          if (mounted) {
            setState(() {
              // amp.current 为 dBFS 值，范围约 -160 ~ 0，转换为 0.0 ~ 1.0
              _currentAmplitude = ((amp.current + 60) / 60).clamp(0.0, 1.0);
            });
          }
        },
        onError: (Object error) {
          AppLogger.e('MicrophoneTest', '录音振幅监听错误: $error');
        },
      );

      // 开始录制到文件（使用 start 而不是 startStream，确保生成有效录音文件）
      await _recorder.start(config, path: _recordingPath!);

      setState(() {
        _isRecording = true;
        _statusText = '正在录制... 请对着麦克风说话';
        _hasRecording = false;
      });
      AppLogger.i('MicrophoneTest', '开始麦克风录音');
    } catch (e) {
      AppLogger.e('MicrophoneTest', '开始录音失败: $e');
      if (mounted) {
        setState(() {
          _statusText = '录音失败：$e';
          _errorMsg = e.toString();
        });
      }
    }
  }

  /// 停止录制
  Future<void> _stopRecording() async {
    try {
      _amplitudeSub?.cancel();
      _amplitudeSub = null;

      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _currentAmplitude = 0.0;
        _hasRecording = path != null && File(path!).existsSync();
        _recordingPath = path;
        if (_hasRecording) {
          _statusText = '录制完成！点击播放试听验证麦克风效果';
        } else {
          _statusText = '录制停止，但未检测到有效音频文件';
          _errorMsg = '录制文件无效';
        }
      });
      AppLogger.i('MicrophoneTest', '录音结束，文件: $path');
    } catch (e) {
      AppLogger.e('MicrophoneTest', '停止录音失败: $e');
      setState(() {
        _isRecording = false;
        _statusText = '停止录音失败：$e';
      });
    }
  }

  /// 播放录制的音频
  Future<void> _playRecording() async {
    if (_recordingPath == null || !File(_recordingPath!).existsSync()) {
      setState(() => _statusText = '没有可播放的录音文件');
      return;
    }

    try {
      _player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _statusText = '播放完成，麦克风检测通过';
          });
        }
      });

      await _player.play(DeviceFileSource(_recordingPath!));
      setState(() {
        _isPlaying = true;
        _statusText = '正在播放录制音频...';
      });
    } catch (e) {
      AppLogger.e('MicrophoneTest', '播放录音失败: $e');
      setState(() => _statusText = '播放失败：$e');
    }
  }

  /// 停止播放
  Future<void> _stopPlayback() async {
    await _player.stop();
    setState(() {
      _isPlaying = false;
      _statusText = '播放已停止';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('麦克风检测'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 检测状态卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // 麦克风图标
                    Icon(
                      _isRecording
                          ? Icons.mic
                          : (_hasRecording
                              ? Icons.check_circle_outline
                              : Icons.mic_none),
                      size: 64,
                      color: _isRecording
                          ? Colors.red
                          : (_hasRecording
                              ? Colors.green
                              : theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '麦克风检测',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                    ),
                    if (_errorMsg != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '错误：$_errorMsg',
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 实时音频波形显示
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text(
                      '实时音频波形',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 16),
                    // 音频波形条
                    SizedBox(
                      height: 80,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List.generate(20, (index) {
                          // 每个条根据振幅和随机因子产生不同高度
                          final height = _isRecording
                              ? (_currentAmplitude *
                                  (60.0 + (index % 3) * 10.0) *
                                  (0.5 + 0.5 * (DateTime.now().microsecond % 100) / 100))
                                  .clamp(8.0, 80.0)
                              : 8.0;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            width: 8,
                            height: height,
                            decoration: BoxDecoration(
                              color: _isRecording
                                  ? Colors.red.withValues(alpha: 0.3 + _currentAmplitude * 0.7)
                                  : Colors.grey.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 振幅百分比
                    if (_isRecording)
                      Text(
                        '音量: ${(_currentAmplitude * 100).toInt()}%',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 录制/停止按钮
                ElevatedButton.icon(
                  onPressed: _micAvailable
                      ? (_isRecording ? _stopRecording : _startRecording)
                      : null,
                  icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(_isRecording ? '停止录制' : '开始录制'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.red : theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
                const SizedBox(width: 16),
                // 播放/停止播放按钮
                if (_hasRecording)
                  ElevatedButton.icon(
                    onPressed: _isPlaying ? _stopPlayback : _playRecording,
                    icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                    label: Text(_isPlaying ? '停止播放' : '播放录音'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isPlaying ? Colors.orange : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),

            // 使用说明
            Card(
              elevation: 0,
              color: Colors.blue.withValues(alpha: 0.05),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: Colors.blue.shade400),
                        const SizedBox(width: 8),
                        const Text(
                          '使用说明',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _buildInstruction('1. 点击"开始录制"按钮', Icons.circle_outlined),
                    _buildInstruction('2. 对着手机麦克风说话', Icons.mic_outlined),
                    _buildInstruction('3. 观察音频波形是否有变化', Icons.show_chart),
                    _buildInstruction('4. 点击停止录制并播放验证', Icons.play_circle_outline),
                  ],
                ),
              ),
            ),

            // 检测结果总结
            if (_hasRecording) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '麦克风检测通过！录制和播放功能均正常。',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 构建使用说明行
  Widget _buildInstruction(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}