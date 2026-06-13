// 网址解析工具页面
// v1.52.3+ 新增：输入网址，爬取并解析网页内容信息
// 通过服务端 axios + cheerio 实现网页爬取与结构化数据提取
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../../utils/app_settings.dart';

/// 网址解析结果数据模型
class _UrlParseResult {
  final String url;
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

  _UrlParseResult({
    required this.url,
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
  });

  factory _UrlParseResult.fromJson(Map<String, dynamic> json) {
    return _UrlParseResult(
      url: json['url'] ?? '',
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
      headingsByLevel: Map<String, int>.from(json['stats']?['headingsByLevel'] ?? {}),
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

class UrlParserPage extends StatefulWidget {
  const UrlParserPage({super.key});

  @override
  State<UrlParserPage> createState() => _UrlParserPageState();
}

class _UrlParserPageState extends State<UrlParserPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();

  bool _isLoading = false;
  String? _errorMessage;
  _UrlParseResult? _result;

  // Tab 控制器
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  /// 执行网址解析
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
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _result = _UrlParseResult.fromJson(data);
          _tabController.index = 0; // 重置到第一个tab
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('网址解析工具'),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 输入区域
          _buildInputArea(theme),
          // 结果展示区域
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('正在解析网址...', style: TextStyle(color: Colors.grey)),
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

  /// 输入区域
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
              decoration: InputDecoration(
                hintText: '输入网址，如 https://www.example.com',
                hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
                prefixIcon: const Icon(Icons.link, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                isDense: true,
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
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.search, size: 18),
              label: Text(_isLoading ? '解析中' : '解析'),
            ),
          ),
        ],
      ),
    );
  }

  /// 空状态视图
  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.web, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text('输入网址，点击解析按钮', style: TextStyle(color: Colors.grey.shade500)),
          const SizedBox(height: 4),
          Text('支持解析网页标题、描述、关键词、链接等信息',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  /// 错误视图
  Widget _buildErrorView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(_errorMessage!, textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade700)),
          ],
        ),
      ),
    );
  }

  /// 解析结果视图
  Widget _buildResultView(ThemeData theme) {
    final result = _result!;
    return Column(
      children: [
        // 概览信息卡片
        _buildOverviewCard(result, theme),
        // Tab 栏
        TabBar(
          controller: _tabController,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: Colors.grey,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: '概览'),
            Tab(text: '标题结构'),
            Tab(text: '链接'),
            Tab(text: '正文'),
          ],
        ),
        const Divider(height: 1),
        // Tab 内容
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOverviewTab(result, theme),
              _buildHeadingsTab(result, theme),
              _buildLinksTab(result, theme),
              _buildTextTab(result, theme),
            ],
          ),
        ),
      ],
    );
  }

  /// 概览信息卡片
  Widget _buildOverviewCard(_UrlParseResult result, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            if (result.title != null && result.title!.isNotEmpty) ...[
              Text(result.title!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
            ],
            // 描述
            if (result.description != null && result.description!.isNotEmpty) ...[
              Text(result.description!, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
            ],
            // 统计信息
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildStatChip(Icons.text_fields, '${result.wordCount} 字符', theme),
                _buildStatChip(Icons.link, '${result.linkCount} 链接', theme),
                _buildStatChip(Icons.image, '${result.imageCount} 图片', theme),
                _buildStatChip(Icons.title, '${result.headingCount} 标题', theme),
              ],
            ),
            // 关键词
            if (result.keywords != null && result.keywords!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('关键词: ${result.keywords!}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ],
        ),
      ),
    );
  }

  /// 统计徽章
  Widget _buildStatChip(IconData icon, String label, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
      ],
    );
  }

  /// 概览 Tab
  Widget _buildOverviewTab(_UrlParseResult result, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 页面基本信息
        _buildInfoSection('页面信息', [
          _buildInfoRow('URL', result.url),
          if (result.title != null) _buildInfoRow('标题', result.title!),
          if (result.description != null)
            _buildInfoRow('描述', result.description!, maxLines: 3),
          if (result.keywords != null)
            _buildInfoRow('关键词', result.keywords!),
          if (result.ogSiteName != null)
            _buildInfoRow('站点名称', result.ogSiteName!),
          if (result.ogType != null) _buildInfoRow('OG类型', result.ogType!),
        ], theme),
        const SizedBox(height: 16),
        // 标题层级统计
        if (result.headingsByLevel.isNotEmpty)
          _buildInfoSection('标题层级统计', [
            for (int i = 1; i <= 6; i++)
              if ((result.headingsByLevel['h$i'] ?? 0) > 0)
                _buildInfoRow('H$i', '${result.headingsByLevel['h$i']} 个'),
          ], theme),
        const SizedBox(height: 16),
        // 图片列表
        if (result.images.isNotEmpty)
          _buildInfoSection('图片列表 (${result.images.length})', [
            for (final img in result.images.take(10))
              _buildInfoRow(img.alt.isNotEmpty ? img.alt : '(无描述)', img.src,
                  maxLines: 1),
          ], theme),
      ],
    );
  }

  /// 标题结构 Tab
  Widget _buildHeadingsTab(_UrlParseResult result, ThemeData theme) {
    if (result.headings.isEmpty) {
      return const Center(child: Text('暂无标题结构', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result.headings.length,
      itemBuilder: (_, i) {
        final h = result.headings[i];
        final indent = (h.level - 1) * 16.0;
        final fontSize = 18.0 - h.level * 1.5;
        return Padding(
          padding: EdgeInsets.only(left: indent, bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _headingColor(h.level).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('H${h.level}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: _headingColor(h.level))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(h.text,
                    style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 链接列表 Tab
  Widget _buildLinksTab(_UrlParseResult result, ThemeData theme) {
    if (result.links.isEmpty) {
      return const Center(child: Text('暂无链接', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result.links.length,
      itemBuilder: (_, i) {
        final link = result.links[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.link, size: 18, color: theme.colorScheme.primary),
            title: Text(link.text, style: const TextStyle(fontSize: 13), maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(link.href, style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }

  /// 正文预览 Tab
  Widget _buildTextTab(_UrlParseResult result, ThemeData theme) {
    if (result.textPreview == null || result.textPreview!.isEmpty) {
      return const Center(child: Text('暂无正文内容', style: TextStyle(color: Colors.grey)));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        result.textPreview!,
        style: const TextStyle(fontSize: 14, height: 1.6),
      ),
    );
  }

  /// 信息区块
  Widget _buildInfoSection(String title, List<Widget> children, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary)),
        const Divider(height: 16),
        ...children,
      ],
    );
  }

  /// 信息行
  Widget _buildInfoRow(String label, String value, {int maxLines = 2}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13),
                maxLines: maxLines, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  /// 标题层级颜色
  Color _headingColor(int level) {
    switch (level) {
      case 1: return Colors.blue;
      case 2: return Colors.teal;
      case 3: return Colors.orange;
      case 4: return Colors.purple;
      case 5: return Colors.brown;
      case 6: return Colors.grey;
      default: return Colors.grey;
    }
  }
}