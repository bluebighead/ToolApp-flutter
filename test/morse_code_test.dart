// 摩斯电码加解密单元测试
// 验证 textToMorse 和 morseToText 函数的正确性和边界情况
import 'package:flutter_test/flutter_test.dart';
import 'package:toolapp/pages/encryptor/morse_code_page.dart';

void main() {
  group('textToMorse 文本转摩斯电码', () {
    test('单个字母转换', () {
      expect(textToMorse('A'), '.-');
      expect(textToMorse('E'), '.');
      expect(textToMorse('T'), '-');
      expect(textToMorse('Z'), '--..');
    });

    test('单个数字转换', () {
      expect(textToMorse('0'), '-----');
      expect(textToMorse('5'), '.....');
      expect(textToMorse('9'), '----.');
    });

    test('常见标点转换', () {
      expect(textToMorse('.'), '.-.-.-');
      expect(textToMorse(','), '--..--');
      expect(textToMorse('?'), '..--..');
      expect(textToMorse('!'), '-.-.--');
    });

    test('单词转换', () {
      expect(textToMorse('HELLO'), '.... . .-.. .-.. ---');
      expect(textToMorse('SOS'), '... --- ...');
    });

    test('多单词转换（空格分隔）', () {
      expect(textToMorse('HELLO WORLD'), '.... . .-.. .-.. --- / .-- --- .-. .-.. -..');
    });

    test('大小写不敏感', () {
      expect(textToMorse('hello'), textToMorse('HELLO'));
      expect(textToMorse('Hello'), textToMorse('HELLO'));
    });

    test('数字和字母混合', () {
      expect(textToMorse('ABC123'), '.- -... -.-. .---- ..--- ...--');
    });

    test('空字符串返回空', () {
      expect(textToMorse(''), '');
    });

    test('不支持的字符被跳过', () {
      // 中文字符不在映射表中，应被跳过
      expect(textToMorse('A中B'), '.- -...');
    });

    test('多个空格只产生一个分隔符', () {
      expect(textToMorse('A  B'), '.- / -...');
    });
  });

  group('morseToText 摩斯电码转文本', () {
    test('单个字母解码', () {
      expect(morseToText('.-'), 'A');
      expect(morseToText('.'), 'E');
      expect(morseToText('-'), 'T');
      expect(morseToText('--..'), 'Z');
    });

    test('单个数字解码', () {
      expect(morseToText('-----'), '0');
      expect(morseToText('.....'), '5');
      expect(morseToText('----.'), '9');
    });

    test('单词解码', () {
      expect(morseToText('.... . .-.. .-.. ---'), 'HELLO');
      expect(morseToText('... --- ...'), 'SOS');
    });

    test('多单词解码', () {
      expect(morseToText('.... . .-.. .-.. --- / .-- --- .-. .-.. -..'), 'HELLO WORLD');
    });

    test('空字符串返回空', () {
      expect(morseToText(''), '');
    });

    test('无效摩斯电码用问号占位', () {
      expect(morseToText('.....---'), '?');
    });

    test('多个空格不影响解码', () {
      expect(morseToText('....  .'), 'HE');
    });
  });

  group('加解密往返测试（round-trip）', () {
    test('纯字母往返', () {
      const original = 'HELLO';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('字母数字混合往返', () {
      const original = 'TEST123';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('多单词往返', () {
      const original = 'HELLO WORLD';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('所有字母往返', () {
      const original = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('所有数字往返', () {
      const original = '0123456789';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('常见标点往返', () {
      const original = '.,?!';
      final morse = textToMorse(original);
      final decoded = morseToText(morse);
      expect(decoded, original);
    });

    test('SOS 紧急信号往返', () {
      const original = 'SOS';
      final morse = textToMorse(original);
      expect(morse, '... --- ...');
      final decoded = morseToText(morse);
      expect(decoded, original);
    });
  });
}
