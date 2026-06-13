// 加解密工具页面
// 作为加解密工具大类的二级入口，展示所有加解密小工具
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'encryptor/morse_code_page.dart';
import 'encryptor/code_transfer_page.dart';
import 'encryptor/qr_decoder_page.dart';

class EncryptorPage extends StatelessWidget {
  const EncryptorPage({super.key});

  // 加密工具列表
  static final List<ToolItem> _tools = [
    ToolItem(
      name: '摩斯电码',
      icon: Icons.signal_cellular_alt,
      color: Colors.amber,
      category: ToolCategory.geek,
      subtitle: '加解密 · 振动播放',
      pageBuilder: (_) => const MorseCodePage(),
    ),
    ToolItem(
      name: '扫码传信',
      icon: Icons.qr_code_2,
      color: Colors.teal,
      category: ToolCategory.geek,
      subtitle: '生成二维码 · 条形码',
      pageBuilder: (_) => const CodeTransferPage(),
    ),
    ToolItem(
      name: '二维码解码',
      icon: Icons.qr_code_scanner,
      color: Colors.indigo,
      category: ToolCategory.geek,
      subtitle: '图片解析 · 摄像头扫码 · 解码',
      pageBuilder: (_) => const QrDecoderPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppLogger.d('EncryptorPage', '加解密工具页面 build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('加解密工具'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: _tools.length,
          itemBuilder: (context, index) {
            final tool = _tools[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                AppLogger.i('EncryptorPage', '点击加密工具：${tool.name}');
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: tool.pageBuilder),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
