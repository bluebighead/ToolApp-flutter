import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class TextToolsPage extends StatefulWidget {
  const TextToolsPage({super.key});

  @override
  State<TextToolsPage> createState() => _TextToolsPageState();
}

class _TextToolsPageState extends State<TextToolsPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();
  String _action = '大写';

  static const _actions = ['大写', '小写', '首字母大写', '反转', '反转单词', '移除空格', '统计信息'];

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  void _process() {
    setState(() {
      final text = _inputCtrl.text;
      if (text.isEmpty) {
        _outputCtrl.clear();
        return;
      }
      switch (_action) {
        case '大写':
          _outputCtrl.text = text.toUpperCase();
        case '小写':
          _outputCtrl.text = text.toLowerCase();
        case '首字母大写':
          _outputCtrl.text = text.split(RegExp(r'(\s+)')).map((word) {
            if (word.trim().isEmpty) return word;
            return '${word[0].toUpperCase()}${word.substring(1)}';
          }).join();
        case '反转':
          _outputCtrl.text = text.split('').reversed.join('');
        case '反转单词':
          _outputCtrl.text = text.split(RegExp(r'(\s+)')).reversed.join('');
        case '移除空格':
          _outputCtrl.text = text.replaceAll(RegExp(r'\s+'), '');
        case '统计信息':
          final chars = text.length;
          final words = text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
          final lines = '\n'.allMatches(text).length + 1;
          final letters = text.replaceAll(RegExp(r'[^a-zA-Z]'), '').length;
          final digits = text.replaceAll(RegExp(r'[^0-9]'), '').length;
          final spaces = ' '.allMatches(text).length;
          _outputCtrl.text = '字符: $chars\n单词: $words\n行数: $lines\n字母: $letters\n数字: $digits\n空格: $spaces';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文字工具箱'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '文字工具箱',
              principle: '文字工具箱提供常见文本处理功能：大小写转换、反转、空格处理和文本统计。这些虽然是基础操作，但在日常文字处理中非常实用，如规范化用户输入、快速统计文章字数等。',
              usage: '在输入框中输入文本，选择要执行的操作，结果显示在下方。首字母大写会按单词分割处理；反转单词保持单词内部顺序，仅调整单词位置；统计信息显示字符数、单词数、行数等信息。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _actions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final a = _actions[index];
                  final selected = _action == a;
                  return FilterChip(
                    label: Text(a, style: TextStyle(fontSize: 12, color: selected ? Colors.white : null)),
                    selected: selected,
                    onSelected: (_) => setState(() {
                      _action = a;
                      _process();
                    }),
                    selectedColor: Theme.of(context).colorScheme.primary,
                    checkmarkColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _inputCtrl,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  labelText: '输入文本',
                  hintText: '在此输入文本…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (_) => _process(),
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
