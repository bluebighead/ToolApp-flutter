// 本地播放器 Tab
// 支持自动扫描设备音乐目录和手动选择文件
// 提供播放/暂停、上一首/下一首等控制功能
// 使用 Isolate 后台扫描加速，支持多种音频格式
// 扫描时显示进度百分比
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/music_item.dart';
import '../../services/music_player_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/top_toast.dart';

// 支持的音频文件扩展名（完整列表）
const kAudioExtensions = [
  // 无损格式
  '.flac', '.ape', '.alac', '.wav', '.aiff', '.wv', '.tta',
  // 有损格式
  '.mp3', '.aac', '.ogg', '.opus', '.wma', '.m4a', '.mp4',
  '.m4b', '.m4r', '.3gp', '.ac3', '.dts', '.amr', '.awb',
  // 其他格式
  '.mid', '.midi', '.xmf', '.rtttl', '.rtx', '.ota', '.imy',
];

// 扫描时跳过的目录名（仅系统/无关目录）
const kSkipDirectories = {
  // Android 系统目录
  'Android', 'android',
  // 系统资源目录
  'DCIM', 'Alarms', 'Notifications', 'Ringtones',
  // 缓存和临时目录
  'cache', 'Cache', 'CACHE',
  'temp', 'Temp', 'TEMP',
  'tmp', 'Tmp',
  // 应用数据目录
  'data', 'Data',
  'obb', 'OBB',
  // 系统目录
  'system', 'System',
  'lost+found',
  // 缩略图
  'thumbnails', 'Thumbnails',
};

class LocalPlayerTab extends StatefulWidget {
  const LocalPlayerTab({super.key});

  @override
  State<LocalPlayerTab> createState() => _LocalPlayerTabState();
}

class _LocalPlayerTabState extends State<LocalPlayerTab> {
  // 播放器服务实例
  final MusicPlayerService _player = MusicPlayerService.instance;

  // 本地歌曲列表
  List<MusicItem> _songs = [];

  // 是否正在加载
  bool _isLoading = false;

  // 扫描进度（0.0 ~ 1.0）
  double _scanProgress = 0;

  // 已扫描的文件数
  int _scannedCount = 0;

  // 已发现的音乐文件数
  int _foundCount = 0;

  // 预估总目录数（用于进度计算）
  int _totalDirs = 0;

  // 已扫描目录数
  int _scannedDirs = 0;

  @override
  void initState() {
    super.initState();
    _scanLocalMusic();
  }

  // 扫描设备本地音乐
  // 使用主线程扫描以支持实时进度更新
  Future<void> _scanLocalMusic() async {
    setState(() {
      _isLoading = true;
      _scanProgress = 0;
      _scannedCount = 0;
      _foundCount = 0;
      _scannedDirs = 0;
    });

    try {
      // 请求权限
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        if (mounted) {
          TopToast.show(context, message: '需要存储权限才能扫描本地音乐', type: ToastType.error);
        }
        setState(() => _isLoading = false);
        return;
      }

      // 获取要扫描的目录路径列表
      final dirPaths = _getMusicDirectoryPaths();

      // 第一遍：快速统计目录数（用于进度计算）
      _totalDirs = 0;
      for (final dirPath in dirPaths) {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          _totalDirs++;
        }
      }

      // 第二遍：实际扫描
      final List<MusicItem> foundSongs = [];
      final seen = <String>{};

      for (int i = 0; i < dirPaths.length; i++) {
        final dir = Directory(dirPaths[i]);
        if (await dir.exists()) {
          await _scanDirectoryWithProgress(dir, foundSongs, seen, maxDepth: 5);
          _scannedDirs++;
        }
        // 更新进度
        if (mounted) {
          setState(() {
            _scanProgress = _totalDirs > 0 ? _scannedDirs / _totalDirs : 0;
            _foundCount = foundSongs.length;
          });
        }
      }

      setState(() {
        _songs = foundSongs;
        _isLoading = false;
        _scanProgress = 1.0;
      });

      AppLogger.i('LocalPlayer', '扫描完成，找到 ${foundSongs.length} 首本地音乐');
      if (mounted && foundSongs.isNotEmpty) {
        TopToast.show(context, message: '扫描完成，找到 ${foundSongs.length} 首音乐', type: ToastType.success);
      } else if (mounted) {
        TopToast.show(context, message: '未找到本地音乐文件', type: ToastType.warning);
      }
    } catch (e) {
      AppLogger.e('LocalPlayer', '扫描本地音乐失败: $e');
      setState(() => _isLoading = false);
    }
  }

  // 带进度更新的目录扫描
  Future<void> _scanDirectoryWithProgress(
    Directory dir,
    List<MusicItem> songs,
    Set<String> seen, {
    int maxDepth = 5,
    int currentDepth = 0,
  }) async {
    if (currentDepth > maxDepth) return;

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          _scannedCount++;
          final filePath = entity.path;
          final dotIndex = filePath.lastIndexOf('.');
          if (dotIndex < 0) continue;
          final ext = filePath.substring(dotIndex).toLowerCase();
          if (!kAudioExtensions.contains(ext)) continue;

          // 去重
          if (seen.contains(filePath)) continue;
          seen.add(filePath);

          // 提取文件名
          final fileName = filePath.split(Platform.pathSeparator).last;
          try {
            final fileSize = await entity.length();
            songs.add(MusicItem.fromLocalFile(
              filePath: filePath,
              fileName: fileName,
              fileSize: fileSize,
            ));
            _foundCount++;
          } catch (_) {
            // 文件无法访问，跳过
          }

          // 每发现一定数量文件后更新进度
          if (_scannedCount % 50 == 0 && mounted) {
            setState(() {
              _foundCount = songs.length;
            });
          }
        } else if (entity is Directory) {
          final dirName = entity.path.split(Platform.pathSeparator).last;
          // 跳过隐藏目录和无关系统目录
          if (!dirName.startsWith('.') && !kSkipDirectories.contains(dirName)) {
            await _scanDirectoryWithProgress(
              entity, songs, seen,
              maxDepth: maxDepth,
              currentDepth: currentDepth + 1,
            );
          }
        }
      }
    } catch (_) {
      // 目录无法访问，跳过
    }
  }

  // 请求存储权限
  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      // Android 13 (API 33) 及以上：请求音频权限
      final audioStatus = await Permission.audio.request();
      if (audioStatus.isGranted) return true;

      // Android 12 及以下：请求存储权限
      final storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) return true;

      // 管理外部存储（Android 11+）
      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return true;

      return false;
    }
    return true;
  }

  // 获取设备上的音乐目录路径列表
  List<String> _getMusicDirectoryPaths() {
    final List<String> paths = [];

    if (Platform.isAndroid) {
      const storageRoot = '/storage/emulated/0';

      // 常见音乐目录
      final musicPaths = [
        '$storageRoot/Music',
        '$storageRoot/music',
        '$storageRoot/Download',
        '$storageRoot/Downloads',
        '$storageRoot/下载',
        '$storageRoot/音乐',
        '$storageRoot/录音',
        '$storageRoot/Recordings',
        '$storageRoot/MIUI/music',
        '$storageRoot/cloud/music',
        '$storageRoot/netease/cloudmusic/Music',
        '$storageRoot/qqmusic/song',
        '$storageRoot/kgmusic/download',
        '$storageRoot/kugou/song',
        '$storageRoot/kuwo/music',
      ];

      for (final p in musicPaths) {
        paths.add(p);
      }

      // 也扫描存储根目录（深度5层，跳过无关目录）
      paths.add(storageRoot);

      // SD 卡路径
      try {
        final sdCard = Directory('/storage/sdcard1');
        if (sdCard.existsSync()) {
          paths.add('/storage/sdcard1/Music');
          paths.add('/storage/sdcard1/music');
          paths.add('/storage/sdcard1');
        }
      } catch (_) {}
    }

    return paths;
  }

  // 手动选择音频文件
  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final List<MusicItem> newSongs = [];
        for (final file in result.files) {
          if (file.path != null) {
            newSongs.add(MusicItem.fromLocalFile(
              filePath: file.path!,
              fileName: file.name,
              fileSize: file.size,
            ));
          }
        }

        setState(() {
          for (final song in newSongs) {
            if (!_songs.any((s) => s.id == song.id)) {
              _songs.add(song);
            }
          }
        });

        AppLogger.i('LocalPlayer', '手动添加 ${newSongs.length} 首音乐');
      }
    } catch (e) {
      AppLogger.e('LocalPlayer', '选择文件失败: $e');
    }
  }

  // 播放指定歌曲
  void _playSong(int index) {
    _player.setPlaylist(_songs, startIndex: index);
    _player.playAtIndex(index);
  }

  // 显示支持的音频格式说明
  void _showFormatInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, size: 20),
            SizedBox(width: 8),
            Text('支持的音频格式'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 无损格式
              _buildFormatSection('无损格式', [
                'FLAC (.flac)', 'APE (.ape)', 'ALAC (.alac)',
                'WAV (.wav)', 'AIFF (.aiff)', 'WavPack (.wv)', 'TTA (.tta)',
              ], Icons.high_quality, Colors.purple),
              const SizedBox(height: 12),
              // 有损格式
              _buildFormatSection('有损格式', [
                'MP3 (.mp3)', 'AAC (.aac)', 'OGG (.ogg)',
                'Opus (.opus)', 'WMA (.wma)', 'M4A (.m4a)',
                'MP4 (.mp4)', 'M4B (.m4b)', 'AC3 (.ac3)', 'DTS (.dts)',
              ], Icons.music_note, Colors.blue),
              const SizedBox(height: 12),
              // 其他格式
              _buildFormatSection('其他格式', [
                'MIDI (.mid/.midi)', 'AMR (.amr)', '3GP (.3gp)',
                'XMF (.xmf)', 'iMelody (.imy)',
              ], Icons.library_music, Colors.teal),
              const SizedBox(height: 16),
              // 提示
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lightbulb_outline, size: 16, color: Colors.blue.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '将同名 .lrc 文件放在音频同目录下，即可显示歌词',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // 构建格式分类区块
  Widget _buildFormatSection(String title, List<String> formats, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: formats.map((f) => Chip(
            label: Text(f, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // 顶部操作栏：扫描 + 手动添加 + 格式说明
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // 扫描按钮（带进度显示）
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _scanLocalMusic,
                  icon: _isLoading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // 进度环
                              CircularProgressIndicator(
                                strokeWidth: 2,
                                value: _scanProgress > 0 ? _scanProgress : null,
                                color: theme.colorScheme.primary,
                              ),
                              // 百分比文字
                              Text(
                                '${(_scanProgress * 100).toInt()}',
                                style: TextStyle(
                                  fontSize: 7,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(_isLoading
                      ? '扫描中 ${(_scanProgress * 100).toInt()}%'
                      : '扫描音乐'),
                ),
              ),
              const SizedBox(width: 8),
              // 手动添加按钮
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加文件'),
                ),
              ),
              const SizedBox(width: 8),
              // 格式说明按钮
              SizedBox(
                height: 36,
                width: 36,
                child: IconButton(
                  onPressed: _showFormatInfo,
                  icon: const Icon(Icons.help_outline, size: 18),
                  padding: EdgeInsets.zero,
                  tooltip: '支持格式',
                ),
              ),
            ],
          ),
        ),

        // 扫描进度条（扫描中显示）
        if (_isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                // 线性进度条
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _scanProgress > 0 ? _scanProgress : null,
                    minHeight: 4,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 4),
                // 进度文字
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '已扫描 $_scannedCount 个文件',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                    Text(
                      '发现 $_foundCount 首音乐',
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // 歌曲数量统计
        if (_songs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '共 ${_songs.length} 首歌曲',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
          ),

        const SizedBox(height: 4),

        // 歌曲列表
        Expanded(
          child: _songs.isEmpty && !_isLoading
              ? _buildEmptyView(theme)
              : ListView.builder(
                  itemCount: _songs.length,
                  itemBuilder: (context, index) {
                    return _buildSongItem(_songs[index], index, theme);
                  },
                ),
        ),
      ],
    );
  }

  // 构建空状态视图
  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_note_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            '暂无本地音乐',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '点击"扫描音乐"自动扫描设备\n或点击"添加文件"手动选择',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  // 构建歌曲列表项
  Widget _buildSongItem(MusicItem song, int index, ThemeData theme) {
    final isCurrentPlaying = _player.currentSong?.id == song.id;

    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isCurrentPlaying
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          isCurrentPlaying && _player.isPlaying
              ? Icons.equalizer
              : Icons.music_note,
          color: isCurrentPlaying
              ? theme.colorScheme.primary
              : Colors.grey.shade500,
          size: 22,
        ),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isCurrentPlaying ? FontWeight.w600 : FontWeight.normal,
          color: isCurrentPlaying ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        '${song.artist}${song.formattedFileSize.isNotEmpty ? ' · ${song.formattedFileSize}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
      trailing: isCurrentPlaying && _player.isPlaying
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            )
          : null,
      onTap: () => _playSong(index),
    );
  }
}
