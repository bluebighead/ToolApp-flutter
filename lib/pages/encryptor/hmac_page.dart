import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class HmacPage extends StatefulWidget {
  const HmacPage({super.key});

  @override
  State<HmacPage> createState() => _HmacPageState();
}

class _HmacPageState extends State<HmacPage> {
  final _inputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _md5Ctrl = TextEditingController();
  final _sha1Ctrl = TextEditingController();
  final _sha256Ctrl = TextEditingController();
  final _sha512Ctrl = TextEditingController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    _keyCtrl.dispose();
    _md5Ctrl.dispose();
    _sha1Ctrl.dispose();
    _sha256Ctrl.dispose();
    _sha512Ctrl.dispose();
    super.dispose();
  }

  void _compute() {
    setState(() {
      final text = _inputCtrl.text;
      final key = _keyCtrl.text;
      if (text.isEmpty || key.isEmpty) {
        for (final c in [_md5Ctrl, _sha1Ctrl, _sha256Ctrl, _sha512Ctrl]) {
          c.clear();
        }
        return;
      }
      final data = utf8.encode(text);
      final k = utf8.encode(key);
      _md5Ctrl.text = Hmac(md5, k).convert(data).toString();
      _sha1Ctrl.text = Hmac(sha1, k).convert(data).toString();
      _sha256Ctrl.text = Hmac(sha256, k).convert(data).toString();
      _sha512Ctrl.text = Hmac(sha512, k).convert(data).toString();
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HMAC 计算'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'HMAC 计算',
              principle: 'HMAC（Hash-based Message Authentication Code，基于哈希的消息认证码）使用密钥和哈希函数共同计算消息的认证标记。HMAC结合了密钥与消息，通过两次哈希运算确保只有持有密钥的人才能验证消息完整性。公式：HMAC(K,m)=H((K′⊕opad)∥H((K′⊕ipad)∥m))。',
              usage: '输入消息文本和密钥，下方自动显示 HMAC-MD5、HMAC-SHA1、HMAC-SHA256、HMAC-SHA512 四种结果。点击结果旁的复制按钮可单独复制。',
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
              onChanged: (_) => _compute(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inputCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '输入文本',
                hintText: '在此输入消息文本…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => _compute(),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                children: [
                  _resultRow('HMAC-MD5', _md5Ctrl, Colors.blue),
                  _resultRow('HMAC-SHA1', _sha1Ctrl, Colors.teal),
                  _resultRow('HMAC-SHA256', _sha256Ctrl, Colors.deepOrange),
                  _resultRow('HMAC-SHA512', _sha512Ctrl, Colors.purple),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(String label, TextEditingController ctrl, MaterialColor color) {
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
