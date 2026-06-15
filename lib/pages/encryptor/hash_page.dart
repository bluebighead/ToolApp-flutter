import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class HashPage extends StatefulWidget {
  const HashPage({super.key});

  @override
  State<HashPage> createState() => _HashPageState();
}

class _HashPageState extends State<HashPage> {
  final _inputController = TextEditingController();
  final _md5Ctrl = TextEditingController();
  final _sha1Ctrl = TextEditingController();
  final _sha256Ctrl = TextEditingController();
  final _sha512Ctrl = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    _md5Ctrl.dispose();
    _sha1Ctrl.dispose();
    _sha256Ctrl.dispose();
    _sha512Ctrl.dispose();
    super.dispose();
  }

  void _compute() {
    setState(() {
      final text = _inputController.text;
      if (text.isEmpty) {
        for (final c in [_md5Ctrl, _sha1Ctrl, _sha256Ctrl, _sha512Ctrl]) {
          c.clear();
        }
        return;
      }
      final bytes = utf8.encode(text);
      _md5Ctrl.text = md5.convert(bytes).toString();
      _sha1Ctrl.text = sha1.convert(bytes).toString();
      _sha256Ctrl.text = sha256.convert(bytes).toString();
      _sha512Ctrl.text = sha512.convert(bytes).toString();
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('哈希计算'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '哈希计算',
              principle: '哈希函数（Hash Function）将任意长度的数据映射为固定长度的摘要值。MD5输出128位、SHA1输出160位、SHA256输出256位、SHA512输出512位。哈希是单向的——无法从摘要反推原文。任何微小的输入变化都会导致完全不同的输出（雪崩效应）。常用于文件完整性校验、密码存储等场景。',
              usage: '在输入框中输入文本，下方自动显示MD5、SHA1、SHA256、SHA512四种哈希值。点击每个结果旁的复制按钮可单独复制。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _inputController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '输入文本',
                hintText: '在此输入要计算哈希的文本…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => _compute(),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                children: [
                  _hashRow('MD5', _md5Ctrl, Colors.blue),
                  _hashRow('SHA1', _sha1Ctrl, Colors.teal),
                  _hashRow('SHA256', _sha256Ctrl, Colors.deepOrange),
                  _hashRow('SHA512', _sha512Ctrl, Colors.purple),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hashRow(String label, TextEditingController ctrl, MaterialColor color) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: color.shade200),
                  ),
                  child: Text(label,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color[700])),
                ),
                const Spacer(),
                if (ctrl.text.isNotEmpty)
                  InkWell(
                    onTap: () => _copy(ctrl.text),
                    child: Icon(Icons.copy, size: 16, color: Colors.grey[400]),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              ctrl.text.isEmpty ? '等待输入…' : ctrl.text,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: ctrl.text.isEmpty ? Colors.grey[400] : Colors.grey[800],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
