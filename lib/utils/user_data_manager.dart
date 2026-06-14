// 用户数据管理器：按用户隔离数据存储
// 提供用户专属的数据目录和 SharedPreferences key 前缀
// 确保不同用户的数据互不干扰
// 游客模式使用 "guest" 作为用户标识
//
// 数据目录结构：
//   ToolApp/data/users/guest/     游客数据
//   ToolApp/data/users/1/         用户ID=1 的数据
//   ToolApp/data/users/2/         用户ID=2 的数据
//
// SharedPreferences key 隔离：
//   游客: guest_heart_rate_history_v1
//   用户1: user_1_heart_rate_history_v1
//   用户2: user_2_heart_rate_history_v2
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'app_settings.dart';
import '../services/auth_service.dart';
import 'heart_rate_history.dart';
import 'dice_history.dart';
import 'convert_history.dart';
import 'network_speed_history.dart';
import 'period_model.dart';

class UserDataManager {
  // 全局单例
  static final UserDataManager instance = UserDataManager._();
  UserDataManager._();

  // 旧版 SharedPreferences key（无用户前缀）
  static const List<String> _legacyKeys = [
    'heart_rate_history_v1',
    'dice_history_v1',
    'convert_history_v1',
    'network_speed_history',
    'period_records',
    'period_ovulation_marks',
    'period_settings',
  ];

  // 迁移标记 key
  static const String _kMigrationDone = 'user_data_migration_done';

  /// 获取当前用户的数据标识
  /// 游客模式返回 "guest"，已登录返回 "user_{userId}"
  String get currentUserTag {
    if (AuthService.instance.isGuestMode) return 'guest';
    final userId = AuthService.instance.currentUserId;
    if (userId != null) return 'user_$userId';
    return 'guest'; // 未登录也用 guest
  }

  /// 为 SharedPreferences key 添加用户前缀
  /// 例如：heart_rate_history_v1 → guest_heart_rate_history_v1
  ///       heart_rate_history_v1 → user_1_heart_rate_history_v1
  String prefsKey(String baseKey) {
    return '${currentUserTag}_$baseKey';
  }

  /// 获取当前用户的专属数据目录
  /// 路径：ToolApp/data/users/{userTag}/
  /// 不存在时自动创建
  Future<Directory> getUserDataDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/ToolApp/data/users/$currentUserTag');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 获取所有用户数据目录
  /// 返回 ToolApp/data/users/ 下的所有子目录
  Future<List<Directory>> getAllUserDataDirectories() async {
    final docs = await getApplicationDocumentsDirectory();
    final usersDir = Directory('${docs.path}/ToolApp/data/users');
    if (!await usersDir.exists()) return [];
    final dirs = <Directory>[];
    await for (final entity in usersDir.list(followLinks: false)) {
      if (entity is Directory) {
        dirs.add(entity);
      }
    }
    return dirs;
  }

  /// 删除指定用户的数据目录
  Future<void> deleteUserDataDirectory(String userTag) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/ToolApp/data/users/$userTag');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 用户切换时迁移数据（文件目录）
  /// 从源用户标识迁移到目标用户标识
  /// 用于游客登录后，将游客数据迁移到正式用户目录
  Future<void> migrateData(String fromTag, String toTag) async {
    // 迁移文件目录
    final docs = await getApplicationDocumentsDirectory();
    final fromDir = Directory('${docs.path}/ToolApp/data/users/$fromTag');
    final toDir = Directory('${docs.path}/ToolApp/data/users/$toTag');

    if (await fromDir.exists()) {
      if (await toDir.exists()) {
        await for (final entity in fromDir.list(followLinks: false)) {
          if (entity is File) {
            final fileName = entity.path.split(Platform.pathSeparator).last;
            final targetFile = File('${toDir.path}/$fileName');
            if (!await targetFile.exists()) {
              await entity.copy(targetFile.path);
            }
          }
        }
        await fromDir.delete(recursive: true);
      } else {
        await fromDir.rename(toDir.path);
      }
    }

    // 迁移 SharedPreferences 数据
    await _migratePrefsKeys(fromTag, toTag);
  }

  /// 迁移 SharedPreferences 中指定用户前缀的数据到新用户前缀
  /// 例如：guest_heart_rate_history_v1 → user_1_heart_rate_history_v1
  Future<void> _migratePrefsKeys(String fromTag, String toTag) async {
    final prefs = AppSettings.prefs!;
    final allKeys = prefs.getKeys();
    final prefix = '${fromTag}_';
    int migrated = 0;

    for (final key in allKeys) {
      if (!key.startsWith(prefix)) continue;
      if (key == _kMigrationDone) continue;

      final baseKey = key.substring(prefix.length);
      final newKey = '${toTag}_$baseKey';

      // 如果新 key 已有数据，不覆盖
      if (prefs.getString(newKey) != null) {
        AppLogger.i('UserDataManager', '跳过 $key：$newKey 已有数据');
        await prefs.remove(key);
        continue;
      }

      final value = prefs.getString(key);
      if (value != null) {
        await prefs.setString(newKey, value);
        await prefs.remove(key);
        migrated++;
        AppLogger.i('UserDataManager', '迁移 $key → $newKey');
      }
    }

    if (migrated > 0) {
      AppLogger.i('UserDataManager', 'SharedPreferences 迁移完成，共 $migrated 项');
    }
  }

  /// 清除所有模块的内存缓存
  /// 在用户切换（登录/登出/游客模式切换）时调用
  /// 确保新用户看到的是自己的数据，而不是上一个用户的缓存
  void clearAllCaches() {
    HeartRateHistory.clearCache();
    DiceHistory.clearCache();
    ConvertHistory.clearCache();
    AppLogger.i('UserDataManager', '已清除所有模块内存缓存');
  }

  /// 旧版数据迁移：将无用户前缀的 SharedPreferences 数据迁移到当前用户前缀下
  /// 仅在首次升级到用户隔离版本时执行一次
  /// 迁移逻辑：如果旧 key 存在且新 key 不存在，则复制数据并删除旧 key
  Future<void> migrateLegacyData() async {
    final prefs = AppSettings.prefs!;

    // 检查是否已完成迁移
    final migrationDone = prefs.getBool(_kMigrationDone) ?? false;
    if (migrationDone) return;

    AppLogger.i('UserDataManager', '开始旧版数据迁移...');

    // 确定迁移目标用户标识
    // 如果当前已登录，迁移到该用户；否则迁移到 guest
    final targetTag = currentUserTag;
    int migrated = 0;

    for (final legacyKey in _legacyKeys) {
      // 检查旧 key 是否存在
      final value = prefs.getString(legacyKey);
      if (value == null) continue;

      // 新 key
      final newKey = '${targetTag}_$legacyKey';

      // 如果新 key 已有数据，不覆盖（优先保留新数据）
      if (prefs.getString(newKey) != null) {
        AppLogger.i('UserDataManager', '跳过 $legacyKey：新 key 已有数据');
        await prefs.remove(legacyKey);
        continue;
      }

      // 复制到新 key
      await prefs.setString(newKey, value);
      // 删除旧 key
      await prefs.remove(legacyKey);
      migrated++;
      AppLogger.i('UserDataManager', '迁移 $legacyKey → $newKey');
    }

    // 标记迁移完成
    await prefs.setBool(_kMigrationDone, true);
    AppLogger.i('UserDataManager', '旧版数据迁移完成，共迁移 $migrated 项到 $targetTag');
  }
}
