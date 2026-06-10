// 对局复盘页面
// 显示已结束对局的详细记录，包含分数变化曲线图
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../utils/app_logger.dart';
import '../utils/mahjong_model.dart';

class MahjongReviewPage extends StatefulWidget {
  final MahjongGame game;

  const MahjongReviewPage({super.key, required this.game});

  @override
  State<MahjongReviewPage> createState() => _MahjongReviewPageState();
}

class _MahjongReviewPageState extends State<MahjongReviewPage> {
  late MahjongGame _game;
  late List<List<int>> _scoreHistory; // 每局后4人的累计分数
  final GlobalKey _shareKey = GlobalKey(); // 用于截图分享

  @override
  void initState() {
    super.initState();
    _game = widget.game;
    _calculateScoreHistory();
  }

  /// 计算每局后的累计分数
  void _calculateScoreHistory() {
    _scoreHistory = [];
    final scores = List<int>.filled(_game.playerCount, _game.initialScore);
    // 初始分数
    _scoreHistory.add(List.from(scores));
    // 每局后的分数
    for (final round in _game.rounds) {
      for (int i = 0; i < _game.playerCount; i++) {
        scores[i] += round.scoreChanges[i];
      }
      _scoreHistory.add(List.from(scores));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('对局复盘'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享战绩',
            onPressed: _shareResult,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 可截图区域（用于分享）
            RepaintBoundary(
              key: _shareKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 对局信息卡片
                  _buildInfoCard(theme),
                  const SizedBox(height: 12),
                  // 分数曲线图
                  _buildScoreChart(theme),
                  const SizedBox(height: 12),
                  // 最终排名
                  _buildFinalRanking(theme),
                  const SizedBox(height: 12),
                  // 详细局记录
                  Text('详细记录', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ..._game.rounds.asMap().entries.map((entry) => _buildRoundItem(theme, entry.key, entry.value)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 对局信息卡片
  Widget _buildInfoCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('对局信息', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('玩家：', style: TextStyle(fontSize: 12, color: Colors.grey)),
                Expanded(
                  child: Text(
                    _game.playerNames.join('、'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('共 ${_game.rounds.length} 局', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
              '开始时间：${_formatTime(_game.createdAt)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// 分数曲线图
  Widget _buildScoreChart(ThemeData theme) {
    if (_game.rounds.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('暂无对局记录')),
        ),
      );
    }

    final colors = _playerColors;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('分数变化曲线', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            // 图例
            Wrap(
              spacing: 12,
              children: List.generate(_game.playerCount, (i) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 3,
                    decoration: BoxDecoration(
                      color: colors[i],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(_game.playerNames[i], style: const TextStyle(fontSize: 11)),
                ],
              )),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: _calculateYInterval(),
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                    getDrawingVerticalLine: (value) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        getTitlesWidget: (value, meta) {
                          if (value == value.toInt() && value.toInt() < _scoreHistory.length) {
                            final roundIdx = value.toInt();
                            if (roundIdx == 0) {
                              return const Text('初始', style: TextStyle(fontSize: 9));
                            }
                            // 获取该轮对应的时间
                            final roundTime = _game.rounds[roundIdx - 1].time;
                            return Text(
                              '${roundTime.hour}:${roundTime.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 9),
                            );
                          }
                          return const Text('');
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  lineBarsData: List.generate(_game.playerCount, (playerIdx) {
                    return LineChartBarData(
                      spots: List.generate(_scoreHistory.length, (roundIdx) {
                        return FlSpot(roundIdx.toDouble(), _scoreHistory[roundIdx][playerIdx].toDouble());
                      }),
                      isCurved: true,
                      curveSmoothness: 0.2,
                      color: colors[playerIdx],
                      barWidth: 2.5,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 3,
                            color: colors[playerIdx],
                            strokeWidth: 1,
                            strokeColor: Colors.white,
                          );
                        },
                      ),
                      belowBarData: BarAreaData(show: false),
                    );
                  }),
                  minY: _calculateMinY(),
                  maxY: _calculateMaxY(),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final playerIdx = spot.barIndex;
                          final roundIdx = spot.x.toInt();
                          final score = spot.y.toInt();
                          return LineTooltipItem(
                            '${_game.playerNames[playerIdx]}\n${roundIdx == 0 ? "初始" : "第$roundIdx局"}: $score分',
                            TextStyle(
                              color: colors[playerIdx],
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 计算Y轴间隔
  double _calculateYInterval() {
    if (_scoreHistory.isEmpty) return 10;
    final allScores = _scoreHistory.expand((e) => e).toList();
    final max = allScores.reduce((a, b) => a > b ? a : b);
    final min = allScores.reduce((a, b) => a < b ? a : b);
    final range = max - min;
    if (range <= 20) return 5;
    if (range <= 50) return 10;
    if (range <= 100) return 20;
    return 50;
  }

  double _calculateMinY() {
    if (_scoreHistory.isEmpty) return -10;
    final allScores = _scoreHistory.expand((e) => e).toList();
    if (allScores.isEmpty) return -10;
    final min = allScores.reduce((a, b) => a < b ? a : b);
    final max = allScores.reduce((a, b) => a > b ? a : b);
    // 如果所有分数相同，添加一个合理的范围
    if (min == max) return (min - 10).toDouble();
    return (min - (max - min) * 0.1).toDouble();
  }

  double _calculateMaxY() {
    if (_scoreHistory.isEmpty) return 10;
    final allScores = _scoreHistory.expand((e) => e).toList();
    if (allScores.isEmpty) return 10;
    final min = allScores.reduce((a, b) => a < b ? a : b);
    final max = allScores.reduce((a, b) => a > b ? a : b);
    // 如果所有分数相同，添加一个合理的范围
    if (min == max) return (max + 10).toDouble();
    return (max + (max - min) * 0.1).toDouble();
  }

  /// 最终排名
  Widget _buildFinalRanking(ThemeData theme) {
    final scores = _game.currentScores;
    final ranking = _game.ranking;
    final colors = _playerColors;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最终排名', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...ranking.asMap().entries.map((entry) {
              final rank = entry.key;
              final playerIdx = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    // 排名图标
                    SizedBox(
                      width: 24,
                      child: rank == 0
                          ? const Icon(Icons.emoji_events, size: 18, color: Colors.amber)
                          : Text(
                              '${rank + 1}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                            ),
                    ),
                    const SizedBox(width: 8),
                    // 玩家名
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colors[playerIdx],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 80,
                      child: Text(
                        _game.playerNames[playerIdx],
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Spacer(),
                    // 分数
                    Text(
                      '${scores[playerIdx]}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: scores[playerIdx] > 0
                            ? Colors.red
                            : scores[playerIdx] < 0
                                ? Colors.green
                                : Colors.grey,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 局记录条目
  Widget _buildRoundItem(ThemeData theme, int index, MahjongRound round) {
    String typeLabel;
    Color typeColor;
    switch (round.type) {
      case RoundType.manual:
        typeLabel = '手动';
        typeColor = Colors.blue;
        break;
      case RoundType.selfDraw:
        typeLabel = '自摸';
        typeColor = Colors.orange;
        break;
      case RoundType.discard:
        typeLabel = '点炮';
        typeColor = Colors.purple;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '第 ${index + 1} 局',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: typeColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    typeLabel,
                    style: TextStyle(fontSize: 10, color: typeColor, fontWeight: FontWeight.w500),
                  ),
                ),
                const Spacer(),
                if (round.type != RoundType.manual && round.fans > 0)
                  Text(
                    '${round.fans}番',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                  ),
                const SizedBox(width: 8),
                // 对局时间
                Text(
                  _formatTime(round.time),
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 分差展示（带玩家名）
            Row(
              children: List.generate(_game.playerCount, (i) {
                final change = round.scoreChanges[i];
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        _game.playerNames[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        change == 0 ? '-' : '${change > 0 ? '+' : ''}$change',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: change > 0
                              ? Colors.red
                              : change < 0
                                  ? Colors.green
                                  : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  /// 玩家颜色
  static const _playerColors = [
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
  ];

  /// 分享战绩截图
  Future<void> _shareResult() async {
    try {
      final boundary = _shareKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/mahjong_review.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());

      // 构建分享文字
      final scores = _game.currentScores;
      final ranking = _game.ranking;
      final resultText = ranking.map((idx) {
        return '${_game.playerNames[idx]}: ${scores[idx]}分';
      }).join('\n');

      await Share.shareXFiles(
        [XFile(file.path)],
        text: '麻将战报\n$resultText',
      );
    } catch (e) {
      AppLogger.e('MahjongReview', '分享失败：$e');
    }
  }
}
