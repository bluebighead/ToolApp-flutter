// 摄像头检测页面
// 检测设备前后摄像头是否正常工作
// 功能：预览摄像头画面、切换前后摄像头、拍照测试
// 成熟方案参考：使用 camera 插件实现实时预览和拍照
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

class CameraTestPage extends StatefulWidget {
  const CameraTestPage({super.key});

  @override
  State<CameraTestPage> createState() => _CameraTestPageState();
}

class _CameraTestPageState extends State<CameraTestPage> {
  // 摄像头控制器
  CameraController? _controller;

  // 可用摄像头列表
  List<CameraDescription> _cameras = [];

  // 当前摄像头索引
  int _currentCameraIndex = 0;

  // 是否正在初始化
  bool _initializing = true;

  // 错误信息
  String? _error;

  // 是否正在拍照
  bool _capturing = false;

  // 拍照结果路径
  String? _capturedPath;

  // 检测结果
  Map<String, bool> _testResults = {};

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // 初始化摄像头
  Future<void> _initCamera() async {
    try {
      // 获取可用摄像头列表
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _error = '未检测到摄像头';
        });
        return;
      }

      // 默认使用后置摄像头
      _currentCameraIndex = 0;
      // 优先找后置摄像头
      for (int i = 0; i < _cameras.length; i++) {
        if (_cameras[i].lensDirection == CameraLensDirection.back) {
          _currentCameraIndex = i;
          break;
        }
      }

      await _startController(_currentCameraIndex);

      // 自动检测摄像头数量
      _testResults['摄像头数量'] = _cameras.isNotEmpty;
      _testResults['后置摄像头'] = _cameras.any(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      _testResults['前置摄像头'] = _cameras.any(
        (c) => c.lensDirection == CameraLensDirection.front,
      );

      setState(() {
        _initializing = false;
      });
    } catch (e) {
      AppLogger.e('CameraTestPage', '初始化摄像头失败: $e');
      setState(() {
        _initializing = false;
        _error = '摄像头初始化失败: $e';
      });
    }
  }

  // 启动摄像头控制器
  Future<void> _startController(int index) async {
    final camera = _cameras[index];
    _controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _controller!.initialize();
  }

  // 切换摄像头
  Future<void> _switchCamera() async {
    if (_cameras.length <= 1) return;

    _currentCameraIndex = (_currentCameraIndex + 1) % _cameras.length;
    _capturedPath = null;

    setState(() => _initializing = true);

    await _controller?.dispose();
    try {
      await _startController(_currentCameraIndex);
      setState(() => _initializing = false);
    } catch (e) {
      AppLogger.e('CameraTestPage', '切换摄像头失败: $e');
      setState(() {
        _initializing = false;
        _error = '切换摄像头失败: $e';
      });
    }
  }

  // 拍照测试
  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_capturing) return;

    setState(() => _capturing = true);
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/camera_test_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final xFile = await _controller!.takePicture();
      // 将拍摄的照片保存到临时目录
      final file = File(xFile.path);
      if (await file.exists()) {
        await file.copy(path);
        _testResults['拍照功能'] = true;
        setState(() {
          _capturedPath = path;
          _capturing = false;
        });
        AppLogger.i('CameraTestPage', '拍照成功: $path');
      } else {
        _testResults['拍照功能'] = false;
        setState(() => _capturing = false);
      }
    } catch (e) {
      AppLogger.e('CameraTestPage', '拍照失败: $e');
      _testResults['拍照功能'] = false;
      setState(() => _capturing = false);
    }
  }

  // 获取当前摄像头名称
  String get _currentCameraName {
    if (_cameras.isEmpty) return '无';
    final camera = _cameras[_currentCameraIndex];
    switch (camera.lensDirection) {
      case CameraLensDirection.back:
        return '后置摄像头';
      case CameraLensDirection.front:
        return '前置摄像头';
      default:
        return '外置摄像头';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('摄像头检测'),
      ),
      body: Column(
        children: [
          // 摄像头预览区域
          Expanded(
            flex: 3,
            child: _buildPreview(),
          ),

          // 检测结果区域
          Expanded(
            flex: 2,
            child: _buildResults(),
          ),
        ],
      ),
    );
  }

  // 构建摄像头预览
  Widget _buildPreview() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      );
    }

    if (_initializing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在初始化摄像头...'),
          ],
        ),
      );
    }

    // 如果有拍照结果，显示拍照图片
    if (_capturedPath != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(_capturedPath!),
            fit: BoxFit.contain,
          ),
          // 返回预览按钮
          Positioned(
            top: 8,
            right: 8,
            child: FloatingActionButton.small(
              heroTag: 'back_preview',
              onPressed: () => setState(() => _capturedPath = null),
              child: const Icon(Icons.videocam),
            ),
          ),
        ],
      );
    }

    // 摄像头预览
    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: 1 / _controller!.value.aspectRatio,
            child: CameraPreview(_controller!),
          ),
        ),
        // 摄像头名称标签
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _currentCameraName,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  // 构建检测结果和控制按钮
  Widget _buildResults() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 检测结果标题
          const Text(
            '检测结果',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          // 检测结果列表
          Expanded(
            child: ListView(
              children: _testResults.entries.map((entry) {
                final passed = entry.value;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    passed ? Icons.check_circle : Icons.cancel,
                    color: passed ? Colors.green : Colors.red,
                  ),
                  title: Text(entry.key),
                  trailing: Text(
                    passed ? '正常' : '异常',
                    style: TextStyle(
                      color: passed ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const Divider(),

          // 操作按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 切换摄像头按钮
              ElevatedButton.icon(
                onPressed: _cameras.length > 1 ? _switchCamera : null,
                icon: const Icon(Icons.flip_camera_ios),
                label: const Text('切换摄像头'),
              ),
              // 拍照测试按钮
              ElevatedButton.icon(
                onPressed:
                    _controller?.value.isInitialized == true && !_capturing
                        ? _takePhoto
                        : null,
                icon: _capturing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera),
                label: Text(_capturing ? '拍摄中...' : '拍照测试'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
