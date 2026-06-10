// 登录页面
// 邮箱+密码登录，底部提供"注册新账号"和"游客模式"入口
// 支持账号历史记录下拉选择，记住账号密码功能
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
  // 邮箱输入框的焦点节点
  final _emailFocusNode = FocusNode();

  // 是否正在登录中（防止重复点击）
  bool _isLoading = false;

  // 密码是否可见
  bool _obscurePassword = true;

  // 是否记住密码
  bool _rememberMe = false;

  // 服务器扫描状态
  bool _isScanning = false;
  String _scanStatus = '';

  // 账号历史记录
  List<Map<String, String>> _accountHistory = [];
  // 下拉框是否展开
  bool _isDropdownOpen = false;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _loadAccountHistory();
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

  // 加载账号历史记录
  Future<void> _loadAccountHistory() async {
    final history = await AuthService.instance.getAccountHistory();
    if (mounted) {
      setState(() {
        _accountHistory = history;
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
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
        // 即使不记住密码，也记住账号到历史记录
        await AuthService.instance.addEmailToHistory(email);
        await AuthService.instance.clearCredentials();
      }
    }
    // 登录成功时 AuthWrapper 会自动切换页面，无需手动跳转
  }

  // 选择历史账号
  void _onSelectAccount(Map<String, String> account) {
    setState(() {
      _emailController.text = account['email'] ?? '';
      // 如果该账号有保存密码，自动填充
      final savedPassword = account['password'] ?? '';
      if (savedPassword.isNotEmpty) {
        _passwordController.text = savedPassword;
        _rememberMe = true;
      } else {
        _passwordController.text = '';
        _rememberMe = false;
      }
      _isDropdownOpen = false;
    });
  }

  // 删除历史账号
  Future<void> _onDeleteAccount(String email) async {
    await AuthService.instance.removeAccountFromHistory(email);
    await _loadAccountHistory();
    _showSnackBar('已删除账号 $email');
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

                // 邮箱输入框 + 下拉选择箭头
                Column(
                  children: [
                    TextField(
                      controller: _emailController,
                      focusNode: _emailFocusNode,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(
                        labelText: '邮箱',
                        hintText: '请输入邮箱地址',
                        prefixIcon: const Icon(Icons.email_outlined),
                        // 右侧下拉箭头按钮
                        suffixIcon: _accountHistory.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  _isDropdownOpen
                                      ? Icons.arrow_drop_up
                                      : Icons.arrow_drop_down,
                                  size: 28,
                                  color: theme.colorScheme.primary,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _isDropdownOpen = !_isDropdownOpen;
                                  });
                                },
                                tooltip: '选择历史账号',
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (_) {
                        // 输入时关闭下拉
                        if (_isDropdownOpen) {
                          setState(() => _isDropdownOpen = false);
                        }
                      },
                      onSubmitted: (_) {
                        // 按回车时关闭下拉，焦点移到密码框
                        if (_isDropdownOpen) {
                          setState(() => _isDropdownOpen = false);
                        }
                      },
                    ),
                    // 账号下拉选择列表
                    if (_isDropdownOpen && _accountHistory.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: _accountHistory.length > 5
                                  ? 250
                                  : _accountHistory.length * 50.0,
                            ),
                            child: ListView.builder(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: _accountHistory.length,
                              itemBuilder: (context, index) {
                                final account = _accountHistory[index];
                                final email = account['email'] ?? '';
                                final hasPassword =
                                    (account['password'] ?? '').isNotEmpty;
                                return InkWell(
                                  onTap: () => _onSelectAccount(account),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        // 用户头像图标
                                        CircleAvatar(
                                          radius: 14,
                                          backgroundColor:
                                              theme.colorScheme.primaryContainer,
                                          child: Text(
                                            email.isNotEmpty
                                                ? email[0].toUpperCase()
                                                : '?',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: theme
                                                  .colorScheme.onPrimaryContainer,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // 邮箱地址
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                email,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              if (hasPassword)
                                                Text(
                                                  '已记住密码',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color:
                                                        Colors.green.shade600,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        // 删除按钮
                                        IconButton(
                                          icon: Icon(
                                            Icons.close,
                                            size: 16,
                                            color: Colors.grey.shade400,
                                          ),
                                          onPressed: () =>
                                              _onDeleteAccount(email),
                                          tooltip: '删除此账号',
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
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
