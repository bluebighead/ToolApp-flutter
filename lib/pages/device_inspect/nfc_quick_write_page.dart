import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart';
import 'package:ndef/records/media/wifi.dart';

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

  // 名片速写输入控制器
  final _vcardNameController = TextEditingController();
  final _vcardPhoneController = TextEditingController();
  final _vcardEmailController = TextEditingController();
  final _vcardOrgController = TextEditingController();
  final _vcardWechatController = TextEditingController();
  final _vcardQqController = TextEditingController();

  // 导航速写输入控制器
  final _navNameController = TextEditingController();
  final _navLatController = TextEditingController();
  final _navLngController = TextEditingController();

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
    _vcardNameController.dispose();
    _vcardPhoneController.dispose();
    _vcardEmailController.dispose();
    _vcardOrgController.dispose();
    _vcardWechatController.dispose();
    _vcardQqController.dispose();
    _navNameController.dispose();
    _navLatController.dispose();
    _navLngController.dispose();
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
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

                  // WiFi 密码输入
                  TextField(
                    controller: _wifiPasswordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'WiFi 密码',
                      hintText: '输入WiFi密码',
                      prefixIcon: const Icon(Icons.lock, size: 20),
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
  // 名片速写：输入联系人信息弹窗
  // ======================================================================

  void _showVcardInputDialog() {
    if (!_checkNfcAvailable()) return;

    _vcardNameController.clear();
    _vcardPhoneController.clear();
    _vcardEmailController.clear();
    _vcardOrgController.clear();
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
            final hasWechat = _vcardWechatController.text.trim().isNotEmpty;
            final hasQq = _vcardQqController.text.trim().isNotEmpty;
            final wechatDisabled = hasQq;
            final qqDisabled = hasWechat;

            return Padding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
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
                      const Text('名片速写', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('碰卡即可添加联系人，适合商务社交',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 16),

                  // 姓名输入
                  TextField(
                    controller: _vcardNameController,
                    decoration: InputDecoration(
                      labelText: '姓名 *',
                      hintText: '输入联系人姓名',
                      prefixIcon: const Icon(Icons.person, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 电话输入
                  TextField(
                    controller: _vcardPhoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: '电话 *',
                      hintText: '输入手机号码',
                      prefixIcon: const Icon(Icons.phone, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 邮箱输入
                  TextField(
                    controller: _vcardEmailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: '邮箱',
                      hintText: '输入电子邮箱（选填）',
                      prefixIcon: const Icon(Icons.email, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 公司输入
                  TextField(
                    controller: _vcardOrgController,
                    decoration: InputDecoration(
                      labelText: '公司',
                      hintText: '输入公司名称（选填）',
                      prefixIcon: const Icon(Icons.business, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 微信号输入
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
                    onChanged: (_) => setModalState(() {}),
                  ),
                  const SizedBox(height: 10),

                  // QQ号输入
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
                    onChanged: (_) => setModalState(() {}),
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
                        if (_vcardNameController.text.trim().isEmpty ||
                            _vcardPhoneController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('请填写姓名和电话')),
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        _enterWriteMode(_QuickWriteMode.vcard, '名片信息');
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
    _navLatController.clear();
    _navLngController.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
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
              Text('碰卡即可打开地图导航到目的地，适合车内使用',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 16),

              // 目的地名称
              TextField(
                controller: _navNameController,
                decoration: InputDecoration(
                  labelText: '目的地名称',
                  hintText: '如: 家、公司',
                  prefixIcon: const Icon(Icons.place, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),

              // 经纬度输入
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _navLatController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: '纬度 *',
                        hintText: '如: 39.9042',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _navLngController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: '经度 *',
                        hintText: '如: 116.4074',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 提示：如何获取经纬度
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.help_outline, size: 16, color: Colors.teal[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '如何获取经纬度：在高德/百度地图中长按目的地，即可看到坐标',
                        style: TextStyle(fontSize: 11, color: Colors.teal[700], height: 1.5),
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
                    if (_navLatController.text.trim().isEmpty ||
                        _navLngController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入经纬度坐标')),
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
        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
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

  Future<void> _doPoll() async {
    try {
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

    // 通用可写性检查
    if (tag.ndefWritable == false) {
      _resetAndReturn('写入失败：该NFC卡已被设为只读模式，无法写入数据');
      return;
    }
    if (tag.ndefAvailable != true) {
      String reason;
      if (tag.type == NFCTagType.mifare_classic ||
          tag.type == NFCTagType.mifare_ultralight ||
          tag.type == NFCTagType.mifare_desfire ||
          tag.type == NFCTagType.mifare_plus) {
        reason = '该MIFARE卡不支持NDEF格式，请使用MIFARE扇区读写功能写入底层数据';
      } else {
        reason = '该NFC卡不支持NDEF数据格式，无法进行标准数据写入';
      }
      _resetAndReturn('写入失败：$reason');
      return;
    }

    // 根据模式构建不同的 NDEF 记录
    try {
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

  // 根据当前模式构建 NDEF 记录
  List<NDEFRecord> _buildNdefRecords() {
    switch (_mode) {
      case _QuickWriteMode.screencast:
        // 投屏速写：URI + AAR 记录
        return [
          UriRecord.fromString('toolapp://screencast'),
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.wifi:
        // WiFi 速写：WiFi 配置记录 + AAR 记录
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
        ];

      case _QuickWriteMode.vcard:
        // 名片速写：vCard MIME 记录 + 微信/QQ URI 记录
        final records = <NDEFRecord>[];
        final vcard = _buildVcardString();
        final vcardBytes = utf8.encode(vcard);
        final mimeRecord = MimeRecord(decodedType: 'text/vcard');
        mimeRecord.payload = Uint8List.fromList(vcardBytes);
        records.add(mimeRecord);

        final wechat = _vcardWechatController.text.trim();
        final qq = _vcardQqController.text.trim();
        if (wechat.isNotEmpty) {
          records.add(UriRecord.fromString('weixin://'));
        }
        if (qq.isNotEmpty) {
          records.add(UriRecord.fromString('mqq://card/addfriend?uin=$qq'));
        }
        return records;

      case _QuickWriteMode.navigate:
        // 导航速写：geo URI 记录
        final lat = _navLatController.text.trim();
        final lng = _navLngController.text.trim();
        final name = _navNameController.text.trim();
        // Android 标准 geo URI，地图App均可识别
        final geoUri = name.isNotEmpty
            ? 'geo:$lat,$lng?q=$lat,$lng($name)'
            : 'geo:$lat,$lng';
        return [UriRecord.fromString(geoUri)];

      case _QuickWriteMode.payment:
        // 付款速写：支付宝/微信付款码 URI + AAR 记录
        final uri = _paymentType == 0
            ? 'alipays://platformapi/startapp?appId=20000056' // 支付宝付款码
            : 'weixin://wap/pay'; // 微信付款
        return [
          UriRecord.fromString(uri),
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.home:
        // 回家模式：自定义 deep link URI + AAR 记录
        // 将参数编码到 URI 中，App 收到后解析并执行组合动作
        final addr = Uri.encodeComponent(_homeAddrController.text.trim());
        final ssid = Uri.encodeComponent(_homeWifiSsidController.text.trim());
        final pwd = Uri.encodeComponent(_homeWifiPwdController.text.trim());
        return [
          UriRecord.fromString('toolapp://home?addr=$addr&ssid=$ssid&pwd=$pwd'),
          AARRecord(packageName: 'com.example.toolapp'),
        ];

      case _QuickWriteMode.text:
        return [TextRecord(text: _textController.text.trim())];

      case _QuickWriteMode.url:
        return [UriRecord.fromString(_urlController.text.trim())];

      default:
        return [];
    }
  }

  // 构建 vCard 字符串（标准 vCard 3.0 格式）
  String _buildVcardString() {
    final name = _vcardNameController.text.trim();
    final phone = _vcardPhoneController.text.trim();
    final email = _vcardEmailController.text.trim();
    final org = _vcardOrgController.text.trim();
    final wechat = _vcardWechatController.text.trim();
    final qq = _vcardQqController.text.trim();

    final buffer = StringBuffer();
    buffer.writeln('BEGIN:VCARD');
    buffer.writeln('VERSION:3.0');
    buffer.writeln('FN:$name');
    if (phone.isNotEmpty) buffer.writeln('TEL:$phone');
    if (email.isNotEmpty) buffer.writeln('EMAIL:$email');
    if (org.isNotEmpty) buffer.writeln('ORG:$org');
    if (wechat.isNotEmpty) buffer.writeln('X-WECHAT:$wechat');
    if (qq.isNotEmpty) buffer.writeln('X-QQ:$qq');
    buffer.writeln('END:VCARD');
    return buffer.toString();
  }

  // 获取写入成功提示信息
  String _getSuccessMessage() {
    switch (_mode) {
      case _QuickWriteMode.screencast:
        return '投屏速写写入成功！碰卡即可启动投屏';
      case _QuickWriteMode.wifi:
        return 'WiFi速写写入成功！碰卡即可自动连接WiFi';
      case _QuickWriteMode.vcard:
        final hasSocial = _vcardWechatController.text.trim().isNotEmpty ||
            _vcardQqController.text.trim().isNotEmpty;
        return hasSocial
            ? '名片速写写入成功！碰卡即可添加联系人，自动打开微信/QQ'
            : '名片速写写入成功！碰卡即可添加联系人';
      case _QuickWriteMode.navigate:
        return '导航速写写入成功！碰卡即可打开地图导航';
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
                // 基础写入
                _buildToolCard(
                  icon: Icons.link,
                  title: '网址写入',
                  subtitle: '链接写入NFC标签',
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

                // 功能速写
                _buildToolCard(
                  icon: Icons.cast,
                  title: '投屏速写',
                  subtitle: '碰卡启动投屏',
                  color: const Color(0xFFE65100),
                  onTap: _startScreencastWrite,
                ),
                _buildToolCard(
                  icon: Icons.wifi,
                  title: 'WiFi 速写',
                  subtitle: '碰卡连接WiFi',
                  color: const Color(0xFF1565C0),
                  onTap: _showWifiInputDialog,
                ),
                _buildToolCard(
                  icon: Icons.contact_page,
                  title: '名片速写',
                  subtitle: '碰卡添加联系人',
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
                _buildToolCard(
                  icon: Icons.payment,
                  title: '付款速写',
                  subtitle: '碰卡打开付款码',
                  color: const Color(0xFF2E7D32),
                  onTap: _showPaymentSelectSheet,
                ),
                _buildToolCard(
                  icon: Icons.home,
                  title: '回家模式',
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
        return '名片信息';
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
