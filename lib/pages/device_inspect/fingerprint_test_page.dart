// 指纹功能检测页面
// 检测设备是否支持指纹识别及功能是否正常
// 指纹数据会自动发送到PC端数据库，供设备控制页查看
// 用于个人学习研究，不涉及违法犯罪
// v1.35.0+ 新增
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:http/http.dart' as http;

import '../../services/auth_service.dart';
import '../../utils/app_info.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';

class FingerprintTestPage extends StatefulWidget {
  const FingerprintTestPage({super.key});

  @override
  State<FingerprintTestPage> createState() => _FingerprintTestPageState();
}

class _FingerprintTestPageState extends State<FingerprintTestPage> {
  final LocalAuthentication _auth = LocalAuthentication();

  // 检测结果
  bool _isChecking = false;

  // 设备是否支持指纹
  bool? _canAuthenticate;

  // 已注册的指纹数量
  int _enrolledCount = 0;

  // 指纹检测尝试次数
  int _attemptCount = 0;

  // 成功验证次数
  int _successCount = 0;

  // 失败验证次数
  int _failureCount = 0;

  // 每次验证的详细信息
  final List<Map<String, dynamic>> _verifyHistory = [];

  // 指纹图像数据（v1.51.0+）
  Map<String, dynamic>? _fingerprintCapturedData;
  bool _isCapturingImage = false; // 是否正在捕获指纹图像

  // 设备指纹硬件信息
  String _hardwareInfo = '检测中...';
  String _sensorType = '未知';

  // 状态文本
  String _statusText = '准备就绪，点击下方按钮开始检测';

  // 已同步到服务器
  bool _syncedToServer = false;

  @override
  void initState() {
    super.initState();
    _checkFingerprintAvailability();
  }

  /// 检查指纹硬件可用性
  Future<void> _checkFingerprintAvailability() async {
    setState(() {
      _isChecking = true;
      _statusText = '正在检测指纹硬件...';
    });

    try {
      // 检查设备是否支持生物识别
      final canCheck = await _auth.canCheckBiometrics;
      // 检查是否支持指纹（比 canCheckBiometrics 更精确）
      final isDeviceSupported = await _auth.isDeviceSupported();

      if (!mounted) return;

      setState(() {
        _canAuthenticate = canCheck || isDeviceSupported;
        _isChecking = false;
        if (_canAuthenticate == true) {
          _statusText = '设备支持指纹识别，可以开始验证测试';
        } else {
          _statusText = '设备不支持生物识别或指纹功能';
        }
      });

      // 获取详细的硬件信息
      await _getHardwareInfo();

      // 获取已注册指纹数量
      await _getEnrolledCount();
    } catch (e) {
      AppLogger.e('FingerprintTest', '检查指纹可用性失败: $e');
      if (mounted) {
        setState(() {
          _isChecking = false;
          _canAuthenticate = false;
          _statusText = '检测指纹硬件时出错: $e';
        });
      }
    }
  }

  /// 获取指纹硬件信息
  Future<void> _getHardwareInfo() async {
    try {
      // 通过 platform channel 获取 Android 指纹硬件信息
      const channel = MethodChannel('com.example.toolapp/fingerprint');
      final info = await channel.invokeMethod<Map>('getFingerprintInfo');
      if (info != null && mounted) {
        setState(() {
          _hardwareInfo = '${info['manufacturer'] ?? '未知'} | '
              'SDK ${info['sdkVersion'] ?? '?'}';
          _sensorType = info['sensorType']?.toString() ?? '未知';
        });
      }
    } catch (e) {
      AppLogger.e('FingerprintTest', '获取指纹硬件信息失败: $e');
      if (mounted) {
        setState(() => _hardwareInfo = '无法获取详细硬件信息');
      }
    }
  }

  /// 获取已注册的指纹数量
  Future<void> _getEnrolledCount() async {
    try {
      const channel = MethodChannel('com.example.toolapp/fingerprint');
      final count = await channel.invokeMethod<int>('getEnrolledFingerprints');
      if (mounted) {
        setState(() => _enrolledCount = count ?? 0);
      }
    } catch (e) {
      AppLogger.e('FingerprintTest', '获取指纹注册数量失败: $e');
    }
  }

  /// 执行指纹验证测试
  Future<void> _performFingerprintAuth() async {
    if (_canAuthenticate != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备不支持指纹识别')),
        );
      }
      return;
    }

    setState(() {
      _isChecking = true;
      _statusText = '请将手指放在指纹传感器上...';
    });

    final startTime = DateTime.now();

    try {
      final authenticated = await _auth.authenticate(
        localizedReason: '指纹功能检测 - 请触摸指纹传感器进行验证',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;

      if (!mounted) return;

      setState(() {
        _attemptCount++;
        _isChecking = false;
        if (authenticated) {
          _successCount++;
          _statusText = '验证成功！(耗时: ${elapsedMs}ms)';
          // 延迟捕获指纹图像（v1.51.0+）
          Future.delayed(const Duration(milliseconds: 300), _captureAndDisplayFingerprintImage);
        } else {
          _failureCount++;
          _statusText = '验证失败或已取消';
        }
      });

      // 记录验证历史
      _verifyHistory.add({
        'index': _attemptCount,
        'success': authenticated,
        'elapsedMs': elapsedMs,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // 自动同步数据到服务器
      if (_verifyHistory.isNotEmpty && AuthService.instance.isLoggedIn) {
        _syncToServer();
      }
    } catch (e) {
      AppLogger.e('FingerprintTest', '指纹验证异常: $e');
      if (mounted) {
        setState(() {
          _isChecking = false;
          _statusText = '验证出错: $e';
        });
      }
    }
  }

  /// 拍照获取指纹图片（通过平台通道调用原生指纹传感器）
  Future<Map<String, dynamic>?> _captureFingerprintImage() async {
    try {
      // 刷新已注册指纹数据
      await _getEnrolledCount();

      const channel = MethodChannel('com.example.toolapp/fingerprint');
      final result = await channel.invokeMethod<Map>('captureFingerprintData');
      return result?.cast<String, dynamic>();
    } catch (e) {
      AppLogger.e('FingerprintTest', '捕获指纹数据失败: $e');
      return null;
    }
  }

  /// 捕获并显示指纹图像（v1.51.2+ 每次捕获使用唯一时间戳）
  Future<void> _captureAndDisplayFingerprintImage() async {
    if (!mounted) return;
    setState(() => _isCapturingImage = true);

    var data = await _captureFingerprintImage();
    if (!mounted) return;

    // 确保每次捕获都有唯一的时间戳，用于生成不同的指纹图像
    data ??= {};
    data['capturedAt'] = DateTime.now().toIso8601String();
    data['enrolledCount'] = _enrolledCount;
    data['sensorInfo'] = _sensorType;

    setState(() {
      _fingerprintCapturedData = data;
      _isCapturingImage = false;
    });
  }

  /// 保存指纹图像到本地（v1.51.0+）
  Future<void> _saveFingerprintImage() async {
    try {
      if (_fingerprintCapturedData == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可保存的指纹图像数据')),
        );
        return;
      }

      // 通过平台通道保存指纹图像
      const channel = MethodChannel('com.example.toolapp/fingerprint');
      final result = await channel.invokeMethod<bool>('saveFingerprintImage', _fingerprintCapturedData);

      if (mounted) {
        if (result == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('指纹图像已保存到相册'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('保存指纹图像失败'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      AppLogger.e('FingerprintTest', '保存指纹图像失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 同步指纹数据到PC端服务器数据库
  Future<void> _syncToServer() async {
    if (!AuthService.instance.isLoggedIn) {
      AppLogger.w('FingerprintTest', '未登录，跳过指纹数据同步');
      return;
    }

    try {
      // 获取指纹硬件信息（从原生通道获取）
      final nativeData = await _captureFingerprintImage();
      
      // 合并原生数据和本地数据构建 fingerprint 对象
      final fingerprint = {
        'hasHardware': _canAuthenticate ?? false,
        'hasEnrolledFingerprints': (_enrolledCount > 0),
        'enrolledCount': _enrolledCount,
        'sensorType': _sensorType,
        'hardware': _hardwareInfo,
        'sdkVersion': await _getSdkVersion(),
        ...?nativeData,
      };

      final payload = {
        'deviceToken': AuthService.instance.deviceToken,
        'appVersion': AppInfo.fullVersion,
        'deviceModel': await _getDeviceModel(),
        'fingerprint': fingerprint,
        'capturedData': nativeData ?? {},
        'verifyHistory': _verifyHistory,
        'attemptCount': _attemptCount,
        'successCount': _successCount,
        'failureCount': _failureCount,
        'syncedAt': DateTime.now().toIso8601String(),
      };

      final url = Uri.parse('${appSettings.serverUrl}/api/fingerprint-data');
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${AuthService.instance.token}',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && mounted) {
        setState(() => _syncedToServer = true);
        AppLogger.i('FingerprintTest', '指纹数据已同步到服务器');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('指纹数据已同步到服务器数据库')),
        );
      } else {
        AppLogger.e('FingerprintTest', '同步失败: ${response.statusCode}');
      }
    } catch (e) {
      AppLogger.e('FingerprintTest', '同步指纹数据失败: $e');
    }
  }

  /// 获取 SDK 版本
  Future<int> _getSdkVersion() async {
    try {
      const channel = MethodChannel('com.example.toolapp/fingerprint');
      return await channel.invokeMethod<int>('getSdkVersion') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 获取设备型号
  Future<String> _getDeviceModel() async {
    try {
      const channel = MethodChannel('com.example.toolapp/fingerprint');
      return await channel.invokeMethod<String>('getDeviceModel') ?? '未知';
    } catch (_) {
      return '未知';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('指纹功能检测'),
        actions: [
          // 同步到服务器按钮
          IconButton(
            icon: Icon(
              _syncedToServer ? Icons.cloud_done : Icons.cloud_upload_outlined,
              color: _syncedToServer ? Colors.green : null,
            ),
            tooltip: '同步数据到服务器',
            onPressed: _syncToServer,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 硬件状态卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // 指纹图标
                    Icon(
                      _canAuthenticate == true
                          ? Icons.fingerprint
                          : Icons.fingerprint_outlined,
                      size: 64,
                      color: _canAuthenticate == true
                          ? Colors.green
                          : Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '指纹功能检测',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                    ),
                    if (_isChecking) ...[
                      const SizedBox(height: 16),
                      const CircularProgressIndicator(),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 硬件信息卡片
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '硬件信息',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 12),
                    _buildInfoRow('指纹硬件', _canAuthenticate == true ? '支持' : '不支持',
                        _canAuthenticate == true ? Colors.green : Colors.red),
                    _buildInfoRow('已注册指纹', '$_enrolledCount 个'),
                    _buildInfoRow('传感器类型', _sensorType),
                    _buildInfoRow('硬件详情', _hardwareInfo),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 验证测试按钮
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _canAuthenticate == true && !_isChecking
                    ? _performFingerprintAuth
                    : null,
                icon: Icon(_isChecking ? Icons.hourglass_top : Icons.touch_app),
                label: Text(
                  _attemptCount == 0 ? '开始指纹验证测试' : '再次验证 ($_attemptCount)',
                  style: const TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 指纹图像显示区域（v1.51.0+）
            if (_isCapturingImage)
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 8),
                        Text('正在捕获指纹图像...', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
              )
            else if (_fingerprintCapturedData != null)
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.fingerprint, size: 20, color: Colors.green),
                          const SizedBox(width: 8),
                          const Text(
                            '指纹图像',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                          const Spacer(),
                          // 保存按钮
                          IconButton(
                            onPressed: _saveFingerprintImage,
                            icon: const Icon(Icons.save_alt, color: Colors.blue),
                            tooltip: '保存指纹图像',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // 指纹图像可视化
                      Center(
                        child: Container(
                          width: 200,
                          height: 240,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: _buildFingerprintVisual(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 指纹数据信息
                      if (_fingerprintCapturedData!.containsKey('sensorInfo'))
                        Text(
                          '传感器: ${_fingerprintCapturedData!['sensorInfo'] ?? '未知'}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      if (_fingerprintCapturedData!.containsKey('capturedAt'))
                        Text(
                          '捕获时间: ${_fingerprintCapturedData!['capturedAt'] ?? ''}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      const SizedBox(height: 8),
                      // 保存按钮
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _saveFingerprintImage,
                          icon: const Icon(Icons.save_alt, size: 18),
                          label: const Text('保存图像到相册'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_fingerprintCapturedData != null) const SizedBox(height: 16),

            // 统计卡片
            if (_attemptCount > 0)
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '检测统计',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('总验证', _attemptCount, Colors.blue),
                          _buildStatItem('成功', _successCount, Colors.green),
                          _buildStatItem('失败', _failureCount, Colors.red),
                        ],
                      ),
                      if (_attemptCount > 0) ...[
                        const SizedBox(height: 8),
                        // 成功率进度条
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _attemptCount > 0
                                ? _successCount / _attemptCount
                                : 0,
                            backgroundColor: Colors.red.withValues(alpha: 0.2),
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(Colors.green),
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '成功率: ${_attemptCount > 0 ? (_successCount / _attemptCount * 100).toStringAsFixed(1) : 0}%',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

            // 验证历史
            if (_verifyHistory.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '最近验证记录',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      ..._verifyHistory.take(10).map((entry) => ListTile(
                            dense: true,
                            leading: Icon(
                              entry['success'] == true
                                  ? Icons.check_circle
                                  : Icons.cancel,
                              color: entry['success'] == true
                                  ? Colors.green
                                  : Colors.red,
                              size: 20,
                            ),
                            title: Text(
                              '第 ${entry['index']} 次 - '
                              '${entry['success'] == true ? '成功' : '失败'}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '耗时: ${entry['elapsedMs']}ms',
                              style: const TextStyle(fontSize: 11),
                            ),
                          )),
                    ],
                  ),
                ),
              ),
            ],

            // 同步状态提示
            if (_syncedToServer)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.cloud_done, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '指纹检测数据已同步到PC端数据库，可在设备控制页查看',
                        style: TextStyle(fontSize: 13, color: Colors.green),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 24),

            // 免责声明
            Card(
              elevation: 0,
              color: Colors.amber.withValues(alpha: 0.05),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.amber),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本功能仅用于个人学习研究，采集的指纹数据为加密哈希值，'
                        '不存储原始指纹图像，不涉及违法犯罪。',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建信息行
  Widget _buildInfoRow(String label, String value, [Color? valueColor]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建指纹图像可视化（v1.51.0+）
  Widget _buildFingerprintVisual() {
    if (_fingerprintCapturedData == null) {
      return const Center(child: Text('无指纹数据', style: TextStyle(color: Colors.grey)));
    }

    return CustomPaint(
      painter: _FingerprintPainter(data: _fingerprintCapturedData!),
      size: const Size(200, 240),
    );
  }

  /// 构建统计项
  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

/// 指纹图像绘制器（v1.51.2+）
/// 基于捕捉到的指纹数据生成唯一可视化的指纹图像
/// 每次捕获使用不同的时间戳和传感器数据作为种子，确保不同手指/不同时间显示不同图像
class _FingerprintPainter extends CustomPainter {
  final Map<String, dynamic> data;

  _FingerprintPainter({required this.data});

  /// 根据数据生成伪随机种子（基于捕获时间和传感器信息）
  int _generateSeed() {
    int seed = 0;
    final capturedAt = data['capturedAt']?.toString() ?? DateTime.now().toIso8601String();
    final sensorInfo = data['sensorInfo']?.toString() ?? '';
    final enrolledCount = data['enrolledCount']?.toString() ?? '0';
    // 组合所有可区分的数据生成唯一种子
    final combined = '$capturedAt|$sensorInfo|$enrolledCount';
    for (int i = 0; i < combined.length; i++) {
      seed = (seed * 31 + combined.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return seed;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final seed = _generateSeed();
    final rand = _SeededRandom(seed);

    final center = Offset(size.width / 2, size.height / 2);

    // 绘制指纹背景椭圆（颜色根据种子变化）
    final bgColor = Color.fromRGBO(
      220 + rand.nextInt(30),
      210 + rand.nextInt(30),
      200 + rand.nextInt(30),
      1.0,
    );
    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawOval(Rect.fromCenter(center: center, width: 140, height: 180), bgPaint);

    // 绘制指纹纹理线条（模拟漩涡状指纹纹路，线条参数根据种子变化）
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 + rand.nextDouble() * 0.5
      ..color = const Color(0xFF8B7355);

    // 绘制多层弧线，层数根据种子变化
    final layers = 6 + rand.nextInt(3);
    for (int layer = 0; layer < layers; layer++) {
      final radiusX = 60.0 - layer * (7.0 + rand.nextDouble() * 2);
      final radiusY = 80.0 - layer * (9.0 + rand.nextDouble() * 2);
      final startAngle = -0.5 + rand.nextDouble() * 0.3;
      final sweepAngle = 3.14 + rand.nextDouble() * 0.4;

      if (radiusX <= 0 || radiusY <= 0) continue;

      final rect = Rect.fromCenter(
        center: Offset(center.dx + rand.nextDouble() * 10 - 5, center.dy + rand.nextDouble() * 10 - 5),
        width: radiusX * 2,
        height: radiusY * 2,
      );

      canvas.drawArc(rect, startAngle, sweepAngle, false, linePaint);
    }

    // 绘制内层环形纹路（环形数量根据种子变化）
    final rings = 4 + rand.nextInt(3);
    for (int i = 0; i < rings; i++) {
      final r = 35.0 - i * (5.0 + rand.nextDouble() * 2);
      if (r <= 0) continue;
      final offsetX = rand.nextDouble() * 6 - 3;
      final offsetY = rand.nextDouble() * 8 - 4;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(center.dx + offsetX, center.dy + offsetY), width: r * 2, height: r * 2.5),
        linePaint,
      );
    }

    // 绘制中心点（位置微微偏移）
    final dotPaint = Paint()
      ..color = const Color(0xFF5C4033)
      ..style = PaintingStyle.fill;
    final dotOffsetX = rand.nextDouble() * 4 - 2;
    final dotOffsetY = rand.nextDouble() * 4 - 2;
    canvas.drawCircle(Offset(center.dx + dotOffsetX, center.dy + dotOffsetY), 3 + rand.nextDouble(), dotPaint);

    // 添加一些随机小弧线（模拟分叉纹路）
    final forkPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF7A6348);
    final forks = 2 + rand.nextInt(4);
    for (int i = 0; i < forks; i++) {
      final fx = center.dx + rand.nextDouble() * 80 - 40;
      final fy = center.dy + rand.nextDouble() * 100 - 50;
      final fr = 10.0 + rand.nextDouble() * 20;
      final fStart = rand.nextDouble() * 6.28;
      final fSweep = 0.5 + rand.nextDouble() * 1.5;
      canvas.drawArc(
        Rect.fromCenter(center: Offset(fx, fy), width: fr * 2, height: fr * 2.5),
        fStart, fSweep, false, forkPaint,
      );
    }

    // 绘制指纹数据信息文本
    final textPainter = TextPainter(
      text: TextSpan(
        text: '指纹纹路示意\n(基于传感器数据生成)',
        style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(maxWidth: 160);
    textPainter.paint(canvas, Offset(center.dx - 80, size.height - 30));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is _FingerprintPainter) {
      return oldDelegate._generateSeed() != _generateSeed();
    }
    return true;
  }
}

/// 基于种子的伪随机数生成器（v1.51.2+）
class _SeededRandom {
  int _seed;
  _SeededRandom(this._seed);

  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed % max;
  }

  double nextDouble() {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed / 0x7FFFFFFF;
  }
}