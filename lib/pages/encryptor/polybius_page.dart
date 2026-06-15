import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class PolybiusPage extends StatefulWidget {
  const PolybiusPage({super.key});

  @override
  State<PolybiusPage> createState() => _PolybiusPageState();
}

class _PolybiusPageState extends State<PolybiusPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encryptMode = true;

  static const _grid = [
    ['A', 'B', 'C', 'D', 'E'],
    ['F', 'G', 'H', 'I', 'K'],
    ['L', 'M', 'N', 'O', 'P'],
    ['Q', 'R', 'S', 'T', 'U'],
    ['V', 'W', 'X', 'Y', 'Z'],
  ];

  String _encode(String text) {
    final buffer = StringBuffer();
    for (final c in text.toUpperCase().codeUnits) {
      if (c == 74) {
        buffer.write('24');
        continue;
      }
      if (c < 65 || c > 90) {
        buffer.writeCharCode(c);
        continue;
      }
      for (int r = 0; r < 5; r++) {
        for (int col = 0; col < 5; col++) {
          if (_grid[r][col].codeUnitAt(0) == c) {
            buffer.write('${r + 1}${col + 1}');
          }
        }
      }
    }
    return buffer.toString();
  }

  String _decode(String text) {
    final buffer = StringBuffer();
    final digits = text.replaceAll(RegExp(r'[^1-5]'), '');
    for (int i = 0; i + 1 < digits.length; i += 2) {
      final r = int.parse(digits[i]) - 1;
      final col = int.parse(digits[i + 1]) - 1;
      buffer.write(_grid[r][col]);
    }
    return buffer.toString();
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      _outputCtrl.text = _encryptMode ? _encode(text) : _decode(text);
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('波利比乌斯方阵'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '波利比乌斯方阵',
              principle: '波利比乌斯方阵（Polybius Square）由古希腊历史学家波利比乌斯在公元前2世纪提出。将字母排列在5×5的网格中（I/J合并），每个字母对应一个两位数字：行号+列号（1-5）。最早用于火炬通信系统，通过火把数量传递信息。',
              usage: '选择编码模式将文本转为数字坐标，选择解码模式将数字坐标恢复为文本。页面上方显示5×5参考方阵。注意：字母J会被编码为I（24）。',
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
                    ButtonSegment(value: true, label: Text('编码')),
                    ButtonSegment(value: false, label: Text('解码')),
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
            _buildGrid(),
            const SizedBox(height: 12),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: _encryptMode ? '原文' : '坐标数字',
                  hintText: _encryptMode ? '输入文本…' : '输入数字坐标…',
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

  Widget _buildGrid() {
    return Column(
      children: _grid.map((row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: row.map((c) {
            final idx = _grid.indexOf(row);
            final cidx = row.indexOf(c);
            return Container(
              width: 40,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Text('${idx + 1}${cidx + 1}',
                  style: TextStyle(fontSize: 9, color: Colors.grey[500])),
            );
          }).toList(),
        );
      }).toList(),
    );
  }
}
