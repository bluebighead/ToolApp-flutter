# 工具箱 App - 网速测试（Ping 延迟）设计文档

- **日期**：2026-06-06
- **版本**：v0.1（一期新增）
- **作者**：Trae IDE

## 一、项目目标

在工具箱 App 中新增 **网速测试** 工具（二期工具），提供 Ping 延迟测量与历史记录功能。一期仅实现 Ping（延迟）测试，下载/上传速度留待后续扩展。

## 二、范围

### 本期包含
- 网速测试主页：仪表盘 + 数字结果 + 进度点
- 10 次串行 HTTP HEAD 请求测延迟，每次间隔 1 秒
- 当前/最小/平均/最大/抖动/丢包率六项指标
- 历史记录：SharedPreferences 持久化，最多 20 条
- 历史列表页 + 详情弹层
- 接入首页工具网格

### 本期不包含（后续阶段）
- 下载/上传速度测试
- 服务器切换（固定 `httpbin.org`）
- 历史记录的导出、筛选、搜索
- 单元测试 / Widget 测试
- 桌面端 / iOS 适配（沿用现有安卓优先策略）

## 三、技术选型

| 模块 | 选型 | 版本 | 说明 |
|------|------|------|------|
| HTTP 客户端 | `http` | ^1.2.0 | 轻量、支持超时与 HEAD |
| 持久化 | `shared_preferences` | ^2.2.2 | 已在 pubspec，零新依赖 |
| 测速目标 | `https://httpbin.org/get` | - | 仅用 HEAD，不取响应体 |
| 状态管理 | StatefulWidget + setState | - | 与现有 `decibel_page.dart` 保持一致 |
| 最低 Android SDK | 23 | - | 沿用项目现状 |

## 四、目录结构

```
h:\Mycode\Trae\Flutter\ToolApp\
├── pubspec.yaml                            # 新增 http 依赖
├── lib/
│   ├── pages/
│   │   ├── home_page.dart                  # 工具列表追加"网速测试"项
│   │   ├── network_speed_page.dart         # 新增：测速主页
│   │   └── network_speed_history_page.dart # 新增：历史列表页
│   ├── utils/
│   │   └── network_speed_history.dart      # 新增：历史读写 + PingRecord 模型
│   └── models/
│       └── tool_item.dart                  # 无修改
└── docs/
    └── superpowers/specs/
        └── 2026-06-06-toolapp-networkspeed-design.md  # 本文档
```

## 五、组件设计

### 5.1 首页接入 `HomePage`

`lib/pages/home_page.dart` 的 `_toolList` 末尾追加：

```dart
ToolItem(
  name: '网速测试',
  icon: Icons.network_check,
  color: Colors.teal,
  pageBuilder: (_) => const NetworkSpeedPage(),
),
```

### 5.2 测速主页 `NetworkSpeedPage`

**布局（自上而下）：**
1. `AppBar` 标题"网速测试"，带返回按钮；`actions` 包含 `Icons.history` 图标按钮，点击进入历史页
2. 仪表盘卡片（居中）：
   - 大号当前延迟数字（如 `78`），字号 64
   - 副标题 `ms`
   - 数字颜色按延迟分级：
     - `< 50 ms`：绿色
     - `50 ~ 100 ms`：蓝色
     - `100 ~ 200 ms`：橙色
     - `> 200 ms`：红色
3. 进度点：10 个小圆点，未完成灰色，完成绿色，当前为正在测的脉冲高亮
4. 统计行：5 个等宽小卡，展示 `最小 / 平均 / 最大 / 抖动 / 丢包`
5. 控制按钮：
   - `idle` → "开始测试"
   - `running` → "停止"
   - `done` → "重新测试"
   - `error` → "重试"

**状态机：**

| 状态 | 描述 | 控制按钮 | 仪表盘 |
|------|------|----------|--------|
| `idle` | 未开始 | 开始测试 | 显示 `--` |
| `running` | 测速中 | 停止 | 显示当前样本延迟 |
| `done` | 完成 | 重新测试 | 显示最后一次样本延迟 |
| `error` | 10 次全失败 | 重试 | 显示 `--`，下方错误提示文字 |

**关键字段：**
- `int? _currentLatency`：最近一次有效延迟（ms）
- `List<int?> _samples`：原始样本，长度 ≤ 10，含 `null` 表示丢包
- `int _completedCount`：已完成样本数（用于进度点）
- `bool _isRunning`：是否正在测速
- `bool _cancelled`：用户中途停止标志
- `String? _errorMessage`：错误信息（仅 `error` 状态有值）
- `http.Client? _client`：HTTP 客户端，`dispose` 时关闭
- `Stopwatch _stopwatch`：单次计时

**测速方法 `_runTest()`：**
```
for i in 0..9:
    if _cancelled: break
    _stopwatch.restart()
    try:
        await _client!.head(_url).timeout(const Duration(seconds: 3))
        _samples.add(_stopwatch.elapsedMilliseconds)
    catch:
        _samples.add(null)  // 记为丢包
    setState(() => _completedCount = _samples.length)
    if i < 9: await Future.delayed(const Duration(seconds: 1))

最终状态判定：
- 若 _cancelled == true → 状态切到 done（哪怕 _samples 为空）
- 否则若 _samples 全部为 null → 状态切到 error
- 否则 → 状态切到 done

进入 done 时无条件保存历史记录（用户中途停止也保存，用于记录尝试）
```

**生命周期：**
- `initState`：初始化 `_stopwatch = Stopwatch()`、`_samples = []`、`_client = http.Client()`
- `dispose`：设 `_cancelled = true`、`_client?.close()`
- 用户按"停止"：设 `_cancelled = true`，循环自动跳出

### 5.3 历史数据工具 `NetworkSpeedHistory`

文件：`lib/utils/network_speed_history.dart`

**数据模型 `PingRecord`：**

```dart
class PingRecord {
  final DateTime timestamp;     // 测速时间
  final String server;          // 服务器 URL
  final List<int?> samples;     // 原始样本（null = 丢包）
  final int min;                // 毫秒
  final int avg;                // 毫秒
  final int max;                // 毫秒
  final int jitter;             // 毫秒
  final double lossRate;        // 0.0 ~ 1.0

  Map<String, dynamic> toJson();
  factory PingRecord.fromJson(Map<String, dynamic> json);
}
```

**静态方法：**

```dart
class NetworkSpeedHistory {
  static const _key = 'network_speed_history';
  static const _maxRecords = 20;

  // 保存一条记录：JSON 序列化、追加、裁剪至 20 条、写回 SharedPreferences
  static Future<void> save(PingRecord record);

  // 读取全部记录：解析 JSON、按 timestamp 倒序（最新在前）
  static Future<List<PingRecord>> loadAll();

  // 清空：remove _key
  static Future<void> clear();

  // 从 samples 计算统计指标（min/avg/max/jitter/lossRate）
  static PingRecordStats computeStats(List<int?> samples);
}
```

**JSON 格式：**
```json
[
  {
    "timestamp": "2026-06-06T15:30:45.000",
    "server": "https://httpbin.org/get",
    "samples": [45, 52, 48, 50, 60, 55, 49, 51, 53, 47],
    "min": 45, "avg": 51, "max": 60, "jitter": 4, "lossRate": 0.0
  }
]
```

### 5.4 历史列表页 `NetworkSpeedHistoryPage`

**布局（自上而下）：**
1. `AppBar` 标题"测速历史"，`actions` 含"清空"按钮（弹确认对话框，确认后 `NetworkSpeedHistory.clear()`）
2. `FutureBuilder<List<PingRecord>>`：读取历史数据
   - 加载中：显示 `CircularProgressIndicator`
   - 空数据：显示居中文字"暂无测速记录" + 副标题"完成一次测速即可查看历史"
   - 有数据：`ListView.separated`，每行：
     - 左侧：`yyyy-MM-dd HH:mm` 时间
     - 中部：服务器域名（截取 URL 主机部分，如 `httpbin.org`）
     - 右侧：`avg ms · loss%`（如 `51ms · 0%`）
     - `onTap`：调用 `showModalBottomSheet` 打开详情

**详情弹层：**
- 完整时间戳（`yyyy-MM-dd HH:mm:ss`）
- 服务器完整 URL
- 5 个统计项（最小/平均/最大/抖动/丢包）
- 原始样本数组（10 个数字，超时显示为 `--`）

## 六、数据流

```
用户点击"开始测试"
    ↓
setState(_status = running, _samples = [], _completedCount = 0, _cancelled = false)
    ↓
_runTest() async:
    for i in 0..9:
        stopwatch.restart()
        try:
            await client.head(_url).timeout(3s)
            _samples.add(stopwatch.elapsedMilliseconds)
        catch:
            _samples.add(null)
        setState(_completedCount = _samples.length)
        if i < 9: await Future.delayed(1s)
    ↓
if 所有样本都是 null:
    setState(_status = error, _errorMessage = "网络不可达")
else:
    record = PingRecord(...)
    await NetworkSpeedHistory.save(record)
    setState(_status = done)
    ↓
用户点击 AppBar 历史图标
    ↓
Navigator.push -> NetworkSpeedHistoryPage
    ↓
FutureBuilder 调 NetworkSpeedHistory.loadAll()
    ↓
渲染列表，点击行 -> showModalBottomSheet 显示详情
```

## 七、错误处理

| 错误场景 | 处理方式 |
|---------|---------|
| 单次请求超时 3s | 记为丢包（`null`），继续下一次 |
| 单次请求其他异常 | 记为丢包（`null`），继续下一次 |
| 10 次全部为 `null` | 状态切到 `error`，显示"网络不可达"+ 重试按钮 |
| 用户中途按"停止" | 设 `_cancelled = true`，循环立即跳出，按当前已有样本切到 `done` 并保存（样本数 = 实际完成数） |
| `dispose` 时仍在跑 | 设 `_cancelled = true`、关闭 `http.Client` |
| SharedPreferences 读取失败 | `loadAll` 返回空列表，UI 显示空状态 |
| SharedPreferences 写入失败 | 静默忽略（不影响测速主流程），日志记录 |

## 八、UI 主题

- Material 3
- 主色：`Colors.teal`（与首页 ToolItem 颜色保持一致）
- 延迟分级色：绿/蓝/橙/红
- 统计卡：灰底圆角 + 上下结构（标签 + 数值）
- 进度点：`Colors.grey.shade300` 未完成 / `Colors.green` 已完成

## 九、后续扩展点

- `_toolList` 数组化已支持追加新工具
- `PingRecord.samples` 字段为可空数组，将来加下载/上传测试时可扩展
- `NetworkSpeedHistory` 存储结构为 JSON 数组，扩展记录字段时只需改 `PingRecord` 的 `toJson` / `fromJson`
- 服务器 URL 可后续改为可配置（用 `app_settings.dart` 中的设置项）

## 十、风险

| 风险 | 应对 |
|------|------|
| `httpbin.org` 国内偶尔慢或不可达 | 文档中注明"取决于网络环境"；用户首次测速若全失败，错误提示引导重试 |
| 移动网络延迟抖动大 | 仅作"参考值"显示，不宣称精度 |
| 测速总时长固定 10 秒 | 进度点提供视觉反馈，避免用户误以为卡死 |
| `http` 包未在 pubspec | 需执行 `flutter pub add http` 添加依赖 |
| SharedPreferences 容量 | 20 条记录每条约 200B，总计 < 5KB，远低于 SharedPreferences 限制 |
