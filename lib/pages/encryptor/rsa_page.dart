import 'dart:convert';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart' hide State, Padding;
import 'package:pointycastle/asn1.dart';

import '../../utils/encryptor_help.dart';

class RsaPage extends StatefulWidget {
  const RsaPage({super.key});

  @override
  State<RsaPage> createState() => _RsaPageState();
}

class _RsaPageState extends State<RsaPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  final _pubKeyCtrl = TextEditingController();
  final _privKeyCtrl = TextEditingController();
  bool _encryptMode = true;

  late final FortunaRandom _rng = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    )));

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    _pubKeyCtrl.dispose();
    _privKeyCtrl.dispose();
    super.dispose();
  }

  void _generateKeys() {
    try {
      final keyGen = RSAKeyGenerator()
        ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
          _rng,
        ));
      final pair = keyGen.generateKeyPair();

      final pubKey = pair.publicKey as RSAPublicKey;
      final privKey = pair.privateKey as RSAPrivateKey;

      _pubKeyCtrl.text = _pubKeyToPem(pubKey);
      _privKeyCtrl.text = _privKeyToPem(privKey);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密钥对已生成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('密钥生成失败: $e')),
        );
      }
    }
  }

  String _pubKeyToPem(RSAPublicKey key) {
    final algorithmSeq = ASN1Sequence()
      ..add(ASN1ObjectIdentifier([1, 2, 840, 113549, 1, 1, 1]))
      ..add(ASN1Null());
    final keySeq = ASN1Sequence()
      ..add(ASN1Integer(key.modulus!))
      ..add(ASN1Integer(key.exponent!));
    final topSeq = ASN1Sequence()
      ..add(algorithmSeq)
      ..add(ASN1BitString(stringValues: Uint8List.fromList(keySeq.encode())));
    return '-----BEGIN PUBLIC KEY-----\n${base64Encode(topSeq.encode())}\n-----END PUBLIC KEY-----';
  }

  String _privKeyToPem(RSAPrivateKey key) {
    final seq = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero))
      ..add(ASN1Integer(key.modulus!))
      ..add(ASN1Integer(key.publicExponent!))
      ..add(ASN1Integer(key.privateExponent!))
      ..add(ASN1Integer(key.p!))
      ..add(ASN1Integer(key.q!))
      ..add(ASN1Integer(key.privateExponent! % (key.p! - BigInt.one)))
      ..add(ASN1Integer(key.privateExponent! % (key.q! - BigInt.one)))
      ..add(ASN1Integer(key.q!.modInverse(key.p!)));
    return '-----BEGIN RSA PRIVATE KEY-----\n${base64Encode(seq.encode())}\n-----END RSA PRIVATE KEY-----';
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      try {
        if (_encryptMode) {
          final pubPem = _pubKeyCtrl.text.trim();
          if (pubPem.isEmpty) {
            _outputCtrl.text = '请先生成或输入公钥';
            return;
          }
          final pubKey = enc.RSAKeyParser().parse(pubPem) as RSAPublicKey;
          final encrypter = enc.Encrypter(enc.RSA(publicKey: pubKey));
          final encrypted = encrypter.encrypt(text);
          _outputCtrl.text = encrypted.base64;
        } else {
          final privPem = _privKeyCtrl.text.trim();
          if (privPem.isEmpty) {
            _outputCtrl.text = '请先生成或输入私钥';
            return;
          }
          final privKey = enc.RSAKeyParser().parse(privPem) as RSAPrivateKey;
          final encrypter = enc.Encrypter(enc.RSA(privateKey: privKey));
          final decrypted = encrypter.decrypt(enc.Encrypted.fromBase64(text));
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
        title: const Text('RSA 加解密'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'RSA 加解密',
              principle: 'RSA 是由 Ron Rivest、Adi Shamir 和 Leonard Adleman 在1977年提出的非对称加密算法，以三人姓氏首字母命名。RSA基于大整数分解的数学难题：将两个大质数相乘很容易，但从乘积分解回质数极其困难。公钥用于加密和验证签名，私钥用于解密和签名。RSA-2048是目前推荐的最小安全密钥长度。',
              usage: '点击"生成密钥对"自动生成2048位RSA密钥对。公钥用于加密（可分享给他人），私钥用于解密（必须保密）。加密模式：输入原文，用公钥加密输出Base64密文；解密模式：输入Base64密文，用私钥解密还原原文。',
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
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: _generateKeys,
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '生成密钥对',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _pubKeyCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: '公钥 (PEM)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(8),
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 8),
                onChanged: (_) => _convert(),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _privKeyCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: '私钥 (PEM)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(8),
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 8),
                onChanged: (_) => _convert(),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _encryptMode ? '原文' : '密文 (Base64)',
                  hintText: '输入内容…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (_) => _convert(),
              ),
            ),
            const SizedBox(height: 4),
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
            const SizedBox(height: 4),
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
