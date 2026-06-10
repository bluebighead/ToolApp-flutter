// 麻将计分器数据模型和存储逻辑
// 支持4人麻将的手动记分和番数自动算分
// 使用 SharedPreferences + JSON 持久化对局记录
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

// ============================================================
// 数据模型
// ============================================================

/// 一局记录的类型
enum RoundType {
  /// 手动输入分差
  manual,

  /// 番数自动算分（自摸）
  selfDraw,

  /// 番数自动算分（点炮）
  discard,
}

/// 通用番型定义
class FanType {
  final String name;
  final int fans; // 番数

  const FanType({required this.name, required this.fans});
}

/// 预置通用番型列表（1-13番）
/// 用户可根据实际规则调整底分和番数倍率
const List<FanType> kDefaultFanTypes = [
  FanType(name: '1番', fans: 1),
  FanType(name: '2番', fans: 2),
  FanType(name: '3番', fans: 3),
  FanType(name: '4番', fans: 4),
  FanType(name: '5番', fans: 5),
  FanType(name: '6番', fans: 6),
  FanType(name: '7番', fans: 7),
  FanType(name: '8番', fans: 8),
  FanType(name: '9番', fans: 9),
  FanType(name: '10番', fans: 10),
  FanType(name: '11番', fans: 11),
  FanType(name: '12番', fans: 12),
  FanType(name: '13番', fans: 13),
];

/// 一局记录
class MahjongRound {
  /// 记录类型
  final RoundType type;

  /// 4位玩家的分差（正数赢，负数输）
  /// 索引 0-3 对应4位玩家
  final List<int> scoreChanges;

  /// 番数（仅番数算分时有意义）
  final int fans;

  /// 胡牌者索引（仅番数算分时有意义）
  final int? winnerIndex;

  /// 点炮者索引（仅点炮时有意义）
  final int? discarderIndex;

  /// 备注
  final String note;

  /// 记录时间
  final DateTime time;

  const MahjongRound({
    required this.type,
    required this.scoreChanges,
    this.fans = 0,
    this.winnerIndex,
    this.discarderIndex,
    this.note = '',
    required this.time,
  });

  /// 从 JSON 反序列化
  factory MahjongRound.fromJson(Map<String, dynamic> json) {
    final scoreChangesRaw = (json['scoreChanges'] as List<dynamic>? ?? [])
        .map((e) => e as int)
        .toList();
    // 确保 scoreChanges 至少有4个元素，不足的补0（防止数据损坏导致越界）
    final scoreChanges = List<int>.filled(4, 0);
    for (int i = 0; i < scoreChangesRaw.length && i < 4; i++) {
      scoreChanges[i] = scoreChangesRaw[i];
    }
    // 防止type值超出枚举范围导致崩溃
    final typeIndex = (json['type'] as int? ?? 0).clamp(0, RoundType.values.length - 1);
    return MahjongRound(
      type: RoundType.values[typeIndex],
      scoreChanges: scoreChanges,
      fans: json['fans'] as int? ?? 0,
      winnerIndex: json['winnerIndex'] as int?,
      discarderIndex: json['discarderIndex'] as int?,
      note: json['note'] as String? ?? '',
      time: json['time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['time'] as int)
          : DateTime.now(),
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'type': type.index,
        'scoreChanges': scoreChanges,
        'fans': fans,
        'winnerIndex': winnerIndex,
        'discarderIndex': discarderIndex,
        'note': note,
        'time': time.millisecondsSinceEpoch,
      };
}

/// 一场完整对局
class MahjongGame {
  /// 唯一 ID
  final String id;

  /// 玩家数量（1-4）
  final int playerCount;

  /// 玩家名称
  final List<String> playerNames;

  /// 初始分数
  final int initialScore;

  /// 底分（番数算分时的基础单位）
  final int baseScore;

  /// 对局记录列表
  final List<MahjongRound> rounds;

  /// 创建时间
  final DateTime createdAt;

  /// 是否已结束
  final bool isFinished;

  const MahjongGame({
    required this.id,
    this.playerCount = 4,
    required this.playerNames,
    this.initialScore = 0,
    this.baseScore = 1,
    this.rounds = const [],
    required this.createdAt,
    this.isFinished = false,
  });

  /// 计算每位玩家的当前总分
  List<int> get currentScores {
    final scores = List<int>.filled(playerCount, initialScore);
    for (final round in rounds) {
      for (int i = 0; i < playerCount; i++) {
        scores[i] += round.scoreChanges[i];
      }
    }
    return scores;
  }

  /// 计算排名（返回玩家索引，按分数从高到低）
  List<int> get ranking {
    final scores = currentScores;
    final indices = List.generate(playerCount, (i) => i);
    indices.sort((a, b) => scores[b].compareTo(scores[a]));
    return indices;
  }

  MahjongGame copyWith({
    int? playerCount,
    List<String>? playerNames,
    int? initialScore,
    int? baseScore,
    List<MahjongRound>? rounds,
    bool? isFinished,
  }) {
    return MahjongGame(
      id: id,
      playerCount: playerCount ?? this.playerCount,
      playerNames: playerNames ?? this.playerNames,
      initialScore: initialScore ?? this.initialScore,
      baseScore: baseScore ?? this.baseScore,
      rounds: rounds ?? this.rounds,
      createdAt: createdAt,
      isFinished: isFinished ?? this.isFinished,
    );
  }

  /// 从 JSON 反序列化
  factory MahjongGame.fromJson(Map<String, dynamic> json) {
    final playerCount = json['playerCount'] as int? ?? 4;
    final playerNamesRaw = (json['playerNames'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList();
    // 确保 playerNames 长度与 playerCount 一致，不足的补默认值
    final playerNames = List.generate(
      playerCount,
      (i) => i < playerNamesRaw.length && playerNamesRaw[i].isNotEmpty
          ? playerNamesRaw[i]
          : '玩家${i + 1}',
    );
    return MahjongGame(
      id: json['id'] as String? ?? '',
      playerCount: playerCount,
      playerNames: playerNames,
      initialScore: json['initialScore'] as int? ?? 0,
      baseScore: json['baseScore'] as int? ?? 1,
      rounds: (json['rounds'] as List<dynamic>? ?? [])
          .map((e) => MahjongRound.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
          : DateTime.now(),
      isFinished: json['isFinished'] as bool? ?? false,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'playerCount': playerCount,
        'playerNames': playerNames,
        'initialScore': initialScore,
        'baseScore': baseScore,
        'rounds': rounds.map((e) => e.toJson()).toList(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'isFinished': isFinished,
      };
}

// ============================================================
// 存储逻辑
// ============================================================

/// 麻将计分器存储工具
class MahjongStorage {
  static const String _kGamesKey = 'mahjong_games';

  /// 加载所有对局记录
  static Future<List<MahjongGame>> loadGames() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kGamesKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((e) => MahjongGame.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      AppLogger.e('MahjongStorage', '加载对局记录失败：$e');
      return [];
    }
  }

  /// 保存所有对局记录
  static Future<void> saveGames(List<MahjongGame> games) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(games.map((e) => e.toJson()).toList());
    await prefs.setString(_kGamesKey, jsonStr);
    AppLogger.i('MahjongStorage', '保存对局记录：${games.length} 场');
  }

  /// 添加一场对局
  static Future<void> addGame(MahjongGame game) async {
    final games = await loadGames();
    games.insert(0, game); // 最新的排在前面
    await saveGames(games);
  }

  /// 更新一场对局
  static Future<void> updateGame(MahjongGame game) async {
    final games = await loadGames();
    final index = games.indexWhere((g) => g.id == game.id);
    if (index >= 0) {
      games[index] = game;
      await saveGames(games);
    }
  }

  /// 保存一场对局（新增或更新）
  static Future<void> saveGame(MahjongGame game) async {
    final games = await loadGames();
    final index = games.indexWhere((g) => g.id == game.id);
    if (index >= 0) {
      // 已有对局，更新
      games[index] = game;
    } else {
      // 新对局，插入到列表头部
      games.insert(0, game);
    }
    await saveGames(games);
  }

  /// 删除一场对局
  static Future<void> deleteGame(String gameId) async {
    final games = await loadGames();
    games.removeWhere((g) => g.id == gameId);
    await saveGames(games);
  }

  /// 批量删除对局（一次IO操作，避免循环读写）
  static Future<void> deleteGames(Set<String> gameIds) async {
    final games = await loadGames();
    games.removeWhere((g) => gameIds.contains(g.id));
    await saveGames(games);
  }
}

// ============================================================
// 计分逻辑
// ============================================================

/// 麻将计分计算器
class MahjongCalculator {
  /// 计算自摸得分
  /// 胡牌者赢：底分 x 2^番数 x (玩家数-1)（其他玩家各付一份）
  /// 其他玩家各输：底分 x 2^番数
  /// [fans] 上限为13，超出会被截断以防止整数溢出
  static List<int> selfDrawScore({
    required int winnerIndex,
    required int fans,
    required int baseScore,
    required int playerCount,
  }) {
    // 防止整数溢出：番数上限13（2^13=8192，乘以合理底分不会溢出）
    final safeFans = fans.clamp(0, 13);
    final amount = baseScore * (1 << safeFans); // 2^番数
    final changes = List<int>.filled(playerCount, 0);
    changes[winnerIndex] = amount * (playerCount - 1); // 胡牌者赢(playerCount-1)份
    for (int i = 0; i < playerCount; i++) {
      if (i != winnerIndex) {
        changes[i] = -amount; // 其他玩家各输1份
      }
    }
    return changes;
  }

  /// 计算点炮得分
  /// 胡牌者赢：底分 x 2^番数
  /// 点炮者输：底分 x 2^番数
  /// 其他玩家不输不赢
  /// [fans] 上限为13，超出会被截断以防止整数溢出
  static List<int> discardScore({
    required int winnerIndex,
    required int discarderIndex,
    required int fans,
    required int baseScore,
    int playerCount = 4,
  }) {
    // 防止整数溢出：番数上限13
    final safeFans = fans.clamp(0, 13);
    final amount = baseScore * (1 << safeFans); // 2^番数
    final changes = List<int>.filled(playerCount, 0);
    changes[winnerIndex] = amount; // 胡牌者赢
    changes[discarderIndex] = -amount; // 点炮者输
    return changes;
  }
}
