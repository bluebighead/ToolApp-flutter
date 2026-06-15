import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/encryptor_help.dart';

class PasswordPage extends StatefulWidget {
  const PasswordPage({super.key});

  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final _resultCtrl = TextEditingController();
  int _length = 16;
  bool _useUpper = true;
  bool _useLower = true;
  bool _useDigits = true;
  bool _useSymbols = true;
  int _count = 5;
  final _passwords = <String>[];

  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _lower = 'abcdefghijklmnopqrstuvwxyz';
  static const _digits = '0123456789';
  static const _symbols = '!@#\$%^&*()_+-=[]{}|;:,.<>?';

  @override
  void dispose() {
    _resultCtrl.dispose();
    super.dispose();
  }

  String _generatePassword(int length) {
    String chars = '';
    if (_useUpper) chars += _upper;
    if (_useLower) chars += _lower;
    if (_useDigits) chars += _digits;
    if (_useSymbols) chars += _symbols;
    if (chars.isEmpty) chars = _lower;

    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  void _generate() {
    final list = List.generate(_count, (_) => _generatePassword(_length));
    _resultCtrl.text = list.join('\n');
    setState(() => _passwords..clear()..addAll(list));
  }

  int _strength(String pwd) {
    int score = 0;
    if (pwd.length >= 8) score++;
    if (pwd.length >= 12) score++;
    if (pwd.length >= 16) score++;
    if (pwd.contains(RegExp(r'[A-Z]'))) score++;
    if (pwd.contains(RegExp(r'[a-z]'))) score++;
    if (pwd.contains(RegExp(r'[0-9]'))) score++;
    if (pwd.contains(RegExp(r'[^A-Za-z0-9]'))) score++;
    return score;
  }

  String _strengthLabel(int s) => s >= 7 ? '强' : s >= 5 ? '中' : '弱';
  Color _strengthColor(int s) => s >= 7 ? Colors.green : s >= 5 ? Colors.orange : Colors.red;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('随机密码生成器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '随机密码生成器',
              principle: '强密码的生成依赖于足够大的密钥空间（entropy）。通过组合大写字母、小写字母、数字和特殊符号，并让每个位置的字符随机选择，使暴力破解所需的时间呈指数级增长。例如12位含全部字符集的密码约有3×10²³种组合。',
              usage: '通过复选框选择包含的字符类型（大写/小写/数字/符号），调节滑块设置密码长度。点击"生成"按钮即可生成随机密码，点击复制按钮拷贝到剪贴板。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('密码长度: $_length',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            Slider(
              value: _length.toDouble(), min: 4, max: 64, divisions: 60,
              label: '$_length',
              onChanged: (v) => setState(() => _length = v.round()),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('A-Z', style: TextStyle(fontSize: 12)),
                  selected: _useUpper,
                  onSelected: (v) => setState(() => _useUpper = v),
                ),
                FilterChip(
                  label: const Text('a-z', style: TextStyle(fontSize: 12)),
                  selected: _useLower,
                  onSelected: (v) => setState(() => _useLower = v),
                ),
                FilterChip(
                  label: const Text('0-9', style: TextStyle(fontSize: 12)),
                  selected: _useDigits,
                  onSelected: (v) => setState(() => _useDigits = v),
                ),
                FilterChip(
                  label: const Text('符号', style: TextStyle(fontSize: 12)),
                  selected: _useSymbols,
                  onSelected: (v) => setState(() => _useSymbols = v),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('生成数量: ', style: TextStyle(fontSize: 14)),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 5, label: Text('5', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 10, label: Text('10', style: TextStyle(fontSize: 12))),
                  ],
                  selected: {_count},
                  onSelectionChanged: (v) => setState(() => _count = v.first),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('生成密码'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_passwords.isNotEmpty)
              Expanded(
                child: ListView.separated(
                  itemCount: _passwords.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final pwd = _passwords[i];
                    final s = _strength(pwd);
                    return ListTile(
                      dense: true,
                      title: SelectableText(pwd, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _strengthColor(s).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: _strengthColor(s).withValues(alpha: 0.3)),
                            ),
                            child: Text(_strengthLabel(s),
                                style: TextStyle(fontSize: 10, color: _strengthColor(s), fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: pwd));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制')),
                              );
                            },
                            child: Icon(Icons.copy, size: 16, color: Colors.grey[400]),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
