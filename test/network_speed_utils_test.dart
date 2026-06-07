import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/utils/network_speed_utils.dart';

void main() {
  group('latencyColorFor', () {
    test('null -> 灰', () {
      expect(latencyColorFor(null), Colors.grey);
    });
    test('0ms -> 绿', () {
      expect(latencyColorFor(0), Colors.green);
    });
    test('49ms -> 绿', () {
      expect(latencyColorFor(49), Colors.green);
    });
    test('50ms -> 蓝', () {
      expect(latencyColorFor(50), Colors.blue);
    });
    test('99ms -> 蓝', () {
      expect(latencyColorFor(99), Colors.blue);
    });
    test('100ms -> 橙', () {
      expect(latencyColorFor(100), Colors.orange);
    });
    test('199ms -> 橙', () {
      expect(latencyColorFor(199), Colors.orange);
    });
    test('200ms -> 红', () {
      expect(latencyColorFor(200), Colors.red);
    });
    test('9999ms -> 红', () {
      expect(latencyColorFor(9999), Colors.red);
    });
  });
}
