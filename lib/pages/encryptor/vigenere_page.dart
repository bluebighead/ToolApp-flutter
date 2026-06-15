import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class VigenerePage extends StatefulWidget {
  const VigenerePage({super.key});

  @override
  State<VigenerePage> createState() => _VigenerePageState();
}

class _VigenerePageState extends State<VigenerePage> {
  final _inputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encryptMode = true;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _keyCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      final key = _keyCtrl.text;
      if (text.isEmpty || key.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      final keyUpper = key.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
      if (keyUpper.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      final buffer = StringBuffer();
      int ki = 0;
      for (final c in text.codeUnits) {
        if (c >= 65 && c <= 90) {
          final shift = keyUpper.codeUnitAt(ki % keyUpper.length) - 65;
          final result = _encryptMode
              ? (c - 65 + shift) % 26
              : (c - 65 - shift + 26) % 26;
          buffer.writeCharCode(result + 65);
          ki++;
        } else if (c >= 97 && c <= 122) {
          final shift = keyUpper.codeUnitAt(ki % keyUpper.length) - 65;
          final result = _encryptMode
              ? (c - 97 + shift) % 26
              : (c - 97 - shift + 26) % 26;
          buffer.writeCharCode(result + 97);
          ki++;
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
        title: const Text('维吉尼亚密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '维吉尼亚密码',
              principle: '维吉尼亚密码（Vigenère Cipher）由法国外交官布莱斯·德·维吉尼亚在16世纪提出，是第一个多表替换密码。使用一个关键词决定每个字母的位移量：关键词中的每个字母对应一个凯撒位移（A=0, B=1, …, Z=25），对原文中对应位置的字母进行位移。即使相同的字母也会被加密为不同字符，大大增强了安全性。',
              usage: '先输入关键词（仅字母有效），然后在原文区输入文本，选择加密或解密模式，结果自动显示。关键词越长越安全，建议使用不含重复字母的单词。',
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
            TextField(
              controller: _keyCtrl,
              decoration: InputDecoration(
                labelText: '关键词',
                hintText: '输入关键词…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => _convert(),
            ),
            const SizedBox(height: 12),
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
