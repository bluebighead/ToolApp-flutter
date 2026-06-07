// 工具箱 App 主入口
// 配置 Material 3 主题并启动首页
// 通过 AppSettings 控制屏幕旋转/暗色模式
import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/settings_page.dart';
import 'utils/app_info.dart';
import 'utils/app_logger.dart';
import 'utils/convert_notification.dart';

void main() async {
  // 确保 Flutter 绑定已初始化（异步加载 SharedPreferences 前必须调用）
  WidgetsFlutterBinding.ensureInitialized();

  // 捕获 Flutter 框架运行期未捕获的错误，写入日志便于定位
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.e(
      'FlutterError',
      '未捕获的 Flutter 框架错误：${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
    // 仍然走默认的错误展示（Release 模式下显示红屏等）
    FlutterError.presentError(details);
  };

  AppLogger.i('Main', '应用启动 - ${AppInfo.appName} v${AppInfo.fullVersion}');

  // 启动前先加载本地设置（屏幕旋转/暗色模式偏好）
  await appSettings.load();

  // 初始化视频转换后台通知服务
  // 注意：必须在 runApp 之前完成，否则 video_convert_page 第一次弹通知可能失败
  await ConvertNotification.instance.init();

  runApp(const ToolApp());
}

class ToolApp extends StatelessWidget {
  const ToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    AppLogger.d('ToolApp', '构建 MaterialApp');
    // 基础种子色：靛蓝色
    const seedColor = Colors.indigo;

    // 亮色主题
    final lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
      ),
    );

    // 暗色主题
    final darkTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
      ),
    );

    return ListenableBuilder(
      // 监听 appSettings 变化，根据 darkMode 字段切换主题
      listenable: appSettings,
      builder: (context, _) {
        return MaterialApp(
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          // 亮色主题
          theme: lightTheme,
          // 暗色主题
          darkTheme: darkTheme,
          // 根据用户设置决定使用哪个主题
          themeMode: appSettings.darkMode ? ThemeMode.dark : ThemeMode.light,
          home: const HomePage(),
        );
      },
    );
  }
}
