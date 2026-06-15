import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class SubstitutionPage extends StatefulWidget {
  const SubstitutionPage({super.key});

  @override
  State<SubstitutionPage> createState() => _SubstitutionPageState();
}

class _SubstitutionPageState extends State<SubstitutionPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  bool _encryptMode = true;

  @override
  void initState() {
    super.initState();
    _generateKey();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _generateKey() {
    final chars = _alphabet.split('')..shuffle(Random());
    _keyCtrl.text = chars.join();
    _convert();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      final key = _keyCtrl.text.toUpperCase();
      if (text.isEmpty || key.length != 26) {
        _outputCtrl.clear();
        return;
      }
      final buffer = StringBuffer();
      for (final c in text.codeUnits) {
        if (c >= 65 && c <= 90) {
          final idx = c - 65;
          buffer.write(_encryptMode ? key[idx] : _alphabet[key.indexOf(_alphabet[idx])]);
        } else if (c >= 97 && c <= 122) {
          final idx = c - 97;
          final mapped = _encryptMode ? key[idx] : _alphabet[key.indexOf(_alphabet[idx])];
          buffer.write(mapped.toLowerCase());
        } else {
          buffer.writeCharCode(c);
        }
      }
      _outputCtrl.text = buffer.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('简单替换密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '简单替换密码',
              principle: '简单替换密码（Simple Substitution Cipher）是最经典的替换密码之一。将26个字母随机打乱作为替换表，将原文中的每个字母按替换表映射为另一个字母。理论上共有26!≈4×10²⁶种可能的密钥，但可通过词频分析轻松破解。',
              usage: '系统默认随机生成一个字母替换表，也可手动编辑。点击随机按钮（🎲）生成新的替换表。输入原文后自动加密/解密，支持切换模式。',
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
                    ButtonSegment(value: true, label: Text('加密')),
                    ButtonSegment(value: false, label: Text('解密')),
                  ],
                  selected: {_encryptMode},
                  onSelectionChanged: (v) => setState(() {
                    _encryptMode = v.first;
                    _convert();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keyCtrl,
                    maxLength: 26,
                    decoration: InputDecoration(
                      labelText: '替换字母表 (26 字母不重复)',
                      hintText: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.all(12),
                      isDense: true,
                      counterText: '',
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    onChanged: (_) => _convert(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _generateKey,
                  icon: const Icon(Icons.shuffle, size: 20),
                  tooltip: '随机生成',
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
                  labelText: '原文',
                  hintText: '输入文本…',
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
              flex: 1,
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
