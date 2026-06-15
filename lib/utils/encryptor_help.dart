import 'package:flutter/material.dart';

void showEncryptorHelp(BuildContext context, {
  required String name,
  required String principle,
  required String usage,
}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lightbulb_outline, size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: const TextStyle(fontSize: 17))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('原理', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.blue)),
            ),
            const SizedBox(height: 8),
            Text(principle, style: const TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('使用说明', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green)),
            ),
            const SizedBox(height: 8),
            Text(usage, style: const TextStyle(fontSize: 14, height: 1.6)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
