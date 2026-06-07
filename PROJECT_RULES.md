# ToolApp 项目规则

本文档集中记录本项目的开发与发版规则，所有协作者（以及 AI 编码助手）必须遵守。
规则有更新时，请直接修改本文件，并在 PR / 提交说明中简要描述变更原因。

---

## 1. 代码规范

### 1.1 注释语言
- 所有源代码（`.dart`、`.yaml` 等）中的注释必须使用 **中文**。
- 公共 API 命名遵循 Dart 官方规范（lowerCamelCase / UpperCamelCase），保持英文；注释里再给出中文解释。
- 例外：`pubspec.yaml` 等 Flutter 框架约定的英文字段不加中文注释。

### 1.2 硬件引脚与代码对应（嵌入式相关项目）
- 编写任何涉及硬件引脚的代码之前，必须先与"硬件信息文档"逐项对照。
- 若代码中的引脚号与硬件信息不一致，**以硬件信息为准**调整代码，再继续编写。
- 调整后建议在代码注释中保留一行 `// 硬件对应：XXX 引脚 -> YYY 功能`，便于回溯。

---

## 2. 日志规范

### 2.1 统一使用 `AppLogger`
- 项目内任何位置产生日志，必须通过 `lib/utils/app_logger.dart` 中的 `AppLogger` 类：
  - `AppLogger.d(tag, msg)`：开发期调试信息。
  - `AppLogger.i(tag, msg)`：关键流程节点（页面进入、操作完成）。
  - `AppLogger.w(tag, msg, [error])`：非致命异常。
  - `AppLogger.e(tag, msg, [error, stackTrace])`：致命异常、关键功能失败。
- `tag` 建议使用产生日志的模块/页面名（如 `HomePage`、`DecibelPage`）。
- **禁止**在业务代码中直接调用 `print` / `debugPrint` / `developer.log`，统一走 `AppLogger` 以便统一管理。

### 2.2 日志查看与导出
- 内存日志缓存默认保存最近 500 条，可在"软件说明 → 查看调试日志"页面查看、清空、复制。
- IDE 调试时，日志会同步输出到 Flutter DevTools / Android Logcat，便于开发期排查。

---

## 3. 版本号与发版规则

### 3.1 版本号格式
- 采用 Flutter 官方推荐格式 `主版本.次版本.修订号+构建号`，对应 `pubspec.yaml` 中的 `version` 字段。
  - 例：`1.0.0+1` 表示 `主版本=1`、`次版本=0`、`修订号=0`、`构建号=1`。
- Android 中 `version` 对应 `versionName`（主次修订）和 `versionCode`（构建号）。

### 3.2 每次发版必须更新
发布一个发行版时，**至少**同步更新以下 3 处：
1. `pubspec.yaml` 中的 `version` 字段（主次修订+构建号）。
2. `lib/utils/app_info.dart` 中的 `AppInfo.version`、`AppInfo.buildNumber`、`AppInfo.lastUpdate`。
3. 本文第 4 节"发版记录"追加一行本次发版的简要说明。

### 3.3 升级策略（语义化版本）
- **主版本（major）**：不兼容的架构调整、核心功能重写。
- **次版本（minor）**：新增向后兼容的功能（如新增一个工具页面）。
- **修订号（patch）**：向后兼容的 Bug 修复、小优化、UI 调整、文案修正。
- **构建号（build）**：每次发版必须 `+1`，与主次修订号独立递增；可作为 CI 流水线的内部版本号。

### 3.4 版本号调整示例
| 变更类型           | 旧版本       | 新版本       |
| ------------------ | ------------ | ------------ |
| 新增分贝测试仪工具 | `0.1.0+1`    | `0.2.0+2`    |
| 修复闪退 Bug       | `0.2.0+2`    | `0.2.1+3`    |
| 引入日志/关于页    | `0.2.1+3`    | `0.3.0+4`    |
| 正式 1.0 发布      | `0.9.0+9`    | `1.0.0+10`   |

---

## 4. 发版记录

| 版本            | 更新时间       | 开发者   | 主要变更                                                                 |
| --------------- | -------------- | -------- | ------------------------------------------------------------------------ |
| `1.6.21+47`     | 2026-06-07     | SuperYH  | 转换启停逻辑重做："暂停"与"取消"语义彻底分开：<br>1) **状态机扩展**：新增 `ConvertState.paused` 状态，与 `cancelled` 完全独立；UI 同步新增 `_ConvertStatus.paused`；<br>2) **暂停 = 进度保留 + 跨进程可恢复**：新增 `lib/utils/convert_resume_state.dart`（`ConvertResumeState` + `ConvertResumeStore`），把输入源/输出路径/质量/已编码时长/源总时长等**序列化到 app docs 目录**（`convert_resume_state.json`），系统清缓存、杀后台、甚至重启 App 后只要进入转换页就会自动 `bootstrapFromDisk()` 把状态机恢复到 `paused`；<br>3) **`FFmpegService.convertResume()` 两步走**：第一步用 `-ss <encodedMs>` 让 FFmpeg 从中断点继续编码剩余段到 `<output>.part2`，第二步用 FFmpeg **concat filter**（`[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1` + `-c copy`）把 partial + part2 拼成完整文件，无需重新编码，速度快；<br>4) **Coordinator 暴露 `pause()/resume()/bootstrapFromDisk()`**：`pause()` 抢 `_lastEncodedTimeMs`（在 FFmpeg `statistics` 回调里跟踪最后一帧时间）→ 取消会话 → 写盘 → 切 `paused`；`resume()` 读盘 → 调 `convertResume()` → 完成后走正常 done 流程（保存历史、复制到 SAF）；<br>5) **UI 按钮分场景**：<br>　- **running**：底部两个并排按钮 = 左【暂停转换】（主题色 tonal） + 右【取消转换】（红色 tonal）<br>　- **paused**：底部两个并排按钮 = 左【继续转换】（主题色实心） + 右【取消】（红色 tonal，"取消"即放弃恢复）<br>　- **idle / done**：单个【开始转换】按钮<br>6) **进度卡片加"已暂停"横幅**：状态为 paused 时在进度环上方插一条 amber 提示条 "已暂停（X%）· 进度已保留，可继续转换"，进度环下方文案改为 "已暂停 · 等待继续"；<br>7) **通知栏区分暂停/继续**：新增 `showPaused(sourceName, progressPct)`（not ongoing、可滑掉、提示"回到 App 可继续"）和 `showResumed(sourceName)`（重新进入 ongoing 模式，提示"从暂停点继续"）；<br>8) **视频保存设置新增 JSON 序列化扩展** `VideoSaveSettingsSnapshotJson.toJson()/fromJson()`，让恢复状态能把 `saveSettings` 完整写盘。 |
| `1.6.19+45`     | 2026-06-07     | SuperYH  | 修复"选择后台运行后转换直接结束"的核心 Bug：<br>1) **新增 `lib/utils/convert_coordinator.dart`**：全局单例 `ConvertCoordinator`，独占持有 `FFmpegService`、通知、历史、临时目录清理；进度 / 状态通过 `StreamController<ConvertEvent>` 广播；<br>2) **UI 与任务完全解耦**：`VideoConvertPage.dispose()` 不再调用 `_ffmpeg.cancel()`，只解除 Stream 订阅，FFmpeg 任务由 Coordinator 在 App 全生命周期内持有，**用户选择"后台运行"后真正继续在后台跑**；<br>3) **页面重建自动恢复 UI**：`initState` 调用 `_syncFromCoordinatorSnapshot()`，从 Coordinator 投影当前 state/progress/output 到本地 UI 字段；<br>4) **PopScope 改读 Coordinator 状态**：`canPop` 改为 `!ConvertCoordinator.instance.isRunning`，事件源是状态机而不是页面 State；<br>5) 清理 `convert_history.dart` 未使用 import、`_convertStartInput` 未使用字段、`_clearImportCache` 冗余包装函数、`_evictAllCaches` 未引用方法等静态检查告警。 |
| `1.6.18+44`     | 2026-06-07     | SuperYH  | 视频转换通知 + 自定义保存路径优化：<br>1) `ConvertNotification` 重构为走 `AndroidFlutterLocalNotificationsPlugin` 平台实现（绕开 wrapper 的 4-positional 签名歧义，修复编译错误），统一内部 `_showOnAndroid` 命名参数方法；<br>2) `_buildOngoingDetails` / `_buildCompletedDetails` / `_buildFailedDetails` / `_buildCancelledDetails` 拆分四种通知样式构造，进度条 / ETA / 完成 / 失败 / 取消 一目了然；<br>3) 设置页"选择目录"传参修正：`SafInitialUris.primaryDownload.contentUri`（之前是 enum 实例，与 `String?` 不匹配）；<br>4) 视频保存设置页 `_onPickCustomDir` 引导 SAF 默认定位到 `primary:Download`，用户日常下载目录一键直达；<br>5) 修复 `video_convert_page` 中 `AppLogger.w` 4-arg 调用、`finalOutputPath` 未使用、`_backgroundMode` 字段未读取等静态检查告警。 |
| `1.6.17+43`     | 2026-06-07     | SuperYH  | 修复视频转换完成后"打开文件"/"打开目录"两个操作均失败的 Bug：<br>1) `_openOutput` 改用 `open_filex`（内置 FileProvider，自动转 `content://` URI），彻底解决 Android 7.0+ 的 `FileUriExposedException`；<br>2) 新增 `res/xml/file_paths.xml` 与 `AndroidManifest.xml` 中的 `FileProvider` 声明（authority = `${applicationId}.fileprovider`），把 App 私有目录 `app_flutter/` 暴露给系统应用；<br>3) `MainActivity.openContainingFolder` 改走 `FileProvider.getUriForFile()`，用 `content://` URI + `FLAG_GRANT_READ_URI_PERMISSION` 调起文件管理器 / 视频播放器；<br>4) 同步更新 ProGuard 规则保留 `androidx.core.content.FileProvider`。 |
| `1.4.8+24`      | 2026-06-07     | SuperYH  | 修复"所在文件夹有 m3u8 文件但说找不到"：放弃 `file_picker.getDirectoryPath`（小米/Redmi 定制 ROM 上只返回物理路径），改由 MainActivity 自行用 `ACTION_OPEN_DOCUMENT_TREE` 启动 SAF，强制拿到 `content://` URI；新建 `SafHelper` 工具类 + `SafInitialUris`（从 M3U8 路径推测 SAF 初始位置让 SAF 默认定位到 `primary:Download`） |
| `1.4.7+23`      | 2026-06-07     | SuperYH  | 修复扫描文件夹失败（`Invalid URI: /storage/emulated/0/...`）：MainActivity.kt `listM3u8InTree` / `copyTreeToCache` 兼容 `content://` tree URI 和直接文件系统路径两种入参，适配部分厂商 ROM 上 `file_picker.getDirectoryPath` 返回 `File` 路径的场景 |
| `1.4.6+22`      | 2026-06-07     | SuperYH  | 视频转换：M3U8 选择体验升级——"选择 M3U8"主入口选完文件后**自动**用 SAF 引导用户选一次文件所在目录，把整棵目录树复制到沙盒，segments 一定能被找到；抽出 `_copyDirAndResolveM3u8` 共用方法，单文件入口和文件夹入口复用同一套复制逻辑 |
| `1.4.5+21`      | 2026-06-07     | SuperYH  | M3U8 转换兜底引导：单文件入口选择后自动检测 M3U8 是否引用子目录片段（如 `xxx.m3u8_contents/0`），命中则弹窗提示改用"选择文件夹"入口；预处理失败时 dump 工作目录与父目录内容辅助排查 |
| `1.4.4+20`      | 2026-06-07     | SuperYH  | 新增"选择 M3U8 所在文件夹"入口（FilePicker.getDirectoryPath + Android MethodChannel `saf_helper`），通过 SAF + DocumentFile 把整棵目录树复制到 App 沙盒，确保 segments 子目录可访问；M3U8 列表支持多选弹窗 |
| `1.4.3+19`      | 2026-06-07     | SuperYH  | M3U8 预处理：把片段复制到独立工作目录并改写为相对路径；预处理失败原因直接拼到错误信息里 |
| `1.4.2+18`      | 2026-06-07     | SuperYH  | 修复 M3U8 片段裸文件（`0`/`1`/`2` 无后缀）场景：预处理时复制到 `ToolApp/data/` 并补 `.ts` 后缀 |
| `1.4.1+17`      | 2026-06-07     | SuperYH  | 修复视频转换"URL ... is not in allowed_segment_extensions"：增加 M3U8 预处理，对无扩展名的片段名（`0`、`1` 等）自动到同目录补 `.ts`/`.m4s`/`.mp4` 等后缀 |
| `1.4.0+16`      | 2026-06-07     | SuperYH  | 新增 `AppStorage` 统一管理 App 在手机上的数据目录（`ToolApp/logs/`、`ToolApp/videos/`、`ToolApp/data/`）；日志页新增"导出日志"按钮，将当前内存日志写入 `ToolApp/logs/`；视频转换输出文件改存到 `ToolApp/videos/converted/` |
| `1.3.2+7`       | 2026-06-07     | SuperYH  | 视频转换：FFmpeg 加 `-protocol_whitelist` + `-allowed_extensions ALL`；错误信息卡片直接展示真实错误（过滤 banner），并提供"查看完整日志"入口 |
| `1.3.1+6`       | 2026-06-07     | SuperYH  | 修复视频格式转换工具点击"选择文件"时的 `MissingPluginException`（启用 R8/ProGuard 并补全插件 keep 规则） |
| `1.3.0+5`       | 2026-06-07     | SuperYH  | 首页新增第三个工具：视频格式转换（基于 FFmpeg，支持 M3U8 → MP4，可选原画质/标准压缩/高压缩） |
| `1.2.0+4`       | 2026-06-06     | SuperYH  | 首页左上角新增三明治菜单（从左向右滑出），新增"设置"页面（屏幕旋转、暗色模式） |
| `1.1.1+3`       | 2026-06-06     | SuperYH  | 调整首页"软件说明"按钮配色为灰色（浅灰底 + 深灰图标）                    |
| `1.1.0+2`       | 2026-06-06     | SuperYH  | 重新打包并部署：版本号随发版更新为 1.1.0+2（新增调试日志与关于页）       |
| `1.0.0+1`       | 2026-06-06     | SuperYH  | 加入调试日志（`AppLogger`）、首页右上角"软件说明"入口、关于页与日志查看页 |

> 后续发版请按"版本号 + 更新时间 + 开发者 + 主要变更"的格式在表格末尾追加一行，**不要修改历史行**。
