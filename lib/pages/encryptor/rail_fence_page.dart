import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class RailFencePage extends StatefulWidget {
  const RailFencePage({super.key});

  @override
  State<RailFencePage> createState() => _RailFencePageState();
}

class _RailFencePageState extends State<RailFencePage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  int _rails = 3;
  bool _encryptMode = true;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty || _rails < 2) {
        _outputCtrl.clear();
        return;
      }
      _outputCtrl.text = _encryptMode ? _encrypt(text, _rails) : _decrypt(text, _rails);
    });
  }

  String _encrypt(String text, int rails) {
    final rows = List.generate(rails, (_) => <int>[]);
    int r = 0;
    int dir = 1;
    for (int i = 0; i < text.length; i++) {
      rows[r].add(i);
      r += dir;
      if (r == 0 || r == rails - 1) dir = -dir;
    }
    final buffer = StringBuffer();
    for (final row in rows) {
      for (final idx in row) {
        buffer.write(text[idx]);
      }
    }
    return buffer.toString();
  }

  String _decrypt(String text, int rails) {
    final rows = List.generate(rails, (_) => <int>[]);
    int r = 0;
    int dir = 1;
    for (int i = 0; i < text.length; i++) {
      rows[r].add(i);
      r += dir;
      if (r == 0 || r == rails - 1) dir = -dir;
    }
    final result = List.generate(text.length, (_) => '');
    int idx = 0;
    for (final row in rows) {
      for (final pos in row) {
        result[pos] = text[idx++];
      }
    }
    return result.join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('栅栏密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '栅栏密码',
              principle: '栅栏密码（Rail Fence Cipher）是一种换位密码，不改变字符本身，而是改变字符的顺序。将原文以Z字形（锯齿形）写在多行"栅栏"上，然后按行读取得到密文。例如3栏加密"HELLO WORLD"：H·L··W·R··→·E·O··O·D→··L··O··L。',
              usage: '选择加密或解密模式，通过滑块调整栏数（2-10），在原文区输入文本后结果自动显示。栏数越多换位越复杂。',
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
                const Text('栏数:', style: TextStyle(fontSize: 14)),
                Expanded(
                  child: Slider(
                    value: _rails.toDouble(),
                    min: 2,
                    max: 10,
                    divisions: 8,
                    label: '$_rails',
                    onChanged: (v) {
                      setState(() {
                        _rails = v.round();
                        _convert();
                      });
                    },
                  ),
                ),
                Container(
                  width: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Text('$_rails',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue[700])),
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
