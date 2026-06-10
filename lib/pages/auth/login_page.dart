// 登录页面
// 邮箱+密码登录，底部提供"注册新账号"和"游客模式"入口
// 登录成功后 AuthWrapper 自动切换到首页
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // 邮箱和密码输入控制器
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  // 是否正在登录中（防止重复点击）
  bool _isLoading = false;

  // 密码是否可见
  bool _obscurePassword = true;

  // 是否记住密码
  bool _rememberMe = false;

  // 服务器扫描状态
  bool _isScanning = false;
  String _scanStatus = '';

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  // 加载保存的账号密码
  Future<void> _loadSavedCredentials() async {
    final rememberMe = await AuthService.instance.isRememberMe();
    if (rememberMe) {
      final email = await AuthService.instance.getSavedEmail();
      final password = await AuthService.instance.getSavedPassword();
      if (mounted) {
        setState(() {
          _rememberMe = true;
          if (email != null) _emailController.text = email;
          if (password != null) _passwordController.text = password;
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // 执行登录
  Future<void> _onLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    // 输入校验
    if (email.isEmpty || password.isEmpty) {
      _showSnackBar('请输入邮箱和密码');
      return;
    }

    setState(() => _isLoading = true);

    // 调用认证服务登录
    final error = await AuthService.instance.signIn(
      email: email,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (error != null) {
      _showSnackBar(error);
    } else {
      // 登录成功，根据"记住密码"选项保存或清除凭证
      if (_rememberMe) {
        await AuthService.instance.saveCredentials(email, password);
      } else {
        await AuthService.instance.clearCredentials();
      }
    }
    // 登录成功时 AuthWrapper 会自动切换页面，无需手动跳转
  }

  // 跳转注册页面
  void _onGoRegister() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterPage()),
    );
  }

  // 以游客身份进入应用
  Future<void> _onGuestMode() async {
    await AuthService.instance.enterGuestMode();
    if (!mounted) return;
    // AuthWrapper 会自动检测状态切换页面
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // 修改服务器地址弹窗
  void _showEditServerUrlDialog(BuildContext context) {
    final controller = TextEditingController(text: appSettings.serverUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器 URL',
                hintText: 'http://192.168.x.x:3000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请确保手机和服务器在同一局域网内',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                await appSettings.setServerUrl(url);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('服务器地址已更新')),
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // 扫描局域网中的服务器
  Future<void> _onScanServer() async {
    setState(() {
      _isScanning = true;
      _scanStatus = '正在扫描...';
    });

    final found = await AuthService.instance.scanServer(
      onProgress: (msg) {
        if (mounted) setState(() => _scanStatus = msg);
      },
    );

    if (!mounted) return;

    if (found != null) {
      // 自动更新服务器地址
      await appSettings.setServerUrl(found);
      setState(() {
        _isScanning = false;
        _scanStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已找到服务器: $found')),
      );
    } else {
      setState(() {
        _isScanning = false;
        _scanStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到服务器，请确保电脑已启动服务器且在同一局域网')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 应用图标
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.handyman_outlined,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                // 应用名称
                Text(
                  '实用工具箱',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '登录以同步您的数据',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 40),

                // 邮箱输入框
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(
                    labelText: '邮箱',
                    hintText: '请输入邮箱地址',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 密码输入框
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: '请输入密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _onLogin(),
                ),
                const SizedBox(height: 8),

                // 记住密码选项
                Row(
                  children: [
                    SizedBox(
                      height: 24,
                      width: 24,
                      child: Checkbox(
                        value: _rememberMe,
                        onChanged: (value) {
                          setState(() => _rememberMe = value ?? false);
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => setState(() => _rememberMe = !_rememberMe),
                      child: Text(
                        '记住账号密码',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 登录按钮
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _onLogin,
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            '登录',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                // 注册入口
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '还没有账号？',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                    TextButton(
                      onPressed: _onGoRegister,
                      child: const Text('注册新账号'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 分割线 + "或"
                Row(
                  children: [
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '或',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                  ],
                ),
                const SizedBox(height: 16),

                // 游客模式按钮
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _onGuestMode,
                    icon: const Icon(Icons.person_outline, size: 20),
                    label: const Text(
                      '以游客身份继续',
                      style: TextStyle(fontSize: 16),
                    ),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // 游客模式说明
                Text(
                  '游客模式下数据仅保存在本地，登录后可同步到服务器',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),

                // 服务器地址显示、扫描与修改
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.dns_outlined, size: 14, color: Colors.grey.shade600),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              appSettings.serverUrl,
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            ),
                          ),
                          // 手动修改按钮
                          GestureDetector(
                            onTap: () => _showEditServerUrlDialog(context),
                            child: Icon(Icons.edit, size: 14, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 扫描按钮
                      SizedBox(
                        width: double.infinity,
                        height: 32,
                        child: OutlinedButton.icon(
                          onPressed: _isScanning ? null : _onScanServer,
                          icon: _isScanning
                              ? SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                                )
                              : const Icon(Icons.wifi_find, size: 16),
                          label: Text(
                            _isScanning
                                ? (_scanStatus.isNotEmpty ? _scanStatus : '扫描中...')
                                : '自动扫描服务器',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
