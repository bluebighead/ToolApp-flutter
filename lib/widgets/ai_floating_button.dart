import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/ai_tool_executor.dart';

class AiFloatingButton extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const AiFloatingButton({super.key, required this.navigatorKey});

  @override
  State<AiFloatingButton> createState() => _AiFloatingButtonState();
}

class _AiFloatingButtonState extends State<AiFloatingButton> {
  bool _isProcessing = false;

  // 弹出输入面板，使用 OverlayEntry 替代 showModalBottomSheet
  // showModalBottomSheet 内部移除了 viewInsets.bottom，导致无法获取键盘高度
  void _showInput() {
    final navCtx = widget.navigatorKey.currentContext;
    if (navCtx == null) return;
    final controller = TextEditingController();
    final overlay = Navigator.of(navCtx).overlay;

    // 使用 OverlayEntry 保留完整的 viewInsets，实现键盘避让
    late OverlayEntry overlayEntry;
    overlayEntry = OverlayEntry(
      builder: (overlayCtx) {
        // 使用 AnimatedPadding 手动添加键盘高度的 padding
        return Scaffold(
          backgroundColor: Colors.black54,
          resizeToAvoidBottomInset: false, // 禁用自动避让，手动控制
          body: Stack(
            children: [
              // 背景层，点击关闭面板
              GestureDetector(
                onTap: () {
                  overlayEntry.remove();
                  controller.dispose();
                },
                child: Container(color: Colors.black54),
              ),
              // 面板层，使用 AnimatedPadding 手动添加键盘高度
              AnimatedPadding(
                duration: const Duration(milliseconds: 100),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(overlayCtx).viewInsets.bottom,
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: GestureDetector(
                    onTap: () {}, // 阻止事件穿透
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(16)),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.edit,
                                  size: 20, color: Colors.blue[700]),
                              const SizedBox(width: 8),
                              const Text(
                                '输入需求',
                                style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: '请输入你的需求…',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () {
                                  overlayEntry.remove();
                                  controller.dispose();
                                },
                                child: const Text('取消'),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () {
                                  final text = controller.text.trim();
                                  overlayEntry.remove();
                                  controller.dispose();
                                  _onSend(text, navCtx);
                                },
                                child: const Text('发送'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    overlay?.insert(overlayEntry);
  }

  // 发送消息给AI并显示结果（使用流式响应提升感知速度）
  void _onSend(String text, BuildContext navCtx) async {
    text = text.trim();
    // 防抖检查：如果正在处理则忽略
    if (_isProcessing) return;
    if (text.isEmpty) return;
    if (!mounted) return;
    setState(() => _isProcessing = true);

    try {
      // 先显示加载对话框
      if (!navCtx.mounted) return;
      showDialog(
        context: navCtx,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.auto_awesome, size: 22, color: Colors.blue[700]),
              const SizedBox(width: 8),
              const Text('AI助手', style: TextStyle(fontSize: 17)),
            ],
          ),
          content: StatefulBuilder(
            builder: (dialogCtx, setDialogState) {
              return _StreamingContent(
                stream: AiService.sendMessageStream(text),
                onNavigate: (target) {
                  Navigator.pop(dialogCtx);
                  AiToolExecutor.navigateToTool(target, navCtx);
                },
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      // 捕获未预期的异常，显示友好提示
      if (mounted && navCtx.mounted) {
        showDialog(
          context: navCtx,
          builder: (ctx) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('请求失败'),
            content: const Text('AI助手暂时无法响应，请稍后重试'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _isProcessing ? null : _showInput,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isProcessing ? Colors.white : null,
          gradient: _isProcessing
              ? null
              : LinearGradient(
                  colors: [Colors.blue[400]!, Colors.indigo[500]!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          boxShadow: [
            BoxShadow(
              color: Colors.indigo.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: _isProcessing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Icon(Icons.auto_awesome, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}

// 流式内容显示组件，逐步显示AI回复
class _StreamingContent extends StatefulWidget {
  final Stream<String> stream;
  final Function(String target)? onNavigate;
  const _StreamingContent({required this.stream, this.onNavigate});

  @override
  State<_StreamingContent> createState() => _StreamingContentState();
}

class _StreamingContentState extends State<_StreamingContent> {
  String _content = '';
  bool _isComplete = false;

  @override
  void initState() {
    super.initState();
    _listenStream();
  }

  void _listenStream() async {
    try {
      await for (final chunk in widget.stream) {
        if (!mounted) break;
        setState(() {
          _content += chunk;
        });
      }
    } catch (_) {
      if (mounted && _content.isEmpty) {
        setState(() {
          _content = '请求失败，请检查网络后重试';
          _isComplete = true;
        });
      }
      return;
    }
    if (mounted) {
      final rawContent = _content;
      final parsed = AiService.parseAiResponse(_content);
      final extractedMsg = parsed['message'];
      final displayMsg = (extractedMsg != null && extractedMsg.isNotEmpty)
          ? extractedMsg
          : (rawContent.isNotEmpty ? rawContent : '未收到回复');
      setState(() {
        _isComplete = true;
        _content = displayMsg;
      });
      if (parsed['action'] == 'navigate' && parsed['target'] != null) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) widget.onNavigate?.call(parsed['target']!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.maxFinite,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _content.isEmpty && !_isComplete ? '思考中...' : _content,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            if (!_isComplete && _content.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
