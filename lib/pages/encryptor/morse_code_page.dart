// 摩斯电码加解密工具
// 支持文本转摩斯电码、摩斯电码转文本
// 支持字母、数字、常见标点符号
// 支持音频播放摩斯电码信号
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../utils/app_logger.dart';

// 摩斯电码映射表：字符 -> 摩斯电码
const Map<String, String> _charToMorse = {
  'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.',
  'F': '..-.', 'G': '--.', 'H': '....', 'I': '..', 'J': '.---',
  'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---',
  'P': '.--.', 'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-',
  'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-', 'Y': '-.--',
  'Z': '--..',
  '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
  '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
  '.': '.-.-.-', ',': '--..--', '?': '..--..', "'": '.----.',
  '!': '-.-.--', '/': '-..-.', '(': '-.--.', ')': '-.--.-',
  '&': '.-...', ':': '---...', ';': '-.-.-.', '=': '-...-',
  '+': '.-.-.', '-': '-....-', '_': '..--.-', '"': '.-..-.',
  r'$': '...-..-', r'@': '.--.-.',
};

// 反向映射表：摩斯电码 -> 字符（由 _charToMorse 自动生成）
final Map<String, String> _morseToChar = {
  for (final entry in _charToMorse.entries) entry.value: entry.key,
};

// 文本转摩斯电码
// 每个字符的摩斯电码之间用空格分隔，单词之间用 " / " 分隔
String textToMorse(String text) {
  final buffer = StringBuffer();
  final words = text.toUpperCase().split(RegExp(r'\s+'));

  var firstWord = true;
  for (final word in words) {
    if (word.isEmpty) continue;
    if (!firstWord) buffer.write(' / ');
    firstWord = false;

    var firstChar = true;
    for (var j = 0; j < word.length; j++) {
      final morse = _charToMorse[word[j]];
      if (morse != null) {
        if (!firstChar) buffer.write(' ');
        firstChar = false;
        buffer.write(morse);
      }
      // 不支持的字符跳过
    }
  }

  return buffer.toString();
}

// 摩斯电码转文本
// 支持空格分隔字符，" / " 分隔单词
// 也可支持连续输入，自动按 "/" 分词
String morseToText(String morse) {
  final buffer = StringBuffer();
  // 按 "/" 分词
  final words = morse.split(RegExp(r'\s*/\s*'));

  for (var i = 0; i < words.length; i++) {
    if (i > 0) buffer.write(' ');
    final word = words[i].trim();
    if (word.isEmpty) continue;
    // 按空格分隔每个字符的摩斯电码
    final codes = word.split(RegExp(r'\s+'));
    for (final code in codes) {
      if (code.isEmpty) continue;
      final char = _morseToChar[code];
      if (char != null) {
        buffer.write(char);
      } else {
        // 无法识别的摩斯电码，用 "?" 占位
        buffer.write('?');
      }
    }
  }

  return buffer.toString();
}

// 摩斯电码音频播放器
// 使用 SystemSound 模拟滴答声（短音=点，长音=划）
class MorsePlayer {
  // 播放状态控制
  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  // 播放摩斯电码音频
  // 使用 HapticFeedback 振动反馈模拟电码信号
  Future<void> play(String morse) async {
    if (_isPlaying) return;
    _isPlaying = true;

    try {
      for (var i = 0; i < morse.length; i++) {
        if (!_isPlaying) break;
        final char = morse[i];
        if (char == '.') {
          // 短信号（点）：轻振动
          await HapticFeedback.lightImpact();
          await Future.delayed(const Duration(milliseconds: 150));
        } else if (char == '-') {
          // 长信号（划）：中等振动
          await HapticFeedback.mediumImpact();
          await Future.delayed(const Duration(milliseconds: 400));
        } else if (char == ' ') {
          // 字符间隔
          await Future.delayed(const Duration(milliseconds: 200));
        } else if (char == '/') {
          // 单词间隔
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      _isPlaying = false;
    }
  }

  // 停止播放
  void stop() {
    _isPlaying = false;
  }
}

class MorseCodePage extends StatefulWidget {
  const MorseCodePage({super.key});

  @override
  State<MorseCodePage> createState() => _MorseCodePageState();
}

class _MorseCodePageState extends State<MorseCodePage> {
  // 输入控制器
  final _inputController = TextEditingController();

  // 当前模式：true=加密（文本→摩斯），false=解密（摩斯→文本）
  bool _isEncryptMode = true;
  // 音频播放器
  final MorsePlayer _morsePlayer = MorsePlayer();
  // 是否显示参考表
  bool _showReference = false;
  // 转换结果文本（手动转换后更新）
  String _outputText = '';

  @override
  void dispose() {
    _morsePlayer.stop();
    _inputController.dispose();
    super.dispose();
  }

  // 手动点击转换按钮执行加解密
  void _convert() {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      setState(() => _outputText = '');
      return;
    }

    if (_isEncryptMode) {
      setState(() => _outputText = textToMorse(input));
    } else {
      setState(() => _outputText = morseToText(input));
    }
    AppLogger.i('MorseCodePage', '执行转换: ${_isEncryptMode ? "加密" : "解密"}');
  }

  // 切换加密/解密模式
  void _toggleMode() {
    setState(() {
      _isEncryptMode = !_isEncryptMode;
      // 切换模式时清空输入输出
      _inputController.clear();
      _outputText = '';
    });
    AppLogger.i('MorseCodePage', '切换模式: ${_isEncryptMode ? "加密" : "解密"}');
  }

  // 复制输出结果到剪贴板
  void _copyOutput() {
    if (_outputText.isEmpty) return;

    Clipboard.setData(ClipboardData(text: _outputText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制到剪贴板'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
    AppLogger.i('MorseCodePage', '复制结果到剪贴板');
  }

  // 清空输入输出
  void _clearInput() {
    _inputController.clear();
    setState(() => _outputText = '');
    AppLogger.i('MorseCodePage', '清空输入');
  }

  // 播放摩斯电码振动信号
  void _playMorse() {
    if (_outputText.isEmpty) return;

    if (_morsePlayer.isPlaying) {
      _morsePlayer.stop();
      setState(() {});
      return;
    }

    _morsePlayer.play(_outputText).then((_) {
      if (mounted) setState(() {});
    });
    setState(() {});
    AppLogger.i('MorseCodePage', '播放摩斯电码振动');
  }

  // 交换输入输出（将输出作为新输入，切换模式）
  void _swapInputOutput() {
    if (_outputText.isEmpty) return;

    setState(() {
      _isEncryptMode = !_isEncryptMode;
      _inputController.text = _outputText;
      _outputText = '';
    });
    AppLogger.i('MorseCodePage', '交换输入输出');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('摩斯电码加解密'),
        actions: [
          // 参考表按钮
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '摩斯电码参考表',
            onPressed: () {
              setState(() {
                _showReference = !_showReference;
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 摩斯电码参考表（可折叠）
          if (_showReference) _buildReferenceTable(theme),
          // 主体内容
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 模式切换
                  _buildModeSwitch(theme),
                  const SizedBox(height: 16),
                  // 输入区
                  _buildInputArea(theme),
                  const SizedBox(height: 12),
                  // 转换按钮
                  FilledButton.icon(
                    onPressed: _convert,
                    icon: const Icon(Icons.transform, size: 20),
                    label: Text(_isEncryptMode ? '加密' : '解密'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 操作按钮行：交换、清空
                  _buildActionButtons(theme),
                  const SizedBox(height: 8),
                  // 输出区
                  _buildOutputArea(theme),
                  const SizedBox(height: 12),
                  // 底部功能按钮：播放、复制
                  _buildFunctionButtons(theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建模式切换：加密 / 解密
  Widget _buildModeSwitch(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // 加密模式标签
          Expanded(
            child: GestureDetector(
              onTap: _isEncryptMode ? null : _toggleMode,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _isEncryptMode
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '加密',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _isEncryptMode
                        ? Colors.white
                        : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          // 解密模式标签
          Expanded(
            child: GestureDetector(
              onTap: _isEncryptMode ? _toggleMode : null,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !_isEncryptMode
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '解密',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: !_isEncryptMode
                        ? Colors.white
                        : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建输入区
  Widget _buildInputArea(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isEncryptMode ? '输入文本' : '输入摩斯电码',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _inputController,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: _isEncryptMode
                ? '输入英文字母、数字，如：HELLO WORLD'
                : '输入摩斯电码，点(.)划(-)空格分隔字符，/ 分隔单词',
            hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.all(12),
          ),
          // 加密模式：只允许字母、数字、空格和常见标点
          // 解密模式：只允许 . - / 和空格
          inputFormatters: _isEncryptMode
              ? [
                  // 只允许 A-Z, a-z, 0-9, 空格, 和常见标点
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 .,?!/()&:;=+\-_"$@]')),
                ]
              : [
                  FilteringTextInputFormatter.allow(RegExp(r'[.\-\/\s]')),
                ],
        ),
        // 使用说明
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _isEncryptMode
                      ? '仅支持英文字母、数字和常见标点，不支持中文等其他字符'
                      : '使用 . 表示点，- 表示划，空格分隔字符，/ 分隔单词',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 构建操作按钮行：交换输入输出、清空
  Widget _buildActionButtons(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // 交换按钮：将输出作为新输入并切换模式
        TextButton.icon(
          onPressed: _swapInputOutput,
          icon: const Icon(Icons.swap_vert, size: 18),
          label: const Text('交换'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        // 清空按钮
        TextButton.icon(
          onPressed: _clearInput,
          icon: const Icon(Icons.clear, size: 18),
          label: const Text('清空'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.grey.shade600,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
      ],
    );
  }

  // 构建输出区
  Widget _buildOutputArea(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isEncryptMode ? '摩斯电码' : '解密文本',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 100),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.grey.shade300,
            ),
          ),
          child: SelectableText(
            _outputText.isEmpty
                ? '转换结果将在此显示'
                : _outputText,
            style: TextStyle(
              fontSize: 15,
              fontFamily: _isEncryptMode ? 'monospace' : null,
              color: _outputText.isEmpty
                  ? Colors.grey.shade400
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  // 构建功能按钮：播放振动、复制
  Widget _buildFunctionButtons(ThemeData theme) {
    final hasOutput = _outputText.isNotEmpty;
    // 仅加密模式下可播放振动（播放摩斯电码信号）
    final canPlay = hasOutput && _isEncryptMode;

    return Row(
      children: [
        // 播放振动按钮
        Expanded(
          child: OutlinedButton.icon(
            onPressed: canPlay ? _playMorse : null,
            icon: Icon(
              _morsePlayer.isPlaying ? Icons.stop : Icons.vibration,
              size: 20,
            ),
            label: Text(_morsePlayer.isPlaying ? '停止' : '振动播放'),
          ),
        ),
        const SizedBox(width: 12),
        // 复制按钮
        Expanded(
          child: FilledButton.icon(
            onPressed: hasOutput ? _copyOutput : null,
            icon: const Icon(Icons.copy, size: 20),
            label: const Text('复制结果'),
          ),
        ),
      ],
    );
  }

  // 构建摩斯电码参考表
  Widget _buildReferenceTable(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 250),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '摩斯电码参考表',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            // 字母表
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _charToMorse.entries
                  .where((e) => RegExp(r'^[A-Z]$').hasMatch(e.key))
                  .map((e) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.grey.shade300,
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          '${e.key} ${e.value}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            // 数字
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _charToMorse.entries
                  .where((e) => RegExp(r'^[0-9]$').hasMatch(e.key))
                  .map((e) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.grey.shade300,
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          '${e.key} ${e.value}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 6),
            Text(
              '字符间用空格分隔，单词间用 / 分隔',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
