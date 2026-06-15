import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class RadixPage extends StatefulWidget {
  const RadixPage({super.key});

  @override
  State<RadixPage> createState() => _RadixPageState();
}

class _RadixPageState extends State<RadixPage> {
  final _inputCtrl = TextEditingController();
  final _binCtrl = TextEditingController();
  final _octCtrl = TextEditingController();
  final _decCtrl = TextEditingController();
  final _hexCtrl = TextEditingController();
  int _inputRadix = 10;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _binCtrl.dispose();
    _octCtrl.dispose();
    _decCtrl.dispose();
    _hexCtrl.dispose();
    super.dispose();
  }

  void _convert(String _) {
    setState(() {
      for (final c in [_binCtrl, _octCtrl, _decCtrl, _hexCtrl]) {
        c.clear();
      }
      final text = _inputCtrl.text.trim();
      if (text.isEmpty) return;

      try {
        final value = BigInt.parse(text, radix: _inputRadix);
        _binCtrl.text = value.toRadixString(2);
        _octCtrl.text = value.toRadixString(8);
        _decCtrl.text = value.toRadixString(10);
        _hexCtrl.text = value.toRadixString(16).toUpperCase();
      } catch (_) {}
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
        title: const Text('进制转换'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '进制转换',
              principle: '进制是数字的表示方式。日常生活中使用十进制（基数为10），计算机使用二进制（基数为2），编程中常用八进制（8）和十六进制（16）。不同进制间通过基数展开和重复取余进行转换。例如十进制42的二进制是101010，十六进制是2A。',
              usage: '先选择输入的进制（2/8/10/16），然后在输入框中输入对应进制的数值，下方自动转换为其他三种进制的结果。点击每个结果旁的复制按钮可单独复制。',
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
                const Text('输入进制: ', style: TextStyle(fontSize: 14)),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 2, label: Text('2', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 8, label: Text('8', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 10, label: Text('10', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 16, label: Text('16', style: TextStyle(fontSize: 12))),
                  ],
                  selected: {_inputRadix},
                  onSelectionChanged: (v) => setState(() {
                    _inputRadix = v.first;
                    _inputCtrl.clear();
                    for (final c in [_binCtrl, _octCtrl, _decCtrl, _hexCtrl]) {
                      c.clear();
                    }
                  }),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inputCtrl,
              decoration: InputDecoration(
                labelText: '输入数值',
                hintText: '输入${_inputRadix}进制数值…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _inputCtrl.clear();
                    for (final c in [_binCtrl, _octCtrl, _decCtrl, _hexCtrl]) {
                      c.clear();
                    }
                  },
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              onChanged: _convert,
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                children: [
                  _resultRow('二进制', _binCtrl, Colors.blue),
                  _resultRow('八进制', _octCtrl, Colors.teal),
                  _resultRow('十进制', _decCtrl, Colors.deepOrange),
                  _resultRow('十六进制', _hexCtrl, Colors.purple),
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
                fontSize: 14,
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
