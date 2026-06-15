// 音乐数据模型
// 用于本地播放器和云音乐页面的歌曲信息展示
// 包含歌曲基本信息、来源标识、封面和歌词
class MusicItem {
  // 歌曲唯一标识（云端歌曲为服务器ID，本地歌曲为文件路径的哈希）
  final String id;
  // 歌曲标题
  final String title;
  // 艺术家/演唱者
  final String artist;
  // 专辑名称
  final String album;
  // 歌曲时长（毫秒），-1 表示未知
  final int duration;
  // 本地文件路径（本地歌曲使用）
  final String? localPath;
  // 是否为云端歌曲
  final bool isCloud;
  // 是否已收藏（仅云端歌曲使用）
  bool isFavorite;
  // 文件大小（字节），用于本地歌曲显示
  final int? fileSize;
  // 封面图片 URL（云端歌曲使用）
  final String? coverUrl;
  // 本地封面路径（与音频同目录的同名 jpg/png）
  final String? localCoverPath;
  // 歌词内容（LRC 格式原始文本）
  String? lyrics;

  MusicItem({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.duration = -1,
    this.localPath,
    this.isCloud = false,
    this.isFavorite = false,
    this.fileSize,
    this.coverUrl,
    this.localCoverPath,
    this.lyrics,
  });

  // 从本地文件信息创建 MusicItem
  // 根据文件路径和名称解析歌曲信息
  factory MusicItem.fromLocalFile({
    required String filePath,
    required String fileName,
    int fileSize = 0,
  }) {
    // 尝试从文件名中解析标题和艺术家
    // 常见格式："艺术家 - 标题.mp3" 或 "标题.mp3"
    String title = fileName;
    String artist = '未知艺术家';
    String album = '';

    // 去除扩展名
    final nameWithoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

    // 尝试按 " - " 分割艺术家和标题
    if (nameWithoutExt.contains(' - ')) {
      final parts = nameWithoutExt.split(' - ');
      artist = parts[0].trim();
      title = parts.sublist(1).join(' - ').trim();
    } else {
      title = nameWithoutExt;
    }

    // 尝试查找本地封面（同名 jpg/png）
    final dir = filePath.substring(0, filePath.lastIndexOf('/'));
    final baseName = nameWithoutExt;
    String? localCoverPath;
    // 封面优先级：同名文件 > cover.jpg > folder.jpg
    for (final coverName in ['$baseName.jpg', '$baseName.png', 'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png']) {
      final coverPath = '$dir/$coverName';
      // 注意：这里不检查文件是否存在，在显示时再判断
      // 避免扫描时过多的文件系统 IO
      localCoverPath = coverPath;
      break;
    }

    // 尝试查找同名 LRC 歌词文件
    final lrcPath = '${filePath.substring(0, filePath.lastIndexOf('.'))}.lrc';

    return MusicItem(
      id: 'local_$filePath',
      title: title,
      artist: artist,
      album: album,
      localPath: filePath,
      isCloud: false,
      fileSize: fileSize,
      localCoverPath: localCoverPath,
      lyrics: lrcPath, // 暂存路径，加载时再读取内容
    );
  }

  // 从服务器 JSON 数据创建 MusicItem
  factory MusicItem.fromJson(Map<String, dynamic> json) {
    return MusicItem(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? '未知歌曲',
      artist: json['artist'] ?? '未知艺术家',
      album: json['album'] ?? '',
      duration: json['duration'] ?? -1,
      isCloud: true,
      isFavorite: json['is_favorite'] == true || json['is_favorite'] == 1,
      coverUrl: json['cover_url'],
      lyrics: json['lyrics'],
    );
  }

  // 格式化时长显示（mm:ss）
  String get formattedDuration {
    if (duration < 0) return '--:--';
    final minutes = (duration / 60000).floor();
    final seconds = ((duration % 60000) / 1000).floor();
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // 格式化文件大小显示
  String get formattedFileSize {
    if (fileSize == null || fileSize! <= 0) return '';
    if (fileSize! < 1024) return '$fileSize B';
    if (fileSize! < 1024 * 1024) return '${(fileSize! / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // 获取副标题文本（艺术家 · 专辑）
  String get subtitle {
    if (album.isNotEmpty && album != '未知专辑') {
      return '$artist · $album';
    }
    return artist;
  }
}
