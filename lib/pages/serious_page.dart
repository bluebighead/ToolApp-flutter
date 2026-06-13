// 「一本正经」趣味工具 — 伪装成文本编辑器的秘密阅读器
// 用户上传 TXT/DOCX 小说后，在编辑界面输入文字，
// 实际显示的是小说内容（根据输入字符数逐步展示）。
// 支持保存阅读进度、查看历史记录、URL网页解析提取小说。
// v1.52.2+ 新增：网址解析提取、滑杆修复、退出未保存提醒、自动保存设置
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart' as archive;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:gbk_codec/gbk_codec.dart';

import '../utils/app_logger.dart';

// ============================================================
// 阅读进度数据模型
// ============================================================
class _ReadingProgress {
  final String bookName;       // 书名
  final String bookPath;       // 书籍文件路径（用于重新加载）
  final int totalChars;        // 小说总字符数
  int readPosition;            // 当前阅读位置（已显示的字符数）
  final DateTime lastReadTime; // 上次阅读时间
  final double progressPercent; // 阅读进度百分比

  _ReadingProgress({
    required this.bookName,
    required this.bookPath,
    required this.totalChars,
    required this.readPosition,
    required this.lastReadTime,
  }) : progressPercent = totalChars > 0 ? (readPosition / totalChars * 100).clamp(0, 100) : 0;

  /// 从 JSON 反序列化
  factory _ReadingProgress.fromJson(Map<String, dynamic> json) {
    return _ReadingProgress(
      bookName: json['bookName'] as String,
      bookPath: json['bookPath'] as String,
      totalChars: json['totalChars'] as int,
      readPosition: json['readPosition'] as int,
      lastReadTime: DateTime.parse(json['lastReadTime'] as String),
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'bookName': bookName,
        'bookPath': bookPath,
        'totalChars': totalChars,
        'readPosition': readPosition,
        'lastReadTime': lastReadTime.toIso8601String(),
      };
}

// ============================================================
// 设置数据模型
// ============================================================
class _SeriousSettings {
  bool autoSaveEnabled;
  int autoSaveIntervalSeconds; // 自动保存间隔（秒）

  _SeriousSettings({
    this.autoSaveEnabled = false,
    this.autoSaveIntervalSeconds = 60,
  });

  static const _keyAutoSave = 'serious_auto_save_enabled';
  static const _keyAutoSaveInterval = 'serious_auto_save_interval';

  /// 从 SharedPreferences 加载
  static Future<_SeriousSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _SeriousSettings(
      autoSaveEnabled: prefs.getBool(_keyAutoSave) ?? false,
      autoSaveIntervalSeconds: prefs.getInt(_keyAutoSaveInterval) ?? 60,
    );
  }

  /// 保存到 SharedPreferences
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoSave, autoSaveEnabled);
    await prefs.setInt(_keyAutoSaveInterval, autoSaveIntervalSeconds);
  }
}

// ============================================================
// 主页面
// ============================================================
class SeriousPage extends StatefulWidget {
  const SeriousPage({super.key});

  @override
  State<SeriousPage> createState() => _SeriousPageState();
}

class _SeriousPageState extends State<SeriousPage> {
  // 输入控制器（捕获用户输入但不显示实际内容）
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();

  // 小说相关状态
  String _novelContent = '';          // 小说全部内容
  String _novelName = '未加载小说';    // 小说名称
  int _displayedCharCount = 0;        // 当前显示的字符数
  int _totalCharCount = 0;           // 小说总字符数
  bool _isNovelLoaded = false;       // 是否已加载小说

  // 用于计算显示字符数
  int _userInputLength = 0;          // 用户输入的字符总数
  double _charRatio = 3.0;           // 用户每输入1个字，显示几个小说字

  // 阅读进度列表
  List<_ReadingProgress> _progressList = [];

  // UI状态
  bool _isLoadingBook = false;
  bool _isFetchingUrl = false;       // 是否正在解析网址
  String _statusMessage = '请上传一本小说开始阅读';

  // 网址输入控制器
  final _urlController = TextEditingController();

  // v1.52.2+ 未保存变更追踪
  int _lastSavedPosition = 0;        // 上次保存时的阅读位置
  bool _hasUnsavedChanges = false;   // 是否有未保存的变更

  // v1.52.2+ 自动保存设置
  _SeriousSettings _settings = _SeriousSettings();
  Timer? _autoSaveTimer;             // 自动保存定时器

  // v1.52.3+ 滚动控制器：自动滚动 + 支持手动滚动
  final ScrollController _scrollController = ScrollController();
  bool _autoScrollEnabled = true;     // 是否启用自动滚动（用户手动上滚时暂时禁用）

  @override
  void initState() {
    super.initState();
    _loadProgressList();
    _loadSettings();
    _inputController.addListener(_onInputChanged);
    // 监听滚动事件：用户手动上滚时暂停自动滚动
    _scrollController.addListener(_onScrollChanged);
  }

  @override
  void dispose() {
    _inputController.removeListener(_onInputChanged);
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _urlController.dispose();
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  // ============================================================
  // 加载设置
  // ============================================================
  Future<void> _loadSettings() async {
    _settings = await _SeriousSettings.load();
    _syncAutoSaveTimer();
  }

  /// 同步自动保存定时器
  void _syncAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    if (_settings.autoSaveEnabled && _isNovelLoaded) {
      _autoSaveTimer = Timer.periodic(
        Duration(seconds: _settings.autoSaveIntervalSeconds),
        (_) => _autoSaveTick(),
      );
    }
  }

  /// 自动保存触发
  Future<void> _autoSaveTick() async {
    if (_hasUnsavedChanges && _isNovelLoaded) {
      await _updateProgress();
      await _loadProgressList();
      setState(() {
        _lastSavedPosition = _displayedCharCount;
        _hasUnsavedChanges = false;
      });
      AppLogger.i('SeriousPage', '自动保存完成: $_displayedCharCount / $_totalCharCount');
    }
  }

  // ============================================================
  // 加载历史阅读进度
  // ============================================================
  Future<void> _loadProgressList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList('serious_reading_progress') ?? [];
      setState(() {
        _progressList = data
            .map((s) => _ReadingProgress.fromJson(jsonDecode(s) as Map<String, dynamic>))
            .toList();
        // 按最后阅读时间倒序排列
        _progressList.sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
      });
    } catch (e) {
      AppLogger.e('SeriousPage', '加载阅读进度失败: $e');
    }
  }

  /// 保存所有阅读进度到 SharedPreferences
  Future<void> _saveProgressList() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _progressList.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList('serious_reading_progress', data);
  }

  /// 更新或新增阅读进度
  Future<void> _updateProgress() async {
    if (!_isNovelLoaded || _novelName == '未加载小说') return;
    // 查找是否存在该书的历史记录
    final existingIndex = _progressList.indexWhere((p) => p.bookName == _novelName);

    final progress = _ReadingProgress(
      bookName: _novelName,
      bookPath: '', // 通过名称查找
      totalChars: _totalCharCount,
      readPosition: _displayedCharCount,
      lastReadTime: DateTime.now(),
    );

    if (existingIndex >= 0) {
      _progressList[existingIndex] = progress;
    } else {
      _progressList.insert(0, progress);
    }
    // 重新排序
    _progressList.sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
    await _saveProgressList();
  }

  // ============================================================
  // 滚动监听：用户手动上滚时暂停自动滚动，滚回底部时恢复
  // ============================================================
  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    // 距离底部不到50像素视为在底部
    final atBottom = (maxScroll - currentScroll) < 50;
    if (atBottom != _autoScrollEnabled) {
      _autoScrollEnabled = atBottom;
    }
  }

  /// 自动滚动到底部（如果用户没有手动上滚）
  void _autoScrollToBottom() {
    if (_autoScrollEnabled && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && _autoScrollEnabled) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  // ============================================================
  // 用户输入变化回调（核心逻辑）
  // v1.52.3+ 修复：支持输入法组合输入和退格删除
  // ============================================================
  void _onInputChanged() {
    if (!_isNovelLoaded) return;

    // 输入法正在组合中（例如中文拼音选字），暂不处理，等组合完成
    if (_inputController.value.composing.isValid) {
      return;
    }

    final text = _inputController.text;
    final newLength = text.length;

    if (newLength > _userInputLength) {
      // 用户新增了字符：显示更多小说内容
      final addedChars = newLength - _userInputLength;
      final novelCharsToAdd = (addedChars * _charRatio).round();
      final newDisplayed = math.min(_displayedCharCount + novelCharsToAdd, _totalCharCount);
      setState(() {
        _userInputLength = newLength;
        _displayedCharCount = newDisplayed;
        _hasUnsavedChanges = (_displayedCharCount != _lastSavedPosition);
      });
      _autoScrollToBottom();
      _scheduleClearInput();
    } else if (newLength < _userInputLength) {
      // 用户删除了字符（按退格键）：减少显示的小说内容
      final removedChars = _userInputLength - newLength;
      final novelCharsToRemove = (removedChars * _charRatio).round();
      setState(() {
        _userInputLength = math.max(0, newLength);
        _displayedCharCount = math.max(0, _displayedCharCount - novelCharsToRemove);
        _hasUnsavedChanges = (_displayedCharCount != _lastSavedPosition);
      });
      _scheduleClearInput();
    }
  }

  /// 延迟清空输入框（让用户感觉输入被"吞噬"了）
  /// v1.52.3+ 修复：仅在无组合输入时清空
  void _scheduleClearInput() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted && !_inputController.value.composing.isValid) {
        _inputController.removeListener(_onInputChanged);
        _inputController.clear();
        _userInputLength = 0;
        _inputController.addListener(_onInputChanged);
      }
    });
  }

  // ============================================================
  // 文件导入
  // ============================================================
  Future<void> _pickAndLoadBook() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'docx'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;

      setState(() {
        _isLoadingBook = true;
        _statusMessage = '正在加载小说...';
      });

      final path = file.path!;
      await _loadBookFromPath(path, p.basenameWithoutExtension(path));
    } catch (e) {
      setState(() {
        _isLoadingBook = false;
        _statusMessage = '加载失败: ${e.toString().split('\n').first}';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: ${e.toString().split('\n').first}')),
        );
      }
    }
  }

  /// 从文件路径加载书籍
  Future<void> _loadBookFromPath(String path, String name) async {
    final ext = p.extension(path).toLowerCase();
    String content = '';

    if (ext == '.txt') {
      final bytes = await File(path).readAsBytes();
      content = _decodeTextFile(bytes);
    } else if (ext == '.docx') {
      content = await _parseDocx(path);
      if (content.isEmpty) {
        throw Exception('无法解析该DOCX文件，请确认文件格式正确');
      }
    }

    if (content.isEmpty) {
      throw Exception('文件内容为空');
    }

    _applyLoadedContent(content, name);
  }

  /// 应用加载的内容
  void _applyLoadedContent(String content, String name) {
    setState(() {
      _novelContent = content;
      _novelName = name;
      _totalCharCount = content.length;
      _displayedCharCount = 0;
      _userInputLength = 0;
      _lastSavedPosition = 0;
      _hasUnsavedChanges = false;
      _isNovelLoaded = true;
      _isLoadingBook = false;
      _isFetchingUrl = false;
      _statusMessage = '已加载：$name（共${_totalCharCount}字）';
    });

    // 检查是否有历史进度
    _checkHistoryProgress(name);

    // 同步自动保存定时器
    _syncAutoSaveTimer();
  }

  // ============================================================
  // v1.52.2+ 网址解析提取
  // ============================================================
  /// 从网址抓取并解析小说/资讯文本内容
  Future<void> _fetchFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入网址')),
      );
      return;
    }

    // 简单URL格式校验
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的网址（以 http:// 或 https:// 开头）')),
      );
      return;
    }

    setState(() {
      _isFetchingUrl = true;
      _statusMessage = '正在解析网址内容...';
    });

    try {
      // 发送HTTP请求获取网页
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('服务器返回状态码: ${response.statusCode}');
      }

      // 解析HTML
      final document = html_parser.parse(response.body);
      final body = document.body;
      if (body == null) {
        throw Exception('无法解析网页内容');
      }

      // 提取纯文本（移除脚本、样式、导航等非内容元素）
      // 先移除不需要的标签
      final removeTags = ['script', 'style', 'nav', 'header', 'footer', 'aside', 'noscript', 'iframe', 'form'];
      for (final tag in removeTags) {
        body.querySelectorAll(tag).forEach((e) => e.remove());
      }

      // 获取body的纯文本
      String rawText = body.text ?? '';

      // 清理文本：合并多余空白、保留段落结构
      rawText = rawText
          .replaceAll(RegExp(r'[ \t]+'), ' ')     // 合并空格和制表符
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')   // 合并多余空行
          .trim();

      if (rawText.isEmpty) {
        throw Exception('无法从该网页提取到文本内容');
      }

      // 判断是否包含小说/资讯类内容
      // 小说特征：较长文本，有段落结构，包含常见中文标点
      final hasChineseContent = RegExp(r'[\u4e00-\u9fff]').hasMatch(rawText);
      final hasParagraphs = rawText.contains('\n');
      final isLongEnough = rawText.length > 200;

      if (!hasChineseContent || !isLongEnough) {
        setState(() => _isFetchingUrl = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('该网页中未检测到小说或资讯类内容，无法提取'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      // 提取小说名称（从URL或页面标题）
      final titleTag = document.querySelector('title');
      String novelName = titleTag?.text?.trim() ?? '';
      // 清理标题（移除网站名等后缀）
      if (novelName.contains('|')) novelName = novelName.split('|').first.trim();
      if (novelName.contains('-')) novelName = novelName.split('-').first.trim();
      if (novelName.contains('_')) novelName = novelName.split('_').first.trim();
      if (novelName.length > 50) novelName = novelName.substring(0, 50);
      if (novelName.isEmpty) {
        // 从URL提取文件名
        final uri = Uri.parse(url);
        novelName = uri.host.replaceAll('www.', '').split('.').first;
      }

      // 保存到本地文件
      await _saveFetchedContent(novelName, rawText);

      // 应用内容
      _applyLoadedContent(rawText, novelName);

      AppLogger.i('SeriousPage', '网址解析成功: $novelName, ${rawText.length}字');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解析成功！提取到 ${rawText.length} 字')),
        );
      }
    } catch (e) {
      setState(() => _isFetchingUrl = false);
      _statusMessage = '解析失败: ${e.toString().split('\n').first}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('解析失败: ${e.toString().split('\n').first}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }

      AppLogger.e('SeriousPage', '网址解析失败: $e');
    }
  }

  /// 保存从网址获取的内容到本地
  Future<void> _saveFetchedContent(String name, String content) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final bookDir = Directory(p.join(docDir.path, 'serious_books'));
      if (!await bookDir.exists()) {
        await bookDir.create(recursive: true);
      }

      // 清理文件名中的非法字符
      final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final filePath = p.join(bookDir.path, '$safeName.txt');

      // 保存为UTF-8编码的TXT文件
      await File(filePath).writeAsString(content, encoding: utf8);
      AppLogger.i('SeriousPage', '小说已保存到本地: $filePath');
    } catch (e) {
      AppLogger.w('SeriousPage', '保存到本地失败: $e');
    }
  }

  /// 检查是否有该书的阅读历史，有则恢复进度
  void _checkHistoryProgress(String bookName) {
    final existing = _progressList.where((p) => p.bookName == bookName).toList();
    if (existing.isNotEmpty) {
      final progress = existing.first;
      if (progress.readPosition > 0 && progress.readPosition < _totalCharCount) {
        setState(() {
          _displayedCharCount = progress.readPosition;
          _lastSavedPosition = progress.readPosition;
          _hasUnsavedChanges = false;
          _statusMessage = '已恢复阅读进度：${(progress.progressPercent).toStringAsFixed(1)}%';
        });
        // 同步内部计数器：根据恢复的字符数估算用户输入长度
        _userInputLength = (_displayedCharCount / _charRatio).round();
      }
    }
  }

  /// 解码文本文件（自动检测 UTF-8 / GBK / GB2312）
  String _decodeTextFile(List<int> bytes) {
    // 先尝试 UTF-8
    try {
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        // UTF-8 BOM
        return Utf8Decoder().convert(bytes.sublist(3));
      }
      return Utf8Decoder().convert(bytes);
    } catch (_) {
      // UTF-8 失败，尝试 GBK
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // 最后尝试 Latin-1（保留原始字节）
        return Latin1Codec().decode(bytes);
      }
    }
  }

  /// 解析 DOCX 文件
  Future<String> _parseDocx(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final zip = archive.ZipDecoder().decodeBytes(bytes);

    String xmlContent = '';
    for (final file in zip) {
      if (file.name == 'word/document.xml') {
        xmlContent = Utf8Decoder().convert(file.content as List<int>);
        break;
      }
    }

    if (xmlContent.isEmpty) return '';

    // 简单提取 <w:t> 标签中的文本
    final buffer = StringBuffer();
    final tTagRegex = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true);
    final matches = tTagRegex.allMatches(xmlContent);
    for (final match in matches) {
      final text = match.group(1) ?? '';
      buffer.write(text);
    }

    // 在段落标签处插入换行
    String result = buffer.toString();
    result = result.replaceAll(RegExp(r'</w:p>'), '\n');
    // 清理多余的空白行
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return result.trim();
  }

  // ============================================================
  // 保存当前阅读进度
  // ============================================================
  Future<void> _onSaveProgress() async {
    if (!_isNovelLoaded) return;
    await _updateProgress();
    await _loadProgressList();
    setState(() {
      _lastSavedPosition = _displayedCharCount;
      _hasUnsavedChanges = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('阅读进度已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  // ============================================================
  // v1.52.2+ 退出阅读（带未保存提醒）
  // ============================================================
  Future<void> _onExit() async {
    // 如果已经保存过，或没有未保存变更，直接退出
    if (!_hasUnsavedChanges || !_isNovelLoaded) {
      if (mounted) Navigator.pop(context);
      return;
    }

    // 有未保存变更，弹出确认对话框
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出阅读'),
        content: const Text('您有未保存的阅读进度，是否保存后再退出？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('不保存', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );

    if (action == 'save') {
      await _updateProgress();
      await _loadProgressList();
    } else if (action == 'cancel') {
      return; // 不退出
    }

    if (mounted) {
      Navigator.pop(context);
    }
  }

  // ============================================================
  // 显示历史记录面板
  // ============================================================
  void _showHistoryDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _HistoryDialog(
        progressList: _progressList,
        onResume: (progress) {
          Navigator.pop(ctx); // 关闭历史对话框
          _resumeReading(progress);
        },
        onDelete: (indices) {
          setState(() {
            // 按索引降序删除避免错位
            for (final i in indices..sort((a, b) => b.compareTo(a))) {
              _progressList.removeAt(i);
            }
          });
          _saveProgressList();
        },
      ),
    );
  }

  /// 从历史记录恢复阅读
  void _resumeReading(_ReadingProgress progress) {
    _loadBookFromHistory(progress);
  }

  Future<void> _loadBookFromHistory(_ReadingProgress progress) async {
    setState(() {
      _isLoadingBook = true;
      _statusMessage = '正在恢复: ${progress.bookName}...';
    });

    try {
      // 尝试从应用文档目录加载
      final docDir = await getApplicationDocumentsDirectory();
      final bookDir = Directory(p.join(docDir.path, 'serious_books'));
      String? content;

      if (await bookDir.exists()) {
        // 搜索匹配的小说文件
        await for (final entity in bookDir.list()) {
          if (entity is File) {
            final name = p.basenameWithoutExtension(entity.path);
            if (name == progress.bookName) {
              final ext = p.extension(entity.path).toLowerCase();
              if (ext == '.txt') {
                content = _decodeTextFile(await entity.readAsBytes());
              } else if (ext == '.docx') {
                content = await _parseDocx(entity.path);
              }
              break;
            }
          }
        }
      }

      if (content == null) {
        setState(() {
          _isLoadingBook = false;
          _statusMessage = '未找到小说文件，请重新上传';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到原始小说文件，请重新导入')),
          );
        }
        return;
      }

      setState(() {
        _novelContent = content!;
        _novelName = progress.bookName;
        _totalCharCount = content.length;
        _displayedCharCount = progress.readPosition.clamp(0, content.length);
        // v1.52.7+ 修复：恢复阅读时 _userInputLength 必须重置为 0
        // _onInputChanged 用 _userInputLength 对比 TextField 的实时文本长度来判断增删
        // 如果设为旧值（如100），用户键入首个字符时 newLength=1 < oldLength=100，
        // 会错误触发"用户删除了字符"分支，导致已恢复的进度被清空
        _userInputLength = 0;
        _lastSavedPosition = progress.readPosition;
        _hasUnsavedChanges = false;
        _isNovelLoaded = true;
        _isLoadingBook = false;
        _statusMessage = '已恢复: ${progress.bookName}（${(progress.progressPercent).toStringAsFixed(1)}%）';
      });

      _syncAutoSaveTimer();
    } catch (e) {
      setState(() {
        _isLoadingBook = false;
        _statusMessage = '恢复失败: ${e.toString().split('\n').first}';
      });
    }
  }

  // ============================================================
  // v1.52.2+ 修复：阅读速度设置（使用 StatefulBuilder 修复滑杆无法拖动）
  // ============================================================
  void _showRatioDialog() {
    final controller = TextEditingController(text: _charRatio.toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) {
          return AlertDialog(
            title: const Text('阅读速度设置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('用户每输入1个字符，显示多少个小说字？\n（数值越大，阅读速度越快）'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '显示比例',
                    suffixText: '字/字符',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final val = double.tryParse(v);
                    if (val != null && val > 0) {
                      dialogSetState(() {});
                    }
                  },
                ),
                const SizedBox(height: 8),
                Slider(
                  value: double.tryParse(controller.text) ?? _charRatio,
                  min: 0.5,
                  max: 10.0,
                  divisions: 19,
                  label: '${(double.tryParse(controller.text) ?? _charRatio).toStringAsFixed(1)} 字/字符',
                  onChanged: (v) {
                    controller.text = v.toStringAsFixed(1);
                    dialogSetState(() {});
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final newRatio = double.tryParse(controller.text);
                  if (newRatio != null && newRatio > 0) {
                    setState(() => _charRatio = newRatio);
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // v1.52.2+ 设置对话框
  // ============================================================
  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) {
          return AlertDialog(
            title: const Text('阅读设置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 自动保存开关
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动保存'),
                  subtitle: Text(
                    _settings.autoSaveEnabled
                        ? '每 ${_settings.autoSaveIntervalSeconds} 秒自动保存一次'
                        : '关闭自动保存',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _settings.autoSaveEnabled,
                  onChanged: (v) {
                    dialogSetState(() {
                      _settings.autoSaveEnabled = v;
                    });
                  },
                ),
                if (_settings.autoSaveEnabled) ...[
                  const SizedBox(height: 8),
                  // 自动保存间隔
                  Text(
                    '自动保存间隔：${_settings.autoSaveIntervalSeconds}秒',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Slider(
                    value: _settings.autoSaveIntervalSeconds.toDouble(),
                    min: 10,
                    max: 300,
                    divisions: 29,
                    label: '${_settings.autoSaveIntervalSeconds}秒',
                    onChanged: (v) {
                      dialogSetState(() {
                        _settings.autoSaveIntervalSeconds = v.round();
                      });
                    },
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  await _settings.save();
                  _syncAutoSaveTimer();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
                    );
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // 构建UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // 拦截返回键，触发退出逻辑
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onExit();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F0E8), // 护眼的米色背景
        appBar: AppBar(
          title: const Text('一本正经'),
          backgroundColor: Colors.brown.shade600,
          foregroundColor: Colors.white,
          actions: [
            // 速度调节按钮
            IconButton(
              icon: const Icon(Icons.speed),
              tooltip: '阅读速度',
              onPressed: _showRatioDialog,
            ),
            // 保存进度按钮
            IconButton(
              icon: Icon(
                Icons.save,
                color: _hasUnsavedChanges ? Colors.yellow.shade300 : null,
              ),
              tooltip: _hasUnsavedChanges ? '保存进度（有未保存变更）' : '保存进度',
              onPressed: _isNovelLoaded ? _onSaveProgress : null,
            ),
            // 历史记录按钮
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '历史记录',
              onPressed: _showHistoryDialog,
            ),
            // v1.52.2+ 设置按钮
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '阅读设置',
              onPressed: _showSettingsDialog,
            ),
            // 退出按钮
            IconButton(
              icon: const Icon(Icons.exit_to_app),
              tooltip: '退出阅读',
              onPressed: _onExit,
            ),
          ],
        ),
        body: _isNovelLoaded ? _buildEditorUI(theme) : _buildWelcomeUI(theme),
      ),
    );
  }

  /// 构建欢迎界面（未加载小说时）
  Widget _buildWelcomeUI(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.book,
              size: 80,
              color: Colors.brown.shade300,
            ),
            const SizedBox(height: 24),
            Text(
              '一本正经',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Colors.brown.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '伪装成文本编辑器的秘密阅读器',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // 上传小说按钮
            SizedBox(
              width: 260,
              height: 50,
              child: FilledButton.icon(
                onPressed: _isLoadingBook ? null : _pickAndLoadBook,
                icon: _isLoadingBook
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(_isLoadingBook ? '加载中...' : '上传小说（TXT / DOCX）'),
              ),
            ),

            const SizedBox(height: 20),

            // v1.52.2+ 网址解析区域
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('或者', style: TextStyle(color: Colors.grey, fontSize: 13)),
                ),
                Expanded(child: Divider()),
              ],
            ),

            const SizedBox(height: 16),

            // 网址输入框
            Container(
              width: 360,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.brown.shade200),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.link, size: 20, color: Colors.brown.shade400),
                      const SizedBox(width: 8),
                      const Text(
                        '输入小说/资讯网站网址',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    enabled: !_isFetchingUrl,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      hintText: 'https://www.example.com/novel',
                      hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      suffixIcon: _isFetchingUrl
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.arrow_forward, size: 20),
                              onPressed: _fetchFromUrl,
                              tooltip: '解析网址',
                            ),
                    ),
                    onSubmitted: (_) => _fetchFromUrl(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 历史记录快捷入口
            if (_progressList.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _showHistoryDialog,
                icon: const Icon(Icons.history),
                label: Text('历史记录（${_progressList.length}本）'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 构建编辑器界面（加载小说后）
  Widget _buildEditorUI(ThemeData theme) {
    final displayedText = _displayedCharCount > 0
        ? _novelContent.substring(0, _displayedCharCount)
        : '';

    // 计算光标位置
    final cursorPosition = _totalCharCount > 0
        ? (_displayedCharCount / _totalCharCount).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      children: [
        // 顶部状态栏
        _buildStatusBar(theme),

        // 编辑区域（显示小说内容）
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
              border: Border.all(color: Colors.brown.shade200, width: 1),
            ),
            child: GestureDetector(
              onTap: () {
                // 点击显示区时聚焦隐藏输入框，唤出键盘
                _inputFocusNode.requestFocus();
              },
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                thickness: 6,
                radius: const Radius.circular(3),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: displayedText.isEmpty
                          ? Text(
                              '在此处输入任意文字开始阅读...',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade400,
                                fontStyle: FontStyle.italic,
                                height: 1.8,
                              ),
                            )
                          : RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey.shade800,
                                  height: 1.8,
                                  fontFamily: 'serif',
                                ),
                                children: _buildDisplaySpans(displayedText, cursorPosition),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // v1.52.6+ 隐藏输入框：使用 SizedBox(height:0) 替代 off-screen Positioning
        // 关键：不能用 Opacity(opacity:0)，否则 TextField 无法获取焦点，键盘不弹出
        // 配合 clipBehavior: Clip.none 确保 0 高度 TextField 依然可以聚焦
        Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              height: 0,
              child: TextField(
                controller: _inputController,
                focusNode: _inputFocusNode,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(height: 1),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),

        // 底部提示
        _buildBottomHint(),
      ],
    );
  }

  /// 构建显示文本的Span（带光标效果）
  List<TextSpan> _buildDisplaySpans(String text, double cursorPosition) {
    if (text.isEmpty) return [];
    final spans = <TextSpan>[];
    // 将文本按行分割，最后一行末尾加光标
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) {
        spans.add(const TextSpan(text: '\n'));
      }
      if (i == lines.length - 1) {
        // 最后一行，添加闪烁光标
        spans.add(TextSpan(
          text: lines[i],
          children: [
            WidgetSpan(
              child: _CursorWidget(),
              alignment: ui.PlaceholderAlignment.middle,
            ),
          ],
        ));
      } else {
        spans.add(TextSpan(text: lines[i]));
      }
    }
    return spans;
  }

  /// 构建顶部状态栏
  Widget _buildStatusBar(ThemeData theme) {
    final percent = _totalCharCount > 0
        ? (_displayedCharCount / _totalCharCount * 100).clamp(0.0, 100.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.brown.shade50,
        border: Border(bottom: BorderSide(color: Colors.brown.shade200, width: 1)),
      ),
      child: Row(
        children: [
          // 书名
          Icon(Icons.book, size: 16, color: Colors.brown.shade600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _novelName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.brown.shade700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          // 进度
          Text(
            '${percent.toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.brown.shade600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$_displayedCharCount / $_totalCharCount',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
          // 速度标识
          Container(
            margin: const EdgeInsets.only(left: 10),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.brown.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'x${_charRatio.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.brown.shade600,
              ),
            ),
          ),
          // v1.52.2+ 自动保存标识
          if (_settings.autoSaveEnabled) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '自动',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.green.shade700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部提示栏
  Widget _buildBottomHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.brown.shade50,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, size: 14, color: Colors.brown.shade300),
          const SizedBox(width: 6),
          Text(
            '在此区域输入任意文字，系统将自动显示小说内容',
            style: TextStyle(
              fontSize: 12,
              color: Colors.brown.shade400,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 闪烁光标组件
// ============================================================
class _CursorWidget extends StatefulWidget {
  @override
  State<_CursorWidget> createState() => _CursorWidgetState();
}

class _CursorWidgetState extends State<_CursorWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 530),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 2,
        height: 18,
        color: Colors.brown.shade600,
        margin: const EdgeInsets.only(bottom: 2),
      ),
    );
  }
}

// ============================================================
// 历史记录弹窗
// ============================================================

class _HistoryDialog extends StatefulWidget {
  final List<_ReadingProgress> progressList;
  final Function(_ReadingProgress) onResume;
  final Function(List<int>) onDelete;

  const _HistoryDialog({
    required this.progressList,
    required this.onResume,
    required this.onDelete,
  });

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final Set<int> _selectedIndices = {};
  bool _selectAllMode = false;
  bool _editMode = false; // 编辑模式：点击为多选，否则为恢复阅读

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('阅读历史', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          // 编辑/取消编辑按钮
          TextButton(
            onPressed: () {
              setState(() {
                _editMode = !_editMode;
                if (!_editMode) {
                  _selectedIndices.clear();
                  _selectAllMode = false;
                }
              });
            },
            child: Text(
              _editMode ? '完成' : '编辑',
              style: TextStyle(fontSize: 12, color: _editMode ? Colors.blue : null),
            ),
          ),
          if (_editMode) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: () {
                setState(() {
                  if (_selectAllMode) {
                    _selectedIndices.clear();
                    _selectAllMode = false;
                  } else {
                    for (int i = 0; i < widget.progressList.length; i++) {
                      _selectedIndices.add(i);
                    }
                    _selectAllMode = true;
                  }
                });
              },
              child: Text(
                _selectAllMode ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Expanded(
              child: widget.progressList.isEmpty
                  ? const Center(child: Text('暂无阅读历史', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: widget.progressList.length,
                      itemBuilder: (_, i) {
                        final progress = widget.progressList[i];
                        final isSelected = _selectedIndices.contains(i);
                        final time = progress.lastReadTime;
                        final timeStr = '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';

                        return Card(
                          color: isSelected ? Colors.brown.withValues(alpha: 0.08) : null,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap: () {
                              if (_editMode) {
                                // 编辑模式：切换选中状态
                                setState(() {
                                  if (isSelected) {
                                    _selectedIndices.remove(i);
                                    _selectAllMode = false;
                                  } else {
                                    _selectedIndices.add(i);
                                    if (_selectedIndices.length == widget.progressList.length) {
                                      _selectAllMode = true;
                                    }
                                  }
                                });
                              } else {
                                // 普通模式：点击恢复阅读
                                widget.onResume(progress);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  // 编辑模式下显示选择图标
                                  if (_editMode) ...[
                                    Icon(
                                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                      color: isSelected ? Colors.brown : Colors.grey,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          progress.bookName,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${progress.progressPercent.toStringAsFixed(1)}%  |  $timeStr',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                        // 进度条
                                        const SizedBox(height: 4),
                                        LinearProgressIndicator(
                                          value: progress.progressPercent / 100,
                                          backgroundColor: Colors.grey.shade200,
                                          color: Colors.brown.shade300,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!_editMode)
                                    Icon(Icons.chevron_right, color: Colors.grey.shade400),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            // 底部删除按钮（编辑模式下选中项大于0时显示）
            if (_editMode && _selectedIndices.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      widget.onDelete(_selectedIndices.toList());
                      setState(() {
                        _selectedIndices.clear();
                        _selectAllMode = false;
                      });
                    },
                    icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                    label: Text(
                      '删除选中（${_selectedIndices.length}项）',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}