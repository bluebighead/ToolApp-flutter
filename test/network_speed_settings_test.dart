// 网速测试设置读写工具测试
// 验证 SharedPreferences 中三个 key 的默认行为与持久化往返
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toolapp/utils/network_speed_settings.dart';

void main() {
  // 每个 test 前清空 mock prefs，确保隔离
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load() 默认：useCustom=false, url=空, displayMode=0', () async {
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isFalse);
    expect(s.url, isEmpty);
    expect(s.displayMode, 0);
  });

  test('save 后 load 应返回保存值', () async {
    await NetworkSpeedSettings.save(
      useCustom: true,
      url: 'https://example.com',
      displayMode: 2,
    );
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://example.com');
    expect(s.displayMode, 2);
  });

  test('save 只传 useCustom 不应清空 url 和 displayMode', () async {
    await NetworkSpeedSettings.save(url: 'https://x.com', displayMode: 1);
    await NetworkSpeedSettings.save(useCustom: true);
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 1);
  });

  test('save 只传 url 不应修改 useCustom 和 displayMode', () async {
    await NetworkSpeedSettings.save(useCustom: true, displayMode: 2);
    await NetworkSpeedSettings.save(url: 'https://x.com');
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 2);
  });

  test('save 只传 displayMode 不应修改其他字段', () async {
    await NetworkSpeedSettings.save(useCustom: true, url: 'https://x.com');
    await NetworkSpeedSettings.save(displayMode: 1);
    final s = await NetworkSpeedSettings.load();
    expect(s.useCustom, isTrue);
    expect(s.url, 'https://x.com');
    expect(s.displayMode, 1);
  });
}
