# ToolApp

> 一个基于 Flutter 的多功能 Android 工具箱，集成分贝测试、网速测试、视频格式转换等常用小工具。

![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.11-0175C2?logo=dart)
![License](https://img.shields.io/badge/license-Private-lightgrey)
![Version](https://img.shields.io/badge/version-1.73.2%2B264-blue)

---

## 目录

- [项目简介](#项目简介)
- [核心功能](#核心功能)
- [应用截图](#应用截图)
- [技术栈](#技术栈)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [构建发布](#构建发布)
- [版本历史](#版本历史)
- [开发者](#开发者)
- [许可证](#许可证)

---

## 项目简介

**ToolApp** 是一款使用 Flutter 开发的 Android 端多功能小工具集合 App，目标是"装一个 App，干一堆小事"。

- 真实使用场景驱动：作者在日常使用中遇到"需要测环境噪音、想测一下网速、想把 M3U8 视频转成 MP4"等需求，一个个写成了独立小工具。
- 完全离线 / 端侧能力：不依赖任何后端服务，所有计算 / 转码均在手机上完成。
- 工程化约束：源码全部中文注释，遵循统一的日志规范和发版规则（详见 [PROJECT_RULES.md](./PROJECT_RULES.md)）。

> 当前最新版本：**1.73.2+264** （2026-06-18）

---

## 核心功能

### 1. 分贝测试仪
- 实时获取麦克风分贝值，使用 `noise_meter`。
- 折线图（`fl_chart`）展示最近一段时间内的分贝曲线。
- 自动申请麦克风权限（`permission_handler`）。
- 峰值 / 最小值 / 平均值实时统计。

### 2. 网速测试
- 基于 HTTP 下载测量实时网速（`http` 客户端）。
- 自带仪表盘 UI（`network_speed_dial`）与折线图（`network_speed_line_chart`）。
- 支持测试历史记录查看（`network_speed_history_page`）。
- 可配置测试源、并发数等参数（`network_speed_settings`）。

### 3. 视频格式转换
- 基于 **FFmpeg**（`ffmpeg_kit_flutter_new`）实现，**支持 M3U8 → MP4** 等常见格式。
- 提供 **原画质 / 标准压缩 / 高压缩** 三档质量预设。
- 内置 M3U8 预处理，自动补齐无后缀片段、补 `.ts` / `.m4s` / `.mp4` 扩展名。
- "选择 M3U8 文件"与"选择 M3U8 所在文件夹"两种入口：
  - 文件入口自动用 **SAF**（Storage Access Framework）引导选择目录。
  - 文件夹入口通过 SAF + DocumentFile 把整棵目录树复制到 App 沙盒。
- **暂停 / 继续 / 取消** 三态彻底分开：
  - `paused` 与 `cancelled` 是两个完全独立的状态。
  - 暂停时会**把进度写入磁盘**（`convert_resume_state.json`），系统清缓存、杀后台、甚至重启 App 后再进入转换页会自动恢复到 `paused`。
  - 继续时使用 **FFmpeg concat filter** 把已编码部分与剩余部分拼接，**无需重新编码**，速度快。
- 后台运行：选择"后台运行"后 FFmpeg 任务由全局单例 `ConvertCoordinator` 持有，**真正在后台继续跑**，可切回 App 继续查看进度。
- 系统通知栏进度展示：
  - 转换中：ongoing 通知 + 进度条 + 剩余时间（ETA）。
  - 暂停：可滑掉通知，提示"回到 App 可继续"。
  - 完成 / 失败 / 取消：四种样式分别展示。
- 输出文件默认存到 `ToolApp/videos/converted/`，可自定义 SAF 目录。
- 转换历史记录：可在"转换历史"页面回看、分享、打开输出文件 / 打开所在目录。

### 4. 心率广播接收器
- 支持 **BLE 蓝牙低功耗** 和 **WiFi UDP** 两种连接方式。
- 支持 **数字显示**、**折线图**、**组合** 三种显示模式。
- BLE 支持标准心率设备（Heart Rate Service UUID: 0x180D）。
- UDP 支持端口 8888 接收心率数据。
- **设备连接记忆**：首次连接成功后自动保存，下次打开页面自动扫描并连接记忆设备。
- **历史记录**：每次测量会话自动保存，支持查看详情（最高/最低/平均心率、测量时间段）。
- **多选操作**：支持批量删除历史记录，全选/取消全选一键切换。

### 5. 经期宝
- **经期记录**：支持精确记录模式（记录开始和结束日期）和模糊记录模式（仅记录开始日期）。
- **排卵日标记**：支持手动标记排卵日并添加备注。
- **智能预测**：基于历史记录自动计算平均周期天数、平均经期天数，预测下次经期和易孕期。
- **日历视图**：在日历上直观展示经期、预测期、易孕期。
- **统计面板**：周期天数、经期天数、下次经期、易孕期等关键指标一目了然。
- **数据导出**：支持 CSV、XLS（居中对齐）、TXT、DOCX 四种格式导出，方便备份和分享。
- **筛选查找**：支持按日期范围和记录模式筛选历史记录。
- **数据持久化**：SharedPreferences + 文件备份双重存储，防止版本更新时数据丢失。

### 6. 在线功能（账号同步）
- **用户注册 / 登录**：支持邮箱注册和登录，JWT 令牌认证。
- **数据同步**：心率、网速、转换记录等数据自动同步到服务器（默认 5 分钟间隔）。
- **会话管理**：自动跟踪用户在线状态和会话时长。
- **访客模式**：无需注册也可使用基础功能。

### 7. 设备检修（NFC）
- **NFC 读写器**：读取 NFC 标签的 UID、NDEF 文本/URI/vCard 等数据，支持多种标签类型（含 Mifare Classic 扇区级 NDEF 读取）。
- **NFC 功能速写**：支持写入网址、文本、WiFi、微信QQ、导航、投屏、付款、回家模式共 8 种 NFC 标签模式。
  - **已修复碰卡自动跳转**（无 Beta 标志）：网址写入、文本写入、WiFi 速写、微信QQ、导航速写。
  - **Beta 功能**（碰卡跳转待优化）：投屏速写、付款速写、回家模式。
  - **导航速写**：支持选择高德/百度/腾讯地图，写入指定导航软件到 NFC 卡，碰卡自动打开该软件搜索目的地，未安装则提示下载。
  - **微信QQ**：碰卡自动打开微信/QQ并复制账号到剪贴板。
  - **WiFi 速写**：碰卡自动连接 WiFi（使用 `WifiNetworkSuggestion` 建立系统级连接）。
- **安卓系统弹窗抑制**：使用 `androidReaderModeFlags`（NFC_A/B/F/V + SKIP_NDEF_CHECK + NO_PLATFORM_SOUNDS）彻底屏蔽系统弹窗。
- **页面状态保持**：使用 `RouteObserver` + `RouteAware` 在页面间跳转后自动恢复 NFC 感应。

### 8. 加解密工具箱
- 按 **古老加密技术** 和 **现代加密技术** 分区展示，共 18 个小工具。
- **古老加密技术区**：摩斯电码、凯撒密码、Atbash、维吉尼亚密码、柏拉费密码、仿射密码、波利比乌斯方阵、栅栏密码、猪圈密码、简单替换密码。
- **现代加密技术区**：Base64、哈希计算（MD5/SHA1/SHA256/SHA512）、密码生成器、URL 编解码、Unicode 编解码、进制转换、扫码传信、二维码解码、Hex 转换、XOR 加密、HMAC 计算、AES 加解密（128/192/256 位）、RSA 非对称加密（密钥对生成）、文字工具箱。
- **原理说明**：每个工具右上角均有帮助按钮，弹窗展示加密原理和使用说明。

### 9. 骰子
- 支持自定义骰子面数和数量。
- 掷骰动画和结果展示。

### 10. 设置 / 关于 / 日志
- **设置页**：屏幕旋转、暗色模式、视频保存目录。
- **关于页**：展示 App 信息（版本号、构建号、最后更新时间等）。
- **日志页**：查看 / 清空 / 复制 / 导出最近 500 条内存日志。
  - 导出后写入 `ToolApp/logs/`，方便从文件管理器拿走。

---

## 应用截图

> 截图持续补充中……

| 首页                                  | 分贝测试仪                          | 网速测试                            |
| ------------------------------------- | ----------------------------------- | ----------------------------------- |
| `toolapp_home.png`                    | *(待补充)*                          | *(待补充)*                          |

> 截图建议放进 `docs/screenshots/` 目录统一管理。

---

## 技术栈

| 分类             | 选型 / 包                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------- |
| 跨端框架         | [Flutter](https://flutter.dev/) 3.x                                                          |
| 语言             | [Dart](https://dart.dev/) 3.11+                                                              |
| 状态管理         | Flutter 内置 `StatefulWidget` + `ValueNotifier` / `ListenableBuilder`                       |
| 本地存储         | `shared_preferences`、`path_provider`                                                        |
| 文件 / 目录选择  | `file_picker` + Android 原生 `SAF`（通过 MethodChannel 桥接）                                |
| 音视频           | `noise_meter`、`ffmpeg_kit_flutter_new`                                                      |
| 加解密           | `crypto`、`encrypt`、`pointycastle`                                                          |
| 蓝牙 BLE         | `flutter_blue_plus`                                                                          |
| NFC              | `flutter_nfc_kit`、`ndef`                                                                     |
| 图表             | `fl_chart`                                                                                   |
| 权限             | `permission_handler`                                                                         |
| 系统通知         | `flutter_local_notifications`、`timezone`                                                    |
| 文件分享 / 打开  | `share_plus`、`open_filex`                                                                   |
| 测试             | `flutter_test`（`test/` 目录已包含分贝、网速相关的若干单元测试）                             |

### 服务端（toolapp-server）

| 分类             | 选型                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------- |
| 运行时           | [Node.js](https://nodejs.org/)                                                               |
| Web 框架         | [Express](https://expressjs.com/)                                                            |
| 数据库           | [SQLite](https://www.sqlite.org/)（better-sqlite3，WAL 模式）                                |
| 认证             | JWT（jsonwebtoken）+ 管理员密码认证                                                          |
| 部署             | `start-server.bat` 一键启动，支持端口冲突检测                                                |

### 管理软件（toolapp-admin）

| 分类             | 选型                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------- |
| 桌面框架         | [Electron](https://www.electronjs.org/)                                                      |
| 前端框架         | [Vue 3](https://vuejs.org/) + [Element Plus](https://element-plus.org/)                      |
| 状态管理         | [Pinia](https://pinia.vuejs.org/)                                                            |
| 数据库访问       | better-sqlite3（本地模式）/ HTTP API（远程模式）                                             |
| 连接模式         | 本地模式（直接读 SQLite）/ 远程模式（HTTP API）/ 自动检测                                    |
| 管理员密码       | 默认 `666666`，支持通过远程模式修改                                                          |

---

## 目录结构

```
ToolApp/
├── android/                  # Android 原生工程（含 FileProvider 声明、SAF 桥接等）
├── build/                    # 构建产物（已在 .gitignore 中忽略发布时建议清理）
├── docs/
│   └── superpowers/plans/    # 重大重构的实施计划文档
├── lib/
│   ├── main.dart             # 应用入口；主题 / 全局错误捕获 / 通知初始化
│   ├── models/
│   │   └── tool_item.dart    # 首页工具项的数据模型
│   ├── pages/                # 各业务页面
│   │   ├── home_page.dart
│   │   ├── about_page.dart
│   │   ├── settings_page.dart
│   │   ├── logs_page.dart
│   │   ├── decibel_page.dart
│   │   ├── network_speed_page.dart
│   │   ├── video_convert_page.dart
│   │   ├── convert_history_page.dart
│   │   ├── heart_rate_page.dart          # 心率广播接收器主页面
│   │   ├── heart_rate_history_page.dart  # 心率历史记录页面
│   │   ├── period_page.dart              # 经期宝主页面（三Tab容器）
│   │   ├── online/                       # 在线功能相关页面
│   │   │   ├── login_page.dart           # 登录页
│   │   │   ├── register_page.dart        # 注册页
│   │   │   ├── online_lobby_page.dart    # 在线大厅
│   │   │   └── guest_join_page.dart      # 访客加入页
│   │   ├── batch_convert_page.dart       # 批量转换页
│   │   ├── dice_page.dart                # 骰子页面
│   │   ├── device_inspect/               # 设备检修工具
│   │   │   ├── nfc_reader_page.dart      # NFC 读写器
│   │   │   └── nfc_quick_write_page.dart # NFC 功能速写
│   │   ├── encryptor_page.dart           # 加解密工具箱入口（分区展示）
│   │   └── encryptor/                    # 加解密小工具（18 个）
│   │       ├── morse_code_page.dart      # 摩斯电码
│   │       ├── caesar_page.dart          # 凯撒密码
│   │       ├── atbash_page.dart          # Atbash
│   │       ├── vigenere_page.dart        # 维吉尼亚密码
│   │       ├── playfair_page.dart        # 柏拉费密码
│   │       ├── affine_page.dart          # 仿射密码
│   │       ├── polybius_page.dart        # 波利比乌斯方阵
│   │       ├── rail_fence_page.dart      # 栅栏密码
│   │       ├── pigpen_page.dart          # 猪圈密码
│   │       ├── substitution_page.dart    # 简单替换密码
│   │       ├── base64_page.dart          # Base64 编解码
│   │       ├── hash_page.dart            # 哈希计算
│   │       ├── password_page.dart        # 密码生成器
│   │       ├── url_codec_page.dart       # URL 编解码
│   │       ├── unicode_page.dart         # Unicode 编解码
│   │       ├── radix_page.dart           # 进制转换
│   │       ├── code_transfer_page.dart   # 扫码传信
│   │       ├── qr_decoder_page.dart      # 二维码解码
│   │       ├── hex_page.dart             # Hex 转换
│   │       ├── xor_page.dart             # XOR 加密
│   │       ├── hmac_page.dart            # HMAC 计算
│   │       ├── aes_page.dart             # AES 加解密
│   │       ├── rsa_page.dart             # RSA 加解密
│   │       └── text_tools_page.dart      # 文字工具箱
│   ├── services/             # 服务层
│   │   ├── auth_service.dart            # 认证服务（注册/登录/登出）
│   │   ├── sync_service.dart            # 数据同步服务
│   │   └── session_tracker.dart         # 会话跟踪服务（心跳/在线状态）
│   ├── utils/                # 工具类与服务
│   │   ├── app_info.dart              # App 元信息（版本号、构建号等）
│   │   ├── app_logger.dart            # 统一日志门面
│   │   ├── app_settings.dart          # 全局设置（屏幕旋转 / 暗色模式 / 同步间隔等）
│   │   ├── app_storage.dart           # App 私有目录管理
│   │   ├── convert_coordinator.dart   # 转换任务全局协调器（单例）
│   │   ├── convert_history.dart       # 转换历史持久化
│   │   ├── convert_notification.dart  # 转换进度通知
│   │   ├── convert_resume_state.dart  # 暂停恢复状态序列化
│   │   ├── encryptor_help.dart        # 加解密帮助弹窗组件
│   │   ├── ffmpeg_service.dart        # FFmpeg 封装
│   │   ├── heart_rate_ble.dart        # BLE 蓝牙低功耗心率接收
│   │   ├── heart_rate_history.dart    # 心率历史记录持久化
│   │   ├── heart_rate_udp.dart        # WiFi UDP 心率接收
│   │   ├── m3u8_normalizer.dart       # M3U8 规范化
│   │   ├── network_speed_*.dart       # 网速相关工具
│   │   ├── route_observer.dart        # 全局路由观察器（NFC 页面状态）
│   │   ├── saf_directory_helper.dart  # SAF 目录工具
│   │   ├── saf_helper.dart            # SAF 桥接工具
│   │   ├── video_save_settings.dart   # 视频保存设置
│   │   ├── period_model.dart          # 经期宝数据模型、存储和预测算法
│   │   └── period_export.dart         # 经期宝数据导出工具（CSV/XLS/TXT/DOCX）
│   └── widgets/              # 通用组件
│       ├── tool_card.dart
│       ├── decibel_chart.dart
│       ├── decibel_display.dart
│       ├── heart_rate_chart.dart      # 心率折线图组件
│       ├── heart_rate_display.dart    # 心率数字显示组件
│       ├── network_speed_dial.dart
│       └── network_speed_line_chart.dart
├── toolapp-server/           # 后端服务器
│   ├── server.js             # Express 服务器主文件
│   ├── package.json          # Node.js 依赖
│   ├── start-server.bat      # Windows 一键启动脚本
│   └── data/                 # 数据库文件目录
│       └── toolapp.db        # SQLite 数据库（运行时生成）
├── toolapp-admin/            # 桌面管理软件
│   ├── electron/             # Electron 主进程
│   │   ├── main.js           # 主进程入口
│   │   ├── preload.js        # IPC 桥接
│   │   └── db_worker.js      # 数据库工作进程
│   ├── src/                  # Vue 3 前端源码
│   │   ├── views/            # 页面组件
│   │   ├── stores/           # Pinia 状态管理
│   │   ├── components/       # 通用组件
│   │   └── utils/            # 工具函数
│   └── package.json          # Node.js 依赖
├── test/                     # 单元测试
├── docs/                     # 计划 / 调试 / 截图
├── pubspec.yaml              # Flutter 工程配置
├── analysis_options.yaml     # 静态分析规则
├── PROJECT_RULES.md          # 项目开发 / 发版规则
└── README.md                 # 本文件
```

---

## 快速开始

### 环境要求
- Flutter SDK：`^3.11.1`（Dart 3.11+）
- Android Studio / VS Code + Flutter / Dart 插件
- Android 设备或模拟器（**Android 7.0+**，项目使用了 `FileProvider` 暴露沙盒文件）

### 克隆 & 拉依赖

```bash
git clone https://github.com/bluebighead/ToolApp-flutter.git
cd ToolApp-flutter
flutter pub get
```

### 运行（开发态）

```bash
# 列出已连接设备
flutter devices

# 调试模式运行到指定设备
flutter run -d <device-id>
```

### 静态分析 & 测试

```bash
# 静态分析
flutter analyze

# 单元测试
flutter test
```

---

## 构建发布

> ⚠️ 本项目遵循 `PROJECT_RULES.md` 的发版流程：**每次发版必须同步更新 `pubspec.yaml` 的 `version`、`lib/utils/app_info.dart` 的版本字段以及本 README 的版本历史**。

```bash
# 1. 清理旧的 release APK
rm -rf build/app/outputs/flutter-apk/app-release.apk

# 2. 构建 release APK
flutter build apk --release

# 3. 安装到已连接的 Android 设备
flutter install
# 或者：
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

构建产物位置：
- `build/app/outputs/flutter-apk/app-release.apk`

---

## 版本历史

> 完整变更日志请参考 [PROJECT_RULES.md](./PROJECT_RULES.md) 第 4 节"发版记录"。

| 版本          | 更新时间   | 开发者  | 主要变更                                                                 |
| ------------- | ---------- | ------- | ------------------------------------------------------------------------ |
| `1.73.2+264`  | 2026-06-18 | SuperYH | NFC功能速写界面整理：已修复工具排前、Beta工具排后；更新README。 |
| `1.73.1+263`  | 2026-06-18 | SuperYH | 修复高德地图导航scheme（改用keywordNavi按关键字搜索）。 |
| `1.73.0+262`  | 2026-06-18 | SuperYH | 导航速写重构：删除经纬度输入，新增导航软件选择（高德/百度/腾讯）+目的地名称，写入指定导航软件到NFC卡，未安装则提示下载。 |
| `1.72.1+261`  | 2026-06-18 | SuperYH | 微信QQ加强互斥验证（微信号和QQ号不能同时填写）。 |
| `1.72.0+260`  | 2026-06-18 | SuperYH | 名片速写改为"微信QQ"（仅保留微信/QQ输入）；修复网址写入碰卡自动跳转（提取handleUriAndTextNdefMessage方法）。 |
| `1.71.7+259`  | 2026-06-18 | SuperYH | 修复QQ跳转崩溃（改用mqqapi://card/show_pslcard名片页面scheme）。 |
| `1.71.6+258`  | 2026-06-18 | SuperYH | 修复子线程调用Toast导致崩溃（用runOnUiThread包裹跳转调用）。 |
| `1.71.5+257`  | 2026-06-18 | SuperYH | 修复微信/QQ碰卡跳转（提取handleCustomNdefMessage方法，通用NDEF解析兜底+MifareClassic读取后处理自定义MIME）。 |
| `1.71.4+256`  | 2026-06-18 | SuperYH | 修复WiFi"假连接"（改用WifiNetworkSuggestion建立系统级连接）。 |
| `1.71.1+255`  | 2026-06-18 | SuperYH | 修复WiFi连接权限（添加CHANGE_NETWORK_STATE权限）+Mifare Classic NDEF读取逻辑。 |
| `1.70.8+254`  | 2026-06-18 | SuperYH | 修复getInitialIntent的MissingPluginException。 |
| `1.70.7+253`  | 2026-06-18 | SuperYH | 修复WiFi碰卡自动连接（提取handleWifiNdefMessage方法+通用NDEF解析兜底）。 |
| `1.60.2+210`  | 2026-06-16 | SuperYH | 加解密工具箱新增 6 个现代工具（Hex/XOR/HMAC/AES/RSA/文字工具箱）+ 每页帮助按钮。 |
| `1.59.0+209`  | 2026-06-16 | SuperYH | 加解密工具分为古老/现代两区，新增 8 个古密码（Atbash/维吉尼亚/柏拉费/仿射/波利比乌斯/栅栏/猪圈/简单替换）。 |
| `1.58.5+208`  | 2026-06-16 | SuperYH | 加解密工具箱新增 7 个工具（Base64/哈希/凯撒/密码生成/URL编解码/Unicode/进制转换）。 |
| `1.56.0+206`  | 2026-06-15 | SuperYH | NFC 功能速写：名片增加微信/QQ号互斥输入，写入 URI 记录自动打开 App。 |
| `1.55.0+205`  | 2026-06-15 | SuperYH | NFC 功能速写页面：8 种写入模式（网址/文本/名片/WiFi/回家/投屏/导航/支付）+ 系统弹窗抑制 + RouteAware 恢复感应。 |
| `1.53.0+203`  | 2026-06-15 | SuperYH | NFC 读写器页面。 |
| `1.27.0+143`  | 2026-06-11 | SuperYH | 管理软件设置页增强：连接模式切换、远程密码修改、内网穿透预留、使用说明。  |
| `1.26.0+142`  | 2026-06-11 | SuperYH | 修复在线状态误报、同步失败提示、数据库大小计算、启动脚本等问题。          |
| `1.22.0+138`  | 2026-06-10 | SuperYH | 经期宝记录模式（精确/模糊）+ 筛选功能 + 导出增加模式列。                |
| `1.21.0+137`  | 2026-06-10 | SuperYH | 经期宝导出优化：XLS格式居中对齐+自适应列宽。                            |
| `1.20.0+136`  | 2026-06-10 | SuperYH | 经期宝数据导出（CSV/TXT/DOCX）+ 数据持久化加固。                        |
| `1.19.0+135`  | 2026-06-10 | SuperYH | 经期宝功能完整实现（记录/日历/统计/排卵日标记/智能预测）。              |
| `1.7.9+96`    | 2026-06-09 | SuperYH | 心率历史记录功能 + 存储空间统计修复（7GB占用根因修复）。                |
| `1.7.6+92`    | 2026-06-09 | SuperYH | BLE断开后心率显示归零，历史数据清空。                                    |
| `1.7.5+91`    | 2026-06-09 | SuperYH | 修复BLE断开后自动重连Bug，修复连接监听器泄漏。                          |
| `1.7.3+89`    | 2026-06-09 | SuperYH | 心率页面切换按钮改为下拉框，新增使用说明按钮。                          |
| `1.7.2+88`    | 2026-06-09 | SuperYH | 新增BLE设备连接记忆功能，自动保存/恢复连接。                            |
| `1.7.1+87`    | 2026-06-09 | SuperYH | 修复BLE连接权限、UI状态一致性、UDP内存泄漏等问题。                      |
| `1.7.0+86`    | 2026-06-09 | SuperYH | 新增心率广播接收器页面，支持BLE和WiFi UDP两种连接方式。                 |
| `1.6.58+85`   | 2026-06-08 | SuperYH | 批量转换多并行稳定性修复 + 安全加固。                                    |
| `1.6.57+84`   | 2026-06-08 | SuperYH | 修复历史记录删除输出文件时SAF目录文件未被删除的bug。                    |
| `1.6.56+83`   | 2026-06-08 | SuperYH | 质量预估优化 + 存储空间管理卡片。                                        |
| `1.6.55+82`   | 2026-06-08 | SuperYH | 批量转换多选模式 + 转换进行时锁定设置 + 历史记录删除优化。              |
| `1.6.36+63`   | 2026-06-07 | SuperYH | 修复续转卡在FFmpeg启动中、暂停按钮状态优化。                            |
| `1.6.21+47`   | 2026-06-07 | SuperYH | 转换启停逻辑重做："暂停"与"取消"语义彻底分开，支持跨进程恢复。          |
| `1.6.19+45`   | 2026-06-07 | SuperYH | 新增 `ConvertCoordinator`，修复"选择后台运行后转换直接结束"的 Bug。       |
| `1.6.18+44`   | 2026-06-07 | SuperYH | 视频转换通知 + 自定义保存路径优化。                                       |
| `1.6.17+43`   | 2026-06-07 | SuperYH | 修复视频转换完成后"打开文件 / 打开目录"失败的 Bug（`open_filex`）。       |
| `1.4.8+24`    | 2026-06-07 | SuperYH | 修复"所在文件夹有 m3u8 文件但说找不到"（SAF 替代 `getDirectoryPath`）。   |
| `1.4.7+23`    | 2026-06-07 | SuperYH | 修复扫描文件夹失败（`Invalid URI: /storage/emulated/0/...`）。            |
| `1.4.6+22`    | 2026-06-07 | SuperYH | 视频转换：M3U8 选择体验升级。                                             |
| `1.4.5+21`    | 2026-06-07 | SuperYH | M3U8 转换兜底引导。                                                       |
| `1.4.4+20`    | 2026-06-07 | SuperYH | 新增"选择 M3U8 所在文件夹"入口。                                         |
| `1.4.3+19`    | 2026-06-07 | SuperYH | M3U8 预处理：把片段复制到独立工作目录并改写为相对路径。                   |
| `1.4.2+18`    | 2026-06-07 | SuperYH | 修复 M3U8 片段裸文件（`0`/`1`/`2` 无后缀）场景。                          |
| `1.4.1+17`    | 2026-06-07 | SuperYH | 修复视频转换"URL ... is not in allowed_segment_extensions"。             |
| `1.4.0+16`    | 2026-06-07 | SuperYH | 新增 `AppStorage` 统一管理 App 数据目录。                                |
| `1.3.2+7`     | 2026-06-07 | SuperYH | 视频转换：FFmpeg 加 `-protocol_whitelist` + `-allowed_extensions ALL`。   |
| `1.3.1+6`     | 2026-06-07 | SuperYH | 修复视频格式转换"选择文件"时的 `MissingPluginException`。                 |
| `1.3.0+5`     | 2026-06-07 | SuperYH | 首页新增第三个工具：视频格式转换（基于 FFmpeg）。                         |
| `1.2.0+4`     | 2026-06-06 | SuperYH | 首页左上角新增三明治菜单，新增"设置"页面。                               |
| `1.1.1+3`     | 2026-06-06 | SuperYH | 调整首页"软件说明"按钮配色为灰色。                                       |
| `1.1.0+2`     | 2026-06-06 | SuperYH | 重新打包并部署：版本号更新为 1.1.0+2。                                   |
| `1.0.0+1`     | 2026-06-06 | SuperYH | 加入调试日志、关于页与日志查看页。                                        |

---

## 开发者

- **作者 / 维护者**：SuperYH
- **GitHub 账号**：[bluebighead](https://github.com/bluebighead)
- **项目主页**：[https://github.com/bluebighead/ToolApp-flutter](https://github.com/bluebighead/ToolApp-flutter)
- **问题反馈**：欢迎在 [Issues](https://github.com/bluebighead/ToolApp-flutter/issues) 中提单。

---

## 许可证

本项目目前为 **私有项目**（`pubspec.yaml` 中 `publish_to: 'none'`），未指定开源许可证。

> 如果你打算开源本仓库，请补充一个 `LICENSE` 文件并在 README 中更新本节。
> 常见选择：[MIT](./LICENSE) · [Apache-2.0](./LICENSE) · [GPL-3.0](./LICENSE)。
