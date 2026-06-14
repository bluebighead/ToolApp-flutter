import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/bluetooth_debugger.dart';
import 'ble_peripheral_page.dart';
import 'bluetooth_device_detail_page.dart';

class BluetoothDebugPage extends StatefulWidget {
  const BluetoothDebugPage({super.key});

  @override
  State<BluetoothDebugPage> createState() => _BluetoothDebugPageState();
}

class _BluetoothDebugPageState extends State<BluetoothDebugPage>
    with SingleTickerProviderStateMixin {
  final BluetoothDebugger _debugger = BluetoothDebugger();

  late TabController _tabController;

  StreamSubscription<List<BtDevice>>? _devicesSub;

  List<BtDevice> _devices = [];
  String _searchQuery = '';
  bool _isScanning = false;
  int _deviceCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _devicesSub = _debugger.devicesStream.listen((devices) {
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _isScanning = _debugger.isScanning;
        _deviceCount = devices.length;
      });
      final err = _debugger.scanError;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), backgroundColor: Colors.red.shade700, duration: const Duration(seconds: 4)),
        );
      }
    });
    _startScanWithPermissions();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _tabController.dispose();
    _debugger.dispose();
    super.dispose();
  }

  Future<void> _startScanWithPermissions() async {
    final loc = await Permission.location.request();
    if (!loc.isGranted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('需要位置权限才能扫描 BLE 设备')));
      return;
    }
    final bluetoothScan = await Permission.bluetoothScan.request();
    final bluetoothConnect = await Permission.bluetoothConnect.request();
    if (!bluetoothScan.isGranted || !bluetoothConnect.isGranted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('需要蓝牙权限才能扫描 BLE 设备')));
      return;
    }
    _debugger.startScan();
  }

  Future<void> _toggleScan() async {
    if (_debugger.isScanning) {
      _debugger.stopScan();
      return;
    }
    await _startScanWithPermissions();
  }

  Future<void> _connectDevice(BtDevice device) async {
    try {
      await _debugger.connect(device.id);
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BluetoothDeviceDetailPage(
              debugger: _debugger,
              deviceName: device.name,
              deviceId: device.id,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('连接失败'),
            content: Text('$e'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定'))],
          ),
        );
      }
    }
  }

  Future<void> _exportLogs() async {
    final logs = _debugger.logs;
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('暂无日志可导出')));
      return;
    }
    try {
      final text = logs.map((e) => e.format()).join('\n');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ble_log_${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(text);
      await Share.shareXFiles([XFile(file.path)], text: 'BLE 调试器日志');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  List<BtDevice> get _filteredDevices {
    if (_searchQuery.isEmpty) return _devices;
    final q = _searchQuery.toLowerCase();
    return _devices.where((d) =>
        d.name.toLowerCase().contains(q) || d.id.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text('蓝牙调试器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF1A73E8),
              labelColor: const Color(0xFF1A73E8),
              unselectedLabelColor: const Color(0xFF888888),
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              tabs: [
                Tab(text: '扫描 ($_deviceCount)'),
                const Tab(text: '外设'),
                Tab(text: '日志 (${_debugger.logs.length})'),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, size: 20, color: Color(0xFF555555)),
            tooltip: '导出日志',
            onPressed: _exportLogs,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildScanTab(),
          const BlePeripheralPage(),
          _buildLogTab(),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '按名称或 MAC 过滤…',
                    prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF888888)),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF5F5F5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 36,
                child: ElevatedButton.icon(
                  onPressed: _toggleScan,
                  icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching, size: 16),
                  label: Text(_isScanning ? '停止' : '扫描'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isScanning ? const Color(0xFFE53935) : const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_isScanning)
          Container(
            color: const Color(0xFF1A73E8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white)),
                const SizedBox(width: 8),
                Text(
                  '扫描中... $_deviceCount 个设备',
                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w400),
                ),
              ],
            ),
          ),
        Expanded(
          child: _filteredDevices.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bluetooth_searching, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        _isScanning ? '等待设备出现…' : '点击扫描开始',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  itemCount: _filteredDevices.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) => _buildDeviceRow(_filteredDevices[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildDeviceRow(BtDevice device) {
    final rssi = device.rssi;
    final strength = rssi >= -50 ? 4 : rssi >= -70 ? 3 : rssi >= -85 ? 2 : 1;
    final hasBeacon = device.beaconType != BtBeaconType.none;

    return InkWell(
      onTap: () => _connectDevice(device),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        color: Colors.white,
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                hasBeacon ? Icons.wifi_tethering : Icons.bluetooth,
                size: 22, color: const Color(0xFF1A73E8),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15, color: Color(0xFF333333)),
                        ),
                      ),
                      if (hasBeacon)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: device.beaconType == BtBeaconType.iBeacon
                                ? Colors.blue.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            device.beaconType == BtBeaconType.iBeacon ? 'iBeacon' : 'Eddystone',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                                color: device.beaconType == BtBeaconType.iBeacon ? Colors.blue.shade700 : Colors.orange.shade700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    device.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF999999)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                Text('$rssi', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                    color: rssi >= -70 ? const Color(0xFF2E7D32) : rssi >= -85 ? const Color(0xFFE65100) : const Color(0xFFC62828))),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(4, (i) => Icon(
                    Icons.signal_cellular_alt,
                    size: 10,
                    color: i < strength ? const Color(0xFF1A73E8) : const Color(0xFFE0E0E0),
                  )),
                ),
              ],
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: ElevatedButton(
                onPressed: () => _connectDevice(device),
                style: ElevatedButton.styleFrom(
                  backgroundColor: device.isConnected ? Colors.green : const Color(0xFF1A73E8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                child: Text(device.isConnected ? '打开' : '连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogTab() {
    final logs = _debugger.logs;
    if (logs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('暂无日志', style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Text('${logs.length} 条', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _exportLogs,
                icon: const Icon(Icons.share, size: 14),
                label: const Text('导出', style: TextStyle(fontSize: 11)),
              ),
              TextButton.icon(
                onPressed: () { _debugger.clearLogs(); setState(() {}); },
                icon: const Icon(Icons.delete_outline, size: 14),
                label: const Text('清空', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final entry = logs[logs.length - 1 - index];
              return _buildLogItem(entry);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLogItem(BtLogEntry entry) {
    Color levelColor;
    switch (entry.level) {
      case 'ERROR': levelColor = Colors.red.shade700; break;
      case 'WARN': levelColor = Colors.orange.shade700; break;
      case 'NOTIFY': levelColor = Colors.green.shade700; break;
      case 'DEBUG': levelColor = Colors.grey; break;
      default: levelColor = Colors.blue.shade700;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        onTap: () => Clipboard.setData(ClipboardData(text: entry.format())),
        child: Text(
          entry.format(),
          style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: levelColor, height: 1.4),
        ),
      ),
    );
  }
}
