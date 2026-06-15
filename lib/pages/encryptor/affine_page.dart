import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class AffinePage extends StatefulWidget {
  const AffinePage({super.key});

  @override
  State<AffinePage> createState() => _AffinePageState();
}

class _AffinePageState extends State<AffinePage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  int _a = 1;
  int _b = 0;
  bool _encryptMode = true;
  static const _validA = [1, 3, 5, 7, 9, 11, 15, 17, 19, 21, 23, 25];

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  int _modInverse(int a) {
    for (final v in _validA) {
      if ((a * v) % 26 == 1) return v;
    }
    return 1;
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      final buffer = StringBuffer();
      for (final c in text.codeUnits) {
        if (c >= 65 && c <= 90) {
          final x = c - 65;
          final result = _encryptMode
              ? (_a * x + _b) % 26
              : (_modInverse(_a) * (x - _b + 26)) % 26;
          buffer.writeCharCode(result + 65);
        } else if (c >= 97 && c <= 122) {
          final x = c - 97;
          final result = _encryptMode
              ? (_a * x + _b) % 26
              : (_modInverse(_a) * (x - _b + 26)) % 26;
          buffer.writeCharCode(result + 97);
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
        title: const Text('仿射密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '仿射密码',
              principle: '仿射密码（Affine Cipher）是一种基于数学运算的替换密码。加密公式：E(x) = (ax + b) mod 26，其中x是字母编号（A=0~Z=25），a和b为密钥参数。要求a必须与26互质（即gcd(a,26)=1），这样解密时才能通过模逆元还原原文。仿射密码共有12×26=312种密钥组合。',
              usage: '选择加密或解密模式，通过滑块调整a（乘数，可选1,3,5,7,9,11,15,17,19,21,23,25）和b（位移量，0-25）。输入原文后结果自动显示。',
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
                const Text('a (乘数):', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: _validA.indexOf(_a).toDouble(),
                    min: 0,
                    max: _validA.length - 1,
                    divisions: _validA.length - 1,
                    label: '$_a',
                    onChanged: (v) {
                      setState(() {
                        _a = _validA[v.round()];
                        _convert();
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('$_a', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue[700])),
                ),
              ],
            ),
            Row(
              children: [
                const Text('b (位移):', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: _b.toDouble(),
                    min: 0,
                    max: 25,
                    divisions: 25,
                    label: '$_b',
                    onChanged: (v) {
                      setState(() {
                        _b = v.round();
                        _convert();
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('$_b', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal[700])),
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
