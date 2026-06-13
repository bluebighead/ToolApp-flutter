// 注册页面
// 邮箱+密码注册，注册时需要先验证邮箱验证码
// 注册成功后自动登录并跳转首页
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  // 邮箱、密码、确认密码、验证码输入控制器
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _verificationCodeController = TextEditingController();

  // 是否正在注册中
  bool _isLoading = false;

  // 密码是否可见
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // 验证码相关状态
  bool _isSendingCode = false; // 是否正在发送验证码
  int _countdown = 0; // 倒计时秒数
  Timer? _countdownTimer; // 倒计时定时器

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _verificationCodeController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // 发送验证码
  Future<void> _onSendCode() async {
    final email = _emailController.text.trim();

    // 邮箱格式校验
    if (email.isEmpty) {
      _showSnackBar('请输入邮箱');
      return;
    }
    if (!RegExp(r'^[\w-]+(\.[\w-]+)*@[\w-]+(\.[\w-]+)+$').hasMatch(email)) {
      _showSnackBar('请输入有效的邮箱地址');
      return;
    }

    setState(() => _isSendingCode = true);

    final result = await AuthService.instance.sendVerificationCode(email);

    if (!mounted) return;
    setState(() => _isSendingCode = false);

    if (result['success'] == 'true') {
      final message = result['message'] ?? '验证码已发送到您的邮箱';
      _showSnackBar(message);
      // 开始60秒倒计时
      _startCountdown();
    } else {
      _showSnackBar(result['error'] ?? '发送失败');
    }
  }

  // 开始倒计时
  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdown = 60;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        setState(() => _countdown--);
      } else {
        timer.cancel();
      }
    });
  }

  // 执行注册（v1.52.0+ 必须携带验证码）
  Future<void> _onRegister() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;
    final code = _verificationCodeController.text.trim();

    // 输入校验
    if (email.isEmpty) {
      _showSnackBar('请输入邮箱');
      return;
    }
    if (!RegExp(r'^[\w-]+(\.[\w-]+)*@[\w-]+(\.[\w-]+)+$').hasMatch(email)) {
      _showSnackBar('请输入有效的邮箱地址');
      return;
    }
    if (code.isEmpty) {
      _showSnackBar('请输入验证码');
      return;
    }
    if (password.isEmpty) {
      _showSnackBar('请输入密码');
      return;
    }
    if (password.length < 6) {
      _showSnackBar('密码至少需要6位');
      return;
    }
    if (password != confirmPassword) {
      _showSnackBar('两次输入的密码不一致');
      return;
    }

    setState(() => _isLoading = true);

    // 调用认证服务注册，携带验证码
    final error = await AuthService.instance.signUp(
      email: email,
      password: password,
      verificationCode: code,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (error != null) {
      _showSnackBar(error);
    } else {
      // 注册成功（邮箱自动确认模式下会自动登录）
      _showSnackBar('注册成功');
      // AuthWrapper 会自动检测登录状态切换页面
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('注册新账号'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 注册图标
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.person_add_outlined,
                    color: theme.colorScheme.primary,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '创建您的账号',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '注册后数据将自动同步到服务器',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 32),

                // 邮箱输入框 + 发送验证码按钮
                Row(
                  children: [
                    Expanded(
                      child: TextField(
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
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 100,
                      child: FilledButton(
                        onPressed: _isSendingCode || _countdown > 0
                            ? null
                            : _onSendCode,
                        child: _isSendingCode
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _countdown > 0 ? '$_countdown s' : '发送验证码',
                                style: const TextStyle(fontSize: 12),
                              ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 验证码输入框（v1.52.0+ 简化：注册时由服务器验证）
                TextField(
                  controller: _verificationCodeController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: InputDecoration(
                    labelText: '验证码',
                    hintText: '请输入邮箱收到的6位验证码',
                    prefixIcon: const Icon(Icons.security),
                    counterText: '',
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
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: '至少6位',
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
                ),
                const SizedBox(height: 16),

                // 确认密码输入框
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirmPassword,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: '确认密码',
                    hintText: '再次输入密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _onRegister(),
                ),
                const SizedBox(height: 24),

                // 注册按钮
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _onRegister,
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
                            '注册',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                // 返回登录
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '已有账号？',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回登录'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
