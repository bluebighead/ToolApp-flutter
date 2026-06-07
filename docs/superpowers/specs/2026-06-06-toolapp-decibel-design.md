# 工具箱 App - 分贝测试仪 设计文档

- **日期**：2026-06-06
- **版本**：v0.1（一期）
- **作者**：Trae IDE

## 一、项目目标

开发一个安卓工具箱 App，第一期仅实现 **分贝测试仪** 工具。后续可在首页工具列表中扩展更多工具。

## 二、范围

### 一期包含
- 工具箱 App 框架（首页 + 独立工具页面）
- 分贝测试仪：环境分贝实时检测、折线图展示、开始/停止控制
- 麦克风权限申请
- 基础 Material 3 主题

### 一期不包含（后续阶段）
- 工具历史记录、数据导出
- 单元测试 / Widget 测试
- 深色模式手动切换（跟随系统即可）
- iOS 适配
- 多语言

## 三、技术选型

| 模块 | 选型 | 版本 | 说明 |
|------|------|------|------|
| Flutter | stable | 3.x | 主框架 |
| 音频采集 | `noise_meter` | ^4.0.1 | 实时返回分贝 |
| 折线图 | `fl_chart` | ^0.68.0 | 实时滚动折线图 |
| 权限 | `permission_handler` | ^11.0.0 | 麦克风权限申请 |
| 最低 Android SDK | 23 (Android 6.0) | - | noise_meter 最低要求 |

## 四、目录结构

```
h:\Mycode\Trae\Flutter\ToolApp\
├── pubspec.yaml
├── android/
│   └── app/src/main/AndroidManifest.xml   # 添加 RECORD_AUDIO 权限
├── lib/
│   ├── main.dart                          # App 入口
│   ├── pages/
│   │   ├── home_page.dart                 # 首页：工具箱 GridView
│   │   └── decibel_page.dart              # 分贝测试仪页面
│   ├── widgets/
│   │   ├── tool_card.dart                 # 工具卡片
│   │   ├── decibel_display.dart           # 大号分贝值显示
│   │   └── decibel_chart.dart             # 折线图组件
│   └── models/
│       └── tool_item.dart                 # 工具项数据模型
└── docs/
    └── superpowers/specs/
        └── 2026-06-06-toolapp-decibel-design.md
```

## 五、组件设计

### 5.1 数据模型 ToolItem

```dart
class ToolItem {
  final String name;       // 显示名
  final IconData icon;     // 图标
  final WidgetBuilder pageBuilder; // 跳转页面构建器
}
```

### 5.2 首页 HomePage

- `AppBar` 标题"实用工具箱"
- `body` 为 `GridView.count(crossAxisCount: 3)`
- 每个工具对应一个 `ToolCard`
- 点击工具卡片使用 `Navigator.push` 跳转

### 5.3 工具卡片 ToolCard

- `Card` + `InkWell` 包裹
- 垂直布局：图标 + 名称
- 点击触发 `Navigator.push` 进入对应页面

### 5.4 分贝测试仪页面 DecibelPage

**布局（自上而下）：**
1. `AppBar` 标题"分贝测试仪"，带返回按钮
2. `DecibelDisplay`：大号分贝数值 + 文字描述（安静/正常/嘈杂/很吵）
3. `DecibelChart`：折线图，约占 40% 高度
4. 控制按钮：开始 / 停止

**状态机：**
- `idle`（未开始）：显示"开始测试"按钮
- `running`（采集中）：显示"停止"按钮 + 实时数据
- `error`（权限拒绝/麦克风不可用）：显示错误信息 + 重试按钮

**生命周期：**
- `initState` 初始化 `NoiseMeter` 与 `Subscription`
- `dispose` 停止采集、释放资源（关键，防止后台占用麦克风）
- 点击开始：检查权限 → 启动 `NoiseMeter` → 订阅 `noiseStream` → 维护长度为 60 的 `Queue<double>`
- 点击停止：取消订阅 → `NoiseMeter.stop()`

**分贝值分级：**
- < 40 dB：安静（绿色）
- 40 ~ 70 dB：正常（蓝色）
- 70 ~ 90 dB：嘈杂（橙色）
- > 90 dB：很吵（红色）

### 5.5 折线图 DecibelChart

- 接收 `List<double>` 数据
- 使用 `fl_chart` 的 `LineChart`
- X 轴：序号（0 ~ 数据长度-1），隐藏刻度
- Y 轴：固定 30 ~ 120 dB
- 线条颜色根据当前最大 dB 切换
- 折线点不显示（更简洁）

### 5.6 权限处理

- `AndroidManifest.xml` 添加：
  ```xml
  <uses-permission android:name="android.permission.RECORD_AUDIO" />
  ```
- 进入页面时通过 `permission_handler` 申请 `Permission.microphone`
- 拒绝时：SnackBar 提示 + "去设置"按钮

## 六、数据流

```
用户点击"开始测试"
    ↓
Permission.microphone.request()
    ↓ 允许
NoiseMeter().noiseStream.listen(...)
    ↓ NoisePoint
更新 _currentDb / _history Queue
    ↓ setState
DecibelDisplay 重新构建
DecibelChart 重新构建
    ↓
用户点击"停止"
    ↓
_subscription.cancel()
NoiseMeter().stop()
```

## 七、错误处理

| 错误场景 | 处理方式 |
|---------|---------|
| 权限被拒 | SnackBar 提示 + 跳转设置 |
| 麦克风被其他应用占用 | 捕获异常，显示"麦克风不可用" |
| NaN / 负无穷等异常值 | 在 setState 前过滤 |
| 页面销毁 | dispose 中取消订阅和 stop |

## 八、UI 主题

- Material 3
- 配色：浅色为主，分贝数值用渐变色（绿→黄→红）
- 字体：系统默认

## 九、后续扩展点

- 首页工具列表为数组形式，添加新工具只需追加 `ToolItem`
- `ToolItem.pageBuilder` 支持延迟构造，避免一次性加载所有页面

## 十、风险

| 风险 | 应对 |
|------|------|
| `noise_meter` 在某些设备上 dB 值偏差较大 | 文档中说明，仅作"参考值"，不宣称精度 |
| Android 13+ 权限申请 API 变化 | 使用 `permission_handler` 统一处理 |
| 长时间运行内存增长 | 限制历史队列最大 60 点（约 1 分钟） |
