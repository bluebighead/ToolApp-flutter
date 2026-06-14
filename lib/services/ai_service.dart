import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class AiService {
  static const String _baseUrl =
      'https://open.bigmodel.cn/api/paas/v4/chat/completions';
  static const String _model = 'GLM-4.7-Flash';
  static const String _apiKey =
      'b314480d97f847c3bbcb1fdbdae929d8.yRvQhnd3rYTAzVCG';

  // 精简系统提示词，减少token消耗以提升响应速度
  static const String _systemPrompt = '工具箱AI助手。可用工具：NFC读写器、压缩器、分贝测试仪、网速测试、趣味工具、视频格式转换、心率广播接收器、设备检修工具、加解密工具、安装包免压查看、电子元件计算、网址解析、蓝牙调试器、设置、软件说明。\n'
      '回复规则（严格遵守）：\n'
      '- 需要打开工具：{"action":"navigate","target":"工具名称"}\n'
      '- 普通聊天或回答问题：{"action":"chat","message":"简洁回复"}\n'
      '- 只输出JSON，且必须以{开头并以}结尾，回复尽量简洁';

  static void init(String toolsDescription) {
    // init保留接口兼容，系统提示词已内置
  }

  // 流式发送消息，通过回调逐步返回内容
  static Stream<String> sendMessageStream(String userMessage) async* {
    int maxRetries = 3;
    int retryCount = 0;

    while (retryCount < maxRetries) {
      try {
        final client = http.Client();
        try {
          final request =
              http.Request('POST', Uri.parse(_baseUrl));
          request.headers.addAll({
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          });
          request.body = jsonEncode({
            'model': _model,
            'messages': [
              {'role': 'system', 'content': _systemPrompt},
              {'role': 'user', 'content': userMessage},
            ],
            'stream': true, // 启用流式响应
            'temperature': 0.1,
            'max_tokens': 200,
          });

          final streamedResponse = await client
              .send(request)
              .timeout(const Duration(seconds: 60));

          if (streamedResponse.statusCode == 200) {
            // 解析SSE流式数据
            await for (final chunk in streamedResponse.stream
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
              if (chunk.startsWith('data: ')) {
                final data = chunk.substring(6);
                if (data == '[DONE]') {
                  return;
                }
                try {
                  final json = jsonDecode(data);
                  if (json['error'] != null) {
                    final errorMsg = json['error']['message'] as String? ?? '未知错误';
                    yield 'AI服务错误: $errorMsg';
                    return;
                  }
                  final content = json['choices']?[0]?['delta']?['content'];
                  if (content != null && content.isNotEmpty) {
                    yield content;
                  }
                } catch (_) {
                  // 忽略解析错误
                }
              }
            }
            return;
          } else if (streamedResponse.statusCode == 429) {
            retryCount++;
            if (retryCount < maxRetries) {
              await Future.delayed(Duration(seconds: 2 * retryCount));
              continue;
            }
            yield '请求过于频繁，AI服务暂时限流';
            return;
          } else {
            yield 'AI服务暂时不可用（错误码：${streamedResponse.statusCode}）';
            return;
          }
        } finally {
          client.close();
        }
      } on TimeoutException {
        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        yield '请求超时，请检查网络后重试';
        return;
      } catch (e) {
        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        yield '网络连接失败，请检查网络设置';
        return;
      }
    }
  }

  // 保留原有的非流式方法用于简单场景
  static Future<String> sendMessage(String userMessage) async {
    int maxRetries = 3;
    int retryCount = 0;

    while (retryCount < maxRetries) {
      try {
        final client = http.Client();
        try {
          final request =
              http.Request('POST', Uri.parse(_baseUrl));
          request.headers.addAll({
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          });
          request.body = jsonEncode({
            'model': _model,
            'messages': [
              {'role': 'system', 'content': _systemPrompt},
              {'role': 'user', 'content': userMessage},
            ],
            'stream': false,
            'temperature': 0.1, // 降低temperature使回复更简洁快速
            'max_tokens': 200, // 限制最大token数，避免过长回复
          });

          // 总超时60秒
          final streamedResponse = await client
              .send(request)
              .timeout(const Duration(seconds: 60));

          final response =
              await http.Response.fromStream(streamedResponse);

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            return data['choices'][0]['message']['content'] ?? '';
          } else if (response.statusCode == 429) {
            // 请求被限流，等待后重试
            retryCount++;
            if (retryCount < maxRetries) {
              await Future.delayed(
                  Duration(seconds: 2 * retryCount));
              continue;
            }
            return '{"action": "chat", "message": "请求过于频繁，AI服务暂时限流，请稍后再试"}';
          } else {
            return '{"action": "chat", "message": "AI服务暂时不可用（错误码：${response.statusCode}），请稍后重试"}';
          }
        } finally {
          client.close();
        }
      } on TimeoutException {
        // 超时也重试
        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return '{"action": "chat", "message": "请求超时，请检查网络后重试"}';
      } catch (e) {
        // 网络错误也重试
        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return '{"action": "chat", "message": "网络连接失败，请检查网络设置"}';
      }
    }

    return '{"action": "chat", "message": "AI服务暂时不可用，请稍后重试"}';
  }

  static Map<String, String?> parseAiResponse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return {'action': 'chat', 'message': ''};

    int start = -1;
    for (int i = 0; i < s.length; i++) {
      if (s[i] == '{' || s[i] == '[') { start = i; break; }
    }
    if (start == -1) return {'action': 'chat', 'message': s};

    int end = -1;
    for (int i = s.length - 1; i >= start; i--) {
      if (s[i] == '}' || s[i] == ']') { end = i; break; }
    }
    if (end == -1) return {'action': 'chat', 'message': s};

    String jsonStr = s.substring(start, end + 1);
    if (jsonStr.startsWith('[') && (jsonStr.endsWith('}') || jsonStr.endsWith(']'))) {
      jsonStr = '{${jsonStr.substring(1, jsonStr.length - 1)}}';
    } else if (jsonStr.startsWith('{') && jsonStr.endsWith(']')) {
      jsonStr = '{${jsonStr.substring(1, jsonStr.length - 1)}}';
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = json['action'] as String? ?? 'chat';
      if (action == 'navigate') {
        final target = json['target'] as String?;
        return {
          'action': 'navigate',
          'target': target,
          'message': target != null ? '正在打开: $target' : '未指定目标工具',
        };
      }
      final msg = json['message'] as String?;
      return {'action': action, 'message': msg ?? s};
    } catch (_) {
      final reg = RegExp(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"');
      final m = reg.firstMatch(s);
      if (m != null) return {'action': 'chat', 'message': m.group(1)!};
      return {'action': 'chat', 'message': s};
    }
  }

  static String extractMessage(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';

    int start = -1;
    for (int i = 0; i < s.length; i++) {
      if (s[i] == '{' || s[i] == '[') { start = i; break; }
    }
    if (start == -1) return s;

    int end = -1;
    for (int i = s.length - 1; i >= start; i--) {
      if (s[i] == '}' || s[i] == ']') { end = i; break; }
    }
    if (end == -1) return s;

    String jsonStr = s.substring(start, end + 1);

    if (jsonStr.startsWith('[') && (jsonStr.endsWith('}') || jsonStr.endsWith(']'))) {
      jsonStr = '{${jsonStr.substring(1, jsonStr.length - 1)}}';
    } else if (jsonStr.startsWith('{') && jsonStr.endsWith(']')) {
      jsonStr = '{${jsonStr.substring(1, jsonStr.length - 1)}}';
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final msg = json['message'] as String?;
      if (msg != null && msg.isNotEmpty) return msg;
    } catch (_) {
      final reg = RegExp(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"');
      final m = reg.firstMatch(s);
      if (m != null) return m.group(1)!;
    }

    return s;
  }
}
