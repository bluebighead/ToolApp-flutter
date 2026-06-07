// 网速测试 URL 校验函数测试
// 通过 @visibleForTesting 暴露的顶级函数 validateNetworkSpeedUrl 测试
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/pages/network_speed_page.dart';

void main() {
  group('validateNetworkSpeedUrl 合法用例', () {
    test('https 简单 URL', () {
      expect(validateNetworkSpeedUrl('https://www.baidu.com'), isNull);
    });
    test('http 带端口和路径', () {
      expect(validateNetworkSpeedUrl('http://example.com:8080/path?q=1'), isNull);
    });
    test('https 子域', () {
      expect(validateNetworkSpeedUrl('https://api.github.com/users'), isNull);
    });
  });

  group('validateNetworkSpeedUrl 非法用例', () {
    test('空字符串', () {
      expect(validateNetworkSpeedUrl(''), isNotNull);
    });
    test('仅空白', () {
      expect(validateNetworkSpeedUrl('   '), isNotNull);
    });
    test('无 scheme', () {
      expect(validateNetworkSpeedUrl('baidu.com'), isNotNull);
    });
    test('ftp scheme', () {
      expect(validateNetworkSpeedUrl('ftp://x.com'), isNotNull);
    });
    test('https 后无 host', () {
      expect(validateNetworkSpeedUrl('https://'), isNotNull);
    });
  });

  group('detectScheme', () {
    test('空字符串', () {
      expect(detectScheme(''), isNull);
    });
    test('https', () {
      expect(detectScheme('https://x.com'), 'https://');
    });
    test('http', () {
      expect(detectScheme('http://x.com'), 'http://');
    });
    test('无 scheme', () {
      expect(detectScheme('baidu.com'), isNull);
    });
  });

  group('applySchemeToUrl', () {
    test('空文本 -> 返回 scheme 本身', () {
      expect(applySchemeToUrl('', 'https://'), 'https://');
    });
    test('无 scheme 文本 -> 前缀 scheme', () {
      expect(applySchemeToUrl('baidu.com', 'https://'), 'https://baidu.com');
    });
    test('https 文本 -> 替换 scheme 为 https', () {
      expect(
        applySchemeToUrl('https://baidu.com', 'https://'),
        'https://baidu.com',
      );
    });
    test('https 文本 -> 替换 scheme 为 http', () {
      expect(
        applySchemeToUrl('https://baidu.com', 'http://'),
        'http://baidu.com',
      );
    });
    test('http 文本 -> 替换 scheme 为 https', () {
      expect(
        applySchemeToUrl('http://baidu.com', 'https://'),
        'https://baidu.com',
      );
    });
    test('路径 + 查询字符串保留', () {
      expect(
        applySchemeToUrl('https://api.github.com/users?page=1', 'http://'),
        'http://api.github.com/users?page=1',
      );
    });
  });
}
