import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class PlayfairPage extends StatefulWidget {
  const PlayfairPage({super.key});

  @override
  State<PlayfairPage> createState() => _PlayfairPageState();
}

class _PlayfairPageState extends State<PlayfairPage> {
  final _inputCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  bool _encryptMode = true;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _keyCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  List<List<String>> _buildGrid(String key) {
    final seen = <String>{};
    final chars = <String>[];
    for (final c in '${key.toUpperCase()}ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
      final letter = c == 'J' ? 'I' : c;
      if (RegExp(r'^[A-Z]$').hasMatch(letter) && seen.add(letter)) {
        chars.add(letter);
      }
    }
    return [
      for (int r = 0; r < 5; r++)
        [for (int col = 0; col < 5; col++) chars[r * 5 + col]],
    ];
  }

  String _encrypt(String text, List<List<String>> grid) {
    final pairs = <String>[];
    final clean = text.toUpperCase()
        .replaceAll('J', 'I')
        .replaceAll(RegExp(r'[^A-Z]'), '');
    int i = 0;
    while (i < clean.length) {
      if (i + 1 >= clean.length) {
        pairs.add('${clean[i]}X');
        i++;
      } else if (clean[i] == clean[i + 1]) {
        pairs.add('${clean[i]}X');
        i++;
      } else {
        pairs.add('${clean[i]}${clean[i + 1]}');
        i += 2;
      }
    }
    final result = StringBuffer();
    for (final pair in pairs) {
      result.write(_processPair(pair, grid, true));
    }
    return result.toString();
  }

  String _decrypt(String text, List<List<String>> grid) {
    final pairs = <String>[];
    final clean = text.toUpperCase()
        .replaceAll(RegExp(r'[^A-Z]'), '');
    for (int i = 0; i < clean.length; i += 2) {
      if (i + 1 < clean.length) {
        pairs.add('${clean[i]}${clean[i + 1]}');
      } else {
        pairs.add('${clean[i]}X');
      }
    }
    final result = StringBuffer();
    for (final pair in pairs) {
      result.write(_processPair(pair, grid, false));
    }
    return result.toString();
  }

  String _processPair(String pair, List<List<String>> grid, bool encrypt) {
    int r1 = 0, c1 = 0, r2 = 0, c2 = 0;
    for (int r = 0; r < 5; r++) {
      for (int col = 0; col < 5; col++) {
        if (grid[r][col] == pair[0]) { r1 = r; c1 = col; }
        if (grid[r][col] == pair[1]) { r2 = r; c2 = col; }
      }
    }
    final step = encrypt ? 1 : 4;
    if (r1 == r2) {
      return '${grid[r1][(c1 + step) % 5]}${grid[r2][(c2 + step) % 5]}';
    } else if (c1 == c2) {
      return '${grid[(r1 + step) % 5][c1]}${grid[(r2 + step) % 5][c2]}';
    } else {
      return '${grid[r1][c2]}${grid[r2][c1]}';
    }
  }

  void _convert() {
    setState(() {
      final text = _inputCtrl.text;
      final key = _keyCtrl.text;
      if (text.isEmpty || key.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      final grid = _buildGrid(key);
      _outputCtrl.text = _encryptMode ? _encrypt(text, grid) : _decrypt(text, grid);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('柏拉费密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '柏拉费密码',
              principle: '柏拉费密码（Playfair Cipher）由查尔斯·惠斯通于1854年发明，因推广者莱昂·柏拉费得名。使用一个关键词构建5×5字母方阵（I/J合并为一格），将明文两两分组进行加密。每组字母按方阵规则：同行取右边、同列取下边、不同行列取对角交叉。一战中英军广泛使用。',
              usage: '输入关键词，系统自动生成5×5方阵。在原文区输入文本，选择加密或解密模式，结果自动显示。注意：原文中的J会被替换为I，连续相同字母间会插入X。',
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
            TextField(
              controller: _keyCtrl,
              decoration: InputDecoration(
                labelText: '关键词',
                hintText: '输入关键词…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => _convert(),
            ),
            const SizedBox(height: 12),
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
