// 云音乐 API 服务
// 封装与服务端的 HTTP 通信，提供歌曲列表获取、收藏管理等功能
// 依赖 AuthService 获取认证令牌
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/music_item.dart';
import '../services/auth_service.dart';
import '../utils/app_logger.dart';
import '../utils/app_settings.dart';

class CloudMusicService {
  // 全局单例
  static final CloudMusicService instance = CloudMusicService._();
  CloudMusicService._();

  // 获取服务器基础 URL
  String get _baseUrl => appSettings.serverUrl;

  // 获取认证请求头
  Map<String, String> get _authHeaders {
    final token = AuthService.instance.token;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // 获取云音乐歌曲列表
  // 返回服务器上所有可播放的歌曲
  Future<List<MusicItem>> getSongList() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/music/songs'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> songs = data['songs'] ?? [];
        return songs.map((json) => MusicItem.fromJson(json)).toList();
      } else {
        AppLogger.e('CloudMusic', '获取歌曲列表失败: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      AppLogger.e('CloudMusic', '获取歌曲列表异常: $e');
      return [];
    }
  }

  // 添加收藏
  // [songId] 要收藏的歌曲 ID
  Future<bool> addFavorite(String songId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/music/favorites'),
        headers: _authHeaders,
        body: json.encode({'song_id': songId}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        AppLogger.i('CloudMusic', '收藏成功: $songId');
        return true;
      } else {
        final data = json.decode(response.body);
        AppLogger.e('CloudMusic', '收藏失败: ${data['error']}');
        return false;
      }
    } catch (e) {
      AppLogger.e('CloudMusic', '收藏异常: $e');
      return false;
    }
  }

  // 取消收藏
  // [songId] 要取消收藏的歌曲 ID
  Future<bool> removeFavorite(String songId) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/api/music/favorites/$songId'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        AppLogger.i('CloudMusic', '取消收藏成功: $songId');
        return true;
      } else {
        final data = json.decode(response.body);
        AppLogger.e('CloudMusic', '取消收藏失败: ${data['error']}');
        return false;
      }
    } catch (e) {
      AppLogger.e('CloudMusic', '取消收藏异常: $e');
      return false;
    }
  }

  // 切换收藏状态
  // 返回切换后的收藏状态
  Future<bool> toggleFavorite(MusicItem song) async {
    if (song.isFavorite) {
      final success = await removeFavorite(song.id);
      if (success) song.isFavorite = false;
      return !song.isFavorite;
    } else {
      final success = await addFavorite(song.id);
      if (success) song.isFavorite = true;
      return song.isFavorite;
    }
  }

  // 获取收藏列表
  // 返回当前用户收藏的所有歌曲
  Future<List<MusicItem>> getFavorites() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/music/favorites'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> songs = data['songs'] ?? [];
        return songs.map((json) {
          final item = MusicItem.fromJson(json);
          item.isFavorite = true; // 收藏列表中的歌曲默认已收藏
          return item;
        }).toList();
      } else {
        AppLogger.e('CloudMusic', '获取收藏列表失败: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      AppLogger.e('CloudMusic', '获取收藏列表异常: $e');
      return [];
    }
  }
}
