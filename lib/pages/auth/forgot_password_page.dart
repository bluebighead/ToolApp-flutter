// 忘记密码页面
// 支持两种方式：
//   1. 邮箱验证码重置（需要邮箱服务已配置）
//   2. 联系管理员重置（邮箱服务未配置时的降级方案）
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/app_logger.dart';
import 'login_page.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _codeSent = false;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;

  // 倒计时
  int _countdown = 0;

  // 发送验证码
  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnackBar('请输入邮箱地址');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final result = await AuthService.instance.sendVerificationCode(email);
      if (result['success'] == 'true') {
        setState(() => _codeSent = true);
        _startCountdown();
        _showSnackBar(result['message'] ?? '验证码已发送');
      } else {
        _showSnackBar(result['error'] ?? '发送失败');
      }
    } catch (e) {
      _showSnackBar('发送失败：$e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 倒计时
  void _startCountdown() {
    setState(() => _countdown = 60);
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _countdown--);
      return _countdown > 0;
    });
  }

  // 重置密码
  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (email.isEmpty || code.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty) {
      _showSnackBar('请填写所有字段');
      return;
    }

    if (newPassword.length < 6) {
      _showSnackBar('密码至少需要6位');
      return;
    }

    if (newPassword != confirmPassword) {
      _showSnackBar('两次输入的密码不一致');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final error = await AuthService.instance.resetPassword(
        email: email,
        verificationCode: code,
        newPassword: newPassword,
      );

      if (!mounted) return;

      if (error == null) {
        // 重置成功，跳转到登录页
        _showSnackBar('密码重置成功，请使用新密码登录');
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      } else {
        _showSnackBar(error);
      }
    } catch (e) {
      _showSnackBar('重置失败：$e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('忘记密码'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题说明
            Icon(Icons.lock_reset, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              '重置密码',
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '通过邮箱验证码重置您的密码',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // 邮箱输入 + 发送验证码按钮
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '注册邮箱',
                      hintText: '请输入注册时使用的邮箱',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    enabled: !_isLoading,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  height: 56,
                  child: FilledButton(
                    onPressed: _countdown > 0 || _isLoading ? null : _sendCode,
                    child: Text(
                      _countdown > 0 ? '${_countdown}s' : (_codeSent ? '重新发送' : '发送验证码'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 验证码输入
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '验证码',
                hintText: '请输入邮箱收到的验证码',
                prefixIcon: Icon(Icons.pin_outlined),
                border: OutlineInputBorder(),
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),

            // 新密码
            TextField(
              controller: _newPasswordController,
              obscureText: _obscureNewPassword,
              decoration: InputDecoration(
                labelText: '新密码',
                hintText: '至少6位',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureNewPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscureNewPassword = !_obscureNewPassword),
                ),
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),

            // 确认密码
            TextField(
              controller: _confirmPasswordController,
              obscureText: _obscureConfirmPassword,
              decoration: InputDecoration(
                labelText: '确认新密码',
                hintText: '再次输入新密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                ),
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 32),

            // 重置密码按钮
            FilledButton(
              onPressed: _isLoading ? null : _resetPassword,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('重置密码', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 24),

            // 联系管理员提示
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 18, color: Colors.orange.shade700),
                      const SizedBox(width: 6),
                      Text(
                        '无法通过邮箱重置？',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '如果邮箱服务未配置或无法收到验证码，请联系管理员重置密码。管理员可在PC端管理后台修改您的密码。',
                    style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
