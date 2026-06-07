import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/widgets/network_speed_line_chart.dart';

void main() {
  group('samplesToSpots', () {
    test('空列表 -> 空', () {
      expect(samplesToSpots([]), isEmpty);
    });
    test('全 null -> 空', () {
      expect(samplesToSpots([null, null, null]), isEmpty);
    });
    test('全成功 -> 长度=列表长度，X 从 1 开始', () {
      final spots = samplesToSpots([10, 20, 30]);
      expect(spots.length, 3);
      expect(spots[0], const FlSpot(1, 10));
      expect(spots[1], const FlSpot(2, 20));
      expect(spots[2], const FlSpot(3, 30));
    });
    test('含 null -> 跳过 null 保持 X 连续', () {
      final spots = samplesToSpots([10, null, 30, null, 50]);
      expect(spots.length, 3);
      expect(spots[0].x, 1);
      expect(spots[1].x, 3);
      expect(spots[2].x, 5);
    });
  });

  group('maxYFor', () {
    test('空列表 -> 100', () {
      expect(maxYFor([]), 100);
    });
    test('全 null -> 100', () {
      expect(maxYFor([null, null]), 100);
    });
    test('正常值 -> max * 1.2', () {
      expect(maxYFor([10, 20, 50]), 60);
    });
    test('小值钳位到 50', () {
      expect(maxYFor([1, 2, 3]), 50);
    });
    test('10 个等大值', () {
      expect(maxYFor([100, 100, 100, 100, 100, 100, 100, 100, 100, 100]), 120);
    });
  });
}
