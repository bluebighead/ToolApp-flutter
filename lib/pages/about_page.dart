// 软件说明页面（关于页面）
// 显示应用名称、版本号、开发者、更新时间等元数据。
// 入口：首页 AppBar 右上角圆形问号按钮。
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/feedback_service.dart';
import '../services/update_service.dart';
import '../utils/app_info.dart';
import '../utils/app_logger.dart';
import 'logs_page.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  // 单行信息项的构建器
  Widget _infoTile(BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 进入页面时记录日志
    AppLogger.i('AboutPage', '进入软件说明页面');
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件说明'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部：应用 Logo 占位 + 名称
              Column(
                children: [
                  // Logo 占位图标（统一用 indigo 圆形 + 内置工具图标）
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.handyman_outlined,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 应用名称
                  Text(
                    AppInfo.appName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 一句话简介
                  Text(
                    AppInfo.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // 详细信息卡片
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _infoTile(context, Icons.tag, '版本号', AppInfo.fullVersion),
                      const Divider(height: 1),
                      _infoTile(context, Icons.person_outline, '开发者', AppInfo.developer),
                      const Divider(height: 1),
                      _infoTile(context, Icons.update, '最近更新', AppInfo.lastUpdate),
                      const Divider(height: 1),
                      _infoTile(context, Icons.info_outline, '包名', AppInfo.packageName),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 版权信息
              Center(
                child: Text(
                  AppInfo.copyright,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 检查更新按钮
              FilledButton.icon(
                icon: const Icon(Icons.system_update),
                label: const Text('检查更新'),
                onPressed: () => _checkForUpdate(context),
              ),
              const SizedBox(height: 12),
              // 意见反馈按钮
              OutlinedButton.icon(
                icon: const Icon(Icons.feedback_outlined),
                label: const Text('意见反馈'),
                onPressed: () => _openFeedbackDialog(context),
              ),
              const SizedBox(height: 12),
              // 调试入口：进入日志查看页面
              OutlinedButton.icon(
                icon: const Icon(Icons.bug_report_outlined),
                label: const Text('查看调试日志'),
                onPressed: () {
                  AppLogger.i('AboutPage', '点击查看调试日志');
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LogsPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 手动检查更新
  Future<void> _checkForUpdate(BuildContext context) async {
    AppLogger.i('AboutPage', '手动检查更新');

    // 显示加载提示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在检查更新...'),
          ],
        ),
      ),
    );

    final updateInfo = await UpdateService.instance.checkForUpdate();

    // 关闭加载提示
    if (context.mounted) Navigator.pop(context);

    if (!context.mounted) return;

    if (updateInfo.hasUpdate) {
      // 有新版本，显示更新对话框
      UpdateService.showUpdateDialog(context, updateInfo);
    } else {
      // 已是最新版本
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(updateInfo.message ?? '已是最新版本')),
      );
    }
  }

  // 打开意见反馈对话框
  Future<void> _openFeedbackDialog(BuildContext context) async {
    AppLogger.i('AboutPage', '打开意见反馈对话框');

    // 检查登录状态
    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录后再提交反馈')),
      );
      return;
    }

    final contentController = TextEditingController();
    final contactController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('意见反馈'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '欢迎提出您的宝贵意见和建议，我们会认真阅读每一条反馈。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: contentController,
                minLines: 5,
                maxLines: 10,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '反馈内容 *',
                  hintText: '请描述您遇到的问题或改进建议...',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请填写反馈内容';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: contactController,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '联系方式（可选）',
                  hintText: '邮箱或其他联系方式',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;

              // 关闭对话框
              Navigator.pop(dialogContext);

              // 显示加载提示
              if (context.mounted) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => const AlertDialog(
                    content: Row(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(width: 16),
                        Text('正在提交...'),
                      ],
                    ),
                  ),
                );
              }

              final result = await FeedbackService.instance.submitFeedback(
                content: contentController.text,
                contact: contactController.text,
              );

              // 关闭加载提示
              if (context.mounted) Navigator.pop(context);

              // 显示结果
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(result.message),
                    backgroundColor: result.success ? Colors.green : Colors.red,
                  ),
                );
              }
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );

    contentController.dispose();
    contactController.dispose();
  }
}
