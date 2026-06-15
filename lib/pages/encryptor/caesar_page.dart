import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class CaesarPage extends StatefulWidget {
  const CaesarPage({super.key});

  @override
  State<CaesarPage> createState() => _CaesarPageState();
}

class _CaesarPageState extends State<CaesarPage> {
  final _inputController = TextEditingController();
  final _outputController = TextEditingController();
  int _shift = 3;
  // true=加密（正向位移），false=解密（反向位移）
  bool _isEncrypt = true;

  @override
  void dispose() {
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  // 凯撒密码核心算法
  // 加密：字符正向位移 shift 位
  // 解密：字符反向位移 shift 位（即正向位移 26-shift / 10-shift）
  void _convert() {
    setState(() {
      final text = _inputController.text;
      if (text.isEmpty) {
        _outputController.clear();
        return;
      }
      // 解密时偏移量取反
      final effectiveShift = _isEncrypt ? _shift : (26 - _shift);
      final effectiveDigitShift = _isEncrypt ? _shift : (10 - _shift % 10);

      final buffer = StringBuffer();
      for (final c in text.codeUnits) {
        if (c >= 65 && c <= 90) {
          // 大写字母 A-Z：位移 26 取模
          buffer.writeCharCode((c - 65 + effectiveShift) % 26 + 65);
        } else if (c >= 97 && c <= 122) {
          // 小写字母 a-z：位移 26 取模
          buffer.writeCharCode((c - 97 + effectiveShift) % 26 + 97);
        } else if (c >= 48 && c <= 57) {
          // 数字 0-9：位移 10 取模
          buffer.writeCharCode((c - 48 + effectiveDigitShift) % 10 + 48);
        } else {
          // 其他字符不处理
          buffer.writeCharCode(c);
        }
      }
      _outputController.text = buffer.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('凯撒密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '凯撒密码',
              principle: '凯撒密码（Caesar Cipher）是古罗马统治者尤利乌斯·凯撒使用的一种替换密码。通过将字母表中的每个字母按照固定数目进行位移来实现加密。例如偏移量为3时，A→D、B→E、C→F……X→A。属于单表替换密码，仅有25种可能的偏移，极易被暴力破解。',
              usage: '通过滑块调整偏移量（1-25），在上方输入原文，下方自动输出加密/解密结果。加密和解密使用同一偏移量，解密时反向偏移即可。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 加密/解密模式切换
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('加密', style: TextStyle(fontSize: 13))),
                ButtonSegment(value: false, label: Text('解密', style: TextStyle(fontSize: 13))),
              ],
              selected: {_isEncrypt},
              onSelectionChanged: (v) => setState(() {
                _isEncrypt = v.first;
                _convert();
              }),
            ),
            const SizedBox(height: 12),
            // 偏移量滑块
            Row(
              children: [
                const Text('偏移量: ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                Expanded(
                  child: Slider(
                    value: _shift.toDouble(),
                    min: 1,
                    max: 25,
                    divisions: 24,
                    label: '$_shift',
                    onChanged: (v) => setState(() {
                      _shift = v.round();
                      _convert();
                    }),
                  ),
                ),
                Container(
                  width: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Text('$_shift',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue[700])),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputController,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _isEncrypt ? '原文' : '密文',
                  hintText: _isEncrypt ? '请输入要加密的文本…' : '请输入要解密的密文…',
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
                // 交换输入输出
                IconButton.filled(
                  onPressed: () {
                    final temp = _inputController.text;
                    _inputController.text = _outputController.text;
                    _outputController.text = temp;
                    setState(() {
                      _isEncrypt = !_isEncrypt;
                    });
                  },
                  icon: const Icon(Icons.swap_vert),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: () {
                    _inputController.clear();
                    _outputController.clear();
                  },
                  icon: const Icon(Icons.clear),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _outputController.text));
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
                controller: _outputController,
                maxLines: null,
                expands: true,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: _isEncrypt ? '密文' : '原文',
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
