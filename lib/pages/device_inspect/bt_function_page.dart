import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/bluetooth_debugger.dart';
import 'bt_steering_page.dart';

class BtFunctionPage extends StatefulWidget {
  final BluetoothDebugger debugger;
  final bool showAppBar;
  final bool isNormalMode;
  final VoidCallback? onToggleMode;

  const BtFunctionPage({super.key, required this.debugger, this.showAppBar = true, this.isNormalMode = true, this.onToggleMode});

  @override
  State<BtFunctionPage> createState() => _BtFunctionPageState();
}

class _BtFunctionPageState extends State<BtFunctionPage> {
  StreamSubscription<List<BtDevice>>? _sub;
  List<BtDevice> _devices = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.debugger.devicesStream.listen((devices) {
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _isScanning = widget.debugger.isScanning;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    final loc = await Permission.location.request();
    if (!loc.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要位置权限才能扫描 BLE 设备'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    if (!scan.isGranted || !connect.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要蓝牙权限才能扫描设备'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    widget.debugger.startScan();
  }

  void _toggleScan() {
    if (widget.debugger.isScanning) {
      widget.debugger.stopScan();
    } else {
      _startScan();
    }
  }

  Future<void> _connectDevice(BtDevice device) async {
    try {
      await widget.debugger.connect(device.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已连接: ${device.name}'), backgroundColor: Colors.green.shade700, duration: const Duration(seconds: 2)),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('连接失败'),
          content: Text(e.toString()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定'))],
        ),
      );
    }
  }

  void _showDeviceSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            // listen for device list changes from parent
            final sub = widget.debugger.devicesStream.listen((_) {
              if (ctx.mounted) setSheetState(() {});
            });
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.85,
              expand: false,
              builder: (ctx, scrollController) {
                sub.cancel();
                return Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          const Text('搜索设备', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                          if (_isScanning)
                            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const Spacer(),
                          TextButton(
                            onPressed: _toggleScan,
                            child: Text(_isScanning ? '停止' : '扫描', style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _devices.isEmpty
                          ? Center(
                              child: Text(
                                _isScanning ? '正在搜索…' : '点击右上角搜索按钮',
                                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              itemCount: _devices.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                              itemBuilder: (_, index) => _buildSheetDeviceRow(_devices[index]),
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSheetDeviceRow(BtDevice device) {
    return InkWell(
      onTap: () => _connectDevice(device),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(21),
              ),
              child: const Icon(Icons.bluetooth, size: 20, color: Color(0xFF1A73E8)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(device.id, style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF999999))),
                ],
              ),
            ),
            Text('${device.rssi}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
            const SizedBox(width: 8),
            SizedBox(
              height: 30,
              child: ElevatedButton(
                onPressed: () => _connectDevice(device),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A73E8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                child: const Text('连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.debugger.isConnected;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: widget.showAppBar
          ? AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('功能模块', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF555555)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // 模式切换
          if (widget.onToggleMode != null)
            GestureDetector(
              onTap: widget.onToggleMode,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.isNormalMode ? const Color(0xFFE3F2FD) : const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: widget.isNormalMode ? const Color(0xFF1565C0) : const Color(0xFFE65100),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.isNormalMode ? Icons.person : Icons.engineering,
                      size: 14,
                      color: widget.isNormalMode ? const Color(0xFF1565C0) : const Color(0xFFE65100),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.isNormalMode ? '普通' : '专业',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: widget.isNormalMode ? const Color(0xFF1565C0) : const Color(0xFFE65100),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 搜索按钮
          IconButton(
            icon: Icon(
              _isScanning ? Icons.bluetooth_connected : Icons.bluetooth_searching,
              color: _isScanning ? Colors.green : const Color(0xFF555555),
              size: 22,
            ),
            tooltip: _isScanning ? '搜索中…' : '搜索设备',
            onPressed: _toggleScan,
          ),
          // 菜单按钮
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF555555)),
            onSelected: (v) {
              switch (v) {
                case 'scan':
                  _toggleScan();
                  break;
                case 'devices':
                  _showDeviceSheet();
                  break;
                case 'disconnect':
                  widget.debugger.disconnect();
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已断开连接'), backgroundColor: Colors.orange, duration: Duration(seconds: 2)),
                  );
                  break;
              }
            },
            itemBuilder: (_) => [
              if (!connected)
                const PopupMenuItem(value: 'scan', child: ListTile(leading: Icon(Icons.bluetooth_searching, size: 20), title: Text('搜索连接设备'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem(value: 'devices', child: ListTile(leading: Icon(Icons.list, size: 20), title: Text('查看设备列表'), contentPadding: EdgeInsets.zero)),
              if (connected)
                const PopupMenuItem(value: 'disconnect', child: ListTile(leading: Icon(Icons.link_off, size: 20), title: Text('断开连接'), contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      )
          : null,
      body: Column(
        children: [
          // 连接状态栏
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  connected ? '已连接' : '未连接',
                  style: TextStyle(fontSize: 13, color: connected ? Colors.green.shade700 : Colors.red.shade700, fontWeight: FontWeight.w500),
                ),
                if (widget.debugger.connectedDeviceId != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.debugger.connectedDeviceId!.substring(0, 8),
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF999999)),
                  ),
                ],
                const Spacer(),
                if (!connected)
                  TextButton.icon(
                    onPressed: _showDeviceSheet,
                    icon: const Icon(Icons.bluetooth_searching, size: 14),
                    label: const Text('搜索设备', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A73E8)),
                  )
                else
                  TextButton.icon(
                    onPressed: () {
                      widget.debugger.disconnect();
                      setState(() {});
                    },
                    icon: const Icon(Icons.link_off, size: 14),
                    label: const Text('断开', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
                  ),
              ],
            ),
          ),
          // 模块卡片
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _buildModuleCard(
                  icon: Icons.gamepad,
                  title: '模拟遥控',
                  desc: '通过蓝牙向设备发送方向控制指令',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => BtSteeringPage(debugger: widget.debugger)),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleCard({required IconData icon, required String title, required String desc, required VoidCallback onTap}) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF1A73E8), size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                    const SizedBox(height: 3),
                    Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
