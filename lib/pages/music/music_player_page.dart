// 音乐播放器主页面
// 上方有两个 Tab：本地播放器 / 云音乐
// 底部迷你播放栏，点击空白处展开全屏播放器
import 'package:flutter/material.dart';

import '../../models/music_item.dart';
import '../../services/music_player_service.dart';
import '../../services/cloud_music_service.dart';
import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/top_toast.dart';
import 'cloud_player_tab.dart';
import 'full_screen_player.dart';
import 'local_player_tab.dart';

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  // Tab 控制器
  late TabController _tabController;

  // 播放器服务实例
  final MusicPlayerService _player = MusicPlayerService.instance;

  @override
  void initState() {
    super.initState();
    // 初始化 Tab 控制器，2 个 Tab
    _tabController = TabController(length: 2, vsync: this);
    // 初始化播放器
    _player.init();
    // 监听播放器状态变化以刷新 UI
    _player.addListener(_onPlayerStateChanged);
    AppLogger.i('MusicPlayer', '音乐播放器页面已创建');
  }

  @override
  void dispose() {
    _tabController.dispose();
    _player.removeListener(_onPlayerStateChanged);
    super.dispose();
  }

  // 播放器状态变化回调
  void _onPlayerStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // 打开全屏播放器
  void _openFullScreenPlayer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (context) => const SizedBox(
        height: double.infinity,
        child: FullScreenPlayer(),
      ),
    );
  }

  // 切换收藏状态
  Future<void> _toggleFavorite(MusicItem song) async {
    if (!song.isCloud) {
      TopToast.show(context, message: '本地歌曲暂不支持收藏', type: ToastType.info);
      return;
    }

    if (!AuthService.instance.isLoggedIn) {
      TopToast.show(context, message: '请先登录后再收藏', type: ToastType.warning);
      return;
    }

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
      AppLogger.e('MusicPlayerPage', '收藏操作失败: $e');
      if (mounted) {
        TopToast.show(context, message: '收藏操作失败', type: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 底部安全区域高度
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐播放器'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            // 本地播放器 Tab
            Tab(
              icon: Icon(Icons.phone_android),
              text: '本地播放',
            ),
            // 云音乐 Tab
            Tab(
              icon: Icon(Icons.cloud),
              text: '云音乐',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Tab 内容区域
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                // 本地播放器
                LocalPlayerTab(),
                // 云音乐
                CloudPlayerTab(),
              ],
            ),
          ),
          // 底部迷你播放栏（仅在有歌曲播放时显示）
          if (_player.currentSong != null)
            _buildMiniPlayerBar(theme, bottomPadding),
        ],
      ),
    );
  }

  // 构建底部迷你播放栏
  // 点击空白区域展开全屏播放器
  // 包含：上一首、封面、歌曲信息、播放/暂停、下一首、播放模式、收藏
  Widget _buildMiniPlayerBar(ThemeData theme, double bottomPadding) {
    final song = _player.currentSong!;

    return GestureDetector(
      // 点击空白区域展开全屏播放器
      onTap: _openFullScreenPlayer,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
          border: Border(
            top: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 迷你进度条（细线样式）
            _buildMiniProgressBar(theme),
            // 歌曲信息 + 控制按钮
            Padding(
              // 增加垂直 padding 抬高播放栏，底部加上安全区域
              padding: EdgeInsets.only(
                left: 4,
                right: 4,
                top: 10,
                bottom: bottomPadding + 10,
              ),
              child: Row(
                children: [
                  // 封面缩略图
                  _buildMiniCover(song, theme),
                  const SizedBox(width: 8),
                  // 歌曲信息（可点击展开）
                  Expanded(
                    child: GestureDetector(
                      onTap: _openFullScreenPlayer,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            song.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 上一首按钮（紧靠播放暂停按钮左边）
                  IconButton(
                    onPressed: _player.playPrevious,
                    icon: const Icon(Icons.skip_previous, size: 24),
                    color: theme.colorScheme.onSurface,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  // 加载中动画 / 播放暂停按钮
                  _player.isLoading
                      ? SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : IconButton(
                          onPressed: _player.togglePlayPause,
                          icon: Icon(
                            _player.isPlaying ? Icons.pause : Icons.play_arrow,
                            size: 30,
                          ),
                          color: theme.colorScheme.onSurface,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        ),
                  // 下一首按钮
                  IconButton(
                    onPressed: _player.playNext,
                    icon: const Icon(Icons.skip_next, size: 24),
                    color: theme.colorScheme.onSurface,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  // 播放模式切换按钮
                  IconButton(
                    onPressed: () {
                      _player.togglePlayMode();
                      TopToast.show(context, message: _player.playModeText, type: ToastType.info);
                    },
                    icon: Icon(_player.playModeIcon, size: 20),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  // 收藏按钮
                  IconButton(
                    onPressed: () => _toggleFavorite(song),
                    icon: Icon(
                      song.isFavorite ? Icons.favorite : Icons.favorite_border,
                      size: 20,
                    ),
                    color: song.isFavorite ? Colors.red : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 构建迷你封面缩略图
  Widget _buildMiniCover(MusicItem song, ThemeData theme) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: song.isCloud && song.coverUrl != null
            ? Image.network(
                song.coverUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.music_note,
                  color: theme.colorScheme.primary,
                ),
              )
            : Icon(
                Icons.music_note,
                color: theme.colorScheme.primary,
              ),
      ),
    );
  }

  // 构建迷你进度条（细线样式，无滑块）
  Widget _buildMiniProgressBar(ThemeData theme) {
    final duration = _player.duration > 0 ? _player.duration : 1;
    final position = _player.position.clamp(0, duration);
    final progress = position / duration;

    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        value: progress.clamp(0.0, 1.0),
        backgroundColor: Colors.grey.shade200,
        valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
      ),
    );
  }
}
