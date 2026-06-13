// 账号设置页面
// 由侧边栏顶部的"实用工具箱"图标进入
// 包含：登录/注册、账号信息、修改密码、登录设备管理、登出
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import '../auth/forgot_password_page.dart';
import '../auth/login_page.dart';
import '../auth/register_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  List<Map<String, dynamic>> _devices = [];
  bool _loadingDevices = false;

  @override
  void initState() {
    super.initState();
    if (AuthService.instance.isLoggedIn) {
      _loadDevices();
    }
  }

  // 加载登录设备列表
  Future<void> _loadDevices() async {
    setState(() => _loadingDevices = true);
    try {
      final devices = await AuthService.instance.getDevices();
      if (mounted) {
        setState(() => _devices = devices);
      }
    } catch (e) {
      AppLogger.e('AccountPage', '加载设备列表失败: $e');
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  // 踢出设备
  Future<void> _kickDevice(String deviceToken, String deviceInfo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认踢出'),
        content: Text('确定要踢出设备 "$deviceInfo" 吗？该设备将被强制退出登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认踢出')),
        ],
      ),
    );

    if (confirmed != true) return;

    final error = await AuthService.instance.kickDevice(deviceToken);
    if (!mounted) return;

    if (error == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已踢出该设备')));
      _loadDevices();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  // 登出
  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认登出'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认登出')),
        ],
      ),
    );

    if (confirmed != true) return;

    await AuthService.instance.signOut();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = AuthService.instance.isLoggedIn;
    final isGuest = AuthService.instance.isGuestMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号与安全'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 账号状态卡片
            _buildAccountCard(theme, isLoggedIn, isGuest),
            const SizedBox(height: 16),

            // 已登录时显示的功能列表
            if (isLoggedIn) ...[
              // 修改密码
              _buildMenuCard(
                icon: Icons.lock_outline,
                title: '修改密码',
                subtitle: '更改当前账号的登录密码',
                onTap: () => _showChangePasswordDialog(),
              ),
              const SizedBox(height: 12),

              // 登录设备管理
              _buildDeviceSection(theme),
              const SizedBox(height: 12),

              // 忘记密码
              _buildMenuCard(
                icon: Icons.help_outline,
                title: '忘记密码',
                subtitle: '通过邮箱验证码重置密码',
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordPage()));
                },
              ),
              const SizedBox(height: 12),

              // 登出按钮
              FilledButton.tonal(
                onPressed: _signOut,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red.shade700,
                ),
                child: const Text('退出登录', style: TextStyle(fontSize: 15)),
              ),
            ],

            // 未登录时显示登录/注册按钮
            if (!isLoggedIn && !isGuest) ...[
              FilledButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
                },
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('登录', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage()));
                },
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('注册新账号', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordPage()));
                },
                child: const Text('忘记密码？'),
              ),
            ],

            // 游客模式时显示登录提示
            if (isGuest) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Column(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange.shade700, size: 32),
                    const SizedBox(height: 8),
                    Text(
                      '当前为游客模式',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange.shade700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '数据仅保存在本地，登录后可同步到服务器',
                      style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  AuthService.instance.exitGuestMode();
                },
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('登录账号', style: TextStyle(fontSize: 16)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 账号状态卡片
  Widget _buildAccountCard(ThemeData theme, bool isLoggedIn, bool isGuest) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLoggedIn
              ? [theme.colorScheme.primary, theme.colorScheme.primary.withValues(alpha: 0.8)]
              : [Colors.grey.shade400, Colors.grey.shade500],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // 头像
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.white.withValues(alpha: 0.3),
            child: Icon(
              isLoggedIn ? Icons.person : (isGuest ? Icons.person_outline : Icons.person_off),
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(height: 12),
          // 邮箱/状态
          Text(
            isLoggedIn ? (AuthService.instance.userEmail ?? '已登录') : (isGuest ? '游客模式' : '未登录'),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            isLoggedIn ? '账号状态正常' : (isGuest ? '数据仅保存在本地' : '登录以同步数据'),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
          ),
        ],
      ),
    );
  }

  // 菜单卡片
  Widget _buildMenuCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  // 登录设备管理区域
  Widget _buildDeviceSection(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Icon(Icons.devices, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text('登录设备', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_loadingDevices)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _loadDevices,
                    tooltip: '刷新设备列表',
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // 设备列表
            if (_devices.isEmpty && !_loadingDevices)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无登录设备记录', style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
              )
            else
              ..._devices.map((device) {
                final isCurrent = device['isCurrentDevice'] == true;
                final deviceInfo = device['device_info'] as String? ?? '未知设备';
                final lastActive = device['last_active'] as String? ?? '';
                final token = device['device_token'] as String? ?? '';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isCurrent ? theme.colorScheme.primary.withValues(alpha: 0.05) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isCurrent ? theme.colorScheme.primary.withValues(alpha: 0.3) : Colors.grey.shade200,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isCurrent ? Icons.phone_android : Icons.devices_other,
                        color: isCurrent ? theme.colorScheme.primary : Colors.grey,
                        size: 24,
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
                                    deviceInfo,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: isCurrent ? theme.colorScheme.primary : null,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isCurrent) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('当前', style: TextStyle(color: Colors.white, fontSize: 10)),
                                  ),
                                ],
                              ],
                            ),
                            if (lastActive.isNotEmpty)
                              Text(
                                '最后活跃: $lastActive',
                                style: const TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                          ],
                        ),
                      ),
                      // 非当前设备显示踢出按钮
                      if (!isCurrent)
                        IconButton(
                          icon: Icon(Icons.logout, size: 18, color: Colors.red.shade400),
                          onPressed: () => _kickDevice(token, deviceInfo),
                          tooltip: '踢出该设备',
                        ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  // 修改密码对话框
  void _showChangePasswordDialog() {
    final oldPwdController = TextEditingController();
    final newPwdController = TextEditingController();
    final confirmPwdController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '当前密码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '新密码（至少6位）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '确认新密码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final oldPwd = oldPwdController.text;
              final newPwd = newPwdController.text;
              final confirmPwd = confirmPwdController.text;

              if (oldPwd.isEmpty || newPwd.isEmpty || confirmPwd.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写所有字段')));
                return;
              }
              if (newPwd.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('新密码至少需要6位')));
                return;
              }
              if (newPwd != confirmPwd) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('两次输入的新密码不一致')));
                return;
              }

              Navigator.pop(ctx);
              final error = await AuthService.instance.changePassword(oldPwd, newPwd);
              if (!mounted) return;
              if (error == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码修改成功')));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
              }
            },
            child: const Text('确认修改'),
          ),
        ],
      ),
    );
  }
}
