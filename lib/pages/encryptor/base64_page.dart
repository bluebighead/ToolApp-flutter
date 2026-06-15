import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class Base64Page extends StatefulWidget {
  const Base64Page({super.key});

  @override
  State<Base64Page> createState() => _Base64PageState();
}

class _Base64PageState extends State<Base64Page> {
  final _inputController = TextEditingController();
  final _outputController = TextEditingController();
  bool _isEncoding = true;

  @override
  void dispose() {
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  void _convert() {
    final text = _inputController.text;
    if (text.isEmpty) {
      _outputController.clear();
      return;
    }
    try {
      if (_isEncoding) {
        final encoded = base64Encode(utf8.encode(text));
        _outputController.text = encoded;
      } else {
        final decoded = utf8.decode(base64Decode(text));
        _outputController.text = decoded;
      }
    } catch (e) {
      _outputController.text = '转换失败: $e';
    }
  }

  void _swap() {
    final temp = _inputController.text;
    _inputController.text = _outputController.text;
    _outputController.text = temp;
    setState(() {});
  }

  void _clear() {
    _inputController.clear();
    _outputController.clear();
  }

  void _copyOutput() {
    Clipboard.setData(ClipboardData(text: _outputController.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Base64 编解码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'Base64',
              principle: 'Base64 是一种用64个可打印字符（A-Z、a-z、0-9、+、/）来表示二进制数据的编码方式。将每3个字节（24位）分为4组，每组6位，映射到对应的Base64字符。常用于在文本协议中传输二进制数据，如邮件附件、图片的Data URL等。不是加密算法，只是编码。',
              usage: '选择编码或解码模式，输入文本后结果自动显示。编码时将任意文本转为Base64，解码时将Base64字符串恢复为原文本。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('编码', style: TextStyle(fontSize: 13))),
                ButtonSegment(value: false, label: Text('解码', style: TextStyle(fontSize: 13))),
              ],
              selected: {_isEncoding},
              onSelectionChanged: (v) => setState(() {
                _isEncoding = v.first;
                _outputController.clear();
              }),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _inputController,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _isEncoding ? '输入文本' : '输入 Base64',
                  hintText: _isEncoding ? '在此输入要编码的文本…' : '在此输入 Base64 字符串…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (_) => _convert(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filled(onPressed: _swap, icon: const Icon(Icons.swap_vert)),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(onPressed: _clear, icon: const Icon(Icons.clear)),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(onPressed: _copyOutput, icon: const Icon(Icons.copy)),
                ],
              ),
            ),
            Expanded(
              child: TextField(
                controller: _outputController,
                maxLines: null,
                expands: true,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: _isEncoding ? 'Base64 结果' : '解码结果',
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
