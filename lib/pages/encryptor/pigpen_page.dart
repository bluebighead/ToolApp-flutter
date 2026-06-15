import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class PigpenPage extends StatefulWidget {
  const PigpenPage({super.key});

  @override
  State<PigpenPage> createState() => _PigpenPageState();
}

class _PigpenPageState extends State<PigpenPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encryptMode = true;

  // Use visible ASCII symbols that look distinct and printable
  static const _symbols = [
    '⊏', '⊐', '⊓', '⊔', '⌐', '¬',
    '⊏̇', '⊐̇', '⊓̇', '⊔̇', '⌐̇', '¬̇',
    '◰', '◳', '◲', '◱', '⬠', '⬡',
    '◰̇', '◳̇', '◲̇', '◱̇', '⬠̇', '⬡̇',
    '⟐', '⧄', '⧅', '⨁',
  ];

  String _toPigpen(String text) {
    final buffer = StringBuffer();
    for (final c in text.toUpperCase().codeUnits) {
      if (c >= 65 && c <= 90) {
        buffer.write(_symbols[c - 65]);
      } else if (c >= 97 && c <= 122) {
        buffer.write(_symbols[c - 97]);
      } else {
        buffer.writeCharCode(c);
      }
    }
    return buffer.toString();
  }

  String _fromPigpen(String text) {
    final map = <String, int>{};
    for (int i = 0; i < 26; i++) {
      map[_symbols[i]] = i;
    }
    final buffer = StringBuffer();
    int i = 0;
    while (i < text.length) {
      if (i + 1 < text.length) {
        final two = text.substring(i, i + 2);
        if (map.containsKey(two)) {
          buffer.writeCharCode(map[two]! + 65);
          i += 2;
          continue;
        }
      }
      final one = text[i];
      if (map.containsKey(one)) {
        buffer.writeCharCode(map[one]! + 65);
      } else {
        buffer.write(one);
      }
      i++;
    }
    return buffer.toString();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      _outputCtrl.text = _encryptMode ? _toPigpen(text) : _fromPigpen(text);
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('猪圈密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '猪圈密码',
              principle: '猪圈密码（Pigpen Cipher），又称共济会密码（Freemason Cipher），在18世纪由共济会成员广泛使用。将字母分成几组放入不同的网格图案中：前两组放入"田"字格（带点表示第二组），后两组放入"X"形格（带点表示第二组）。每个字母对应一个独特的网格符号。',
              usage: '选择编码模式将字母转为猪圈符号，选择解码模式将符号恢复为文本。注意：不同的猪圈密码变体使用的符号映射可能不同，本工具采用标准共济会版本。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Text('模式:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('编码')),
                    ButtonSegment(value: false, label: Text('解码')),
                  ],
                  selected: {_encryptMode},
                  onSelectionChanged: (v) => setState(() {
                    _encryptMode = v.first;
                    _convert();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _encryptMode ? '原文' : '猪圈符号',
                  hintText: _encryptMode ? '输入文本…' : '输入猪圈符号…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (_) => _convert(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  onPressed: () {
                    _inputCtrl.clear();
                    _outputCtrl.clear();
                  },
                  icon: const Icon(Icons.clear),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _outputCtrl.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _outputCtrl,
                maxLines: null,
                expands: true,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: '结果',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
