// 工具箱 App 主入口
// 配置 Material 3 主题并启动首页
// 通过 AppSettings 控制屏幕旋转/暗色模式
// v1.8.0+ 新增：自建轻量服务器认证（HTTP + JWT 替代 Supabase）
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/auth/login_page.dart';
import 'pages/home_page.dart';
import 'services/ai_service.dart';
import 'services/ai_tool_executor.dart';
import 'services/auth_service.dart';
import 'services/camera_stream_service.dart';
import 'services/device_info_service.dart';
import 'services/online_overlay_manager.dart';
import 'services/session_tracker.dart';
import 'services/sync_service.dart';
import 'services/update_service.dart';
import 'utils/app_info.dart';
import 'utils/app_logger.dart';
import 'utils/app_settings.dart';
import 'utils/app_storage.dart';
import 'utils/convert_coordinator.dart';
import 'utils/convert_notification.dart';
import 'utils/route_observer.dart';
import 'utils/saf_directory_helper.dart';
import 'utils/user_data_manager.dart';
import 'widgets/ai_floating_button.dart';

/// 根 Navigator 的 GlobalKey，用于悬浮按钮管理器获取上下文
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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

  // 启动前先加载本地设置（屏幕旋转/暗色模式/服务器地址偏好）
  await appSettings.load();

  // 初始化认证服务（恢复本地登录态和游客模式）
  await AuthService.instance.initialize();

  // 迁移旧版数据到用户隔离格式（仅首次升级时执行）
  await UserDataManager.instance.migrateLegacyData();

  // 后台智能清理临时文件和过期数据（v1.51.2+）
  unawaited(AppStorage.smartClean());

  // v1.53.0+ 初始化AI助手（注册所有可用工具）
  AiService.init(AiToolExecutor.getToolsDescription());

  // 初始化视频转换后台通知服务
  // 注意：必须在 runApp 之前完成，否则 video_convert_page 第一次弹通知可能失败
  await ConvertNotification.instance.init();

  // v1.6.56+ 修复：注册通知栏"停止"按钮的取消回调
  // 当用户在通知栏点击"停止"时，Kotlin 端通过 MethodChannel 回调到此处，
  // 再通知 ConvertCoordinator 取消 FFmpeg 转换
  ForegroundServiceHelper.registerCancelCallback(() {
    AppLogger.i('Main', '收到通知栏取消请求，取消转换');
    unawaited(ConvertCoordinator.instance.cancel());
  });

  runApp(const ToolApp());
}

class ToolApp extends StatefulWidget {
  const ToolApp({super.key});

  @override
  State<ToolApp> createState() => _ToolAppState();
}

class _ToolAppState extends State<ToolApp> with WidgetsBindingObserver {
  OverlayEntry? _aiOverlay;

  // Deep link 方法通道，用于接收 Android 端的 intent 数据
  static const _channel = MethodChannel('android.intent');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appSettings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateAiOverlay());
    // 监听 deep link（NFC 碰卡触发的投屏指令等）
    _setupDeepLinkListener();
  }

  // 设置 deep link 监听器
  // 当 NFC 标签被扫描时，Android 通过 intent 传递 URI 到 Flutter
  void _setupDeepLinkListener() {
    // 检查 App 启动时是否带有 deep link
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'handleDeepLink') {
        final uri = call.arguments as String?;
        if (uri != null) _handleDeepLink(uri);
      }
      // 处理NFC文本类型的碰卡（文本/URL/名片速写等）
      else if (call.method == 'handleNdefText') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) {
          _showNfcTextNotice(text);
        }
      }
    });

    // 通过 MethodChannel 获取初始 intent（App 冷启动时的 deep link）
    _checkInitialIntent();
  }

  // 检查 App 冷启动时是否带有 deep link
  Future<void> _checkInitialIntent() async {
    try {
      // 修复：原方法体为空导致冷启动 deep link 丢失
      // 通过 MethodChannel 获取冷启动时的 intent data
      final initialUri = await _channel.invokeMethod<String>('getInitialIntent');
      if (initialUri != null && initialUri.isNotEmpty) {
        _handleDeepLink(initialUri);
      }
    } catch (e, st) {
      // 捕获并记录异常，避免静默失败导致 deep link 丢失难以排查
      AppLogger.e('ToolApp', '检查初始 intent 失败: $e', e, st);
    }
  }

  // 处理 deep link URI
  void _handleDeepLink(String uri) {
    AppLogger.i('ToolApp', '收到 deep link: $uri');

    // 解析 URI
    final uriObj = Uri.tryParse(uri);
    if (uriObj == null) return;

    if (uri == 'toolapp://screencast') {
      _launchScreencast();
    } else if (uriObj.scheme == 'toolapp' && uriObj.host == 'home') {
      _launchHomeMode(uriObj);
    }
  }

  // 显示NFC碰卡读取到的文本内容（用于文本/URL/名片速写等）
  void _showNfcTextNotice(String text) {
    AppLogger.i('ToolApp', 'NFC碰卡读取到文本: $text');
    try {
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.nfc, color: Color(0xFF1565C0), size: 24),
                SizedBox(width: 8),
                Text('NFC 碰卡信息'),
              ],
            ),
            content: Text(
              text,
              style: const TextStyle(fontSize: 15),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      AppLogger.e('ToolApp', '显示NFC文本失败: $e');
    }
  }

  // 启动 OPPO 互联投屏
  Future<void> _launchScreencast() async {
    AppLogger.i('ToolApp', 'NFC触发投屏，正在启动OPPO互联...');
    try {
      const packageName = 'com.heytap.duplicate';
      const channel = MethodChannel('app.launcher');
      await channel.invokeMethod('launchApp', {'packageName': packageName});
    } catch (e) {
      AppLogger.w('ToolApp', '启动OPPO互联失败: $e，尝试备用方案...');
      try {
        const altPackage = 'com.oplus.cast';
        const channel = MethodChannel('app.launcher');
        await channel.invokeMethod('launchApp', {'packageName': altPackage});
      } catch (e2) {
        AppLogger.w('ToolApp', '备用方案也失败: $e2');
      }
    }
  }

  // 回家模式：依次执行导航、连接WiFi、启动音乐
  Future<void> _launchHomeMode(Uri uriObj) async {
    AppLogger.i('ToolApp', 'NFC触发回家模式...');
    const channel = MethodChannel('app.launcher');

    // 1. 导航回家（如果有地址参数，打开地图导航）
    final addr = uriObj.queryParameters['addr'];
    if (addr != null && addr.isNotEmpty) {
      // 通过 geo URI 打开地图导航
      try {
        // 启动高德地图导航（地址参数已记录，由高德 App 内部处理导航目标）
        await channel.invokeMethod('launchApp', {
          'packageName': 'com.autonavi.minimap',
        });
        AppLogger.i('ToolApp', '已启动高德地图导航，目标地址: $addr');
      } catch (e) {
        AppLogger.w('ToolApp', '启动导航失败: $e');
      }
    }

    // 2. 启动音乐 App
    try {
      await channel.invokeMethod('launchApp', {
        'packageName': 'com.kugou.android',
      });
      AppLogger.i('ToolApp', '已启动酷狗音乐');
    } catch (e) {
      // 备用：QQ音乐
      try {
        await channel.invokeMethod('launchApp', {
          'packageName': 'com.tencent.qqmusic',
        });
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appSettings.removeListener(_onSettingsChanged);
    _aiOverlay?.remove();
    super.dispose();
  }

  void _onSettingsChanged() {
    _updateAiOverlay();
  }

  void _updateAiOverlay() {
    if (appSettings.aiEnabled) {
      _insertAiOverlay();
    } else {
      _removeAiOverlay();
    }
  }

  void _insertAiOverlay() {
    if (_aiOverlay != null) return;
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _aiOverlay = OverlayEntry(
      builder: (context) => Positioned(
        right: 16,
        bottom: 16,
        child: AiFloatingButton(navigatorKey: rootNavigatorKey),
      ),
    );
    overlay.insert(_aiOverlay!);
  }

  void _removeAiOverlay() {
    _aiOverlay?.remove();
    _aiOverlay = null;
  }

  // 应用前后台切换回调
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
        // 应用进入后台
        SessionTracker.instance.onAppPaused();
        break;
      case AppLifecycleState.resumed:
        // 应用恢复前台
        SessionTracker.instance.onAppResumed();
        // 检查WebSocket连接状态，断开则自动重连
        _checkAndReconnectWebSocket();
        break;
      case AppLifecycleState.detached:
        // 应用被分离
        SessionTracker.instance.endSession();
        break;
      default:
        break;
    }
  }

  /// 检查WebSocket连接状态，断开则自动重连
  void _checkAndReconnectWebSocket() {
    final cameraService = CameraStreamService.instance;
    if (AuthService.instance.isLoggedIn && !cameraService.isConnected) {
      AppLogger.i('ToolApp', 'App恢复前台，WebSocket已断开，尝试重连...');
      // 取消可能存在的自动重连定时器，避免重复重连
      cameraService.cancelReconnect();
      cameraService.connect().then((ok) {
        if (ok) {
          AppLogger.i('ToolApp', 'WebSocket重连成功');
        } else {
          AppLogger.w('ToolApp', 'WebSocket重连失败，将由自动重连机制继续尝试');
        }
      }).catchError((e) {
        AppLogger.w('ToolApp', 'WebSocket重连异常: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
        final app = MaterialApp(
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [appRouteObserver],
          builder: (context, child) {
            // 保持原始 MediaQuery，不覆盖 viewInsets，确保键盘避让正常工作
            return child!;
          },
          localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('zh', 'CN'),
              Locale('en', 'US'),
            ],
            // 亮色主题
            theme: lightTheme,
            // 暗色主题
            darkTheme: darkTheme,
            // 根据用户设置决定使用哪个主题
            themeMode: appSettings.darkMode ? ThemeMode.dark : ThemeMode.light,
            // 认证路由：根据登录状态显示首页或登录页
            home: const AuthWrapper(),
        );

        // 将 navigatorKey 注册到 OnlineOverlayManager 用于获取根上下文
        OnlineOverlayManager().navigatorKey = rootNavigatorKey;

        return app;
      },
    );
  }
}

/// 认证路由包装器
/// 监听 AuthService 状态变化：
///   - 已登录 → 显示首页
///   - 游客模式 → 显示首页
///   - 未登录 → 显示登录页
/// 游客模式登录成功后自动同步本地数据到服务器
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  // 记录上一次是否处于游客模式，用于检测"游客→登录"的转换
  bool _wasGuestMode = false;

  // 顶号检测定时器
  Timer? _kickedCheckTimer;

  @override
  void initState() {
    super.initState();
    _wasGuestMode = AuthService.instance.isGuestMode;
    // 监听 AuthService 状态变化（登录/登出/游客模式切换）
    AuthService.instance.addListener(_onAuthStateChanged);
    // 启动顶号检测定时器（每30秒检查一次）
    _startKickedCheck();
    // 启动时自动检查更新（延迟2秒，等待页面渲染完成）
    Future.delayed(const Duration(seconds: 2), () {
      _autoCheckUpdate();
    });
    // 启动时延迟5秒，尝试在后台异步上传一次设备参数（非强制）
    Future.delayed(const Duration(seconds: 5), () async {
      try {
        if (AuthService.instance.isLoggedIn) {
          AppLogger.i('AuthWrapper', '启动后延迟上传设备参数');
          await DeviceInfoService.instance.uploadDeviceInfo();
        }
      } catch (e) {
        AppLogger.w('AuthWrapper', '启动后上传设备参数失败: $e');
      }
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthStateChanged);
    _kickedCheckTimer?.cancel();
    super.dispose();
  }

  // 启动顶号检测
  void _startKickedCheck() {
    _kickedCheckTimer?.cancel();
    // 立即检测一次
    _checkIfKicked();
    // 每15秒检测一次
    _kickedCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkIfKicked();
    });
  }

  // 启动时自动检查更新
  Future<void> _autoCheckUpdate() async {
    final updateInfo = await UpdateService.instance.checkForUpdate();
    if (!mounted) return;

    // 有更新时才弹窗（无论是否强制更新都弹窗提示）
    if (updateInfo.hasUpdate) {
      UpdateService.showUpdateDialog(context, updateInfo);
    }
  }

  // 检查是否被踢出
  Future<void> _checkIfKicked() async {
    if (!AuthService.instance.isLoggedIn) return;

    final isKicked = await AuthService.instance.checkIfKicked();
    if (isKicked && mounted) {
      // 停止顶号检测
      _kickedCheckTimer?.cancel();

      // 弹出被踢出提示框
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('账号退出提示'),
          content: const Text('您的账号已在另一台设备登录，当前设备已被强制退出。'),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                // 执行登出
                AuthService.instance.signOut();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  // 认证状态变化回调
  void _onAuthStateChanged() {
    if (!mounted) return;

    // 检测从游客模式登录成功的转换
    final wasGuest = _wasGuestMode;
    final isNowLoggedIn = AuthService.instance.isLoggedIn;
    _wasGuestMode = AuthService.instance.isGuestMode;

    if (wasGuest && isNowLoggedIn) {
      // 游客模式登录成功，退出游客模式（不触发 notifyListeners 避免递归）
      // 迁移游客数据到正式用户，然后自动同步本地数据到服务器
      AppLogger.i('AuthWrapper', '游客模式登录成功，开始迁移数据并同步');
      AuthService.instance.exitGuestModeQuiet();
      // 迁移游客 SharedPreferences 数据和文件目录到正式用户
      UserDataManager.instance.migrateData('guest', 'user_${AuthService.instance.currentUserId}').then((_) {
        UserDataManager.instance.clearAllCaches();
        SyncService.instance.syncAll().then((result) {
          AppLogger.i('AuthWrapper', '自动同步完成: ${result.summary}');
        });
      });
    }

    // 登录成功时启动会话跟踪
    if (isNowLoggedIn && !SessionTracker.instance.isTracking) {
      SessionTracker.instance.startSession();
      // 启动自动同步（如果已设置间隔）
      if (appSettings.autoSyncInterval > 0) {
        SyncService.instance.startAutoSync();
      }
      // 登录成功后重启顶号检测
      _startKickedCheck();
    }

    // 登出时结束会话跟踪
    if (!isNowLoggedIn && SessionTracker.instance.isTracking) {
      SessionTracker.instance.endSession();
      // 停止自动同步
      SyncService.instance.stopAutoSync();
      // 登出时停止顶号检测
      _kickedCheckTimer?.cancel();
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 使用 ListenableBuilder 监听 AuthService 变化
    return ListenableBuilder(
      listenable: AuthService.instance,
      builder: (context, _) {
        // 已登录或游客模式均可进入首页
        if (AuthService.instance.canEnterApp) {
          return const HomePage();
        }
        return const LoginPage();
      },
    );
  }
}
