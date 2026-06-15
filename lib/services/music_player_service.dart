// 音频播放核心服务
// 封装 audioplayers 库，提供统一的播放控制接口
// 本地播放器和云音乐共用此服务
// 支持播放/暂停、上一首/下一首、进度控制等功能
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/music_item.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';

// 播放状态枚举
enum MusicPlayerState { stopped, playing, paused }

// 播放模式枚举
enum PlayMode { sequence, loop, shuffle }

class MusicPlayerService extends ChangeNotifier {
  // 全局单例
  static final MusicPlayerService instance = MusicPlayerService._();
  MusicPlayerService._();

  // audioplayers 播放器实例
  final AudioPlayer _player = AudioPlayer();

  // 当前播放列表
  List<MusicItem> _playlist = [];
  List<MusicItem> get playlist => _playlist;

  // 当前播放索引
  int _currentIndex = -1;
  int get currentIndex => _currentIndex;

  // 当前播放的歌曲
  MusicItem? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;

  // 播放状态
  MusicPlayerState _state = MusicPlayerState.stopped;
  MusicPlayerState get state => _state;
  bool get isPlaying => _state == MusicPlayerState.playing;
  bool get isPaused => _state == MusicPlayerState.paused;

  // 是否正在加载（准备播放中）
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  // 播放模式
  PlayMode _playMode = PlayMode.sequence;
  PlayMode get playMode => _playMode;

  // 当前播放进度（毫秒）
  int _position = 0;
  int get position => _position;

  // 歌曲总时长（毫秒）
  int _duration = 0;
  int get duration => _duration;

  // 播放进度流（供 UI 监听）
  Stream<Duration> get positionStream => _player.onPositionChanged;
  Stream<Duration> get durationStream => _player.onDurationChanged;
  Stream<void> get onCompleteStream => _player.onPlayerComplete;

  // 初始化播放器事件监听
  bool _initialized = false;

  // 初始化播放器
  void init() {
    if (_initialized) return;
    _initialized = true;

    // 监听播放状态变化
    _player.onPlayerStateChanged.listen((audioPlayerState) {
      // audioplayers 的 PlayerState 和自定义的 MusicPlayerState 不同
      AppLogger.d('MusicPlayer', '播放状态变化: $audioPlayerState');
    });

    // 监听播放完成
    _player.onPlayerComplete.listen((_) {
      AppLogger.i('MusicPlayer', '歌曲播放完成');
      _onSongComplete();
    });

    // 监听时长变化
    _player.onDurationChanged.listen((Duration d) {
      _duration = d.inMilliseconds;
      notifyListeners();
    });

    // 监听进度变化
    _player.onPositionChanged.listen((Duration d) {
      _position = d.inMilliseconds;
      notifyListeners();
    });

    // 监听播放错误
    _player.onLog.listen((String msg) {
      if (msg.contains('ERROR') || msg.contains('error')) {
        AppLogger.e('MusicPlayer', '播放器日志: $msg');
      }
    });

    AppLogger.i('MusicPlayer', '播放器服务已初始化');
  }

  // 设置播放列表
  void setPlaylist(List<MusicItem> songs, {int startIndex = 0}) {
    _playlist = List.from(songs);
    _currentIndex = startIndex;
    notifyListeners();
  }

  // 播放指定歌曲
  Future<void> play(MusicItem song) async {
    try {
      init(); // 确保已初始化

      // 查找歌曲在列表中的索引
      final index = _playlist.indexWhere((s) => s.id == song.id);
      if (index >= 0) {
        _currentIndex = index;
      }

      // 设置加载状态
      _isLoading = true;
      notifyListeners();

      // 根据歌曲来源设置播放源
      if (song.isCloud) {
        // 云端歌曲：通过服务器流式播放
        final serverUrl = appSettings.serverUrl;
        final url = '$serverUrl/api/music/songs/${song.id}/stream';
        await _player.play(UrlSource(url));
      } else if (song.localPath != null) {
        // 本地歌曲：播放本地文件
        await _player.play(DeviceFileSource(song.localPath!));
      }

      _isLoading = false;
      _state = MusicPlayerState.playing;
      AppLogger.i('MusicPlayer', '开始播放: ${song.title} - ${song.artist}');
      notifyListeners();
    } catch (e) {
      AppLogger.e('MusicPlayer', '播放失败: $e');
      _isLoading = false;
      _state = MusicPlayerState.stopped;
      notifyListeners();
    }
  }

  // 播放指定索引的歌曲
  Future<void> playAtIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;
    await play(_playlist[index]);
  }

  // 暂停播放
  Future<void> pause() async {
    await _player.pause();
    _state = MusicPlayerState.paused;
    notifyListeners();
  }

  // 恢复播放
  Future<void> resume() async {
    await _player.resume();
    _state = MusicPlayerState.playing;
    notifyListeners();
  }

  // 切换播放/暂停
  Future<void> togglePlayPause() async {
    if (_state == MusicPlayerState.playing) {
      await pause();
    } else if (_state == MusicPlayerState.paused) {
      await resume();
    } else if (currentSong != null) {
      await play(currentSong!);
    }
  }

  // 停止播放
  Future<void> stop() async {
    await _player.stop();
    _state = MusicPlayerState.stopped;
    _position = 0;
    notifyListeners();
  }

  // 播放上一首
  Future<void> playPrevious() async {
    if (_playlist.isEmpty) return;

    int prevIndex;
    if (_playMode == PlayMode.shuffle) {
      // 随机模式：随机选择一首
      prevIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
    } else {
      // 顺序/循环模式：播放上一首
      prevIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
    }

    await playAtIndex(prevIndex);
  }

  // 播放下一首
  Future<void> playNext() async {
    if (_playlist.isEmpty) return;

    int nextIndex;
    if (_playMode == PlayMode.shuffle) {
      // 随机模式：随机选择一首
      nextIndex = DateTime.now().millisecondsSinceEpoch % _playlist.length;
    } else {
      // 顺序/循环模式：播放下一首
      nextIndex = (_currentIndex + 1) % _playlist.length;
    }

    await playAtIndex(nextIndex);
  }

  // 歌曲播放完成后的处理
  void _onSongComplete() {
    if (_playMode == PlayMode.loop) {
      // 单曲循环：重新播放当前歌曲
      if (currentSong != null) {
        play(currentSong!);
      }
    } else {
      // 顺序/随机：播放下一首
      playNext();
    }
  }

  // 跳转到指定进度
  Future<void> seekTo(int milliseconds) async {
    await _player.seek(Duration(milliseconds: milliseconds));
  }

  // 切换播放模式
  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.sequence:
        _playMode = PlayMode.loop;
        break;
      case PlayMode.loop:
        _playMode = PlayMode.shuffle;
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.sequence;
        break;
    }
    AppLogger.i('MusicPlayer', '播放模式切换: $_playMode');
    notifyListeners();
  }

  // 获取播放模式图标
  IconData get playModeIcon {
    switch (_playMode) {
      case PlayMode.sequence:
        return Icons.repeat;
      case PlayMode.loop:
        return Icons.repeat_one;
      case PlayMode.shuffle:
        return Icons.shuffle;
    }
  }

  // 获取播放模式文字
  String get playModeText {
    switch (_playMode) {
      case PlayMode.sequence:
        return '顺序播放';
      case PlayMode.loop:
        return '单曲循环';
      case PlayMode.shuffle:
        return '随机播放';
    }
  }

  // 格式化时间显示
  String formatTime(int milliseconds) {
    if (milliseconds < 0) return '00:00';
    final minutes = (milliseconds / 60000).floor();
    final seconds = ((milliseconds % 60000) / 1000).floor();
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
