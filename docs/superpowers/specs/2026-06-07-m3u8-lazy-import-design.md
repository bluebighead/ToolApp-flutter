# M3U8 目录选择：先扫后选 + 精准复制

**日期**：2026-06-07
**版本目标**：1.6.11+37
**状态**：分隔符已改为 NUL (U+0000)，待用户最终确认

## 背景

当前 `_pickM3u8Folder` 实现是：

1. SAF 选根目录
2. **直接**把整棵目录树复制到 `Directory.systemTemp`（可能 10+ GB）
3. 复制完后才扫 `.m3u8`，让用户挑

痛点：

- 用户一个根目录下有多个 M3U8（每个对应一个同名 segments 文件夹，几 GB 起步）
- 每次选目录都要等几十分钟复制
- 即使上次已经选过这个 M3U8，目录里其他无关 M3U8 的 segments 也会被重复复制
- v1.6.10+36 加的"按 tree URI 缓存整棵树"虽然避免了同一根目录的二次复制，但**用户换个根目录又要全部重拷**

## 目标

把"一次性复制整棵树"拆成"先扫 M3U8 列表 → 用户单选 → 只复制选中的那一份"。

预期收益：

- 首次进入选目录：扫描是毫秒级，无需等待
- 精准复制只涉及 1 个 M3U8 + 1 个 segments 文件夹（通常 1-2 GB），而不是整棵树
- 同根目录切换不同 M3U8：互不影响，各自缓存
- 同 M3U8 二次选择：直接命中缓存

## 用户场景

用户设备上的目录结构（用户描述）：

```
根目录/
├── 测试视频.m3u8              （KB 级）
├── 测试视频/                  （同名文件夹，GB 级 segments）
│   ├── seg_001.ts
│   ├── seg_002.ts
│   └── ...
├── 其他视频.m3u8
├── 其他视频/
│   ├── seg_001.ts
│   └── ...
```

## 设计

### 新流程

```
┌──────────────────────────────────────┐
│ 1. SAF 选根目录 → treeUri            │
└────────────┬─────────────────────────┘
             │ （不复制任何东西）
             ▼
┌──────────────────────────────────────┐
│ 2. 浅扫描根目录的 .m3u8 (毫秒级)      │
│    → ["测试视频.m3u8", ...]          │
└────────────┬─────────────────────────┘
             │
             ▼
┌──────────────────────────────────────┐
│ 3. 0 个 → 报错 SnackBar              │
│    1 个 → 直接用                     │
│    2+ 个 → 弹 SimpleDialog (单选)     │
└────────────┬─────────────────────────┘
             │ pickedRel
             ▼
┌──────────────────────────────────────┐
│ 4. 缓存检查 (key 见下文)              │
│    命中 → 复用 temp 目录              │
│    未命中 → ↓                         │
└────────────┬─────────────────────────┘
             │ (miss)
             ▼
┌──────────────────────────────────────┐
│ 5. 清理其他 treeUri 的旧缓存          │
│    + 建 temp 目录 + loading 对话框    │
└────────────┬─────────────────────────┘
             │
             ▼
┌──────────────────────────────────────┐
│ 6. 精准复制 (M3U8 + segments)         │
│    ├─ 复制 M3U8 文件到 temp           │
│    ├─ 尝试复制同名 segments 文件夹     │
│    │   存在 → 一次文件夹复制 (快)     │
│    │   不存在 → 解析 M3U8 拿到        │
│    │            segments 路径逐个复制  │
│    └─ 返回文件总数                    │
└────────────┬─────────────────────────┘
             │
             ▼
┌──────────────────────────────────────┐
│ 7. 关 loading + 注册新缓存            │
└────────────┬─────────────────────────┘
             │
             ▼
┌──────────────────────────────────────┐
│ 8. 走原有"找 M3U8 + setState"流程    │
└──────────────────────────────────────┘
```

### 缓存模型

#### 旧

```dart
String? _importCacheKey;       // 单条：tree URI
String? _importCacheDirPath;   // 单条：import 目录路径
```

#### 新

```dart
class _ImportCacheEntry {
  final String treeUri;
  final String m3u8Rel;
  final Directory dir;
}

/// 缓存 key: treeUri + NUL + m3u8Rel
///
/// 用 NUL (U+0000) 做分隔符的原因：
///   - 合法 SAF content URI 不会包含 NUL（会被 percent-encode 成 %00）
///   - 合法文件名（POSIX/Android）禁止 NUL
///   - 比 "|" 安全："/" 在 URI 里大量存在，"|" 也不会撞但 NUL 更稳
///
/// 在 Dart 代码里这样写：
///   final key = '$treeUri\u0000$m3u8Rel';
Map<String, _ImportCacheEntry> _importCache;  // 多条
```

#### 清理策略

| 场景 | 行为 |
|---|---|
| 用户切换根目录 | 旧 treeUri 的所有缓存从磁盘删（避免占空间） |
| 同根目录切换 M3U8 | 旧 M3U8 的缓存保留（用户可能切回来） |
| 页面 dispose | 所有缓存从磁盘删 |

#### 缓存 key 冲突分析

- `treeUri` 是 SAF 返回的 content URI，理论上同一根目录每次选都返回相同 URI；不同根目录 URI 不同
- `m3u8Rel` 是相对路径，根目录浅扫出来不会包含 `/`
- NUL 不会出现在任何合法 URI 或文件名里
- 三者组合 → 不会撞 key

### 启发式 + 解析双保险

#### 首选：同名文件夹启发式

约定：M3U8 文件 `xxx.m3u8` 的 segments 都在 `xxx/` 文件夹里。

```
treeUri/xxx.m3u8       →  treeUri/xxx/
```

实现上：复制 M3U8 文件 + 复制同名文件夹（一次文件夹级复制，Kotlin 用 `DocumentFile` 递归）。

#### 兜底：解析 M3U8

当同名文件夹**不存在**时，进入解析流程：

1. 读 temp 目录里的 M3U8 内容（已经复制过去了）
2. 解析出所有 segment 引用（相对路径）
3. 对每条引用：
   - 如果是 `http://` / `https://` 开头的 URL → **跳过**（FFmpeg 自己下载）
   - 否则 → 在 SAF treeUri 下解析出源文件路径，单独复制到 temp

解析器逻辑足够简单（找非 `#` 开头的行），不需要复用 `m3u8_normalizer.dart` 的全部能力。`m3u8_normalizer` 还会改 M3U8 内容（补扩展名等），我们这里**只解析、不修改**。

### 新增 Kotlin 方法

#### `listM3u8InDir(treeUri: String): List<String>`

- 用 `DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, ...)` 浅扫
- 过滤 `.m3u8` / `.M3U8` 后缀
- 返回相对于 treeUri 的路径列表

#### `copyM3u8WithSegments(treeUri: String, destDir: String, m3u8Rel: String): int`

逻辑：

1. 复制 M3U8 文件：`treeUri/<m3u8Rel>` → `destDir/<m3u8Rel>`，count += 1
2. 计算 segments 文件夹名：`<m3u8Rel 去扩展名>/`（如 `测试视频.m3u8` → `测试视频/`）
3. 用 `DocumentsContract` 检查 `treeUri/<segments_folder>/` 是否存在
4. **存在**：整文件夹递归复制到 `destDir/<segments_folder>/`，count += 文件数
5. **不存在**：
   - 读 `destDir/<m3u8Rel>` 内容
   - 解析 segment 引用
   - 对每条引用（非 URL）：单独复制 `treeUri/<seg_rel>` → `destDir/<seg_rel>`，count += 1
6. 返回 count

### 兼容性

- **保留** `listM3u8InTree` / `copyTreeToCache` / `_findM3u8Recursive` 不动
- 不删任何旧方法（其他地方可能用到，删了要扫一遍代码）
- 只在 `_pickM3u8Folder` 里改用新方法

### 不修改的部分

- `_pickM3u8File`（单文件选择器）保持不变
- 单 URL 模式（`_InputMode.url`）保持不变
- 转换流程（FFmpeg 调用、进度条、输出）保持不变
- 进度对话框（`_ImportProgressDialog`）保持不变

## 风险与边界

| 风险 | 缓解 |
|---|---|
| M3U8 引用 `https://...` 形式 segments | 解析时跳过，FFmpeg 自己下载；不影响复制流程 |
| M3U8 是 master playlist（引用其他 M3U8） | 暂不处理（首版聚焦主流程），后续可加二次解析 |
| 同名文件夹里有"无关文件" | 一起复制（少量冗余，但比整棵父目录少得多） |
| 树 URI 跨进程变化 | SAF 持久化权限可能在某些设备上失效 → 缓存不命中，走重新复制流程（已有逻辑） |
| 同根目录选不同 M3U8 缓存无限增长 | 用户手动 dispose 或切换根目录时清理；首版不引入 LRU |

## 数据流

### Cache Hit

```
用户点选 → SAF 选目录 → 浅扫 .m3u8 → 弹单选 → 缓存命中
→ 跳过复制 → setState 标记输入 → 显示"已命中缓存：xxx" SnackBar
```

### Cache Miss

```
用户点选 → SAF 选目录 → 浅扫 .m3u8 → 弹单选 → 缓存未命中
→ 清理旧 treeUri 缓存 → 建 temp 目录 → 弹 loading
→ 复制 M3U8 + 启发式/解析 segments → 关 loading
→ 注册新缓存 → setState 标记输入 → 显示"已导入：xxx" SnackBar
```

## 测试要点

手动验证：

1. 选根目录（多个 M3U8）→ 看到 M3U8 列表 → 选一个 → 精准复制 + 转换成功
2. 同根目录再选同一个 M3U8 → "已命中缓存"
3. 同根目录选另一个 M3U8 → 重新复制（旧的 M3U8 缓存保留）
4. 选另一个根目录 → 旧根目录的缓存从磁盘清掉
5. 选只有 1 个 M3U8 的根目录 → 不弹选择对话框，直接复制
6. 选没有 M3U8 的根目录 → 报错
7. M3U8 引用了 `https://` segments → 复制不报错的 segments，FFmpeg 自己下载 URL 的
8. 退出页面再进 → 缓存还在（内存级别，不持久化）

## 实现清单（待 writing-plans 拆任务）

1. **Kotlin 端**：
   - [ ] `SafDirectoryHelper.kt` 新增 `listM3u8InDir(treeUri)`
   - [ ] `SafDirectoryHelper.kt` 新增 `copyM3u8WithSegments(treeUri, destDir, m3u8Rel)`
2. **Dart 端**：
   - [ ] `video_convert_page.dart` 新增 `_ImportCacheEntry` 类
   - [ ] 把 `_importCacheKey` / `_importCacheDirPath` 改成 `Map<String, _ImportCacheEntry> _importCache`
   - [ ] 改写 `_clearImportCache` 支持按 treeUri 清理
   - [ ] 改写 `_pickM3u8Folder` 走新流程
   - [ ] 新增 `_prepareImportDirForM3u8(treeUri, m3u8Rel)` 辅助方法
3. **版本 + 发布**：
   - [ ] `pubspec.yaml` 1.6.10+36 → 1.6.11+37
   - [ ] `flutter build apk --release`
   - [ ] 装到手机
   - [ ] 清旧 APK
