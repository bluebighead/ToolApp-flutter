// 压缩器入口页面
// 作为压缩器大类的二级入口，展示视频/音频/图片压缩三个入口
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'video_compress_page.dart';
import 'audio_compress_page.dart';
import 'compress_history_page.dart';
import 'image_compress_page.dart';

// 压缩器三个子功能的入口列表
class CompressorEntryPage extends StatelessWidget {
  const CompressorEntryPage({super.key});

  // 压缩器子功能入口列表
  static final List<ToolItem> _compressTools = [
    ToolItem(
      name: '视频压缩',
      icon: Icons.videocam,
      color: Colors.blue,
      pageBuilder: (_) => const VideoCompressPage(),
    ),
    ToolItem(
      name: '音频压缩',
      icon: Icons.audiotrack,
      color: Colors.orange,
      pageBuilder: (_) => const AudioCompressPage(),
    ),
    ToolItem(
      name: '图片压缩',
      icon: Icons.image,
      color: Colors.green,
      pageBuilder: (_) => const ImageCompressPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppLogger.d('CompressorEntryPage', '压缩器入口页面 build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('压缩器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '压缩历史',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const CompressHistoryPage()),
              );
            },
          ),
        ],
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
          itemCount: _compressTools.length,
          itemBuilder: (context, index) {
            final tool = _compressTools[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                AppLogger.i(
                    'CompressorEntryPage', '点击压缩工具：${tool.name}');
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
