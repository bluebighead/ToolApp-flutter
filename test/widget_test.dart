// 工具箱 App 基础 widget 测试
// 验证首页能正常渲染，并能看到"分贝测试仪"工具卡片
import 'package:flutter_test/flutter_test.dart';

import 'package:toolapp/main.dart';

void main() {
  testWidgets('首页应显示分贝测试仪工具卡片', (WidgetTester tester) async {
    // 启动 App
    await tester.pumpWidget(const ToolApp());
    await tester.pumpAndSettle();

    // 验证 AppBar 标题存在
    expect(find.text('实用工具箱'), findsOneWidget);

    // 验证分贝测试仪卡片存在
    expect(find.text('分贝测试仪'), findsOneWidget);
  });
}
