import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart';
import 'package:ndef/records/media/wifi.dart';
import 'package:permission_handler/permission_handler.dart';

// 速写模式枚举
enum _QuickWriteMode {
  none,
  text,
  url,
  screencast,
  wifi,
  vcard,
  navigate,
  payment,
  home,
}

class NfcQuickWritePage extends StatefulWidget {
  const NfcQuickWritePage({super.key});

  @override
  State<NfcQuickWritePage> createState() => _NfcQuickWritePageState();
}

class _NfcQuickWritePageState extends State<NfcQuickWritePage>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _urlController = TextEditingController();

  // WiFi 速写输入控制器
  final _wifiSsidController = TextEditingController();
  final _wifiPasswordController = TextEditingController();
  // WiFi密码是否可见
  bool _wifiPasswordVisible = false;
  // WiFi密码输入框焦点控制（选择WiFi后自动聚焦到密码框）
  final _wifiPasswordFocusNode = FocusNode();

  // WiFi 扫描状态
  List<Map<String, dynamic>> _wifiScanResults = [];
  bool _isScanningWifi = false;

  // 微信QQ输入控制器
  final _vcardWechatController = TextEditingController();
  final _vcardQqController = TextEditingController();

  // 导航速写输入控制器
  final _navNameController = TextEditingController();
  // 选中的导航软件索引：0=高德, 1=百度, 2=腾讯
  int _navAppIndex = 0;

  // 回家模式输入控制器
  final _homeAddrController = TextEditingController();
  final _homeWifiSsidController = TextEditingController();
  final _homeWifiPwdController = TextEditingController();

  _QuickWriteMode _mode = _QuickWriteMode.none;
  NFCAvailability _availability = NFCAvailability.not_supported;
  String _statusMessage = '';
  bool _isWaiting = false;
  bool _isWriting = false;

  // WiFi 加密类型选择
  WifiAuthenticationType _wifiAuthType = WifiAuthenticationType.wpa2Personal;

  // 付款方式选择
  int _paymentType = 0; // 0=支付宝, 1=微信

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
    _textController.dispose();
    _urlController.dispose();
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    _wifiPasswordFocusNode.dispose();
    _vcardWechatController.dispose();
    _vcardQqController.dispose();
    _navNameController.dispose();
    _homeAddrController.dispose();
    _homeWifiSsidController.dispose();
    _homeWifiPwdController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNfcStatus();
    }
  }

  Future<void> _checkNfcStatus() async {
    try {
      final avail = await FlutterNfcKit.nfcAvailability;
      if (mounted) setState(() => _availability = avail);
    } catch (_) {}
  }

  Future<void> _finishSession() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  // ======================================================================
  // NFC 可用性检查
  // ======================================================================

  bool _checkNfcAvailable() {
    if (_availability != NFCAvailability.available) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _availability == NFCAvailability.disabled
                ? 'NFC功能未开启，请在系统设置中打开NFC开关'
                : '该设备不支持NFC功能',
          ),
        ),
      );
      return false;
    }
    return true;
  }

  // ======================================================================
  // 进入写入待命状态
  // ======================================================================

  void _enterWriteMode(_QuickWriteMode mode, String waitHint) {
    _finishSession();
    setState(() {
      _mode = mode;
      _isWaiting = true;
      _isWriting = false;
      _statusMessage = '请将NFC卡靠近手机感应区域…';
    });
    _doPoll();
  }

  // ======================================================================
  // 投屏速写：显示品牌选择弹窗
  // ======================================================================

  void _startScreencastWrite() {
    if (!_checkNfcAvailable()) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题栏
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE65100).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.cast, color: Color(0xFFE65100), size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text('投屏速写', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('选择投屏品牌', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '选择你的手机品牌，将投屏指令写入NFC标签，碰卡即可启动投屏',
                style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.5),
              ),
              const SizedBox(height: 16),

              // OPPO / 一加品牌选项
              _buildBrandOption(
                ctx: ctx,
                icon: Icons.phone_android,
                brandName: 'OPPO / 一加',
                appName: 'OPPO互联',
                description: 'OPPO及一加手机自带投屏，需电脑安装OPPO互联客户端',
                color: const Color(0xFF1BA784),
              ),

              const SizedBox(height: 12),
              // 底部提示
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '写入前请确保：手机和电脑连接同一WiFi，电脑已安装对应投屏客户端',
                        style: TextStyle(fontSize: 11, color: Colors.orange[700], height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 构建投屏品牌选项卡片
  Widget _buildBrandOption({
    required BuildContext ctx,
    required IconData icon,
    required String brandName,
    required String appName,
    required String description,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () {
            Navigator.pop(ctx);
            _enterWriteMode(_QuickWriteMode.screencast, '投屏指令');
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(brandName,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(appName,
                                style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(description,
                          style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.4),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey[400], size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ======================================================================
  // WiFi 速写：输入 WiFi 信息弹窗
  // ======================================================================

  void _showWifiInputDialog() {
    if (!_checkNfcAvailable()) return;

    _wifiSsidController.clear();
    _wifiPasswordController.clear();
    _wifiAuthType = WifiAuthenticationType.wpa2Personal;
    _wifiScanResults = [];
    _isScanningWifi = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            // 修复卡顿：使用AnimatedPadding平滑处理键盘弹出
            // 避免viewInsets.bottom变化时触发完整重建导致卡顿
            return AnimatedPadding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              duration: const Duration(milliseconds: 100),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.wifi, color: Color(0xFF1565C0), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text('WiFi 速写', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('碰卡即可自动连接WiFi，适合家里来客使用',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 16),

                  // WiFi 扫描按钮
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isScanningWifi ? null : () async {
                        setModalState(() => _isScanningWifi = true);
                        await _scanWifiNetworks(setModalState);
                      },
                      icon: _isScanningWifi
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_find, size: 18),
                      label: Text(_isScanningWifi ? '正在扫描...' : '扫描附近WiFi'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1565C0),
                        side: const BorderSide(color: Color(0xFF1565C0)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // WiFi 列表（如果有扫描结果）
                  if (_wifiScanResults.isNotEmpty) ...[
                    Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _wifiScanResults.length,
                        itemBuilder: (context, index) {
                          final wifi = _wifiScanResults[index];
                          final ssid = wifi['ssid'] as String;
                          final signal = wifi['signal'] as int;
                          final authType = wifi['authType'] as String;
                          
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.wifi,
                              color: signal >= 3 ? Colors.green : signal >= 2 ? Colors.orange : Colors.red,
                              size: 20,
                            ),
                            title: Text(
                              ssid,
                              style: const TextStyle(fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '$authType · 信号${'▮' * (signal + 1)}${'▯' * (4 - signal)}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () {
                              _wifiSsidController.text = ssid;
                              if (authType == 'OPEN') {
                                _wifiAuthType = WifiAuthenticationType.open;
                              } else {
                                _wifiAuthType = WifiAuthenticationType.wpa2Personal;
                              }
                              // 修复：选择WiFi后不调用setModalState重建UI
                              // SSID已通过controller自动更新到TextField，无需重建
                              // 非开放网络时，延迟聚焦密码框并弹出键盘
                              if (authType != 'OPEN') {
                                Future.delayed(const Duration(milliseconds: 100), () {
                                  _wifiPasswordFocusNode.requestFocus();
                                });
                              }
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // WiFi 名称输入
                  TextField(
                    controller: _wifiSsidController,
                    decoration: InputDecoration(
                      labelText: 'WiFi 名称 (SSID)',
                      hintText: '如: MyHomeWiFi',
                      prefixIcon: const Icon(Icons.wifi, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // WiFi 密码输入（带显示/隐藏按钮）
                  TextField(
                    controller: _wifiPasswordController,
                    focusNode: _wifiPasswordFocusNode,
                    obscureText: !_wifiPasswordVisible,
                    decoration: InputDecoration(
                      labelText: 'WiFi 密码',
                      hintText: '输入WiFi密码',
                      prefixIcon: const Icon(Icons.lock, size: 20),
                      // 密码显示/隐藏切换按钮
                      suffixIcon: IconButton(
                        icon: Icon(
                          _wifiPasswordVisible ? Icons.visibility : Icons.visibility_off,
                          size: 20,
                          color: Colors.grey[600],
                        ),
                        onPressed: () {
                          setModalState(() {
                            _wifiPasswordVisible = !_wifiPasswordVisible;
                          });
                        },
                        tooltip: _wifiPasswordVisible ? '隐藏密码' : '显示密码',
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 加密类型选择
                  DropdownButtonFormField<WifiAuthenticationType>(
                    value: _wifiAuthType,
                    decoration: InputDecoration(
                      labelText: '加密方式',
                      prefixIcon: const Icon(Icons.security, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: WifiAuthenticationType.wpa2Personal,
                        child: Text('WPA/WPA2 个人'),
                      ),
                      DropdownMenuItem(
                        value: WifiAuthenticationType.wpa3Personal,
                        child: Text('WPA3 个人'),
                      ),
                      DropdownMenuItem(
                        value: WifiAuthenticationType.open,
                        child: Text('无密码（开放网络）'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) setModalState(() => _wifiAuthType = val);
                    },
                  ),
                  const SizedBox(height: 20),

                  // 确认写入按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      // 修复：移除密码验证步骤，直接进入写卡流程
                      // 原因：Android 10+ 的密码验证机制不可靠（WifiNetworkSuggestion
                      // 无法强制连接），验证过程长达15+秒且会中断用户当前WiFi连接，
                      // 导致用户长时间等待后无任何提示。改为直接写卡，由用户对密码正确性负责。
                      onPressed: () {
                        if (_wifiSsidController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请输入WiFi名称')),
                          );
                          return;
                        }
                        if (_wifiAuthType != WifiAuthenticationType.open &&
                            _wifiPasswordController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请输入WiFi密码')),
                          );
                          return;
                        }
                        // 直接进入写卡流程，不再验证密码
                        Navigator.pop(ctx);
                        _enterWriteMode(_QuickWriteMode.wifi, 'WiFi配置');
                      },
                      icon: const Icon(Icons.nfc, size: 18),
                      label: const Text('确认写入'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ======================================================================
  // WiFi 扫描
  // ======================================================================

  Future<void> _scanWifiNetworks(Function setModalState) async {
    try {
      // 请求位置权限（Android 8.0+ 扫描WiFi需要位置权限）
      final locationStatus = await Permission.locationWhenInUse.request();
      if (!locationStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要位置权限才能扫描附近WiFi')),
          );
        }
        setModalState(() => _isScanningWifi = false);
        return;
      }

      final wifiChannel = MethodChannel('com.example.toolapp/wifi_helper');
      final results = await wifiChannel.invokeMethod<List<dynamic>>('scanWifiNetworks');
      
      if (results != null) {
        _wifiScanResults = results.map((r) {
          final map = r as Map<dynamic, dynamic>;
          return {
            'ssid': map['ssid'] as String,
            'signal': map['signal'] as int,
            'authType': map['authType'] as String,
          };
        }).toList();
        
        // 按信号强度排序
        _wifiScanResults.sort((a, b) => (b['signal'] as int).compareTo(a['signal'] as int));
        
        // 更新UI显示扫描结果
        setModalState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('WiFi扫描失败: $e')),
        );
      }
    } finally {
      setModalState(() => _isScanningWifi = false);
    }
  }

  // ======================================================================
  // 微信QQ：输入社交账号信息弹窗
  // ======================================================================

  void _showVcardInputDialog() {
    if (!_checkNfcAvailable()) return;

    _vcardWechatController.clear();
    _vcardQqController.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            // 修复卡顿：不在builder中添加任何listener或调用setModalState
            // 微信/QQ互斥状态在点击确认按钮时检查即可，输入过程中不需要实时更新
            final hasWechat = _vcardWechatController.text.trim().isNotEmpty;
            final hasQq = _vcardQqController.text.trim().isNotEmpty;
            final wechatDisabled = hasQq;
            final qqDisabled = hasWechat;

            // 修复卡顿：使用AnimatedPadding平滑处理键盘弹出
            return AnimatedPadding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              duration: const Duration(milliseconds: 100),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF6A1B9A).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.contact_page, color: Color(0xFF6A1B9A), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text('微信QQ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('碰卡即可自动打开微信或QQ添加好友',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 16),

                  // 微信号输入（修复卡顿：不使用FocusNode监听，不触发setModalState）
                  TextField(
                    controller: _vcardWechatController,
                    enabled: !wechatDisabled,
                    decoration: InputDecoration(
                      labelText: '微信号',
                      hintText: wechatDisabled ? '已填写QQ号，请先清空' : '输入微信号（选填）',
                      prefixIcon: Icon(Icons.chat, size: 20,
                          color: wechatDisabled ? Colors.grey[400] : null),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // QQ号输入（修复卡顿：不使用FocusNode监听，不触发setModalState）
                  TextField(
                    controller: _vcardQqController,
                    enabled: !qqDisabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'QQ号',
                      hintText: qqDisabled ? '已填写微信号，请先清空' : '输入QQ号码（选填）',
                      prefixIcon: Icon(Icons.forum, size: 20,
                          color: qqDisabled ? Colors.grey[400] : null),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 提示：碰卡自动打开微信/QQ
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6A1B9A).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF6A1B9A).withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 16, color: const Color(0xFF6A1B9A)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '微信号和QQ号只能填写其中一项，填写的项将被写入标签，碰卡时自动打开对应App',
                            style: TextStyle(fontSize: 11, color: const Color(0xFF6A1B9A), height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 确认写入按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final wechat = _vcardWechatController.text.trim();
                        final qq = _vcardQqController.text.trim();
                        // 验证：微信号或QQ号至少填写一项
                        if (wechat.isEmpty && qq.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请至少填写微信号或QQ号其中一项')),
                          );
                          return;
                        }
                        // 验证：微信号和QQ号不能同时填写（防止bug）
                        if (wechat.isNotEmpty && qq.isNotEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('微信号和QQ号只能填写其中一项，请清空其中一个')),
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        _enterWriteMode(_QuickWriteMode.vcard, '微信QQ');
                      },
                      icon: const Icon(Icons.nfc, size: 18),
                      label: const Text('确认写入'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6A1B9A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ======================================================================
  // 导航速写：输入目的地信息弹窗
  // ======================================================================

  void _showNavigateInputDialog() {
    if (!_checkNfcAvailable()) return;

    _navNameController.clear();
    _navAppIndex = 0;

    // 国内主流导航软件列表
    final navApps = [
      {'name': '高德地图', 'icon': Icons.map_outlined, 'color': const Color(0xFF1677FF)},
      {'name': '百度地图', 'icon': Icons.map, 'color': const Color(0xFF2932E1)},
      {'name': '腾讯地图', 'icon': Icons.explore, 'color': const Color(0xFF00C2C2)},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AnimatedPadding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              duration: const Duration(milliseconds: 100),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00897B).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.navigation, color: Color(0xFF00897B), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text('导航速写', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('选择导航软件并输入目的地，碰卡自动打开该软件导航',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 16),

                  // 导航软件选择
                  Text('选择导航软件', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[700])),
                  const SizedBox(height: 8),
                  Row(
                    children: List.generate(navApps.length, (i) {
                      final app = navApps[i];
                      final selected = _navAppIndex == i;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setModalState(() => _navAppIndex = i),
                          child: Container(
                            margin: EdgeInsets.only(right: i < navApps.length - 1 ? 8 : 0),
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                            decoration: BoxDecoration(
                              color: selected ? (app['color'] as Color).withValues(alpha: 0.12) : Colors.grey[100],
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected ? app['color'] as Color : Colors.grey[300]!,
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Icon(app['icon'] as IconData,
                                    color: selected ? app['color'] as Color : Colors.grey[500], size: 22),
                                const SizedBox(height: 4),
                                Text(app['name'] as String,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                      color: selected ? app['color'] as Color : Colors.grey[600],
                                    )),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),

                  // 目的地名称/地址输入
                  TextField(
                    controller: _navNameController,
                    decoration: InputDecoration(
                      labelText: '目的地名称或地址 *',
                      hintText: '如: 天安门、北京市朝阳区xx路xx号',
                      prefixIcon: const Icon(Icons.place, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 提示：目的地会被写入NFC卡，碰卡自动打开选中的导航软件搜索该目的地
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00897B).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF00897B).withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 16, color: const Color(0xFF00897B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '目的地和导航软件会被写入NFC卡。碰卡后自动打开选中的导航软件并搜索目的地。若手机未安装该软件，将给出提示。',
                            style: TextStyle(fontSize: 11, color: const Color(0xFF00897B), height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 确认写入按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        if (_navNameController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请输入目的地名称或地址')),
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        _enterWriteMode(_QuickWriteMode.navigate, '导航指令');
                      },
                      icon: const Icon(Icons.nfc, size: 18),
                      label: const Text('确认写入'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00897B),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ======================================================================
  // 付款速写：选择付款方式弹窗
  // ======================================================================

  void _showPaymentSelectSheet() {
    if (!_checkNfcAvailable()) return;

    _paymentType = 0;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D32).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.payment, color: Color(0xFF2E7D32), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text('付款速写', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text('选择付款方式', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('碰卡即可打开付款码，适合收银台快速付款',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 16),

                  // 支付宝选项
                  _buildPaymentOption(
                    ctx: ctx,
                    setModalState: setModalState,
                    index: 0,
                    icon: Icons.account_balance_wallet,
                    name: '支付宝',
                    description: '碰卡打开支付宝付款码',
                    color: const Color(0xFF1677FF),
                  ),
                  const SizedBox(height: 10),

                  // 微信选项
                  _buildPaymentOption(
                    ctx: ctx,
                    setModalState: setModalState,
                    index: 1,
                    icon: Icons.chat_bubble,
                    name: '微信',
                    description: '碰卡打开微信付款码',
                    color: const Color(0xFF07C160),
                  ),

                  const SizedBox(height: 16),
                  // 确认写入按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _enterWriteMode(_QuickWriteMode.payment, '付款码指令');
                      },
                      icon: const Icon(Icons.nfc, size: 18),
                      label: const Text('确认写入'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // 构建付款方式选项
  Widget _buildPaymentOption({
    required BuildContext ctx,
    required StateSetter setModalState,
    required int index,
    required IconData icon,
    required String name,
    required String description,
    required Color color,
  }) {
    final isSelected = _paymentType == index;
    return Material(
      color: isSelected ? color.withValues(alpha: 0.08) : Colors.grey.shade50,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => setModalState(() => _paymentType = index),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : Colors.grey.shade200,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(description, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  ],
                ),
              ),
              // 选中指示器
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? color : Colors.transparent,
                  border: Border.all(
                    color: isSelected ? color : Colors.grey.shade400,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ======================================================================
  // 回家模式：输入组合信息弹窗
  // ======================================================================

  void _showHomeInputDialog() {
    if (!_checkNfcAvailable()) return;

    _homeAddrController.clear();
    _homeWifiSsidController.clear();
    _homeWifiPwdController.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return AnimatedPadding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          duration: const Duration(milliseconds: 100),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题栏
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD84315).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.home, color: Color(0xFFD84315), size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text('回家模式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text('碰卡自动执行：导航回家 + 连接WiFi + 启动音乐',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 16),

              // 家庭地址
              TextField(
                controller: _homeAddrController,
                decoration: InputDecoration(
                  labelText: '家庭地址',
                  hintText: '输入回家导航地址',
                  prefixIcon: const Icon(Icons.place, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),

              // 家庭WiFi名称
              TextField(
                controller: _homeWifiSsidController,
                decoration: InputDecoration(
                  labelText: '家庭WiFi名称',
                  hintText: '输入家里WiFi的SSID',
                  prefixIcon: const Icon(Icons.wifi, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),

              // 家庭WiFi密码
              TextField(
                controller: _homeWifiPwdController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '家庭WiFi密码',
                  hintText: '输入家里WiFi密码',
                  prefixIcon: const Icon(Icons.lock, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),

              // 提示
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '碰卡后App将依次执行：导航回家、连接WiFi、打开音乐App',
                        style: TextStyle(fontSize: 11, color: Colors.orange[700], height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 确认写入按钮
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (_homeAddrController.text.trim().isEmpty &&
                        _homeWifiSsidController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请至少填写一项内容')),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    _enterWriteMode(_QuickWriteMode.home, '回家模式指令');
                  },
                  icon: const Icon(Icons.nfc, size: 18),
                  label: const Text('确认写入'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD84315),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ======================================================================
  // 文本/网址输入弹窗
  // ======================================================================

  void _showInputDialog(_QuickWriteMode mode) {
    final isUrl = mode == _QuickWriteMode.url;
    final controller = isUrl ? _urlController : _textController;
    final hint = isUrl ? '请输入网址，如 https://example.com' : '请输入要写入的文本内容';
    final icon = isUrl ? Icons.link : Icons.text_fields;
    final title = isUrl ? '网址写入' : '文本写入';
    final label = isUrl ? '网址' : '文本内容';

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.blue[700], size: 20),
              ),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontSize: 18)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              maxLines: 3,
              minLines: 1,
              autofocus: true,
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx),
              icon: const Icon(Icons.close, size: 18),
              label: const Text('关闭'),
              style: TextButton.styleFrom(foregroundColor: Colors.grey[600]),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _startWrite(mode);
              },
              icon: const Icon(Icons.nfc, size: 18),
              label: const Text('确认写入'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _startWrite(_QuickWriteMode mode) {
    final content = mode == _QuickWriteMode.text
        ? _textController.text.trim()
        : _urlController.text.trim();

    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入内容后再进行写入')),
      );
      return;
    }

    if (!_checkNfcAvailable()) return;

    _finishSession();

    setState(() {
      _mode = mode;
      _isWaiting = true;
      _isWriting = false;
      _statusMessage = '请将NFC卡靠近手机感应区域…';
    });
    _doPoll();
  }

  // ======================================================================
  // NFC 轮询和标签发现
  // ======================================================================

  // NFC 轮询：发现标签
  Future<void> _doPoll() async {
    try {
      // 使用0x80(FLAG_READER_SKIP_NDEF_CHECK)跳过NDEF检查
      // 对CUID/MIFARE Classic卡，NDEF检查可能导致poll超时或失败
      // MIFARE Classic卡改用块级写入，不依赖NDEF API
      const readerFlags = 0x01 | 0x02 | 0x04 | 0x08 | 0x80 | 0x100;
      final tag = await FlutterNfcKit.poll(
        androidReaderModeFlags: readerFlags,
        androidPlatformSound: false,
        androidCheckNDEF: false,
      );
      if (!mounted) return;
      await _onTagDiscovered(tag);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWaiting = false;
          _statusMessage = 'NFC感应中断: $e';
        });
      }
    }
  }

  // ======================================================================
  // 标签发现后写入逻辑
  // ======================================================================

  Future<void> _onTagDiscovered(NFCTag tag) async {
    setState(() {
      _isWaiting = false;
      _isWriting = true;
      _statusMessage = '正在写入数据…请保持NFC卡靠近手机';
    });

    final isMifareClassic = tag.type == NFCTagType.mifare_classic;

    // MIFARE Classic/CUID卡：直接使用块级NDEF写入
    // 不依赖NDEF API（因为androidCheckNDEF=false时NDEF方法不可用，
    // 且CUID卡可能未格式化NDEF导致标准写入失败）
    if (isMifareClassic) {
      try {
        final records = _buildNdefRecords();
        await _writeNdefToMifareClassic(tag, records);
        if (!mounted) return;
        setState(() {
          _isWriting = false;
          _statusMessage = '✓ ${_getSuccessMessage()}';
          _mode = _QuickWriteMode.none;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isWriting = false;
          _isWaiting = false;
          _statusMessage = '写入失败：$e';
          _mode = _QuickWriteMode.none;
        });
      }
      return;
    }

    // 非MIFARE Classic卡：需要NDEF API
    // 由于poll时跳过了NDEF检查，需要重新poll启用NDEF
    if (tag.ndefWritable == false) {
      _resetAndReturn('写入失败：该NFC卡已被设为只读模式，无法写入数据');
      return;
    }

    // 重新poll启用NDEF检查
    try {
      await FlutterNfcKit.finish();
      const readerFlags = 0x01 | 0x02 | 0x04 | 0x08 | 0x100;
      final reTag = await FlutterNfcKit.poll(
        androidReaderModeFlags: readerFlags,
        androidPlatformSound: false,
        androidCheckNDEF: true,
      );
      if (!mounted) return;

      if (reTag.ndefAvailable != true) {
        String reason;
        if (tag.type == NFCTagType.mifare_ultralight ||
            tag.type == NFCTagType.mifare_desfire ||
            tag.type == NFCTagType.mifare_plus) {
          reason = '该MIFARE卡不支持NDEF格式，请使用MIFARE扇区读写功能写入底层数据';
        } else {
          reason = '该NFC卡不支持NDEF数据格式，无法进行标准数据写入';
        }
        _resetAndReturn('写入失败：$reason');
        return;
      }

      final records = _buildNdefRecords();
      await FlutterNfcKit.writeNDEFRecords(records);
      if (!mounted) return;
      setState(() {
        _isWriting = false;
        _statusMessage = '✓ ${_getSuccessMessage()}';
        _mode = _QuickWriteMode.none;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isWriting = false;
        _isWaiting = false;
        _statusMessage = '写入失败：$e';
        _mode = _QuickWriteMode.none;
      });
    }
  }

  // ======================================================================
  // MIFARE Classic/CUID卡块级NDEF写入
  // 通过MIFARE扇区认证+块写入方式，直接将NDEF数据写入卡的扇区块中
  // 不依赖NDEF API，适用于CUID卡和未格式化NDEF的MIFARE Classic卡
  // ======================================================================

  Future<void> _writeNdefToMifareClassic(
      NFCTag tag, List<NDEFRecord> records) async {
    // 获取扇区数和块数信息
    final sectorCount = tag.mifareInfo?.sectorCount ??
        (tag.mifareInfo?.blockCount != null
            ? (tag.mifareInfo!.blockCount / 4).ceil()
            : 16);
    final blocksPerSector = tag.mifareInfo?.blockCount != null && sectorCount > 0
        ? (tag.mifareInfo!.blockCount / sectorCount).ceil()
        : 4;

    // 默认认证密钥（CUID卡默认全F密钥）
    const defaultKeyA = 'FFFFFFFFFFFF';

    // 编码NDEF消息为字节数组（使用手动编码，避免ndef包内部null check问题）
    final ndefBytes = _encodeNdefMessage(records);

    // 构建NDEF TLV: 03 <length> <ndef_bytes> FE
    final tlv = <int>[];
    tlv.add(0x03); // NDEF Message TLV类型标记
    if (ndefBytes.length < 255) {
      tlv.add(ndefBytes.length); // 短格式长度
    } else {
      tlv.add(0xFF); // 长格式标记
      tlv.add((ndefBytes.length >> 8) & 0xFF); // 长度高字节
      tlv.add(ndefBytes.length & 0xFF); // 长度低字节
    }
    tlv.addAll(ndefBytes);
    tlv.add(0xFE); // TLV结束标记

    final blockSize = 16;

    // 构建Capability Container（CC）
    // CC格式: E1 10 <max_size> 00 + padding
    // MIFARE Classic 1K: 0x3E (62*8=496字节NDEF空间)
    // MIFARE Classic 4K: 0x60 (96*8=768字节NDEF空间)
    final maxNdefSize = sectorCount <= 16 ? 0x3E : 0x60;
    final cc = Uint8List(blockSize);
    cc[0] = 0xE1; // NDEF映射版本标记
    cc[1] = 0x10; // 映射版本1.0
    cc[2] = maxNdefSize; // 最大NDEF消息大小（8字节为单位）
    cc[3] = 0x00; // 读写访问权限

    // 将NDEF TLV数据分配到各个块中
    final allBlocks = <int, Uint8List>{};

    // 块1：写入CC（Capability Container）
    allBlocks[1] = cc;

    // 从块2开始写入NDEF TLV数据
    int tlvOffset = 0;
    int currentBlock = 2;
    int currentSector = 0;

    while (tlvOffset < tlv.length) {
      // 检查当前块是否是扇区尾（不可写入）
      final blockInSector = currentBlock - currentSector * blocksPerSector;
      if (blockInSector == blocksPerSector - 1) {
        // 跳过扇区尾，进入下一个扇区
        currentSector++;
        currentBlock = currentSector * blocksPerSector;
        continue;
      }

      if (currentSector >= sectorCount) {
        throw Exception('NDEF数据超出卡片容量');
      }

      // 填充一个块的数据
      final blockData = Uint8List(blockSize);
      final remaining = tlv.length - tlvOffset;
      final copyLen = remaining > blockSize ? blockSize : remaining;
      for (var i = 0; i < copyLen; i++) {
        blockData[i] = tlv[tlvOffset + i];
      }
      allBlocks[currentBlock] = blockData;

      tlvOffset += copyLen;
      currentBlock++;
    }

    // 逐块写入数据（先认证再写入）
    final authenticatedSectors = <int>{};
    for (final entry in allBlocks.entries) {
      final blockIdx = entry.key;
      final blockData = entry.value;
      final sector = blockIdx ~/ blocksPerSector;

      // 认证扇区（每个扇区只需认证一次）
      if (!authenticatedSectors.contains(sector)) {
        final ok = await FlutterNfcKit.authenticateSector(
          sector,
          keyA: defaultKeyA,
        );
        if (!ok) {
          throw Exception('扇区$sector 认证失败，请检查密钥是否正确');
        }
        authenticatedSectors.add(sector);
      }

      // 写入块数据
      final hexStr = blockData
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await FlutterNfcKit.writeBlock(blockIdx, hexStr);

      // 写入后立即读取验证，确保数据真正写入到卡片
      final readBack = await FlutterNfcKit.readBlock(blockIdx);
      if (readBack == null || !_bytesEqual(readBack, blockData)) {
        throw Exception('块$blockIdx 写入验证失败：数据未正确写入卡片');
      }
    }
  }

  /// 比较两个字节数组是否相等
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // 根据当前模式构建 NDEF 记录
  List<NDEFRecord> _buildNdefRecords() {
    switch (_mode) {
      case _QuickWriteMode.screencast:
        return [
          UriRecord.fromString('toolapp://screencast'),
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.wifi:
        return [
          WifiRecord(
            ssid: _wifiSsidController.text.trim(),
            networkKey: _wifiAuthType == WifiAuthenticationType.open
                ? null
                : _wifiPasswordController.text.trim(),
            authenticationType: _wifiAuthType,
            encryptionType: _wifiAuthType == WifiAuthenticationType.open
                ? WifiEncryptionType.none
                : WifiEncryptionType.aes,
          ),
          // AAR记录：告诉Android系统应该用本应用来处理此NFC数据，
          // 同时配合AndroidManifest中的intent-filter实现碰卡自动连接
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.vcard:
        final records = <NDEFRecord>[];
        final wechat = _vcardWechatController.text.trim();
        final qq = _vcardQqController.text.trim();

        // 微信/QQ跳转：使用自定义MIME类型 + 本应用AAR记录
        // 修复：不再使用weixin://或mqqwpa://的URI记录 + 第三方AAR
        // 原因：1.微信/QQ没有注册NDEF_DISCOVERED的intent-filter，无法接收NDEF数据
        //       2.Android 16上自定义scheme的NDEF匹配不可靠
        //       3.AAR指向第三方应用时，第三方应用不处理NDEF，系统弹出默认对话框
        // 新方案：写入自定义MIME类型(application/vnd.com.example.toolapp.nfc)
        //         payload为JSON格式包含跳转类型和参数
        //         AAR指向本应用，确保本应用100%接收到NFC intent
        //         本应用解析JSON后通过ACTION_VIEW转发给微信/QQ
        // 构建JSON payload
        final jsonData = <String, dynamic>{};
        if (wechat.isNotEmpty) {
          jsonData['type'] = 'wechat';
          jsonData['id'] = wechat;
        } else if (qq.isNotEmpty) {
          jsonData['type'] = 'qq';
          jsonData['id'] = qq;
        }

        final jsonBytes = utf8.encode(jsonEncode(jsonData));
        final mimeRecord = MimeRecord(decodedType: 'application/vnd.com.example.toolapp.nfc');
        mimeRecord.payload = Uint8List.fromList(jsonBytes);
        records.add(mimeRecord);
        // AAR指向本应用，确保碰卡时本应用能接收到NFC数据
        records.add(AARRecord(packageName: 'com.example.toolapp'));
        return records;

      case _QuickWriteMode.navigate:
        // 导航速写：使用自定义MIME类型写入导航软件+目的地JSON
        // 导航软件标识：amap=高德, baidu=百度, tencent=腾讯
        final navAppIds = ['amap', 'baidu', 'tencent'];
        final navQuery = _navNameController.text.trim();
        final jsonData = <String, dynamic>{
          'type': 'navigate',
          'app': navAppIds[_navAppIndex],
          'query': navQuery,
        };
        final navJsonBytes = utf8.encode(jsonEncode(jsonData));
        final navMimeRecord = MimeRecord(decodedType: 'application/vnd.com.example.toolapp.nfc');
        navMimeRecord.payload = Uint8List.fromList(navJsonBytes);
        return [
          navMimeRecord,
          // AAR记录：确保本应用接收NFC数据，解析JSON后转发给指定导航软件
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.payment:
        // 支付跳转：使用自定义MIME类型 + 本应用AAR
        // 与微信/QQ同理，不再直接写URI+第三方AAR
        final jsonData = <String, dynamic>{};
        if (_paymentType == 0) {
          jsonData['type'] = 'alipay';
        } else {
          jsonData['type'] = 'wechat_pay';
        }
        final jsonBytes = utf8.encode(jsonEncode(jsonData));
        final mimeRecord = MimeRecord(decodedType: 'application/vnd.com.example.toolapp.nfc');
        mimeRecord.payload = Uint8List.fromList(jsonBytes);
        return [
          mimeRecord,
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.home:
        final addr = Uri.encodeComponent(_homeAddrController.text.trim());
        final ssid = Uri.encodeComponent(_homeWifiSsidController.text.trim());
        final pwd = Uri.encodeComponent(_homeWifiPwdController.text.trim());
        return [
          UriRecord.fromString('toolapp://home?addr=$addr&ssid=$ssid&pwd=$pwd'),
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.text:
        // 手动设置语言为中文，避免ndef包编码时language!空值错误
        return [
          TextRecord(language: 'zh', text: _textController.text.trim()),
          // AAR记录：确保文本模式的NFC数据能被本应用捕获
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.url:
        return [
          UriRecord.fromString(_urlController.text.trim()),
          // AAR记录：确保URL模式的NFC数据能被本应用捕获并自动跳转
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      default:
        return [];
    }
  }

  // ======================================================================
  // 手动NDEF编码：绕过ndef包内部编码中的null check问题
  // 直接构建NDEF记录二进制格式，适用于CUID/MIFARE Classic卡
  // ======================================================================

  /// NDEF记录Flags常量
  static const int _ndefFlagMB = 0x80; // 消息开始
  static const int _ndefFlagME = 0x40; // 消息结束
  static const int _ndefFlagSR = 0x10; // 短记录标记
  static const int _ndefTNF_WellKnown = 0x01; // NFC Forum Well-Known类型
  static const int _ndefTNF_Media = 0x02; // MIME媒体类型
  static const int _ndefTNF_External = 0x04; // NFC Forum外部类型

  /// 手动编码NDEF消息为字节数组
  /// 直接构建二进制NDEF格式，不依赖ndef包的encode()方法
  Uint8List _encodeNdefMessage(List<NDEFRecord> records) {
    final allBytes = <int>[];
    for (int i = 0; i < records.length; i++) {
      final record = records[i];
      final isFirst = i == 0;
      final isLast = i == records.length - 1;

      final ndefBytes = _encodeSingleNdefRecord(record, isFirst: isFirst, isLast: isLast);
      allBytes.addAll(ndefBytes);
    }
    return Uint8List.fromList(allBytes);
  }

  /// 编码单个NDEF记录为二进制格式
  Uint8List _encodeSingleNdefRecord(NDEFRecord record, {required bool isFirst, required bool isLast}) {
    // 获取TNF和类型：根据记录类型显式设置正确的TNF
    TypeNameFormat tnf;
    if (record is TextRecord || record is UriRecord) {
      tnf = TypeNameFormat.nfcWellKnown;
    } else if (record is WifiRecord || record is MimeRecord) {
      tnf = TypeNameFormat.media;
    } else if (record is AARRecord) {
      tnf = TypeNameFormat.nfcExternal;
    } else {
      tnf = record.tnf;
    }
    final type = _getNdefRecordType(record);
    final payload = _getNdefRecordPayload(record);

    // 构建Flags字节（低3位为TNF值）
    int flags = 0;
    if (isFirst) flags |= _ndefFlagMB;
    if (isLast) flags |= _ndefFlagME;
    if (payload.length < 256) flags |= _ndefFlagSR; // 短记录

    switch (tnf) {
      case TypeNameFormat.nfcWellKnown:
        flags |= 0x01;
        break;
      case TypeNameFormat.media:
        flags |= 0x02;
        break;
      case TypeNameFormat.nfcExternal:
        flags |= 0x04;
        break;
      default:
        break;
    }

    final encoded = <int>[];
    encoded.add(flags); // 第1字节：Flags
    encoded.add(type.length); // 第2字节：类型长度

    // 载荷长度
    if (payload.length < 256) {
      encoded.add(payload.length); // 第3字节：短格式载荷长度
    } else {
      encoded.add((payload.length >> 24) & 0xFF);
      encoded.add((payload.length >> 16) & 0xFF);
      encoded.add((payload.length >> 8) & 0xFF);
      encoded.add(payload.length & 0xFF);
    }

    // 类型
    encoded.addAll(type);

    // 载荷
    encoded.addAll(payload);

    return Uint8List.fromList(encoded);
  }

  /// 获取NDEF记录的类型字节
  Uint8List _getNdefRecordType(NDEFRecord record) {
    // 根据NDEF规范，各记录类型有标准的类型标识符
    if (record is TextRecord) {
      return Uint8List.fromList(utf8.encode('T')); // NFC Forum Well-Known: Text
    } else if (record is UriRecord) {
      return Uint8List.fromList(utf8.encode('U')); // NFC Forum Well-Known: URI
    } else if (record is AARRecord) {
      return Uint8List.fromList(utf8.encode('android.com:pkg')); // NFC Forum External: AAR
    } else if (record is WifiRecord) {
      return Uint8List.fromList(utf8.encode('application/vnd.wfa.wsc')); // MIME类型: WiFi配置
    } else if (record is MimeRecord) {
      final decodedType = record.decodedType;
      if (decodedType != null && decodedType.isNotEmpty) {
        return Uint8List.fromList(utf8.encode(decodedType));
      }
    }
    // 回退到decodedType
    final decodedType = record.decodedType;
    if (decodedType != null && decodedType.isNotEmpty) {
      return Uint8List.fromList(utf8.encode(decodedType));
    }
    return Uint8List(0);
  }

  /// 获取NDEF记录的载荷字节
  Uint8List _getNdefRecordPayload(NDEFRecord record) {
    // 根据记录类型手动构建载荷，避免ndef包内部编码时的null check问题
    if (record is TextRecord) {
      return _encodeTextRecordPayload(record);
    } else if (record is UriRecord) {
      return _encodeUriRecordPayload(record);
    } else if (record is AARRecord) {
      return _encodeAARRecordPayload(record);
    } else if (record is WifiRecord) {
      return _encodeWifiRecordPayload(record);
    } else if (record is MimeRecord) {
      return _encodeMimeRecordPayload(record);
    }

    // 回退：尝试ndef包自身的payload
    final payload = record.payload;
    if (payload != null) {
      return payload;
    }
    return Uint8List(0);
  }

  /// 编码TextRecord载荷
  /// 格式: [状态字节] [语言代码] [文本UTF-8]
  /// 状态字节: bit7=编码(0=UTF8), bit5-0=语言代码长度
  Uint8List _encodeTextRecordPayload(TextRecord record) {
    final text = record.text ?? '';
    final language = record.language ?? 'en';
    final languageBytes = utf8.encode(language);
    final textBytes = utf8.encode(text);

    // 状态字节：UTF-8编码(bit7=0) + 语言代码长度
    final statusByte = languageBytes.length & 0x3F;

    return Uint8List.fromList([statusByte, ...languageBytes, ...textBytes]);
  }

  /// 编码UriRecord载荷
  /// 格式: [前缀代码] [剩余URI UTF-8]
  Uint8List _encodeUriRecordPayload(UriRecord record) {
    final iriString = record.iriString ?? '';
    if (iriString.isEmpty) {
      return Uint8List.fromList([0x00]);
    }

    // 使用ndef包的prefixMap进行前缀压缩
    for (int i = 1; i < UriRecord.prefixMap.length; i++) {
      final prefix = UriRecord.prefixMap[i];
      if (iriString.startsWith(prefix)) {
        final remaining = iriString.substring(prefix.length);
        return Uint8List.fromList([i, ...utf8.encode(remaining)]);
      }
    }

    // 无匹配前缀，使用0x00（无前缀）
    return Uint8List.fromList([0x00, ...utf8.encode(iriString)]);
  }

  /// 编码AARRecord载荷
  /// 格式: [包名字符串UTF-8]
  Uint8List _encodeAARRecordPayload(AARRecord record) {
    return Uint8List.fromList(utf8.encode(record.packageName ?? ''));
  }

  /// 编码MimeRecord载荷
  Uint8List _encodeMimeRecordPayload(MimeRecord record) {
    return record.payload ?? Uint8List(0);
  }

  /// 编码WifiRecord载荷
  /// 使用WSC (WiFi Simple Configuration) TLV格式
  Uint8List _encodeWifiRecordPayload(WifiRecord record) {
    final ssid = record.ssid ?? '';
    final networkKey = record.networkKey ?? '';
    final authType = record.authenticationType;
    final encType = record.encryptionType;

    // WSC TLV属性
    const attrCredential = 0x100E;
    const attrSsid = 0x1045;
    const attrNetworkKey = 0x1027;
    const attrAuthType = 0x1003;
    const attrEncryptionType = 0x100F;

    // 构建TLV的方法
    Uint8List buildTLV(int type, Uint8List value) {
      final result = <int>[];
      result.add((type >> 8) & 0xFF);
      result.add(type & 0xFF);
      result.add((value.length >> 8) & 0xFF);
      result.add(value.length & 0xFF);
      result.addAll(value);
      return Uint8List.fromList(result);
    }

    final credentialData = <int>[];

    // SSID
    credentialData.addAll(buildTLV(attrSsid, Uint8List.fromList(utf8.encode(ssid))));

    // 认证类型 (2字节)
    final authBytes = Uint8List(2);
    authBytes[0] = (authType.wscValue >> 8) & 0xFF;
    authBytes[1] = authType.wscValue & 0xFF;
    credentialData.addAll(buildTLV(attrAuthType, authBytes));

    // 加密类型 (2字节)
    final encBytes = Uint8List(2);
    encBytes[0] = (encType.wscValue >> 8) & 0xFF;
    encBytes[1] = encType.wscValue & 0xFF;
    credentialData.addAll(buildTLV(attrEncryptionType, encBytes));

    // 网络密钥（非开放网络时）
    if (authType != WifiAuthenticationType.open && networkKey.isNotEmpty) {
      credentialData.addAll(buildTLV(attrNetworkKey, Uint8List.fromList(utf8.encode(networkKey))));
    }

    // 凭证容器
    final credBytes = Uint8List.fromList(credentialData);
    final result = <int>[];
    result.add((attrCredential >> 8) & 0xFF);
    result.add(attrCredential & 0xFF);
    result.add((credBytes.length >> 8) & 0xFF);
    result.add(credBytes.length & 0xFF);
    result.addAll(credBytes);

    return Uint8List.fromList(result);
  }

  // 获取写入成功提示信息
  String _getSuccessMessage() {
    switch (_mode) {
      case _QuickWriteMode.screencast:
        return '投屏速写写入成功！碰卡即可启动投屏';
      case _QuickWriteMode.wifi:
        return 'WiFi速写写入成功！碰卡即可自动连接WiFi';
      case _QuickWriteMode.vcard:
        return '微信QQ写入成功！碰卡即可自动打开微信/QQ';
      case _QuickWriteMode.navigate:
        return '导航速写写入成功！碰卡即可打开选中的导航软件';
      case _QuickWriteMode.payment:
        return '付款速写写入成功！碰卡即可打开付款码';
      case _QuickWriteMode.home:
        return '回家模式写入成功！碰卡即可执行回家指令';
      default:
        return '写入成功！';
    }
  }

  void _resetAndReturn(String message) {
    if (!mounted) return;
    setState(() {
      _isWriting = false;
      _isWaiting = false;
      _statusMessage = message;
      _mode = _QuickWriteMode.none;
    });
  }

  void _cancelWait() {
    _finishSession();
    if (!mounted) return;
    setState(() {
      _isWaiting = false;
      _isWriting = false;
      _statusMessage = '';
      _mode = _QuickWriteMode.none;
    });
  }

  // ======================================================================
  // UI 构建
  // ======================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('功能速写'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isWaiting) return _buildWaitingView();
    if (_isWriting) return _buildWritingView();
    if (_statusMessage.isNotEmpty) return _buildResultView();
    return _buildCardsView();
  }

  // 速写卡片主界面
  Widget _buildCardsView() {
    if (_availability == NFCAvailability.not_supported) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.nfc, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('该设备不支持NFC功能',
                style: TextStyle(fontSize: 16, color: Colors.grey[600])),
          ],
        ),
      );
    }
    if (_availability == NFCAvailability.disabled) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.nfc, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('NFC功能未开启',
                style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('请在系统设置中打开NFC开关',
                style: TextStyle(fontSize: 13, color: Colors.grey[500])),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text('选择写入类型',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[800])),
                const SizedBox(width: 8),
                Text('点击卡片输入内容',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
          Expanded(
            child: GridView(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              children: [
                // ===== 基础写入 =====
                _buildToolCard(
                  icon: Icons.link,
                  title: '网址写入',
                  subtitle: '碰卡自动打开链接',
                  color: const Color(0xFF1E88E5),
                  onTap: () => _showInputDialog(_QuickWriteMode.url),
                ),
                _buildToolCard(
                  icon: Icons.text_fields,
                  title: '文本写入',
                  subtitle: '文字写入NFC标签',
                  color: const Color(0xFF43A047),
                  onTap: () => _showInputDialog(_QuickWriteMode.text),
                ),

                // ===== 功能速写（已修复碰卡跳转） =====
                _buildToolCard(
                  icon: Icons.wifi,
                  title: 'WiFi 速写',
                  subtitle: '碰卡连接WiFi',
                  color: const Color(0xFF1565C0),
                  onTap: _showWifiInputDialog,
                ),
                _buildToolCard(
                  icon: Icons.contact_page,
                  title: '微信QQ',
                  subtitle: '碰卡打开微信/QQ',
                  color: const Color(0xFF6A1B9A),
                  onTap: _showVcardInputDialog,
                ),
                _buildToolCard(
                  icon: Icons.navigation,
                  title: '导航速写',
                  subtitle: '碰卡打开导航',
                  color: const Color(0xFF00897B),
                  onTap: _showNavigateInputDialog,
                ),

                // ===== 功能速写（Beta，碰卡跳转待修复） =====
                _buildToolCard(
                  icon: Icons.cast,
                  title: '投屏速写 Beta',
                  subtitle: '碰卡启动投屏',
                  color: const Color(0xFFE65100),
                  onTap: _startScreencastWrite,
                ),
                _buildToolCard(
                  icon: Icons.payment,
                  title: '付款速写 Beta',
                  subtitle: '碰卡打开付款码',
                  color: const Color(0xFF2E7D32),
                  onTap: _showPaymentSelectSheet,
                ),
                _buildToolCard(
                  icon: Icons.home,
                  title: '回家模式 Beta',
                  subtitle: '碰卡执行组合指令',
                  color: const Color(0xFFD84315),
                  onTap: _showHomeInputDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 构建速写卡片
  Widget _buildToolCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const Spacer(),
              // 标题
              Text(title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: color)),
              const SizedBox(height: 4),
              // 副标题
              Text(subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
        ),
      ),
    );
  }

  // 等待NFC卡靠近视图
  Widget _buildWaitingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 2000),
                    builder: (context, value, child) {
                      return Container(
                        width: 90 + value * 50,
                        height: 90 + value * 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.blue.withValues(alpha: (1.0 - value) * 0.4),
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
                        width: 80 + value * 30,
                        height: 80 + value * 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.blue.withValues(alpha: (1.0 - value) * 0.25),
                            width: 1.5,
                          ),
                        ),
                      );
                    },
                  ),
                  Icon(Icons.nfc, size: 56, color: Colors.blue[400]),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(_statusMessage,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(
              '正在等待写入${_getModeHint()}…',
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: _cancelWait,
              icon: const Icon(Icons.cancel, size: 18),
              label: const Text('取消写入'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: BorderSide(color: Colors.red[200]!),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 获取当前模式的提示文字
  String _getModeHint() {
    switch (_mode) {
      case _QuickWriteMode.screencast:
        return '投屏指令';
      case _QuickWriteMode.wifi:
        return 'WiFi配置';
      case _QuickWriteMode.vcard:
        return '微信QQ';
      case _QuickWriteMode.navigate:
        return '导航指令';
      case _QuickWriteMode.payment:
        return '付款码指令';
      case _QuickWriteMode.home:
        return '回家模式指令';
      case _QuickWriteMode.text:
        return '文本内容';
      case _QuickWriteMode.url:
        return '网址';
      default:
        return '数据';
    }
  }

  // 写入中视图
  Widget _buildWritingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 24),
          Text(_statusMessage,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text('请保持NFC卡靠近手机',
              style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        ],
      ),
    );
  }

  // 结果视图
  Widget _buildResultView() {
    final isSuccess = _statusMessage.startsWith('✓');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSuccess ? Icons.check_circle_outline : Icons.error_outline,
              size: 72,
              color: isSuccess ? Colors.green : Colors.red[400],
            ),
            const SizedBox(height: 20),
            Text(
              isSuccess ? '写入成功' : '写入失败',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: isSuccess ? Colors.green[700] : Colors.red[700]),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isSuccess ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSuccess ? Colors.green.shade200 : Colors.red.shade200,
                ),
              ),
              child: Text(
                _statusMessage.replaceFirst('✓ ', ''),
                style: TextStyle(
                  fontSize: 13,
                  color: isSuccess ? Colors.green[800] : Colors.red[800],
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() => _statusMessage = '');
                  },
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('继续写入'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('返回'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
