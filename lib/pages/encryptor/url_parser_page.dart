// 网址解析工具页面 v2
// 本页面同时包含"在线解析"（依赖服务端 axios+cheerio）和
// "本地解析"（纯 Dart，输入后即时展示 URL 基本信息）两种模式。
// 即使服务端不可用，用户也可获得 URL 结构分析、参数解码、安全检测等基础功能。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';

// ============================================================
// 数据模型
// ============================================================

/// 服务端完整解析结果（扩展版）
class _UrlParseResult {
  final String url;
  final String? finalUrl;
  final int? statusCode;
  final String? title;
  final String? description;
  final String? keywords;
  final String? favicon;
  final String? ogImage;
  final String? ogType;
  final String? ogSiteName;
  final String? textPreview;
  final int wordCount;
  final int linkCount;
  final int imageCount;
  final int headingCount;
  final Map<String, int> headingsByLevel;
  final List<_HeadingItem> headings;
  final List<_LinkItem> links;
  final List<_ImageItem> images;
  final List<dynamic> jsonLd;

  _UrlParseResult({
    required this.url,
    this.finalUrl,
    this.statusCode,
    this.title,
    this.description,
    this.keywords,
    this.favicon,
    this.ogImage,
    this.ogType,
    this.ogSiteName,
    this.textPreview,
    required this.wordCount,
    required this.linkCount,
    required this.imageCount,
    required this.headingCount,
    required this.headingsByLevel,
    required this.headings,
    required this.links,
    required this.images,
    this.jsonLd = const [],
  });

  factory _UrlParseResult.fromJson(Map<String, dynamic> json) {
    return _UrlParseResult(
      url: json['url'] ?? '',
      finalUrl: json['finalUrl'],
      statusCode: json['statusCode'],
      title: json['title'],
      description: json['description'],
      keywords: json['keywords'],
      favicon: json['favicon'],
      ogImage: json['ogImage'],
      ogType: json['ogType'],
      ogSiteName: json['ogSiteName'],
      textPreview: json['textPreview'],
      wordCount: json['stats']?['wordCount'] ?? 0,
      linkCount: json['stats']?['linkCount'] ?? 0,
      imageCount: json['stats']?['imageCount'] ?? 0,
      headingCount: json['stats']?['headingCount'] ?? 0,
      headingsByLevel:
          Map<String, int>.from(json['stats']?['headingsByLevel'] ?? {}),
      headings: (json['headings'] as List<dynamic>?)
              ?.map((h) => _HeadingItem.fromJson(h))
              .toList() ??
          [],
      links: (json['links'] as List<dynamic>?)
              ?.map((l) => _LinkItem.fromJson(l))
              .toList() ??
          [],
      images: (json['images'] as List<dynamic>?)
              ?.map((i) => _ImageItem.fromJson(i))
              .toList() ??
          [],
      jsonLd: (json['jsonLd'] as List<dynamic>?) ?? [],
    );
  }
}

class _HeadingItem {
  final int level;
  final String text;
  _HeadingItem({required this.level, required this.text});
  factory _HeadingItem.fromJson(Map<String, dynamic> json) =>
      _HeadingItem(level: json['level'] ?? 0, text: json['text'] ?? '');
}

class _LinkItem {
  final String text;
  final String href;
  _LinkItem({required this.text, required this.href});
  factory _LinkItem.fromJson(Map<String, dynamic> json) =>
      _LinkItem(text: json['text'] ?? '', href: json['href'] ?? '');
}

class _ImageItem {
  final String src;
  final String alt;
  _ImageItem({required this.src, required this.alt});
  factory _ImageItem.fromJson(Map<String, dynamic> json) =>
      _ImageItem(src: json['src'] ?? '', alt: json['alt'] ?? '');
}

/// 本地 URL 解析结果（纯 Dart，不依赖服务端）
class _LocalUrlInfo {
  final String scheme;
  final String host;
  final int? port;
  final String path;
  final String? fragment;
  final List<_QueryParam> queryParams;
  final bool isHttps;
  final bool isIpAddress;
  final bool hasAuthInUrl;
  final String? authInfo;
  final String? decodedPath;

  _LocalUrlInfo({
    required this.scheme,
    required this.host,
    this.port,
    required this.path,
    this.fragment,
    required this.queryParams,
    required this.isHttps,
    required this.isIpAddress,
    required this.hasAuthInUrl,
    this.authInfo,
    this.decodedPath,
  });
}

class _QueryParam {
  final String key;
  final String value;
  final String? decodedValue;
  _QueryParam({required this.key, required this.value, this.decodedValue});
}

/// SEO 检测报告
class _SeoReport {
  final int titleLength;
  final String? titleIssue;
  final bool hasDescription;
  final int descriptionLength;
  final String? descriptionIssue;
  final int h1Count;
  final String? h1Issue;
  final double imageAltRatio;
  final int imageAltMissingCount;
  final bool isHttps;
  final bool hasCanonical;
  final bool hasFavicon;
  final bool hasOgTags;
  final int internalLinkCount;
  final int externalLinkCount;
  final double score;
  final String grade;

  _SeoReport({
    required this.titleLength,
    this.titleIssue,
    required this.hasDescription,
    required this.descriptionLength,
    this.descriptionIssue,
    required this.h1Count,
    this.h1Issue,
    required this.imageAltRatio,
    required this.imageAltMissingCount,
    required this.isHttps,
    required this.hasCanonical,
    required this.hasFavicon,
    required this.hasOgTags,
    required this.internalLinkCount,
    required this.externalLinkCount,
    required this.score,
    required this.grade,
  });
}

// ============================================================
// 本地 URL 解析工具（纯 Dart）
// ============================================================

_LocalUrlInfo? _parseLocalUrl(String urlStr) {
  try {
    var raw = urlStr.trim();
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final uri = Uri.parse(raw);
    if (!uri.hasScheme || !uri.hasAuthority) return null;

    final host = uri.host;
    final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) ||
        host.contains(':');

    String? auth;
    if (uri.userInfo.isNotEmpty) {
      auth = uri.userInfo;
    }

    final queryParams = <_QueryParam>[];
    uri.queryParametersAll.forEach((key, values) {
      for (final v in values) {
        queryParams.add(_QueryParam(
          key: key,
          value: v,
          decodedValue: Uri.decodeQueryComponent(v),
        ));
      }
    });

    String? decodedPath;
    try {
      final decoded = Uri.decodeComponent(uri.path);
      if (decoded != uri.path) decodedPath = decoded;
    } catch (_) {}

    return _LocalUrlInfo(
      scheme: uri.scheme,
      host: host,
      port: uri.port != (uri.scheme == 'https' ? 443 : 80) ? uri.port : null,
      path: uri.path.isEmpty ? '/' : uri.path,
      fragment: uri.fragment.isNotEmpty ? uri.fragment : null,
      queryParams: queryParams,
      isHttps: uri.scheme == 'https',
      isIpAddress: isIp,
      hasAuthInUrl: auth != null,
      authInfo: auth,
      decodedPath: decodedPath,
    );
  } catch (_) {
    return null;
  }
}

// ============================================================
// SEO 分析器
// ============================================================

_SeoReport _analyzeSeo(_UrlParseResult result, String baseUrl) {
  final issues = <String>[];

  final titleLength = result.title?.length ?? 0;
  String? titleIssue;
  if (result.title == null || result.title!.isEmpty) {
    titleIssue = '缺少 Title 标签';
    issues.add(titleIssue);
  } else if (titleLength < 10) {
    titleIssue = 'Title 过短（$titleLength 字符，建议 10-70）';
  } else if (titleLength > 70) {
    titleIssue = 'Title 过长（$titleLength 字符，建议不超过 70）';
  }

  final hasDescription =
      result.description != null && result.description!.isNotEmpty;
  final descriptionLength = result.description?.length ?? 0;
  String? descriptionIssue;
  if (!hasDescription) {
    descriptionIssue = '缺少 Meta Description';
    issues.add(descriptionIssue);
  } else if (descriptionLength < 50) {
    descriptionIssue =
        'Description 过短（$descriptionLength 字符，建议 50-160）';
  } else if (descriptionLength > 160) {
    descriptionIssue =
        'Description 过长（$descriptionLength 字符，建议不超过 160）';
  }

  final h1Count = result.headingsByLevel['h1'] ?? 0;
  String? h1Issue;
  if (h1Count == 0) {
    h1Issue = '页面缺少 H1 标签';
    issues.add(h1Issue);
  } else if (h1Count > 1) {
    h1Issue = '页面包含多个 H1（$h1Count 个，建议仅一个）';
  }

  final totalImages = result.images.length;
  final altMissing =
      result.images.where((img) => img.alt.isEmpty).length;
  final imageAltRatio =
      totalImages > 0 ? (totalImages - altMissing) / totalImages : 1.0;

  final baseUri = Uri.tryParse(baseUrl);
  final internalLinks = result.links.where((l) {
    final linkUri = Uri.tryParse(l.href);
    if (linkUri == null || !linkUri.hasScheme) return true;
    return linkUri.host == baseUri?.host;
  }).length;
  final externalLinks = result.links.length - internalLinks;

  final isHttps = baseUrl.startsWith('https://');
  final hasFavicon =
      result.favicon != null && result.favicon!.isNotEmpty;
  final hasOgTags =
      (result.ogImage != null && result.ogImage!.isNotEmpty) ||
          (result.ogType != null && result.ogType!.isNotEmpty);

  final checks = <double>[
    titleIssue == null ? 10 : 0,
    hasDescription ? 15 : 0,
    h1Count == 1 ? 15 : (h1Count == 0 ? 0 : 8),
    isHttps ? 15 : 0,
    hasFavicon ? 10 : 0,
    hasOgTags ? 10 : 0,
    imageAltRatio > 0.8 ? 10 : (imageAltRatio > 0.5 ? 5 : 0),
    result.linkCount > 0 ? 5 : 0,
    internalLinks > externalLinks ? 5 : 3,
    titleLength >= 10 && titleLength <= 70 ? 5 : 0,
  ];
  final score = checks.fold(0.0, (a, b) => a + b);

  String grade;
  if (score >= 85) {
    grade = '优秀';
  } else if (score >= 65) {
    grade = '良好';
  } else if (score >= 40) {
    grade = '一般';
  } else {
    grade = '较差';
  }

  return _SeoReport(
    titleLength: titleLength,
    titleIssue: titleIssue,
    hasDescription: hasDescription,
    descriptionLength: descriptionLength,
    descriptionIssue: descriptionIssue,
    h1Count: h1Count,
    h1Issue: h1Issue,
    imageAltRatio: imageAltRatio,
    imageAltMissingCount: altMissing,
    isHttps: isHttps,
    hasCanonical: false,
    hasFavicon: hasFavicon,
    hasOgTags: hasOgTags,
    internalLinkCount: internalLinks,
    externalLinkCount: externalLinks,
    score: score,
    grade: grade,
  );
}

// ============================================================
// 工具函数
// ============================================================

bool _isInternalLink(String href, String baseUrl) {
  final linkUri = Uri.tryParse(href);
  if (linkUri == null || !linkUri.hasScheme) return true;
  final baseUri = Uri.tryParse(baseUrl);
  if (baseUri == null) return false;
  return linkUri.host == baseUri.host;
}

String _linkTypeLabel(String href) {
  if (href.startsWith('mailto:')) return '邮件';
  if (href.startsWith('tel:')) return '电话';
  if (href.startsWith('javascript:')) return '脚本';
  if (href.endsWith('.pdf')) return 'PDF';
  if (href.endsWith('.zip') || href.endsWith('.rar')) return '压缩包';
  if (href.endsWith('.jpg') || href.endsWith('.png') || href.endsWith('.gif') ||
      href.endsWith('.webp')) return '图片';
  if (href.endsWith('.mp4') || href.endsWith('.avi') || href.endsWith('.mov')) {
    return '视频';
  }
  return '网页';
}

IconData _linkTypeIcon(String href) {
  if (href.startsWith('mailto:')) return Icons.email;
  if (href.startsWith('tel:')) return Icons.phone;
  if (href.endsWith('.pdf')) return Icons.picture_as_pdf;
  if (href.endsWith('.zip') || href.endsWith('.rar')) return Icons.folder_zip;
  if (RegExp(r'\.(jpg|png|gif|webp|svg)$').hasMatch(href)) return Icons.image;
  if (RegExp(r'\.(mp4|avi|mov|mkv)$').hasMatch(href)) return Icons.videocam;
  return Icons.open_in_new;
}

Color _statusCodeColor(int? code) {
  if (code == null) return Colors.grey;
  if (code >= 200 && code < 300) return Colors.green;
  if (code >= 300 && code < 400) return Colors.orange;
  if (code >= 400) return Colors.red;
  return Colors.grey;
}

String _statusCodeLabel(int? code) {
  if (code == null) return '未知';
  if (code == 200) return '200 OK';
  if (code == 301) return '301 永久重定向';
  if (code == 302) return '302 临时重定向';
  if (code == 304) return '304 未修改';
  if (code == 403) return '403 禁止访问';
  if (code == 404) return '404 未找到';
  if (code == 500) return '500 服务器错误';
  if (code == 502) return '502 网关错误';
  if (code == 503) return '503 服务不可用';
  return '$code';
}

// ============================================================
// 主页面
// ============================================================

class UrlParserPage extends StatefulWidget {
  const UrlParserPage({super.key});

  @override
  State<UrlParserPage> createState() => _UrlParserPageState();
}

class _UrlParserPageState extends State<UrlParserPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();
  late TabController _tabController;

  bool _isLoading = false;
  String? _errorMessage;
  _UrlParseResult? _result;

  // 本地解析结果（即时，不依赖服务端）
  _LocalUrlInfo? _localInfo;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onUrlChanged(String text) {
    if (text.trim().isEmpty) {
      setState(() => _localInfo = null);
      return;
    }
    final info = _parseLocalUrl(text);
    setState(() => _localInfo = info);
  }

  Future<void> _parseUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _errorMessage = '请输入网址');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _result = null;
    });

    try {
      final serverUrl = appSettings.serverUrl;
      final response = await http
          .post(
            Uri.parse('$serverUrl/api/url-parse'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _result = _UrlParseResult.fromJson(data);
        });
        AppLogger.i('UrlParserPage', '解析成功: $url');
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() => _errorMessage = data['error'] ?? '解析失败');
      }
    } catch (e) {
      setState(() => _errorMessage = '请求失败: ${e.toString()}');
      AppLogger.e('UrlParserPage', '解析失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('网址解析工具'),
        centerTitle: true,
        elevation: 0,
        actions: [
          if (_result != null)
            IconButton(
              icon: const Icon(Icons.share, size: 20),
              tooltip: '分享结果',
              onPressed: () => _shareResult(context),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildInputArea(theme),
          if (_localInfo != null && _result == null && !_isLoading)
            _buildLocalInfoBanner(theme),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('正在解析网址...',
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : _errorMessage != null
                    ? _buildErrorView(theme)
                    : _result != null
                        ? _buildResultView(theme)
                        : _buildEmptyView(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              focusNode: _urlFocusNode,
              keyboardType: TextInputType.url,
              enabled: !_isLoading,
              onChanged: _onUrlChanged,
              decoration: InputDecoration(
                hintText: '输入网址，如 https://www.example.com',
                hintStyle:
                    TextStyle(fontSize: 14, color: Colors.grey.shade400),
                prefixIcon: const Icon(Icons.link, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                isDense: true,
                suffixIcon: _urlController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _urlController.clear();
                          setState(() {
                            _localInfo = null;
                            _result = null;
                            _errorMessage = null;
                          });
                        },
                      )
                    : null,
              ),
              onSubmitted: (_) => _parseUrl(),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : _parseUrl,
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.search, size: 18),
              label: Text(_isLoading ? '解析中' : '解析'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalInfoBanner(ThemeData theme) {
    if (_localInfo == null) return const SizedBox.shrink();
    final info = _localInfo!;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.blue.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已识别本地 URL 信息，点击"解析"获取完整网页数据',
              style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.web, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text('输入网址，点击解析按钮',
              style: TextStyle(color: Colors.grey.shade500)),
          const SizedBox(height: 4),
          Text('支持解析网页标题、描述、关键词、链接等信息',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
          const SizedBox(height: 24),
          if (_localInfo != null) _buildUrlPreviewCard(theme),
        ],
      ),
    );
  }

  Widget _buildUrlPreviewCard(ThemeData theme) {
    final info = _localInfo!;
    final issues = <String>[];
    if (!info.isHttps) issues.add('非 HTTPS 连接');
    if (info.isIpAddress) issues.add('IP 直连（非域名）');
    if (info.hasAuthInUrl) issues.add('URL 包含认证信息');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.search, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('本地 URL 预览',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              ],
            ),
            const Divider(height: 16),
            _buildLocalRow('协议', info.scheme, Icons.lock_outline),
            _buildLocalRow('主机', info.host, Icons.dns_outlined),
            if (info.port != null)
              _buildLocalRow('端口', '${info.port}', Icons.settings_ethernet),
            _buildLocalRow('路径', info.path, Icons.folder_outlined),
            if (info.fragment != null)
              _buildLocalRow('片段', '#${info.fragment}', Icons.tag),
            if (info.queryParams.isNotEmpty)
              _buildLocalRow(
                  '参数', '${info.queryParams.length} 个', Icons.list_alt),
            if (issues.isNotEmpty) ...[
              const Divider(height: 12),
              ...issues.map((issue) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber, size: 14, color: Colors.orange.shade700),
                        const SizedBox(width: 6),
                        Text(issue,
                            style: TextStyle(
                                fontSize: 12, color: Colors.orange.shade700)),
                      ],
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLocalRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          SizedBox(
            width: 40,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(_errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade700)),
            const SizedBox(height: 24),
            // 即使出错也显示本地 URL 信息
            if (_localInfo != null) _buildUrlPreviewCard(theme),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 结果视图（含 TabBar）
  // ============================================================

  Widget _buildResultView(ThemeData theme) {
    final result = _result!;
    return Column(
      children: [
        _buildOverviewCard(result, theme),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: Colors.grey,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontSize: 13),
          tabs: const [
            Tab(text: '概览'),
            Tab(text: 'URL剖析'),
            Tab(text: '链接'),
            Tab(text: '图片'),
            Tab(text: '正文'),
            Tab(text: 'SEO检测'),
            Tab(text: '结构化数据'),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOverviewTab(result, theme),
              _buildUrlAnalysisTab(theme),
              _buildLinksTab(result, theme),
              _buildImagesTab(result, theme),
              _buildTextTab(result, theme),
              _buildSeoTab(result, theme),
              _buildJsonLdTab(result, theme),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 概览卡片（顶部固定）
  // ============================================================

  Widget _buildOverviewCard(_UrlParseResult result, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行 + favicon
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.favicon != null && result.favicon!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 2),
                    child: Image.network(
                      result.favicon!,
                      width: 20,
                      height: 20,
                      errorBuilder: (_, __, ___) =>
                          Icon(Icons.public, size: 20, color: theme.colorScheme.primary),
                    ),
                  ),
                Expanded(
                  child: Text(
                    result.title?.isNotEmpty == true
                        ? result.title!
                        : '(无标题)',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 描述
            if (result.description?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(result.description!,
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              ),
            // 状态码 + URL
            Row(
              children: [
                if (result.statusCode != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _statusCodeColor(result.statusCode)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: _statusCodeColor(result.statusCode)
                              .withValues(alpha: 0.3)),
                    ),
                    child: Text(_statusCodeLabel(result.statusCode),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _statusCodeColor(result.statusCode))),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.finalUrl ?? result.url,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (result.finalUrl != null &&
                result.finalUrl != result.url) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.redo, size: 12, color: Colors.orange.shade400),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text('原始 URL: ${result.url}',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade400),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // 统计
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildStatChip(Icons.text_fields, '${result.wordCount} 字符', theme),
                _buildStatChip(Icons.link, '${result.linkCount} 链接', theme),
                _buildStatChip(Icons.image, '${result.imageCount} 图片', theme),
                _buildStatChip(Icons.title, '${result.headingCount} 标题', theme),
                if (result.ogSiteName != null)
                  _buildStatChip(Icons.language, result.ogSiteName!, theme),
              ],
            ),
            // OG 图片缩略图
            if (result.ogImage != null && result.ogImage!.isNotEmpty) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  result.ogImage!,
                  width: double.infinity,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(IconData icon, String label, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
      ],
    );
  }

  // ============================================================
  // Tab 1: 概览
  // ============================================================

  Widget _buildOverviewTab(_UrlParseResult result, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoSection('页面信息', [
          _buildInfoRow('URL', result.url, canCopy: true),
          if (result.finalUrl != null)
            _buildInfoRow('最终 URL', result.finalUrl!, canCopy: true),
          if (result.title != null)
            _buildInfoRow('标题', result.title!, canCopy: true),
          if (result.description != null)
            _buildInfoRow('描述', result.description!, maxLines: 3, canCopy: true),
          if (result.keywords != null)
            _buildInfoRow('关键词', result.keywords!, canCopy: true),
          if (result.ogSiteName != null)
            _buildInfoRow('站点名称', result.ogSiteName!),
          if (result.ogType != null) _buildInfoRow('OG类型', result.ogType!),
          if (result.statusCode != null)
            _buildInfoRow('状态码', _statusCodeLabel(result.statusCode)),
        ], theme),
        const SizedBox(height: 16),
        if (result.headingsByLevel.isNotEmpty)
          _buildInfoSection('标题层级统计', [
            for (int i = 1; i <= 6; i++)
              if ((result.headingsByLevel['h$i'] ?? 0) > 0)
                _buildInfoRow('H$i', '${result.headingsByLevel['h$i']} 个'),
          ], theme),
      ],
    );
  }

  // ============================================================
  // Tab 2: URL 剖析（本地，离线可用）
  // ============================================================

  Widget _buildUrlAnalysisTab(ThemeData theme) {
    if (_localInfo == null) {
      return const Center(
          child: Text('输入 URL 后可查看本地解析',
              style: TextStyle(color: Colors.grey)));
    }
    final info = _localInfo!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoSection('URL 结构（本地解析）', [
          _buildInfoRow('协议', info.scheme),
          _buildInfoRow('主机', info.host),
          if (info.port != null) _buildInfoRow('端口', '${info.port}'),
          _buildInfoRow('路径', info.path, canCopy: true),
          if (info.decodedPath != null)
            _buildInfoRow('解码路径', info.decodedPath!, canCopy: true),
          if (info.fragment != null) _buildInfoRow('片段', '#${info.fragment}'),
        ], theme),
        const SizedBox(height: 16),
        // Query 参数表
        if (info.queryParams.isNotEmpty) ...[
          _buildInfoSection(
              '查询参数 (${info.queryParams.length})', [
            for (final p in info.queryParams)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(p.key,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.blue.shade700)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.value,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis),
                          if (p.decodedValue != null &&
                              p.decodedValue != p.value)
                            Text('解码: ${p.decodedValue}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ], theme),
          const SizedBox(height: 16),
        ],
        // 安全检测
        _buildInfoSection('安全检测', [
          _buildSecurityRow('HTTPS', info.isHttps, '使用 HTTPS 加密连接'),
          _buildSecurityRow(
              'IP 直连', !info.isIpAddress, '使用域名而非 IP 直连'),
          _buildSecurityRow(
              'URL 认证信息', !info.hasAuthInUrl, 'URL 中未包含认证信息'),
          if (info.queryParams.isNotEmpty)
            _buildSecurityRow(
                '参数编码',
                info.queryParams
                    .every((p) => p.decodedValue != p.value),
                '${info.queryParams.where((p) => p.decodedValue != p.value).length}/${info.queryParams.length} 参数已编码'),
        ], theme),
      ],
    );
  }

  Widget _buildSecurityRow(
      String label, bool isGood, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isGood ? Icons.check_circle : Icons.warning_amber,
            size: 18,
            color: isGood ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text(description,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Tab 3: 链接（增强版）
  // ============================================================

  Widget _buildLinksTab(_UrlParseResult result, ThemeData theme) {
    if (result.links.isEmpty) {
      return const Center(
          child: Text('暂无链接', style: TextStyle(color: Colors.grey)));
    }
    final baseUrl = result.finalUrl ?? result.url;
    final internalLinks =
        result.links.where((l) => _isInternalLink(l.href, baseUrl)).length;
    final externalLinks = result.links.length - internalLinks;

    return Column(
      children: [
        // 统计摘要
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surface,
          child: Row(
            children: [
              _buildLinkStat('全部', result.links.length, Colors.blue, theme),
              const SizedBox(width: 16),
              _buildLinkStat('站内', internalLinks, Colors.green, theme),
              const SizedBox(width: 16),
              _buildLinkStat('站外', externalLinks, Colors.orange, theme),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: result.links.length,
            itemBuilder: (_, i) {
              final link = result.links[i];
              final isInternal = _isInternalLink(link.href, baseUrl);
              final type = _linkTypeLabel(link.href);
              return Card(
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    _linkTypeIcon(link.href),
                    size: 18,
                    color: isInternal ? Colors.green : Colors.orange,
                  ),
                  title: Text(link.text.isNotEmpty ? link.text : '(空)',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: (isInternal ? Colors.green : Colors.orange)
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(isInternal ? '站内' : '站外',
                            style: TextStyle(
                                fontSize: 10,
                                color:
                                    isInternal ? Colors.green : Colors.orange)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(type,
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade600)),
                      ),
                      if (isInternal && link.href.startsWith('/'))
                        const SizedBox(width: 6),
                      if (isInternal && link.href.startsWith('/'))
                        Text(link.href,
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade400),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 16),
                    onSelected: (action) {
                      if (action == 'open') _openLink(link.href, baseUrl);
                      if (action == 'copy') _copyText(link.href);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'open',
                          child: Row(children: [
                            Icon(Icons.open_in_new, size: 16),
                            SizedBox(width: 8),
                            Text('打开')
                          ])),
                      const PopupMenuItem(
                          value: 'copy',
                          child: Row(children: [
                            Icon(Icons.copy, size: 16),
                            SizedBox(width: 8),
                            Text('复制链接')
                          ])),
                    ],
                  ),
                  onTap: () => _openLink(link.href, baseUrl),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLinkStat(
      String label, int count, Color color, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text('$label $count',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ],
    );
  }

  // ============================================================
  // Tab 4: 图片网格
  // ============================================================

  Widget _buildImagesTab(_UrlParseResult result, ThemeData theme) {
    if (result.images.isEmpty) {
      return const Center(
          child: Text('暂无图片', style: TextStyle(color: Colors.grey)));
    }
    final altMissing =
        result.images.where((img) => img.alt.isEmpty).length;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surface,
          child: Row(
            children: [
              Icon(Icons.image, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text('共 ${result.images.length} 张图片',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              if (altMissing > 0)
                Text('$altMissing 张缺 Alt 标签',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade700)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.2,
            ),
            itemCount: result.images.length,
            itemBuilder: (_, i) {
              final img = result.images[i];
              return GestureDetector(
                onTap: () => _previewImage(context, img.src, img.alt),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Image.network(
                          img.src,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.grey.shade100,
                            child: Icon(Icons.broken_image,
                                size: 32, color: Colors.grey.shade400),
                          ),
                          loadingBuilder: (_, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              color: Colors.grey.shade50,
                              child: const Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            );
                          },
                        ),
                      ),
                      if (img.alt.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: Text(img.alt,
                              style: const TextStyle(fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ============================================================
  // Tab 5: 正文（增强版）
  // ============================================================

  Widget _buildTextTab(_UrlParseResult result, ThemeData theme) {
    if (result.textPreview == null || result.textPreview!.isEmpty) {
      return const Center(
          child: Text('暂无正文内容', style: TextStyle(color: Colors.grey)));
    }

    final text = result.textPreview!;
    final readingTime = (text.length / 300).ceil();
    final paragraphs = text.split('\n').where((p) => p.trim().isNotEmpty).toList();
    final keywords = result.keywords?.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList() ?? [];

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surface,
          child: Row(
            children: [
              _buildTextStat(Icons.text_fields, '${text.length} 字', theme),
              const SizedBox(width: 16),
              _buildTextStat(Icons.timer_outlined, '约 $readingTime 分钟', theme),
              const SizedBox(width: 16),
              _buildTextStat(Icons.short_text, '${paragraphs.length} 段', theme),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: paragraphs.length,
            itemBuilder: (_, i) {
              final paragraph = paragraphs[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SelectableText.rich(
                  TextSpan(
                    children: _highlightKeywords(paragraph, keywords, theme),
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.6),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  List<TextSpan> _highlightKeywords(
      String text, List<String> keywords, ThemeData theme) {
    if (keywords.isEmpty) return [TextSpan(text: text)];

    final spans = <TextSpan>[];
    var remaining = text;
    while (remaining.isNotEmpty) {
      String? firstKeyword;
      int firstIndex = remaining.length;
      for (final kw in keywords) {
        final idx = remaining.toLowerCase().indexOf(kw.toLowerCase());
        if (idx >= 0 && idx < firstIndex) {
          firstIndex = idx;
          firstKeyword = kw;
        }
      }
      if (firstKeyword == null) {
        spans.add(TextSpan(text: remaining));
        break;
      }
      if (firstIndex > 0) {
        spans.add(TextSpan(text: remaining.substring(0, firstIndex)));
      }
      spans.add(TextSpan(
        text: remaining.substring(firstIndex, firstIndex + firstKeyword.length),
        style: TextStyle(
          backgroundColor: Colors.yellow.shade200,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      ));
      remaining = remaining.substring(firstIndex + firstKeyword.length);
    }
    return spans;
  }

  Widget _buildTextStat(IconData icon, String label, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade600),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ],
    );
  }

  // ============================================================
  // Tab 6: SEO 检测
  // ============================================================

  Widget _buildSeoTab(_UrlParseResult result, ThemeData theme) {
    final seo = _analyzeSeo(result, result.finalUrl ?? result.url);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 评分卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('SEO 综合评分',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                Text('${seo.score.round()}',
                    style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: _seoGradeColor(seo.grade))),
                Text(seo.grade,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _seoGradeColor(seo.grade))),
                const SizedBox(height: 12),
                // 简易进度条
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: seo.score / 100,
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(
                        _seoGradeColor(seo.grade)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 详细检测项
        _buildInfoSection('检测项', [
          _buildSeoCheckItem('Title 标签', seo.titleIssue, seo.titleIssue == null,
              '${seo.titleLength} 字符'),
          _buildSeoCheckItem('Meta Description', seo.descriptionIssue,
              seo.descriptionIssue == null,
              seo.hasDescription ? '${seo.descriptionLength} 字符' : '缺失'),
          _buildSeoCheckItem('H1 标签', seo.h1Issue, seo.h1Issue == null,
              seo.h1Count == 0 ? '缺失' : '${seo.h1Count} 个'),
          _buildSeoCheckItem('HTTPS', null, seo.isHttps,
              seo.isHttps ? '已启用' : '未启用'),
          _buildSeoCheckItem('Favicon', null, seo.hasFavicon,
              seo.hasFavicon ? '已设置' : '缺失'),
          _buildSeoCheckItem('OG 标签', null, seo.hasOgTags,
              seo.hasOgTags ? '已设置' : '缺失'),
          _buildSeoCheckItem('图片 Alt 属性', null, seo.imageAltRatio > 0.8,
              '${seo.imageAltMissingCount}/${result.images.length} 缺失'),
          _buildSeoCheckItem('站内/站外链接', null, seo.internalLinkCount > seo.externalLinkCount,
              '${seo.internalLinkCount} 站内 / ${seo.externalLinkCount} 站外'),
        ], theme),
      ],
    );
  }

  Color _seoGradeColor(String grade) {
    switch (grade) {
      case '优秀':
        return Colors.green;
      case '良好':
        return Colors.blue;
      case '一般':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  Widget _buildSeoCheckItem(
      String label, String? issue, bool isGood, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isGood ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: isGood ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (issue != null)
                  Text(issue,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.red.shade600)),
                Text(detail,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Tab 7: 结构化数据（JSON-LD）
  // ============================================================

  Widget _buildJsonLdTab(_UrlParseResult result, ThemeData theme) {
    if (result.jsonLd.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schema_outlined, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text('未检测到结构化数据',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 4),
            Text('该页面未嵌入 JSON-LD 结构化数据',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result.jsonLd.length,
      itemBuilder: (_, i) {
        final data = result.jsonLd[i];
        return _buildJsonLdCard(data, i, theme);
      },
    );
  }

  Map<String, dynamic>? _castMap(dynamic v) {
    if (v is Map) return v.cast<String, dynamic>();
    return null;
  }

  Widget _buildJsonLdCard(dynamic data, int index, ThemeData theme) {
    final map = _castMap(data);
    if (map == null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('$data',
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ),
      );
    }

    final type = map['@type'] ?? (() {
      final graph = map['@graph'];
      if (graph is List && graph.isNotEmpty) {
        final first = graph[0];
        if (first is Map) return first['@type'];
      }
      return null;
    }()) as String? ?? 'Unknown';
    final name = map['name'] ?? map['headline'] ?? map['title'] ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schema, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('$type',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary)),
                ),
              ],
            ),
            if (name is String && name.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(name,
                  style:
                      const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 8),
            ..._buildJsonLdFields(map, '', theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildJsonLdFields(
      Map<String, dynamic> map, String prefix, ThemeData theme) {
    final widgets = <Widget>[];
    final skipKeys = {'@context', '@type', '@id', '@graph'};
    for (final entry in map.entries) {
      if (skipKeys.contains(entry.key)) continue;
      final label = prefix.isNotEmpty ? '$prefix.${entry.key}' : entry.key;
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 100,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600)),
              ),
              Expanded(
                child: Text(value,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2),
              ),
            ],
          ),
        ));
      } else if (value is List && value.isNotEmpty && value.first is String) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 100,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade600)),
              ),
              Expanded(
                child: Text((value as List).join(', '),
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ));
      }
    }
    return widgets;
  }

  // ============================================================
  // 通用 UI 组件
  // ============================================================

  Widget _buildInfoSection(String title, List<Widget> children, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary)),
        const Divider(height: 16),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String value,
      {int maxLines = 2, bool canCopy = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: GestureDetector(
              onLongPress: canCopy ? () => _copyText(value) : null,
              child: Text(value,
                  style: const TextStyle(fontSize: 13),
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
          if (canCopy)
            InkWell(
              onTap: () => _copyText(value),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.copy,
                    size: 14, color: Colors.grey.shade400),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // 操作：打开链接 / 复制 / 分享 / 预览图片
  // ============================================================

  Future<void> _openLink(String href, String baseUrl) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    Uri target;
    if (!uri.hasScheme) {
      final base = Uri.tryParse(baseUrl);
      if (base == null) return;
      target = base.resolve(href);
    } else {
      target = uri;
    }
    try {
      if (await canLaunchUrl(target)) {
        await launchUrl(target, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      AppLogger.e('UrlParserPage', '打开链接失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接: $e')),
        );
      }
    }
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('已复制'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _shareResult(BuildContext context) {
    final r = _result;
    if (r == null) return;
    final text = StringBuffer()
      ..writeln('URL 解析结果')
      ..writeln('=' * 30)
      ..writeln('URL: ${r.url}')
      ..writeln('标题: ${r.title ?? "(无)"}')
      ..writeln('描述: ${r.description ?? "(无)"}')
      ..writeln('关键词: ${r.keywords ?? "(无)"}')
      ..writeln('字符数: ${r.wordCount}')
      ..writeln('链接数: ${r.linkCount}')
      ..writeln('图片数: ${r.imageCount}');
    Share.share(text.toString(), subject: 'URL 解析结果 - ${r.title ?? r.url}');
  }

  void _previewImage(BuildContext context, String src, String alt) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                src,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.black54,
                  height: 200,
                  child: const Center(
                    child: Icon(Icons.broken_image,
                        size: 48, color: Colors.white54),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (alt.isNotEmpty)
              Text(alt,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
