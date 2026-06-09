# 视频转换提速 + 批量转换功能设计文档

**日期：** 2026-06-08
**版本：** v1.6.43+

---

## 一、需求概述

1. **提速视频转换**：2-7GB 文件高压缩需半小时，需要提速
2. **批量转换功能**：支持一次选择并转换多个 M3U8 文件
3. **批量转换入口按钮**：放在历史记录按钮左侧
4. **设置界面新增选项**：转换加速模式、批量并行数量、更换默认打开方式

---

## 二、提速方案

### 2.1 转换加速模式

在设置界面新增"转换加速模式"选项，三种模式：

| 模式 | FFmpeg 参数变化 | 速度 | 画质 | 文件大小 |
|------|----------------|------|------|----------|
| 关闭（默认） | `-preset veryfast` + 软件编码 | 基准 | 好 | 基准 |
| 硬件编码 | `-c:v h264_mediacodec` | 快 3-10x | 略低 | 略大 |
| ultrafast | `-preset ultrafast` | 快 2-3x | 相同 | 大 20-40% |

### 2.2 实现方式

- 在 `AppSettings` 中新增 `ConvertSpeedMode` 枚举和持久化
- `FFmpegService._buildArgs()` 根据加速模式生成不同参数
- 硬件编码需要 fallback：如果设备不支持 MediaCodec，自动降级到软件编码

---

## 三、批量转换功能

### 3.1 用户流程

1. 用户在转换页添加 M3U8 文件夹 → 检测到多个 M3U8 文件
2. 弹出 M3U8 播放列表弹窗 → 新增"多选"按钮
3. 点击多选 → 每个文件旁出现复选框
4. 选择数量 > 1 → 自动跳转到批量转换页面
5. 批量转换页面显示竖向列表，每项显示：文件名、进度条、剩余时间、完成后的"打开文件"按钮

### 3.2 架构设计

#### BatchConvertCoordinator

新建 `lib/utils/batch_convert_coordinator.dart`：

- 管理批量转换的状态机
- 使用 `Semaphore` 控制并行数量（默认2，最大5）
- 每个任务独立运行，复用 `FFmpegService`
- 每个任务完成后写入历史记录
- 保存路径复用 `VideoSaveSettings`

#### BatchConvertTask

每个批量转换任务的状态：

```dart
enum BatchTaskState {
  waiting,      // 等待中
  converting,   // 转换中
  done,         // 已完成
  failed,       // 失败
  cancelled,    // 已取消
}

class BatchConvertTask {
  final String inputPath;        // 输入文件路径
  final String sourceName;       // 源文件名
  final String outputPath;       // 输出文件路径
  final int index;               // 序号（用于命名）
  BatchTaskState state;          // 当前状态
  ConvertProgress? progress;     // 进度
  String? errorMessage;          // 错误信息
}
```

#### 输出文件命名

- 原文件名：`video.m3u8` → 输出：`video_1.mp4`
- 加序号区分，避免同名冲突
- 序号从 1 开始，按用户选择顺序递增

### 3.3 并行控制

- 设置中可配置并行数量（1-5，默认2）
- 使用 `Semaphore` 控制并发
- 前台服务通知显示整体进度（如 "3/5 完成"）

---

## 四、批量转换入口按钮

### 4.1 位置

- AppBar 的 actions 中，历史记录按钮左侧
- 图标：`Icons.playlist_play`
- tooltip：`批量转换`

### 4.2 批量转换页面

新建 `lib/pages/batch_convert_page.dart`：

- 竖向列表显示所有待转换文件
- 每项显示：文件名、进度条、剩余时间、状态
- 完成后显示"打开文件"按钮
- 顶部显示整体进度和"全部取消"按钮
- 支持滚动查看所有任务

---

## 五、设置界面新增选项

### 5.1 转换加速模式

- 位置：设置页"视频转换"分组下
- 类型：RadioListTile 三选一
- 选项：关闭 / 硬件编码 / ultrafast
- 说明文字："改变编码方式以提升转换速度，硬件编码速度最快但画质略低"

### 5.2 批量并行数量

- 位置：设置页"视频转换"分组下
- 类型：数字输入框
- 范围：1-5，默认 2
- 说明文字："批量转换时同时进行的任务数量，越多越快但可能卡顿"

### 5.3 更换默认打开方式

- 位置：设置页"视频转换"分组下
- 类型：按钮
- 行为：使用 `OpenFilex.open()` 弹出系统选择器
- 标注文字："⚠️ 此设置仅改变本 App 内视频的打开方式，与其他工具的打开方式设置无关"
- 行为：每次打开视频时都弹出系统选择器，不记住选择

---

## 六、数据流

```
用户选择 M3U8 文件 → 多选 → 跳转到 BatchConvertPage
    ↓
BatchConvertCoordinator.start(
  tasks: [BatchConvertTask...],
  format: VideoFormat,
  quality: VideoQuality,
  parallelCount: int,
)
    ↓
Semaphore(parallelCount) 控制并发
    ↓
每个任务 → FFmpegService.convert() → 写入历史记录
    ↓
全部完成 → 更新 UI → 显示结果
```

---

## 七、文件变更清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `lib/utils/batch_convert_coordinator.dart` | 批量转换协调器 |
| `lib/pages/batch_convert_page.dart` | 批量转换页面 |
| `lib/utils/convert_speed_settings.dart` | 转换加速设置持久化 |

### 修改文件

| 文件 | 变更 |
|------|------|
| `lib/utils/app_settings.dart` | 新增 ConvertSpeedMode 和 batchParallelCount |
| `lib/utils/ffmpeg_service.dart` | _buildArgs() 支持加速模式参数 |
| `lib/pages/video_convert_page.dart` | 新增批量入口按钮、多选功能 |
| `lib/pages/settings_page.dart` | 新增三个设置选项 |
| `lib/utils/app_info.dart` | 版本号更新 |
| `pubspec.yaml` | 版本号更新 |

---

## 八、边界情况处理

1. **硬件编码不支持**：自动降级到软件编码，提示用户
2. **批量转换中途取消**：已完成的保留，进行中的取消，等待中的跳过
3. **批量转换中途失败**：单个任务失败不影响其他任务
4. **磁盘空间不足**：每个任务开始前检查空间，不足则标记失败
5. **App 被杀后恢复**：批量转换不持久化，App 重启后清空（与单文件转换一致）
