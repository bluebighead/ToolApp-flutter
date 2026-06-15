package com.example.toolapp

import android.media.MediaCodecList
import android.media.MediaCodecInfo
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiInfo
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
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
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "com.example.toolapp/saf_helper"

    /**
     * 独立的"存储/文件操作"通道，专注于输出文件相关动作。
     * 与 SAF 通道分离，避免和目录选择流程耦合。
     */
    private val storageChannelName = "com.example.toolapp/storage"
    /** 复制进度 EventChannel：用于向 Dart 端推送实时进度 */
    private val copyProgressChannelName = "com.example.toolapp/copy_progress"
    /** 前台服务控制 MethodChannel：用于启动/停止转换保活服务 */
    private val foregroundServiceChannelName = "com.example.toolapp/foreground_service"
    /** 编解码器检测 MethodChannel：用于检测设备硬件编码能力 */
    private val codecDetectorChannelName = "com.example.toolapp/codec_detector"
    /** 联机掷骰子 WiFi 通道：MulticastLock + WiFi SSID 获取 */
    private val wifiChannelName = "com.example.toolapp/wifi_helper"
    private val TAG = "SafHelper"

    /** WiFi 多播锁：Android 默认过滤 UDP 多播包，必须获取锁才能接收 */
    private var multicastLock: WifiManager.MulticastLock? = null

    /** 当前活跃的进度事件流（用于 copyM3u8WithSegments 期间推送进度） */
    private var copyProgressSink: EventChannel.EventSink? = null

    /** BLE 广播回调：startAdvertising 时创建，stopAdvertising 时复用以避免 callback cannot be null */
    private var bleAdvertiseCallback: android.bluetooth.le.AdvertiseCallback? = null

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
        srcPath: String,
        mimeType: String = "video/*"
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
            tree.createFile(mimeType, finalName)
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
                                resetProgressState()
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
                        val mimeType = call.argument<String>("mimeType") ?: "video/*"
                        if (treeUri == null || fileName == null || srcPath == null) {
                            result.error("ARG_ERROR", "treeUri / fileName / srcPath 不能为空", null)
                            return@setMethodCallHandler
                        }
                        // 写入涉及 I/O，丢到后台线程避免阻塞 UI
                        Thread {
                            try {
                                val written = writeFileToSafTree(treeUri, fileName, srcPath, mimeType)
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

                    // v1.6.55+ 新增：弹出视频播放器选择器
                    // 不依赖实际文件，而是用 ACTION_VIEW + video/* 列出所有能处理视频的 App
                    "showVideoPlayerChooser" -> {
                        try {
                            // 使用一个虚拟的 video/* intent 来查询所有能播放视频的 App
                            val probeIntent = Intent(Intent.ACTION_VIEW).apply {
                                type = "video/*"
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            val chooser = Intent.createChooser(probeIntent, "选择视频播放器").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(chooser)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.error("NO_HANDLER", "未找到可播放视频的应用", null)
                        } catch (e: Throwable) {
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }

                    // v1.6.57+ 新增：从 SAF 自定义目录中删除指定文件
                    // 参数：treeUri (SAF 目录 URI), fileName (要删除的文件名)
                    // 使用 DocumentFile API（与 writeFileToSafTree 一致），兼容性更好
                    // v1.6.58+ 修复：result 回调必须在主线程，否则 Flutter 端收不到结果
                    "deleteFileFromSafTree" -> {
                        val treeUriStr = call.argument<String>("treeUri")
                        val fileName = call.argument<String>("fileName")
                        if (treeUriStr == null || fileName == null) {
                            result.error("INVALID_ARGS", "treeUri 和 fileName 不能为空", null)
                        } else {
                            Thread {
                                try {
                                    val tree = DocumentFile.fromTreeUri(this@MainActivity, Uri.parse(treeUriStr))
                                    if (tree == null || !tree.exists()) {
                                        runOnUiThread {
                                            result.error("INVALID_URI", "SAF 目录不存在或已失效", null)
                                        }
                                        return@Thread
                                    }
                                    // 在目录中查找同名文件
                                    val targetFile = tree.findFile(fileName)
                                    if (targetFile != null && targetFile.exists()) {
                                        val deleted = targetFile.delete()
                                        if (deleted) {
                                            Log.i(TAG, "deleteFileFromSafTree: 已删除 $fileName")
                                            runOnUiThread { result.success(true) }
                                        } else {
                                            runOnUiThread {
                                                result.error("DELETE_FAILED", "删除 SAF 文件失败：$fileName", null)
                                            }
                                        }
                                    } else {
                                        // 文件不存在于 SAF 目录中，不算错误
                                        Log.i(TAG, "deleteFileFromSafTree: 文件不存在 $fileName")
                                        runOnUiThread { result.success(false) }
                                    }
                                } catch (e: Throwable) {
                                    Log.e(TAG, "deleteFileFromSafTree 异常", e)
                                    runOnUiThread {
                                        result.error("EXCEPTION", e.message ?: "unknown", null)
                                    }
                                }
                            }.start()
                        }
                    }

                    // v1.6.58+ 新增：获取 App 本体大小（APK 大小）
                    "getAppSize" -> {
                        try {
                            val appInfo = applicationContext.applicationInfo
                            val apkFile = File(appInfo.sourceDir)
                            val apkSize = if (apkFile.exists()) apkFile.length() else 0L
                            result.success(apkSize)
                        } catch (e: Throwable) {
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // 注册复制进度 EventChannel（用于向 Dart 端推送实时进度）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, copyProgressChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    copyProgressSink = events
                    Log.i(TAG, "copy_progress: Dart 端开始监听进度")
                }
                override fun onCancel(arguments: Any?) {
                    copyProgressSink = null
                    Log.i(TAG, "copy_progress: Dart 端停止监听进度")
                }
            })

        // 注册前台服务控制通道（用于转换保活）
        val foregroundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, foregroundServiceChannelName)

        // v1.6.56+ 修复：注册通知栏"停止"按钮的取消回调
        // 当用户在通知栏点击"停止"时，Kotlin 端通过此回调通知 Flutter 端取消 FFmpeg
        ConvertForegroundService.setOnCancelRequestedListener {
            Log.i(TAG, "通知栏停止按钮被点击，通知 Flutter 端取消转换")
            foregroundChannel.invokeMethod("onCancelRequested", null)
        }

        foregroundChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService" -> {
                        val title = call.argument<String>("title") ?: "视频转换中…"
                        val content = call.argument<String>("content") ?: "正在转换"
                        try {
                            ConvertForegroundService.start(this, title, content)
                            Log.i(TAG, "前台服务已请求启动: $title - $content")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "启动前台服务失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", e.stackTraceToString())
                        }
                    }
                    "updateForegroundService" -> {
                        val title = call.argument<String>("title") ?: "视频转换中…"
                        val content = call.argument<String>("content") ?: ""
                        val progress = call.argument<Int>("progress") ?: 0
                        val subtext = call.argument<String>("subtext") ?: ""
                        try {
                            ConvertForegroundService.update(this, title, content, progress, subtext)
                        } catch (e: Throwable) {
                            Log.w(TAG, "更新前台服务失败: ${e.message}")
                        }
                        result.success(true)
                    }
                    "stopForegroundService" -> {
                        try {
                            ConvertForegroundService.stop(this)
                            Log.i(TAG, "前台服务已请求停止")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "停止前台服务失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", e.stackTraceToString())
                        }
                    }
                    // WebSocket保活前台服务：启动
                    "startWsForegroundService" -> {
                        val content = call.argument<String>("content") ?: "设备连接保持中"
                        try {
                            WebSocketForegroundService.start(this, content)
                            Log.i(TAG, "WebSocket保活前台服务已请求启动: $content")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "启动WebSocket保活前台服务失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", e.stackTraceToString())
                        }
                    }
                    // WebSocket保活前台服务：停止
                    "stopWsForegroundService" -> {
                        try {
                            WebSocketForegroundService.stop(this)
                            Log.i(TAG, "WebSocket保活前台服务已请求停止")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "停止WebSocket保活前台服务失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", e.stackTraceToString())
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册编解码器检测通道（用于检测设备硬件编码能力）
        // 通过 Android MediaCodecList API 遍历设备编解码器，
        // 检查是否存在支持 H.264 编码的硬件编码器
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, codecDetectorChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkH264Encoder" -> {
                        try {
                            val hasEncoder = checkH264HardwareEncoder()
                            Log.i(TAG, "checkH264Encoder: 设备H.264硬件编码器=$hasEncoder")
                            result.success(hasEncoder)
                        } catch (e: Throwable) {
                            Log.e(TAG, "checkH264Encoder 检测失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    // 获取设备芯片信息（芯片型号、内核数、CPU频率等）
                    "getCpuInfo" -> {
                        try {
                            val cpuInfo = getCpuInfo()
                            Log.i(TAG, "getCpuInfo: $cpuInfo")
                            result.success(cpuInfo)
                        } catch (e: Throwable) {
                            Log.e(TAG, "getCpuInfo 检测失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // v1.35.0+ 注册指纹检测通道（用于设备检修工具中的指纹功能检测）
        // 通过 Android FingerprintManager API 获取指纹硬件信息及已注册指纹状态
        val fingerprintChannelName = "com.example.toolapp/fingerprint"
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fingerprintChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFingerprintInfo" -> {
                        try {
                            val info = getFingerprintInfo()
                            Log.i(TAG, "getFingerprintInfo: $info")
                            result.success(info)
                        } catch (e: Throwable) {
                            Log.e(TAG, "getFingerprintInfo 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    "getEnrolledFingerprints" -> {
                        try {
                            val count = getEnrolledFingerprints()
                            Log.i(TAG, "getEnrolledFingerprints: $count")
                            result.success(count)
                        } catch (e: Throwable) {
                            Log.e(TAG, "getEnrolledFingerprints 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    "captureFingerprintData" -> {
                        try {
                            val data = captureFingerprintData()
                            Log.i(TAG, "captureFingerprintData: 数据大小=${data.size}")
                            result.success(data)
                        } catch (e: Throwable) {
                            Log.e(TAG, "captureFingerprintData 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    "getSdkVersion" -> {
                        try {
                            result.success(Build.VERSION.SDK_INT)
                        } catch (e: Throwable) {
                            Log.e(TAG, "getSdkVersion 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    "getDeviceModel" -> {
                        try {
                            result.success(Build.MODEL)
                        } catch (e: Throwable) {
                            Log.e(TAG, "getDeviceModel 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册设备信息通道（v1.51.2+ 提供设备详细硬件信息）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.toolapp/device_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTotalMemory" -> {
                        try {
                            val actManager = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                            val memInfo = android.app.ActivityManager.MemoryInfo()
                            actManager.getMemoryInfo(memInfo)
                            val totalMemMB = (memInfo.totalMem / (1024 * 1024)).toInt()
                            result.success(totalMemMB)
                        } catch (e: Exception) {
                            Log.e(TAG, "getTotalMemory 失败", e)
                            result.success(null)
                        }
                    }
                    "getTotalStorage" -> {
                        try {
                            val stat = android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path)
                            val totalBytes = stat.blockCountLong * stat.blockSizeLong
                            val totalMB = (totalBytes / (1024 * 1024)).toInt()
                            result.success(totalMB)
                        } catch (e: Exception) {
                            Log.e(TAG, "getTotalStorage 失败", e)
                            result.success(null)
                        }
                    }
                    "getCpuCores" -> {
                        try {
                            val cores = Runtime.getRuntime().availableProcessors()
                            result.success(cores)
                        } catch (e: Exception) {
                            Log.e(TAG, "getCpuCores 失败", e)
                            result.success(null)
                        }
                    }
                    "getScreenInches" -> {
                        try {
                            val metrics = resources.displayMetrics
                            val widthInches = metrics.widthPixels / (metrics.xdpi.coerceAtLeast(1f))
                            val heightInches = metrics.heightPixels / (metrics.ydpi.coerceAtLeast(1f))
                            val diagonal = Math.sqrt(
                                (widthInches * widthInches + heightInches * heightInches).toDouble()
                            )
                            result.success(diagonal)
                        } catch (e: Exception) {
                            Log.e(TAG, "getScreenInches 失败", e)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册 WiFi 辅助通道（联机掷骰子用）
        // 提供 MulticastLock 获取/释放（Android 默认过滤 UDP 多播包）
        // 提供 WiFi SSID 获取（显示当前连接的网络名称）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 获取 WiFi 多播锁（UDP 广播/多播接收必须）
                    "acquireMulticastLock" -> {
                        try {
                            if (multicastLock == null) {
                                val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                                multicastLock = wifiManager.createMulticastLock("toolapp_online_dice")
                                multicastLock?.setReferenceCounted(false)
                            }
                            multicastLock?.acquire()
                            Log.i(TAG, "MulticastLock 已获取")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "获取 MulticastLock 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    // 释放 WiFi 多播锁
                    "releaseMulticastLock" -> {
                        try {
                            multicastLock?.release()
                            Log.i(TAG, "MulticastLock 已释放")
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "释放 MulticastLock 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    // 获取当前 WiFi SSID（网络名称）
                    "getWifiSsid" -> {
                        try {
                            val ssid = getWifiSsid()
                            Log.i(TAG, "getWifiSsid: $ssid")
                            result.success(ssid)
                        } catch (e: Throwable) {
                            Log.e(TAG, "获取 WiFi SSID 失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册 BLE 外设模式通道（模拟 BLE 从机广播）
        val blePeripheralChannel = "com.example.toolapp/ble_peripheral"
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, blePeripheralChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        val name = call.argument<String>("name") ?: "ToolApp BLE"
                        val serviceUuids = call.argument<List<String>>("serviceUuids") ?: emptyList()
                        val includeDeviceName = call.argument<Boolean>("includeDeviceName") ?: true
                        try {
                            val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                            if (adapter == null) {
                                result.error("NO_BT", "设备不支持蓝牙", null)
                                return@setMethodCallHandler
                            }
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                                val advertiser = adapter.bluetoothLeAdvertiser
                                if (advertiser == null) {
                                    result.error("NO_LE", "设备不支持 BLE 外设模式", null)
                                    return@setMethodCallHandler
                                }
                                val settings = android.bluetooth.le.AdvertiseSettings.Builder()
                                    .setAdvertiseMode(android.bluetooth.le.AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                                    .setTxPowerLevel(android.bluetooth.le.AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                                    .setConnectable(true)
                                    .build()
                                val dataBuilder = android.bluetooth.le.AdvertiseData.Builder()
                                    .setIncludeDeviceName(includeDeviceName)
                                for (uuid in serviceUuids) {
                                    try {
                                        dataBuilder.addServiceUuid(android.os.ParcelUuid.fromString(uuid))
                                    } catch (_: Throwable) {}
                                }
                                advertiser.startAdvertising(settings, dataBuilder.build(),
                                    object : android.bluetooth.le.AdvertiseCallback() {
                                        override fun onStartSuccess(settingsInEffect: android.bluetooth.le.AdvertiseSettings?) {
                                            Log.i(TAG, "BLE 外设广播启动成功")
                                            result.success(true)
                                        }
                                        override fun onStartFailure(errorCode: Int) {
                                            Log.e(TAG, "BLE 外设广播启动失败: errorCode=$errorCode")
                                            bleAdvertiseCallback = null
                                            result.error("ADV_FAIL", "广播启动失败: $errorCode", null)
                                        }
                                    }.also { bleAdvertiseCallback = it }
                                )
                            } else {
                                result.error("API_LOW", "Android 5.0+ 才支持 BLE 外设模式", null)
                            }
                        } catch (e: Throwable) {
                            Log.e(TAG, "启动 BLE 外设广播异常", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    "stopAdvertising" -> {
                        try {
                            val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                            if (adapter != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                                val cb = bleAdvertiseCallback
                                if (cb != null) {
                                    adapter.bluetoothLeAdvertiser?.stopAdvertising(cb)
                                    bleAdvertiseCallback = null
                                }
                            }
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.e(TAG, "停止 BLE 外设广播异常", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册 Android Profiler 通道：CPU/内存/网络/电量实时监控
        val profilerHelper = ProfilerHelper(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.toolapp/profiler")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCpuInfo" -> {
                        try { result.success(profilerHelper.getCpuInfo()) }
                        catch (e: Exception) { result.error("CPU_ERROR", e.message, null) }
                    }
                    "getMemoryInfo" -> {
                        try { result.success(profilerHelper.getMemoryInfo()) }
                        catch (e: Exception) { result.error("MEMORY_ERROR", e.message, null) }
                    }
                    "getNetworkInfo" -> {
                        try { result.success(profilerHelper.getNetworkInfo()) }
                        catch (e: Exception) { result.error("NETWORK_ERROR", e.message, null) }
                    }
                    "getBatteryInfo" -> {
                        try { result.success(profilerHelper.getBatteryInfo()) }
                        catch (e: Exception) { result.error("BATTERY_ERROR", e.message, null) }
                    }
                    "getProcessList" -> {
                        try { result.success(profilerHelper.getProcessList()) }
                        catch (e: Exception) { result.error("PROCESS_ERROR", e.message, null) }
                    }
                    "getAppBatteryUsage" -> {
                        try { result.success(profilerHelper.getAppBatteryUsage()) }
                        catch (e: Exception) { result.error("BATTERY_USAGE_ERROR", e.message, null) }
                    }
                    "isUsageStatsGranted" -> {
                        result.success(profilerHelper.isUsageStatsGranted())
                    }
                    "openUsageStatsSettings" -> {
                        try {
                            profilerHelper.openUsageStatsSettings()
                            result.success(true)
                        } catch (e: Exception) { result.error("SETTINGS_ERROR", e.message, null) }
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

        // #region debug-point 1
        // v1.6.48+ 调试日志：打印复制前的状态
        Log.i(TAG, "[DEBUG] copyM3u8WithSegments: m3u8Rel='$m3u8Rel', destDir='${destDir.absolutePath}'")
        // #endregion

        // 2. 多候选启发式：依次尝试不同命名规则的同名 segments 文件夹
        //
        // 实际场景的命名约定（按命中概率排序）：
        //   a) "<M3U8文件名>.m3u8_contents" — 一些视频下载工具/网盘客户端的命名规则
        //      例：video1.m3u8 -> video1.m3u8_contents/
        //   b) "<M3U8文件名>（去后缀）" — 通用约定
        //      例：video1.m3u8 -> video1/
        //   c) "<M3U8完整文件名>" — 极少见但无副作用
        //   d) 从 M3U8 内部 segment refs 第一段提取的父目录 — 兜底
        //
        // v1.6.46+ 修复：m3u8BaseName 是相对路径前缀（如 "subdir"），
        // 不是文件夹名的一部分。启发式搜索的文件夹名应该只基于 m3u8FileName。
        val m3u8FileName = File(m3u8Rel).name
        val m3u8Stem = m3u8FileName.substringBeforeLast('.', m3u8FileName)

        val candidates = listOf(
            // a) <M3U8文件名>.m3u8_contents（实测最常见）
            "${m3u8FileName}.m3u8_contents",
            // b) <M3U8文件名>（去 .m3u8 后缀）
            m3u8Stem,
            // c) <M3U8完整文件名>（极少见但尝试一下）
            m3u8FileName,
        )

        // #region debug-point 2
        Log.i(TAG, "[DEBUG] 启发式候选文件夹: $candidates")
        // #endregion

        for (folderName in candidates) {
            val copied = tryCopyHeuristicFolder(treeUriOrPath, folderName, destDir)
            if (copied > 0) {
                count += copied
                Log.i(TAG, "copyM3u8WithSegments: 启发式命中 '$folderName'，复制 $copied 个文件")
                // #region debug-point 3
                Log.i(TAG, "[DEBUG] 成功复制了 $copied 个文件到 ${destDir.absolutePath}")
                // #endregion
                return count
            }
        }

        // 3. 上面启发式都失败 → 解析 M3U8 拿到 segment refs，从第一段提取候选文件夹名
        val parsedFirstSeg = firstSegmentFolderFromM3u8(destDir, m3u8Rel)
        if (parsedFirstSeg != null && parsedFirstSeg !in candidates) {
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
                        val fileSize = outFile.outputStream().use { output -> input.copyTo(output) }
                        totalCopiedFiles++
                        totalCopiedBytes += fileSize
                        reportProgress()
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
                val fileSize = sourceFile.inputStream().use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
                totalCopiedFiles++
                totalCopiedBytes += fileSize
                reportProgress()
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
    // 进度上报辅助
    // ----------------------------------------------------------------------

    /** 累计已复制文件数（由 copy 函数更新，reportProgress 读取） */
    private var totalCopiedFiles = 0
    /** 累计已复制字节数（由 copy 函数更新，reportProgress 读取） */
    private var totalCopiedBytes = 0L
    /** 上次上报进度后的已复制文件数，用于节流（每 10 个文件或每 5MB 上报一次） */
    private var lastReportedFileCount = 0
    private var lastReportedByteCount = 0L

    /** 上报进度到 Dart 端（读取累计值，节流后推送） */
    private fun reportProgress(force: Boolean = false) {
        val sink = copyProgressSink ?: return
        // 节流：每 10 个文件或累计 5MB 才上报一次，避免 EventChannel 过载
        if (!force &&
            totalCopiedFiles - lastReportedFileCount < 10 &&
            totalCopiedBytes - lastReportedByteCount < 5 * 1024 * 1024
        ) {
            return
        }
        lastReportedFileCount = totalCopiedFiles
        lastReportedByteCount = totalCopiedBytes
        try {
            runOnUiThread {
                sink.success(mapOf(
                    "fileCount" to totalCopiedFiles,
                    "byteCount" to totalCopiedBytes
                ))
            }
        } catch (e: Throwable) {
            Log.w(TAG, "reportProgress 失败: ${e.message}")
        }
    }

    /** 重置进度上报状态 */
    private fun resetProgressState() {
        totalCopiedFiles = 0
        totalCopiedBytes = 0L
        lastReportedFileCount = 0
        lastReportedByteCount = 0L
    }

    // ----------------------------------------------------------------------
    // SAF 分支
    // ----------------------------------------------------------------------

    private fun copyDirRecursiveSaf(source: DocumentFile, dest: File): Int {
        var count = 0
        if (!dest.exists()) dest.mkdirs()
        
        // v1.6.45+ 优化：在 listFiles() 前先强制上报一次进度，避免 SAF 扫描期间显示"已复制0"
        reportProgress(force = true)
        
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
        
        // v1.6.44+ 优化：分离文件和文件夹，先并行复制文件，再递归处理子目录
        val files = mutableListOf<DocumentFile>()
        val dirs = mutableListOf<DocumentFile>()
        for (file in children) {
            if (file.isDirectory) {
                dirs.add(file)
            } else if (file.isFile) {
                files.add(file)
            }
        }
        
        // 并行复制文件（使用 Java 原生线程池，最多 4 个线程同时复制）
        val executor = java.util.concurrent.Executors.newFixedThreadPool(4)
        val futures = mutableListOf<java.util.concurrent.Future<*>>()
        
        for (file in files) {
            futures.add(executor.submit {
                try {
                    val name = file.name ?: return@submit
                    val outFile = File(dest, name)
                    val fileSize = copyFileFastSaf(file, outFile)
                    if (fileSize > 0) {
                        synchronized(this@MainActivity) {
                            count++
                            totalCopiedFiles++
                            totalCopiedBytes += fileSize
                            reportProgress()
                        }
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "SAF 复制失败: ${file.uri} -> $dest/${file.name}: ${e.message}")
                }
            })
        }
        
        // 等待所有文件复制完成
        for (future in futures) {
            try {
                future.get()
            } catch (e: java.util.concurrent.ExecutionException) {
                Log.w(TAG, "复制任务异常: ${e.cause?.message}")
            }
        }
        executor.shutdown()
        
        // 串行复制子目录（避免过度并发导致内存溢出）
        for (dir in dirs) {
            val name = dir.name ?: continue
            count += copyDirRecursiveSaf(dir, File(dest, name))
        }
        
        return count
    }
    
    /**
     * v1.6.44+ 新增：快速复制单个 SAF 文件
     * 
     * 优先使用 FileChannel.transferTo 零拷贝传输，
     * 如果不可用则回退到大缓冲区流复制（1MB buffer）
     */
    private fun copyFileFastSaf(sourceFile: DocumentFile, outFile: File): Long {
        return try {
            // 尝试使用 FileDescriptor 零拷贝传输
            contentResolver.openFileDescriptor(sourceFile.uri, "r")?.use { pfd ->
                val inputChannel = java.io.FileInputStream(pfd.fileDescriptor).channel
                val outputChannel = java.io.FileOutputStream(outFile).channel
                
                val size = inputChannel.size()
                var position = 0L
                var remaining = size
                
                // transferTo 在 Android 上对某些 SAF URI 可能不支持
                // 所以使用带大缓冲区的循环
                while (remaining > 0) {
                    val transferred = inputChannel.transferTo(position, minOf(remaining, 1024 * 1024), outputChannel)
                    if (transferred <= 0) break
                    position += transferred
                    remaining -= transferred
                }
                
                inputChannel.close()
                outputChannel.close()
                size
            } ?: run {
                // 回退到大缓冲区流复制
                copyWithLargeBuffer(sourceFile, outFile)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "零拷贝复制失败，回退到流复制: ${e.message}")
            copyWithLargeBuffer(sourceFile, outFile)
        }
    }
    
    /**
     * 使用 1MB 大缓冲区进行流复制（比默认 8KB 快很多）
     */
    private fun copyWithLargeBuffer(sourceFile: DocumentFile, outFile: File): Long {
        contentResolver.openInputStream(sourceFile.uri)?.use { input ->
            val buffer = ByteArray(1024 * 1024) // 1MB 缓冲区
            var totalRead = 0L
            outFile.outputStream().use { output ->
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    totalRead += read
                }
            }
            return totalRead
        }
        return 0
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

    // ----------------------------------------------------------------------
    // 编解码器检测
    // ----------------------------------------------------------------------

    /**
     * 检测设备是否支持 H.264 硬件编码器。
     *
     * 通过 Android MediaCodecList API 遍历设备所有编解码器，
     * 检查是否存在支持 "video/avc"（H.264）类型的编码器。
     *
     * 这是 Android 官方 API，检测结果真实可靠：
     *   - MediaCodecList 是 Android 系统提供的标准 API
     *   - 它直接查询系统底层编解码器注册表
     *   - 只有设备真正拥有硬件编码芯片时才会返回 true
     *
     * @return true 表示设备支持 H.264 硬件编码
     */
    private fun checkH264HardwareEncoder(): Boolean {
        // H.264 在 Android 中的 MIME 类型是 "video/avc"
        val targetMimeType = "video/avc"
        val codecCount = MediaCodecList.getCodecCount()

        for (i in 0 until codecCount) {
            val codecInfo = MediaCodecList.getCodecInfoAt(i)
            // 只关注编码器（isEncoder == true），忽略解码器
            if (!codecInfo.isEncoder) continue

            val supportedTypes = codecInfo.supportedTypes
            for (type in supportedTypes) {
                if (type.equals(targetMimeType, ignoreCase = true)) {
                    Log.i(TAG, "checkH264HardwareEncoder: 找到 H.264 编码器 - ${codecInfo.name}")
                    return true
                }
            }
        }

        Log.i(TAG, "checkH264HardwareEncoder: 未找到 H.264 硬件编码器")
        return false
    }

    /**
     * 获取设备芯片（CPU）信息。
     *
     * 综合使用以下 Android 标准 API 获取芯片信息：
     *   1. Build 类：获取芯片型号、硬件平台、设备制造商等
     *   2. /proc/cpuinfo：获取 CPU 架构、硬件名称、核心实现等底层信息
     *   3. Runtime.getRuntime().availableProcessors()：获取可用处理器核心数
     *   4. /sys/devices/system/cpu/cpu0/cpufreq/：获取 CPU 频率范围
     *
     * 这些都是 Android/Linux 系统标准接口，成熟稳定，所有 Android 设备均支持。
     *
     * @return Map 包含芯片详细信息
     */
    private fun getCpuInfo(): Map<String, String> {
        val info = mutableMapOf<String, String>()

        // 通过 Build 类获取芯片型号和硬件平台信息
        // Build.HARDWARE：硬件平台名称（如 qcom、mt6789、exynos5等）
        // Build.SOC_MODEL：SoC 型号名称（Android 12+，如 Snapdragon 888、Dimensity 8000）
        // Build.SOC_MANUFACTURER：SoC 制造商（Android 12+，如 Qualcomm、MediaTek）
        info["硬件平台"] = Build.HARDWARE ?: "未知"
        info["SoC型号"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL ?: "未知"
        } else {
            "未知（需 Android 12+）"
        }
        info["SoC制造商"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER ?: "未知"
        } else {
            "未知（需 Android 12+）"
        }
        // Build.CPU_ABI：CPU 指令集架构（如 arm64-v8a、armeabi-v7a）
        info["CPU架构"] = Build.CPU_ABI ?: "未知"
        info["设备型号"] = Build.MODEL ?: "未知"
        info["设备制造商"] = Build.MANUFACTURER ?: "未知"

        // 通过 Runtime 获取可用处理器核心数
        // 这是最准确的核心数获取方式，返回 JVM 可用的处理器数
        val coreCount = Runtime.getRuntime().availableProcessors()
        info["CPU核心数"] = coreCount.toString()

        // 通过 /proc/cpuinfo 获取更详细的 CPU 信息
        // /proc/cpuinfo 是 Linux 内核标准接口，所有 Android 设备都有
        // 内容包括：Processor（处理器编号）、Hardware（硬件名称）、
        // CPU implementer/part/variant/revision（ARM 核心实现信息）等
        try {
            val cpuinfoFile = java.io.File("/proc/cpuinfo")
            if (cpuinfoFile.exists()) {
                val cpuinfo = cpuinfoFile.readText()
                // 提取 Hardware 字段（通常包含芯片平台名称）
                val hardwareMatch = Regex("Hardware\\s*:\\s*(.+)").find(cpuinfo)
                if (hardwareMatch != null) {
                    info["CPU硬件名称"] = hardwareMatch.groupValues[1].trim()
                }
                // 提取 CPU part 字段（ARM 核心型号标识）
                val cpuPartMatch = Regex("CPU part\\s*:\\s*(.+)").find(cpuinfo)
                if (cpuPartMatch != null) {
                    info["CPU核心型号"] = cpuPartMatch.groupValues[1].trim()
                }
                // 统计逻辑核心数（通过 "processor" 关键字计数）
                val processorCount = Regex("^processor\\s*:", RegexOption.MULTILINE)
                    .findAll(cpuinfo).count()
                if (processorCount > 0) {
                    info["逻辑核心数"] = processorCount.toString()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "读取 /proc/cpuinfo 失败：${e.message}")
        }

        // 通过 /sys 文件系统获取 CPU 频率范围
        // cpufreq 是 Linux CPU 频率调节子系统的标准接口
        try {
            val maxFreqFile = java.io.File("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
            val minFreqFile = java.io.File("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq")
            if (maxFreqFile.exists() && minFreqFile.exists()) {
                val maxFreq = maxFreqFile.readText().trim().toLongOrNull() ?: 0
                val minFreq = minFreqFile.readText().trim().toLongOrNull() ?: 0
                if (maxFreq > 0) {
                    // 频率单位是 kHz，转换为 MHz 显示
                    info["最大频率"] = "${maxFreq / 1000} MHz"
                    info["最小频率"] = "${minFreq / 1000} MHz"
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "读取 CPU 频率失败：${e.message}")
        }

        return info
    }

    /**
     * v1.35.0+ 获取指纹硬件信息
     * 通过 Android FingerprintManager API 查询设备指纹传感器状态
     */
    private fun getFingerprintInfo(): Map<String, Any> {
        val info = mutableMapOf<String, Any>()
        info["sdkVersion"] = Build.VERSION.SDK_INT
        info["manufacturer"] = Build.MANUFACTURER
        info["model"] = Build.MODEL

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val fingerprintManager = getSystemService(android.hardware.fingerprint.FingerprintManager::class.java)
                info["hasHardware"] = fingerprintManager?.isHardwareDetected ?: false
                info["hasEnrolledFingerprints"] = fingerprintManager?.hasEnrolledFingerprints() ?: false

                // 传感器类型推测（Android 标准API无法直接获取传感器类型，通过硬件信息推测）
                val hasHardware = fingerprintManager?.isHardwareDetected ?: false
                info["sensorType"] = when {
                    hasHardware && Build.MANUFACTURER.lowercase().contains("samsung") -> "超声波"
                    hasHardware && Build.MANUFACTURER.lowercase().contains("xiaomi") -> "光学"
                    hasHardware -> "电容式（推测）"
                    else -> "无"
                }
            } else {
                info["hasHardware"] = false
                info["sensorType"] = "不支持（SDK < 23）"
            }
        } catch (e: Exception) {
            Log.e(TAG, "获取指纹硬件信息失败", e)
            info["error"] = e.message ?: "unknown"
        }

        return info
    }

    /**
     * v1.35.0+ 获取已注册的指纹数量
     * 注意：Android 9+ 不再暴露具体数量，只返回是否已注册
     */
    private fun getEnrolledFingerprints(): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val fingerprintManager = getSystemService(android.hardware.fingerprint.FingerprintManager::class.java)
                if (fingerprintManager?.hasEnrolledFingerprints() == true) {
                    1 // 至少注册了1个指纹
                } else {
                    0
                }
            } else {
                0
            }
        } catch (e: Exception) {
            Log.e(TAG, "获取指纹注册数量失败", e)
            0
        }
    }

    /**
     * v1.35.0+ 捕获指纹相关数据（供学习研究用）
     * 采集的是指纹硬件元数据和哈希特征值，不采集原始指纹图像
     * 本功能仅用于个人学习研究，不传播推广，不涉及违法犯罪
     */
    private fun captureFingerprintData(): Map<String, Any> {
        val data = mutableMapOf<String, Any>()

        try {
            // 获取指纹硬件基本信息
            val hardwareInfo = getFingerprintInfo()
            data.putAll(hardwareInfo)

            // 添加设备标识信息（脱敏处理）
            data["deviceFingerprint"] = Build.FINGERPRINT.takeLast(16) // 只取后16位
            data["board"] = Build.BOARD
            data["bootloader"] = Build.BOOTLOADER
            data["brand"] = Build.BRAND
            data["device"] = Build.DEVICE
            data["display"] = Build.DISPLAY
            data["hardware"] = Build.HARDWARE
            data["product"] = Build.PRODUCT

            // 添加时间戳
            data["capturedAt"] = System.currentTimeMillis()

            // 添加安全相关参数（用于学习生物识别认证流程）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val keyguardManager = getSystemService(android.app.KeyguardManager::class.java)
                    data["isKeyguardSecure"] = keyguardManager?.isKeyguardSecure ?: false
                    data["isDeviceSecure"] = keyguardManager?.isDeviceSecure ?: false
                } catch (e: Exception) {
                    Log.w(TAG, "获取Keyguard信息失败: ${e.message}")
                }
            }

            Log.i(TAG, "指纹数据捕获完成（仅硬件元数据，不含原始指纹图像）")
        } catch (e: Exception) {
            Log.e(TAG, "捕获指纹数据失败", e)
            data["error"] = e.message ?: "unknown"
        }

        return data
    }

    /**
     * 获取当前 WiFi SSID（网络名称）
     *
     * Android 各版本获取 SSID 的方式不同：
     * - Android 12+：需要 ACCESS_FINE_LOCATION 权限，通过 WifiManager.getConnectionInfo() 获取
     * - Android 10-11：同上，但部分 ROM 可能返回 "<unknown ssid>"
     * - 无论如何，如果获取失败则返回空字符串
     */
    private fun getWifiSsid(): String {
        try {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            val wifiInfo: WifiInfo? = wifiManager.connectionInfo
            var ssid = wifiInfo?.ssid ?: ""
            // Android 返回的 SSID 带引号，如 "\"MyWiFi\""，去掉引号
            if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length >= 2) {
                ssid = ssid.substring(1, ssid.length - 1)
            }
            // "<unknown ssid>" 表示获取失败
            if (ssid == "<unknown ssid>" || ssid.isBlank()) {
                return ""
            }
            return ssid
        } catch (e: Throwable) {
            Log.e(TAG, "获取 WiFi SSID 失败", e)
            return ""
        }
    }
}
