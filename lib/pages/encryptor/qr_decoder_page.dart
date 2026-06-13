// 二维码解码器
// 支持从图片中解析二维码/条形码内容，以及使用摄像头实时扫码
// v1.52.1+ 新增，v1.52.2+ 增加摄像头扫码
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../utils/app_logger.dart';

class QrDecoderPage extends StatefulWidget {
  const QrDecoderPage({super.key});

  @override
  State<QrDecoderPage> createState() => _QrDecoderPageState();
}

class _QrDecoderPageState extends State<QrDecoderPage> {
  // 解码模式：'gallery' 图片解析，'camera' 摄像头扫码
  String _mode = 'gallery';

  // 图片解析状态
  bool _isDecoding = false;
  String? _decodedContent;
  String? _barcodeFormat;
  String? _imagePath;
  String? _imageName;

  // 解码历史
  final List<_DecodeRecord> _history = [];
  final _contentController = TextEditingController();

  // 摄像头扫码控制器
  MobileScannerController? _cameraController;

  @override
  void dispose() {
    _contentController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  /// 切换模式
  void _switchMode(String mode) {
    setState(() {
      _mode = mode;
      if (mode == 'camera') {
        _cameraController = MobileScannerController();
      } else {
        _cameraController?.dispose();
        _cameraController = null;
      }
    });
  }

  /// 摄像头扫码回调
  /// v1.52.3+ 修复：扫码成功后自动跳转到图片解析页显示结果，移除 SnackBar 卡住问题
  void _onCameraDetect(BarcodeCapture capture) {
    if (capture.barcodes.isEmpty) return;
    final barcode = capture.barcodes.first;
    final content = barcode.displayValue ?? barcode.rawValue ?? '';
    if (content.isEmpty) return;

    // 记录解码结果
    setState(() {
      _decodedContent = content;
      _barcodeFormat = barcode.format.name;
    });
    _contentController.text = content;

    // 添加到历史记录
    _history.insert(0, _DecodeRecord(
      imageName: '摄像头扫码',
      content: content,
      format: barcode.format.name,
      time: DateTime.now(),
    ));

    AppLogger.i('QrDecoderPage', '摄像头扫码成功: ${barcode.format.name}');

    // 停止摄像头并切换到图片解析页显示结果
    _cameraController?.stop();
    _cameraController?.dispose();
    _cameraController = null;
    setState(() {
      _mode = 'gallery';
    });
  }

  /// 选择图片并解码
  Future<void> _pickAndDecode() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;

      setState(() {
        _isDecoding = true;
        _imagePath = file.path;
        _imageName = file.name;
        _decodedContent = null;
        _barcodeFormat = null;
      });

      AppLogger.i('QrDecoderPage', '开始解码图片: ${file.path}');

      final controller = MobileScannerController();
      final capture = await controller.analyzeImage(file.path!);
      controller.dispose();

      if (capture != null && capture.barcodes.isNotEmpty) {
        final barcode = capture.barcodes.first;
        final content = barcode.displayValue ?? barcode.rawValue ?? '';

        setState(() {
          _decodedContent = content;
          _barcodeFormat = barcode.format.name;
          _isDecoding = false;
        });

        _contentController.text = content;

        _history.insert(0, _DecodeRecord(
          imageName: file.name,
          content: content,
          format: barcode.format.name,
          time: DateTime.now(),
        ));

        AppLogger.i('QrDecoderPage', '图片解码成功: ${barcode.format.name}');
      } else {
        setState(() => _isDecoding = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未在图片中检测到二维码或条形码')),
          );
        }
        AppLogger.w('QrDecoderPage', '未检测到码');
      }
    } catch (e) {
      setState(() => _isDecoding = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解码失败: $e')),
        );
      }
      AppLogger.e('QrDecoderPage', '解码失败: $e');
    }
  }

  /// 复制内容到剪贴板
  void _copyContent() {
    if (_decodedContent == null || _decodedContent!.isEmpty) return;
    _contentController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _contentController.text.length,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('内容已选中，可长按复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('二维码解码器'),
        actions: [
          if (_decodedContent != null && _decodedContent!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '复制内容',
              onPressed: _copyContent,
            ),
        ],
      ),
      body: Column(
        children: [
          // 模式切换
          _buildModeSwitch(theme),
          // 内容区域
          Expanded(
            child: _mode == 'camera' ? _buildCameraView(theme) : _buildGalleryView(theme),
          ),
          // 历史记录
          if (_history.isNotEmpty && _mode != 'camera') _buildHistorySection(theme),
        ],
      ),
    );
  }

  /// 模式切换选项卡
  Widget _buildModeSwitch(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeTab(
              icon: Icons.image_search,
              label: '图片解析',
              isSelected: _mode == 'gallery',
              onTap: () => _switchMode('gallery'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ModeTab(
              icon: Icons.camera_alt,
              label: '摄像头扫码',
              isSelected: _mode == 'camera',
              onTap: () => _switchMode('camera'),
            ),
          ),
        ],
      ),
    );
  }

  /// 摄像头扫码视图
  /// v1.52.3+ 优化：移除内联结果显示，扫码成功后自动跳转到图片解析页
  Widget _buildCameraView(ThemeData theme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          // 摄像头预览
          MobileScanner(
            controller: _cameraController,
            onDetect: _onCameraDetect,
          ),
          // 扫码框
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // 四角装饰
          ..._buildCornerDecorations(),
          // 提示文字
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Text(
              '将二维码/条形码对准框内',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  /// 扫码框四角装饰
  List<Widget> _buildCornerDecorations() {
    const size = 30.0;
    const strokeWidth = 3.0;
    const color = Colors.white;
    return [
      // 左上角
      Positioned(top: 0, left: 0, child: _cornerPainter(size, strokeWidth, color, Alignment.topLeft)),
      // 右上角
      Positioned(top: 0, right: 0, child: _cornerPainter(size, strokeWidth, color, Alignment.topRight)),
      // 左下角
      Positioned(bottom: 0, left: 0, child: _cornerPainter(size, strokeWidth, color, Alignment.bottomLeft)),
      // 右下角
      Positioned(bottom: 0, right: 0, child: _cornerPainter(size, strokeWidth, color, Alignment.bottomRight)),
    ];
  }

  Widget _cornerPainter(double size, double strokeWidth, Color color, Alignment alignment) {
    return CustomPaint(
      size: const Size(30, 30),
      painter: _CornerPainter(size: size, strokeWidth: strokeWidth, color: color, alignment: alignment),
    );
  }

  /// 图片解析视图
  Widget _buildGalleryView(ThemeData theme) {
    return Column(
      children: [
        // 选择图片区域
        _buildPickArea(theme),
        // 解码状态
        if (_isDecoding)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        // 解码结果显示
        if (_decodedContent != null) _buildResultArea(theme),
        if (_decodedContent == null && !_isDecoding)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_scanner, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text(
                    '选择一张包含二维码或条形码的图片',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 选择图片区域
  Widget _buildPickArea(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: InkWell(
        onTap: _isDecoding ? null : _pickAndDecode,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.image_search,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _imageName ?? '点击选择图片',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _imagePath != null ? '已选择图片' : '支持 JPG、PNG、BMP 等格式',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
              if (_imagePath != null)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新选择',
                  onPressed: _isDecoding ? null : _pickAndDecode,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 解码结果显示区域
  // ============================================================
  // 解码结果区域（v1.52.3+ 添加继续扫码按钮）
  // ============================================================
  Widget _buildResultArea(ThemeData theme) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '解码成功',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.green.shade700,
                    ),
                  ),
                  const Spacer(),
                  if (_barcodeFormat != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _formatLabel(_barcodeFormat!),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(height: 24),
              Expanded(
                child: TextField(
                  controller: _contentController,
                  readOnly: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                  decoration: InputDecoration(
                    hintText: '解码内容将显示在这里...',
                    hintStyle: TextStyle(color: Colors.grey.shade400),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // v1.52.3+ 继续扫码按钮
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _switchMode('camera'),
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('继续扫码'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 历史记录区域
  Widget _buildHistorySection(ThemeData theme) {
    return Container(
      height: 160,
      margin: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(Icons.history, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Text(
                  '解码历史',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _history.clear()),
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final record = _history[index];
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _decodedContent = record.content;
                      _barcodeFormat = record.format;
                      _imageName = record.imageName;
                    });
                    _contentController.text = record.content;
                  },
                  child: Container(
                    width: 200,
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.imageName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: Text(
                            record.content,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _formatLabel(record.format),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _formatTime(record.time),
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 格式化码类型显示名
  String _formatLabel(String format) {
    switch (format) {
      case 'qrCode':
        return 'QR二维码';
      case 'code128':
        return 'Code 128';
      case 'code39':
        return 'Code 39';
      case 'code93':
        return 'Code 93';
      case 'dataMatrix':
        return 'Data Matrix';
      case 'pdf417':
        return 'PDF417';
      case 'ean8':
        return 'EAN-8';
      case 'ean13':
        return 'EAN-13';
      case 'upcA':
        return 'UPC-A';
      case 'upcE':
        return 'UPC-E';
      case 'aztec':
        return 'Aztec';
      default:
        return format;
    }
  }

  /// 格式化时间
  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}

/// 解码记录
class _DecodeRecord {
  final String imageName;
  final String content;
  final String format;
  final DateTime time;

  _DecodeRecord({
    required this.imageName,
    required this.content,
    required this.format,
    required this.time,
  });
}

// ============================================================
// 模式切换选项卡
// ============================================================
class _ModeTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeTab({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? Colors.white : Colors.grey.shade600,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isSelected ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 扫码框四角绘制器
// ============================================================
class _CornerPainter extends CustomPainter {
  final double size;
  final double strokeWidth;
  final Color color;
  final Alignment alignment;

  _CornerPainter({
    required this.size,
    required this.strokeWidth,
    required this.color,
    required this.alignment,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final w = canvasSize.width;
    final h = canvasSize.height;

    if (alignment == Alignment.topLeft) {
      path.moveTo(w, 0);
      path.lineTo(0, 0);
      path.lineTo(0, h);
    } else if (alignment == Alignment.topRight) {
      path.moveTo(0, 0);
      path.lineTo(w, 0);
      path.lineTo(w, h);
    } else if (alignment == Alignment.bottomLeft) {
      path.moveTo(w, h);
      path.lineTo(0, h);
      path.lineTo(0, 0);
    } else {
      path.moveTo(0, h);
      path.lineTo(w, h);
      path.lineTo(w, 0);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}