// 云音乐 Tab
// 从服务器获取歌曲列表并播放
// 每首歌旁有收藏按钮，顶部有收藏夹入口
import 'package:flutter/material.dart';

import '../../models/music_item.dart';
import '../../services/cloud_music_service.dart';
import '../../services/music_player_service.dart';
import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/top_toast.dart';
import 'favorites_page.dart';

class CloudPlayerTab extends StatefulWidget {
  const CloudPlayerTab({super.key});

  @override
  State<CloudPlayerTab> createState() => _CloudPlayerTabState();
}

class _CloudPlayerTabState extends State<CloudPlayerTab> {
  // 播放器服务实例
  final MusicPlayerService _player = MusicPlayerService.instance;
  // 云音乐服务实例
  final CloudMusicService _cloudMusic = CloudMusicService.instance;

  // 云端歌曲列表
  List<MusicItem> _songs = [];

  // 是否正在加载
  bool _isLoading = false;

  // 收藏操作中的歌曲 ID 集合（防止重复点击）
  final Set<String> _favoritingIds = {};

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  // 从服务器加载歌曲列表
  Future<void> _loadSongs() async {
    setState(() => _isLoading = true);

    try {
      final songs = await _cloudMusic.getSongList();
      setState(() {
        _songs = songs;
        _isLoading = false;
      });
      AppLogger.i('CloudPlayer', '加载云端歌曲 ${songs.length} 首');
    } catch (e) {
      AppLogger.e('CloudPlayer', '加载云端歌曲失败: $e');
      setState(() => _isLoading = false);
    }
  }

  // 切换收藏状态
  Future<void> _toggleFavorite(MusicItem song) async {
    // 检查登录状态
    if (!AuthService.instance.isLoggedIn) {
      if (mounted) {
        TopToast.show(context, message: '请先登录后再收藏', type: ToastType.warning);
      }
      return;
    }

    // 防止重复点击
    if (_favoritingIds.contains(song.id)) return;
    _favoritingIds.add(song.id);

    try {
      final isFavorite = await _cloudMusic.toggleFavorite(song);
      if (mounted) {
        setState(() {}); // 刷新 UI
        TopToast.show(
          context,
          message: isFavorite ? '已添加到收藏' : '已取消收藏',
          type: ToastType.success,
        );
      }
    } catch (e) {
      AppLogger.e('CloudPlayer', '收藏操作失败: $e');
    } finally {
      _favoritingIds.remove(song.id);
    }
  }

  // 播放指定歌曲
  void _playSong(int index) {
    _player.setPlaylist(_songs, startIndex: index);
    _player.playAtIndex(index);
  }

  // 跳转到收藏夹页面
  void _openFavorites() {
    if (!AuthService.instance.isLoggedIn) {
      TopToast.show(context, message: '请先登录后查看收藏', type: ToastType.warning);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FavoritesPage()),
    ).then((_) {
      // 从收藏夹返回后刷新列表，更新收藏状态
      _loadSongs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // 顶部操作栏：刷新 + 收藏夹入口
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // 刷新按钮
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _loadSongs,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(_isLoading ? '加载中...' : '刷新列表'),
                ),
              ),
              const SizedBox(width: 8),
              // 收藏夹按钮
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openFavorites,
                  icon: const Icon(Icons.favorite, size: 18),
                  label: const Text('收藏夹'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade400,
                    side: BorderSide(color: Colors.red.shade200),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 歌曲数量统计
        if (_songs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
          Icon(Icons.cloud_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            '暂无云端音乐',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '点击"刷新列表"获取服务器音乐\n或检查网络连接',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  // 构建歌曲列表项（含收藏按钮）
  Widget _buildSongItem(MusicItem song, int index, ThemeData theme) {
    // 判断是否为当前播放的歌曲
    final isCurrentPlaying = _player.currentSong?.id == song.id;
    // 是否正在收藏操作中
    final isFavoriting = _favoritingIds.contains(song.id);

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
              : Icons.cloud,
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
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
      // 收藏按钮
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 收藏心形按钮
          IconButton(
            onPressed: isFavoriting ? null : () => _toggleFavorite(song),
            icon: isFavoriting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    song.isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: song.isFavorite ? Colors.red.shade400 : Colors.grey.shade400,
                    size: 22,
                  ),
            tooltip: song.isFavorite ? '取消收藏' : '添加收藏',
          ),
        ],
      ),
      onTap: () => _playSong(index),
    );
  }
}
