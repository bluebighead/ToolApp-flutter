import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class HexPage extends StatefulWidget {
  const HexPage({super.key});

  @override
  State<HexPage> createState() => _HexPageState();
}

class _HexPageState extends State<HexPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encodeMode = true;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      try {
        if (_encodeMode) {
          _outputCtrl.text = text.codeUnits.map((c) => c.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
        } else {
          final cleaned = text.replaceAll(RegExp(r'\s+'), '');
          _outputCtrl.text = utf8.decode([
            for (int i = 0; i + 1 < cleaned.length; i += 2)
              int.parse(cleaned.substring(i, i + 2), radix: 16),
          ]);
        }
      } catch (_) {
        _outputCtrl.text = '解码失败，请检查输入格式';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hex 转换'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'Hex 转换',
              principle: '十六进制（Hexadecimal）是一种基数为16的进制表示法，使用0-9和A-F表示数字。Hex转换工具将文本转换为十六进制字节表示（每字节两位十六进制数），或将十六进制字符串还原为原文。常用于查看二进制数据、调试协议报文等场景。',
              usage: '选择编码模式将文本转为Hex，选择解码模式将Hex转回文本。解码时自动忽略空格，输入如"48 65 6C 6C 6F"或"48656C6C6F"均可。',
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
                  selected: {_encodeMode},
                  onSelectionChanged: (v) => setState(() {
                    _encodeMode = v.first;
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
                  labelText: _encodeMode ? '原文' : 'Hex',
                  hintText: _encodeMode ? '输入文本…' : '输入十六进制…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                  filled: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
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
                  labelText: _encodeMode ? 'Hex' : '原文',
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
