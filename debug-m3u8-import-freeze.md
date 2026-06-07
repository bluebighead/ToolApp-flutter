# Debug: 选 M3U8 目录后卡死

## 状态
[OPEN]

## 症状
- 用户点击"选择 M3U8 所在目录（推荐）"按钮
- 弹出系统 SAF 目录选择器，正常选择目录后
- App 完全卡死（不可点击任何按钮、无响应）

## 复现步骤
1. 打开 App → 视频格式转换
2. 点击"选择 M3U8 所在目录（推荐）"
3. 在系统 SAF 里选 M3U8 父目录
4. App 立即冻结

## 假设清单

| # | 假设 | 关键观测点 | 验证方式 |
|---|------|-----------|---------|
| H1 | `copyTreeToCache` 阻塞了 Android 主线程（UI 线程） | `DocumentFile.listFiles()` + `openInputStream().copyTo()` 是同步 I/O，方法通道回调默认在 MainThread 执行 | 把 `copyTreeToCache`/`listM3u8InTree` 整体挪到 `Thread` 或 `Executors.newSingleThreadExecutor` 上，结果用 `runOnUiThread { result.success(...) }` 回传 |
| H2 | 用户选了一个超大目录（整个 Downloads/），递归复制数千文件耗时极长 | 复制耗时随文件数线性增长 | UI 加 loading dialog，Kotlin 端每 50 个文件 `Log.i` 一次进度 |
| H3 | `DocumentFile.fromTreeUri()` 因权限问题返回 null / `listFiles()` 静默抛异常 | 看 logcat 是否有 `无法解析 tree URI` | 已有 try-catch，应能在 SnackBar 看到；如未触发说明卡在 listFiles 内 |
| H4 | SAF tree URI 权限未持久化，下次 `openInputStream` 时被拒 | 看是否有 `SecurityException` | H3 同样能覆盖 |
| H5 | Dart 侧 `await` 永远不返回（平台侧从未调 `result.success`），可能因主线程已死 | 看 Dart isolate 是否还有响应 | H1 修复后自然解除 |

## 计划修改

### 第一步（插桩 / 体验改善）
- Dart 端：选完目录后弹 loading 对话框，告诉用户"正在复制文件，请稍候..."
- Kotlin 端：补 `Log.i(TAG, ...)` 进度日志

### 第二步（最小修复，验证 H1）
- Kotlin 端：把 `copyTreeToCache`、`listM3u8InTree` 两个方法的实际工作
  整体挪到 `Thread { ... }.start()` 上跑；结果用 `runOnUiThread { result.success(...) }` 回主线程

## 验证标准
- 用户选目录后 UI 不再卡死（按钮仍可点击、loading dialog 可见旋转）
- 复制完成后 SnackBar 弹出"已导入 xxx.m3u8（共 N 个文件）"
- logcat 中能看到 `SafHelper` 标签的进度日志

## 修复内容
- `android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt`：
  - `copyTreeToCache`、`listM3u8InTree` 整体挪到 `Thread { ... }.start()` 后台线程执行
  - 结果通过 `runOnUiThread { result.success(...) }` 回传到主线程
  - `copyDirRecursiveSaf`、`collectM3u8Saf` 加 `Log.i` 进度日志
- `lib/pages/video_convert_page.dart` `_pickM3u8Folder`：
  - 选完目录后立即弹 `AlertDialog + CircularProgressIndicator` loading
  - 复制/扫描完成后统一 `Navigator.of(context).pop()` 关闭
  - 错误分支也会兜底关闭 dialog
- pubspec.yaml 升级 `1.6.5+31`，已 build + adb install -r 部署

## 状态
[FIXED] v1.6.6+32：加进度计数器后再次部署

## v1.6.5+31 复测反馈
- ✅ 不再卡死
- ❌ 体验差：loading 对话框没有进度数字，长时间"正在复制"让用户误以为死循环

## v1.6.6+32 改进
- 新增 `_ImportProgressDialog` 组件：
  - 接收 `destDir` 路径，每 300ms 轮询
  - 实时显示"已复制 N 个文件（X.X MB）"
  - 自动统计字节数，让用户感知到复制真的在推进
- 把 destDir 创建挪到 dialog 弹出之前，这样 dialog 上来时目录已存在
- 复制完成时统一 `Navigator.pop()` 关闭 dialog
- M3U8 多选对话框标题显示"共 N 个"，避免选错

## v1.6.6+32 复测反馈
- ✅ 进度能动了，体验改善
- ❌ 但复制完成转码时报 `m3u8_import_xxx/测试视频.m3u8: No such file or directory`

## v1.6.7+33 改进（路径自检 + 自动回退）
- 选完 M3U8 后，`m3u8Path = p.join(destDir.path, pickedRel)` 后立刻做 `File.exists()` 自检
- 不存在时：
  1. 用 `_findM3u8Recursive(destDir.path)` 递归扫描 destDir 找所有 `.m3u8`
  2. 找到唯一 → 直接用
  3. 找到多个 → 弹"找到多个同名 M3U8"对话框让用户挑
  4. 一个没找到 → 提示并在 SnackBar 里打出实际 destDir 路径
- 关键路径全部 `AppLogger.i`：m3u8List / pickedRel / m3u8Path / existsSync 结果
- 复测时把 logcat 中 tag=`VideoConvertPage` / `SafDirHelper` 的输出给我一份，能直接定位矛盾

## v1.6.7+33 复测反馈
- ❌ 仍然报 `m3u8_import_xxx/测试视频.m3u8: No such file or directory`，自检 + 回退都没用

## v1.6.7+33 失败根因（关键）
- 代码时序问题：`setState` 调 `_resetOutputState` → `_resetOutputState` 调 `_cleanupImportedTempDir`
- 而 `_cleanupImportedTempDir` 是按 `_importedTempDir` 字段**找到目录就 delete recursive**
- 原本想达到"切换输入源时把上一次的临时目录清掉"，但新导入的 destDir 已经被赋值给 `_importedTempDir` 了
- 顺序是：
  1. `_importedTempDir = destDir`  ← 新的 destDir 注册成"上一次的"
  2. `setState` → `_resetOutputState` → `_cleanupImportedTempDir` → **新 destDir 立刻被删！**
  3. UI 上 `_sourceValue = actualM3u8Path` 还指向这个已删除目录下的文件
  4. 用户点开始转换 → FFmpeg 报 No such file or directory
- 自检里 `File.exists()` 之所以返回 true，是因为**自检时 destDir 还在**（还没走到 setState 内部），过完 setState 才被删

## v1.6.8+34 修复
- 调整顺序：
  1. 先 setState（触发 `_resetOutputState` 清掉**旧的** _importedTempDir）
  2. setState 完后再 `_importedTempDir = destDir`（让新的 destDir 留到下次再清）
- 加了详细中文注释把这个坑钉死
