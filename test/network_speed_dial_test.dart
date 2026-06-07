import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/widgets/network_speed_dial.dart';

void main() {
  group('pointerAngleFor', () {
    test('null -> pi（指针在起点）', () {
      expect(pointerAngleFor(null), math.pi);
    });
    test('0ms -> pi', () {
      expect(pointerAngleFor(0), math.pi);
    });
    test('500ms -> pi + pi/2（正右方）', () {
      expect(pointerAngleFor(500), math.pi + math.pi / 2);
    });
    test('1000ms -> 2pi（指针在终点）', () {
      expect(pointerAngleFor(1000), 2 * math.pi);
    });
    test('>1000ms 钳位到 2pi', () {
      expect(pointerAngleFor(2000), 2 * math.pi);
      expect(pointerAngleFor(99999), 2 * math.pi);
    });
    test('负数钳位到 pi', () {
      expect(pointerAngleFor(-50), math.pi);
    });
    test('单调递增：0 < 100 < 500 < 1000', () {
      final a0 = pointerAngleFor(0);
      final a1 = pointerAngleFor(100);
      final a5 = pointerAngleFor(500);
      final a10 = pointerAngleFor(1000);
      expect(a0, lessThan(a1));
      expect(a1, lessThan(a5));
      expect(a5, lessThan(a10));
    });
  });
}
