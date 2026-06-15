// 收藏夹页面
// 展示用户收藏的云端歌曲列表
// 支持播放收藏歌曲和取消收藏操作
import 'package:flutter/material.dart';

import '../../models/music_item.dart';
import '../../services/cloud_music_service.dart';
import '../../services/music_player_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/top_toast.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  // 播放器服务实例
  final MusicPlayerService _player = MusicPlayerService.instance;
  // 云音乐服务实例
  final CloudMusicService _cloudMusic = CloudMusicService.instance;

  // 收藏列表
  List<MusicItem> _favorites = [];

  // 是否正在加载
  bool _isLoading = false;

  // 收藏操作中的歌曲 ID 集合
  final Set<String> _removingIds = {};

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  // 加载收藏列表
  Future<void> _loadFavorites() async {
    setState(() => _isLoading = true);

    try {
      final favorites = await _cloudMusic.getFavorites();
      setState(() {
        _favorites = favorites;
        _isLoading = false;
      });
      AppLogger.i('Favorites', '加载收藏 ${favorites.length} 首');
    } catch (e) {
      AppLogger.e('Favorites', '加载收藏失败: $e');
      setState(() => _isLoading = false);
    }
  }

  // 取消收藏
  Future<void> _removeFavorite(MusicItem song) async {
    if (_removingIds.contains(song.id)) return;
    _removingIds.add(song.id);

    try {
      final success = await _cloudMusic.removeFavorite(song.id);
      if (success) {
        setState(() {
          _favorites.removeWhere((s) => s.id == song.id);
        });
        if (mounted) {
          TopToast.show(context, message: '已取消收藏', type: ToastType.success);
        }
      }
    } catch (e) {
      AppLogger.e('Favorites', '取消收藏失败: $e');
    } finally {
      _removingIds.remove(song.id);
    }
  }

  // 播放收藏歌曲
  void _playSong(int index) {
    _player.setPlaylist(_favorites, startIndex: index);
    _player.playAtIndex(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _favorites.isEmpty
              ? _buildEmptyView(theme)
              : Column(
                  children: [
                    // 歌曲数量统计
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '共收藏 ${_favorites.length} 首歌曲',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                    ),
                    // 收藏列表
                    Expanded(
                      child: ListView.builder(
                        itemCount: _favorites.length,
                        itemBuilder: (context, index) {
                          return _buildSongItem(_favorites[index], index, theme);
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  // 构建空状态视图
  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            '暂无收藏',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '在云音乐中点击心形图标\n即可收藏喜欢的歌曲',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  // 构建歌曲列表项
  Widget _buildSongItem(MusicItem song, int index, ThemeData theme) {
    // 判断是否为当前播放的歌曲
    final isCurrentPlaying = _player.currentSong?.id == song.id;
    // 是否正在取消收藏中
    final isRemoving = _removingIds.contains(song.id);

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
              : Icons.favorite,
          color: isCurrentPlaying
              ? theme.colorScheme.primary
              : Colors.red.shade300,
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
      // 取消收藏按钮
      trailing: IconButton(
        onPressed: isRemoving ? null : () => _removeFavorite(song),
        icon: isRemoving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.delete_outline,
                color: Colors.grey.shade400,
                size: 22,
              ),
        tooltip: '取消收藏',
      ),
      onTap: () => _playSong(index),
    );
  }
}
