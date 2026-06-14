// NFC读写器工具
// v1.53.0+ 新增
// 功能：读取NFC标签信息、写入NDEF数据、MIFARE扇区认证与块读写
// 使用 flutter_nfc_kit 实现跨平台NFC通信
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart';

class _MifareSectorState {
  bool authenticated;
  String? keyA;
  String? keyB;
  _MifareSectorState({this.authenticated = false, this.keyA, this.keyB});
}

class NfcReaderPage extends StatefulWidget {
  const NfcReaderPage({super.key});

  @override
  State<NfcReaderPage> createState() => _NfcReaderPageState();
}

class _NfcReaderPageState extends State<NfcReaderPage>
    with WidgetsBindingObserver {
  NFCAvailability _availability = NFCAvailability.not_supported;
  bool _isPolling = false;
  NFCTag? _currentTag;
  List<NDEFRecord>? _ndefRecords;
  bool _isLoadingNdef = false;
  String _statusMessage = '';
  bool _isWriting = false;

  // MIFARE state
  final Map<int, _MifareSectorState> _mifareSectors = {};
  int _selectedSector = 0;
  int _selectedBlock = 0;
  String _lastBlockHex = '';
  final _keyAController = TextEditingController(text: 'FFFFFFFFFFFF');
  final _keyBController = TextEditingController(text: 'FFFFFFFFFFFF');
  final _blockWriteController = TextEditingController();
  bool _mifareAuthInProgress = false;
  String _mifareStatusMsg = '';

  // Track if MIFARE init was done
  bool _mifareInitialized = false;

  // Clone state
  Map<int, String> _cloneData = {};
  String? _cloneFilePath;
  bool _isCloneReading = false;
  bool _isCloneWriting = false;
  String _cloneStatusMsg = '';
  bool _cloneWritePending = false;
  Map<int, String>? _pendingCloneData;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNfcStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finishSession();
    _keyAController.dispose();
    _keyBController.dispose();
    _blockWriteController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNfcStatus();
    }
  }

  bool get _isMifare => _currentTag?.type == NFCTagType.mifare_classic ||
      _currentTag?.type == NFCTagType.mifare_ultralight ||
      _currentTag?.type == NFCTagType.mifare_desfire ||
      _currentTag?.type == NFCTagType.mifare_plus;

  int get _sectorCount {
    if (_currentTag?.mifareInfo != null && _currentTag!.mifareInfo!.sectorCount != null) {
      return _currentTag!.mifareInfo!.sectorCount!;
    }
    if (_currentTag?.mifareInfo != null) {
      final blocks = _currentTag!.mifareInfo!.blockCount;
      if (blocks > 0) return (blocks / 4).ceil();
    }
    return 16;
  }

  int get _blocksPerSector {
    if (_currentTag?.mifareInfo != null && _currentTag!.mifareInfo!.blockCount > 0) {
      final sc = _sectorCount;
      if (sc > 0) return (_currentTag!.mifareInfo!.blockCount / sc).ceil();
    }
    return 4;
  }

  int blockIndexFor(int sector, int block) => sector * _blocksPerSector + block;

  bool _isSectorTrailer(int sector, int block) =>
      block == _blocksPerSector - 1;

  void _initMifareState() {
    if (_mifareInitialized) return;
    _mifareSectors.clear();
    _selectedSector = 0;
    _selectedBlock = 0;
    _lastBlockHex = '';
    _mifareStatusMsg = '';
    _mifareInitialized = true;
  }

  Future<void> _checkNfcStatus() async {
    setState(() => _statusMessage = '正在检查NFC状态…');
    try {
      final avail = await FlutterNfcKit.nfcAvailability;
      if (!mounted) return;
      setState(() {
        _availability = avail;
        _statusMessage = switch (avail) {
          NFCAvailability.available => '请将NFC卡放在感应区',
          NFCAvailability.disabled => 'NFC功能未开启，请在系统设置中打开NFC开关',
          NFCAvailability.not_supported => '该设备不支持NFC功能',
        };
      });
      if (avail == NFCAvailability.available) _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availability = NFCAvailability.not_supported;
        _statusMessage = 'NFC检测失败';
      });
    }
  }

  Future<void> _startPolling() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      final tag = await FlutterNfcKit.poll();
      if (!mounted) return;
      await _onTagDiscovered(tag);
    } catch (_) {
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _finishSession() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  Future<void> _onTagDiscovered(NFCTag tag) async {
    // Clone write mode
    if (_cloneWritePending && _pendingCloneData != null) {
      await _writeCloneToCard(tag);
      return;
    }

    _mifareInitialized = false;
    setState(() {
      _currentTag = tag;
      _isLoadingNdef = true;
    });
    if (_isMifare) _initMifareState();

    // Load NDEF in background to avoid blocking UI
    try {
      final records = await FlutterNfcKit.readNDEFRecords();
      if (mounted) {
        setState(() {
          _ndefRecords = records;
          _isLoadingNdef = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _ndefRecords = null;
          _isLoadingNdef = false;
        });
      }
    }
  }

  Future<void> _returnToWaiting() async {
    await _finishSession();
    if (!mounted) return;
    setState(() {
      _currentTag = null;
      _ndefRecords = null;
      _statusMessage = '请将NFC卡放在感应区';
      _isLoadingNdef = false;
      _cloneWritePending = false;
    });
    _startPolling();
  }

  // --- NDEF operations ---

  Future<void> _performWrite(List<NDEFRecord> records) async {
    setState(() => _isWriting = true);
    try {
      await FlutterNfcKit.writeNDEFRecords(records);
      if (mounted) {
        final updated = await FlutterNfcKit.readNDEFRecords();
        if (mounted) setState(() => _ndefRecords = updated);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写入失败: $e')),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _isWriting = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写入成功'), backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _performClear() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清除'),
        content: const Text('确定要清除此NFC卡上的所有NDEF数据吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认清除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isWriting = true);
    try {
      await FlutterNfcKit.writeNDEFRecords([]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('NDEF数据已清除'), backgroundColor: Colors.orange),
        );
        setState(() => _ndefRecords = []);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isWriting = false);
    }
  }

  // --- MIFARE operations ---

  Future<void> _authenticateSector(int sector) async {
    setState(() {
      _mifareAuthInProgress = true;
      _mifareStatusMsg = '正在认证扇区 $sector …';
    });

    final keyA = _keyAController.text.trim().replaceAll(' ', '');
    final keyB = _keyBController.text.trim().replaceAll(' ', '');

    try {
      final ok = await FlutterNfcKit.authenticateSector(
        sector,
        keyA: keyA,
        keyB: keyB,
      );
      if (mounted) {
        if (ok) {
          setState(() {
            _mifareSectors[sector] = _MifareSectorState(
              authenticated: true,
              keyA: keyA,
              keyB: keyB,
            );
            _mifareStatusMsg = '扇区 $sector 认证成功';
          });
        } else {
          setState(() {
            _mifareStatusMsg = '扇区 $sector 认证失败 - 密钥错误';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _mifareStatusMsg = '认证异常: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _mifareAuthInProgress = false);
    }
  }

  Future<void> _readBlock(int sector, int block) async {
    final idx = blockIndexFor(sector, block);
    setState(() => _mifareStatusMsg = '正在读取块 $idx …');

    try {
      final data = await FlutterNfcKit.readBlock(idx);
      if (mounted) {
        final hex = _bytesToHex(data);
        setState(() {
          _selectedSector = sector;
          _selectedBlock = block;
          _lastBlockHex = hex;
          _blockWriteController.text = hex;
          _mifareStatusMsg = '读取成功 - 块 $idx';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _mifareStatusMsg = '读取失败: $e';
        });
      }
    }
  }

  Future<void> _readSector(int sector) async {
    setState(() => _mifareStatusMsg = '正在读取扇区 $sector …');
    try {
      final data = await FlutterNfcKit.readSector(sector);
      if (mounted) {
        final hex = _bytesToHex(data);
        setState(() {
          _lastBlockHex = hex;
          _blockWriteController.text = hex;
          _mifareStatusMsg = '扇区 $sector 读取成功 (${data.length} 字节)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _mifareStatusMsg = '读取扇区失败: $e';
        });
      }
    }
  }

  Future<void> _writeBlock(int sector, int block) async {
    final idx = blockIndexFor(sector, block);
    final hex = _blockWriteController.text.trim().replaceAll(' ', '');

    if (hex.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入要写入的十六进制数据')),
      );
      return;
    }
    if (hex.length % 2 != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('数据长度必须为偶数（十六进制）')),
      );
      return;
    }

    setState(() => _mifareStatusMsg = '正在写入块 $idx …');
    try {
      await FlutterNfcKit.writeBlock(idx, hex);
      if (mounted) {
        setState(() => _mifareStatusMsg = '块 $idx 写入成功');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('写入成功'), backgroundColor: Colors.green),
        );
        _readBlock(sector, block);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _mifareStatusMsg = '写入失败: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写入失败: $e')),
        );
      }
    }
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  Uint8List _hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '').replaceAll('\n', '');
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  // --- Clone operations ---

  Future<void> _readAllSectors() async {
    if (!_isMifare) {
      setState(() => _cloneStatusMsg = '仅MIFARE卡支持全卡读取');
      return;
    }
    setState(() {
      _isCloneReading = true;
      _cloneStatusMsg = '正在读取全卡数据…请保持卡片靠近';
      _cloneData = {};
    });

    final keyA = _keyAController.text.trim().replaceAll(' ', '');
    final keyB = _keyBController.text.trim().replaceAll(' ', '');
    final data = <int, String>{};
    int success = 0, fail = 0;

    for (var sector = 0; sector < _sectorCount; sector++) {
      final state = _mifareSectors[sector];
      final alreadyAuth = state?.authenticated == true;

      // Try to authenticate if not yet authenticated
      if (!alreadyAuth) {
        try {
          final ok = await FlutterNfcKit.authenticateSector(sector, keyA: keyA, keyB: keyB);
          if (ok && mounted) {
            _mifareSectors[sector] = _MifareSectorState(authenticated: true, keyA: keyA, keyB: keyB);
          }
        } catch (_) {
          // auth failed, skip this sector
        }
      }

      final authNow = _mifareSectors[sector]?.authenticated == true;
      if (!authNow) {
        fail++;
        if (mounted) setState(() => _cloneStatusMsg = '扇区$sector 认证失败，已跳过');
        continue;
      }

      try {
        final bytes = await FlutterNfcKit.readSector(sector);
        data[sector] = _bytesToHex(bytes).replaceAll(' ', '');
        success++;
      } catch (e) {
        fail++;
      }
      if (mounted) {
        setState(() => _cloneStatusMsg = '读取中… 扇区$sector 成功($success) 失败($fail)');
      }
    }

    if (mounted) {
      setState(() {
        _cloneData = data;
        _isCloneReading = false;
        _cloneStatusMsg = data.isEmpty
            ? '全卡读取失败 — 请检查认证密钥是否正确'
            : '读取完成 — 成功 $success 个扇区，$fail 个扇区失败';
      });
    }
  }

  Future<void> _saveCloneData() async {
    if (_cloneData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无克隆数据，请先读取')),
      );
      return;
    }

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dir == null) return;

    final uid = _currentTag?.id ?? 'unknown';
    final path = '$dir\\nfc_clone_$uid.json';

    final json = jsonEncode({
      'uid': uid,
      'tagType': _currentTag?.type.name,
      'sectorCount': _sectorCount,
      'blocksPerSector': _blocksPerSector,
      'sectors': _cloneData,
      'createdAt': DateTime.now().toIso8601String(),
    });

    try {
      await File(path).writeAsString(json);
      setState(() => _cloneFilePath = path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到: $path'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  Future<void> _loadCloneData() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: '选择克隆数据文件',
    );
    if (result == null || result.files.isEmpty) return;

    final file = File(result.files.single.path!);
    if (!await file.exists()) return;

    try {
      final jsonStr = await file.readAsString();
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final sectors = (json['sectors'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(int.parse(k), v as String),
      );

      setState(() {
        _cloneData = sectors;
        _cloneFilePath = file.path;
        _cloneStatusMsg = '已加载 ${sectors.length} 个扇区数据 (UID: ${json['uid'] ?? '未知'})';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  Future<void> _writeCloneToCard(NFCTag tag) async {
    if (_pendingCloneData == null || _pendingCloneData!.isEmpty) {
      setState(() {
        _cloneWritePending = false;
        _cloneStatusMsg = '无待写入数据';
      });
      return;
    }

    setState(() {
      _isCloneWriting = true;
      _cloneStatusMsg = '正在写入目标卡…请保持卡片靠近';
    });

    final data = _pendingCloneData!;
    int success = 0, fail = 0;
    final sectors = data.keys.toList()..sort();

    for (final sector in sectors) {
      final hex = data[sector]!;
      try {
        if (sector == 0) {
          // Write block 0 separately (UID block - UID+manufacturer data)
          // Skip block 0 bytes (first 4 are UID which can't be changed on standard cards)
          // Write blocks 1,2,3 of sector 0
          final allBytes = _hexToBytes(hex);
          final blockSize = 16;
          for (var b = 1; b < 4; b++) {
            final start = b * blockSize;
            if (start + blockSize <= allBytes.length) {
              final blockHex = allBytes
                  .sublist(start, start + blockSize)
                  .map((x) => x.toRadixString(16).padLeft(2, '0'))
                  .join();
              await FlutterNfcKit.writeBlock(b, blockHex);
            }
          }
        } else {
          // Write entire sector via readSector/writeBlock approach
          final allBytes = _hexToBytes(hex);
          final blockSize = 16;
          for (var b = 0; b < 4; b++) {
            final start = b * blockSize;
            if (start + blockSize <= allBytes.length) {
              final blockHex = allBytes
                  .sublist(start, start + blockSize)
                  .map((x) => x.toRadixString(16).padLeft(2, '0'))
                  .join();
              await FlutterNfcKit.writeBlock(
                sector * _blocksPerSector + b,
                blockHex,
              );
            }
          }
        }
        success++;
      } catch (e) {
        fail++;
      }
      if (mounted) {
        setState(() => _cloneStatusMsg = '写入中… 扇区$sector 成功($success) 失败($fail)');
      }
    }

    setState(() {
      _isCloneWriting = false;
      _cloneWritePending = false;
      _pendingCloneData = null;
      _cloneStatusMsg = data.isEmpty
          ? '写入完成 — 成功 $success 个扇区，$fail 个失败'
          : '写入完成 — 成功 $success 个扇区，$fail 个失败';
    });

    await _finishSession();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('克隆写入完成 — 成功 $success 个，失败 $fail 个'),
          backgroundColor: fail > 0 ? Colors.orange : Colors.green,
        ),
      );
      _startPolling();
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC读写器'),
        actions: [
          if (_currentTag != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('已连接',
                          style: TextStyle(
                              fontSize: 12, color: Colors.green.shade700)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isWriting) return _buildWritingOverlay();
    if (_currentTag != null) return _buildDetailView();
    return _buildWaitingView();
  }

  Widget _buildWaitingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_availability == NFCAvailability.not_supported)
              _buildUnsupported()
            else ...[
              _buildNfcAnimation(),
              const SizedBox(height: 32),
              Text(_statusMessage,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Text('将NFC卡靠近手机背部感应区域',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              if (_availability == NFCAvailability.disabled) ...[
                const SizedBox(height: 16),
                _buildHintCard(
                  Icons.warning_amber,
                  '请在系统设置中开启NFC功能后重试',
                  Colors.orange,
                ),
              ],
              const SizedBox(height: 24),
              _buildHintCard(
                Icons.info_outline,
                '支持读取NFC标签基本信息、NDEF数据记录。可对NDEF标签进行文本和链接写入。MIFARE Classic卡支持扇区认证和块读写。',
                Colors.blue,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupported() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.nfc, size: 100, color: Colors.grey[400]),
        const SizedBox(height: 24),
        Text('该设备不支持NFC功能',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.grey[700])),
        const SizedBox(height: 16),
        _buildHintCard(
          Icons.warning_amber,
          '当前设备未检测到NFC硬件支持，无法使用NFC读写功能。\n\n'
          '请确认您的设备满足以下条件：\n'
          '• 支持NFC功能的Android设备\n'
          '• 系统版本 Android 5.0 (API 21) 及以上\n'
          '• 已在系统设置中开启NFC开关',
          Colors.orange,
        ),
      ],
    );
  }

  Widget _buildNfcAnimation() {
    return SizedBox(
      width: 180,
      height: 180,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 2000),
            builder: (context, value, child) {
              return Container(
                width: 120 + value * 60,
                height: 120 + value * 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.blue.withValues(alpha: (1.0 - value) * 0.5),
                    width: 2,
                  ),
                ),
              );
            },
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 2000),
            builder: (context, value, child) {
              return Container(
                width: 100 + value * 40,
                height: 100 + value * 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.blue.withValues(alpha: (1.0 - value) * 0.3),
                    width: 1.5,
                  ),
                ),
              );
            },
          ),
          Icon(Icons.nfc, size: 72, color: Colors.blue[400]),
        ],
      ),
    );
  }

  Widget _buildWritingOverlay() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 24),
          const Text('正在执行操作…',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text('请保持NFC卡靠近手机，不要移开',
              style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        ],
      ),
    );
  }

  // --- Detail View ---

  Widget _buildDetailView() {
    final isMifare = _isMifare;
    final baseCount = isMifare && _currentTag!.ndefAvailable == true ? 3 : 2;
    final tabCount = baseCount + 1; // +1 for clone tab
    return DefaultTabController(
      length: tabCount,
      child: Column(
        children: [
          _buildConnectedBar(),
          TabBar(
            tabs: [
              const Tab(text: '读取识别', icon: Icon(Icons.download_rounded)),
              const Tab(text: '写入修改', icon: Icon(Icons.upload_rounded)),
              if (isMifare && baseCount == 3)
                const Tab(text: 'MIFARE', icon: Icon(Icons.memory)),
              const Tab(text: '克隆卡', icon: Icon(Icons.copy_all_rounded)),
            ],
            labelColor: Colors.blue[800],
            unselectedLabelColor: Colors.grey[600],
            indicatorColor: Colors.blue,
            indicatorSize: TabBarIndicatorSize.tab,
            isScrollable: baseCount > 3,
          ),
          Expanded(
            child: TabBarView(children: [
                    _buildReadTab(),
                    _buildWriteTab(),
                    if (isMifare && baseCount == 3) _buildMifareTab(),
                    _buildCloneTab(),
                  ]),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedBar() {
    final tag = _currentTag!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border(bottom: BorderSide(color: Colors.green.shade100)),
      ),
      child: Row(
        children: [
          Icon(Icons.nfc, size: 20, color: Colors.green[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已识别 · ${tag.id.length > 8 ? tag.id.substring(0, 8) : tag.id}'
              '${_isMifare ? " · MIFARE" : ""}',
              style: TextStyle(fontSize: 12, color: Colors.green[700]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: _returnToWaiting,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 2),
                  Text('断开',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const Map<String, String> _fieldExplanations = {
    '标签UID': '每张NFC卡唯一的标识符，类似身份证号。出厂即固化无法更改。\n\n'
        '读取时以十六进制显示，长度为4~7字节不等。MIFARE Classic UID通常为4字节。\n\n'
        '可用作卡片识别和计数，但部分卡支持UID改写（中国魔改卡）。',
    '标签类型': 'NFC卡所属的技术标准类型。\n\n'
        '• MIFARE Classic — 最常见，广泛用于门禁、公交、校园卡\n'
        '• MIFARE Ultralight — 低成本标签，用于门票、海报\n'
        '• MIFARE DESFire — 高安全型号，支持加密通信\n'
        '• ISO 15693 — 长距离读取，用于图书馆、资产管理\n'
        '• FeliCa — 日本标准，用于交通卡、电子钱包\n\n'
        '不同类型支持的命令集和存储结构不同。',
    '通信标准': '标签与读卡器之间的底层通信协议。\n\n'
        '• ISO 14443-4 (Type A/B) — 最常用的非接触式智能卡标准\n'
        '• ISO 15693 — 远距离Vicinity卡标准\n'
        '• ISO 18092 — NFC-F (FeliCa) 标准\n\n'
        '决定了读卡器与标签的交互方式，通常与卡类型对应。',
    'NDEF可写': '是否允许修改NDEF（NFC Data Exchange Format）数据。\n\n'
        '• 是 — 可以写入新的NDEF记录\n'
        '• 否 — 标签已被永久锁定为只读，数据不可更改（不可逆操作）\n\n'
        '即使NDEF只读，MIFARE扇区数据仍可能通过扇区认证+块写入修改。',
    '支持NDEF': '标签是否支持NDEF（NFC数据交换格式）。\n\n'
        'NDEF是NFC论坛标准化的数据格式，支持后手机可直接读写文本、链接等。\n\n'
        'MIFARE Classic通常需要在扇区0数据区内写入NDEF兼容头才能被识别为NDEF卡。\n'
        '如果显示不支持NDEF，可尝试使用MIFARE扇区读写工具操作底层块数据。',
    'NDEF容量': '标签可用于存储NDEF数据的最大字节数。\n\n'
        '• MIFARE Ultralight: 48~144字节\n'
        '• MIFARE Classic 1K: 约716字节（NDEF格式占用部分开销）\n'
        '• 实际可用容量受标签类型和NDEF格式头影响。',
    '可设为只读': '标签是否可以被永久锁定为只读状态。\n\n'
        '⚠ 此操作不可逆！锁定后：\n'
        '• NDEF数据无法再修改或删除\n'
        '• 扇区尾部块中的访问位可能被锁定\n'
        '• 卡片变为只读状态，适合数据分发场景',
    'MIFARE类型': 'MIFARE卡的子型号。\n\n'
        '• Classic 1K — 16扇区×4块×16字节=1024字节，最常见\n'
        '• Classic 4K — 40扇区，4096字节\n'
        '• Ultralight — 低成本，64~144字节\n'
        '• DESFire — 高安全，支持AES加密\n'
        '• Plus — Classic的升级版，兼容Classic',
    'MIFARE容量': 'MIFARE卡的总存储容量（字节）。\n\n'
        '注意：总容量中包含扇区尾部块（存储密钥和访问位），实际可用于用户数据的空间小于总容量。\n\n'
        '例如 Classic 1K 总容量1024字节，实际数据空间约752字节。',
    '扇区数': 'MIFARE Classic卡的扇区数量。\n\n'
        '每个扇区有独立的密钥对（Key A / Key B），互不干扰。\n'
        '• Classic 1K: 16个扇区 (0~15)\n'
        '• Classic 4K: 40个扇区 (0~39)\n\n'
        '每个扇区需单独认证后才能读写其中的块数据。',
    '块数': 'MIFARE卡的总块数量。\n\n'
        '块是读写操作的最小单位，每块通常为16字节。\n\n'
        '每扇区包含4个块（块0~2为用户数据，块3为扇区尾部）。\n'
        '扇区尾部块存储Key A（6字节）+ 访问位（4字节）+ Key B（6字节）。',
    '每块大小': '每个存储块的大小，MIFARE Classic固定为16字节。\n\n'
        '读写指令以块为单位操作，每次读写最小16字节。\n'
        '块数据通常以十六进制显示和编辑。',
  };

  static const List<Map<String, String>> _commonMifareKeys = [
    {'name': '出厂默认Key A', 'key': 'FFFFFFFFFFFF'},
    {'name': '出厂默认Key B', 'key': 'FFFFFFFFFFFF'},
    {'name': '全零Key A', 'key': '000000000000'},
    {'name': '全零Key B', 'key': '000000000000'},
    {'name': '中国通用卡Key A', 'key': 'A0B0C0D0E0F0'},
    {'name': '中国通用卡Key B', 'key': 'A0B0C0D0E0F0'},
    {'name': 'NXP测试Key A', 'key': 'A0A1A2A3A4A5'},
    {'name': 'NXP测试Key B', 'key': 'B0B1B2B3B4B5'},
    {'name': 'MIFARE Classic 1K Key A', 'key': '4D4946415245'},
    {'name': 'MIFARE Classic 1K Key B', 'key': '4D4946415245'},
    {'name': 'AAA测试Key A', 'key': 'AABBCCDDEEFF'},
    {'name': 'AAA测试Key B', 'key': 'AABBCCDDEEFF'},
  ];

  // --- Read Tab ---

  Widget _buildReadTab() {
    final tag = _currentTag!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionCard(
              '标签基本信息', Icons.credit_card, _buildBasicInfo(tag)),
          const SizedBox(height: 12),
          _buildSectionCard('NDEF数据内容', Icons.article, _buildNdefSection()),
          const SizedBox(height: 12),
          _buildSectionCard('技术详情', Icons.memory, _buildTechSection(tag)),
          if (_isMifare && _mifareSectors.values.any((s) => s.authenticated))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _buildSectionCard(
                  'MIFARE已认证数据', Icons.lock_open, _buildMifareReadSection()),
            ),
          if (tag.ndefAvailable != true &&
              (_ndefRecords == null || _ndefRecords!.isEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _buildHintCard(
                Icons.warning_amber,
                _isMifare
                    ? '此MIFARE卡未包含NDEF数据。切换到"写入修改"或"MIFARE"标签页使用扇区认证和块读写功能。'
                    : '此NFC卡不支持NDEF数据格式或未包含NDEF数据。',
                Colors.grey,
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildMifareReadSection() {
    final items = <Widget>[];
    for (final entry in _mifareSectors.entries) {
      if (!entry.value.authenticated) continue;
      final sector = entry.key;
      final st = entry.value;
      items.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('扇区 $sector 已认证 (KeyA: ${st.keyA ?? "?"})',
            style: TextStyle(fontSize: 13, color: Colors.green[700])),
      ));
    }
    if (_lastBlockHex.isNotEmpty) {
      items.add(const SizedBox(height: 8));
      items.add(const Divider());
      items.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('块 $_selectedBlock (扇区 $_selectedSector):',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      ));
      items.add(Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(
          _lastBlockHex,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.greenAccent),
        ),
      ));
    }
    if (items.isEmpty) {
      items.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无已认证的扇区数据'),
      ));
    }
    return items;
  }

  Widget _buildSectionCard(
      String title, IconData icon, List<Widget> items) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey[200]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[800])),
              ],
            ),
            const Divider(height: 20),
            ...items,
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBasicInfo(NFCTag tag) {
    final rows = <Widget>[];
    void r(String label, String value) {
      rows.add(_buildKV(
        label, value,
        explanation: _fieldExplanations[label],
      ));
    }

    r('标签UID', tag.id);
    r('标签类型', _tagTypeName(tag.type));
    r('通信标准', tag.standard);

    final writable = tag.ndefWritable == true;
    r('NDEF可写', writable ? '是' : '否');

    r('支持NDEF', tag.ndefAvailable == true ? '是' : '否');

    if (tag.ndefCapacity != null) {
      r('NDEF容量', '${tag.ndefCapacity} 字节');
    }

    r('可设为只读', tag.ndefCanMakeReadOnly == true ? '是' : '否');

    if (tag.mifareInfo != null) {
      r('MIFARE类型', tag.mifareInfo!.type);
      r('MIFARE容量', '${tag.mifareInfo!.size} 字节');
      r('扇区数', '${_sectorCount}');
      r('块数', '${tag.mifareInfo!.blockCount}');
      if (tag.mifareInfo!.blockSize > 0) {
        r('每块大小', '${tag.mifareInfo!.blockSize} 字节');
      }
    }

    return rows;
  }

  String _tagTypeName(NFCTagType type) {
    return switch (type) {
      NFCTagType.iso7816 => 'ISO 7816 (接触式IC卡)',
      NFCTagType.iso15693 => 'ISO 15693 (Vicinity卡)',
      NFCTagType.iso18092 => 'ISO 18092 (NFC-F / FeliCa)',
      NFCTagType.mifare_classic => 'MIFARE Classic',
      NFCTagType.mifare_ultralight => 'MIFARE Ultralight',
      NFCTagType.mifare_desfire => 'MIFARE DESFire',
      NFCTagType.mifare_plus => 'MIFARE Plus',
      NFCTagType.webusb => 'WebUSB (浏览器NFC)',
      NFCTagType.unknown => '未知类型',
    };
  }

  void _showFieldInfo(String title, String explanation) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.info_outline, size: 20, color: Colors.blue[700]),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(explanation,
              style: TextStyle(fontSize: 13, color: Colors.grey[700], height: 1.5)),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildKV(String label, String value,
      {String? explanation}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (explanation != null) ...[
            InkWell(
              onTap: () => _showFieldInfo(label, explanation),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey[200],
                ),
                child: Center(
                  child: Icon(Icons.help_outline,
                      size: 11, color: Colors.grey[500]),
                ),
              ),
            ),
            const SizedBox(width: 2),
          ],
          SizedBox(
            width: 105,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          ),
          SizedBox(
            width: 8,
            child: Center(
              child: Text('|',
                  style: TextStyle(fontSize: 12, color: Colors.grey[300])),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildNdefSection() {
    if (_isLoadingNdef) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('正在读取NDEF数据…',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
          ),
        ),
      ];
    }

    if (_ndefRecords == null || _ndefRecords!.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Colors.grey[400]),
              const SizedBox(width: 8),
              Text('此标签未包含NDEF数据',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
          ),
        ),
      ];
    }

    final items = <Widget>[];
    for (var i = 0; i < _ndefRecords!.length; i++) {
      items.add(_buildNdefCard(i, _ndefRecords![i]));
      if (i < _ndefRecords!.length - 1) items.add(const SizedBox(height: 8));
    }
    return items;
  }

  Widget _buildNdefCard(int index, NDEFRecord record) {
    String typeStr;
    IconData typeIcon;
    String displayText;

    if (record is TextRecord) {
      typeStr = '文本记录';
      typeIcon = Icons.text_fields;
      displayText = record.text ?? '(空)';
    } else if (record is UriRecord) {
      typeStr = '链接/URI';
      typeIcon = Icons.link;
      displayText = record.iriString ?? '(空)';
    } else {
      typeStr = '类型: ${record.tnf}';
      typeIcon = Icons.help_outline;
      displayText = record.fullType ?? '(未知)';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(typeIcon, size: 16, color: Colors.blue[600]),
              const SizedBox(width: 6),
              Text('记录 ${index + 1} · $typeStr',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey[100]!),
            ),
            child: SelectableText(displayText,
                style: TextStyle(fontSize: 13, color: Colors.grey[800])),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTechSection(NFCTag tag) {
    final items = <Widget>[];
    void r(String label, String value) {
      items.add(_buildKV(label, value));
    }

    if (tag.atqa != null) r('ATQA', tag.atqa!);
    if (tag.sak != null) r('SAK', tag.sak!);
    if (tag.historicalBytes != null) r('历史字节', tag.historicalBytes!);
    if (tag.hiLayerResponse != null) r('高层响应', tag.hiLayerResponse!);
    if (tag.protocolInfo != null) r('协议信息', tag.protocolInfo!);
    if (tag.applicationData != null) r('应用数据', tag.applicationData!);
    if (tag.manufacturer != null) r('制造商', tag.manufacturer!);
    if (tag.systemCode != null) r('系统代码', tag.systemCode!);
    if (tag.dsfId != null) r('DSFID', tag.dsfId!);
    if (tag.ndefType != null) r('NDEF类型', tag.ndefType!);

    if (items.isEmpty) {
      items.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('无额外的技术详情数据',
            style: TextStyle(color: Colors.grey[500], fontSize: 13)),
      ));
    }

    final hint = _tagHint(tag.type);
    if (hint != null) {
      items.add(const SizedBox(height: 8));
      items.add(hint);
    }

    return items;
  }

  Widget? _tagHint(NFCTagType type) {
    return switch (type) {
      NFCTagType.iso18092 => _buildHintCard(
          Icons.info,
          'FeliCa (ISO 18092) 卡片常见于日本公共交通IC卡、电子钱包等应用场景',
          Colors.blue),
      NFCTagType.mifare_classic => _buildHintCard(
          Icons.info,
          'MIFARE Classic 广泛用于门禁卡、公交卡、校园卡等场景。\n'
          '使用默认密钥(FFFFFFFFFFFF)尝试认证扇区后可进行块读写。',
          Colors.amber),
      NFCTagType.mifare_ultralight => _buildHintCard(
          Icons.info,
          'MIFARE Ultralight 低成本NFC标签，常用于活动门票、海报标签等',
          Colors.teal),
      NFCTagType.iso15693 => _buildHintCard(
          Icons.info,
          'ISO 15693 (Vicinity Card) 常用于图书馆管理、资产追踪、物流管理等',
          Colors.purple),
      _ => null,
    };
  }

  Widget _buildHintCard(IconData icon, String text, MaterialColor color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.shade100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: color[800], height: 1.4)),
          ),
        ],
      ),
    );
  }

  // --- Write Tab ---

  Widget _buildWriteTab() {
    final tag = _currentTag!;

    // MIFARE without NDEF: show MIFARE tools directly
    if (_isMifare && tag.ndefAvailable != true) {
      return _buildMifareTab();
    }

    if (tag.ndefWritable == false) {
      return _buildBlocked(Icons.lock, '此标签为NDEF只读',
          '该NFC卡已被设置为只读模式，无法进行数据写入操作。此设置不可逆。');
    }

    if (tag.ndefAvailable != true) {
      String msg;
      if (_isMifare) {
        msg = '此MIFARE卡不支持NDEF格式，请使用MIFARE扇区读写功能。';
      } else {
        msg = '当前NFC卡不支持NDEF格式，无法进行标准数据写入。\n\n建议：\n'
            '• 使用空白NDEF格式NFC标签卡（如NTAG系列）\n'
            '• 确保标签为NDEF可格式化类型';
      }
      return _buildBlocked(Icons.warning_amber, '此标签不支持NDEF', msg);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _NDEFWriteForm(
            existingRecords: _ndefRecords ?? [],
            onWrite: _performWrite,
            onClear: _performClear,
          ),
          if (_isMifare) ...[
            const SizedBox(height: 24),
            _buildSectionCard('MIFARE扇区读写', Icons.memory, [
              _buildHintCard(
                Icons.info,
                '此MIFARE卡同时支持NDEF，展开下方扇区读写工具可执行底层块操作。',
                Colors.blue,
              ),
            ]),
            const SizedBox(height: 12),
            _buildMifareTools(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildBlocked(IconData icon, String title, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey[200]!),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 56, color: Colors.orange[300]),
                const SizedBox(height: 16),
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
                Text(message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        height: 1.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Clone Tab ---

  Widget _buildCloneTab() {
    if (!_isMifare) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.copy_all_rounded, size: 64, color: Colors.grey[300]),
              const SizedBox(height: 16),
              Text('克隆功能仅支持MIFARE卡',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600])),
              const SizedBox(height: 8),
              Text('非MIFARE标签（如ISO 15693、FeliCa）不支持扇区级克隆',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400])),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionCard('克隆操作', Icons.copy_all_rounded, _buildCloneActions()),
          if (_cloneData.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSectionCard('已读取数据', Icons.storage, _buildCloneDataInfo()),
          ],
          if (_cloneStatusMsg.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildHintCard(Icons.info, _cloneStatusMsg, Colors.blue),
          ],
          if (_cloneData.isNotEmpty && _cloneFilePath != null) ...[
            const SizedBox(height: 12),
            _buildHintCard(Icons.folder, '保存路径: $_cloneFilePath', Colors.teal),
          ],
          if (_pendingCloneData != null && !_cloneWritePending) ...[
            const SizedBox(height: 12),
            _buildHintCard(
              Icons.warning_amber,
              '已有待写入数据，请点击"开始写入目标卡"后将新卡靠近手机',
              Colors.orange,
            ),
          ],
          const SizedBox(height: 16),
          _buildHintCard(
            Icons.info,
            '克隆过程：\n'
            '1. 在MIFARE/MIFARE标签页设置扇区认证密钥（Key A/B）\n'
            '2. 点击"读取全卡数据" — 将自动尝试用当前密钥认证每个扇区并读取\n'
            '3. 读取成功后保存到文件或直接写入目标卡\n'
            '4. 写入时将目标空白卡靠近手机即可',
            Colors.blue,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildCloneActions() {
    final hasData = _cloneData.isNotEmpty;
    return [
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _isCloneReading ? null : _readAllSectors,
          icon: _isCloneReading
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_rounded, size: 18),
          label: Text(_isCloneReading ? '读取中…' : '读取全卡数据'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: hasData && !_isCloneReading ? _saveCloneData : null,
              icon: const Icon(Icons.save_alt, size: 16),
              label: const Text('保存到文件'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isCloneReading ? null : _loadCloneData,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('从文件加载'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: (_isCloneWriting || _cloneWritePending || _cloneData.isEmpty)
              ? null
              : () {
                  setState(() {
                    _pendingCloneData = Map.from(_cloneData);
                    _cloneWritePending = true;
                    _statusMessage = '请将目标卡靠近手机感应区';
                    _cloneStatusMsg = '准备写入目标卡，请放置目标卡…';
                  });
                  _finishSession();
                  _startPolling();
                },
          icon: _isCloneWriting || _cloneWritePending
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_rounded, size: 18),
          label: Text(
            _isCloneWriting
                ? '写入中…'
                : _cloneWritePending
                    ? '等待目标卡…'
                    : '开始写入目标卡',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      if (_cloneWritePending) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: () {
              setState(() {
                _cloneWritePending = false;
                _pendingCloneData = null;
                _cloneStatusMsg = '已取消写入';
              });
            },
            icon: const Icon(Icons.cancel, size: 16),
            label: const Text('取消写入'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ),
      ],
    ];
  }

  List<Widget> _buildCloneDataInfo() {
    final sectors = _cloneData.keys.toList()..sort();
    final totalBytes = sectors.fold<int>(0, (sum, s) => sum + (_cloneData[s]!.length ~/ 2));
    return [
      Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: Colors.green[600]),
          const SizedBox(width: 6),
          Text('${sectors.length} 个扇区 | $totalBytes 字节',
              style: TextStyle(fontSize: 13, color: Colors.grey[700])),
        ],
      ),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已读取的扇区: ${sectors.join(", ")}',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            if (_cloneFilePath != null) ...[
              const SizedBox(height: 4),
              Text('文件: ${_cloneFilePath!.split('\\').last}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ],
          ],
        ),
      ),
    ];
  }

  // --- MIFARE Tab / Tools ---

  Widget _buildMifareTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionCard('MIFARE扇区认证', Icons.lock, _buildAuthSection()),
          const SizedBox(height: 12),
          _buildSectionCard('块读写操作', Icons.edit, _buildBlockOpsSection()),
          if (_mifareStatusMsg.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildHintCard(Icons.info, _mifareStatusMsg, Colors.blue),
          ],
          if (_lastBlockHex.isNotEmpty && _mifareSectors[_selectedSector]?.authenticated == true) ...[
            const SizedBox(height: 12),
            _buildSectionCard(
                '最后读取数据 (扇区$_selectedSector 块$_selectedBlock)',
                Icons.data_array, [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _lastBlockHex,
                  style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Colors.greenAccent),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 16),
          _buildHintCard(
            Icons.warning_amber,
            'MIFARE Classic 扇区尾部块(第${_blocksPerSector - 1}块)存储密钥和访问控制位，错误修改可能导致卡片永久损坏！',
            Colors.red,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildAuthSection() {
    return [
      Row(
        children: [
          const Text('扇区: ', style: TextStyle(fontSize: 13)),
          SizedBox(
            width: 72,
            child: DropdownButtonFormField<int>(
              value: _selectedSector.clamp(0, _sectorCount - 1),
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                isDense: true,
              ),
              items: List.generate(_sectorCount,
                  (i) => DropdownMenuItem(value: i, child: Text('$i', style: const TextStyle(fontSize: 13)))),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _selectedSector = v;
                    _selectedBlock = 0;
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          if (_mifareSectors[_selectedSector]?.authenticated == true)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Text('已认证',
                  style: TextStyle(fontSize: 11, color: Colors.green[700])),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keyAController,
              decoration: const InputDecoration(
                labelText: 'Key A (Hex)',
                hintText: 'FFFFFFFFFFFF',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              maxLength: 12,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _keyBController,
              decoration: const InputDecoration(
                labelText: 'Key B (Hex)',
                hintText: 'FFFFFFFFFFFF',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              maxLength: 12,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed:
              _mifareAuthInProgress ? null : () => _authenticateSector(_selectedSector),
          icon: _mifareAuthInProgress
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.lock_open, size: 18),
          label: Text(_mifareAuthInProgress ? '认证中…' : '认证此扇区'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ExpansionTile(
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Row(
          children: [
            Icon(Icons.key, size: 16, color: Colors.amber[700]),
            const SizedBox(width: 6),
            Text('常见密钥列表',
                style: TextStyle(fontSize: 13, color: Colors.amber[800])),
          ],
        ),
        children: [
          const SizedBox(height: 4),
          Text('点击"填充"将密钥填入上方输入框',
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          const SizedBox(height: 8),
          ..._commonMifareKeys.map((entry) {
            final name = entry['name']!;
            final hex = entry['key']!;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                          const SizedBox(height: 2),
                          Text(hex,
                              style: const TextStyle(
                                  fontSize: 12, fontFamily: 'monospace')),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 28,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          if (name.endsWith('Key A')) {
                            _keyAController.text = hex;
                            _keyAController.selection = TextSelection.fromPosition(
                              TextPosition(offset: hex.length),
                            );
                          } else if (name.endsWith('Key B')) {
                            _keyBController.text = hex;
                            _keyBController.selection = TextSelection.fromPosition(
                              TextPosition(offset: hex.length),
                            );
                          }
                        });
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        foregroundColor: Colors.blue[700],
                        backgroundColor: Colors.blue[50],
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      child: const Text('填充',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    ];
  }

  List<Widget> _buildBlockOpsSection() {
    final authSectors = _mifareSectors.entries
        .where((e) => e.value.authenticated)
        .map((e) => e.key)
        .toList();

    if (authSectors.isEmpty) {
      return [
        _buildHintCard(Icons.info,
            '请先在上方认证一个扇区，然后才能进行块读写操作。', Colors.grey),
      ];
    }

    final canWrite = _selectedSector == _selectedBlock ~/ _blocksPerSector &&
        _mifareSectors[_selectedSector]?.authenticated == true;

    return [
      Row(
        children: [
          const Text('扇区: ', style: TextStyle(fontSize: 13)),
          SizedBox(
            width: 64,
            child: DropdownButtonFormField<int>(
              value: authSectors.contains(_selectedSector)
                  ? _selectedSector
                  : authSectors.first,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                isDense: true,
              ),
              items: authSectors.map((s) => DropdownMenuItem(
                  value: s, child: Text('$s', style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _selectedSector = v;
                    _selectedBlock = 0;
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 16),
          const Text('块: ', style: TextStyle(fontSize: 13)),
          SizedBox(
            width: 64,
            child: DropdownButtonFormField<int>(
              value: _selectedBlock.clamp(0, _blocksPerSector - 1),
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                isDense: true,
              ),
              items: List.generate(
                _blocksPerSector,
                (i) => DropdownMenuItem(
                    value: i,
                    child: Text('$i',
                        style: TextStyle(
                          fontSize: 13,
                          color: _isSectorTrailer(_selectedSector, i)
                              ? Colors.red
                              : null,
                        ))),
              ).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _selectedBlock = v);
              },
            ),
          ),
        ],
      ),
      if (_isSectorTrailer(_selectedSector, _selectedBlock))
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('⚠ 扇区尾部块（存储密钥和访问位）',
              style: TextStyle(fontSize: 11, color: Colors.red[600])),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () =>
                  _readBlock(_selectedSector, _selectedBlock),
              icon: const Icon(Icons.download, size: 16),
              label: const Text('读取块'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _readSector(_selectedSector),
              icon: const Icon(Icons.downloading, size: 16),
              label: const Text('读取整扇区'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _blockWriteController,
        decoration: InputDecoration(
          labelText: '十六进制数据 (Hex)',
          hintText: '00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F',
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          suffixIcon: IconButton(
            icon: const Icon(Icons.paste, size: 18),
            onPressed: () {
              if (_lastBlockHex.isNotEmpty) {
                _blockWriteController.text = _lastBlockHex;
              }
            },
          ),
        ),
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        maxLines: 2,
        minLines: 1,
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: canWrite
              ? () => _writeBlock(_selectedSector, _selectedBlock)
              : null,
          icon: const Icon(Icons.upload, size: 18),
          label: const Text('写入块'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    ];
  }

  Widget _buildMifareTools() {
    return _buildSectionCard('扇区认证与块读写', Icons.memory, _buildAuthSection()
      ..addAll([
        const SizedBox(height: 16),
        ..._buildBlockOpsSection(),
      ]));
  }
}

// --- NDEF Write Form (extracted) ---

class _NDEFWriteForm extends StatefulWidget {
  final List<NDEFRecord> existingRecords;
  final Future<void> Function(List<NDEFRecord> records) onWrite;
  final VoidCallback onClear;

  const _NDEFWriteForm({
    required this.existingRecords,
    required this.onWrite,
    required this.onClear,
  });

  @override
  State<_NDEFWriteForm> createState() => _NDEFWriteFormState();
}

class _NDEFWriteFormState extends State<_NDEFWriteForm> {
  final _textController = TextEditingController();
  final _uriController = TextEditingController();
  bool _isWriting = false;

  @override
  void initState() {
    super.initState();
    for (final record in widget.existingRecords) {
      if (record is TextRecord && record.text != null) {
        _textController.text = record.text!;
      } else if (record is UriRecord && record.iriString != null) {
        _uriController.text = record.iriString!;
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _uriController.dispose();
    super.dispose();
  }

  Future<void> _handleWrite() async {
    final records = <NDEFRecord>[];
    if (_textController.text.trim().isNotEmpty) {
      records.add(TextRecord(text: _textController.text.trim()));
    }
    if (_uriController.text.trim().isNotEmpty) {
      records.add(UriRecord.fromString(_uriController.text.trim()));
    }
    if (records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少填写一项内容')),
      );
      return;
    }
    setState(() => _isWriting = true);
    await widget.onWrite(records);
    if (mounted) setState(() => _isWriting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey[200]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, size: 20, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text('NDEF数据写入',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[800])),
              ],
            ),
            const Divider(height: 20),
            _buildInputGroup('文本内容', Icons.text_fields,
                '输入要写入NFC卡的文本信息', _textController),
            const SizedBox(height: 16),
            _buildInputGroup('链接地址', Icons.link,
                '输入URL链接地址（如 https://example.com）', _uriController),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isWriting ? null : _handleWrite,
                    icon: _isWriting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save, size: 18),
                    label: Text(_isWriting ? '写入中…' : '写入数据'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isWriting ? null : widget.onClear,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('清除数据'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red[600],
                      side: BorderSide(color: Colors.red[200]!),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber,
                      size: 18, color: Colors.amber[700]),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '写入操作将覆盖NFC卡上所有已有的NDEF数据，请谨慎操作。'
                      '操作过程中请保持NFC卡靠近手机，不要移开。',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber[800],
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputGroup(String label, IconData icon, String hint,
      TextEditingController controller) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.blue[600]),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
            ),
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
