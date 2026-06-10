// 联机掷骰子玩家数据模型
// 表示一个联机房间中的玩家

/// 玩家状态
enum PlayerStatus {
  waiting('等待中'),
  guessing('猜数字中'),
  rolling('掷骰子中'),
  finished('已完成'),
  ;

  final String label;
  const PlayerStatus(this.label);
}

/// 玩家数据模型
class OnlinePlayer {
  /// 玩家唯一 ID
  final String id;

  /// 玩家名称
  final String name;

  /// 是否为房主
  final bool isHost;

  /// 当前状态
  final PlayerStatus status;

  /// 掷骰子结果（每颗骰子的点数）
  final List<int> results;

  /// 总点数
  final int total;

  /// 猜数字玩法：玩家猜测的数字（-1 表示未提交）
  final int guessNumber;

  const OnlinePlayer({
    required this.id,
    required this.name,
    this.isHost = false,
    this.status = PlayerStatus.waiting,
    this.results = const [],
    this.total = 0,
    this.guessNumber = -1,
  });

  /// 创建副本并修改指定字段
  OnlinePlayer copyWith({
    String? id,
    String? name,
    bool? isHost,
    PlayerStatus? status,
    List<int>? results,
    int? total,
    int? guessNumber,
  }) {
    return OnlinePlayer(
      id: id ?? this.id,
      name: name ?? this.name,
      isHost: isHost ?? this.isHost,
      status: status ?? this.status,
      results: results ?? this.results,
      total: total ?? this.total,
      guessNumber: guessNumber ?? this.guessNumber,
    );
  }

  /// 从 JSON 反序列化
  factory OnlinePlayer.fromJson(Map<String, dynamic> json) {
    return OnlinePlayer(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      isHost: json['isHost'] as bool? ?? false,
      status: PlayerStatus.values.firstWhere(
        (e) => e.name == (json['status'] as String? ?? 'waiting'),
        orElse: () => PlayerStatus.waiting,
      ),
      results: (json['results'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          [],
      total: json['total'] as int? ?? 0,
      guessNumber: json['guessNumber'] as int? ?? -1,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isHost': isHost,
        'status': status.name,
        'results': results,
        'total': total,
        'guessNumber': guessNumber,
      };
}
