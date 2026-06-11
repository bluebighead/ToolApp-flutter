// 应用更新服务
// 负责检查服务器最新版本、下载APK并触发安装
// 支持强制更新（不更新则退出）和非强制更新（可跳过）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';

// 更新信息数据类
class AppUpdateInfo {
  final bool hasUpdate;
  final String? version;
  final int? buildNumber;
  final String? downloadUrl;
  final int? fileSize;
  final String? updateNotes;
  final bool forceUpdate;
  final String? message;

  AppUpdateInfo({
    required this.hasUpdate,
    this.version,
    this.buildNumber,
    this.downloadUrl,
    this.fileSize,
    this.updateNotes,
    this.forceUpdate = false,
    this.message,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      hasUpdate: json['hasUpdate'] ?? false,
      version: json['version'],
      buildNumber: json['buildNumber'],
      downloadUrl: json['downloadUrl'],
      fileSize: json['fileSize'],
      updateNotes: json['updateNotes'],
      forceUpdate: json['forceUpdate'] ?? false,
      message: json['message'],
    );
  }
}

class UpdateService {
  static const String _logTag = 'UpdateService';

  // 单例模式
  static final UpdateService instance = UpdateService._();
  UpdateService._();

  // 是否正在下载
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  // 下载进度（0.0 ~ 1.0）
  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  /// 检查更新（请求服务器）
  Future<AppUpdateInfo> checkForUpdate() async {
    try {
      final serverUrl = appSettings.serverUrl;
      if (serverUrl.isEmpty) {
        AppLogger.w(_logTag, '服务器地址未配置，跳过检查更新');
        return AppUpdateInfo(hasUpdate: false, message: '服务器地址未配置');
      }

      final url = Uri.parse('$serverUrl/api/app/version/check')
          .replace(queryParameters: {
        'platform': 'android',
        'buildNumber': AppInfo.buildNumber.toString(),
      });

      AppLogger.i(_logTag, '检查更新: $url');

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = _parseJson(response.body);
        if (json != null) {
          final info = AppUpdateInfo.fromJson(json);
          AppLogger.i(_logTag, '检查更新结果: hasUpdate=${info.hasUpdate}, version=${info.version}, force=${info.forceUpdate}');
          return info;
        }
      }

      AppLogger.w(_logTag, '检查更新失败: HTTP ${response.statusCode}');
      return AppUpdateInfo(hasUpdate: false, message: '检查更新失败');
    } catch (e) {
      AppLogger.e(_logTag, '检查更新异常: $e');
      return AppUpdateInfo(hasUpdate: false, message: '网络连接失败');
    }
  }

  /// 下载APK并触发安装
  /// onProgress: 下载进度回调（0.0 ~ 1.0）
  /// 返回true表示下载成功并已触发安装
  Future<bool> downloadAndInstall(
    String downloadUrl, {
    void Function(double progress)? onProgress,
  }) async {
    if (_isDownloading) return false;
    _isDownloading = true;
    _downloadProgress = 0.0;

    try {
      final serverUrl = appSettings.serverUrl;
      // 拼接完整下载URL
      String fullUrl;
      if (downloadUrl.startsWith('http')) {
        fullUrl = downloadUrl;
      } else {
        fullUrl = '$serverUrl$downloadUrl';
      }

      AppLogger.i(_logTag, '开始下载APK: $fullUrl');

      // 发起带进度监听的下载请求
      final request = http.Request('GET', Uri.parse(fullUrl));
      final response = await request.send();

      if (response.statusCode != 200) {
        AppLogger.e(_logTag, '下载APK失败: HTTP ${response.statusCode}');
        return false;
      }

      // 获取总大小
      final contentLength = response.contentLength ?? 0;

      // 保存到临时目录
      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/toolapp_update.apk';
      final file = File(filePath);
      final sink = file.openWrite();

      int receivedBytes = 0;

      await response.stream.forEach((chunk) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        if (contentLength > 0) {
          _downloadProgress = receivedBytes / contentLength;
        } else {
          // 无法获取总大小时，按已接收字节数估算进度
          _downloadProgress = receivedBytes > 0 ? 0.5 : 0.0;
        }

        onProgress?.call(_downloadProgress);
      });

      await sink.close();

      AppLogger.i(_logTag, 'APK下载完成: $filePath (${_formatFileSize(receivedBytes)})');

      // 触发安装
      final result = await OpenFilex.open(filePath);
      AppLogger.i(_logTag, '触发安装结果: ${result.type} - ${result.message}');

      return result.type == ResultType.done;
    } catch (e) {
      AppLogger.e(_logTag, '下载安装异常: $e');
      return false;
    } finally {
      _isDownloading = false;
      _downloadProgress = 0.0;
    }
  }

  /// 显示更新对话框
  /// forceUpdate为true时不可关闭，用户只能更新或退出
  static Future<void> showUpdateDialog(
    BuildContext context,
    AppUpdateInfo updateInfo,
  ) async {
    // 强制更新时不可关闭对话框
    final canDismiss = !updateInfo.forceUpdate;

    await showDialog(
      context: context,
      barrierDismissible: canDismiss,
      // 强制更新时禁用返回键关闭
      builder: (ctx) => PopScope(
        canPop: canDismiss,
        child: _UpdateDialog(updateInfo: updateInfo),
      ),
    );
  }

  /// 格式化文件大小
  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 安全解析JSON
  static Map<String, dynamic>? _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}

// 更新对话框组件
class _UpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;

  const _UpdateDialog({required this.updateInfo});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusText = '';

  @override
  Widget build(BuildContext context) {
    final info = widget.updateInfo;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text('发现新版本'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 版本信息
          Text(
            'v${info.version ?? "未知"} (Build ${info.buildNumber ?? "?"})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          // 更新说明
          if (info.updateNotes != null && info.updateNotes!.isNotEmpty) ...[
            const Text('更新说明：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Text(
                  info.updateNotes!,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          // 文件大小
          if (info.fileSize != null && info.fileSize! > 0)
            Text(
              '安装包大小：${UpdateService._formatFileSize(info.fileSize!)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          // 强制更新提示
          if (info.forceUpdate) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 18, color: Colors.orange.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '此为强制更新，更新后才能继续使用',
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // 下载进度
          if (_isDownloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 4),
            Text(
              _statusText,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ],
      ),
      actions: _isDownloading
          ? [] // 下载中不显示按钮
          : [
              // 非强制更新时显示"稍后再说"
              if (!info.forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('稍后再说'),
                ),
              // 强制更新时显示"退出应用"
              if (info.forceUpdate)
                TextButton(
                  onPressed: () => exit(0),
                  child: const Text('退出应用'),
                ),
              // "立即更新"按钮
              FilledButton(
                onPressed: _startDownload,
                child: const Text('立即更新'),
              ),
            ],
    );
  }

  // 开始下载APK
  Future<void> _startDownload() async {
    if (widget.updateInfo.downloadUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载链接无效')),
      );
      return;
    }

    setState(() {
      _isDownloading = true;
      _statusText = '正在下载...';
      _progress = 0.0;
    });

    final success = await UpdateService.instance.downloadAndInstall(
      widget.updateInfo.downloadUrl!,
      onProgress: (progress) {
        if (mounted) {
          setState(() {
            _progress = progress;
            _statusText = '正在下载... ${(progress * 100).toStringAsFixed(0)}%';
          });
        }
      },
    );

    if (!mounted) return;

    if (success) {
      setState(() {
        _statusText = '下载完成，请在系统安装界面完成安装';
        _progress = 1.0;
      });
    } else {
      setState(() {
        _isDownloading = false;
        _statusText = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载失败，请稍后重试')),
      );
    }
  }
}
