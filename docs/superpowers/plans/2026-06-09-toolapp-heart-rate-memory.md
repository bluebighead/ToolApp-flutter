# 心率设备连接记忆功能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为心率广播接收器添加设备连接记忆功能，使用 SharedPreferences 持久化设备信息，实现下次打开时自动连接

**Architecture:** 在 HeartRateBle 类中封装 SharedPreferences 读写逻辑，提供自动连接方法。页面层在 _startBle() 中检测记忆设备并触发自动连接流程。

**Tech Stack:** Flutter, flutter_reactive_ble, shared_preferences

---

### Task 1: 在 HeartRateBle 中添加设备记忆功能

**Files:**
- Modify: `lib/utils/heart_rate_ble.dart`

- [ ] **Step 1: 添加 shared_preferences 导入和记忆相关方法**

在 `lib/utils/heart_rate_ble.dart` 文件顶部，`import 'app_logger.dart';` 之后添加：

```dart
import 'package:shared_preferences/shared_preferences.dart';
```

在 `HeartRateBle` 类中，`dispose()` 方法之前添加以下方法：

```dart
  /// 保存最后连接的设备信息到本地存储
  Future<void> _saveLastConnectedDevice(String deviceId, String deviceName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_connected_ble_device_id', deviceId);
      await prefs.setString('last_connected_ble_device_name', deviceName);
      AppLogger.i('HeartRateBle', '已保存记忆设备: $deviceName ($deviceId)');
    } catch (e) {
      AppLogger.e('HeartRateBle', '保存记忆设备失败', e);
    }
  }

  /// 获取最后连接的设备信息
  Future<Map<String, String>?> _getLastConnectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('last_connected_ble_device_id');
      final deviceName = prefs.getString('last_connected_ble_device_name');
      if (deviceId != null && deviceName != null) {
        return {'id': deviceId, 'name': deviceName};
      }
      return null;
    } catch (e) {
      AppLogger.e('HeartRateBle', '读取记忆设备失败', e);
      return null;
    }
  }

  /// 清除记忆设备（保留接口，当前不使用）
  Future<void> _clearLastConnectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_connected_ble_device_id');
      await prefs.remove('last_connected_ble_device_name');
      AppLogger.i('HeartRateBle', '已清除记忆设备');
    } catch (e) {
      AppLogger.e('HeartRateBle', '清除记忆设备失败', e);
    }
  }
```

- [ ] **Step 2: 修改 `connectToDevice` 方法，连接成功后自动保存记忆**

在 `connectToDevice` 方法中，找到 `DeviceConnectionState.connected` 分支，在 `_connectedDeviceId = deviceId;` 之后、`onStatus('已连接');` 之前添加保存记忆的代码：

修改前：
```dart
          if (connectionState.connectionState == DeviceConnectionState.connected) {
            AppLogger.i('HeartRateBle', '设备已连接: $deviceId');
            _isConnected = true;
            _connectedDeviceId = deviceId;
            onStatus('已连接');
```

修改后：
```dart
          if (connectionState.connectionState == DeviceConnectionState.connected) {
            AppLogger.i('HeartRateBle', '设备已连接: $deviceId');
            _isConnected = true;
            _connectedDeviceId = deviceId;
            // 保存记忆设备（从扫描列表中获取设备名称）
            final deviceName = _scannedDevices[deviceId]?.name ?? '未知设备';
            await _saveLastConnectedDevice(deviceId, deviceName);
            onStatus('已连接');
```

- [ ] **Step 3: 添加自动连接方法**

在 `_subscribeToHeartRate` 方法之后添加自动连接方法：

```dart
  /// 自动连接记忆设备
  /// 开始扫描，当扫描到记忆设备时自动连接
  /// [onStatus] 回调用于传递状态信息
  /// [onDeviceFound] 回调用于通知页面层记忆设备已找到并开始连接
  Future<void> autoConnectLastDevice({
    required Function(String status) onStatus,
    Function()? onDeviceFound,
  }) async {
    final lastDevice = await _getLastConnectedDevice();
    if (lastDevice == null) {
      AppLogger.i('HeartRateBle', '无记忆设备，跳过自动连接');
      return;
    }

    AppLogger.i('HeartRateBle', '开始自动连接记忆设备: ${lastDevice['name']} (${lastDevice['id']})');
    onStatus('正在寻找上次连接的设备...');

    // 开始扫描
    await startScan(
      onStatus: (status) {
        // 只在非匹配状态时传递状态，避免覆盖"正在寻找..."提示
        if (!status.contains('正在寻找')) {
          onStatus(status);
        }
      },
    );

    // 监听设备列表，当记忆设备出现时自动连接
    devicesStream.stream.listen(
      (devices) {
        final targetDevice = devices.firstWhere(
          (d) => d.id == lastDevice['id'],
          orElse: () => ScannedDevice(id: '', name: '', rssi: 0),
        );

        if (targetDevice.id.isNotEmpty && !_isConnected) {
          AppLogger.i('HeartRateBle', '找到记忆设备: ${targetDevice.name}');
          onDeviceFound?.call();
          // 停止扫描并自动连接
          stopScan().then((_) {
            connectToDevice(
              targetDevice.id,
              onStatus: onStatus,
            ).catchError((e) {
              AppLogger.w('HeartRateBle', '自动连接失败，继续扫描等待', e);
              // 连接失败后重新开始扫描等待
              startScan(onStatus: (status) {
                if (!status.contains('正在寻找')) {
                  onStatus(status);
                }
              });
            });
          });
        }
      },
    );
  }
```

- [ ] **Step 4: 提交**

```bash
git add lib/utils/heart_rate_ble.dart
git commit -m "feat: 心率BLE添加设备连接记忆功能"
```

---

### Task 2: 修改页面层支持自动连接流程

**Files:**
- Modify: `lib/pages/heart_rate_page.dart`

- [ ] **Step 1: 添加 `_hasMemoryDevice` 状态变量**

在 `_HeartRatePageState` 类中，`_errorMessage` 变量之后添加：

```dart
  // 是否有记忆设备（用于UI提示）
  bool _hasMemoryDevice = false;
```

- [ ] **Step 2: 修改 `_startBle()` 方法，支持自动连接**

将 `_startBle()` 方法替换为以下代码：

```dart
  /// 启动BLE接收
  Future<void> _startBle() async {
    // 检查蓝牙和位置权限（Android 12+需要bluetoothScan和bluetoothConnect）
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    final locationStatus = await Permission.location.request();

    if (!scanStatus.isGranted || !connectStatus.isGranted || !locationStatus.isGranted) {
      setState(() {
        _errorMessage = '需要蓝牙和位置权限';
        _status = '权限被拒绝';
      });
      return;
    }

    // 订阅心率数据流
    _heartRateSubscription = _ble.heartRateStream.stream.listen(
      _onHeartRateData,
      onError: _onHeartRateError,
    );

    // 检查是否有记忆设备，有则尝试自动连接
    final hasMemory = await _checkMemoryDevice();

    if (hasMemory) {
      // 有记忆设备，尝试自动连接
      await _ble.autoConnectLastDevice(
        onStatus: (status) {
          if (mounted) {
            setState(() => _status = status);
          }
        },
        onDeviceFound: () {
          if (mounted) {
            setState(() {
              _status = '找到记忆设备，正在连接...';
            });
          }
        },
      );
      setState(() {
        _isScanning = true;
        _hasMemoryDevice = true;
      });
    } else {
      // 无记忆设备，保持原有行为（扫描等待用户选择）
      await _ble.startScan(
        onStatus: (status) {
          if (mounted) {
            setState(() => _status = status);
          }
        },
      );
      setState(() {
        _isScanning = true;
        _hasMemoryDevice = false;
      });
    }
  }

  /// 检查是否有记忆设备
  Future<bool> _checkMemoryDevice() async {
    // 通过尝试获取记忆设备来判断（HeartRateBle内部处理）
    // 这里简化处理：直接检查BLE类是否有记忆
    // 由于记忆功能在HeartRateBle内部，我们通过autoConnectLastDevice的返回值判断
    // 实际上autoConnectLastDevice在无记忆时会直接return，不会启动扫描
    // 所以我们先调用一次检查
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('last_connected_ble_device_id');
    return deviceId != null;
  }
```

- [ ] **Step 3: 添加 SharedPreferences 导入**

在文件顶部 import 区域，`import '../widgets/heart_rate_chart.dart';` 之后添加：

```dart
import 'package:shared_preferences/shared_preferences.dart';
```

- [ ] **Step 4: 修改设备列表，标记"上次连接"的设备**

在 `_buildDeviceListSheet()` 方法中，找到 `ListTile` 的 `subtitle` 部分，修改为：

修改前：
```dart
                    subtitle: Text(
                      'ID: ${device.id}\n信号强度: ${device.rssi} dBm',
                      style: const TextStyle(fontSize: 12),
                    ),
```

修改后：
```dart
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ID: ${device.id}\n信号强度: ${device.rssi} dBm',
                          style: const TextStyle(fontSize: 12),
                        ),
                        // 标记上次连接的设备
                        if (_ble.connectedDeviceId != device.id && _hasMemoryDevice)
                          FutureBuilder<Map<String, String>?>(
                            future: _ble._getLastConnectedDevice(),
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data!['id'] == device.id) {
                                return Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '上次连接',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                      ],
                    ),
```

注意：`_getLastConnectedDevice` 需要从 private 改为 public（去掉下划线），或者在 HeartRateBle 中添加一个 public getter：

在 `HeartRateBle` 类中添加：

```dart
  /// 获取记忆设备信息（public版本）
  Future<Map<String, String>?> getLastConnectedDevice() => _getLastConnectedDevice();
```

然后将页面中的 `_ble._getLastConnectedDevice()` 改为 `_ble.getLastConnectedDevice()`。

- [ ] **Step 5: 修改 `_stopReceiving()` 清除 `_hasMemoryDevice` 状态**

在 `_stopReceiving()` 的 `setState` 中添加 `_hasMemoryDevice = false;`：

修改前：
```dart
      setState(() {
        _isActive = false;
        _isScanning = false;
        _status = '未连接';
      });
```

修改后：
```dart
      setState(() {
        _isActive = false;
        _isScanning = false;
        _hasMemoryDevice = false;
        _status = '未连接';
      });
```

- [ ] **Step 6: 提交**

```bash
git add lib/pages/heart_rate_page.dart
git commit -m "feat: 心率页面支持自动连接记忆设备"
```

---

### Task 3: 测试和验证

**Files:**
- 无文件变更

- [ ] **Step 1: 运行 flutter analyze 检查代码**

```bash
flutter analyze
```

Expected: 无错误或警告

- [ ] **Step 2: 提交**

```bash
git commit --allow-empty -m "chore: 心率设备记忆功能代码检查通过"
```

---

## 自审检查

### 1. 规范覆盖
- [x] SharedPreferences 持久化：Task 1 Step 1
- [x] 连接成功自动保存：Task 1 Step 2
- [x] 自动连接方法：Task 1 Step 3
- [x] 页面层自动连接流程：Task 2 Step 2
- [x] 设备列表标记"上次连接"：Task 2 Step 4
- [x] 状态管理：Task 2 Step 1, Step 5

### 2. 边界情况
- [x] 无记忆设备时保持原有行为
- [x] 记忆设备未开机时持续扫描等待
- [x] 自动连接失败后继续扫描等待
- [x] 用户手动连接新设备时更新记忆（connectToDevice 中已保存）
- [x] 断开连接时不清除记忆

### 3. 代码质量
- [x] DRY：记忆功能封装在 HeartRateBle 中
- [x] YAGNI：不添加多设备记忆、清除历史等过度功能
- [x] 复用现有 shared_preferences 依赖
