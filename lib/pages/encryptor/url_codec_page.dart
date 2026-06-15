import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class UrlCodecPage extends StatefulWidget {
  const UrlCodecPage({super.key});

  @override
  State<UrlCodecPage> createState() => _UrlCodecPageState();
}

class _UrlCodecPageState extends State<UrlCodecPage> {
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
        _outputController.text = Uri.encodeComponent(text);
      } else {
        _outputController.text = Uri.decodeComponent(text);
      }
    } catch (e) {
      _outputController.text = '转换失败: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('URL 编解码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'URL 编解码',
              principle: 'URL编码（Percent-encoding）将URL中的特殊字符转换为%后跟两位十六进制数的格式。例如空格→%20、中文→%E4%BD%A0等。因为URL中只允许ASCII字母、数字和部分特殊符号，其他字符必须被编码。解码则是将%XX序列恢复为原始字符。',
              usage: '选择编码或解码模式，输入文本后自动转换。编码时将特殊字符转为%XX格式，解码时还原。适合处理URL参数中的非ASCII字符。',
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
                  labelText: _isEncoding ? '输入文本' : '输入 URL 编码',
                  hintText: _isEncoding ? '在此输入要编码的文本…' : '在此输入 URL 编码字符串…',
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
                  labelText: _isEncoding ? '编码结果' : '解码结果',
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
