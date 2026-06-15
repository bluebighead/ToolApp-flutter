import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class UnicodePage extends StatefulWidget {
  const UnicodePage({super.key});

  @override
  State<UnicodePage> createState() => _UnicodePageState();
}

class _UnicodePageState extends State<UnicodePage> {
  final _inputController = TextEditingController();
  final _outputController = TextEditingController();
  bool _isEncoding = true;

  @override
  void dispose() {
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  // Unicode 编解码核心算法
  // 编码：将每个字符转为 \uXXXX 格式（支持 BMP 以外字符，码点超过4位时补齐至实际位数）
  // 解码：将 \uXXXX 格式转回字符（支持4位及以上的十六进制码点）
  void _convert() {
    final text = _inputController.text;
    if (text.isEmpty) {
      _outputController.clear();
      return;
    }
    try {
      if (_isEncoding) {
        // 编码：遍历所有 Unicode 码点（runes），转为 \uXXXX 格式
        _outputController.text = text.runes.map((r) {
          final hex = r.toRadixString(16);
          // BMP 字符（U+0000 ~ U+FFFF）补齐4位，BMP 以外字符补齐至实际位数（至少4位）
          final padded = hex.padLeft(hex.length <= 4 ? 4 : hex.length, '0');
          return '\\u$padded';
        }).join();
      } else {
        // 解码：匹配 \u 后跟4位及以上十六进制数字
        _outputController.text = text.replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4,})'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
        );
      }
    } catch (e) {
      _outputController.text = '转换失败: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unicode 编解码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'Unicode 编解码',
              principle: 'Unicode是一种字符编码标准，为每个字符分配唯一的码点（Code Point）。\\uXXXX格式使用4位十六进制表示码点（U+0000~U+FFFF），\\UXXXXXXXX格式使用8位十六进制表示扩展字符（U+10000及以上）。编解码工具在字符和转义序列之间互相转换。',
              usage: '选择编码或解码模式。编码时将文本转为\\uXXXX转义序列，解码时将转义序列恢复为可读文本。支持基本多语言平面（BMP）字符。',
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
                  labelText: _isEncoding ? '输入文本' : '输入 Unicode 编码',
                  hintText: _isEncoding ? '例如: 你好 😀' : '例如: \\u4f60\\u597d\\u1f600',
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
                  IconButton.filled(onPressed: () {
                    final temp = _inputController.text;
                    _inputController.text = _outputController.text;
                    _outputController.text = temp;
                    setState(() {});
                  }, icon: const Icon(Icons.swap_vert)),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(onPressed: () {
                    _inputController.clear();
                    _outputController.clear();
                  }, icon: const Icon(Icons.clear)),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(onPressed: () {
                    Clipboard.setData(ClipboardData(text: _outputController.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制')),
                    );
                  }, icon: const Icon(Icons.copy)),
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
                  labelText: _isEncoding ? 'Unicode 编码结果' : '解码结果',
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
