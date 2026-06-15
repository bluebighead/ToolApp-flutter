// 设备检修工具页面
// 作为设备检修大类的二级入口，展示摄像头检测、屏幕坏点、麦克风、扬声器、指纹检测、GPS检测等小工具
// v1.35.0+ 新增：麦克风检测、扬声器检测、指纹功能检测
// v1.52.5+ 新增：GPS定位检测
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'device_inspect/camera_test_page.dart';
import 'device_inspect/screen_dead_pixel_page.dart';
import 'device_inspect/microphone_test_page.dart';
import 'device_inspect/speaker_test_page.dart';
import 'device_inspect/fingerprint_test_page.dart';
import 'device_inspect/gps_test_page.dart';
import 'device_inspect/profiler_page.dart';

class DeviceInspectPage extends StatelessWidget {
  const DeviceInspectPage({super.key});

  // 设备检修工具列表
  static final List<ToolItem> _tools = [
    ToolItem(
      name: '摄像头检测',
      icon: Icons.camera_alt,
      color: Colors.blue,
      pageBuilder: (_) => const CameraTestPage(),
    ),
    ToolItem(
      name: '屏幕坏点检测',
      icon: Icons.phonelink_setup,
      color: Colors.orange,
      pageBuilder: (_) => const ScreenDeadPixelPage(),
    ),
    ToolItem(
      name: '麦克风检测',
      icon: Icons.mic,
      color: Colors.red,
      subtitle: '录音·播放',
      pageBuilder: (_) => const MicrophoneTestPage(),
    ),
    ToolItem(
      name: '扬声器检测',
      icon: Icons.speaker,
      color: Colors.teal,
      subtitle: '频率·声道',
      pageBuilder: (_) => const SpeakerTestPage(),
    ),
    ToolItem(
      name: '指纹功能检测',
      icon: Icons.fingerprint,
      color: Colors.deepPurple,
      subtitle: '验证·同步',
      pageBuilder: (_) => const FingerprintTestPage(),
    ),
    ToolItem(
      name: 'GPS定位检测',
      icon: Icons.gps_fixed,
      color: Colors.cyan,
      subtitle: '坐标·地图',
      pageBuilder: (_) => const GpsTestPage(),
    ),
    ToolItem(
      name: 'Android Profiler',
      icon: Icons.speed,
      color: Colors.green,
      subtitle: 'CPU·内存·网络·电量',
      pageBuilder: (_) => const ProfilerPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppLogger.d('DeviceInspectPage', '设备检修工具页面 build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备检修工具'),
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
                AppLogger.i('DeviceInspectPage', '点击检修工具：${tool.name}');
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
