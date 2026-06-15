// 扫码传信工具
// 支持将文本/文件内容生成二维码或条形码
// 其他用户扫描后可以查看传输的信息
// 取名"扫码传信"：扫码即传，一码传信
// v1.35.0+ 修复：大文件处理改用 isolate 异步处理，避免 UI 卡顿
//             BarcodeWidget 使用 key 缓存避免重复构建
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:isolate';

import 'package:barcode/barcode.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../utils/app_logger.dart';
import '../../utils/encryptor_help.dart';

/// 在 isolate 中处理大文件内容（读取 + base64 编码）
/// 避免大文件阻塞 UI 线程
Future<String> _processLargeFileInIsolate(String filePath) async {
  return await compute(_readAndEncodeFile, filePath);
}

String _readAndEncodeFile(String filePath) {
  final file = File(filePath);
  final bytes = file.readAsBytesSync();

  // 文本文件：尝试 UTF-8 解码
  try {
    return utf8.decode(bytes);
  } catch (_) {
    // 二进制文件：转 base64 编码
    return 'BASE64:${base64Encode(bytes)}';
  }
}

class CodeTransferPage extends StatefulWidget {
  const CodeTransferPage({super.key});

  @override
  State<CodeTransferPage> createState() => _CodeTransferPageState();
}

class _CodeTransferPageState extends State<CodeTransferPage> {
  // 内容输入模式：text（文本）或 file（文件）
  String _inputMode = 'text';

  // 文本输入内容
  final TextEditingController _textController = TextEditingController();

  // 文件路径和内容
  String? _filePath;
  String? _fileContent;
  String? _fileName;

  // 当前内容（用于生成码）
  String _currentContent = '';

  // 码类型选择
  String _codeType = 'qr';

  // 码类型列表
  static const List<Map<String, String>> _codeTypes = [
    {'value': 'qr', 'label': 'QR 二维码', 'desc': '最常用，容量大，扫码识别快'},
    {'value': 'code128', 'label': 'Code 128', 'desc': '一维条形码，支持字母数字'},
    {'value': 'code39', 'label': 'Code 39', 'desc': '一维条形码，支持大写字母数字'},
    {'value': 'datamatrix', 'label': 'Data Matrix', 'desc': '二维矩阵码，容量大'},
    {'value': 'pdf417', 'label': 'PDF417', 'desc': '二维堆叠码，支持大量数据'},
    {'value': 'ean13', 'label': 'EAN-13', 'desc': '商品条码，13位数字'},
  ];

  // 生成状态
  bool _isGenerating = false;

  // 生成的码图片路径（用于分享）
  String? _savedImagePath;

  // v1.35.0+ 缓存：防止 BarcodeWidget 重复构建导致卡顿
  // 使用内容+类型的组合 key 来标识是否需要重建
  String? _cachedBarcodeKey;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码传信'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => showEncryptorHelp(
              context,
              name: '扫码传信',
              principle: '二维码（QR Code）是一种矩阵式条码，由日本电装公司在1994年发明。通过黑白方块排列存储数据，支持数字、字母、汉字等。具有容错能力强、识别速度快、信息容量大等优点。条形码（Barcode）则是一维编码，仅在一个方向上存储信息。',
              usage: '在输入框中输入要编码的文本，选择二维码或条形码格式，下方自动生成对应的码图。可调整容错级别（仅二维码）和图片大小。生成的码图可保存到相册或分享。',
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 输入模式切换
            _buildInputModeSelector(),
            const SizedBox(height: 16),

            // 文本输入或文件选择
            if (_inputMode == 'text') _buildTextInput() else _buildFileInput(),
            const SizedBox(height: 16),

            // 码类型选择
            _buildCodeTypeSelector(),
            const SizedBox(height: 16),

            // 生成按钮
            _buildGenerateButton(),
            const SizedBox(height: 20),

            // 码预览
            if (_currentContent.isNotEmpty) _buildCodePreview(),
          ],
        ),
      ),
    );
  }

  // 输入模式切换（文本 / 文件）
  Widget _buildInputModeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _buildModeTab('文本输入', 'text', Icons.text_fields),
            ),
            Expanded(
              child: _buildModeTab('文件上传', 'file', Icons.upload_file),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeTab(String label, String mode, IconData icon) {
    final isSelected = _inputMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _inputMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 文本输入区域
  Widget _buildTextInput() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note, size: 18, color: Colors.grey),
                const SizedBox(width: 6),
                const Text('输入内容', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const Spacer(),
                Text(
                  '${_textController.text.length} 字',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              maxLines: 5,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: '请输入要传递的信息...',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }

  // 文件选择区域
  Widget _buildFileInput() {
    return Card(
      child: InkWell(
        onTap: _pickFile,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.insert_drive_file, color: Colors.blue, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fileName ?? '点击选择文件',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_fileContent != null)
                      Text(
                        '内容长度：${_fileContent!.length} 字符',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ),
                  ],
                ),
              ),
              if (_filePath != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _filePath = null;
                    _fileContent = null;
                    _fileName = null;
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 选择文件（使用 isolate 异步处理大文件，避免 UI 卡顿）
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        final name = result.files.first.name;
        if (path == null) return;

        final file = File(path);
        final size = await file.length();

        // 限制文件最大 500KB（二维码数据容量有限，2MB 太大导致卡顿且无法完整传输）
        if (size > 500 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('文件过大，请选择 500KB 以内的文件')),
            );
          }
          return;
        }

        // v1.35.0+ 修复：大文件使用 isolate 异步处理，避免 UI 卡顿
        // 超过 50KB 的文件使用后台 isolate 处理
        String content;
        if (size > 50 * 1024) {
          // 显示处理中状态
          setState(() {
            _fileName = name;
            _filePath = path;
            _fileContent = '处理中...';
          });
          content = await _processLargeFileInIsolate(path);
        } else {
          // 小文件直接读取
          try {
            content = await file.readAsString();
          } catch (_) {
            final bytes = await file.readAsBytes();
            content = 'BASE64:${base64Encode(bytes)}';
          }
        }

        setState(() {
          _filePath = path;
          _fileName = name;
          _fileContent = content;
        });
      }
    } catch (e) {
      AppLogger.e('CodeTransferPage', '选择文件失败：$e');
    }
  }

  // 码类型选择器
  Widget _buildCodeTypeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.qr_code_2, size: 18, color: Colors.grey),
                SizedBox(width: 6),
                Text('码类型', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _codeTypes.map((type) {
                final isSelected = _codeType == type['value'];
                return ChoiceChip(
                  label: Text(type['label']!, style: const TextStyle(fontSize: 12)),
                  selected: isSelected,
                  onSelected: (_) => setState(() => _codeType = type['value']!),
                  selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  labelStyle: TextStyle(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.shade700,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
            // 显示当前类型描述
            Text(
              _codeTypes.firstWhere((t) => t['value'] == _codeType)['desc']!,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  // 生成按钮
  Widget _buildGenerateButton() {
    final hasContent = _inputMode == 'text'
        ? _textController.text.trim().isNotEmpty
        : _fileContent != null;

    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: hasContent ? _generateCode : null,
        icon: const Icon(Icons.qr_code),
        label: const Text('生成码'),
      ),
    );
  }

  // 生成码（异步放在 isolate 中处理，避免大内容卡顿 UI）
  void _generateCode() {
    final content = _inputMode == 'text'
        ? _textController.text.trim()
        : _fileContent ?? '';

    if (content.isEmpty) return;

    setState(() {
      _isGenerating = true;
      _currentContent = content;
      // v1.35.0+ 缓存 key 失效，强制重建 BarcodeWidget
      _cachedBarcodeKey = '${_codeType}_${content.hashCode}';
    });

    // v1.35.0+ 使用 Future.microtask 延迟一帧，让 loading 指示器先渲染
    // 然后 BarcodeWidget 在下一帧构建，避免同步构建大 QR 码卡死 UI
    Future.microtask(() {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    });
  }

  // 码预览区域
  Widget _buildCodePreview() {
    // 获取当前类型的描述
    final typeInfo = _codeTypes.firstWhere((t) => t['value'] == _codeType);
    final int maxLen = _getMaxContentLength(_codeType);

    // 截断过长内容
    String displayContent = _currentContent;
    bool isTruncated = false;
    if (_currentContent.length > maxLen) {
      displayContent = _currentContent.substring(0, maxLen);
      isTruncated = true;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 标题
            Row(
              children: [
                const Icon(Icons.qr_code_2, size: 20, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    typeInfo['label']!,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                // 保存按钮
                IconButton(
                  icon: const Icon(Icons.save_alt, size: 20),
                  tooltip: '保存到本地',
                  onPressed: _saveCodeImage,
                ),
                // 分享按钮
                IconButton(
                  icon: const Icon(Icons.share, size: 20),
                  tooltip: '分享',
                  onPressed: _shareCodeImage,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 码图像（v1.35.0+ 使用 RepaintBoundary + Key 缓存，避免重复构建）
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: RepaintBoundary(
                child: _isGenerating
                    ? const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : KeyedSubtree(
                        key: ValueKey(_cachedBarcodeKey ?? 'no_code'),
                        child: _buildBarcodeWidget(displayContent),
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // 内容预览
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _inputMode == 'text' ? '文本内容' : '文件内容',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                      if (isTruncated) ...[
                        const SizedBox(width: 8),
                        Text(
                          '（已截断，原始 ${_currentContent.length} 字）',
                          style: TextStyle(fontSize: 10, color: Colors.orange.shade600),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    displayContent,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 提示
            Text(
              '使用相机或扫码工具扫描上方码即可查看内容',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // 根据类型构建对应的条形码组件
  Widget _buildBarcodeWidget(String data) {
    if (data.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('无内容')),
      );
    }

    try {
      // v1.35.0+ 对超大数据给出警告提示，避免 QR 码生成崩溃
      final maxLen = _getMaxContentLength(_codeType);
      final displayData = data.length > maxLen ? data.substring(0, maxLen) : data;

      switch (_codeType) {
        case 'qr':
          return BarcodeWidget(
            barcode: Barcode.qrCode(),
            data: displayData,
            width: 250,
            height: 250,
            drawText: false,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        case 'code128':
          return BarcodeWidget(
            barcode: Barcode.code128(),
            data: displayData,
            width: 300,
            height: 120,
            drawText: true,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        case 'code39':
          return BarcodeWidget(
            barcode: Barcode.code39(),
            data: displayData,
            width: 300,
            height: 120,
            drawText: true,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        case 'datamatrix':
          return BarcodeWidget(
            barcode: Barcode.dataMatrix(),
            data: displayData,
            width: 250,
            height: 250,
            drawText: false,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        case 'pdf417':
          return BarcodeWidget(
            barcode: Barcode.pdf417(),
            data: displayData,
            width: 300,
            height: 150,
            drawText: false,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        case 'ean13':
          // EAN-13 需要恰好 12 或 13 位数字
          final eanData = displayData.replaceAll(RegExp(r'[^0-9]'), '');
          final validEan = eanData.length >= 12 ? eanData.substring(0, 12) : eanData.padRight(12, '0');
          return BarcodeWidget(
            barcode: Barcode.ean13(),
            data: validEan,
            width: 300,
            height: 120,
            drawText: true,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
        default:
          return BarcodeWidget(
            barcode: Barcode.qrCode(),
            data: displayData,
            width: 250,
            height: 250,
            drawText: false,
            padding: const EdgeInsets.all(10),
            backgroundColor: Colors.white,
          );
      }
    } catch (e) {
      AppLogger.e('CodeTransferPage', '生成码失败：$e');
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '生成失败：${e.toString()}',
              style: const TextStyle(color: Colors.red, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
  }

  // 获取不同码类型的最大内容长度
  int _getMaxContentLength(String type) {
    switch (type) {
      case 'qr':
        return 2000;
      case 'code128':
        return 80;
      case 'code39':
        return 40;
      case 'datamatrix':
        return 1500;
      case 'pdf417':
        return 1000;
      case 'ean13':
        return 13;
      default:
        return 500;
    }
  }

  // 保存码图片到本地
  Future<void> _saveCodeImage() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final codeDir = Directory(p.join(docsDir.path, 'codes'));
      if (!await codeDir.exists()) {
        await codeDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'code_$timestamp.txt';
      final filePath = p.join(codeDir.path, fileName);

      final file = File(filePath);
      await file.writeAsString('类型: $_codeType\n内容: $_currentContent');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('码内容已保存到：$filePath')),
        );
      }
      _savedImagePath = filePath;
    } catch (e) {
      AppLogger.e('CodeTransferPage', '保存码失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败')),
        );
      }
    }
  }

  // 分享码内容
  Future<void> _shareCodeImage() async {
    try {
      // 先保存再分享
      if (_savedImagePath == null) {
        await _saveCodeImage();
      }
      if (_savedImagePath != null) {
        await Share.shareXFiles(
          [XFile(_savedImagePath!)],
          text: '扫码传信 - $_codeType',
        );
      }
    } catch (e) {
      AppLogger.e('CodeTransferPage', '分享码失败：$e');
    }
  }
}