# M3U8 先扫后选 + 精准复制 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"选完目录就复制整棵树"改成"先扫 M3U8 列表 → 用户单选 → 只复制选中的那一份（M3U8 文件 + 同名 segments 文件夹）"。

**Architecture:**
- **Kotlin 端**（`MainActivity.kt`）：新增 2 个 MethodChannel 方法 — `listM3u8InDir`（浅扫）和 `copyM3u8WithSegments`（M3U8 + 同名文件夹启发式，失败则解析 M3U8 逐文件复制）
- **Dart 端**（`video_convert_page.dart`）：把单条 `_importCacheKey`/`_importCacheDirPath` 换成 `Map<String, _ImportCacheEntry>`，key 用 `treeUri + NUL + m3u8Rel` 拼；重写 `_pickM3u8Folder` 走"先扫后选"流程

**Tech Stack:** Flutter / Dart, Kotlin, Android SAF (DocumentsContract + DocumentFile)

**Spec:** [docs/superpowers/specs/2026-06-07-m3u8-lazy-import-design.md](../specs/2026-06-07-m3u8-lazy-import-design.md)

---

## 文件结构

**修改：**
- `android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt` — 加 2 个新方法（listM3u8InDir, copyM3u8WithSegments）+ 辅助方法
- `lib/pages/video_convert_page.dart` — 重写缓存模型 + _pickM3u8Folder 流程
- `pubspec.yaml` — 版本号 1.6.10+36 → 1.6.11+37

**新增：** 无（所有改动都在现有文件里）

**不动：**
- `copyTreeToCache` / `listM3u8InTree` / `_findM3u8Recursive` 等旧方法保留（向后兼容）
- `_pickM3u8File`、URL 模式、FFmpeg 转换流程

---

## Task 1: Kotlin — 加 `listM3u8InDir` 浅扫

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt`

**背景：** 现成的 `listM3u8InTree` 是递归的（`collectM3u8Saf` 递归遍历），我们要的是只扫直接子项的浅扫版本。新方法基于 tree URI 列出 immediate children，过滤 `.m3u8`/`.M3U8` 后缀，返回相对路径列表。

- [ ] **Step 1: 在 MethodChannel handler 里注册新 case**

在 `setMethodCallHandler { call, result -> when (call.method) { ... } }` 块里，在 `"listM3u8InTree"` case 后面加：

```kotlin
"listM3u8InDir" -> {
    val treeUri = call.argument<String>("treeUri")
    if (treeUri == null) {
        result.error("ARG_ERROR", "treeUri 不能为空", null)
        return@setMethodCallHandler
    }
    Log.i(TAG, "listM3u8InDir [后台线程] 开始: $treeUri")
    Thread {
        try {
            val list = listM3u8InDir(treeUri)
            Log.i(TAG, "listM3u8InDir [后台线程] 完成: 找到 ${list.size} 个 .m3u8")
            runOnUiThread { result.success(list) }
        } catch (e: Throwable) {
            Log.e(TAG, "listM3u8InDir [后台线程] 失败", e)
            runOnUiThread {
                result.error(
                    "EXCEPTION",
                    e.message ?: "unknown",
                    e.stackTraceToString()
                )
            }
        }
    }.start()
}
```

- [ ] **Step 2: 加 `listM3u8InDir` 私有方法（SAF + FS 双分支）**

在 `listM3u8InTree` 方法后面加：

```kotlin
/**
 * 浅扫 treeUri 的直接子项里的 .m3u8 文件，返回相对路径列表。
 * 不递归（区别于 listM3u8InTree）。
 * 兼容 SAF content:// URI 和直接 FS 路径。
 */
private fun listM3u8InDir(treeUriOrPath: String): List<String> {
    val result = mutableListOf<String>()
    if (isContentUri(treeUriOrPath)) {
        val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
            ?: return emptyList()
        val children = try {
            tree.listFiles()
        } catch (e: Throwable) {
            Log.e(TAG, "listM3u8InDir: listFiles() 失败: ${e.message}", e)
            return emptyList()
        }
        if (children == null) {
            Log.w(TAG, "listM3u8InDir: listFiles() 返回 null: ${tree.uri}")
            return emptyList()
        }
        for (file in children) {
            val name = file.name ?: continue
            if (file.isFile &&
                (name.endsWith(".m3u8", ignoreCase = true) ||
                 name.endsWith(".M3U8", ignoreCase = true))
            ) {
                result.add(name)
            }
        }
    } else {
        val sourceDir = File(treeUriOrPath)
        if (!sourceDir.exists() || !sourceDir.isDirectory) return emptyList()
        if (!sourceDir.canRead()) {
            throw SecurityException(
                "FS 模式下无权限读取目录: ${sourceDir.absolutePath}。" +
                    "Android 11+ 严格模式（Scoped Storage）下需要用 SAF 选目录。"
            )
        }
        val children = sourceDir.listFiles() ?: return emptyList()
        for (file in children) {
            val name = file.name
            if (file.isFile &&
                (name.endsWith(".m3u8", ignoreCase = true) ||
                 name.endsWith(".M3U8", ignoreCase = true))
            ) {
                result.add(name)
            }
        }
    }
    return result
}
```

- [ ] **Step 3: 编译验证**

Run: `cd android && ./gradlew assembleDebug`（Windows: `gradlew.bat assembleDebug`）

Expected: BUILD SUCCESSFUL，无编译错误。如果有错就修。

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt
git commit -m "feat(kotlin): add listM3u8InDir for shallow M3U8 scan"
```

---

## Task 2: Kotlin — 加 `copyM3u8WithSegments`（启发式：M3U8 文件 + 同名文件夹）

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt`

**背景：** 这是新流程的核心。新方法接受 `treeUri` + `m3u8Rel`（M3U8 相对路径），先复制 M3U8 文件本身，然后启发式地尝试复制"同名 segments 文件夹"（如 `测试视频.m3u8` → `测试视频/`）。本任务只做"启发式"分支，解析兜底留到 Task 3。

- [ ] **Step 1: 在 MethodChannel handler 里注册新 case**

在 `"listM3u8InDir"` case 后面加：

```kotlin
"copyM3u8WithSegments" -> {
    val treeUri = call.argument<String>("treeUri")
    val destDir = call.argument<String>("destDir")
    val m3u8Rel = call.argument<String>("m3u8Rel")
    if (treeUri == null || destDir == null || m3u8Rel == null) {
        result.error(
            "ARG_ERROR",
            "treeUri / destDir / m3u8Rel 不能为空",
            null
        )
        return@setMethodCallHandler
    }
    Log.i(TAG, "copyM3u8WithSegments [后台线程] 开始: $treeUri / $m3u8Rel -> $destDir")
    Thread {
        try {
            val total = copyM3u8WithSegments(treeUri, File(destDir), m3u8Rel)
            Log.i(TAG, "copyM3u8WithSegments [后台线程] 完成: 复制 $total 个文件")
            runOnUiThread { result.success(total) }
        } catch (e: Throwable) {
            Log.e(TAG, "copyM3u8WithSegments [后台线程] 失败", e)
            runOnUiThread {
                result.error(
                    "EXCEPTION",
                    e.message ?: "unknown",
                    e.stackTraceToString()
                )
            }
        }
    }.start()
}
```

- [ ] **Step 2: 加 `copyM3u8WithSegments` 私有方法（启发式分支）**

在 `listM3u8InDir` 方法后面加：

```kotlin
/**
 * 精准复制单个 M3U8 + 它的 segments。
 *
 * 策略：
 *   1. 复制 M3U8 文件本身
 *   2. 启发式：尝试复制"同名 segments 文件夹"（如 "测试视频.m3u8" -> "测试视频/"）
 *      - 存在则整文件夹复制（一次文件夹级复制，最快）
 *      - 不存在则 fallthrough 到解析 M3U8 的兜底逻辑（见 Task 3）
 *
 * @return 复制的文件总数
 */
private fun copyM3u8WithSegments(
    treeUriOrPath: String,
    destDir: File,
    m3u8Rel: String
): Int {
    if (!destDir.exists()) destDir.mkdirs()
    var count = 0

    // 1. 复制 M3U8 文件本身
    count += copySingleFileSaf(treeUriOrPath, m3u8Rel, destDir)

    // 2. 启发式：尝试复制同名 segments 文件夹
    //    "测试视频.m3u8" -> "测试视频/"
    val segmentsFolderName = m3u8Rel.substringBeforeLast('.', m3u8Rel)
    val heuristicHit = tryCopyHeuristicFolder(
        treeUriOrPath, segmentsFolderName, destDir
    )
    if (heuristicHit > 0) {
        count += heuristicHit
        Log.i(TAG, "copyM3u8WithSegments: 启发式命中 segments 文件夹 $segmentsFolderName/")
        return count
    }

    // 3. 启发式失败，回退到解析 M3U8（见 Task 3）
    Log.w(TAG, "copyM3u8WithSegments: 启发式未命中（同名文件夹 $segmentsFolderName/ 不存在），走解析兜底")
    val parsedCount = parseAndCopySegments(
        treeUriOrPath, destDir, m3u8Rel
    )
    count += parsedCount
    return count
}
```

- [ ] **Step 3: 加 `copySingleFileSaf` 辅助方法（SAF + FS 双分支）**

在 `copyM3u8WithSegments` 后面加：

```kotlin
/**
 * 复制 treeUriOrPath 下的单个文件 m3u8Rel 到 destDir。
 * 保留 m3u8Rel 的 basename（不保留中间路径，本场景下 m3u8Rel 就是文件名）。
 * @return 1 表示成功，0 表示失败
 */
private fun copySingleFileSaf(
    treeUriOrPath: String,
    relPath: String,
    destDir: File
): Int {
    val name = File(relPath).name
    val outFile = File(destDir, name)
    try {
        if (isContentUri(treeUriOrPath)) {
            val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
                ?: return 0
            val sourceFile = tree.findFile(relPath)
                ?: run {
                    Log.w(TAG, "copySingleFileSaf: 找不到 $relPath 在 $treeUriOrPath")
                    return 0
                }
            if (!sourceFile.isFile) {
                Log.w(TAG, "copySingleFileSaf: $relPath 不是文件")
                return 0
            }
            contentResolver.openInputStream(sourceFile.uri).use { input ->
                if (input == null) return 0
                outFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
        } else {
            val sourceFile = File(treeUriOrPath, relPath)
            if (!sourceFile.exists() || !sourceFile.isFile) {
                Log.w(TAG, "copySingleFileSaf: FS 模式找不到 $sourceFile")
                return 0
            }
            sourceFile.inputStream().use { input ->
                outFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
        }
        return 1
    } catch (e: Throwable) {
        Log.w(TAG, "copySingleFileSaf 失败: $relPath -> ${outFile.absolutePath}: ${e.message}")
        return 0
    }
}
```

- [ ] **Step 4: 加 `tryCopyHeuristicFolder` 辅助方法（SAF + FS 双分支）**

在 `copySingleFileSaf` 后面加：

```kotlin
/**
 * 启发式：尝试把 treeUriOrPath/<folderName>/ 整个文件夹复制到 destDir/<folderName>/
 * @return 复制的文件数；0 表示文件夹不存在或复制失败
 */
private fun tryCopyHeuristicFolder(
    treeUriOrPath: String,
    folderName: String,
    destDir: File
): Int {
    return try {
        if (isContentUri(treeUriOrPath)) {
            val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
                ?: return 0
            val sourceFolder = tree.findFile(folderName)
                ?: return 0
            if (!sourceFolder.isDirectory) return 0
            val targetDir = File(destDir, folderName)
            copyDirRecursiveSaf(sourceFolder, targetDir)
        } else {
            val sourceFolder = File(treeUriOrPath, folderName)
            if (!sourceFolder.exists() || !sourceFolder.isDirectory) return 0
            if (!sourceFolder.canRead()) return 0
            val targetDir = File(destDir, folderName)
            copyDirRecursiveFs(sourceFolder, targetDir)
        }
    } catch (e: Throwable) {
        Log.w(TAG, "tryCopyHeuristicFolder 失败: $folderName: ${e.message}")
        0
    }
}
```

- [ ] **Step 5: 加 `parseAndCopySegments` 占位（Task 3 替换）**

在 `tryCopyHeuristicFolder` 后面加（Task 3 会替换为完整实现）：

```kotlin
/**
 * 兜底：解析 M3U8 文件拿到 segments 引用，逐个复制到 destDir。
 * Task 3 会替换为完整实现。
 */
private fun parseAndCopySegments(
    treeUriOrPath: String,
    destDir: File,
    m3u8Rel: String
): Int {
    // 占位：Task 3 实现
    Log.w(TAG, "parseAndCopySegments: 占位实现，Task 3 替换")
    return 0
}
```

- [ ] **Step 6: 编译验证**

Run: `cd android && ./gradlew assembleDebug`（Windows: `gradlew.bat assembleDebug`）

Expected: BUILD SUCCESSFUL。

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt
git commit -m "feat(kotlin): add copyM3u8WithSegments with same-name folder heuristic"
```

---

## Task 3: Kotlin — 实现 M3U8 解析兜底

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt`

**背景：** 启发式失败时（同名文件夹不存在），我们需要读 M3U8 文件内容，找出所有 segment 引用，逐个复制。`http://`/`https://` 开头的 URL 跳过（FFmpeg 自己下载）。

- [ ] **Step 1: 替换 `parseAndCopySegments` 占位为完整实现**

把 Task 2 Step 5 加的 `parseAndCopySegments` 方法整个替换为：

```kotlin
/**
 * 兜底：解析 M3U8 文件拿到 segments 引用，逐个复制到 destDir。
 *
 * 解析规则（简化版）：
 *   - 跳过空行和以 # 开头的行（注释 / 标签）
 *   - 每条引用是一个相对路径或 URL
 *   - http:// / https:// 开头的跳过（FFmpeg 自己下载）
 *   - 其余视为相对路径，解析到 treeUriOrPath 下的源文件，复制到 destDir
 *
 * 相对路径的解析方式：以 M3U8 文件所在目录为基准
 *   - 如果 segment 是 "测试视频/seg_001.ts"（M3U8 在根目录），源文件是 treeUri/测试视频/seg_001.ts
 *   - 如果 segment 是 "../其他文件夹/seg_001.ts"，先 normalize 再解析
 *
 * @return 成功复制的文件数
 */
private fun parseAndCopySegments(
    treeUriOrPath: String,
    destDir: File,
    m3u8Rel: String
): Int {
    val m3u8File = File(destDir, File(m3u8Rel).name)
    if (!m3u8File.exists()) {
        Log.w(TAG, "parseAndCopySegments: M3U8 文件不在 destDir: ${m3u8File.absolutePath}")
        return 0
    }

    // 1. 读 M3U8 内容
    val lines = try {
        m3u8File.readLines()
    } catch (e: Throwable) {
        Log.e(TAG, "parseAndCopySegments: 读 M3U8 失败: ${e.message}", e)
        return 0
    }

    // 2. 提取所有 segment 引用（非空行、非 # 开头）
    val segmentRefs = lines
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }

    if (segmentRefs.isEmpty()) {
        Log.w(TAG, "parseAndCopySegments: M3U8 里没找到 segment 引用")
        return 0
    }

    // 3. M3U8 所在目录（用于解析相对路径）
    val m3u8Dir = m3u8File.parentFile ?: destDir

    // 4. 逐个 segment 复制
    var count = 0
    for (ref in segmentRefs) {
        // 跳过 URL 形式的 segments（FFmpeg 会自己下载）
        if (ref.startsWith("http://", ignoreCase = true) ||
            ref.startsWith("https://", ignoreCase = true)
        ) {
            Log.i(TAG, "parseAndCopySegments: 跳过 URL segment: $ref")
            continue
        }

        // 解析相对路径
        val resolvedDest = File(m3u8Dir, ref).let { f ->
            // 简单 normalize：处理 ../ 和 ./ 
            try {
                f.canonicalFile
            } catch (e: Throwable) {
                f.absoluteFile
            }
        }
        // 计算相对 destDir 的目标路径（保留子目录结构）
        val relToDest = try {
            resolvedDest.relativeTo(destDir).path.replace('\\', '/')
        } catch (e: Throwable) {
            // resolvedDest 不在 destDir 下（跨目录引用），fallback 用 basename
            Log.w(TAG, "parseAndCopySegments: segment $ref 解析到 destDir 外，用 basename 兜底")
            File(ref).name
        }
        val sourceRel = relToDest

        // 5. 复制
        val copied = copySingleFileSaf(treeUriOrPath, sourceRel, destDir)
        if (copied == 1) {
            count++
        }
    }
    Log.i(TAG, "parseAndCopySegments: 解析得到 ${segmentRefs.size} 个引用，成功复制 $count 个")
    return count
}
```

- [ ] **Step 2: 编译验证**

Run: `cd android && ./gradlew assembleDebug`（Windows: `gradlew.bat assembleDebug`）

Expected: BUILD SUCCESSFUL。

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/kotlin/com/example/toolapp/MainActivity.kt
git commit -m "feat(kotlin): implement M3U8 parse fallback in copyM3u8WithSegments"
```

---

## Task 4: Dart — 加 `_ImportCacheEntry` 类 + Map 缓存模型

**Files:**
- Modify: `lib/pages/video_convert_page.dart`

**背景：** 把单条 `_importCacheKey` + `_importCacheDirPath` 改成 `Map<String, _ImportCacheEntry>`，key 用 `treeUri + NUL + m3u8Rel`。

- [ ] **Step 1: 删旧的字段（保留 `_clearImportCache` 方法）**

在 `_VideoConvertPageState` 类里搜 `_importCacheKey` 和 `_importCacheDirPath`，把这两个字段都删掉。`_clearImportCache` 方法先保留，下个 task 改写。

- [ ] **Step 2: 在类里加新字段**

在类里合适位置（紧挨着 `_importedTempDir` 字段附近）加：

```dart
/// 导入缓存：key -> 缓存条目
///
/// key 格式：`'$treeUri $m3u8Rel'`，用 NUL (U+0000) 做分隔符
///
/// 为什么不直接用 Record 或自定义类做 key？
///   - Dart `Map` 的 key 需要实现 `==` 和 `hashCode`
///   - Record 自带，但 IDE 调试时显示不如 String 直观
///   - String + NUL 简单可靠，NUL 不会出现在合法 SAF URI 或文件名里
///
/// 为什么不用单条字段（v1.6.10 的旧实现）？
///   - 旧实现一份缓存只能缓存一个 M3U8，切到另一个 M3U8 就清掉
///   - 同一根目录下有多个 M3U8 时互不干扰才是正确行为
Map<String, _ImportCacheEntry> _importCache = {};
```

- [ ] **Step 3: 删掉旧的 `_ImportPrepResult` 类（v1.6.10 的，新版不再用）**

搜索 `_ImportPrepResult` 类，删掉它（整个类定义）。新版的 cache 条目改用 `_ImportCacheEntry`（下面 Step 4 加）。

- [ ] **Step 4: 在文件顶部（顶层）加 `_ImportCacheEntry` 类**

紧挨着 `_InputMode` 枚举后面、`_ConvertStatus` 枚举前面，加：

```dart
/// 导入缓存条目：单个 M3U8 文件对应的 import 目录
///
/// [treeUri] 来源 SAF tree URI（content://...）
/// [m3u8Rel] M3U8 相对路径（如 "测试视频.m3u8"）
/// [dir] 复制完成后的临时目录（包含 M3U8 + segments）
class _ImportCacheEntry {
  final String treeUri;
  final String m3u8Rel;
  final Directory dir;

  const _ImportCacheEntry({
    required this.treeUri,
    required this.m3u8Rel,
    required this.dir,
  });
}
```

- [ ] **Step 5: 编译验证（只 Dart 部分）**

Run: `flutter analyze lib/pages/video_convert_page.dart`

Expected: 有错误（`_clearImportCache` 还在引用旧字段），但能看到 `_ImportCacheEntry` 类和 `_importCache` 字段被正确识别。

- [ ] **Step 6: Commit**

```bash
git add lib/pages/video_convert_page.dart
git commit -m "refactor(dart): replace single import cache with Map<String, _ImportCacheEntry>"
```

---

## Task 5: Dart — 加 cache 管理方法

**Files:**
- Modify: `lib/pages/video_convert_page.dart`

**背景：** 把旧的 `_clearImportCache({bool deleteDir = false})` 改写为支持新模型的方法集：
- `_makeCacheKey(treeUri, m3u8Rel)` — 拼 key
- `_findCache(treeUri, m3u8Rel)` — 查缓存，返回 entry 或 null
- `_registerCache(treeUri, m3u8Rel, dir)` — 注册
- `_evictCachesForOtherTrees(currentTreeUri, {bool deleteDirs})` — 切根目录时清理
- `_evictAllCaches({bool deleteDirs})` — dispose 时清理
- 改写 `_clearImportCache` 为内部辅助（不直接被外部调用）

- [ ] **Step 1: 加 `_makeCacheKey` 私有方法**

在 `_clearImportCache` 现有位置附近（后续会改它）加：

```dart
/// 拼 cache key：`treeUri + NUL + m3u8Rel`
///
/// 详细原因见 `_importCache` 字段注释
String _makeCacheKey(String treeUri, String m3u8Rel) =>
    '$treeUri $m3u8Rel';
```

- [ ] **Step 2: 加 `_findCache` 私有方法**

```dart
/// 在缓存里找 (treeUri, m3u8Rel) 对应的目录
///
/// 命中后还会检查磁盘目录是否还存在（外部可能清掉了 temp 目录）；
/// 不存在则清掉缓存条目并返回 null（让调用方走重新复制流程）
Future<_ImportCacheEntry?> _findCache(String treeUri, String m3u8Rel) async {
  final key = _makeCacheKey(treeUri, m3u8Rel);
  final entry = _importCache[key];
  if (entry == null) return null;
  if (!await entry.dir.exists()) {
    AppLogger.w('VideoConvertPage', '缓存目录已不存在，清掉条目：${entry.dir.path}');
    _importCache.remove(key);
    return null;
  }
  return entry;
}
```

- [ ] **Step 3: 加 `_registerCache` 私有方法**

```dart
/// 注册新的缓存条目
void _registerCache(String treeUri, String m3u8Rel, Directory dir) {
  _importCache[_makeCacheKey(treeUri, m3u8Rel)] = _ImportCacheEntry(
    treeUri: treeUri,
    m3u8Rel: m3u8Rel,
    dir: dir,
  );
}
```

- [ ] **Step 4: 加 `_evictCachesForOtherTrees` 私有方法**

```dart
/// 清掉所有 `treeUri != currentTreeUri` 的缓存
///
/// 场景：用户从根目录 A 切到根目录 B，A 的缓存从磁盘删（避免占空间）
///
/// [deleteDirs] 为 true 时同时把磁盘目录删掉；false 只清字段引用
Future<void> _evictCachesForOtherTrees(
  String currentTreeUri, {
  bool deleteDirs = true,
}) async {
  final toRemove = <String>[];
  for (final entry in _importCache.entries) {
    if (entry.value.treeUri != currentTreeUri) {
      toRemove.add(entry.key);
      if (deleteDirs) {
        try {
          if (await entry.value.dir.exists()) {
            await entry.value.dir.delete(recursive: true);
            AppLogger.i(
              'VideoConvertPage',
              '清理旧 treeUri 缓存目录：${entry.value.dir.path}',
            );
          }
        } catch (e) {
          AppLogger.w(
            'VideoConvertPage',
            '清理旧 treeUri 缓存目录失败：$e',
          );
        }
      }
    }
  }
  for (final k in toRemove) {
    _importCache.remove(k);
  }
}
```

- [ ] **Step 5: 加 `_evictAllCaches` 私有方法**

```dart
/// 清掉所有缓存
///
/// 场景：页面 dispose / 强制刷新
///
/// [deleteDirs] 为 true 时同时把磁盘目录全删掉
Future<void> _evictAllCaches({bool deleteDirs = true}) async {
  if (deleteDirs) {
    for (final entry in _importCache.values) {
      try {
        if (await entry.dir.exists()) {
          await entry.dir.delete(recursive: true);
        }
      } catch (e) {
        AppLogger.w('VideoConvertPage', '清理缓存目录失败：$e');
      }
    }
  }
  _importCache.clear();
}
```

- [ ] **Step 6: 改写旧的 `_clearImportCache` 改为内部辅助（或删除）**

旧的 `_clearImportCache` 签名是 `({bool deleteDir = false})`，新版不再被外部调用。如果 `grep` 确认无外部引用，直接删掉整个方法。如果有引用，改为调用新方法。

Run: `grep -n "_clearImportCache" lib/`（Windows PowerShell: `Select-String -Path lib/**/*.dart -Pattern "_clearImportCache"`）

Expected: 只在 `_VideoConvertPageState` 内部被引用（在 `_resetOutputState` 之类的地方）。如果有，改成调用 `_evictAllCaches(deleteDirs: true)`。如果没引用，直接删方法定义。

- [ ] **Step 7: 编译验证**

Run: `flutter analyze lib/pages/video_convert_page.dart`

Expected: 无错误（或只剩旧调用方的引用错误，下个 task 修）。

- [ ] **Step 8: Commit**

```bash
git add lib/pages/video_convert_page.dart
git commit -m "refactor(dart): add cache management methods (find/register/evict)"
```

---

## Task 6: Dart — 重写 `_pickM3u8Folder` 走新流程

**Files:**
- Modify: `lib/pages/video_convert_page.dart`

**背景：** 这是核心改动。把"选完目录直接 copyTreeToCache + 扫 M3U8 + 选"改成"选目录 → 浅扫 M3U8 → 选 → 缓存检查 → 命中复用/未命中精准复制"。

- [ ] **Step 1: 找到当前的 `_pickM3u8Folder` 方法位置**

用 `grep -n "_pickM3u8Folder" lib/pages/video_convert_page.dart` 找到方法定义（约在第 220 行附近）。整个方法用下面 Step 2-3 的新版替换。

- [ ] **Step 2: 替换 `_pickM3u8Folder` 方法**

整个方法替换为：

```dart
/// 选择 M3U8 所在的根目录（先扫后选 + 精准复制）
///
/// 适用场景：M3U8 + segments 在同一根目录下，file_picker 单文件模式只复制 M3U8，
/// segments 会丢失，导致 FFmpeg 找不到片段。
///
/// 流程（v1.6.11+ 重构版）：
///  1. SAF 选根目录 -> treeUri（不复制任何东西）
///  2. 浅扫根目录的 .m3u8 文件（毫秒级）
///  3. 0 个 -> 报错；1 个 -> 直接用；2+ 个 -> 弹选择对话框（单选）
///  4. 缓存检查（key = treeUri + NUL + m3u8Rel）
///  5. 命中 -> 复用之前的 import 目录
///  6. 未命中 -> 清理其他 treeUri 的旧缓存 + 建临时目录 + 弹 loading +
///               复制 M3U8 + 启发式/解析 segments + 注册新缓存
///  7. 走原有"找 M3U8 + setState"流程
Future<void> _pickM3u8Folder() async {
  AppLogger.i('VideoConvertPage', '点击选择 M3U8 所在根目录');
  try {
    final treeUri = await SafDirectoryHelper.pickDirectory();
    if (treeUri == null || treeUri.isEmpty) {
      AppLogger.i('VideoConvertPage', '用户取消选择目录');
      return;
    }

    // ========== 浅扫根目录的 .m3u8（不复制任何东西） ==========
    final m3u8List = await SafDirectoryHelper.listM3u8InDir(treeUri);
    AppLogger.i('VideoConvertPage', '扫到 ${m3u8List.length} 个 .m3u8：$m3u8List');

    if (m3u8List.isEmpty) {
      _showSnack('所选目录中没有 .m3u8 文件');
      return;
    }

    // ========== 用户挑一个 ==========
    String pickedRel;
    if (m3u8List.length == 1) {
      pickedRel = m3u8List.first;
    } else {
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('请选择 M3U8 播放列表（共 ${m3u8List.length} 个）'),
          children: m3u8List
              .map(
                (rel) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, rel),
                  child: Text(rel, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
        ),
      );
      if (selected == null) return;
      pickedRel = selected;
    }

    // ========== 准备 import 目录（缓存命中 / 未命中走不同分支） ==========
    final prep = await _prepareImportDirForM3u8(treeUri, pickedRel);
    if (prep == null) return;
    final Directory destDir = prep.dir;
    final bool cacheHit = prep.cacheHit;
    final int copied = prep.copiedCount;

    // ========== 找 M3U8、注册到 UI ==========
    final m3u8Path = p.join(destDir.path, pickedRel);
    AppLogger.i('VideoConvertPage', '最终 M3U8：$m3u8Path');

    // 关键自检：路径真的存在吗？找不到时回退到递归扫描
    final existsDirectly = await File(m3u8Path).exists();
    AppLogger.i('VideoConvertPage',
        'm3u8Path.exists() = $existsDirectly  (destDir=${destDir.path}, pickedRel=$pickedRel)');

    String actualM3u8Path = m3u8Path;
    if (!existsDirectly) {
      AppLogger.w('VideoConvertPage',
          '按 pickedRel 找不到 m3u8，递归扫描 destDir 找同名 M3U8 …');
      final found = await _findM3u8Recursive(destDir.path);
      if (found.isEmpty) {
        _showSnack('复制完成但在 $pickedRel 位置找不到 M3U8（$destDir）');
        return;
      }
      if (found.length == 1) {
        actualM3u8Path = found.first;
        AppLogger.i('VideoConvertPage', '回退匹配到唯一 M3U8：$actualM3u8Path');
      } else {
        if (!mounted) return;
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('找到多个同名 M3U8，请选择实际文件'),
            children: found
                .map(
                  (full) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, full),
                    child: Text(
                      p.relative(full, from: destDir.path),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
          ),
        );
        if (picked == null) return;
        actualM3u8Path = picked;
      }
    }

    // ⚠️ 缓存命中时需要先临时把 _importedTempDir 置空，
    // 否则 _resetOutputState 会把"上一次"指向同一个缓存目录的引用清掉，
    // 缓存目录直接被删，下次选同一个 M3U8 就缓存 miss 了
    if (cacheHit) {
      _importedTempDir = null;
    }
    int size = 0;
    try {
      size = await File(actualM3u8Path).length();
    } catch (_) {}
    setState(() {
      _inputMode = _InputMode.file;
      _sourceName = pickedRel;
      _sourceValue = actualM3u8Path;
      _sourceSize = size;
      _resetOutputState();
    });
    // 缓存命中：不注册 _importedTempDir（缓存自己管生命周期，dispose / 切目录时清）
    // 缓存未命中：注册新的临时目录（让旧目录被清，但新的保留）
    if (!cacheHit) {
      _importedTempDir = destDir;
    }
    _showSnack(cacheHit
        ? '已命中缓存：$pickedRel（跳过复制）'
        : '已导入：$pickedRel（共 $copied 个文件）');
  } catch (e, st) {
    AppLogger.e('VideoConvertPage', '选择 M3U8 目录失败', e, st);
    _showSnack('选择目录失败：$e');
  }
}
```

- [ ] **Step 3: 加 `_prepareImportDirForM3u8` 辅助方法**

在 `_pickM3u8Folder` 后面（`_findM3u8Recursive` 前面）加：

```dart
/// 单 M3U8 的 import 目录准备结果
class _M3u8ImportPrepResult {
  final Directory dir;
  final bool cacheHit;
  final int copiedCount;

  const _M3u8ImportPrepResult({
    required this.dir,
    required this.cacheHit,
    required this.copiedCount,
  });
}

/// 为单个 M3U8 准备 import 目录：缓存命中直接复用；缓存未命中则精准复制
///
/// 与旧的 `_prepareImportDir`（v1.6.10，按 treeUri 缓存整棵树）的区别：
///   - 按 (treeUri, m3u8Rel) 缓存，同一 root 下不同 M3U8 互不干扰
///   - 只复制 1 个 M3U8 + 它的 segments（不复制整棵 root 树）
///
/// 返回 null 表示 0 个文件（应该走 SnackBar 报错并提前返回）
Future<_M3u8ImportPrepResult?> _prepareImportDirForM3u8(
  String treeUri,
  String m3u8Rel,
) async {
  // ========== 缓存检查 ==========
  final cached = await _findCache(treeUri, m3u8Rel);
  if (cached != null) {
    AppLogger.i('VideoConvertPage',
        '命中导入缓存：$treeUri|$m3u8Rel -> ${cached.dir.path}（跳过复制）');
    return _M3u8ImportPrepResult(
      dir: cached.dir,
      cacheHit: true,
      copiedCount: 0,
    );
  }

  // ========== 缓存未命中：清理其他 treeUri 的旧缓存 + 精准复制 ==========
  // 切到新 root 时，旧 root 的缓存从磁盘清掉
  await _evictCachesForOtherTrees(treeUri, deleteDirs: true);

  // 先把目标目录建出来，progress dialog 才能轮询到它
  final newDir = await Directory.systemTemp.createTemp(
    'm3u8_import_${DateTime.now().millisecondsSinceEpoch}_',
  );
  AppLogger.i('VideoConvertPage', '精准复制到：${newDir.path}');

  if (!mounted) return null;
  // 带"已复制 N 个文件…"实时计数的 loading 对话框
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ImportProgressDialog(destDirPath: newDir.path),
  );
  AppLogger.i('VideoConvertPage', '已显示进度对话框');

  // Kotlin 后台线程跑，Dart 这边 await 不阻塞 UI
  final copied = await SafDirectoryHelper.copyM3u8WithSegments(
    treeUri: treeUri,
    destDir: newDir.path,
    m3u8Rel: m3u8Rel,
  );
  AppLogger.i('VideoConvertPage', '复制完成，共 $copied 个文件');

  if (copied <= 0) {
    if (mounted) Navigator.of(context).pop();
    await newDir.delete(recursive: true);
    _showSnack('复制失败：M3U8 文件不存在或无法访问');
    return null;
  }

  // 关 loading
  if (mounted) Navigator.of(context).pop();

  // 注册新缓存
  _registerCache(treeUri, m3u8Rel, newDir);

  return _M3u8ImportPrepResult(
    dir: newDir,
    cacheHit: false,
    copiedCount: copied,
  );
}
```

- [ ] **Step 4: 在 `dispose` 方法里调用 `_evictAllCaches`**

找 `dispose` 方法（应该在 `_VideoConvertPageState` 类里），在方法最后加：

```dart
// 页面销毁时清理所有 import 缓存（连磁盘目录一起删）
_evictAllCaches(deleteDirs: true);
```

- [ ] **Step 5: 删掉旧的 `_prepareImportDir` 和 `_ImportPrepResult`（如果有）**

如果 v1.6.10 加的旧方法还存在，删掉它们（被新的 `_prepareImportDirForM3u8` 取代）。

- [ ] **Step 6: 编译验证**

Run: `flutter analyze lib/pages/video_convert_page.dart`

Expected: 无错误。

- [ ] **Step 7: Commit**

```bash
git add lib/pages/video_convert_page.dart
git commit -m "feat(dart): rewrite _pickM3u8Folder with shallow scan + precise copy"
```

---

## Task 7: 版本号 + 构建 + 安装 + 清理

**Files:**
- Modify: `pubspec.yaml`
- Delete: `build/app/outputs/apk/release/app-release.apk`（如果存在）
- Delete: `build/app/outputs/flutter-apk/app-release.apk`（旧版本，新版本会覆盖）

- [ ] **Step 1: 升级版本号**

修改 `pubspec.yaml` 第 19 行（或附近）：

```yaml
version: 1.6.11+37
```

（旧值：`1.6.10+36`）

- [ ] **Step 2: 清理旧 APK（构建前先清）**

Run: 
```bash
Remove-Item build\app\outputs\apk\release\app-release.apk -ErrorAction SilentlyContinue
Remove-Item build\app\outputs\flutter-apk\app-release.apk -ErrorAction SilentlyContinue
```

- [ ] **Step 3: 构建 release APK**

Run: `flutter build apk --release 2>&1 | Tee-Object -FilePath build.log`

Expected: `Built build\app\outputs\flutter-apk\app-release.apk (xxx MB)`，exit code 0。

如果有编译错误，看 build.log 修。常见问题：
- `_ImportCacheEntry` 字段没匹配上
- `_clearImportCache` 还有旧引用（应该 Step 5 删干净了）
- 旧 `_prepareImportDir` 还有调用方

- [ ] **Step 4: 检查手机连接**

Run: `adb devices`

Expected: 至少一台设备 `device` 状态（不是 `unauthorized` 或 `offline`）。如果没有，提示用户插手机开 USB 调试。

- [ ] **Step 5: 安装到手机**

Run: `adb install -r build\app\outputs\flutter-apk\app-release.apk`

Expected: `Success`

- [ ] **Step 6: 清理旧 APK（构建后清）**

Run:
```bash
Remove-Item build\app\outputs\apk\release\app-release.apk -ErrorAction SilentlyContinue
```

（`flutter-apk/app-release.apk` 是新版本，保留）

- [ ] **Step 7: 手动测试 8 个场景**

打开 App，进入视频格式转换页面，验证：

1. 选有多个 M3U8 的根目录 → 看到 M3U8 列表 → 选一个 → **精准复制** + 转换成功
2. 同根目录再选同一个 M3U8 → "已命中缓存：xxx（跳过复制）"
3. 同根目录选另一个 M3U8 → 重新复制（旧的 M3U8 缓存保留在内存）
4. 选另一个根目录 → 旧根目录的缓存从磁盘清掉（看 logcat 应该有 "清理旧 treeUri 缓存目录"）
5. 选只有 1 个 M3U8 的根目录 → 不弹选择对话框，直接复制
6. 选没有 M3U8 的根目录 → 报错 "所选目录中没有 .m3u8 文件"
7. M3U8 引用了 `https://` segments → 复制不报错的 segments，FFmpeg 自己下载 URL 的
8. 退出页面再进 → 缓存还在（内存级别，App 不杀进程就还在）

- [ ] **Step 8: Commit**

```bash
git add pubspec.yaml
git commit -m "chore: bump version to 1.6.11+37"
```

---

## Self-Review 报告

**1. Spec 覆盖：**
- ✅ "先扫 M3U8 列表" — Task 6 Step 2
- ✅ "用户单选" — Task 6 Step 2（SimpleDialog）
- ✅ "只复制选中的那一份" — Task 2 + 3 + 6（copyM3u8WithSegments）
- ✅ "缓存粒度改为按 M3U8" — Task 4（Map<String, _ImportCacheEntry>）
- ✅ "key 用 NUL 分隔" — Task 4 + 5（`_makeCacheKey`）
- ✅ "启发式 + 解析双保险" — Task 2（启发式）+ Task 3（解析兜底）
- ✅ "清理策略" — Task 5（`_evictCachesForOtherTrees` / `_evictAllCaches`）
- ✅ "保留旧方法" — Task 1-3 没有改 copyTreeToCache / listM3u8InTree
- ✅ "版本号 + 构建 + 安装 + 清理" — Task 7

**2. Placeholder 扫描：**
- 无 TBD / TODO / "待实现"
- 每个代码块都是完整可粘贴的代码
- 每个命令都有 Expected 输出

**3. 类型一致性：**
- `_ImportCacheEntry { treeUri, m3u8Rel, dir }` — Task 4 定义，Task 5 用法一致
- `_M3u8ImportPrepResult { dir, cacheHit, copiedCount }` — Task 6 Step 3 定义并使用
- `_makeCacheKey` 拼 key 的方式：Task 5 + 6 一致（`'$treeUri\u0000$m3u8Rel'`）
- 缓存 key = `treeUri + NUL + m3u8Rel`，对应 spec 描述
