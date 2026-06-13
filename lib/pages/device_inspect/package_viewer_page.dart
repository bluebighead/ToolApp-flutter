// 安装包免压查看器
// 用户可查看手机中的压缩包，免解压直接查看内容
// 支持 ZIP/RAR/7z/TAR/GZ 等常见格式及 APK 直接查看
// v1.35.0+ 新增
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';
import '../../utils/app_storage.dart';

/// APK 文件信息
class ApkInfo {
  final String? packageName;
  final String? versionName;
  final String? versionCode;
  final String? appName;
  final int? minSdkVersion;
  final int? targetSdkVersion;
  final List<String> permissions;
  final List<String> activities;
  final List<String> services;
  final List<String> receivers;
  final Map<String, String> iconPaths; // density -> icon path

  ApkInfo({
    this.packageName,
    this.versionName,
    this.versionCode,
    this.appName,
    this.minSdkVersion,
    this.targetSdkVersion,
    this.permissions = const [],
    this.activities = const [],
    this.services = const [],
    this.receivers = const [],
    this.iconPaths = const {},
  });

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'versionName': versionName,
        'versionCode': versionCode,
        'appName': appName,
        'minSdkVersion': minSdkVersion,
        'targetSdkVersion': targetSdkVersion,
        'permissions': permissions,
        'activities': activities,
        'services': services,
        'receivers': receivers,
      };
}

class PackageViewerPage extends StatefulWidget {
  const PackageViewerPage({super.key});

  @override
  State<PackageViewerPage> createState() => _PackageViewerPageState();
}

class _PackageViewerPageState extends State<PackageViewerPage> {
  // 当前打开的压缩文件路径
  String? _archivePath;

  // 压缩文件名
  String? _archiveName;

  // 是否为 APK 文件
  bool _isApk = false;

  // APK 解析信息
  ApkInfo? _apkInfo;

  // 文件列表
  List<ArchiveFile> _files = [];

  // 当前浏览目录路径
  String _currentDir = '';

  // 是否正在加载
  bool _loading = false;

  // 错误信息
  String? _error;

  // 排序方式
  _SortMode _sortMode = _SortMode.name;

  // 是否升序
  bool _ascending = true;

  // 预览文件内容缓存
  String? _previewContent;

  // 预览图片路径
  String? _previewImagePath;

  // 是否显示预览面板
  bool _showPreview = false;

  // 搜索关键字
  String _searchQuery = '';

  // APK 查看模式
  _ApkViewMode _apkViewMode = _ApkViewMode.fileList;

  // 已过滤的文件列表（搜索后）
  List<ArchiveFile> get _filteredFiles {
    if (_searchQuery.isEmpty) return _files;
    return _files
        .where((f) =>
            f.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_archiveName ?? '安装包免压查看器'),
        actions: [
          // APK 模式切换
          if (_isApk)
            PopupMenuButton<_ApkViewMode>(
              icon: const Icon(Icons.view_list),
              tooltip: '切换视图',
              onSelected: (mode) {
                setState(() => _apkViewMode = mode);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _ApkViewMode.fileList,
                  child: Text('文件列表'),
                ),
                const PopupMenuItem(
                  value: _ApkViewMode.apkInfo,
                  child: Text('APK 信息'),
                ),
                const PopupMenuItem(
                  value: _ApkViewMode.manifestXml,
                  child: Text('AndroidManifest'),
                ),
              ],
            ),
          // 排序按钮
          PopupMenuButton<_SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            onSelected: (mode) {
              setState(() {
                if (_sortMode == mode) {
                  _ascending = !_ascending;
                } else {
                  _sortMode = mode;
                  _ascending = true;
                }
                _sortFiles();
              });
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _SortMode.name,
                child: Row(
                  children: [
                    const Text('按名称'),
                    if (_sortMode == _SortMode.name)
                      Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 16),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _SortMode.size,
                child: Row(
                  children: [
                    const Text('按大小'),
                    if (_sortMode == _SortMode.size)
                      Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 16),
                  ],
                ),
              ),
              PopupMenuItem(
                value: _SortMode.type,
                child: Row(
                  children: [
                    const Text('按类型'),
                    if (_sortMode == _SortMode.type)
                      Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 16),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      // 底部预览面板
      bottomSheet: _showPreview && _previewContent != null
          ? Container(
              height: 300,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // 标题栏
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.preview, size: 16),
                        const SizedBox(width: 8),
                        const Text('文件预览', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            _showPreview = false;
                            _previewContent = null;
                          }),
                        ),
                      ],
                    ),
                  ),
                  // 预览内容
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _previewContent!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: Column(
        children: [
          // 搜索栏
          if (_archivePath != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '搜索文件...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () =>
                              setState(() => _searchQuery = ''),
                        )
                      : null,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
          ],

          // 主体内容
          Expanded(child: _buildBody()),
        ],
      ),
      // 底部：选择文件按钮 + 统计信息
      floatingActionButton: _archivePath != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _pickArchive,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择压缩包'),
            ),
    );
  }

  /// 构建主体内容
  Widget _buildBody() {
    if (_archivePath == null) {
      return _buildEmptyState();
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _buildErrorState();
    }

    // APK 信息视图
    if (_isApk && _apkViewMode == _ApkViewMode.apkInfo && _apkInfo != null) {
      return _buildApkInfoView();
    }

    // Manifest XML 视图
    if (_isApk && _apkViewMode == _ApkViewMode.manifestXml) {
      return _buildManifestXmlView();
    }

    return _buildFileListView();
  }

  /// 空状态：选择文件提示
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.archive, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text(
            '安装包免压查看器',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 ZIP / RAR / 7z / TAR / GZ / APK 等格式\n免解压即可查看压缩包内容',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 24),
          // 支持的格式列表
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              _buildFormatChip('ZIP', Colors.blue),
              _buildFormatChip('RAR', Colors.red),
              _buildFormatChip('7z', Colors.orange),
              _buildFormatChip('TAR', Colors.teal),
              _buildFormatChip('GZ', Colors.green),
              _buildFormatChip('APK', Colors.deepPurple),
              _buildFormatChip('AAB', Colors.indigo),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormatChip(String format, Color color) {
    return Chip(
      label: Text(format, style: TextStyle(fontSize: 12, color: color)),
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  /// 错误状态
  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text('加载失败: $_error',
              style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _pickArchive,
            child: const Text('重新选择文件'),
          ),
        ],
      ),
    );
  }

  /// APK 信息视图
  Widget _buildApkInfoView() {
    final info = _apkInfo!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 基本信息
          _buildSectionTitle('基本信息'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _buildApkInfoRow('应用名称', info.appName ?? '未知'),
                  _buildApkInfoRow('包名', info.packageName ?? '未知'),
                  _buildApkInfoRow('版本名', info.versionName ?? '未知'),
                  _buildApkInfoRow('版本号', info.versionCode ?? '未知'),
                  _buildApkInfoRow('最小 SDK', info.minSdkVersion?.toString() ?? '未知'),
                  _buildApkInfoRow('目标 SDK', info.targetSdkVersion?.toString() ?? '未知'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 权限列表
          if (info.permissions.isNotEmpty) ...[
            _buildSectionTitle('权限列表 (${info.permissions.length})'),
            Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: info.permissions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.security, size: 16),
                  title: Text(info.permissions[i],
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 组件列表
          if (info.activities.isNotEmpty) ...[
            _buildSectionTitle('Activity (${info.activities.length})'),
            Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: min(info.activities.length, 20),
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.smartphone, size: 16),
                  title: Text(info.activities[i],
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildApkInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  /// Manifest XML 视图
  Widget _buildManifestXmlView() {
    String? manifestContent;
    for (final file in _files) {
      if (file.name == 'AndroidManifest.xml') {
        try {
          final bytes = file.content as List<int>;
          // AndroidManifest.xml 是二进制的 AXML 格式，需要反编译
          manifestContent = _decodeBinaryXml(bytes);
        } catch (e) {
          manifestContent = '无法解析 AndroidManifest.xml (二进制AXML格式)\n\n'
              '原始字节大小: ${file.size} bytes\n'
              '错误: $e';
        }
        break;
      }
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        manifestContent ?? '未找到 AndroidManifest.xml',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }

  /// 文件列表视图
  Widget _buildFileListView() {
    final files = _filteredFiles;

    // 统计信息
    final totalSize = _files.fold<int>(0, (sum, f) => sum + f.size);

    return Column(
      children: [
        // 统计信息栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          child: Row(
            children: [
              Text(
                '${_files.length} 个文件',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(width: 16),
              Text(
                '总大小: ${_formatSize(totalSize)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const Spacer(),
              if (_isApk)
                Chip(
                  label: const Text('APK', style: TextStyle(fontSize: 10)),
                  backgroundColor: Colors.deepPurple.withValues(alpha: 0.1),
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ),

        // 文件列表
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: _searchQuery.isNotEmpty
                      ? const Text('未找到匹配的文件')
                      : const Text('压缩包为空'),
                )
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) =>
                      _buildFileItem(files[index]),
                ),
        ),
      ],
    );
  }

  /// 构建单个文件项
  Widget _buildFileItem(ArchiveFile file) {
    final icon = _getFileIcon(file.name);
    final isDir = file.isFile == false;
    final color = _getFileColor(file.name);

    return ListTile(
      dense: true,
      leading: Icon(
        isDir ? Icons.folder : icon,
        size: 20,
        color: isDir ? Colors.amber : color,
      ),
      title: Text(
        file.name,
        style: const TextStyle(fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isDir ? '目录' : _formatSize(file.size),
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
      ),
      trailing: isDir
          ? const Icon(Icons.chevron_right, size: 16, color: Colors.grey)
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 16),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'preview',
                  child: Text('预览内容', style: TextStyle(fontSize: 13)),
                ),
                const PopupMenuItem(
                  value: 'extract',
                  child: Text('提取此文件', style: TextStyle(fontSize: 13)),
                ),
                if (_isApk && file.name.endsWith('.png') || file.name.endsWith('.jpg'))
                  const PopupMenuItem(
                    value: 'view_image',
                    child: Text('查看图片', style: TextStyle(fontSize: 13)),
                  ),
              ],
              onSelected: (action) => _onFileAction(file, action),
            ),
      onTap: () {
        if (isDir) {
          // TODO: 目录浏览
        } else {
          _previewFile(file);
        }
      },
    );
  }

  /// 文件操作
  void _onFileAction(ArchiveFile file, String action) {
    switch (action) {
      case 'preview':
        _previewFile(file);
        break;
      case 'extract':
        _extractFile(file);
        break;
      case 'view_image':
        _viewImageFile(file);
        break;
    }
  }

  /// 预览文件内容（支持文本/图片/视频/文档，v1.51.2+ 增强）
  void _previewFile(ArchiveFile file) {
    final ext = p.extension(file.name).toLowerCase();

    // 视频格式（v1.51.2+ 新增）
    const videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.3gp', '.m4v', '.ts'];
    // 图片格式
    const imageExts = ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg', '.ico', '.tiff', '.heic'];
    // 文档格式（v1.51.2+ 新增 PDF）
    const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.ods', '.odp'];

    if (videoExts.contains(ext)) {
      _previewVideoFile(file);
    } else if (imageExts.contains(ext)) {
      _viewImageFile(file);
    } else if (ext == '.pdf') {
      _previewPdfFile(file);
    } else {
      // 文本文件预览
      _previewTextFile(file);
    }
  }

  /// 预览视频文件（内置播放器，v1.51.2+ 新增）
  Future<void> _previewVideoFile(ArchiveFile file) async {
    try {
      // 文件大小限制：超过 200MB 的视频不预览
      if (file.size > 200 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('视频文件过大 (${_formatSize(file.size)})，请使用提取功能查看。')),
          );
        }
        return;
      }

      // 显示加载提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正在加载视频...'), duration: Duration(seconds: 1)),
        );
      }

      final bytes = file.content as List<int>;
      final dir = await getTemporaryDirectory();
      final tempPath = p.join(dir.path, 'temp_${p.basename(file.name)}');
      await File(tempPath).writeAsBytes(bytes);

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _VideoPreviewPage(filePath: tempPath, fileName: file.name),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('视频预览失败: ${e.toString().split("\\n").first}')),
        );
      }
    }
  }

  /// 预览PDF文件（内置PDF查看器，v1.51.2+ 新增）
  Future<void> _previewPdfFile(ArchiveFile file) async {
    try {
      // 文件大小限制：超过 50MB 的PDF不预览
      if (file.size > 50 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF文件过大 (${_formatSize(file.size)})，请使用提取功能查看。')),
          );
        }
        return;
      }

      final bytes = file.content as List<int>;
      final dir = await getTemporaryDirectory();
      final tempPath = p.join(dir.path, 'temp_${p.basename(file.name)}');
      await File(tempPath).writeAsBytes(bytes);

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _PdfPreviewPage(filePath: tempPath, fileName: file.name),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF预览失败: ${e.toString().split("\\n").first}')),
        );
      }
    }
  }

  /// 预览文本文件（v1.51.2+ 重构）
  void _previewTextFile(ArchiveFile file) {
    try {
      // 文件大小限制：超过 1MB 的文件不预览，避免卡死
      if (file.size > 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件过大 (${_formatSize(file.size)})，请使用提取功能查看。')),
          );
        }
        return;
      }

      final bytes = file.content as List<int>;
      final ext = p.extension(file.name).toLowerCase();
      final textExts = ['.txt', '.xml', '.json', '.html', '.css', '.js',
          '.dart', '.java', '.kt', '.py', '.yml', '.yaml', '.md', '.gradle',
          '.properties', '.pro', '.cmake', '.mk', '.cpp', '.h', '.c'];

      if (textExts.contains(ext) || file.name == 'AndroidManifest.xml') {
        // 对于 APK 中的 AndroidManifest.xml，尝试解析AXML
        if (file.name == 'AndroidManifest.xml' && _isApk) {
          setState(() {
            _previewContent = _decodeBinaryXml(bytes);
            _showPreview = true;
          });
        } else {
          setState(() {
            _previewContent = utf8.decode(bytes);
            _showPreview = true;
          });
        }
      } else {
        // 尝试作为文本解码
        try {
          final text = utf8.decode(bytes, allowMalformed: true);
          setState(() {
            _previewContent = '文件类型: $ext\n'
                '大小: ${_formatSize(file.size)}\n\n'
                '--- 文本预览 ---\n$text';
            _showPreview = true;
          });
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('无法预览 ${file.name} (二进制文件)')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('预览失败: ${e.toString().split("\\n").first}')),
        );
      }
    }
  }

  /// 提取单个文件
  Future<void> _extractFile(ArchiveFile file) async {
    try {
      final bytes = file.content as List<int>;
      final outputDir = await AppStorage.getOutputRootDirectory();
      final outputPath = p.join(outputDir.path, p.basename(file.name));
      await File(outputPath).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已提取到: $outputPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提取失败: $e')),
        );
      }
    }
  }

  /// 查看图片文件
  Future<void> _viewImageFile(ArchiveFile file) async {
    try {
      final bytes = file.content as List<int>;
      final dir = await getTemporaryDirectory();
      final tempPath = p.join(dir.path, 'temp_${p.basename(file.name)}');
      await File(tempPath).writeAsBytes(bytes);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(file.name)),
              body: Center(
                child: InteractiveViewer(
                  child: Image.file(File(tempPath)),
                ),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('查看图片失败: $e')),
        );
      }
    }
  }

  /// 选择压缩包文件
  Future<void> _pickArchive() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'rar', '7z', 'tar', 'gz', 'apk', 'aab',
            'jar', 'war', 'ear', 'bz2', 'xz', 'tgz', 'lz', 'lzma'],
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        return; // 用户取消
      }

      final filePath = result.files.single.path;
      if (filePath == null) {
        setState(() {
          _loading = false;
          _error = '无法获取文件路径';
        });
        return;
      }

      await _loadArchive(filePath);
    } catch (e) {
      AppLogger.e('PackageViewer', '选择文件失败: $e');
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 加载压缩文件
  Future<void> _loadArchive(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        setState(() {
          _loading = false;
          _error = '文件不存在';
        });
        return;
      }

      final fileName = p.basename(filePath);
      final ext = p.extension(filePath).toLowerCase();
      final isApk = ext == '.apk' || ext == '.aab' || ext == '.jar';
      final bytes = await file.readAsBytes();

      // 使用 archive 包解码 ZIP/APK 格式
      // APK 本质上就是 ZIP 格式
      Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (e) {
        // 尝试 Tar 解码
        try {
          archive = TarDecoder().decodeBytes(bytes);
        } catch (e2) {
          // 尝试 GZip 解码
          try {
            final gzBytes = GZipDecoder().decodeBytes(bytes);
            archive = TarDecoder().decodeBytes(gzBytes);
          } catch (e3) {
            setState(() {
              _loading = false;
              _error = '不支持的压缩格式或文件已损坏: ${e3.toString().split('\n').first}';
            });
            return;
          }
        }
      }

      // 转换为文件列表
      final files = archive.files.where((f) => !f.isFile || f.size > 0).toList();

      // 解析 APK 信息
      ApkInfo? apkInfo;
      if (isApk) {
        apkInfo = _parseApkInfo(archive);
      }

      if (mounted) {
        setState(() {
          _archivePath = filePath;
          _archiveName = fileName;
          _isApk = isApk;
          _apkInfo = apkInfo;
          _files = files;
          _loading = false;
          _error = null;
          _currentDir = '';
          _searchQuery = '';
          _showPreview = false;
          _previewContent = null;
          _sortFiles();
        });
      }

      AppLogger.i('PackageViewer', '加载压缩包成功: $fileName (${files.length} 个文件)');
    } catch (e) {
      AppLogger.e('PackageViewer', '加载压缩包失败: $e');
      setState(() {
        _loading = false;
        _error = '加载失败: $e';
      });
    }
  }

  /// 解析 APK 信息
  ApkInfo _parseApkInfo(Archive archive) {
    ApkInfo info = ApkInfo();

    try {
      // 查找并解析 AndroidManifest.xml（二进制 AXML 格式）
      final manifestFile = archive.find('AndroidManifest.xml') ??
          archive.files.cast<ArchiveFile?>().firstWhere(
              (f) => f?.name == 'AndroidManifest.xml', orElse: () => null);

      if (manifestFile != null) {
        final bytes = manifestFile.content as List<int>;
        _parseAxmL(bytes, info);
      }

      // 查找 resources.arsc 解析应用名
      final arscFile = archive.find('resources.arsc') ??
          archive.files.cast<ArchiveFile?>().firstWhere(
              (f) => f?.name == 'resources.arsc', orElse: () => null);

      if (arscFile != null) {
        // 简单从二进制的 resources.arsc 中搜索可能的应用名
        // 完整解析需要专门的 ARSC parser，这里做简化处理
        try {
          final arscBytes = arscFile.content as List<int>;
          final arscStr = utf8.decode(arscBytes, allowMalformed: true);
          // 尝试查找 app_name
          final nameMatch = RegExp(r'app_name.{0,20}([A-Za-z\u4e00-\u9fff]{2,30})')
              .firstMatch(arscStr);
          if (nameMatch != null && info.appName == null) {
            info = ApkInfo(
              packageName: info.packageName,
              appName: nameMatch.group(1),
              versionName: info.versionName,
              versionCode: info.versionCode,
              permissions: info.permissions,
              activities: info.activities,
              services: info.services,
              receivers: info.receivers,
            );
          }
        } catch (_) {}
      }
    } catch (e) {
      AppLogger.e('PackageViewer', '解析 APK 信息失败: $e');
    }

    return info;
  }

  /// 解析 AXML 二进制格式 (Android Binary XML)
  void _parseAxmL(List<int> bytes, ApkInfo info) {
    try {
      // AXML 解析是简化版，通过正则搜索关键信息
      final content = utf8.decode(bytes, allowMalformed: true);

      // 搜索包名（通常在 manifest 标签中）
      final pkgMatch = RegExp(r'package="([^"]+)"').firstMatch(content);
      if (pkgMatch != null) {
        info = ApkInfo(
          packageName: pkgMatch.group(1),
          appName: info.appName,
          versionName: info.versionName,
          versionCode: info.versionCode,
          permissions: info.permissions,
          activities: info.activities,
          services: info.services,
          receivers: info.receivers,
        );
      }

      // 搜索版本名
      final verNameMatch = RegExp(r'versionName="([^"]+)"').firstMatch(content);
      if (verNameMatch != null) {
        info = ApkInfo(
          packageName: info.packageName,
          appName: info.appName,
          versionName: verNameMatch.group(1),
          versionCode: info.versionCode,
          permissions: info.permissions,
          activities: info.activities,
          services: info.services,
          receivers: info.receivers,
        );
      }

      // 搜索版本号
      final verCodeMatch = RegExp(r'versionCode="([^"]+)"').firstMatch(content);
      if (verCodeMatch != null) {
        info = ApkInfo(
          packageName: info.packageName,
          appName: info.appName,
          versionName: info.versionName,
          versionCode: verCodeMatch.group(1),
          permissions: info.permissions,
          activities: info.activities,
          services: info.services,
          receivers: info.receivers,
        );
      }

      // 搜索权限
      final permissions = RegExp(r'uses-permission.*?android:name="([^"]+)"')
          .allMatches(content)
          .map((m) => m.group(1)!.split('.').last)
          .toList();
      if (permissions.isNotEmpty) {
        info = ApkInfo(
          packageName: info.packageName,
          appName: info.appName,
          versionName: info.versionName,
          versionCode: info.versionCode,
          permissions: permissions,
          activities: info.activities,
          services: info.services,
          receivers: info.receivers,
        );
      }

      // 搜索 Activity
      final activities = RegExp(r'<activity.*?android:name="([^"]+)"')
          .allMatches(content)
          .map((m) => m.group(1)!)
          .toList();
      if (activities.isNotEmpty) {
        info = ApkInfo(
          packageName: info.packageName,
          appName: info.appName,
          versionName: info.versionName,
          versionCode: info.versionCode,
          permissions: info.permissions,
          activities: activities,
          services: info.services,
          receivers: info.receivers,
        );
      }
    } catch (e) {
      AppLogger.e('PackageViewer', '解析 AXML 失败: $e');
    }
  }

  /// 解码二进制 XML 为可读文本
  String _decodeBinaryXml(List<int> bytes) {
    final sb = StringBuffer();
    sb.writeln('# AndroidManifest.xml (二进制AXML格式)');
    sb.writeln('# 大小: ${_formatSize(bytes.length)}');
    sb.writeln();

    try {
      // 尝试从中提取可读的字符串片段
      final content = utf8.decode(bytes, allowMalformed: true);

      // 提取所有可读的完整字符串（两个 null 字节之间或引号内）
      final strings = <String>[];
      final buffer = StringBuffer();
      bool inString = false;

      for (int i = 0; i < content.length; i++) {
        final char = content[i];
        if (char == '"') {
          if (inString) {
            strings.add(buffer.toString());
            buffer.clear();
            inString = false;
          } else {
            inString = true;
          }
        } else if (inString) {
          buffer.write(char);
        } else if (char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) < 127) {
          buffer.write(char);
        } else if (buffer.isNotEmpty) {
          final s = buffer.toString().trim();
          if (s.length > 2) {
            strings.add(s);
          }
          buffer.clear();
        }
      }

      if (buffer.isNotEmpty) {
        final s = buffer.toString().trim();
        if (s.length > 2) strings.add(s);
      }

      // 去重并过滤
      final unique = strings.where((s) =>
          s.length > 2 &&
          !s.startsWith(' ') &&
          !s.startsWith('\n')).toSet().toList();

      sb.writeln('## 可解析的字符串片段:');
      for (final s in unique) {
        sb.writeln('  - $s');
      }
    } catch (e) {
      sb.writeln('解析异常: $e');
    }

    return sb.toString();
  }

  /// 排序文件列表
  void _sortFiles() {
    setState(() {
      switch (_sortMode) {
        case _SortMode.name:
          _files.sort((a, b) => _ascending
              ? a.name.compareTo(b.name)
              : b.name.compareTo(a.name));
          break;
        case _SortMode.size:
          _files.sort((a, b) => _ascending
              ? a.size.compareTo(b.size)
              : b.size.compareTo(a.size));
          break;
        case _SortMode.type:
          _files.sort((a, b) {
            final extA = p.extension(a.name);
            final extB = p.extension(b.name);
            final cmp = extA.compareTo(extB);
            return _ascending ? cmp : -cmp;
          });
          break;
      }
    });
  }

  /// 获取文件图标
  IconData _getFileIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
        return Icons.image;
      case '.xml':
        return Icons.code;
      case '.dex':
        return Icons.android;
      case '.so':
        return Icons.memory;
      case '.arsc':
        return Icons.translate;
      case '.pro':
      case '.properties':
        return Icons.settings;
      case '.kotlin_module':
        return Icons.layers;
      default:
        return Icons.insert_drive_file;
    }
  }

  /// 获取文件颜色
  Color _getFileColor(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
        return Colors.pink;
      case '.xml':
        return Colors.orange;
      case '.dex':
        return Colors.green;
      case '.so':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// 构建 section 标题
  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ============================================================
// 内置视频预览页（v1.51.2+ 新增）
// ============================================================

/// 视频预览页面，使用内置 video_player 播放器
class _VideoPreviewPage extends StatefulWidget {
  final String filePath;
  final String fileName;

  const _VideoPreviewPage({required this.filePath, required this.fileName});

  @override
  State<_VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<_VideoPreviewPage> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _controller = VideoPlayerController.file(File(widget.filePath));
      await _controller.initialize();
      if (mounted) {
        setState(() => _isInitialized = true);
        _controller.addListener(() {
          if (mounted) setState(() {});
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '视频加载失败: $e');
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.fileName, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: _error.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    Text(_error, style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : !_isInitialized
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : GestureDetector(
                  onTap: () {
                    setState(() {
                      if (_controller.value.isPlaying) {
                        _controller.pause();
                      } else {
                        _controller.play();
                      }
                      _isPlaying = _controller.value.isPlaying;
                    });
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 视频画面
                      Center(child: AspectRatio(aspectRatio: _controller.value.aspectRatio, child: VideoPlayer(_controller))),
                      // 播放/暂停按钮
                      if (!_controller.value.isPlaying)
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.play_arrow, size: 40, color: Colors.white),
                        ),
                      // 底部控制栏
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          color: Colors.black54,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 进度条
                              Row(
                                children: [
                                  Text(
                                    _formatDuration(_controller.value.position),
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                        activeTrackColor: Colors.blue,
                                        inactiveTrackColor: Colors.white30,
                                        thumbColor: Colors.blue,
                                      ),
                                      child: Slider(
                                        value: _controller.value.position.inMilliseconds.toDouble().clamp(
                                          0.0,
                                          _controller.value.duration.inMilliseconds.toDouble(),
                                        ),
                                        max: _controller.value.duration.inMilliseconds.toDouble(),
                                        onChanged: (v) {
                                          _controller.seekTo(Duration(milliseconds: v.toInt()));
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _formatDuration(_controller.value.duration),
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

// ============================================================
// 内置PDF预览页（v1.51.2+ 新增）
// ============================================================

/// PDF预览页面，使用内置 flutter_pdfview 查看器
class _PdfPreviewPage extends StatefulWidget {
  final String filePath;
  final String fileName;

  const _PdfPreviewPage({required this.filePath, required this.fileName});

  @override
  State<_PdfPreviewPage> createState() => _PdfPreviewPageState();
}

class _PdfPreviewPageState extends State<_PdfPreviewPage> {
  int _totalPages = 0;
  int _currentPage = 1;
  bool _ready = false;
  String _error = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          if (_ready)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: _error.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    Text(_error, style: const TextStyle(fontSize: 14), textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : PDFView(
              filePath: widget.filePath,
              enableSwipe: true,
              swipeHorizontal: false,
              autoSpacing: true,
              pageFling: true,
              pageSnap: true,
              defaultPage: 0,
              fitPolicy: FitPolicy.WIDTH,
              onRender: (_pages) {
                if (mounted) setState(() {
                  _totalPages = _pages ?? 0;
                  _ready = true;
                });
              },
              onViewCreated: (controller) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (mounted) {
                    final pages = controller.getPageCount();
                    if (pages is Future) {
                      pages.then((count) {
                        if (mounted) setState(() {
                          _totalPages = count ?? 0;
                          _ready = true;
                        });
                      });
                    }
                  }
                });
              },
              onError: (error) {
                if (mounted) setState(() => _error = 'PDF加载失败: $error');
              },
              onPageChanged: (page, total) {
                if (mounted) setState(() {
                  _currentPage = page ?? 1;
                  _totalPages = total ?? 0;
                });
              },
            ),
    );
  }
}

/// 排序模式
enum _SortMode { name, size, type }

/// APK 查看模式
enum _ApkViewMode { fileList, apkInfo, manifestXml }