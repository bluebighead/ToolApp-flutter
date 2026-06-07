package com.example.toolapp

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * FlutterActivity 子类。
 *
 * 注册 MethodChannel `com.example.toolapp/saf_helper`，提供：
 *
 *   - pickDirectory({ initialUri? }):
 *       自行启动系统 SAF (`ACTION_OPEN_DOCUMENT_TREE`) 让用户选目录，
 *       返回 `content://com.android.externalstorage.documents/tree/...` 格式的 URI。
 *       同时 take 持久权限（takePersistableUriPermission），
 *       保证 App 重启后还能继续访问。
 *
 *   - copyTreeToCache(treeUriOrPath, destDir):
 *       递归复制"目标目录"到 destDir 真实目录。
 *       入参兼容两种格式：
 *         A. SAF tree URI：content://...
 *         B. 直接文件系统路径：/storage/emulated/0/...（仅供兼容老路径，
 *            在 Android 11+ Scoped Storage 下大概率会因为无权限而失败）
 *
 *   - listM3u8InTree(treeUriOrPath):
 *       扫描目标目录下所有 .m3u8 文件的相对路径列表。兼容同上。
 *
 *   - listM3u8InDir(treeUriOrPath):
 *       只扫直接子项里的 .m3u8（浅扫，不递归）。用于"先扫后选"流程。
 *
 *   - copyM3u8WithSegments(treeUriOrPath, destDir, m3u8Rel):
 *       精准复制单个 M3U8 文件 + 它的 segments：
 *         1) 先复制 M3U8 文件本身
 *         2) 启发式：尝试复制"同名 segments 文件夹"（如 "测试视频.m3u8" -> "测试视频/"）
 *         3) 启发式失败则解析 M3U8，按引用逐个复制 segments
 *       适用"先扫后选"流程：避免把整个根目录都复制过来。
 *
 * 为什么不直接用 file_picker.getDirectoryPath？
 *   在小米/Redmi 等深度定制 ROM 上，file_picker 8.1.x 的 getDirectoryPath
 *   在 Android 11+ 上**只返回 /storage/emulated/0/... 物理路径**，
 *   不返回 SAF content:// URI。我们拿这个路径调 DocumentFile.fromTreeUri
 *   会抛 IllegalArgumentException；而调 File.listFiles() 又会被
 *   Scoped Storage 静默拒掉。
 *   所以**自行启动 SAF Intent**才是稳定可靠的方案。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.example.toolapp/saf_helper"

    /**
     * 独立的"存储/文件操作"通道，专注于输出文件相关动作。
     * 与 SAF 通道分离，避免和目录选择流程耦合。
     */
    private val storageChannelName = "com.example.toolapp/storage"
    private val TAG = "SafHelper"

    /** 选目录请求码：保证唯一，避免与 Flutter 自身 onActivityResult 冲突 */
    private val REQUEST_CODE_PICK_DIRECTORY = 0x1001

    /** 暂存选目录 MethodChannel.Result，等 onActivityResult 回来再回 */
    private var pendingDirectoryResult: MethodChannel.Result? = null

    // 把 App 私有目录下的文件转成 content:// URI（走 FileProvider，规避 Android 7.0+ 的 FileUriExposedException）
    private fun fileProviderUriFor(file: File): Uri {
        val authority = "${packageName}.fileprovider"
        return FileProvider.getUriForFile(this, authority, file)
    }

    // 在系统文件管理器/视频播放器中定位并打开指定文件
    //
    // 设计要点：
    //   1) 多 mime 尝试：按从宽松到严格依次尝试 */* → video/* → video/<subtype>，
    //      解决部分文件管理器（MiXplorer / Solid / ES 等）只注册 */* 而播放器只注册 video/* 的问题
    //   2) 用 Intent.createChooser：即使只有 1 个 App 能处理也弹出选择器，
    //      用户可从所有候选里挑（视频播放器 / 文件管理器 / 图库等），不会"硬塞"给某个 App
    //   3) FLAG_GRANT_READ_URI_PERMISSION：把 content:// URI 的读权限临时授予被选中的 App
    //   4) 若所有 mime 均无 App 可处理，返回 false；Dart 端会走"调用 SAF 目录选择器"兜底
    private fun openContainingFolder(filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists()) {
            Log.w(TAG, "openContainingFolder: 文件不存在 $filePath")
            return false
        }
        Log.i(TAG, "openContainingFolder: 目标文件=$filePath")
        val fileUri: Uri = try {
            fileProviderUriFor(file)
        } catch (e: Throwable) {
            Log.e(TAG, "openContainingFolder: FileProvider 失败 ${e.message}", e)
            return false
        }

        // mime 尝试顺序：从最宽松到最具体
        //   */*：几乎所有"文件查看类" App 都会注册（文件管理器 / 文档查看器等）
        //   video/*：视频播放器（系统播放器、MX Player、VLC 等）
        //   video/<具体子类型>：少数只注册特定后缀的冷门播放器
        val mimeCandidates = listOf(
            "*/*",
            "video/*",
            "video/mp4",
            "video/x-matroska",
            "video/quicktime",
        )
        val pm = packageManager

        for (mime in mimeCandidates) {
            val probeIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(fileUri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val handlers = pm.queryIntentActivities(probeIntent, 0)
            if (handlers.isEmpty()) continue
            Log.i(
                TAG,
                "openContainingFolder: mime=$mime 找到 ${handlers.size} 个候选 App"
            )
            // 用 createChooser：把候选 App 全列给用户挑
            // （即使是 1 个 App，也走 chooser，让用户决定是"用播放器播放"还是"用文件管理器查看"）
            val chooser = Intent.createChooser(probeIntent, "选择应用打开").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return try {
                startActivity(chooser)
                Log.i(TAG, "openContainingFolder: 启动 chooser 成功 (mime=$mime)")
                true
            } catch (e: ActivityNotFoundException) {
                Log.w(TAG, "openContainingFolder: chooser 启动失败 (mime=$mime) ${e.message}")
                false
            } catch (e: Throwable) {
                Log.e(TAG, "openContainingFolder: 未知异常 (mime=$mime)", e)
                false
            }
        }

        Log.w(TAG, "openContainingFolder: 没有任何 App 能处理该文件")
        return false
    }

    /**
     * 把源文件 [srcPath] 写入用户通过 SAF 选定的自定义目录 [treeUri]。
     * 视频转换页面专用：让视频出现在用户"看得见"的系统目录中。
     *
     * 流程：
     *  1. DocumentFile.fromTreeUri 解析 treeUri（用户已在原生层 take 持久权限）
     *  2. 在该目录下创建目标文件名对应的 DocumentFile
     *  3. openOutputStream 写入 srcPath 的字节
     *  4. 返回最终写入的 SAF document URI（content://），便于"打开"和"分享"
     *
     * 注意：源 srcPath 仍然在 App 私有沙盒里；用户选择的"自定义目录"才是写入目标。
     * 写入成功后 App 私有副本保留（用户可选择删除），但"打开/分享"应该用 SAF URI。
     */
    private fun writeFileToSafTree(
        treeUri: String,
        fileName: String,
        srcPath: String
    ): String {
        val src = File(srcPath)
        if (!src.exists()) {
            throw FileNotFoundException("源文件不存在: $srcPath")
        }
        val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
            ?: throw FileNotFoundException("无法解析 SAF tree URI: $treeUri")
        if (!tree.canWrite()) {
            // 持久权限可能已失效，提示用户重选
            throw SecurityException("对所选目录无写权限，请重新选择保存目录")
        }
        // 1) 避免文件名冲突：如果同名文件已存在，在文件名后追加时间戳
        var finalName = fileName
        var targetDoc = tree.findFile(finalName)
        if (targetDoc != null && targetDoc.exists()) {
            val dotIdx = fileName.lastIndexOf('.')
            val stem = if (dotIdx > 0) fileName.substring(0, dotIdx) else fileName
            val ext = if (dotIdx > 0) fileName.substring(dotIdx) else ""
            val ts = System.currentTimeMillis()
            finalName = "${stem}_$ts$ext"
            targetDoc = tree.findFile(finalName)
        }
        // 2) 创建目标 DocumentFile
        val createdDoc = if (targetDoc == null) {
            tree.createFile("video/*", finalName)
                ?: throw IOException("无法在 SAF 目录中创建文件: $finalName")
        } else {
            targetDoc
        }
        // 3) 复制源文件字节
        contentResolver.openOutputStream(createdDoc.uri)?.use { out ->
            src.inputStream().use { input -> input.copyTo(out) }
        } ?: throw IOException("无法打开 SAF 输出流: ${createdDoc.uri}")
        Log.i(TAG, "writeFileToSafTree: 写入成功 $srcPath -> ${createdDoc.uri}")
        return createdDoc.uri.toString()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 SAF 通道（目录选择 / 树复制 / M3U8 扫描）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> handlePickDirectory(call, result)

                    "copyTreeToCache" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val destDir = call.argument<String>("destDir")
                        if (treeUri == null || destDir == null) {
                            result.error(
                                "ARG_ERROR",
                                "treeUri / destDir 不能为空",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        // 关键：MethodChannel 默认在主线程回调，
                        // DocumentFile.listFiles() + openInputStream().copyTo()
                        // 全是阻塞 I/O，会把 UI 线程卡死。
                        // 把整个工作挪到后台线程，结果 runOnUiThread 回传。
                        Log.i(TAG, "copyTreeToCache [后台线程] 开始: $treeUri -> $destDir")
                        Thread {
                            try {
                                val total = copyTreeToCache(treeUri, File(destDir))
                                Log.i(TAG, "copyTreeToCache [后台线程] 完成: 复制 $total 个文件")
                                runOnUiThread { result.success(total) }
                            } catch (e: Throwable) {
                                Log.e(TAG, "copyTreeToCache [后台线程] 失败", e)
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

                    "listM3u8InTree" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri == null) {
                            result.error("ARG_ERROR", "treeUri 不能为空", null)
                            return@setMethodCallHandler
                        }
                        // 同样在后台线程跑，避免大目录卡死 UI
                        Log.i(TAG, "listM3u8InTree [后台线程] 开始: $treeUri")
                        Thread {
                            try {
                                val list = listM3u8InTree(treeUri)
                                Log.i(TAG, "listM3u8InTree [后台线程] 完成: 找到 ${list.size} 个 .m3u8")
                                runOnUiThread { result.success(list) }
                            } catch (e: Throwable) {
                                Log.e(TAG, "listM3u8InTree [后台线程] 失败", e)
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

                    // 浅扫：只列直接子项里的 .m3u8，不递归
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

                    // 精准复制：单个 M3U8 + 它的 segments（启发式 + 解析兜底）
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
                                val total = copyM3u8WithSegments(
                                    treeUri, File(destDir), m3u8Rel
                                )
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

                    // 在系统文件管理器中定位并高亮指定文件
                    // 入口已迁移到 storageChannelName 通道（com.example.toolapp/storage）
                    // 保留此注释提示该方法由 storage 通道提供

                    else -> result.notImplemented()
                }
            }

        // 注册存储通道（输出文件的"打开"/"打开目录"/"分享"/"写入 SAF 自定义目录"等动作）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 在系统文件管理器/视频播放器中定位并打开指定文件
                    // 入参：filePath（绝对路径）
                    // 行为：把 App 私有目录里的文件转成 content:// URI（FileProvider），
                    //       走 ACTION_VIEW + FLAG_GRANT_READ_URI_PERMISSION 调起系统应用
                    "openContainingFolder" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("ARG_ERROR", "filePath 不能为空", null)
                            return@setMethodCallHandler
                        }
                        val ok = openContainingFolder(filePath)
                        if (ok) {
                            result.success(true)
                        } else {
                            result.error(
                                "NO_HANDLER",
                                "未找到可用的文件管理器",
                                null
                            )
                        }
                    }
                    // 把源文件写入用户选定的 SAF 自定义目录
                    // 入参：treeUri（SAF tree URI 字符串）, fileName（目标文件名）, srcPath（源文件绝对路径）
                    // 返回：写入成功后的 SAF document URI（content://...）
                    "writeFileToSafTree" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val fileName = call.argument<String>("fileName")
                        val srcPath = call.argument<String>("srcPath")
                        if (treeUri == null || fileName == null || srcPath == null) {
                            result.error("ARG_ERROR", "treeUri / fileName / srcPath 不能为空", null)
                            return@setMethodCallHandler
                        }
                        // 写入涉及 I/O，丢到后台线程避免阻塞 UI
                        Thread {
                            try {
                                val written = writeFileToSafTree(treeUri, fileName, srcPath)
                                runOnUiThread { result.success(written) }
                            } catch (e: Throwable) {
                                Log.e(TAG, "writeFileToSafTree 失败", e)
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
                    else -> result.notImplemented()
                }
            }
    }

    // ----------------------------------------------------------------------
    // 选目录入口
    // ----------------------------------------------------------------------

    /**
     * 启动系统 SAF 让用户选目录，回调通过 onActivityResult 走回。
     * 入参 `initialUri`：可选的 `content://` tree URI，让 SAF 默认定位到该目录
     *   （例如 `content://com.android.externalstorage.documents/tree/primary%3ADownload`）。
     *   由 Dart 端根据 M3U8 文件路径推断。
     */
    private fun handlePickDirectory(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        if (pendingDirectoryResult != null) {
            result.error("BUSY", "已有选目录请求在进行中", null)
            return
        }
        pendingDirectoryResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            // 关键：让 SAF 默认定位到 M3U8 所在"父"位置（用户少点几次）
            val initialUriStr = call.argument<String>("initialUri")
            if (!initialUriStr.isNullOrEmpty()) {
                try {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUriStr))
                } catch (e: Throwable) {
                    Log.w(TAG, "设置 EXTRA_INITIAL_URI 失败: ${e.message}")
                }
            }
        }

        try {
            startActivityForResult(intent, REQUEST_CODE_PICK_DIRECTORY)
        } catch (e: Throwable) {
            pendingDirectoryResult = null
            result.error(
                "EXCEPTION",
                "无法启动 SAF 目录选择器: ${e.message}",
                e.stackTraceToString()
            )
        }
    }

    /**
     * SAF 选目录完成回调。
     * 注意：必须用 super.onActivityResult(...) 先让 Flutter 处理它自己的 requestCode，
     * 我们的 REQUEST_CODE_PICK_DIRECTORY 是 0x1001（> 0xFF），不会和 Flutter 冲突。
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != REQUEST_CODE_PICK_DIRECTORY) return

        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null

        if (resultCode == RESULT_OK && data?.data != null) {
            val uri = data.data!!
            // 关键：take 持久权限，App 重启后仍可读
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (e: Throwable) {
                Log.w(TAG, "takePersistableUriPermission 失败: ${e.message}")
            }
            Log.i(TAG, "用户选择目录: $uri")
            result.success(uri.toString())
        } else {
            Log.i(TAG, "用户取消选择目录 (resultCode=$resultCode)")
            result.success(null)
        }
    }

    // ----------------------------------------------------------------------
    // 复制 / 扫描入口：兼容 content:// URI 和直接路径
    // ----------------------------------------------------------------------

    private fun copyTreeToCache(treeUriOrPath: String, destDir: File): Int {
        if (!destDir.exists()) destDir.mkdirs()
        if (isContentUri(treeUriOrPath)) {
            // 分支 A：SAF tree URI
            val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
                ?: throw FileNotFoundException("无法解析 tree URI: $treeUriOrPath")
            return copyDirRecursiveSaf(tree, destDir)
        } else {
            // 分支 B：直接路径（兜底，在 Android 11+ 大概率失败）
            val sourceDir = File(treeUriOrPath)
            if (!sourceDir.exists() || !sourceDir.isDirectory) {
                throw FileNotFoundException("路径不存在或不是目录: $treeUriOrPath")
            }
            if (!sourceDir.canRead()) {
                throw SecurityException(
                    "FS 模式下无权限读取目录: ${sourceDir.absolutePath}。" +
                        "Android 11+ 严格模式（Scoped Storage）下需要用 SAF 选目录，" +
                        "App 才能获得访问授权。"
                )
            }
            return copyDirRecursiveFs(sourceDir, destDir)
        }
    }

    private fun listM3u8InTree(treeUriOrPath: String): List<String> {
        val result = mutableListOf<String>()
        if (isContentUri(treeUriOrPath)) {
            // 分支 A：SAF tree URI
            val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
                ?: return emptyList()
            collectM3u8Saf(tree, "", result)
        } else {
            // 分支 B：直接路径
            val sourceDir = File(treeUriOrPath)
            if (!sourceDir.exists() || !sourceDir.isDirectory) return emptyList()
            if (!sourceDir.canRead()) {
                // 与 copyTreeToCache 一致：明确抛错，不静默吞掉
                throw SecurityException(
                    "FS 模式下无权限读取目录: ${sourceDir.absolutePath}。" +
                        "Android 11+ 严格模式（Scoped Storage）下需要用 SAF 选目录。"
                )
            }
            collectM3u8Fs(sourceDir, "", result)
        }
        return result
    }

    /**
     * 浅扫：只列 treeUriOrPath 直接子项里的 .m3u8 文件，返回相对路径列表（不带子目录）。
     * 不递归，区别于 [listM3u8InTree]。
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

    /**
     * 精准复制单个 M3U8 + 它的 segments。
     *
     * 策略：
     *   1. 复制 M3U8 文件本身
     *   2. 多候选启发式：尝试复制 segments 文件夹，按以下顺序：
     *      a) "<M3U8文件名>.m3u8_contents" — 一些视频下载工具的命名规则（实测最常见）
     *      b) "<M3U8文件名>"（去后缀）— 通用约定
     *      c) "<M3U8完整文件名>" — 极少见
     *      d) 从 M3U8 内容里 segment refs 第一段提取的父目录名 — 兜底
     *      任一命中则整文件夹复制（一次文件夹级复制，最快）
     *   3. 启发式都未命中 → 解析 M3U8 内容，逐个 segment 复制
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
        count += copySingleFile(treeUriOrPath, m3u8Rel, destDir)

        // 2. 多候选启发式：依次尝试不同命名规则的同名 segments 文件夹
        //
        // 实际场景的命名约定（按命中概率排序）：
        //   a) "<M3U8文件名>.m3u8_contents" — 一些视频下载工具/网盘客户端的命名规则
        //      例：TUE-142...2896591493.m3u8 -> TUE-142...2896591493.m3u8_contents/
        //   b) "<M3U8文件名>（去后缀）" — 通用约定
        //      例：测试视频.m3u8 -> 测试视频/
        //   c) "<M3U8完整文件名>" — 极少见但无副作用
        //   d) 从 M3U8 内部 segment refs 第一段提取的父目录 — 兜底
        val m3u8BaseName = m3u8Rel.substringBeforeLast('/', m3u8Rel)
        val m3u8FileName = File(m3u8Rel).name
        val m3u8Stem = m3u8FileName.substringBeforeLast('.', m3u8FileName)

        val candidates = mutableListOf<String>().apply {
            // a) <M3U8文件名>.m3u8_contents（实测最常见）
            add("$m3u8BaseName/$m3u8FileName.m3u8_contents")
            // b) <M3U8文件名>（去 .m3u8 后缀）
            add("$m3u8BaseName/$m3u8Stem")
            // c) <M3U8完整文件名>（极少见但尝试一下）
            add("$m3u8BaseName/$m3u8FileName")
        }

        for (candidate in candidates) {
            val folderName = candidate.substringAfterLast('/')
            val copied = tryCopyHeuristicFolder(treeUriOrPath, folderName, destDir)
            if (copied > 0) {
                count += copied
                Log.i(TAG, "copyM3u8WithSegments: 启发式命中 '$folderName'，复制 $copied 个文件")
                return count
            }
        }

        // 3. 上面启发式都失败 → 解析 M3U8 拿到 segment refs，从第一段提取候选文件夹名
        val parsedFirstSeg = firstSegmentFolderFromM3u8(destDir, m3u8Rel)
        if (parsedFirstSeg != null && parsedFirstSeg !in candidates.map { it.substringAfterLast('/') }) {
            val copied = tryCopyHeuristicFolder(treeUriOrPath, parsedFirstSeg, destDir)
            if (copied > 0) {
                count += copied
                Log.i(TAG, "copyM3u8WithSegments: 启发式命中（从 M3U8 解析）'$parsedFirstSeg'，复制 $copied 个文件")
                return count
            }
        }

        // 4. 全部启发式失败 → 解析 M3U8 逐个复制 segments
        Log.w(
            TAG,
            "copyM3u8WithSegments: 启发式都未命中（试过 ${candidates.size} 个候选" +
                (if (parsedFirstSeg != null) " + 解析候选 '$parsedFirstSeg'" else "") +
                "），走逐个复制兜底"
        )
        val parsedCount = parseAndCopySegments(treeUriOrPath, destDir, m3u8Rel)
        count += parsedCount
        if (parsedCount == 0) {
            // 兜底也复制了 0 个 → 大概率是云端没下载，提示用户
            Log.w(
                TAG,
                "copyM3u8WithSegments: ⚠️ segments 一个都没复制成功。" +
                    "可能 M3U8 引用了 URL 形式的 segments，或对应 segments 文件夹在云端未下载到本地。"
            )
        }
        return count
    }

    /**
     * 解析 M3U8 拿到第一个非空、非注释行，取其第一段 '/' 之前的部分作为
     * 候选 segments 文件夹名。
     *
     * 例：M3U8 内容第一行 segment ref 是
     *     "TUE-142 尾随...MissAV...2896591493.m3u8_contents/0"
     * 则返回 "TUE-142 尾随...MissAV...2896591493.m3u8_contents"
     */
    private fun firstSegmentFolderFromM3u8(destDir: File, m3u8Rel: String): String? {
        return try {
            val m3u8File = File(destDir, File(m3u8Rel).name)
            if (!m3u8File.exists()) return null
            val firstRef = m3u8File.useLines { lines ->
                lines
                    .map { it.trim() }
                    .firstOrNull { it.isNotEmpty() && !it.startsWith("#") }
            } ?: return null
            // 跳过 http(s)://
            if (firstRef.startsWith("http://", true) || firstRef.startsWith("https://", true)) {
                null
            } else {
                firstRef.substringBefore('/').takeIf { it.isNotEmpty() && it != firstRef }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "firstSegmentFolderFromM3u8 失败: ${e.message}")
            null
        }
    }

    /**
     * 复制 treeUriOrPath 下的单个文件 relPath 到 destDir。
     *
     * relPath 可以是多段路径（含 '/'），例如 "subdir1/subdir2/file.ts"。
     * SAF 模式下 DocumentFile.findFile 只查直接子项，所以按 '/' split
     * 逐层链式 findFile；同时 destDir 下也建对应的子目录结构。
     *
     * @return 1 表示成功，0 表示失败
     */
    private fun copySingleFile(
        treeUriOrPath: String,
        relPath: String,
        destDir: File
    ): Int {
        // outFile 保留 relPath 的子目录结构（不只取 basename）
        val outFile = File(destDir, relPath)
        return try {
            if (isContentUri(treeUriOrPath)) {
                val tree = DocumentFile.fromTreeUri(this, Uri.parse(treeUriOrPath))
                    ?: return 0
                // 按 '/' split，链式 findFile（SAF 的 findFile 只查直接子项，不支持 '/'）
                val parts = relPath.split('/').filter { it.isNotEmpty() }
                if (parts.isEmpty()) {
                    Log.w(TAG, "copySingleFile: relPath 为空")
                    return 0
                }
                var current: DocumentFile? = tree
                for ((idx, part) in parts.withIndex()) {
                    current = current?.findFile(part)
                    if (current == null) {
                        if (idx == 0) {
                            Log.w(TAG, "copySingleFile: SAF findFile('${parts[0]}') 在 root 下未找到（relPath='$relPath'）")
                        } else {
                            Log.w(TAG, "copySingleFile: 链式 findFile 第 ${idx + 1} 段 '$part' 失败（relPath='$relPath'）")
                        }
                        return 0
                    }
                }
                val sourceFile = current
                if (sourceFile == null || !sourceFile.isFile) {
                    Log.w(TAG, "copySingleFile: $relPath 不是文件（是目录？）")
                    return 0
                }
                outFile.parentFile?.mkdirs()
                val ok = try {
                    contentResolver.openInputStream(sourceFile.uri)?.use { input ->
                        outFile.outputStream().use { output -> input.copyTo(output) }
                        true
                    } ?: false
                } catch (e: Throwable) {
                    Log.w(TAG, "copySingleFile 复制流失败: $relPath: ${e.message}")
                    false
                }
                if (ok) 1 else 0
            } else {
                val sourceFile = File(treeUriOrPath, relPath)
                if (!sourceFile.exists() || !sourceFile.isFile) {
                    return 0
                }
                outFile.parentFile?.mkdirs()
                sourceFile.inputStream().use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
                1
            }
        } catch (e: Throwable) {
            Log.w(TAG, "copySingleFile 异常: relPath='$relPath' error=${e.message}")
            0
        }
    }

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
                if (sourceFolder == null) {
                    Log.i(TAG, "tryCopyHeuristicFolder: root 下没有 '$folderName' 文件夹（启发式未命中）")
                    return 0
                }
                if (!sourceFolder.isDirectory) return 0
                val targetDir = File(destDir, folderName)
                val copied = copyDirRecursiveSaf(sourceFolder, targetDir)
                Log.i(TAG, "tryCopyHeuristicFolder: '$folderName' 命中，复制 $copied 个文件 -> $targetDir")
                copied
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
        Log.i(TAG, "parseAndCopySegments: M3U8 共 ${lines.size} 行")

        // 2. 提取所有 segment 引用（非空行、非 # 开头）
        val segmentRefs = lines
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }

        if (segmentRefs.isEmpty()) {
            Log.w(TAG, "parseAndCopySegments: M3U8 里没找到 segment 引用")
            return 0
        }
        Log.i(TAG, "parseAndCopySegments: 解析到 ${segmentRefs.size} 个 segment 引用")

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

            // 解析相对路径到 destDir 内
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
            val copied = copySingleFile(treeUriOrPath, sourceRel, destDir)
            if (copied == 1) {
                count++
            } else if (count < 3) {
                // 只在每段第一次失败时打日志，避免 N 段全打刷屏
                Log.w(TAG, "parseAndCopySegments: 复制失败 $count+：sourceRel='$sourceRel'")
            }
        }
        Log.i(TAG, "parseAndCopySegments: 解析得到 ${segmentRefs.size} 个引用，成功复制 $count 个")
        return count
    }

    private fun isContentUri(s: String): Boolean = s.startsWith("content://")

    // ----------------------------------------------------------------------
    // SAF 分支
    // ----------------------------------------------------------------------

    private fun copyDirRecursiveSaf(source: DocumentFile, dest: File): Int {
        var count = 0
        if (!dest.exists()) dest.mkdirs()
        val children = try {
            source.listFiles()
        } catch (e: Throwable) {
            Log.e(TAG, "DocumentFile.listFiles() 失败: ${e.message}", e)
            return 0
        }
        if (children == null) {
            Log.w(TAG, "DocumentFile.listFiles() 返回 null: ${source.uri}")
            return 0
        }
        Log.i(TAG, "SAF 目录 ${source.name ?: "(未命名)"} 包含 ${children.size} 个直接子项，开始复制")
        for (file in children) {
            val name = file.name ?: continue
            if (file.isDirectory) {
                count += copyDirRecursiveSaf(file, File(dest, name))
            } else if (file.isFile) {
                val outFile = File(dest, name)
                try {
                    contentResolver.openInputStream(file.uri).use { input ->
                        if (input == null) continue
                        outFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                    count++
                    // 每 50 个文件打一次进度
                    if (count % 50 == 0) {
                        Log.i(TAG, "SAF 复制进度: 已复制 $count 个文件")
                    }
                } catch (e: Throwable) {
                    Log.w(
                        TAG,
                        "SAF 复制失败: ${file.uri} -> ${outFile.absolutePath}: ${e.message}"
                    )
                }
            }
        }
        return count
    }

    private fun collectM3u8Saf(
        dir: DocumentFile,
        prefix: String,
        out: MutableList<String>
    ) {
        val children = try {
            dir.listFiles()
        } catch (e: Throwable) {
            Log.e(TAG, "collectM3u8Saf: listFiles() 失败: ${e.message}", e)
            return
        }
        if (children == null) {
            Log.w(TAG, "collectM3u8Saf: listFiles() 返回 null: ${dir.uri}")
            return
        }
        for (file in children) {
            val name = file.name ?: continue
            val rel = if (prefix.isEmpty()) name else "$prefix/$name"
            if (file.isDirectory) {
                collectM3u8Saf(file, rel, out)
            } else if (file.isFile) {
                if (name.endsWith(".m3u8", ignoreCase = true) ||
                    name.endsWith(".M3U8", ignoreCase = true)
                ) {
                    out.add(rel)
                }
            }
        }
    }

    // ----------------------------------------------------------------------
    // FS 分支（兜底，Android 10 以下能工作，11+ 大概率失败）
    // ----------------------------------------------------------------------

    private fun copyDirRecursiveFs(source: File, dest: File): Int {
        var count = 0
        if (!dest.exists()) dest.mkdirs()
        val children = source.listFiles()
        if (children == null) {
            Log.w(TAG, "FS listFiles() 返回 null: ${source.absolutePath}")
            return 0
        }
        for (file in children) {
            if (file.isDirectory) {
                count += copyDirRecursiveFs(file, File(dest, file.name))
            } else if (file.isFile) {
                val outFile = File(dest, file.name)
                try {
                    file.inputStream().use { input ->
                        outFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                    count++
                } catch (e: Throwable) {
                    Log.w(
                        TAG,
                        "FS 复制失败: ${file.absolutePath} -> ${outFile.absolutePath}: ${e.message}"
                    )
                }
            }
        }
        return count
    }

    private fun collectM3u8Fs(
        dir: File,
        prefix: String,
        out: MutableList<String>
    ) {
        if (!dir.canRead()) {
            throw SecurityException("FS 模式下无权限读取目录: ${dir.absolutePath}")
        }
        val children = dir.listFiles()
        if (children == null) {
            // 不静默吞掉：listFiles() 返回 null 在 Android 11+ Scoped Storage 下
            // 经常意味着无权限，让上游能看到具体原因。
            throw SecurityException(
                "FS 模式下无法列出目录内容: ${dir.absolutePath}。" +
                    "Android 11+ 严格模式（Scoped Storage）下需要用 SAF 选目录。"
            )
        }
        for (file in children) {
            val name = file.name
            val rel = if (prefix.isEmpty()) name else "$prefix/$name"
            if (file.isDirectory) {
                collectM3u8Fs(file, rel, out)
            } else if (file.isFile) {
                if (name.endsWith(".m3u8", ignoreCase = true) ||
                    name.endsWith(".M3U8", ignoreCase = true)
                ) {
                    out.add(rel)
                }
            }
        }
    }
}
