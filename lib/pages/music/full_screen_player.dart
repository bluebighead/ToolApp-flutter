// 全屏展开播放器
// 从底部滑出的全屏播放界面
// 左右滑动切换：播放页（封面+控制）/ 歌词页
// 参考网易云/Apple Music 风格设计
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../models/music_item.dart';
import '../../services/cloud_music_service.dart';
import '../../services/music_player_service.dart';
import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';
import '../../utils/lrc_parser.dart';
import '../../utils/top_toast.dart';

class FullScreenPlayer extends StatefulWidget {
  const FullScreenPlayer({super.key});

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer>
    with SingleTickerProviderStateMixin {
  // 播放器服务
  final MusicPlayerService _player = MusicPlayerService.instance;

  // 页面控制器（左右滑动切换）
  late PageController _pageController;

  // 当前页面索引
  int _currentPage = 0;

  // 解析后的歌词
  ParsedLyrics _lyrics = ParsedLyrics([]);

  // 歌词滚动控制器
  final ScrollController _lyricsScrollController = ScrollController();

  // 当前歌词行索引
  int _currentLyricIndex = -1;

  // 是否正在拖动进度条
  bool _isDragging = false;

  // 拖动时的临时进度值
  double _dragValue = 0;

  // 收藏操作中标记
  bool _isFavoriting = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _player.addListener(_onPlayerChanged);
    _loadLyrics();
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    _pageController.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  // 播放器状态变化回调
  void _onPlayerChanged() {
    if (!mounted) return;

    // 检查歌曲是否切换，切换时重新加载歌词
    if (_player.currentSong != null) {
      _loadLyrics();
    }

    // 更新歌词高亮
    if (_lyrics.isNotEmpty && !_isDragging) {
      final newIndex = _lyrics.getCurrentIndex(_player.position);
      if (newIndex != _currentLyricIndex) {
        setState(() => _currentLyricIndex = newIndex);
        _scrollToLyric(newIndex);
      }
    }

    setState(() {});
  }

  // 加载歌词
  Future<void> _loadLyrics() async {
    final song = _player.currentSong;
    if (song == null) return;

    try {
      if (song.isCloud) {
        // 云端歌曲：优先使用已缓存的歌词，否则从 API 获取
        if (song.lyrics != null && song.lyrics!.isNotEmpty && song.lyrics!.startsWith('[')) {
          _lyrics = LrcParser.parse(song.lyrics!);
        } else {
          _lyrics = await _fetchCloudLyrics(song.id);
        }
      } else if (song.localPath != null) {
        // 本地歌曲：从同名 .lrc 文件读取
        _lyrics = await LrcParser.fromLocalFile(song.localPath!);
      } else {
        _lyrics = ParsedLyrics([]);
      }
    } catch (e) {
      AppLogger.e('FullScreenPlayer', '加载歌词失败: $e');
      _lyrics = ParsedLyrics([]);
    }

    if (mounted) setState(() {});
  }

  // 从服务器 API 获取云端歌词
  Future<ParsedLyrics> _fetchCloudLyrics(String songId) async {
    try {
      final baseUrl = appSettings.serverUrl;
      final response = await http.get(
        Uri.parse('$baseUrl/api/music/songs/$songId/lyrics'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final lyricsText = data['lyrics'] as String? ?? '';
        if (lyricsText.isNotEmpty && lyricsText.startsWith('[')) {
          _player.currentSong?.lyrics = lyricsText;
          return LrcParser.parse(lyricsText);
        }
      }
      return ParsedLyrics([]);
    } catch (e) {
      AppLogger.e('FullScreenPlayer', '获取云端歌词失败: $e');
      return ParsedLyrics([]);
    }
  }

  // 滚动歌词到指定行
  void _scrollToLyric(int index) {
    if (!_lyricsScrollController.hasClients || index < 0) return;

    final targetOffset = (index * 48.0) - (_lyricsScrollController.position.viewportDimension / 2) + 24;
    final clampedOffset = targetOffset.clamp(0.0, _lyricsScrollController.position.maxScrollExtent);

    _lyricsScrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // 切换收藏状态
  Future<void> _toggleFavorite() async {
    final song = _player.currentSong;
    if (song == null) return;

    if (!song.isCloud) {
      TopToast.show(context, message: '本地歌曲暂不支持收藏', type: ToastType.info);
      return;
    }

    if (!AuthService.instance.isLoggedIn) {
      TopToast.show(context, message: '请先登录后再收藏', type: ToastType.warning);
      return;
    }

    if (_isFavoriting) return;
    setState(() => _isFavoriting = true);

    try {
      final isFavorite = await CloudMusicService.instance.toggleFavorite(song);
      if (mounted) {
        TopToast.show(
          context,
          message: isFavorite ? '已添加到收藏' : '已取消收藏',
          type: ToastType.success,
        );
      }
    } catch (e) {
      AppLogger.e('FullScreenPlayer', '收藏操作失败: $e');
      if (mounted) {
        TopToast.show(context, message: '收藏操作失败', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _isFavoriting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = _player.currentSong;
    if (song == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    return Scaffold(
      // 透明背景，让渐变背景显示
      backgroundColor: Colors.transparent,
      body: Container(
        // 高透明度渐变背景
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.85),
              theme.colorScheme.primary.withValues(alpha: 0.6),
              theme.scaffoldBackgroundColor.withValues(alpha: 0.95),
            ],
          ),
        ),
        // 额外顶部间距
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            children: [
              // 顶部栏：下拉收起 + 歌曲名
              _buildTopBar(song, theme),

              // 中部内容区：可左右滑动
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                  },
                  children: [
                    // 左页：封面 + 歌曲信息 + 控制
                    _buildPlayPage(song, theme, size),
                    // 右页：歌词
                    _buildLyricsPage(song, theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建顶部栏
  Widget _buildTopBar(MusicItem song, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // 下拉收起按钮
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.keyboard_arrow_down, size: 28),
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
          const SizedBox(width: 8),
          // 歌曲名
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  song.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // 更多按钮
          IconButton(
            onPressed: () {},
            icon: Icon(Icons.more_horiz, color: Colors.white.withValues(alpha: 0.8)),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }

  // 构建播放页（封面 + 信息 + 控制）
  Widget _buildPlayPage(MusicItem song, ThemeData theme, Size size) {
    final coverSize = size.width * 0.6;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const SizedBox(height: 16),

          // 专辑封面（加载中时显示加载动画）
          _player.isLoading
              ? _buildLoadingCover(coverSize, theme)
              : _buildCoverArt(song, coverSize, theme),

          const SizedBox(height: 28),

          // 歌曲信息
          _buildSongInfo(song, theme),

          const SizedBox(height: 20),

          // 进度条
          _buildProgressBar(theme),

          const SizedBox(height: 12),

          // 播放控制按钮
          _buildControls(song, theme),

          const SizedBox(height: 12),

          // 附加操作栏
          _buildExtraActions(song, theme),

          const SizedBox(height: 16),

          // 页面指示器（内嵌在播放页底部）
          _buildPageIndicator(),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // 加载中的封面占位
  Widget _buildLoadingCover(double size, ThemeData theme) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: theme.colorScheme.primary,
              strokeWidth: 3,
            ),
            const SizedBox(height: 12),
            Text(
              '加载中...',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建封面
  Widget _buildCoverArt(MusicItem song, double size, ThemeData theme) {
    Widget coverImage;

    if (song.isCloud && song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      coverImage = Image.network(
        song.coverUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildDefaultCover(theme),
      );
    } else if (!song.isCloud && song.localCoverPath != null) {
      final coverFile = File(song.localCoverPath!);
      coverImage = FutureBuilder<bool>(
        future: coverFile.exists(),
        builder: (context, snapshot) {
          if (snapshot.data == true) {
            return Image.file(coverFile, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildDefaultCover(theme));
          }
          return _buildDefaultCover(theme);
        },
      );
    } else {
      coverImage = _buildDefaultCover(theme);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 30,
            offset: const Offset(0, 15),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: coverImage,
      ),
    );
  }

  // 默认封面（音符图标）
  Widget _buildDefaultCover(ThemeData theme) {
    return Container(
      color: theme.colorScheme.primary.withValues(alpha: 0.15),
      child: Center(
        child: Icon(
          Icons.music_note,
          size: 80,
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  // 构建歌曲信息
  Widget _buildSongInfo(MusicItem song, ThemeData theme) {
    return Column(
      children: [
        Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          song.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  // 构建进度条
  Widget _buildProgressBar(ThemeData theme) {
    final duration = _player.duration > 0 ? _player.duration : 1;
    final position = _player.position.clamp(0, duration);
    final progress = position / duration;
    final displayValue = _isDragging ? _dragValue : progress.clamp(0.0, 1.0);

    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: theme.colorScheme.primary,
            inactiveTrackColor: Colors.grey.shade300,
            thumbColor: theme.colorScheme.primary,
          ),
          child: Slider(
            value: displayValue,
            onChangeStart: (_) => setState(() => _isDragging = true),
            onChanged: (value) => setState(() => _dragValue = value),
            onChangeEnd: (value) {
              _player.seekTo((value * duration).toInt());
              setState(() {
                _isDragging = false;
                _dragValue = 0;
              });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _player.formatTime(_isDragging ? (_dragValue * duration).toInt() : position),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              Text(
                _player.formatTime(duration),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 构建播放控制按钮
  Widget _buildControls(MusicItem song, ThemeData theme) {
    final isFavorite = song.isCloud && song.isFavorite;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 播放模式（带弹窗提示）
        IconButton(
          onPressed: () {
            _player.togglePlayMode();
            TopToast.show(context, message: _player.playModeText, type: ToastType.info);
          },
          icon: Icon(_player.playModeIcon, size: 22),
          color: theme.colorScheme.primary,
          tooltip: _player.playModeText,
        ),
        // 上一首
        IconButton(
          onPressed: _player.playPrevious,
          icon: const Icon(Icons.skip_previous, size: 36),
          color: theme.colorScheme.onSurface,
        ),
        // 播放/暂停（大圆按钮，加载中显示加载动画）
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: _player.isLoading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                )
              : IconButton(
                  onPressed: _player.togglePlayPause,
                  icon: Icon(
                    _player.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 32,
                    color: Colors.white,
                  ),
                ),
        ),
        // 下一首
        IconButton(
          onPressed: _player.playNext,
          icon: const Icon(Icons.skip_next, size: 36),
          color: theme.colorScheme.onSurface,
        ),
        // 收藏按钮
        IconButton(
          onPressed: _isFavoriting ? null : _toggleFavorite,
          icon: _isFavoriting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                )
              : Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                ),
          color: isFavorite ? Colors.red.shade400 : Colors.grey.shade400,
          tooltip: isFavorite ? '取消收藏' : '添加收藏',
        ),
      ],
    );
  }

  // 附加操作栏（白色图标+粗体文字）
  Widget _buildExtraActions(MusicItem song, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildActionChip(Icons.playlist_play, '列表'),
        _buildActionChip(Icons.share_outlined, '分享'),
        _buildActionChip(Icons.timer_outlined, '定时'),
      ],
    );
  }

  // 操作按钮（白色图标 + 白色粗体文字）
  Widget _buildActionChip(IconData icon, String label) {
    return TextButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 18, color: Colors.white),
      label: Text(
        label,
        style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }

  // 构建歌词页
  Widget _buildLyricsPage(MusicItem song, ThemeData theme) {
    if (_lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lyrics_outlined, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text('暂无歌词', style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            if (!song.isCloud)
              Text(
                '将同名 .lrc 文件放在音频同目录下\n即可显示歌词',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
              ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _lyricsScrollController,
      padding: const EdgeInsets.symmetric(vertical: 200, horizontal: 32),
      itemCount: _lyrics.lines.length,
      itemBuilder: (context, index) {
        final line = _lyrics.lines[index];
        final isCurrent = index == _currentLyricIndex;

        return GestureDetector(
          onTap: () => _player.seekTo(line.timestamp),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              line.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isCurrent ? 18 : 15,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                color: isCurrent ? theme.colorScheme.primary : Colors.grey.shade500,
                height: 1.6,
              ),
            ),
          ),
        );
      },
    );
  }

  // 构建页面指示器
  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () => _pageController.animateToPage(0,
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut,
          ),
          child: Container(
            width: _currentPage == 0 ? 24 : 8,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: _currentPage == 0
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        GestureDetector(
          onTap: () => _pageController.animateToPage(1,
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut,
          ),
          child: Container(
            width: _currentPage == 1 ? 24 : 8,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: _currentPage == 1
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }
}
