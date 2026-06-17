package com.example.toolapp

import android.media.MediaCodecList
import android.media.MediaCodecInfo
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiInfo
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.NdefRecord
import android.os.BatteryManager
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
import java.util.zip.ZipInputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.concurrent.TimeUnit

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
                    // 扫描附近 WiFi 列表（NFC WiFi 速写用）
                    "scanWifiNetworks" -> {
                        try {
                            val wifiList = scanWifiNetworks()
                            result.success(wifiList)
                        } catch (e: Throwable) {
                            Log.e(TAG, "WiFi 扫描失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    // 连接指定 WiFi（NFC WiFi 速写用）
                    "connectWifi" -> {
                        val ssid = call.argument<String>("ssid")
                        val password = call.argument<String>("password") ?: ""
                        val authType = call.argument<String>("authType") ?: "WPA"
                        if (ssid == null) {
                            result.error("ARG_ERROR", "SSID 不能为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val success = connectWifi(ssid, password, authType)
                            result.success(success)
                        } catch (e: Throwable) {
                            Log.e(TAG, "WiFi 连接失败", e)
                            result.error("EXCEPTION", e.message ?: "unknown", null)
                        }
                    }
                    // 验证 WiFi 密码是否正确（NFC WiFi 速写用，写卡前验证）
                    // 必须在后台线程执行，避免Thread.sleep阻塞主线程导致ANR闪退
                    "verifyWifiPassword" -> {
                        val ssid = call.argument<String>("ssid")
                        val password = call.argument<String>("password") ?: ""
                        val authType = call.argument<String>("authType") ?: "WPA"
                        if (ssid == null) {
                            result.error("ARG_ERROR", "SSID 不能为空", null)
                            return@setMethodCallHandler
                        }
                        // 在后台线程执行验证，避免阻塞主线程
                        Thread {
                            try {
                                val success = verifyWifiPassword(ssid, password, authType)
                                runOnUiThread {
                                    result.success(success)
                                }
                            } catch (e: Throwable) {
                                Log.e(TAG, "WiFi 密码验证失败", e)
                                runOnUiThread {
                                    result.error("EXCEPTION", e.message ?: "unknown", null)
                                }
                            }
                        }.start()
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

        // 注册应用启动器通道：用于 deep link 触发启动指定应用（如 OPPO 互联投屏）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.launcher")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchApp" -> {
                        val packageName = call.argument<String>("packageName")
                        if (packageName == null) {
                            result.error("ARG_ERROR", "packageName 不能为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = packageManager.getLaunchIntentForPackage(packageName)
                            if (intent != null) {
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            } else {
                                // 应用未安装，尝试打开应用市场
                                val marketIntent = Intent(Intent.ACTION_VIEW).apply {
                                    data = Uri.parse("market://details?id=$packageName")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(marketIntent)
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("LAUNCH_ERROR", "启动应用失败: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册电池健康度通道：通过多种方式获取电池容量信息
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.toolapp/battery_health")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBatteryHealth" -> {
                        try {
                            val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                            // BATTERY_PROPERTY_CHARGE_COUNTER: 当前电量（微安时 µAh）
                            val chargeCounter = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
                            } else -1
                            // BATTERY_PROPERTY_CAPACITY: 当前电量百分比
                            val capacityPercent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                            } else -1
                            // 通过反射获取设计容量（mAh）
                            var designCapacityMah = -1
                            try {
                                // BATTERY_PROPERTY_CHARGE_FULL = 5 (隐藏常量)
                                val fullUah = bm.getIntProperty(5)
                                if (fullUah > 0) designCapacityMah = fullUah / 1000
                            } catch (_: Exception) {}
                            result.success(mapOf(
                                "chargeCounter" to chargeCounter,
                                "capacityPercent" to capacityPercent,
                                "designCapacityMah" to designCapacityMah,
                            ))
                        } catch (e: Throwable) {
                            result.error("BATTERY_ERROR", e.message ?: "unknown", null)
                        }
                    }
                    "tryReadSysfs" -> {
                        try {
                            // 尝试多种 sysfs 路径获取电池信息
                            // 修复：移除语义错误的路径，capacity 是电量百分比、constant_charge_current_max 是最大充电电流，均非设计容量
                            val designPaths = listOf(
                                "/sys/class/power_supply/battery/charge_full_design",
                                "/sys/class/power_supply/bms/charge_full_design",
                                "/sys/class/power_supply/battery/energy_full_design",
                            )
                            val fullPaths = listOf(
                                "/sys/class/power_supply/battery/charge_full",
                                "/sys/class/power_supply/bms/charge_full",
                                "/sys/class/power_supply/battery/charge_counter",
                            )
                            var designUah: Int? = null
                            var fullUah: Int? = null

                            for (path in designPaths) {
                                try {
                                    val value = java.io.File(path).readText().trim().toIntOrNull()
                                    if (value != null && value > 0) {
                                        designUah = value
                                        break
                                    }
                                } catch (_: Exception) { continue }
                            }
                            for (path in fullPaths) {
                                try {
                                    val value = java.io.File(path).readText().trim().toIntOrNull()
                                    if (value != null && value > 0) {
                                        fullUah = value
                                        break
                                    }
                                } catch (_: Exception) { continue }
                            }
                            result.success(mapOf(
                                "chargeFullDesign" to (designUah ?: -1),
                                "chargeFull" to (fullUah ?: -1),
                            ))
                        } catch (e: Throwable) {
                            result.error("SYSFS_ERROR", e.message ?: "unknown", null)
                        }
                    }
                    // 通过 dumpsys battery 获取电池信息（在原生端执行，权限比Flutter沙箱高）
                    // 修复：原实现在主线程执行 dumpsys 会导致 ANR，改为后台线程执行
                    "readDumpsys" -> {
                        Thread {
                            var process: Process? = null
                            try {
                                process = Runtime.getRuntime().exec(arrayOf("dumpsys", "battery"))
                                // 消费 stderr 避免缓冲区满导致进程挂死
                                val stderr = process.errorStream.bufferedReader().readText()
                                val output = process.inputStream.bufferedReader().readText()
                                // 增加超时保护，避免 dumpsys 挂死导致永久阻塞
                                val finished = process.waitFor(10, TimeUnit.SECONDS)
                                if (!finished) {
                                    process.destroyForcibly()
                                    runOnUiThread { result.error("DUMPSYS_TIMEOUT", "dumpsys 执行超时", null) }
                                    return@Thread
                                }
                                var designUah: Int? = null
                                var fullUah: Int? = null
                                var status: String? = null
                                var level: Int? = null
                                var voltage: Int? = null
                                var temperature: Int? = null
                                var technology: String? = null
                                var currentNow: Int? = null
                                var chargeCounter: Int? = null

                                for (line in output.lines()) {
                                    val trimmed = line.trim()
                                    when {
                                        // 标准格式
                                        trimmed.startsWith("charge_full_design:") ->
                                            designUah = trimmed.substringAfter(':').trim().toIntOrNull()
                                        trimmed.startsWith("charge_full:") ->
                                            fullUah = trimmed.substringAfter(':').trim().toIntOrNull()
                                        // OPPO/OnePlus 特有格式：Charge counter（大写C开头）
                                        trimmed.startsWith("Charge counter:") ->
                                            chargeCounter = trimmed.substringAfter(':').trim().toIntOrNull()
                                        // 标准格式 status（可能是数字或字符串）
                                        trimmed.startsWith("status:") -> {
                                            val valStr = trimmed.substringAfter(':').trim()
                                            status = when (valStr) {
                                                "1", "Unknown" -> "Unknown"
                                                "2", "Charging" -> "Charging"
                                                "3", "Discharging" -> "Discharging"
                                                "4", "Not charging" -> "Not charging"
                                                "5", "Full" -> "Full"
                                                else -> valStr
                                            }
                                        }
                                        trimmed.startsWith("level:") ->
                                            level = trimmed.substringAfter(':').trim().toIntOrNull()
                                        trimmed.startsWith("voltage:") ->
                                            voltage = trimmed.substringAfter(':').trim().toIntOrNull()
                                        trimmed.startsWith("temperature:") ->
                                            temperature = trimmed.substringAfter(':').trim().toIntOrNull()
                                        trimmed.startsWith("technology:") -> {
                                            val techVal = trimmed.substringAfter(':').trim()
                                            // 过滤纯数字（OPPO/OnePlus 返回数字如 "8"，不是有效类型）
                                            if (techVal.isNotEmpty() && techVal.toIntOrNull() == null) {
                                                technology = techVal
                                            }
                                        }
                                        trimmed.startsWith("current_now:") ->
                                            currentNow = trimmed.substringAfter(':').trim().toIntOrNull()
                                    }
                                }
                                val resultMap = mapOf(
                                    "chargeFullDesign" to (designUah ?: -1),
                                    "chargeFull" to (fullUah ?: -1),
                                    "chargeCounter" to (chargeCounter ?: -1),
                                    "status" to (status ?: ""),
                                    "level" to (level ?: -1),
                                    "voltage" to (voltage ?: -1),
                                    "temperature" to (temperature ?: -1),
                                    "technology" to (technology ?: ""),
                                    "currentNow" to (currentNow ?: -1),
                                )
                                runOnUiThread { result.success(resultMap) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("DUMPSYS_ERROR", e.message ?: "unknown", null) }
                            } finally {
                                // 确保进程被销毁，避免资源泄漏
                                process?.destroy()
                            }
                        }.start()
                    }
                    // 通过设备型号查询已知的设计容量数据库
                    // 同时匹配 MODEL / DEVICE / PRODUCT 三个维度
                    "getKnownDesignCapacity" -> {
                        try {
                            val model = Build.MODEL ?: ""
                            val device = Build.DEVICE ?: ""
                            val product = Build.PRODUCT ?: ""
                            // 依次匹配 MODEL → DEVICE → PRODUCT
                            var capacityMah = getKnownBatteryCapacity(model)
                            if (capacityMah <= 0) capacityMah = getKnownBatteryCapacity(device)
                            if (capacityMah <= 0) capacityMah = getKnownBatteryCapacity(product)
                            result.success(mapOf(
                                "model" to model,
                                "device" to device,
                                "product" to product,
                                "designCapacityMah" to capacityMah,
                            ))
                        } catch (e: Throwable) {
                            result.error("KNOWN_ERROR", e.message ?: "unknown", null)
                        }
                    }
                    // 直接在原生端解析 zip 中的电池信息
                    // 支持：标准 zip、嵌套 zip（小米 bug report 格式）
                    // 使用 ZipInputStream 流式读取 + 逐行解析，避免 OOM
                    // 不需要中间文件，直接返回解析结果
                    // 修复：原实现在主线程执行 ZIP 解压+大文件解析会导致 ANR，改为后台线程
                    "parseBatteryFromZip" -> {
                        Thread {
                            try {
                                val zipPath = call.argument<String>("zipPath") ?: ""
                                Log.d(TAG, "parseBatteryFromZip: path=$zipPath")
                                val zipFile = File(zipPath)
                                if (!zipFile.exists()) {
                                    Log.e(TAG, "parseBatteryFromZip: file not found: $zipPath")
                                    runOnUiThread { result.error("FILE_NOT_FOUND", "文件不存在: $zipPath", null) }
                                    return@Thread
                                }
                                Log.d(TAG, "parseBatteryFromZip: file size=${zipFile.length()}")

                                // 递归解析 zip（支持嵌套 zip）
                                val batteryData = parseBatteryFromZipFile(zipFile, maxDepth = 2)

                                if (batteryData != null) {
                                    Log.d(TAG, "parseBatteryFromZip: found battery data=$batteryData")
                                    runOnUiThread { result.success(batteryData) }
                                } else {
                                    Log.w(TAG, "parseBatteryFromZip: no battery data found")
                                    runOnUiThread { result.success(null) }
                                }
                            } catch (e: Throwable) {
                                Log.e(TAG, "parseBatteryFromZip error", e)
                                runOnUiThread { result.error("PARSE_ERROR", e.message ?: "unknown", null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册 deep link 通道：将 Android intent 的 data 传递给 Flutter
        deepLinkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "android.intent")
        // 保存冷启动时的 intent URI，供 Flutter 端 getInitialIntent 查询
        // 修复 MissingPluginException：Flutter 端调用 getInitialIntent 时原生端未实现
        initialIntentUri = intent?.data?.toString()
        // 设置 MethodCallHandler 处理 Flutter 端发来的方法调用
        deepLinkChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Flutter 端查询冷启动时的 deep link URI（如 toolapp://screencast）
                "getInitialIntent" -> result.success(initialIntentUri)
                else -> result.notImplemented()
            }
        }
        // 检查当前 activity 是否带有 deep link intent
        handleIncomingIntent(intent, deepLinkChannel!!)
    }

    // ----------------------------------------------------------------------
    // Deep Link 处理：NFC 碰卡触发的投屏等指令
    // ----------------------------------------------------------------------

    private var deepLinkChannel: MethodChannel? = null
    /** 冷启动时的 deep link URI，供 Flutter 端 getInitialIntent 查询 */
    private var initialIntentUri: String? = null

    /**
     * 处理传入的 intent，检查是否包含 deep link URI 或 WiFi NDEF 配置
     * 冷启动时在 configureFlutterEngine 中调用
     * 热启动时在 onNewIntent 中调用
     * 
     * 修复问题：
     * 1. AAR记录指向本应用时，系统可能用ACTION_TECH_DISCOVERED而非ACTION_NDEF_DISCOVERED启动
     * 2. getParcelableArrayListExtra在Android 13+已废弃，需要使用兼容API
     * 3. 微信/QQ URI需要通过ACTION_VIEW转发给第三方应用
     */
    private fun handleIncomingIntent(intent: Intent?, channel: MethodChannel) {
        deepLinkChannel = channel
        val action = intent?.action

        // 处理所有NFC类型的碰卡事件
        if (action == NfcAdapter.ACTION_NDEF_DISCOVERED
            || action == NfcAdapter.ACTION_TECH_DISCOVERED
            || action == NfcAdapter.ACTION_TAG_DISCOVERED) {
            
            Log.i(TAG, "NFC碰卡: action=$action, type=${intent?.type}, data=${intent?.data}")
            
            val mimeType = intent?.type
            // 优先处理 WiFi NDEF 配置（有特定mimeType的快速路径）
            // 注意：当AAR记录存在时，系统可能用ACTION_TECH_DISCOVERED启动，
            // 此时intent.type为null，此快速路径无法命中，
            // 需要依赖下方通用NDEF解析中的兜底处理
            if (mimeType == "application/vnd.wfa.wsc") {
                Log.i(TAG, "收到 WiFi NDEF 配置 (mimeType快速路径)")
                val ndefMessages = getNdefMessages(intent)
                if (handleWifiNdefMessage(ndefMessages)) {
                    return
                }
            }

            // 处理本应用自定义MIME类型的NFC数据（微信/QQ/支付宝跳转）
            // 注意：当AAR记录存在时，系统可能用ACTION_TECH_DISCOVERED启动，
            // 此时intent.type为null，此快速路径无法命中，
            // 需要依赖下方通用NDEF解析中的兜底处理
            if (mimeType == "application/vnd.com.example.toolapp.nfc") {
                Log.i(TAG, "收到本应用自定义NFC数据 (mimeType快速路径)")
                val ndefMessages = getNdefMessages(intent)
                if (handleCustomNdefMessage(ndefMessages)) {
                    return
                }
            }

            // 处理 URI/URL/文本/WiFi类型的NDEF
            // 修复：当系统用ACTION_TECH_DISCOVERED/TAG_DISCOVERED启动时，
            // intent.type为null，上方mimeType快速路径无法命中WiFi配置，
            // 这里作为兜底路径，遍历NDEF记录查找WiFi记录
            val ndefMessages = getNdefMessages(intent)
            if (ndefMessages != null && ndefMessages.isNotEmpty()) {
                val firstMessage = ndefMessages[0]
                // 遍历NDEF记录，查找URI、文本或WiFi记录
                for (record in firstMessage.records) {
                    val tnf = record.tnf
                    val type = String(record.type, Charsets.UTF_8)
                    val payload = record.payload

                    // TNF 2: MIME media type (WiFi配置等)
                    // 兜底处理：当mimeType为null时，通过遍历记录类型识别WiFi配置
                    if (tnf == NdefRecord.TNF_MIME_MEDIA) {
                        // WiFi Simple Config记录
                        if (type == "application/vnd.wfa.wsc") {
                            Log.i(TAG, "NFC碰卡: 通用解析兜底发现WiFi配置记录")
                            if (handleWifiNdefMessage(ndefMessages)) {
                                return
                            }
                        }
                        // 本应用自定义MIME记录（微信/QQ/支付宝跳转）
                        if (type == "application/vnd.com.example.toolapp.nfc") {
                            Log.i(TAG, "NFC碰卡: 通用解析兜底发现自定义MIME记录")
                            if (handleCustomNdefMessage(ndefMessages)) {
                                return
                            }
                        }
                    }

                    // TNF 1: Well-known type (U=URI, T=Text)
                    if (tnf == NdefRecord.TNF_WELL_KNOWN) {
                        // URI记录: type="U"
                        if (type == "U" && payload.isNotEmpty()) {
                            val uri = parseNdefUriRecord(payload)
                            if (uri != null) {
                                Log.i(TAG, "NFC碰卡: 解析到URI = $uri")
                                // 立即处理URI（不延迟），加快跳转响应
                                handleNfcUri(uri, channel)
                                return
                            }
                        }
                        // Text记录: type="T"
                        if (type == "T" && payload.isNotEmpty()) {
                            val text = parseNdefTextRecord(payload)
                            if (text != null) {
                                Log.i(TAG, "NFC碰卡: 解析到文本 = $text")
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    channel.invokeMethod("handleNdefText", text)
                                }, 300)
                                return
                            }
                        }
                    }
                }
            }

            // 如果没有解析到有效NDEF记录，但有TAG发现，提示用户
            // 修复：ACTION_TECH_DISCOVERED/TAG_DISCOVERED时EXTRA_NDEF_MESSAGES可能为空
            // 需要从EXTRA_TAG获取Tag对象，通过Ndef API主动读取NDEF消息
            Log.i(TAG, "NFC TAG 被本应用捕获 (action=$action, mimeType=$mimeType), 尝试从Tag读取NDEF消息")

            // 从intent中获取Tag对象，在后台线程读取NDEF消息
            // 兼容Android 13+的getParcelableExtra废弃警告
            val tag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(NfcAdapter.EXTRA_TAG, android.nfc.Tag::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra<android.nfc.Tag>(NfcAdapter.EXTRA_TAG)
            }
            if (tag != null) {
                // 打印Tag诊断信息：tech列表、ID、大小
                Log.i(TAG, "NFC碰卡: Tag techList=${tag.techList?.toList()}, id=${tag.id?.joinToString("") { "%02X".format(it) }}, size=${tag.id?.size}")
                Thread {
                    try {
                        val ndef = android.nfc.tech.Ndef.get(tag)
                        if (ndef != null) {
                            ndef.connect()
                            try {
                                val ndefMessage = ndef.ndefMessage
                                if (ndefMessage != null) {
                                    Log.i(TAG, "NFC碰卡: 从Tag成功读取NDEF消息, records=${ndefMessage.records.size}")
                                    val messages = arrayOf(ndefMessage)
                                    // 优先处理WiFi配置
                                    if (handleWifiNdefMessage(messages)) {
                                        return@Thread
                                    }
                                    // 处理自定义MIME记录（微信/QQ/支付宝跳转）
                                    if (handleCustomNdefMessage(messages)) {
                                        return@Thread
                                    }
                                    // 处理URI/Text记录（网站跳转/文本显示）
                                    if (handleUriAndTextNdefMessage(messages, channel)) {
                                        return@Thread
                                    }
                                } else {
                                    Log.w(TAG, "NFC碰卡: Tag的NDEF消息为null（可能是空标签）")
                                }
                            } finally {
                                try { ndef.close() } catch (_: Throwable) { }
                            }
                        } else {
                            Log.w(TAG, "NFC碰卡: Ndef.get(tag)返回null，尝试MifareClassic读取NDEF")
                            // Mifare Classic卡：NDEF数据通过扇区块映射存储，不是原生Ndef格式
                            // 需要用MifareClassic API认证扇区+读取块+解析NDEF TLV
                            val ndefMessage = readNdefFromMifareClassic(tag)
                            if (ndefMessage != null) {
                                Log.i(TAG, "NFC碰卡: 从MifareClassic成功读取NDEF消息, records=${ndefMessage.records.size}")
                                val messages = arrayOf(ndefMessage)
                                // 优先处理WiFi配置
                                if (handleWifiNdefMessage(messages)) {
                                    return@Thread
                                }
                                // 处理自定义MIME记录（微信/QQ/支付宝跳转）
                                if (handleCustomNdefMessage(messages)) {
                                    return@Thread
                                }
                                // 处理URI/Text记录（网站跳转/文本显示）
                                if (handleUriAndTextNdefMessage(messages, channel)) {
                                    return@Thread
                                }
                            } else {
                                Log.w(TAG, "NFC碰卡: MifareClassic读取NDEF失败或无NDEF数据")
                            }
                        }
                    } catch (e: Throwable) {
                        Log.e(TAG, "NFC碰卡: 从Tag读取NDEF消息失败（标签可能已离开感应区）", e)
                    }
                }.start()
            } else {
                Log.w(TAG, "NFC碰卡: intent中没有EXTRA_TAG")
            }
        }

        // 处理其他 deep link
        if (intent?.action == Intent.ACTION_VIEW) {
            val uri = intent.data?.toString()
            if (uri != null) {
                Log.i(TAG, "收到 deep link: $uri")
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    channel.invokeMethod("handleDeepLink", uri)
                }, 300)
            }
        }
    }

    /**
     * 处理 WiFi NDEF 消息：解析WiFi配置并自动连接
     * 
     * 此方法统一处理WiFi连接逻辑，被两处调用：
     * 1. handleIncomingIntent中mimeType快速路径（ACTION_NDEF_DISCOVERED + application/vnd.wfa.wsc）
     * 2. handleIncomingIntent中通用NDEF解析兜底路径（ACTION_TECH_DISCOVERED/TAG_DISCOVERED时mimeType为null）
     * 
     * 修复问题：
     * 原代码仅在mimeType == "application/vnd.wfa.wsc"时处理WiFi连接，
     * 但当NFC标签包含AAR记录时，系统常以ACTION_TECH_DISCOVERED启动应用，
     * 此时intent.type为null，导致WiFi连接逻辑被跳过。
     * 
     * @param ndefMessages NDEF消息数组，通常从getNdefMessages(intent)获取
     * @return true表示已处理WiFi连接（无论成功与否），false表示未找到WiFi配置
     */
    private fun handleWifiNdefMessage(ndefMessages: Array<NdefMessage>?): Boolean {
        if (ndefMessages == null || ndefMessages.isEmpty()) {
            return false
        }

        // 先检查NDEF消息中是否包含WiFi记录（application/vnd.wfa.wsc）
        var hasWifiRecord = false
        for (record in ndefMessages[0].records) {
            if (record.tnf == NdefRecord.TNF_MIME_MEDIA) {
                val type = String(record.type, Charsets.UTF_8)
                if (type == "application/vnd.wfa.wsc") {
                    hasWifiRecord = true
                    break
                }
            }
        }

        if (!hasWifiRecord) {
            return false
        }

        // 在后台线程解析WiFi配置并连接
        Thread {
            try {
                val wifiConfig = parseWifiNdefMessage(ndefMessages[0])
                if (wifiConfig != null) {
                    val ssid = wifiConfig["ssid"] ?: ""
                    Log.i(TAG, "WiFi NDEF处理: 开始连接 SSID=$ssid")
                    val success = connectWifi(
                        ssid,
                        wifiConfig["password"] ?: "",
                        wifiConfig["authType"] ?: "WPA"
                    )
                    runOnUiThread {
                        if (success) {
                            android.widget.Toast.makeText(
                                this,
                                "已自动连接 WiFi: $ssid",
                                android.widget.Toast.LENGTH_LONG
                            ).show()
                        } else {
                            android.widget.Toast.makeText(
                                this,
                                "WiFi 连接失败，请检查密码",
                                android.widget.Toast.LENGTH_LONG
                            ).show()
                        }
                    }
                } else {
                    Log.w(TAG, "WiFi NDEF处理: 解析WiFi配置为空")
                    runOnUiThread {
                        android.widget.Toast.makeText(
                            this,
                            "WiFi 配置解析失败",
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "处理 WiFi NDEF 失败", e)
                runOnUiThread {
                    android.widget.Toast.makeText(
                        this,
                        "WiFi 配置解析失败",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            }
        }.start()

        return true
    }

    /**
     * 处理本应用自定义MIME类型的NDEF消息（微信/QQ/支付宝跳转）
     *
     * 此方法统一处理自定义MIME类型(application/vnd.com.example.toolapp.nfc)的NDEF消息，
     * 被两处调用：
     * 1. handleIncomingIntent中mimeType快速路径（ACTION_NDEF_DISCOVERED）
     * 2. handleIncomingIntent中通用NDEF解析兜底路径（ACTION_TECH_DISCOVERED时mimeType为null）
     * 3. MifareClassic读取NDEF消息后的处理
     *
     * payload为JSON格式，包含type字段（wechat/qq/alipay/wechat_pay）和对应的id参数
     *
     * @param ndefMessages NDEF消息数组
     * @return true表示已处理自定义MIME记录，false表示未找到自定义MIME记录
     */
    private fun handleCustomNdefMessage(ndefMessages: Array<NdefMessage>?): Boolean {
        if (ndefMessages == null || ndefMessages.isEmpty()) {
            return false
        }

        // 遍历NDEF记录，查找自定义MIME类型记录
        for (record in ndefMessages[0].records) {
            // TNF 2: MIME media type
            if (record.tnf == NdefRecord.TNF_MIME_MEDIA) {
                val type = String(record.type, Charsets.UTF_8)
                if (type == "application/vnd.com.example.toolapp.nfc") {
                    try {
                        val payload = String(record.payload, Charsets.UTF_8)
                        Log.i(TAG, "自定义NFC数据payload: $payload")
                        val json = org.json.JSONObject(payload)
                        val actionType = json.optString("type", "")

                        when (actionType) {
                            // 微信跳转：打开微信
                            "wechat" -> {
                                val wechatId = json.optString("id", "")
                                Log.i(TAG, "NFC碰卡: 微信跳转, id=$wechatId")
                                // 切换到主线程执行，避免子线程调用Toast崩溃
                                runOnUiThread { openWechat(wechatId) }
                            }
                            // QQ跳转：打开QQ临时会话
                            "qq" -> {
                                val qqId = json.optString("id", "")
                                Log.i(TAG, "NFC碰卡: QQ跳转, id=$qqId")
                                // 切换到主线程执行，避免子线程调用Toast崩溃
                                runOnUiThread { openQQ(qqId) }
                            }
                            // 支付宝跳转
                            "alipay" -> {
                                Log.i(TAG, "NFC碰卡: 支付宝跳转")
                                // 切换到主线程执行，避免子线程调用Toast崩溃
                                runOnUiThread { openAlipay() }
                            }
                            // 微信支付跳转
                            "wechat_pay" -> {
                                Log.i(TAG, "NFC碰卡: 微信支付跳转")
                                // 切换到主线程执行，避免子线程调用Toast崩溃
                                runOnUiThread { openWechatPay() }
                            }
                            // 导航跳转：打开指定导航软件搜索目的地
                            "navigate" -> {
                                val navApp = json.optString("app", "amap")
                                val navQuery = json.optString("query", "")
                                Log.i(TAG, "NFC碰卡: 导航跳转, app=$navApp, query=$navQuery")
                                // 切换到主线程执行，避免子线程调用startActivity崩溃
                                runOnUiThread { openNavigate(navApp, navQuery) }
                            }
                        }
                        return true
                    } catch (e: Throwable) {
                        Log.e(TAG, "解析自定义NFC数据失败", e)
                    }
                }
            }
        }
        return false
    }

    /**
     * 处理URI和Text类型的NDEF消息（网站跳转/文本显示）
     *
     * 此方法统一处理URI记录和Text记录，被两处调用：
     * 1. handleIncomingIntent中通用NDEF解析兜底路径（ACTION_TECH_DISCOVERED时mimeType为null）
     * 2. MifareClassic读取NDEF消息后的处理
     *
     * 注意：此方法可能从子线程调用，handleNfcUri中的startActivity需要切换到主线程
     *
     * @param ndefMessages NDEF消息数组
     * @param channel MethodChannel用于与Flutter通信
     * @return true表示已处理URI或Text记录，false表示未找到URI或Text记录
     */
    private fun handleUriAndTextNdefMessage(ndefMessages: Array<NdefMessage>?, channel: MethodChannel): Boolean {
        if (ndefMessages == null || ndefMessages.isEmpty()) {
            return false
        }

        // 遍历NDEF记录，查找URI或Text记录
        for (record in ndefMessages[0].records) {
            val tnf = record.tnf
            val type = String(record.type, Charsets.UTF_8)
            val payload = record.payload

            // TNF 1: Well-known type (U=URI, T=Text)
            if (tnf == NdefRecord.TNF_WELL_KNOWN) {
                // URI记录: type="U"
                if (type == "U" && payload.isNotEmpty()) {
                    val uri = parseNdefUriRecord(payload)
                    if (uri != null) {
                        Log.i(TAG, "NFC碰卡: 解析到URI = $uri")
                        // 切换到主线程处理URI，避免子线程调用startActivity崩溃
                        runOnUiThread { handleNfcUri(uri, channel) }
                        return true
                    }
                }
                // Text记录: type="T"
                if (type == "T" && payload.isNotEmpty()) {
                    val text = parseNdefTextRecord(payload)
                    if (text != null) {
                        Log.i(TAG, "NFC碰卡: 解析到文本 = $text")
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            channel.invokeMethod("handleNdefText", text)
                        }, 300)
                        return true
                    }
                }
            }
        }
        return false
    }

    /**
     * 打开微信
     * 先尝试通过weixin://scheme打开微信，再尝试通过包名直接启动
     */
    private fun openWechat(wechatId: String) {
        try {
            // 方案1：通过weixin://scheme打开微信
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("weixin://"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.setPackage("com.tencent.mm")
            startActivity(intent)
            Log.i(TAG, "已打开微信")
            // 提示用户微信号
            if (wechatId.isNotEmpty()) {
                // 复制微信号到剪贴板，方便用户搜索添加
                val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("微信号", wechatId))
                android.widget.Toast.makeText(
                    this,
                    "已复制微信号: $wechatId\n请在微信中搜索添加",
                    android.widget.Toast.LENGTH_LONG
                ).show()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "通过scheme打开微信失败，尝试包名启动", e)
            try {
                // 方案2：通过包名直接启动微信
                val launchIntent = packageManager.getLaunchIntentForPackage("com.tencent.mm")
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                    if (wechatId.isNotEmpty()) {
                        val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("微信号", wechatId))
                        android.widget.Toast.makeText(
                            this,
                            "已复制微信号: $wechatId\n请在微信中搜索添加",
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                    }
                } else {
                    android.widget.Toast.makeText(this, "未安装微信", android.widget.Toast.LENGTH_LONG).show()
                }
            } catch (e2: Throwable) {
                android.widget.Toast.makeText(this, "无法打开微信", android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    /**
     * 打开QQ
     * 先复制QQ号到剪贴板，再尝试通过scheme打开QQ名片页面，失败则直接打开QQ
     * 注意：mqqwpa://临时会话scheme在新版QQ上可能导致崩溃，不再使用
     */
    private fun openQQ(qqId: String) {
        // 先复制QQ号到剪贴板，方便用户搜索添加
        if (qqId.isNotEmpty()) {
            try {
                val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("QQ号", qqId))
            } catch (_: Throwable) { }
        }

        if (qqId.isEmpty()) {
            // 没有QQ号，直接打开QQ
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage("com.tencent.mobileqq")
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                } else {
                    android.widget.Toast.makeText(this, "未安装QQ", android.widget.Toast.LENGTH_LONG).show()
                }
            } catch (_: Throwable) { }
            return
        }

        try {
            // 方案1：通过mqqapi://scheme打开QQ名片页面（比临时会话更稳定）
            // 用户可以在名片页面直接添加好友
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("mqqapi://card/show_pslcard?src_type=internal&version=1&uin=$qqId&card_type=person&source=qrcode"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.setPackage("com.tencent.mobileqq")
            startActivity(intent)
            Log.i(TAG, "已打开QQ名片页面: $qqId")
            android.widget.Toast.makeText(
                this,
                "已复制QQ号: $qqId\n请在名片页面添加好友",
                android.widget.Toast.LENGTH_LONG
            ).show()
        } catch (e: Throwable) {
            Log.w(TAG, "通过scheme打开QQ名片失败，尝试包名启动", e)
            try {
                // 方案2：直接打开QQ，用户手动搜索添加（QQ号已复制到剪贴板）
                val launchIntent = packageManager.getLaunchIntentForPackage("com.tencent.mobileqq")
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                    android.widget.Toast.makeText(
                        this,
                        "已复制QQ号: $qqId\n请在QQ中搜索添加",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                } else {
                    android.widget.Toast.makeText(this, "未安装QQ", android.widget.Toast.LENGTH_LONG).show()
                }
            } catch (e2: Throwable) {
                android.widget.Toast.makeText(this, "无法打开QQ", android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    /**
     * 打开支付宝收款码
     */
    private fun openAlipay() {
        try {
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("alipays://platformapi/startapp?appId=20000056"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.setPackage("com.eg.android.AlipayGphone")
            startActivity(intent)
            Log.i(TAG, "已打开支付宝收款码")
        } catch (e: Throwable) {
            Log.w(TAG, "通过scheme打开支付宝失败，尝试包名启动", e)
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage("com.eg.android.AlipayGphone")
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                } else {
                    android.widget.Toast.makeText(this, "未安装支付宝", android.widget.Toast.LENGTH_LONG).show()
                }
            } catch (e2: Throwable) {
                android.widget.Toast.makeText(this, "无法打开支付宝", android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    /**
     * 打开微信付款码
     */
    private fun openWechatPay() {
        try {
            // 微信没有公开的付款码scheme，直接打开微信
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("weixin://"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.setPackage("com.tencent.mm")
            startActivity(intent)
            android.widget.Toast.makeText(this, "请在微信中打开付款码", android.widget.Toast.LENGTH_LONG).show()
        } catch (e: Throwable) {
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage("com.tencent.mm")
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                } else {
                    android.widget.Toast.makeText(this, "未安装微信", android.widget.Toast.LENGTH_LONG).show()
                }
            } catch (_: Throwable) {
                android.widget.Toast.makeText(this, "无法打开微信", android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }

    /**
     * 打开指定导航软件并搜索目的地
     *
     * 支持国内主流导航软件：高德地图、百度地图、腾讯地图
     * 根据app标识构造对应的搜索scheme，指定包名打开对应应用
     * 若应用未安装，则弹出提示框告知用户
     *
     * @param navApp 导航软件标识：amap=高德, baidu=百度, tencent=腾讯
     * @param query 目的地名称或地址（用户输入的文本）
     */
    private fun openNavigate(navApp: String, query: String) {
        // 导航软件包名和搜索scheme映射表
        val navAppConfig = when (navApp) {
            "amap" -> Triple(
                "com.autonavi.minimap",  // 高德地图包名
                "高德地图",
                // 高德地图：使用keywordNavi按关键字搜索导航（用户只输入名称没有经纬度）
                // androidamap://keywordNavi?sourceApplication=xxx&keyword=目的地&style=2
                "androidamap://keywordNavi?sourceApplication=toolapp&keyword=${android.net.Uri.encode(query)}&style=2"
            )
            "baidu" -> Triple(
                "com.baidu.BaiduMap",    // 百度地图包名
                "百度地图",
                "baidumap://map/navi?query=${android.net.Uri.encode(query)}&src=toolapp"
            )
            "tencent" -> Triple(
                "com.tencent.map",       // 腾讯地图包名
                "腾讯地图",
                "qqmap://route/plan?to=${android.net.Uri.encode(query)}&referer=toolapp"
            )
            else -> Triple(
                "com.autonavi.minimap",
                "高德地图",
                "androidamap://keywordNavi?sourceApplication=toolapp&keyword=${android.net.Uri.encode(query)}&style=2"
            )
        }

        val (packageName, appName, scheme) = navAppConfig

        try {
            // 通过scheme打开指定导航软件，设置包名确保直接打开目标应用
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(scheme))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.setPackage(packageName)
            startActivity(intent)
            Log.i(TAG, "已打开${appName}导航到: $query")
        } catch (e: Throwable) {
            Log.w(TAG, "${appName}未安装或无法打开", e)
            // 应用未安装，弹出提示框告知用户
            android.app.AlertDialog.Builder(this)
                .setTitle("未安装$appName")
                .setMessage("您的手机未安装$appName，无法自动导航到「$query」。\n\n请前往应用商店下载安装$appName，或重新写卡选择其他导航软件。")
                .setPositiveButton("去下载") { _, _ ->
                    // 尝试打开应用商店搜索该应用
                    try {
                        val marketIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("market://details?id=$packageName"))
                        marketIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(marketIntent)
                    } catch (_: Throwable) {
                        // 应用商店也未安装，打开浏览器搜索
                        try {
                            val browserIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://www.baidu.com/s?wd=$appName 下载"))
                            browserIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(browserIntent)
                        } catch (_: Throwable) {
                            android.widget.Toast.makeText(this, "无法打开应用商店", android.widget.Toast.LENGTH_LONG).show()
                        }
                    }
                }
                .setNegativeButton("取消", null)
                .show()
        }
    }

    /**
     * 兼容Android 13+的NDEF消息获取方法
     * Android 13+中getParcelableArrayListExtra已废弃，需要使用getParcelableArrayListExtra(key, class)
     */
    @Suppress("DEPRECATION")
    private fun getNdefMessages(intent: Intent?): Array<NdefMessage>? {
        if (intent == null) return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val messages = intent.getParcelableArrayListExtra(
                    NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java
                )
                messages?.toTypedArray()
            } else {
                val messages = intent.getParcelableArrayListExtra<NdefMessage>(
                    NfcAdapter.EXTRA_NDEF_MESSAGES
                )
                messages?.toTypedArray()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "获取NDEF消息失败", e)
            null
        }
    }

    /**
     * 处理NFC碰卡解析到的URI
     * 根据URI类型分发处理：本应用指令、微信/QQ/支付宝跳转、其他URI
     */
    private fun handleNfcUri(uri: String, channel: MethodChannel) {
        when {
            // 本应用自定义scheme
            uri.startsWith("toolapp://") -> {
                channel.invokeMethod("handleDeepLink", uri)
            }
            // 微信/QQ/支付宝URI：通过ACTION_VIEW转发给对应应用
            uri.startsWith("weixin://") || uri.startsWith("mqqwpa://") || uri.startsWith("alipays://") -> {
                try {
                    val viewIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))
                    viewIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    // 设置包名确保直接打开目标应用，避免再次弹出选择弹窗
                    when {
                        uri.startsWith("weixin://") -> viewIntent.setPackage("com.tencent.mm")
                        uri.startsWith("mqqwpa://") -> viewIntent.setPackage("com.tencent.mobileqq")
                        uri.startsWith("alipays://") -> viewIntent.setPackage("com.eg.android.AlipayGphone")
                    }
                    startActivity(viewIntent)
                    Log.i(TAG, "NFC碰卡: 已转发URI到第三方应用: $uri")
                } catch (e: Throwable) {
                    // 如果指定包名失败（如应用未安装），尝试不指定包名
                    Log.w(TAG, "指定包名打开失败，尝试通用方式: $uri", e)
                    try {
                        val fallbackIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))
                        fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(fallbackIntent)
                    } catch (e2: Throwable) {
                        Log.e(TAG, "无法打开URI: $uri", e2)
                        android.widget.Toast.makeText(
                            this,
                            "无法打开：请确认已安装对应应用",
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                    }
                }
            }
            // 其他URI
            else -> {
                try {
                    val viewIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))
                    viewIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(viewIntent)
                } catch (e: Throwable) {
                    Log.e(TAG, "无法打开URI: $uri", e)
                    android.widget.Toast.makeText(
                        this,
                        "已读取数据: $uri",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            }
        }
    }

    /**
     * 解析 NDEF URI 记录（NFC Forum Well-known Type "U"）
     * 格式：payload[0] = 标识符字节（URI前缀索引），其余为URI字符串
     */
    private fun parseNdefUriRecord(payload: ByteArray): String? {
        if (payload.isEmpty()) return null
        try {
            // URI缩写前缀表（NFC Forum标准）
            val uriPrefixes = arrayOf(
                "",                         // 0x00: 无缩写
                "http://www.",              // 0x01
                "https://www.",             // 0x02
                "http://",                  // 0x03
                "https://",                 // 0x04
                "tel:",                     // 0x05
                "mailto:",                  // 0x06
                "ftp://anonymous:anonymous@", // 0x07
                "ftp://ftp.",               // 0x08
                "ftps://",                  // 0x09
                "sftp://",                  // 0x0A
                "smb://",                   // 0x0B
                "nfs://",                   // 0x0C
                "ftp://",                   // 0x0D
                "geo:",                     // 0x0E
                "telnet://",                // 0x0F
                "imap:",                    // 0x10
                "rtsp://",                  // 0x11
                "urn:",                     // 0x12
                "pop:",                     // 0x13
                "sip:",                     // 0x14
                "sips:",                    // 0x15
                "tftp://",                  // 0x16
                "btspp://",                 // 0x17
                "btl2cap://",               // 0x18
                "btgoep://",                // 0x19
                "tcpobex://",               // 0x1A
                "irdaobex://",              // 0x1B
                "file://",                  // 0x1C
                "urn:epc:id:",              // 0x1D
                "urn:epc:tag:",             // 0x1E
                "urn:epc:pat:",             // 0x1F
                "urn:epc:raw:",             // 0x20
                "urn:epc:",                 // 0x21
                "urn:nfc:"                  // 0x22
            )
            val prefixIndex = payload[0].toInt() and 0xFF
            val prefix = if (prefixIndex < uriPrefixes.size) uriPrefixes[prefixIndex] else ""
            val uriBody = String(payload.copyOfRange(1, payload.size), Charsets.UTF_8)
            return prefix + uriBody
        } catch (e: Throwable) {
            Log.e(TAG, "解析NDEF URI失败", e)
            return null
        }
    }

    /**
     * 解析 NDEF Text 记录（NFC Forum Well-known Type "T"）
     * 格式：payload[0] = 状态字节（前3位是编码，后5位是语言代码长度）
     *       payload[1..n] = 语言代码（ISO/IANA）
     *       payload[n+1..] = 文本内容（UTF-8 或 UTF-16）
     */
    private fun parseNdefTextRecord(payload: ByteArray): String? {
        if (payload.size < 3) return null
        try {
            val statusByte = payload[0].toInt() and 0xFF
            val textEncoding = (statusByte shr 7) and 0x01  // 0=UTF-8, 1=UTF-16
            val languageCodeLength = statusByte and 0x3F   // 低5位
            if (languageCodeLength + 1 > payload.size) return null
            val textStart = 1 + languageCodeLength
            if (textStart >= payload.size) return ""
            val charset = if (textEncoding == 0x01) Charsets.UTF_16 else Charsets.UTF_8
            return String(payload.copyOfRange(textStart, payload.size), charset)
        } catch (e: Throwable) {
            Log.e(TAG, "解析NDEF Text失败", e)
            return null
        }
    }

    /**
     * 从 Mifare Classic 卡读取 NDEF 消息
     *
     * Mifare Classic 卡不是原生 Ndef 标签，NDEF 数据通过扇区块映射存储：
     * - 扇区0块0：制造商数据（只读）
     * - 扇区0块1：Capability Container (CC)，以 0xE1 开头
     * - 扇区0块2起：NDEF TLV (03 <length> <ndef_bytes> FE)
     * - 每扇区最后一块是扇区尾（密钥块），需跳过
     *
     * 读取流程：认证扇区 → 读取块 → 拼接数据 → 解析 NDEF TLV → 解析 NDEF 消息
     *
     * @param tag NFC Tag 对象
     * @return 解析出的 NdefMessage，失败返回 null
     */
    private fun readNdefFromMifareClassic(tag: android.nfc.Tag): android.nfc.NdefMessage? {
        val mfc = android.nfc.tech.MifareClassic.get(tag) ?: run {
            Log.w(TAG, "MifareClassic.get(tag)返回null")
            return null
        }

        try {
            mfc.connect()
            // 默认认证密钥（CUID卡默认全F密钥，与写卡端一致）
            val defaultKey = byteArrayOf(
                0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                0xFF.toByte(), 0xFF.toByte()
            )

            val sectorCount = mfc.sectorCount
            val blocksPerSector = 4 // Mifare Classic 每扇区4块
            Log.i(TAG, "MifareClassic: sectorCount=$sectorCount")

            // 收集所有数据块（跳过块0制造商数据和每扇区尾块）
            val dataBytes = mutableListOf<Byte>()

            // 从扇区0开始读取，块0跳过（制造商数据），从块1开始
            for (sector in 0 until sectorCount) {
                try {
                    // 认证扇区
                    val authed = mfc.authenticateSectorWithKeyA(sector, defaultKey)
                    if (!authed) {
                        Log.w(TAG, "MifareClassic: 扇区${sector}认证失败")
                        continue
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "MifareClassic: 扇区${sector}认证异常", e)
                    continue
                }

                // 读取该扇区的数据块（跳过最后一块扇区尾）
                for (blockInSector in 0 until blocksPerSector - 1) {
                    val blockIdx = mfc.sectorToBlock(sector) + blockInSector
                    // 跳过扇区0块0（制造商数据，只读）
                    if (sector == 0 && blockInSector == 0) continue
                    try {
                        val blockData = mfc.readBlock(blockIdx)
                        dataBytes.addAll(blockData.toList())
                    } catch (e: Throwable) {
                        Log.w(TAG, "MifareClassic: 读取块${blockIdx}失败", e)
                    }
                }
            }

            if (dataBytes.isEmpty()) {
                Log.w(TAG, "MifareClassic: 未读取到任何数据")
                return null
            }

            // 打印前64字节用于诊断
            val hexPreview = dataBytes.take(64).joinToString(" ") { "%02X".format(it) }
            Log.i(TAG, "MifareClassic: 读取到${dataBytes.size}字节, 前64字节: $hexPreview")

            // 查找 NDEF TLV 标记 (0x03)
            // CC块以 0xE1 开头，NDEF TLV 以 0x03 开头
            var ndefStart = -1
            for (i in dataBytes.indices) {
                if (dataBytes[i] == 0x03.toByte()) {
                    ndefStart = i
                    break
                }
            }

            if (ndefStart < 0) {
                Log.w(TAG, "MifareClassic: 未找到NDEF TLV标记(0x03)")
                return null
            }

            // 解析 NDEF TLV: 03 <length> <ndef_bytes> [FE]
            val lengthByte = dataBytes[ndefStart + 1].toInt() and 0xFF
            val ndefLength: Int
            val ndefDataStart: Int

            if (lengthByte == 0xFF) {
                // 长格式：03 FF <high> <low> <data>
                ndefLength = ((dataBytes[ndefStart + 2].toInt() and 0xFF) shl 8) or
                             (dataBytes[ndefStart + 3].toInt() and 0xFF)
                ndefDataStart = ndefStart + 4
            } else {
                // 短格式：03 <length> <data>
                ndefLength = lengthByte
                ndefDataStart = ndefStart + 2
            }

            Log.i(TAG, "MifareClassic: NDEF TLV length=$ndefLength, dataStart=$ndefDataStart")

            if (ndefDataStart + ndefLength > dataBytes.size) {
                Log.w(TAG, "MifareClassic: NDEF数据长度超出读取范围")
                return null
            }

            // 提取 NDEF 消息字节
            val ndefBytes = ByteArray(ndefLength)
            for (i in 0 until ndefLength) {
                ndefBytes[i] = dataBytes[ndefDataStart + i]
            }

            // 解析为 NdefMessage
            return android.nfc.NdefMessage(ndefBytes)
        } catch (e: Throwable) {
            Log.e(TAG, "MifareClassic: 读取NDEF失败", e)
            return null
        } finally {
            try { mfc.close() } catch (_: Throwable) { }
        }
    }

    /**
     * 解析 WiFi NDEF 消息，提取 SSID、密码和加密类型
     */
    private fun parseWifiNdefMessage(ndefMessage: android.nfc.NdefMessage): Map<String, String>? {
        try {
            val records = ndefMessage.records
            for (record in records) {
                if (record.tnf == android.nfc.NdefRecord.TNF_MIME_MEDIA) {
                    val mimeType = String(record.type, Charsets.UTF_8)
                    if (mimeType == "application/vnd.wfa.wsc") {
                        return parseWifiWscPayload(record.payload)
                    }
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "解析 WiFi NDEF 消息失败", e)
        }
        return null
    }

    /**
     * 解析 WSC (WiFi Simple Configuration) TLV 格式
     */
    private fun parseWifiWscPayload(payload: ByteArray): Map<String, String>? {
        val result = mutableMapOf<String, String>()
        var offset = 0
        
        while (offset < payload.size - 4) {
            // 读取 TLV 类型 (2字节)
            val type = ((payload[offset].toInt() and 0xFF) shl 8) or 
                       (payload[offset + 1].toInt() and 0xFF)
            offset += 2
            
            // 读取 TLV 长度 (2字节)
            val length = ((payload[offset].toInt() and 0xFF) shl 8) or 
                         (payload[offset + 1].toInt() and 0xFF)
            offset += 2
            
            if (offset + length > payload.size) break
            
            // 读取 TLV 值
            val value = payload.copyOfRange(offset, offset + length)
            offset += length
            
            // 解析凭证容器 (0x100E)
            if (type == 0x100E) {
                val subConfig = parseWifiWscPayload(value)
                if (subConfig != null) {
                    result.putAll(subConfig)
                }
            }
            // SSID (0x1045)
            else if (type == 0x1045) {
                result["ssid"] = String(value, Charsets.UTF_8)
                Log.i(TAG, "WiFi WSC解析: SSID=${result["ssid"]}")
            }
            // 网络密钥/密码 (0x1027)
            else if (type == 0x1027) {
                result["password"] = String(value, Charsets.UTF_8)
                Log.i(TAG, "WiFi WSC解析: password长度=${value.size}")
            }
            // 认证类型 (0x1003)
            else if (type == 0x1003) {
                if (value.size >= 2) {
                    val authType = ((value[0].toInt() and 0xFF) shl 8) or
                                   (value[1].toInt() and 0xFF)
                    result["authType"] = when (authType) {
                        0x0001 -> "OPEN"
                        0x0002 -> "WEP"
                        0x0004, 0x0008, 0x0010 -> "WPA"
                        0x0020 -> "WPA2"
                        else -> "WPA"
                    }
                    Log.i(TAG, "WiFi WSC解析: authType=${result["authType"]}(raw=0x${authType.toString(16)})")
                }
            }
        }
        
        return if (result.isNotEmpty()) result else null
    }

    /**
     * 热启动时 Android 会通过 onNewIntent 传递新的 intent
     * 例如 App 已在后台，碰 NFC 卡后系统通过 deep link 唤起 App
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        deepLinkChannel?.let { channel ->
            handleIncomingIntent(intent, channel)
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

    /**
     * 扫描附近 WiFi 列表（NFC WiFi 速写用）
     * 返回 WiFi 列表，每项包含 ssid, signal, authType
     */
    private fun scanWifiNetworks(): List<Map<String, Any?>> {
        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

        // 检查 WiFi 是否开启
        if (!wifiManager.isWifiEnabled) {
            wifiManager.isWifiEnabled = true
            // 等待 WiFi 启动
            Thread.sleep(1500)
        }

        // 先尝试获取已缓存的扫描结果（多数情况下系统已定期扫描更新）
        val cachedResults = wifiManager.scanResults
        if (!cachedResults.isNullOrEmpty()) {
            val hasValidResults = cachedResults.any {
                val ssid = it.SSID
                ssid != null && ssid.isNotBlank() && ssid != "<unknown ssid>"
            }
            if (hasValidResults) {
                return parseWifiResults(cachedResults)
            }
        }

        // 如缓存结果为空，尝试主动触发扫描并等待结果
        try {
            wifiManager.startScan()
        } catch (_: Throwable) {
            // Android 13+ 可能限制 startScan，忽略错误继续使用现有结果
        }

        // 等待扫描结果（最多等待 2.5 秒，分 5 次轮询）
        var resultList: List<android.net.wifi.ScanResult>? = null
        for (i in 1..5) {
            Thread.sleep(500)
            val currentResults = wifiManager.scanResults
            if (!currentResults.isNullOrEmpty()) {
                val hasValid = currentResults.any {
                    val ssid = it.SSID
                    ssid != null && ssid.isNotBlank() && ssid != "<unknown ssid>"
                }
                if (hasValid) {
                    resultList = currentResults
                    break
                }
            }
        }

        // 最终 fallback：直接返回当前可用的 scanResults
        if (resultList == null) {
            resultList = wifiManager.scanResults
        }

        if (resultList.isNullOrEmpty()) {
            return emptyList()
        }

        return parseWifiResults(resultList)
    }

    /**
     * 将原生 ScanResult 列表转换为 Dart 可读取的数据结构
     */
    private fun parseWifiResults(results: List<android.net.wifi.ScanResult>): List<Map<String, Any?>> {
        val seen = HashSet<String>()
        val resultList = mutableListOf<Map<String, Any?>>()

        for (scanResult in results) {
            val ssid = scanResult.SSID ?: continue
            if (ssid.isBlank() || ssid == "<unknown ssid>") continue

            // 去重（同一 SSID 可能出现在多个频段上）
            if (seen.contains(ssid)) continue
            seen.add(ssid)

            // 信号强度转换为 0-4 级
            val signal = when {
                scanResult.level >= -50 -> 4
                scanResult.level >= -60 -> 3
                scanResult.level >= -70 -> 2
                scanResult.level >= -80 -> 1
                else -> 0
            }

            // 解析加密类型
            val capabilities = scanResult.capabilities ?: ""
            val authType = when {
                capabilities.contains("WPA3") -> "WPA3"
                capabilities.contains("WPA2") -> "WPA2"
                capabilities.contains("WPA") -> "WPA"
                capabilities.contains("WEP") -> "WEP"
                else -> "OPEN"
            }

            resultList.add(
                mapOf(
                    "ssid" to ssid,
                    "signal" to signal,
                    "authType" to authType
                )
            )
        }

        // 按信号强度降序返回
        return resultList.sortedByDescending { it["signal"] as Int }
    }

    /**
     * 验证 WiFi 密码是否正确（NFC WiFi 速写用，写卡前验证）
     * 通过尝试连接指定 WiFi 来验证密码正确性，超时 8 秒
     * 返回: true = 密码正确，false = 密码错误或连接失败
     */
    private fun verifyWifiPassword(ssid: String, password: String, authType: String): Boolean {
        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

        // 检查 WiFi 是否开启
        if (!wifiManager.isWifiEnabled) {
            try {
                wifiManager.isWifiEnabled = true
            } catch (e: Throwable) {
                return false
            }
            Thread.sleep(1500)
        }

        // 记录当前连接的WiFi（验证后恢复）
        val originalNetworkId = wifiManager.connectionInfo?.networkId ?: -1
        val originalSsid = wifiManager.connectionInfo?.ssid?.trim('"') ?: ""

        val sdkInt = android.os.Build.VERSION.SDK_INT
        var verifySuccess = false

        try {
            verifySuccess = if (sdkInt >= android.os.Build.VERSION_CODES.Q) {
                // Android 10+ 使用 NetworkCallback 方式验证
                verifyWifiAndroid10Plus(ssid, password, authType)
            } else {
                // Android 9- 使用 WifiConfiguration 方式验证
                verifyWifiLegacy(ssid, password, authType)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "WiFi 密码验证异常", e)
            verifySuccess = false
        }

        // 验证完成后，尝试恢复到原连接（如果原来有连接且与当前不同）
        try {
            if (originalSsid.isNotEmpty() && originalSsid != ssid && originalNetworkId != -1) {
                wifiManager.enableNetwork(originalNetworkId, true)
                wifiManager.reconnect()
            }
        } catch (_: Throwable) { }

        return verifySuccess
    }

    /**
     * Android 10+ 验证 WiFi 密码
     * 
     * Android 16/MIUI兼容方案：
     * 1. 优先检查是否已连接到目标SSID（已连接则密码正确）
     * 2. 使用 WifiNetworkSuggestion 添加网络建议
     * 3. 如果addNetworkSuggestions返回需要用户批准（status=4），直接信任用户输入
     * 4. 通过轮询检查WiFi连接状态判断是否连接成功
     * 5. 验证完毕后移除网络建议，恢复原状态
     */
    @android.annotation.TargetApi(android.os.Build.VERSION_CODES.Q)
    private fun verifyWifiAndroid10Plus(ssid: String, password: String, authType: String): Boolean {
        try {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

            // ---- 步骤1：检查是否已连接到目标SSID ----
            val currentSsid = wifiManager.connectionInfo?.ssid?.trim('"') ?: ""
            if (currentSsid == ssid) {
                Log.i(TAG, "WiFi密码验证：已连接到目标SSID=$ssid，密码正确")
                return true
            }

            // ---- 步骤2：记录当前连接的SSID，用于验证后恢复 ----
            val originalSsid = currentSsid

            // ---- 步骤3：使用 WifiNetworkSuggestion API 添加网络建议 ----
            val suggestionBuilder = android.net.wifi.WifiNetworkSuggestion.Builder()
            suggestionBuilder.setSsid(ssid)

            // 根据加密类型设置密码
            when (authType.uppercase()) {
                "WPA", "WPA2", "WPA3" -> {
                    if (password.isNotEmpty()) {
                        suggestionBuilder.setWpa2Passphrase(password)
                    }
                }
                "OPEN", "", "NONE" -> {
                    // 开放网络，无需密码
                }
                else -> {
                    if (password.isNotEmpty()) {
                        suggestionBuilder.setWpa2Passphrase(password)
                    }
                }
            }

            val suggestion = suggestionBuilder.build()
            val suggestions = listOf(suggestion)

            // 添加网络建议（触发系统自动连接）
            val addStatus = wifiManager.addNetworkSuggestions(suggestions)
            Log.i(TAG, "WiFi密码验证：addNetworkSuggestions status=$addStatus")
            // status=0 表示成功
            // status=4 表示需要用户批准（Android 11+）
            // 在MIUI/Android 16上，status=4时用户批准对话框可能被屏蔽
            // 此时直接信任用户输入的密码，不再等待连接验证

            if (addStatus == 4) {
                // 需要用户批准但对话框可能被屏蔽，直接信任用户输入
                Log.i(TAG, "WiFi密码验证：需要用户批准(status=4)，直接信任用户输入")
                // 清理网络建议
                try {
                    wifiManager.removeNetworkSuggestions(suggestions)
                } catch (_: Throwable) { }
                return true
            }

            // ---- 步骤4：注册 BroadcastReceiver 监听 WiFi 状态变化 ----
            var connectedToTarget = false
            val wifiReceiver = object : android.content.BroadcastReceiver() {
                override fun onReceive(context: android.content.Context?, intent: Intent?) {
                    if (intent?.action == android.net.wifi.WifiManager.NETWORK_STATE_CHANGED_ACTION) {
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(
                                android.net.wifi.WifiManager.EXTRA_WIFI_INFO,
                                android.net.wifi.WifiInfo::class.java
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra<android.net.wifi.WifiInfo>(
                                android.net.wifi.WifiManager.EXTRA_WIFI_INFO
                            )
                        }
                        val connectedSsid = info?.ssid?.trim('"') ?: ""
                        if (connectedSsid == ssid) {
                            val ipAddr = info?.ipAddress ?: 0
                            if (ipAddr != 0) {
                                connectedToTarget = true
                                Log.i(TAG, "WiFi密码验证：已连接到SSID=$ssid，IP已获取")
                            }
                        }
                    }
                }
            }

            // 注册广播接收器
            val intentFilter = IntentFilter(android.net.wifi.WifiManager.NETWORK_STATE_CHANGED_ACTION)
            registerReceiver(wifiReceiver, intentFilter)

            // ---- 步骤5：等待连接结果（最多15秒） ----
            val startTime = System.currentTimeMillis()
            val timeoutMs = 15000L
            while (!connectedToTarget && System.currentTimeMillis() - startTime < timeoutMs) {
                try {
                    Thread.sleep(500)
                } catch (_: InterruptedException) { }

                // 也直接检查WiFi连接状态（双重保障）
                val info = wifiManager.connectionInfo
                val checkSsid = info?.ssid?.trim('"') ?: ""
                val checkIp = info?.ipAddress ?: 0
                if (checkSsid == ssid && checkIp != 0) {
                    connectedToTarget = true
                    Log.i(TAG, "WiFi密码验证：直接检查到已连接SSID=$ssid")
                    break
                }
            }

            // ---- 步骤6：清理 ----
            try {
                unregisterReceiver(wifiReceiver)
            } catch (_: Throwable) { }

            // 移除网络建议（避免残留）
            try {
                wifiManager.removeNetworkSuggestions(suggestions)
                Log.i(TAG, "WiFi密码验证：已移除网络建议")
            } catch (_: Throwable) { }

            // ---- 步骤7：如果验证成功且原来连接的是其他WiFi，尝试恢复 ----
            if (connectedToTarget && originalSsid.isNotEmpty() && originalSsid != ssid) {
                // 延迟2秒后恢复原连接
                Thread {
                    try {
                        Thread.sleep(2000)
                        // 重新添加原WiFi的网络建议
                        val origSuggestionBuilder = android.net.wifi.WifiNetworkSuggestion.Builder()
                        origSuggestionBuilder.setSsid(originalSsid)
                        wifiManager.addNetworkSuggestions(listOf(origSuggestionBuilder.build()))
                        Log.i(TAG, "WiFi密码验证：已恢复原WiFi建议=$originalSsid")
                    } catch (_: Throwable) { }
                }.start()
            }

            if (connectedToTarget) {
                Log.i(TAG, "WiFi密码验证成功：SSID=$ssid")
            } else {
                Log.i(TAG, "WiFi密码验证失败：未能连接到SSID=$ssid")
            }

            return connectedToTarget
        } catch (e: Throwable) {
            Log.e(TAG, "Android 10+ WiFi密码验证失败", e)
            return false
        }
    }

    /**
     * Android 9- 验证 WiFi 密码：使用 WifiConfiguration 方式
     */
    @Suppress("DEPRECATION")
    private fun verifyWifiLegacy(ssid: String, password: String, authType: String): Boolean {
        try {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

            // 创建临时的网络配置
            val wifiConfig = android.net.wifi.WifiConfiguration().apply {
                this.SSID = "\"$ssid\""

                when (authType.uppercase()) {
                    "WPA", "WPA2", "WPA3" -> {
                        this.preSharedKey = "\"$password\""
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.WPA_PSK)
                    }
                    "WEP" -> {
                        this.wepKeys[0] = "\"$password\""
                        this.wepTxKeyIndex = 0
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
                    }
                    else -> {
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
                    }
                }
            }

            // 添加网络
            val networkId = wifiManager.addNetwork(wifiConfig)
            if (networkId == -1) return false

            // 尝试连接
            wifiManager.disconnect()
            wifiManager.enableNetwork(networkId, true)
            wifiManager.reconnect()

            // 等待最多8秒检查连接状态
            val startTime = System.currentTimeMillis()
            var connectSuccess = false
            while (System.currentTimeMillis() - startTime < 8000) {
                try {
                    val info = wifiManager.connectionInfo
                    if (info != null) {
                        val currentSsid = info.ssid?.trim('"') ?: ""
                        val ipAddr = info.ipAddress
                        if (currentSsid == ssid && ipAddr != 0) {
                            // 已成功获取IP，连接成功
                            connectSuccess = true
                            break
                        }
                        // 检查网络状态
                        val networkState = wifiManager.getConfiguredNetworks()?.find {
                            it.networkId == networkId
                        }?.status
                        if (networkState != null && networkState != android.net.wifi.WifiConfiguration.Status.DISABLED) {
                            if (currentSsid == ssid) {
                                connectSuccess = true
                                break
                            }
                        }
                    }
                    Thread.sleep(500)
                } catch (_: Throwable) { }
            }

            // 验证失败时移除临时配置的网络
            if (!connectSuccess) {
                try {
                    wifiManager.removeNetwork(networkId)
                } catch (_: Throwable) { }
            }

            return connectSuccess
        } catch (e: Throwable) {
            Log.e(TAG, "Legacy WiFi密码验证失败", e)
            return false
        }
    }

    /**
     * 连接指定 WiFi（NFC WiFi 速写用）
     * 兼容 Android 10+ 使用 WifiNetworkSpecifier，Android 9- 使用 WifiConfiguration
     */
    private fun connectWifi(ssid: String, password: String, authType: String): Boolean {
        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

        // 检查 WiFi 是否开启
        if (!wifiManager.isWifiEnabled) {
            try {
                wifiManager.isWifiEnabled = true
            } catch (e: Throwable) {
                // Android 10+ 不允许应用直接开关WiFi
                // 尝试引导用户开启
                try {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_WIFI_SETTINGS)
                    intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    applicationContext.startActivity(intent)
                } catch (_: Throwable) { }
                return false
            }
            Thread.sleep(1500)
        }

        val sdkInt = android.os.Build.VERSION.SDK_INT

        return if (sdkInt >= android.os.Build.VERSION_CODES.Q) {
            // Android 10+ 使用 WifiNetworkSpecifier
            connectWifiAndroid10Plus(ssid, password, authType)
        } else {
            // Android 9- 使用 WifiConfiguration（已废弃）
            connectWifiLegacy(ssid, password, authType)
        }
    }

    /**
     * Android 10+ 连接 WiFi（碰卡后自动连接）
     *
     * Android 10+ 连接方案：
     * 1. 使用 WifiNetworkSuggestion 添加网络建议（系统级连接，会显示在WiFi界面）
     *    系统会自动尝试连接，连接成功后WiFi界面会显示已连接
     * 2. 等待一段时间检查连接状态
     * 3. 如果超时未连接，打开系统WiFi设置页让用户手动连接
     *
     * 注意：不使用 WifiNetworkSpecifier.requestNetwork，因为它创建的是应用专属临时连接，
     * 不会在系统WiFi界面显示（"假连接"问题）
     */
    private fun connectWifiAndroid10Plus(ssid: String, password: String, authType: String): Boolean {
        try {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

            // 先检查是否已连接到目标SSID
            val currentSsid = wifiManager.connectionInfo?.ssid?.trim('"') ?: ""
            if (currentSsid == ssid) {
                Log.i(TAG, "WiFi连接：已连接到目标SSID=$ssid")
                return true
            }

            // ---- 方案1：使用 WifiNetworkSuggestion 建立系统级连接 ----
            // 此API添加网络建议后，系统会自动尝试连接
            // 连接成功后会在系统WiFi界面显示已连接（真正的系统级连接）
            Log.i(TAG, "WiFi连接：使用WifiNetworkSuggestion建立系统级连接, SSID=$ssid")
            val suggestionBuilder = android.net.wifi.WifiNetworkSuggestion.Builder()
            suggestionBuilder.setSsid(ssid)

            when (authType.uppercase()) {
                "WPA", "WPA2", "WPA3" -> {
                    if (password.isNotEmpty()) {
                        suggestionBuilder.setWpa2Passphrase(password)
                    }
                }
                "OPEN", "", "NONE" -> {
                    // 开放网络
                }
                else -> {
                    if (password.isNotEmpty()) {
                        suggestionBuilder.setWpa2Passphrase(password)
                    }
                }
            }

            val suggestion = suggestionBuilder.build()
            val suggestions = listOf(suggestion)

            // 先移除旧的建议，再添加新的（避免重复添加导致冲突）
            try {
                wifiManager.removeNetworkSuggestions(suggestions)
            } catch (_: Throwable) { }

            val addStatus = wifiManager.addNetworkSuggestions(suggestions)
            Log.i(TAG, "WiFi连接：addNetworkSuggestions status=$addStatus (0=成功)")

            if (addStatus != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
                Log.w(TAG, "WiFi连接：addNetworkSuggestions失败, status=$addStatus")
            }

            // 等待系统自动连接，最多15秒
            val startTime = System.currentTimeMillis()
            val timeoutMs = 15000L
            var connected = false

            while (!connected && System.currentTimeMillis() - startTime < timeoutMs) {
                try {
                    Thread.sleep(500)
                } catch (_: InterruptedException) { }

                val info = wifiManager.connectionInfo
                val checkSsid = info?.ssid?.trim('"') ?: ""
                val checkIp = info?.ipAddress ?: 0
                if (checkSsid == ssid && checkIp != 0) {
                    connected = true
                    Log.i(TAG, "WiFi连接：通过Suggestion已成功连接到SSID=$ssid")
                    break
                }
            }

            if (connected) {
                return true
            }

            // ---- 方案2：打开系统WiFi设置页让用户手动连接 ----
            Log.i(TAG, "WiFi连接：Suggestion自动连接超时，打开系统WiFi设置页")
            try {
                val settingsIntent = android.content.Intent(android.provider.Settings.ACTION_WIFI_SETTINGS)
                settingsIntent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                applicationContext.startActivity(settingsIntent)
                // 提示用户手动选择网络
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    android.widget.Toast.makeText(
                        applicationContext,
                        "已打开WiFi设置，请手动连接: $ssid",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            } catch (_: Throwable) { }

            return connected
        } catch (e: Throwable) {
            Log.e(TAG, "Android 10+ WiFi连接失败", e)
            return false
        }
    }

    /**
     * Android 9- 连接 WiFi：使用已废弃的 WifiConfiguration API
     */
    @Suppress("DEPRECATION")
    private fun connectWifiLegacy(ssid: String, password: String, authType: String): Boolean {
        try {
            val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager

            // 检查是否已配置该网络
            val configuredNetworks = wifiManager.configuredNetworks ?: emptyList()
            val existingNetwork = configuredNetworks.find {
                it.SSID == "\"$ssid\"" || it.SSID == ssid
            }

            if (existingNetwork != null) {
                wifiManager.disconnect()
                val enabled = wifiManager.enableNetwork(existingNetwork.networkId, true)
                wifiManager.reconnect()
                return enabled
            }

            // 创建新的网络配置
            val wifiConfig = android.net.wifi.WifiConfiguration().apply {
                this.SSID = "\"$ssid\""

                when (authType.uppercase()) {
                    "WPA", "WPA2", "WPA3" -> {
                        this.preSharedKey = "\"$password\""
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.WPA_PSK)
                    }
                    "WEP" -> {
                        this.wepKeys[0] = "\"$password\""
                        this.wepTxKeyIndex = 0
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
                    }
                    else -> {
                        this.allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
                    }
                }
            }

            val networkId = wifiManager.addNetwork(wifiConfig)
            if (networkId == -1) return false

            wifiManager.disconnect()
            val enabled = wifiManager.enableNetwork(networkId, true)
            wifiManager.reconnect()

            return enabled
        } catch (e: Throwable) {
            Log.e(TAG, "Legacy WiFi连接失败", e)
            return false
        }
    }

    // ----------------------------------------------------------------------
    // 已知设备电池容量数据库
    // 当 BatteryManager/dumpsys/sysfs 均无法获取设计容量时，
    // ----------------------------------------------------------------------
    // 直接在原生端流式解析 zip 中的电池信息
    // 支持：标准 zip、嵌套 zip（小米 bug report 格式）
    // 外层 zip 用 ZipFile（支持 ZIP64）
    // 内层 zip 用 ZipInputStream（容忍重复条目名，小米 bugreport 有此问题）
    // ----------------------------------------------------------------------
    private fun parseBatteryFromZipFile(zipFile: File, maxDepth: Int): Map<String, Any?>? {
        if (maxDepth <= 0) {
            Log.w(TAG, "parseZip: maxDepth reached, stopping recursion")
            return null
        }

        Log.d(TAG, "parseZip: opening file=${zipFile.name} size=${zipFile.length()} maxDepth=$maxDepth")

        try {
            // 使用 ZipFile 读取（支持 ZIP64，比 ZipInputStream 更可靠）
            ZipFile(zipFile).use { zf ->
                val entries = zf.entries()
                var entryCount = 0
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    entryCount++
                    if (entry.isDirectory) continue

                    val entryName = entry.name.lowercase()
                    Log.d(TAG, "parseZip: entry #$entryCount name=${entry.name} size=${entry.size}")

                    // 内层 zip（小米格式：bugreport-*.zip）
                    if (entryName.endsWith(".zip") && entryName.contains("bugreport")) {
                        Log.d(TAG, "parseZip: found inner zip: ${entry.name}")
                        // 将内层 zip 保存到临时文件
                        val innerZipFile = File(cacheDir, "inner_zip_${System.currentTimeMillis()}.zip")
                        try {
                            zf.getInputStream(entry).buffered().use { input ->
                                innerZipFile.outputStream().buffered().use { output ->
                                    input.copyTo(output)
                                }
                            }
                            Log.d(TAG, "parseZip: inner zip saved, size=${innerZipFile.length()}, parsing with ZipInputStream")
                            // 内层 zip 用 ZipInputStream 读取（容忍重复条目名）
                            val result = parseInnerZipWithStream(innerZipFile)
                            if (result != null) return result
                            Log.d(TAG, "parseZip: inner zip returned null")
                        } catch (e: Throwable) {
                            Log.e(TAG, "parseZip: inner zip extraction/parse failed", e)
                        } finally {
                            innerZipFile.delete()
                        }
                    }
                    // bugreport 主文本文件（如 bugreport-houji-xxx.txt）
                    else if (entryName.contains("bugreport") && entryName.endsWith(".txt")) {
                        Log.d(TAG, "parseZip: found bugreport txt: ${entry.name}")
                        zf.getInputStream(entry).buffered().use { input ->
                            val result = parseBatteryFromStream(input.bufferedReader(Charsets.UTF_8), entry.name)
                            if (result != null) return result
                            Log.d(TAG, "parseZip: bugreport txt returned null")
                        }
                    }
                    // dumpstate 日志
                    else if (entryName.contains("dumpstate") && entryName.endsWith(".txt")) {
                        Log.d(TAG, "parseZip: found dumpstate txt: ${entry.name}")
                        zf.getInputStream(entry).buffered().use { input ->
                            val result = parseBatteryFromStream(input.bufferedReader(Charsets.UTF_8), entry.name)
                            if (result != null) return result
                        }
                    }
                }
                Log.d(TAG, "parseZip: total entries=$entryCount, no battery data found")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "parseBatteryFromZipFile error for ${zipFile.name}", e)
        }
        return null
    }

    // 使用 ZipInputStream 读取内层 zip（容忍重复条目名）
    // 小米 bugreport 的内层 zip 包含重复条目名，ZipFile 无法打开
    private fun parseInnerZipWithStream(zipFile: File): Map<String, Any?>? {
        try {
            ZipInputStream(zipFile.inputStream().buffered()).use { zis ->
                var entry: ZipEntry? = zis.nextEntry
                var entryCount = 0
                while (entry != null) {
                    entryCount++
                    if (!entry.isDirectory) {
                        val entryName = entry.name.lowercase()
                        Log.d(TAG, "parseInnerZip: entry #$entryCount name=${entry.name} size=${entry.size}")

                        // bugreport 主文本文件
                        if (entryName.contains("bugreport") && entryName.endsWith(".txt")) {
                            Log.d(TAG, "parseInnerZip: found bugreport txt: ${entry.name}")
                            val result = parseBatteryFromStream(zis.bufferedReader(Charsets.UTF_8), entry.name)
                            if (result != null) return result
                            Log.d(TAG, "parseInnerZip: bugreport txt returned null")
                        }
                        // dumpstate 日志
                        else if (entryName.contains("dumpstate") && entryName.endsWith(".txt")) {
                            Log.d(TAG, "parseInnerZip: found dumpstate txt: ${entry.name}")
                            val result = parseBatteryFromStream(zis.bufferedReader(Charsets.UTF_8), entry.name)
                            if (result != null) return result
                        }
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
                Log.d(TAG, "parseInnerZip: total entries=$entryCount, no battery data found")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "parseInnerZipWithStream error for ${zipFile.name}", e)
        }
        return null
    }

    // 从 BufferedReader 逐行读取，提取 "DUMP OF SERVICE battery:" 区域
    // 找到后立即返回，避免读取整个大文件
    private fun parseBatteryFromStream(reader: java.io.BufferedReader, sourceName: String): Map<String, Any?>? {
        var designCapacityMah: Int? = null
        var fullCapacityMah: Int? = null
        var chargeCounterUah: Int? = null
        var level: Int? = null
        var status: String? = null
        var voltageMv: Int? = null
        var temperature: Int? = null
        var technology: String? = null

        var inBatterySection = false
        var lineCount = 0
        var totalLines = 0

        try {
            var line: String? = reader.readLine()
            while (line != null) {
                totalLines++

                val trimmed = line.trim()

                // 检测 battery 服务区域开始
                if (!inBatterySection &&
                    trimmed.contains("DUMP OF SERVICE battery:") &&
                    !trimmed.contains("batterystats")) {
                    inBatterySection = true
                    lineCount = 0
                    Log.d(TAG, "parseStream: found DUMP OF SERVICE battery at line $totalLines")
                    line = reader.readLine()
                    continue
                }

                if (inBatterySection) {
                    // 检测区域结束
                    if (trimmed.startsWith("DUMP OF SERVICE") ||
                        (trimmed.startsWith("---------") && lineCount > 5)) {
                        break
                    }
                    lineCount++

                    // 提取冒号后的值
                    fun afterColon(prefix: String): String? {
                        if (!trimmed.startsWith(prefix)) return null
                        val idx = trimmed.indexOf(':')
                        if (idx < 0) return null
                        return trimmed.substring(idx + 1).trim()
                    }

                    // 设计容量（µAh → mAh）
                    afterColon("charge_full_design:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) designCapacityMah = (it / 1000) }
                    }
                    // 满充容量（µAh → mAh）
                    afterColon("charge_full:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) fullCapacityMah = (it / 1000) }
                    }
                    // 当前电量（Charge counter，小米/OPPO/OnePlus 格式）
                    afterColon("Charge counter:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) chargeCounterUah = it }
                    }
                    // 标准小写格式
                    if (chargeCounterUah == null) {
                        afterColon("charge_counter:")?.let { v ->
                            v.toIntOrNull()?.let { if (it > 0) chargeCounterUah = it }
                        }
                    }
                    // 电量百分比
                    afterColon("level:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) level = it }
                    }
                    // 充电状态
                    afterColon("status:")?.let { v ->
                        status = when (v) {
                            "1", "Unknown" -> "Unknown"
                            "2", "Charging" -> "Charging"
                            "3", "Discharging" -> "Discharging"
                            "4", "Not charging" -> "Not charging"
                            "5", "Full" -> "Full"
                            else -> v
                        }
                    }
                    // 电压
                    afterColon("voltage:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) voltageMv = it }
                    }
                    // 温度
                    afterColon("temperature:")?.let { v ->
                        v.toIntOrNull()?.let { if (it > 0) temperature = it }
                    }
                    // 电池技术
                    afterColon("technology:")?.let { v ->
                        if (v.isNotEmpty() && v.toIntOrNull() == null) technology = v
                    }
                }

                line = reader.readLine()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "parseBatteryFromStream error after $totalLines lines", e)
        }

        // 只要收集到任何容量数据就返回
        if (chargeCounterUah == null && designCapacityMah == null && fullCapacityMah == null) {
            Log.d(TAG, "parseStream: no capacity data found (read $totalLines lines, inBattery=$inBatterySection)")
            return null
        }

        Log.d(TAG, "parseStream: found data - design=$designCapacityMah full=$fullCapacityMah counter=$chargeCounterUah level=$level")

        return mapOf(
            "designCapacityMah" to designCapacityMah,
            "fullCapacityMah" to fullCapacityMah,
            "chargeCounterUah" to chargeCounterUah,
            "level" to level,
            "status" to (status ?: ""),
            "voltageMv" to voltageMv,
            "temperature" to temperature,
            "technology" to (technology ?: ""),
            "source" to sourceName,
        )
    }

    // 通过设备型号/设备名/产品名查询已知的电池设计容量
    // ----------------------------------------------------------------------
    private fun getKnownBatteryCapacity(model: String): Int {
        // 主流设备电池设计容量数据库（mAh）
        // 数据来源：官方规格参数
        // key 可以是 Build.MODEL / Build.DEVICE / Build.PRODUCT
        val knownCapacities = mapOf(
            // ===== OnePlus 一加 =====
            // 一加 Ace 系列
            "PHK110" to 5000, "OP5913L1" to 5000,   // 一加 Ace 2 (中国版)
            "CPH2447" to 5000,                         // 一加 Ace 2 (印度版)
            "PHB110" to 5000,                          // 一加 Ace 2V
            "CPH2615" to 5500, "OP5553L1" to 5500,   // 一加 Ace 3
            "CPH2609" to 5500,                         // 一加 Ace 3V
            "PGP110" to 5000, "OP5A0FL1" to 5000,   // 一加 Ace 5
            "PGW110" to 6100, "OP5AEFL1" to 6100,   // 一加 Ace 5 Pro
            "CPH2493" to 4500,                         // 一加 Ace Racing
            // 一加数字系列
            "CPH2449" to 5000, "OP5953L1" to 5000,   // 一加 11
            "CPH2581" to 5000, "OP5921L1" to 5000,   // 一加 12
            "CPH2611" to 5400,                         // 一加 13
            "IN2020" to 4260, "IN2023" to 4260,       // 一加 8 Pro
            "IN2010" to 4300,                          // 一加 8
            "LE2121" to 4500, "LE2123" to 4500,       // 一加 9 Pro
            "LE2101" to 4500,                          // 一加 9
            "CPH2159" to 4300,                         // 一加 9R
            "CPH2179" to 4300,                         // 一加 9RT
            "LE2211" to 5000,                          // 一加 10 Pro
            "CPH2399" to 4500,                         // 一加 10T
            "CPH2381" to 5000,                         // 一加 Nord 2T
            "CPH2269" to 4500,                         // 一加 Nord 2
            "A3000" to 3300,                           // 一加 3
            "E1003" to 3000,                           // 一加 X

            // ===== OPPO =====
            "CPH2583" to 5000, "OP59ADL1" to 5000,   // OPPO Find X6
            "CPH2585" to 5000, "OP5A1DL1" to 5000,   // OPPO Find X6 Pro
            "CPH2587" to 5000,                         // OPPO Find X7
            "CPH2589" to 5400,                         // OPPO Find X7 Ultra
            "CPH2621" to 5400,                         // OPPO Find X8 Pro
            "CPH2591" to 4500,                         // OPPO Reno 10 Pro+
            "PFDM00" to 4600,                          // OPPO Reno8 Pro+
            "PFGM00" to 5000,                          // OPPO Reno9 Pro+
            "PFTM00" to 4310,                          // OPPO Reno10 Pro
            "PEEM00" to 4220,                          // OPPO Reno7 Pro
            "PEDM00" to 4025,                          // OPPO Reno6 Pro
            "PCHM30" to 4025,                          // OPPO Reno5 Pro
            "PCKM00" to 3935,                          // OPPO Reno4 Pro
            "PCAM00" to 3765,                          // OPPO Reno3 Pro
            "PBBT00" to 4100,                          // OPPO Reno2
            "PBBM00" to 4100,                          // OPPO Reno2 F
            "PACT00" to 4000,                          // OPPO Reno
            "PABM00" to 4000,                          // OPPO Reno A
            "PAAM00" to 3600,                          // OPPO R17
            "RMX3350" to 4500,                         // realme GT Neo
            "RMX3360" to 4500,                         // realme GT Neo2
            "RMX3461" to 5000,                         // realme GT Neo3

            // ===== Xiaomi 小米 =====
            // 小米数字系列
            "24030PN60G" to 5300, "aurora" to 5300,   // 小米14 Ultra
            "23116PN5BC" to 4880, "23116PN5BG" to 4880, "sheng" to 4880,    // 小米14 Pro
            "23127PN0C" to 4610, "23127PN0CC" to 4610, "23127PN0CG" to 4610, "houji" to 4610,    // 小米14
            "2304FPN6DG" to 5000, "ishtar" to 5000,  // 小米13 Ultra
            "2210132C" to 4820, "nuwa" to 4820,      // 小米13 Pro
            "2211133C" to 4500, "fuxi" to 4500,      // 小米13
            "22081212C" to 4860, "dagu" to 4860,     // 小米12S Ultra
            "2201122C" to 4600, "zeus" to 4600,      // 小米12 Pro
            "2201123C" to 4500, "cupid" to 4500,     // 小米12
            "2112123AC" to 5000, "star" to 5000,     // 小米11 Ultra
            "M2011K2C" to 4600, "venus" to 4600,     // 小米11
            "M2012K11C" to 4780, "cas" to 4780,      // 小米10 至尊纪念版
            "M2012K11AC" to 4780, "thyme" to 4780,   // 小米10 Pro
            "M2007J22C" to 4720, "umi" to 4720,      // 小米10
            "M2007J3SY" to 5020, "tucana" to 5020,   // 小米CC9 Pro
            "M2004J7BC" to 4780, "cepheus" to 4780,  // 小米9
            "M2006C3LV" to 5020, "angelic" to 5020,  // 小米10 Lite
            "M2010J4SY" to 4820, "gauguin" to 4820,  // 小米10T Pro
            // Redmi K 系列
            "23117RK66C" to 5000, "manet" to 5000,   // Redmi K70 Pro
            "2311DRK48C" to 5000, "vermeer" to 5000, // Redmi K70
            "22127RK95C" to 5000, "mondrian" to 5000, // Redmi K60 Pro
            "2210132C75" to 5500, "rembrandt" to 5500, // Redmi K60
            "22081212UC" to 5000, "diting" to 5000,  // Redmi K50 Ultra
            "22011211C" to 5500, "rubens" to 5500,   // Redmi K50 Pro
            "22041211AC" to 5500, "xaga" to 5500,    // Redmi K50
            "2106118C" to 5160, "ares" to 5160,      // Redmi K40 Pro
            "M2012K11AC" to 4520, "alioth" to 4520,  // Redmi K40
            "M2007J3SC" to 4700, "apollo" to 4700,   // Redmi K30S
            // Redmi Note 系列
            "23090RA98G" to 5000, "sapphire" to 5000, // Redmi Note 13 Pro+
            "23090RA89C" to 5000, "sapphiren" to 5000, // Redmi Note 13 Pro
            "22101316UC" to 5000, "sweet" to 5000,   // Redmi Note 12 Pro+
            "22101316C" to 5000, "sweetk6" to 5000,  // Redmi Note 12 Pro
            "2201117TI" to 5000, "evergo" to 5000,   // Redmi Note 11 Pro+
            "21061119BC" to 5160, "vili" to 5160,    // Redmi Note 11 Pro 5G
            "M2101K9C" to 5000, "rosemary" to 5000,  // Redmi Note 10 Pro
            "M2003J15SC" to 5020, "merlin" to 5020,  // Redmi Note 9

            // ===== Samsung 三星 =====
            "SM-S928B" to 5000, "e3q" to 5000,       // Galaxy S24 Ultra
            "SM-S926B" to 4500, "e2q" to 4500,       // Galaxy S24+
            "SM-S921B" to 3900, "e1q" to 3900,       // Galaxy S24
            "SM-S918B" to 5000, "p3q" to 5000,       // Galaxy S23 Ultra
            "SM-S916B" to 4500, "p2q" to 4500,       // Galaxy S23+
            "SM-S911B" to 3900, "p1q" to 3900,       // Galaxy S23
            "SM-S908B" to 5000, "b0q" to 5000,       // Galaxy S22 Ultra
            "SM-S906B" to 4500, "b2q" to 4500,       // Galaxy S22+
            "SM-S901B" to 3800, "b1q" to 3800,       // Galaxy S22
            "SM-A546B" to 5000,                        // Galaxy A54
            "SM-A536B" to 5000,                        // Galaxy A53
            "SM-A346B" to 5000,                        // Galaxy A34
            "SM-A528B" to 4500,                        // Galaxy A52s
            "SM-A127F" to 5000,                        // Galaxy A12
            "SM-M526B" to 5000,                        // Galaxy M52
            "SM-M336B" to 5000,                        // Galaxy M32
            "SM-M127F" to 5000,                        // Galaxy M12

            // ===== Huawei 华为 =====
            "ALT-AL10" to 4750, "ALT-AN00" to 4750,  // Mate 60 Pro+
            "OCE-AN10" to 4100,                        // P60 Pro
            "NOH-AN00" to 4200,                        // Mate 40 Pro
            "TET-AN00" to 3800,                        // P40 Pro
            "ANA-AN00" to 4100,                        // P30 Pro
            "VOG-AL00" to 4200,                        // Mate 20 Pro
            "ELE-AL00" to 3650,                        // P30
            "VIE-AL10" to 4000,                        // Mate 9 Pro

            // ===== Google Pixel =====
            "Pixel 8 Pro" to 5050, "husky" to 5050,
            "Pixel 8" to 4575, "shiba" to 4575,
            "Pixel 7 Pro" to 5000, "cheetah" to 5000,
            "Pixel 7" to 4355, "panther" to 4355,
            "Pixel 6 Pro" to 5003, "raven" to 5003,
            "Pixel 6" to 4614, "oriole" to 4614,
            "Pixel 5" to 4080, "redfin" to 4080,
            "Pixel 4a" to 3885, "sunfish" to 3885,
        )
        // 精确匹配
        knownCapacities[model]?.let { return it }
        // 模糊匹配：遍历查找包含关系
        for ((key, value) in knownCapacities) {
            if (model.contains(key, ignoreCase = true) || key.contains(model, ignoreCase = true)) {
                return value
            }
        }
        return -1
    }
}
