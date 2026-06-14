import 'package:flutter/material.dart';

import '../../services/ble_peripheral.dart';

class BlePeripheralPage extends StatefulWidget {
  const BlePeripheralPage({super.key});

  @override
  State<BlePeripheralPage> createState() => _BlePeripheralPageState();
}

class _BlePeripheralPageState extends State<BlePeripheralPage> {
  final BlePeripheralService _service = BlePeripheralService();
  final TextEditingController _nameController = TextEditingController(text: 'ToolApp BLE');
  bool _isAdvertising = false;

  @override
  void dispose() {
    _nameController.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _toggleAdvertising() async {
    if (_isAdvertising) {
      await _service.stopAdvertising();
      if (mounted) setState(() => _isAdvertising = false);
    } else {
      final ok = await _service.startAdvertising(
        name: _nameController.text.trim(),
        serviceUuids: [],
        includeDeviceName: true,
      );
      if (mounted) setState(() => _isAdvertising = ok);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = _service.logs;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A73E8).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.bluetooth_connected, size: 18, color: Color(0xFF1A73E8)),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('BLE Peripheral', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                      SizedBox(height: 2),
                      Text('Advertise as a BLE device', style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Device name',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _toggleAdvertising,
                  icon: Icon(_isAdvertising ? Icons.stop : Icons.bluetooth_searching, size: 18),
                  label: Text(_isAdvertising ? 'STOP ADVERTISING' : 'START ADVERTISING'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isAdvertising ? const Color(0xFFE53935) : const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_isAdvertising)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2E7D32))),
                      const SizedBox(width: 6),
                      const Text('Advertising', style: TextStyle(fontSize: 12, color: Color(0xFF2E7D32), fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0))),
                ),
                child: Row(
                  children: [
                    const Text('Log', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF333333))),
                    const SizedBox(width: 8),
                    Text('(${logs.length})', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
                    const Spacer(),
                    if (logs.isNotEmpty)
                      InkWell(
                        onTap: () { _service.clearLogs(); setState(() {}); },
                        child: const Icon(Icons.delete_outline, size: 16, color: Color(0xFF888888)),
                      ),
                  ],
                ),
              ),
              if (logs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No events', style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 13))),
                )
              else
                ...List.generate(logs.length, (index) {
                  final entry = logs[logs.length - 1 - index];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFFF5F5F5))),
                    ),
                    child: Text(
                      entry.format(),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF666666), height: 1.4),
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }
}
