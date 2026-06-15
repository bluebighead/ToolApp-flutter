import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/bluetooth_debugger.dart';
import 'bt_function_page.dart';

class NormalBtPage extends StatefulWidget {
  final BluetoothDebugger debugger;

  const NormalBtPage({super.key, required this.debugger});

  @override
  State<NormalBtPage> createState() => _NormalBtPageState();
}

class _NormalBtPageState extends State<NormalBtPage> {
  List<BtDevice> _devices = [];
  bool _isScanning = false;
  bool _isConnecting = false;

  StreamSubscription<List<BtDevice>>? _sub;

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

  Future<void> _connectDevice(BtDevice device) async {
    setState(() => _isConnecting = true);
    try {
      await widget.debugger.connect(device.id);
      if (!mounted) return;
      // 连接成功后显示已连接提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已连接: ${device.name}'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
      // 跳转到功能模块页面
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BtFunctionPage(debugger: widget.debugger)),
      );
    } catch (e) {
      if (!mounted) return;
      _showPairingDialog(e.toString());
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _showPairingDialog(String error) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('连接失败'),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  int _rssiBars(int rssi) {
    if (rssi >= -50) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -85) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 搜索按钮区域
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: _isScanning ? () => widget.debugger.stopScan() : _startScan,
                  icon: Icon(
                    _isScanning ? Icons.stop : Icons.bluetooth_searching,
                    size: 20,
                  ),
                  label: Text(
                    _isScanning ? '停止搜索' : '开始搜索设备',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isScanning ? const Color(0xFFE53935) : const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              if (_isScanning) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text(
                      '搜索中… 已发现 ${_devices.length} 个设备',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        // 设备列表（折叠栏）
        Expanded(
          child: _devices.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bluetooth, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        _isScanning ? '等待设备回应…' : '点击上方按钮搜索附近蓝牙设备',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text(
                        '搜索到 ${_devices.length} 个设备',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                    for (final device in _devices)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: ExpansionTile(
                          key: ValueKey(device.id),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(Icons.bluetooth, size: 20, color: Color(0xFF1A73E8)),
                          ),
                          title: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            device.id,
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF999999)),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildSignalIcon(device.rssi),
                              const SizedBox(width: 8),
                              Icon(
                                device.isConnected ? Icons.link : Icons.link_off,
                                size: 16,
                                color: device.isConnected ? Colors.green : Colors.grey.shade400,
                              ),
                            ],
                          ),
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.signal_cellular_alt, size: 14, color: Color(0xFF888888)),
                                const SizedBox(width: 4),
                                Text('信号强度: ${device.rssi} dBm', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _isConnecting ? null : () => _connectDevice(device),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1A73E8),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                child: _isConnecting
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Text('配对连接', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSignalIcon(int rssi) {
    final bars = _rssiBars(rssi);
    return Row(
      children: List.generate(4, (i) {
        return Container(
          width: 3,
          height: 4 + i * 3,
          margin: const EdgeInsets.only(left: 1.5),
          decoration: BoxDecoration(
            color: i < bars ? const Color(0xFF1A73E8) : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}
