import 'dart:convert';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class AesPage extends StatefulWidget {
  const AesPage({super.key});

  @override
  State<AesPage> createState() => _AesPageState();
}

class _AesPageState extends State<AesPage> {
  final _inputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _ivCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encryptMode = true;
  String _keySize = '256';
  String _mode = 'CBC';
  bool _outputBase64 = true;

  static final _rng = Random.secure();

  @override
  void dispose() {
    _inputCtrl.dispose();
    _keyCtrl.dispose();
    _ivCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  void _generateKey() {
    final size = _keySize == '128' ? 16 : (_keySize == '192' ? 24 : 32);
    final key = List<int>.generate(size, (_) => _rng.nextInt(256));
    _keyCtrl.text = base64Encode(key);
    _generateIv();
    _convert();
  }

  void _generateIv() {
    final iv = List<int>.generate(16, (_) => _rng.nextInt(256));
    _ivCtrl.text = base64Encode(iv);
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      try {
        final keyB64 = _keyCtrl.text.trim();
        final ivB64 = _mode == 'ECB' ? '' : _ivCtrl.text.trim();
        if (keyB64.isEmpty || (_mode != 'ECB' && ivB64.isEmpty)) {
          _outputCtrl.text = '请先生成或输入密钥';
          return;
        }
        final key = enc.Key.fromBase64(keyB64);
        final encrypter = enc.Encrypter(
          enc.AES(key, mode: _mode == 'CBC' ? enc.AESMode.cbc : enc.AESMode.ecb),
        );
        if (_encryptMode) {
          final iv = _mode == 'ECB' ? null : enc.IV.fromBase64(ivB64);
          final encrypted = iv != null ? encrypter.encrypt(text, iv: iv) : encrypter.encrypt(text);
          _outputCtrl.text = _outputBase64 ? encrypted.base64 : encrypted.bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
        } else {
          final iv = _mode == 'ECB' ? null : enc.IV.fromBase64(ivB64);
          final data = _outputBase64
              ? enc.Encrypted.fromBase64(text)
              : enc.Encrypted(Uint8List.fromList([
                  for (int i = 0; i + 1 < text.replaceAll(RegExp(r'\s+'), '').length; i += 2)
                    int.parse(text.replaceAll(RegExp(r'\s+'), '').substring(i, i + 2), radix: 16),
                ]));
          final decrypted = iv != null ? encrypter.decrypt(data, iv: iv) : encrypter.decrypt(data);
          _outputCtrl.text = decrypted;
        }
      } catch (e) {
        _outputCtrl.text = '操作失败: $e';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AES 加解密'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'AES 加解密',
              principle: 'AES（Advanced Encryption Standard，高级加密标准）是美国国家标准与技术研究院（NIST）2001年采用的对称加密标准，取代了DES。AES使用Rijndael算法，支持128/192/256位密钥长度。CBC模式需要初始化向量（IV），同一明文每次加密结果不同；ECB模式无需IV，但相同明文得出相同密文，安全性较低。AES-256是目前最广泛使用的加密标准之一。',
              usage: '选择密钥位数（128/192/256）和加密模式（CBC/ECB）。点击"生成密钥"自动生成密钥和IV，也可手动粘贴Base64格式的密钥。输入原文或密文，选择加密/解密模式，结果自动显示。可切换输出格式为Base64或Hex。',
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
                Expanded(
                  child: TextField(
                    controller: _keyCtrl,
                    maxLines: 1,
                    decoration: InputDecoration(
                      labelText: '密钥 (Base64)',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    onChanged: (_) => _convert(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _generateKey,
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '生成密钥',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_mode != 'ECB')
              TextField(
                controller: _ivCtrl,
                decoration: InputDecoration(
                  labelText: 'IV (Base64)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                onChanged: (_) => _convert(),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '128', label: Text('128', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: '192', label: Text('192', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: '256', label: Text('256', style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_keySize},
                  onSelectionChanged: (v) => setState(() {
                    _keySize = v.first;
                  }),
                ),
                const SizedBox(width: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'CBC', label: Text('CBC', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: 'ECB', label: Text('ECB', style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() {
                    _mode = v.first;
                    _convert();
                  }),
                ),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('B64', style: TextStyle(fontSize: 11))),
                    ButtonSegment(value: false, label: Text('Hex', style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_outputBase64},
                  onSelectionChanged: (v) => setState(() {
                    _outputBase64 = v.first;
                    _convert();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _encryptMode ? '原文' : '密文',
                  hintText: _encryptMode ? '输入要加密的文本…' : '输入要解密的密文…',
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
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
