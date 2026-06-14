import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/bluetooth_debugger.dart';

class BluetoothDeviceDetailPage extends StatefulWidget {
  final BluetoothDebugger debugger;
  final String deviceName;
  final String deviceId;

  const BluetoothDeviceDetailPage({
    super.key,
    required this.debugger,
    required this.deviceName,
    required this.deviceId,
  });

  @override
  State<BluetoothDeviceDetailPage> createState() => _BluetoothDeviceDetailPageState();
}

class _BluetoothDeviceDetailPageState extends State<BluetoothDeviceDetailPage> {
  StreamSubscription<List<BtService>>? _servicesSub;
  List<BtService> _services = [];
  bool _isConnected = true;
  bool _showChart = false;
  Timer? _rssiTimer;

  @override
  void initState() {
    super.initState();
    widget.debugger.clearRssiHistory();
    _servicesSub = widget.debugger.servicesStream.listen((services) {
      if (!mounted) return;
      setState(() {
        _services = services;
        _isConnected = widget.debugger.isConnected;
      });
      if (!widget.debugger.isConnected) Navigator.pop(context);
    });
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _servicesSub?.cancel();
    _rssiTimer?.cancel();
    super.dispose();
  }

  Future<void> _disconnect() async {
    await widget.debugger.disconnect();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _requestMtu() async {
    final controller = TextEditingController(text: '512');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请求 MTU'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'MTU (23~517)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final v = int.tryParse(controller.text);
              if (v != null && v >= 23 && v <= 517) Navigator.pop(ctx, v);
            },
            child: const Text('请求'),
          ),
        ],
      ),
    );
    if (result != null) {
      await widget.debugger.requestMtuManually(result);
      if (mounted) setState(() {});
    }
  }

  String _serviceName(String uuid) {
    const names = <String, String>{
      '00001800-0000-1000-8000-00805f9b34fb': 'Generic Access',
      '00001801-0000-1000-8000-00805f9b34fb': 'Generic Attribute',
      '0000180a-0000-1000-8000-00805f9b34fb': 'Device Information',
      '0000180f-0000-1000-8000-00805f9b34fb': 'Battery Service',
      '00001812-0000-1000-8000-00805f9b34fb': 'Human Interface Device',
      '0000180d-0000-1000-8000-00805f9b34fb': 'Heart Rate',
      '0000180e-0000-1000-8000-00805f9b34fb': 'Phone Alert Status',
    };
    return names[uuid] ?? 'Unknown Service';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.deviceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
            Text(widget.deviceId, style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF999999))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _disconnect,
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFE53935)),
            child: const Text('断开', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: _isConnected
          ? (_services.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A73E8))),
                      SizedBox(height: 12),
                      Text('正在发现服务…', style: TextStyle(color: Color(0xFF888888), fontSize: 14)),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(top: 8),
                  children: [
                    _buildConnectionInfo(),
                    if (widget.debugger.rssiHistory.isNotEmpty) _buildRssiSection(),
                    ..._services.map((s) => _buildServiceSection(s)),
                  ],
                ))
          : const Center(child: Text('设备已断开', style: TextStyle(color: Color(0xFF888888)))),
    );
  }

  Widget _buildConnectionInfo() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF2E7D32))),
          const SizedBox(width: 8),
          const Text('已连接', style: TextStyle(fontSize: 13, color: Color(0xFF2E7D32), fontWeight: FontWeight.w500)),
          const SizedBox(width: 16),
          _smallBadge('MTU: ${widget.debugger.mtu}'),
          const SizedBox(width: 6),
          _smallBadge('RSSI: ${widget.debugger.rssiHistory.isNotEmpty ? "${widget.debugger.rssiHistory.last} dBm" : "N/A"}'),
          const Spacer(),
          InkWell(
            onTap: _requestMtu,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune, size: 14, color: Color(0xFF1A73E8)),
                  SizedBox(width: 4),
                  Text('MTU', style: TextStyle(fontSize: 11, color: Color(0xFF1A73E8), fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
    );
  }

  Widget _buildRssiSection() {
    final rssiHistory = widget.debugger.rssiHistory;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _showChart = !_showChart),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.trending_up, size: 18, color: Color(0xFF1A73E8)),
                  const SizedBox(width: 8),
                  const Text('RSSI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF333333))),
                  const SizedBox(width: 8),
                  Text('${rssiHistory.last} dBm', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
                  const Spacer(),
                  Text('${rssiHistory.length} 个样本', style: const TextStyle(fontSize: 11, color: Color(0xFFBBBBBB))),
                  const SizedBox(width: 4),
                  Icon(_showChart ? Icons.expand_less : Icons.expand_more, size: 20, color: Color(0xFF888888)),
                ],
              ),
            ),
          ),
          if (_showChart)
            SizedBox(
              height: 140,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                child: _buildRssiChart(rssiHistory),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRssiChart(List<int> rssiHistory) {
    final spots = <FlSpot>[];
    for (var i = 0; i < rssiHistory.length; i++) {
      spots.add(FlSpot(i.toDouble(), rssiHistory[i].toDouble()));
    }
    final minY = (rssiHistory.reduce(min) - 10).toDouble();
    final maxY = (rssiHistory.reduce(max) + 10).toDouble();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          horizontalInterval: max(10, ((maxY - minY) / 4).roundToDouble()),
          getDrawingHorizontalLine: (value) => FlLine(color: Colors.grey.withValues(alpha: 0.15), strokeWidth: 1),
          getDrawingVerticalLine: (_) => const FlLine(color: Colors.transparent),
        ),
        titlesData: const FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: const Color(0xFF1A73E8),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true, color: const Color(0xFF1A73E8).withValues(alpha: 0.06)),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) => touchedSpots.map((spot) =>
              LineTooltipItem('${spot.y.toInt()} dBm', const TextStyle(color: Colors.white, fontSize: 11))
            ).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildServiceSection(BtService service) {
    final si = _serviceName(service.uuid);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
            child: Row(
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: const Color(0xFF1A73E8).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.device_hub, size: 14, color: Color(0xFF1A73E8)),
                ),
                const SizedBox(width: 10),
                Text(_shortUuid(service.uuid), style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                const SizedBox(width: 8),
                Text(si, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
              ],
            ),
          ),
          ...service.characteristics.map((c) => _buildCharacteristicRow(service.uuid, c)),
        ],
      ),
    );
  }

  Widget _buildCharacteristicRow(String serviceUuid, BtCharacteristic ch) {
    final props = <String>[];
    if (ch.isReadable) props.add('R');
    if (ch.isWritableWithResponse) props.add('W');
    if (ch.isWritableWithoutResponse) props.add('WR');
    if (ch.isNotifiable) props.add('N');
    if (ch.isIndicatable) props.add('I');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF5F5F5)))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(color: const Color(0xFFFFA000).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.code, size: 12, color: Color(0xFFFFA000)),
              ),
              const SizedBox(width: 8),
              Text(_shortUuid(ch.uuid), style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w500, color: Color(0xFF333333))),
              const SizedBox(width: 8),
              ...props.map((p) => Container(
                margin: const EdgeInsets.only(right: 3),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: _propColor(p).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3)),
                child: Text(p, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: _propColor(p))),
              )),
              if (ch.isNotifying)
                Container(margin: const EdgeInsets.only(left: 4), width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF2E7D32))),
              const Spacer(),
              if (ch.value != null) Text('${ch.value!.length}B', style: const TextStyle(fontSize: 10, color: Color(0xFFBBBBBB))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (ch.isReadable) _nrfAction(Icons.play_arrow, '读取', () => _doRead(serviceUuid, ch)),
              if (ch.isWritableWithResponse || ch.isWritableWithoutResponse) ...[
                const SizedBox(width: 4),
                _nrfAction(Icons.edit, '写入', () => _showWriteDialog(serviceUuid, ch)),
              ],
              if (ch.isNotifiable || ch.isIndicatable) ...[
                const SizedBox(width: 4),
                _nrfAction(ch.isNotifying ? Icons.notifications_off : Icons.notifications, ch.isNotifying ? '取消通知' : '通知', () => _toggleNotify(serviceUuid, ch)),
              ],
            ],
          ),
          if (ch.value != null) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(4)),
              child: SelectableText(
                ch.value!.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' '),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF555555), height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _nrfAction(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFF1A73E8).withValues(alpha: 0.06), borderRadius: BorderRadius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(0xFF1A73E8)),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF1A73E8))),
          ],
        ),
      ),
    );
  }

  String _shortUuid(String uuid) {
    if (uuid.length == 36 && uuid.startsWith('0000') && uuid.endsWith('-0000-1000-8000-00805f9b34fb')) {
      return '0x${uuid.substring(4, 8)}';
    }
    return uuid;
  }

  Color _propColor(String p) {
    switch (p) {
      case 'R': return const Color(0xFF1A73E8);
      case 'W': case 'WR': return const Color(0xFFE65100);
      case 'N': return const Color(0xFF2E7D32);
      case 'I': return const Color(0xFF6A1B9A);
      default: return Colors.grey;
    }
  }

  Future<void> _doRead(String serviceUuid, BtCharacteristic ch) async {
    final value = await widget.debugger.readCharacteristic(serviceUuid, ch.uuid);
    if (value != null && mounted) {
      setState(() => ch.value = value);
      _showHexDialog('读取值', value);
    }
  }

  Future<void> _showWriteDialog(String serviceUuid, BtCharacteristic ch) async {
    final controller = TextEditingController(text: '00');
    String format = 'HEX';
    final hasResponse = ch.isWritableWithResponse;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('写入值'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: format == 'HEX' ? 'HEX (e.g. 01 02 FF)' : '文本',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'HEX', label: Text('HEX', style: TextStyle(fontSize: 12))),
                  ButtonSegment(value: 'UTF-8', label: Text('文本', style: TextStyle(fontSize: 12))),
                ],
                selected: {format},
                onSelectionChanged: (v) => setDialogState(() => format = v.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {'text': controller.text, 'format': format, 'withResponse': hasResponse}),
              child: const Text('写入'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    List<int> bytes;
    if (result['format'] == 'HEX') {
      try {
        bytes = (result['text'] as String)
            .split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty)
            .map((s) => int.parse(s, radix: 16)).toList();
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('HEX 格式错误')));
        return;
      }
    } else {
      bytes = (result['text'] as String).codeUnits.toList();
    }

    final ok = result['withResponse'] as bool
        ? await widget.debugger.writeCharacteristic(serviceUuid, ch.uuid, bytes)
        : await widget.debugger.writeWithoutResponse(serviceUuid, ch.uuid, bytes);
    if (ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('写入成功')));
  }

  Future<void> _toggleNotify(String serviceUuid, BtCharacteristic ch) async {
    if (ch.isNotifying) {
      await widget.debugger.unsubscribeFromCharacteristic();
      setState(() => ch.isNotifying = false);
    } else {
      final ok = await widget.debugger.subscribeToCharacteristic(serviceUuid, ch.uuid, onData: (data) {
        if (mounted) setState(() => ch.value = data);
      });
      if (ok) setState(() => ch.isNotifying = true);
    }
  }

  void _showHexDialog(String title, List<int> data) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(4)),
              child: SelectableText(
                data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' '),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
              ),
            ),
            const SizedBox(height: 8),
            Text('UTF-8: ${utf8.decode(data, allowMalformed: true)}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 4),
            Text('十进制: ${data.join(' ')}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')));
              Navigator.pop(ctx);
            },
            child: const Text('复制 HEX'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}
