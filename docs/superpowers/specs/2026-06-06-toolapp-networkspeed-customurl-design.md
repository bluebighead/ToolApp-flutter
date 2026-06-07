# 工具箱 App - 网速测试自定义目标 URL 设计文档

- **日期**：2026-06-06
- **版本**：v0.1（二期微迭代）
- **作者**：Trae IDE
- **前序文档**：[2026-06-06-toolapp-networkspeed-design.md](./2026-06-06-toolapp-networkspeed-design.md)

## 一、目标

让用户可以：
1. 通过复选框切换「自定义目标 URL」模式
2. 在自定义模式下输入任意 HTTP/HTTPS URL 进行 Ping 测速
3. 跨 app 重启保留复选框状态和最近输入的 URL
4. 默认测速目标从 `https://httpbin.org/get` 改为 `https://www.baidu.com`

## 二、范围

### 本期包含
- 内联 UI（仪表盘上方一行）：复选框 + 输入框 + 当前目标提示
- SharedPreferences 持久化（两个 key）
- 测速前 URL 合法性校验（必须 `http://` 或 `https://` 开头、`Uri.parse` 不抛错）
- 校验失败时 SnackBar 阻断「开始测试」
- 历史记录 `PingRecord.server` 已存在，自然记录实际测过的 URL（无需改 schema）
- 单元测试：设置读写、URL 校验

### 本期不包含
- 多目标同时测速
- URL 历史下拉/收藏夹
- 服务端证书白名单
- 自动跟随重定向统计（仅 HEAD 首次响应延迟）

## 三、UI 设计

### 布局（方案 A：内联一行）
```
┌─ Scaffold ─────────────────────────────────┐
│  AppBar [网速测试]            [历史图标]    │
├────────────────────────────────────────────┤
│  SafeArea > Padding 16 > Column:           │
│  ┌──────────────────────────────────────┐  │
│  │ Card (padding 12)                    │  │
│  │  [☐] 自定义目标   [ https://...  ]    │  │ ← 勾选时输入框启用
│  └──────────────────────────────────────┘  │
│  当前目标: baidu.com                       │ ← host 形式
│  SizedBox 24                               │
│  [仪表盘：80px 大数字 + ms 单位]           │
│  SizedBox 24                               │
│  [10 个进度点]                             │
│  SizedBox 24                               │
│  [5 个统计卡: 最小/平均/最大/抖动/丢包]   │
│  Spacer                                    │
│  [全宽 48px 按钮：开始/停止/重试/重试]    │
│  SizedBox 8                                │
└────────────────────────────────────────────┘
```

### 组件细节
- 复选框：`Checkbox(value: _useCustomUrl, onChanged: ...)`
- 输入框：`TextField(controller: _urlController, enabled: _useCustomUrl, decoration: InputDecoration(hintText: 'https://...', isDense: true, border: OutlineInputBorder()))`
- 当前目标提示：`Text('当前目标: ${Uri.parse(_resolveTargetUrl()).host}', style: TextStyle(fontSize: 12, color: Colors.grey))`

## 四、架构与代码改动

### 4.1 新增文件
```
lib/utils/network_speed_settings.dart   # 设置读写工具
```

### 4.2 修改文件
```
lib/pages/network_speed_page.dart       # 替换 _kPingUrl，新增 UI、校验、initState 加载
test/network_speed_settings_test.dart   # 单元测试（新增）
test/network_speed_page_test.dart       # URL 校验相关测试（新增）
```

### 4.3 关键数据流

```
Page initState
  → Settings.load() → _useCustomUrl, _customUrl
  → _urlController.text = _customUrl

User toggles Checkbox
  → _customUrl = _urlController.text.trim()  // 兜底保存未失焦的输入
  → setState(_useCustomUrl = v)
  → Settings.save(useCustom: v, url: _customUrl)

User edits & loses focus (onEditingComplete)
  → _customUrl = _urlController.text.trim()
  → Settings.save(useCustom: _useCustomUrl, url: _customUrl)

User clicks 「开始测试」
  → if (_useCustomUrl && !_validateUrl(_customUrl))
       showSnackBar('请输入有效的 http/https URL')
       return
  → target = _resolveTargetUrl()
  → 现有 _runTest(target) 循环不变
  → _saveRecord(server: target)  // 实际测过的 URL
```

### 4.4 NetworkSpeedSettings 接口

```dart
class NetworkSpeedSettings {
  static const String _kKeyUseCustom = 'networkspeed_use_custom_url';
  static const String _kKeyCustomUrl = 'networkspeed_custom_url';

  /// 从 SharedPreferences 加载；缺失时返回默认值
  static Future<({bool useCustom, String url})> load();

  /// 持久化；只写入非空字段
  static Future<void> save({bool? useCustom, String? url});
}
```

### 4.5 NetworkSpeedPage 关键改动

```dart
// 替换原 const _kPingUrl
const String _kDefaultUrl = 'https://www.baidu.com';

class _NetworkSpeedPageState extends State<NetworkSpeedPage> {
  bool _useCustomUrl = false;
  String _customUrl = '';
  final _urlController = TextEditingController();
  // ... 既有字段保留 ...

  @override
  void initState() {
    super.initState();
    _client = http.Client();
    _loadSettings();  // 异步读取设置
  }

  @override
  void dispose() {
    _urlController.dispose();
    // ... 既有 dispose ...
  }

  Future<void> _loadSettings() async {
    final s = await NetworkSpeedSettings.load();
    if (!mounted) return;
    setState(() {
      _useCustomUrl = s.useCustom;
      _customUrl = s.url;
      _urlController.text = _customUrl;
    });
  }

  /// 解析当前应使用的目标 URL
  String _resolveTargetUrl() {
    return _useCustomUrl && _customUrl.isNotEmpty
        ? _customUrl
        : _kDefaultUrl;
  }

  /// 校验自定义 URL：必须 http/https 开头且能 parse
  /// 返回 null 表示通过；返回错误信息表示失败
  String? _validateUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return 'URL 不能为空';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      return 'URL 必须以 http:// 或 https:// 开头';
    }
    try {
      final u = Uri.parse(s);
      if (!u.hasScheme || (u.scheme != 'http' && u.scheme != 'https')) {
        return 'URL 必须以 http:// 或 https:// 开头';
      }
      if (u.host.isEmpty) return 'URL 缺少主机名';
    } catch (_) {
      return 'URL 格式不合法';
    }
    return null;
  }

  Future<void> _runTest() async {
    if (_useCustomUrl) {
      final err = _validateUrl(_customUrl);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err)),
        );
        return;
      }
    }
    final target = _resolveTargetUrl();
    // 既有循环逻辑... 替换 _kPingUrl 为 target
    // 既有 _saveRecord 使用 target
  }
}
```

### 4.6 build 方法新增

```dart
Widget _buildCustomUrlCard() {
  return Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: _useCustomUrl,
            onChanged: (v) async {
              final newVal = v ?? false;
              setState(() => _useCustomUrl = newVal);
              await NetworkSpeedSettings.save(useCustom: newVal);
            },
          ),
          const Text('自定义目标'),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _urlController,
              enabled: _useCustomUrl,
              decoration: const InputDecoration(
                hintText: 'https://...',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onEditingComplete: () async {
                setState(() => _customUrl = _urlController.text.trim());
                await NetworkSpeedSettings.save(url: _customUrl);
                FocusScope.of(context).unfocus();
              },
              onSubmitted: (v) async {
                setState(() => _customUrl = v.trim());
                await NetworkSpeedSettings.save(url: _customUrl);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _buildCurrentTargetLabel() {
  final url = _resolveTargetUrl();
  String host;
  try {
    host = Uri.parse(url).host;
  } catch (_) {
    host = url;
  }
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text('当前目标: $host', style: const TextStyle(fontSize: 12, color: Colors.grey)),
  );
}
```

## 五、错误处理

| 场景 | 行为 |
|------|------|
| 自定义 URL 为空 | 校验失败 → SnackBar「URL 不能为空」 |
| 自定义 URL 无 scheme | 校验失败 → SnackBar「URL 必须以 http:// 或 https:// 开头」 |
| 自定义 URL 解析抛错 | 校验失败 → SnackBar「URL 格式不合法」 |
| 自定义 URL 无 host | 校验失败 → SnackBar「URL 缺少主机名」 |
| 自定义 URL 主机不可达 | 走既有 10 次全失败 → "网络不可达，请检查连接后重试" |
| SSL 握手失败 | 同上 |
| SharedPreferences 读写失败 | 静默忽略（不影响测速） |

## 六、测试

### 6.1 单元测试
- `NetworkSpeedSettingsTest`：
  - `load()` 默认值（无 key 时返回 useCustom=false, url=''）
  - `save` + `load` 往返
- `NetworkSpeedPageUrlValidationTest`（私有 `_validateUrl` 通过 `@visibleForTesting` 暴露）：
  - 合法：`https://www.baidu.com`, `http://example.com:8080/path?q=1`
  - 非法：空、`baidu.com`、`ftp://x.com`、`https://`、`https:///path`

### 6.2 手动测试
- 未勾选：输入框置灰，测速使用百度
- 勾选 + 输入合法 URL：测速命中输入 URL
- 勾选 + 输入非法 URL：SnackBar 提示，不进入测速
- 关闭再打开 app：复选框和 URL 恢复
- 历史记录显示实际测过的 host

## 七、版本号

按项目规范，bump `pubspec.yaml` 版本号：`1.2.2+6` → `1.2.3+7`

## 八、风险与备注

- 用户输入 `https://httpbin.org/redirect-to?url=...` 这类重定向 URL：HTTP HEAD 在 Android 上通常不自动跟随重定向（取决于 http 客户端），延迟取的是首次 TCP+TLS 握手时间。文档提示但不强制拦截。
- 输入 URL 长度无上限校验（TextField 自带最大长度限制，可加 `maxLength: 500`）。
- 与现有 `NetworkSpeedHistory` 完全独立，无 schema 变更。
- `AppLogger.i('NetworkSpeedPage', '开始测速')` 改为 `开始测速 target=$target` 便于排查。
