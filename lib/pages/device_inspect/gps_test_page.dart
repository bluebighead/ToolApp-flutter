// GPS定位检测工具
// 检测手机GPS定位是否正常，显示真实实时坐标
// 内置OpenStreetMap地图直接显示位置，不跳转任何第三方App
// v1.52.5+ 新增
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../utils/app_logger.dart';

class GpsTestPage extends StatefulWidget {
  const GpsTestPage({super.key});

  @override
  State<GpsTestPage> createState() => _GpsTestPageState();
}

class _GpsTestPageState extends State<GpsTestPage> {
  // GPS状态
  bool _isGpsEnabled = false;
  bool _isLocationPermissionGranted = false;
  bool _isGettingLocation = false;

  // 位置信息
  Position? _currentPosition;
  StreamSubscription<Position>? _positionStream;

  // 错误信息
  String? _errorMessage;

  // 坐标历史记录（用于绘制轨迹）
  final List<LatLng> _trackPoints = [];

  // 地图控制器
  final MapController _mapController = MapController();

  // 地图是否已初始化中心点
  bool _mapCentered = false;

  @override
  void initState() {
    super.initState();
    _checkGpsStatus();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  // 检测GPS状态
  Future<void> _checkGpsStatus() async {
    setState(() {
      _isGettingLocation = true;
      _errorMessage = null;
    });

    try {
      // 检查定位服务是否开启
      final isEnabled = await Geolocator.isLocationServiceEnabled();
      setState(() {
        _isGpsEnabled = isEnabled;
      });

      if (!isEnabled) {
        setState(() {
          _isGettingLocation = false;
          _errorMessage = 'GPS定位服务未开启，请在系统设置中开启GPS定位';
        });
        return;
      }

      // 检查定位权限
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _isGettingLocation = false;
            _errorMessage = '定位权限被拒绝，请在系统设置中授予定位权限';
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _isGettingLocation = false;
          _errorMessage = '定位权限被永久拒绝，请在系统设置中手动开启';
        });
        return;
      }

      setState(() {
        _isLocationPermissionGranted = true;
      });

      AppLogger.i('GpsTestPage', 'GPS权限已获取，开始获取位置');

      // 获取当前位置
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );

      setState(() {
        _currentPosition = position;
        _isGettingLocation = false;
      });

      // 添加初始点到轨迹
      _trackPoints.add(LatLng(position.latitude, position.longitude));

      // 地图中心定位到当前位置
      if (!_mapCentered) {
        _mapController.move(LatLng(position.latitude, position.longitude), 16);
        _mapCentered = true;
      }

      // 开始持续监听位置变化
      _startPositionStream();

      AppLogger.i('GpsTestPage', 'GPS定位成功: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      setState(() {
        _isGettingLocation = false;
        _errorMessage = '获取位置失败: ${e.toString().split('\n').first}';
      });
      AppLogger.e('GpsTestPage', '获取位置失败: $e');
    }
  }

  // 开始持续监听位置变化
  void _startPositionStream() {
    _positionStream?.cancel();

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 5,  // 移动5米后更新
      timeLimit: null,    // 无时间限制
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        setState(() {
          _currentPosition = position;
        });

        final newPoint = LatLng(position.latitude, position.longitude);
        // 避免添加重复点
        if (_trackPoints.isEmpty ||
            (_trackPoints.last.latitude != newPoint.latitude ||
             _trackPoints.last.longitude != newPoint.longitude)) {
          _trackPoints.add(newPoint);
          // 限制轨迹点数量，保留最近200个点
          if (_trackPoints.length > 200) {
            _trackPoints.removeAt(0);
          }
        }

        // 自动跟随位置移动地图
        if (position.speed > 0.5) {
          _mapController.move(newPoint, _mapController.camera.zoom);
        }
      },
      onError: (error) {
        AppLogger.e('GpsTestPage', '位置流错误: $error');
        setState(() {
          _errorMessage = '位置更新失败: ${error.toString().split('\n').first}';
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS定位检测'),
        actions: [
          // 重新检测按钮
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新检测',
            onPressed: _checkGpsStatus,
          ),
        ],
      ),
      body: Column(
        children: [
          // GPS状态信息面板
          _buildStatusPanel(theme),

          // 地图显示区域
          Expanded(
            child: _buildMapView(),
          ),
        ],
      ),
    );
  }

  // 构建GPS状态信息面板
  Widget _buildStatusPanel(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // GPS状态指示器
          Row(
            children: [
              _buildStatusDot(),
              const SizedBox(width: 8),
              Text(
                _getStatusText(),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // 坐标更新时间
              if (_currentPosition != null)
                Text(
                  '精度: ${_currentPosition!.accuracy.toStringAsFixed(1)}m',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),

          // 实时坐标信息
          if (_currentPosition != null) ...[
            const SizedBox(height: 10),
            _buildCoordinateRow('纬度 (Lat)', _currentPosition!.latitude.toStringAsFixed(6)),
            _buildCoordinateRow('经度 (Lng)', _currentPosition!.longitude.toStringAsFixed(6)),
            _buildCoordinateRow('海拔高度', '${_currentPosition!.altitude.toStringAsFixed(1)} m'),
            _buildCoordinateRow('移动速度', '${(_currentPosition!.speed * 3.6).toStringAsFixed(1)} km/h'),
            _buildCoordinateRow('方向角度', '${_currentPosition!.heading.toStringAsFixed(1)}°'),
          ],

          // 加载中/错误提示
          if (_isGettingLocation)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在获取GPS定位...', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),

          if (_errorMessage != null && !_isGettingLocation)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // GPS状态圆点
  Widget _buildStatusDot() {
    Color dotColor;
    if (_isGettingLocation) {
      dotColor = Colors.orange;
    } else if (_currentPosition != null) {
      dotColor = Colors.green;
    } else if (_errorMessage != null) {
      dotColor = Colors.red;
    } else {
      dotColor = Colors.grey;
    }

    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: dotColor.withValues(alpha: 0.4),
            blurRadius: 4,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  // 获取状态文本
  String _getStatusText() {
    if (_isGettingLocation) return '正在获取GPS定位...';
    if (_currentPosition != null) return 'GPS定位正常';
    if (_errorMessage != null) return 'GPS定位异常';
    return '等待检测';
  }

  // 构建坐标显示行
  Widget _buildCoordinateRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建内置地图视图（使用OpenStreetMap，不跳转第三方App）
  Widget _buildMapView() {
    final center = _currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : const LatLng(39.90923, 116.39747); // 默认中心：北京天安门

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Flutter原生地图（OpenStreetMap瓦片）
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 16,
                minZoom: 3,
                maxZoom: 18,
                // 交互选项
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
              ),
              children: [
                // 高德地图免费瓦片图层（国内网络友好，无需API Key）
                TileLayer(
                  urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                  subdomains: const ['1', '2', '3', '4'],
                  userAgentPackageName: 'com.example.toolapp',
                  maxZoom: 18,
                ),

                // 当前位置标记
                if (_currentPosition != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(
                          _currentPosition!.latitude,
                          _currentPosition!.longitude,
                        ),
                        width: 40,
                        height: 40,
                        child: const _GpsMarker(),
                      ),
                    ],
                  ),

                // 移动轨迹线
                if (_trackPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline<LatLng>(
                        points: _trackPoints,
                        color: Colors.blue.withValues(alpha: 0.6),
                        strokeWidth: 3,
                      ),
                    ],
                  ),
              ],
            ),

            // 地图底部信息栏
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.map, size: 14, color: Colors.blue),
                    const SizedBox(width: 4),
                    Text(
                      'OpenStreetMap',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const Spacer(),
                    if (_trackPoints.length > 1)
                      Text(
                        '轨迹: ${_trackPoints.length}点',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    if (_currentPosition != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        '缩放: ${_mapController.camera.zoom.toStringAsFixed(1)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 定位当前位置按钮
            Positioned(
              top: 8,
              right: 8,
              child: FloatingActionButton.small(
                heroTag: 'gps_center',
                onPressed: _currentPosition != null
                    ? () {
                        _mapController.move(
                          LatLng(
                            _currentPosition!.latitude,
                            _currentPosition!.longitude,
                          ),
                          16,
                        );
                        _mapCentered = true;
                      }
                    : null,
                tooltip: '定位到当前位置',
                backgroundColor: Colors.white,
                child: const Icon(Icons.my_location, color: Colors.blue),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// GPS位置标记组件（带脉冲动画效果）
class _GpsMarker extends StatefulWidget {
  const _GpsMarker();

  @override
  State<_GpsMarker> createState() => _GpsMarkerState();
}

class _GpsMarkerState extends State<_GpsMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        return Transform.scale(
          scale: _anim.value,
          child: child,
        );
      },
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.blue,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.location_on,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }
}