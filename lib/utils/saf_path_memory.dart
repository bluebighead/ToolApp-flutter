// SAF 自定义路径记忆工具
// 使用 SharedPreferences 持久化用户上次选择的 SAF 目录 URI
// 下次打开压缩页面时自动恢复上次的自定义路径，提升用户体验
import 'package:shared_preferences/shared_preferences.dart';

class SafPathMemory {
  SafPathMemory._();

  static const String _kSafTreeUri = 'saf_tree_uri';
  static const String _kSafDirName = 'saf_dir_name';

  // 保存 SAF 路径记忆
  static Future<void> save({
    required String type,
    required String treeUri,
    required String dirDisplayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_kSafTreeUri}_$type', treeUri);
    await prefs.setString('${_kSafDirName}_$type', dirDisplayName);
  }

  // 读取 SAF 路径记忆，返回 {treeUri, dirDisplayName}，未保存时返回 null
  static Future<Map<String, String>?> load(String type) async {
    final prefs = await SharedPreferences.getInstance();
    final treeUri = prefs.getString('${_kSafTreeUri}_$type');
    final dirName = prefs.getString('${_kSafDirName}_$type');
    if (treeUri != null && treeUri.isNotEmpty && dirName != null && dirName.isNotEmpty) {
      return {'treeUri': treeUri, 'dirDisplayName': dirName};
    }
    return null;
  }

  // 清除指定类型的 SAF 路径记忆
  static Future<void> clear(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_kSafTreeUri}_$type');
    await prefs.remove('${_kSafDirName}_$type');
  }
}