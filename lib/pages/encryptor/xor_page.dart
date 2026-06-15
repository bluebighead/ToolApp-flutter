import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class XorPage extends StatefulWidget {
  const XorPage({super.key});

  @override
  State<XorPage> createState() => _XorPageState();
}

class _XorPageState extends State<XorPage> {
  final _inputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _outputAsHex = false;

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
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      final bytes = utf8.encode(text);
      if (key.isEmpty) {
        if (_outputAsHex) {
          _outputCtrl.text = bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
        } else {
          _outputCtrl.text = utf8.decode(bytes);
        }
        return;
      }
      final keyBytes = utf8.encode(key);
      final result = List<int>.generate(bytes.length, (i) => bytes[i] ^ keyBytes[i % keyBytes.length]);
      if (_outputAsHex) {
        _outputCtrl.text = result.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
      } else {
        _outputCtrl.text = utf8.decode(result);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('XOR 加密'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'XOR 加密',
              principle: 'XOR（异或）加密是一种对称加密算法，使用同一密钥进行加密和解密。将明文每个字节与密钥的对应字节进行异或运算：A⊕B⊕B=A。密钥可循环使用，安全性取决于密钥长度和随机性。虽然简单，但一次性密钥簿（OTP）在理论上是不可破解的。',
              usage: '输入原文和密钥，结果自动显示。XOR 是自反的：对结果再次使用相同密钥即可还原原文。可切换输出格式为文本或十六进制。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _keyCtrl,
              decoration: InputDecoration(
                labelText: '密钥',
                hintText: '输入密钥…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => _convert(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('输出格式:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('文本')),
                    ButtonSegment(value: true, label: Text('Hex')),
                  ],
                  selected: {_outputAsHex},
                  onSelectionChanged: (v) => setState(() {
                    _outputAsHex = v.first;
                    _convert();
                  }),
                ),
              ],
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
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
