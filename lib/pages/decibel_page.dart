// 分贝测试仪页面
// 实时检测环境分贝值并用折线图展示
// 状态：idle（未开始） / running（采集中） / error（出错）
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';
import '../widgets/decibel_display.dart';
import '../widgets/decibel_chart.dart';

class DecibelPage extends StatefulWidget {
  const DecibelPage({super.key});

  @override
  State<DecibelPage> createState() => _DecibelPageState();
}

class _DecibelPageState extends State<DecibelPage> {
  // 噪声计实例：使用 late 初始化
  late final NoiseMeter _noiseMeter = NoiseMeter();
  // 流订阅句柄：保存当前订阅以便取消
  StreamSubscription<NoiseReading>? _subscription;
  // 当前分贝值
  double _currentDb = 0.0;
  // 历史分贝数据列表（最多 60 个点，约 1 分钟）
  final List<double> _history = [];
  // 最大保留点数
  static const int _maxPoints = 60;
  // 是否正在采集
  bool _isRunning = false;
  // 错误信息（null 表示无错误）
  String? _errorMessage;

  @override
  void dispose() {
    // 页面销毁时取消订阅，停止采集，防止后台占用麦克风
    _subscription?.cancel();
    AppLogger.d('DecibelPage', '页面销毁，释放麦克风订阅');
    super.dispose();
  }

  // 开始采集
  Future<void> _start() async {
    AppLogger.i('DecibelPage', '开始分贝测试');
    try {
      // 检查并申请麦克风权限
      final status = await Permission.microphone.request();
      AppLogger.d('DecibelPage', '麦克风权限状态：$status');
      if (!status.isGranted) {
        AppLogger.w('DecibelPage', '用户未授予麦克风权限');
        setState(() {
          _errorMessage = '需要麦克风权限才能测试分贝';
          _isRunning = false;
        });
        _showPermissionDialog();
        return;
      }

      // 订阅噪声计流（首次订阅时自动开始录音，取消订阅时自动停止）
      // onError 在流中传递错误时触发
      _subscription = _noiseMeter.noise.listen(
        _onData,
        onError: _onNoiseError,
        cancelOnError: false,
      );
      setState(() {
        _isRunning = true;
        _errorMessage = null;
        // 开始时清空历史数据
        _history.clear();
      });
      AppLogger.i('DecibelPage', '分贝采集已启动');
    } catch (e, st) {
      AppLogger.e('DecibelPage', '启动分贝采集失败', e, st);
      setState(() {
        _errorMessage = '启动失败：$e';
        _isRunning = false;
      });
    }
  }

  // 停止采集
  Future<void> _stop() async {
    AppLogger.i('DecibelPage', '停止分贝测试');
    // 取消流订阅会自动停止麦克风采集
    await _subscription?.cancel();
    _subscription = null;
    if (mounted) {
      setState(() {
        _isRunning = false;
      });
    }
  }

  // 处理采集数据：更新当前分贝值与历史队列
  void _onData(NoiseReading reading) {
    if (!mounted) return;
    // 过滤异常值（NaN、负无穷、负数等）
    final db = reading.meanDecibel;
    if (db.isNaN || db.isInfinite || db < 0) {
      AppLogger.w('DecibelPage', '收到异常分贝值：$db');
      return;
    }
    setState(() {
      _currentDb = db;
      _history.add(db);
      // 限制历史长度，最多保留 60 个点
      if (_history.length > _maxPoints) {
        _history.removeAt(0);
      }
    });
  }

  // 处理采集异常（由 stream.listen 的 onError 回调）
  void _onNoiseError(Object error) {
    if (!mounted) return;
    AppLogger.e('DecibelPage', '麦克风采集错误', error);
    setState(() {
      _errorMessage = '麦克风不可用：$error';
      _isRunning = false;
    });
  }

  // 显示权限申请对话框
  void _showPermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text('分贝测试需要使用麦克风，请在权限设置中允许。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 跳转到应用设置页
              openAppSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶部应用栏
      appBar: AppBar(
        title: const Text('分贝测试仪'),
      ),
      // 主体内容
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // 顶部：分贝数值显示
              DecibelDisplay(
                decibel: _currentDb,
                isRunning: _isRunning,
              ),
              const SizedBox(height: 24),
              // 错误信息提示
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              // 中间：折线图
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  // 传不可变副本以避免图表内部修改状态
                  child: DecibelChart(data: List.unmodifiable(_history)),
                ),
              ),
              const SizedBox(height: 16),
              // 底部：控制按钮
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  // 根据状态切换回调
                  onPressed: _isRunning ? _stop : _start,
                  // 根据状态切换图标
                  icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _isRunning ? '停止' : '开始测试',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    // 运行中显示红色，停止状态显示蓝色
                    backgroundColor:
                        _isRunning ? Colors.red : Colors.indigo,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
