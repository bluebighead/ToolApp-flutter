import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/encryptor_help.dart';

class AtbashPage extends StatefulWidget {
  const AtbashPage({super.key});

  @override
  State<AtbashPage> createState() => _AtbashPageState();
}

class _AtbashPageState extends State<AtbashPage> {
  final _inputCtrl = TextEditingController();
  final _outputCtrl = TextEditingController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    _outputCtrl.dispose();
    super.dispose();
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
          buffer.writeCharCode(155 - c);
        } else if (c >= 97 && c <= 122) {
          buffer.writeCharCode(219 - c);
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
        title: const Text('Atbash 密码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: 'Atbash 密码',
              principle: 'Atbash 密码起源于公元前6世纪的希伯来语，是最古老的密码之一。原理是将字母表完全反转：A↔Z、B↔Y、C↔X，以此类推。第一次加密等同于解密，因为再应用一次就恢复原文。在《圣经·耶利米书》中就有使用Atbash进行隐晦表达的例子。',
              usage: '在输入框中输入文本，右侧自动输出Atbash编码结果。同样的操作再次执行即可恢复原文。',
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
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
