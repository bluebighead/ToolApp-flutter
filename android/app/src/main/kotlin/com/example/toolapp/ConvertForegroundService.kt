package com.example.toolapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 视频转换前台服务
 *
 * 作用：在 FFmpeg 转换期间保持 App 进程不被 Android 系统限制（Doze 模式 / App Standby）。
 * 息屏、切到后台、离开转换页面时，FFmpeg 原生进程仍能正常执行。
 *
 * 设计要点：
 *   1) 使用 FOREGROUND_SERVICE_DATA_SYNC 类型（Android 10+ 要求）
 *   2) 通知栏持续显示转换进度，用户可随时看到状态
 *   3) 点击通知可回到 App
 *   4) 转换完成/取消时自动 stopSelf()
 */
class ConvertForegroundService : Service() {

    companion object {
        private const val TAG = "ConvertForegroundService"
        private const val NOTIFICATION_ID = 2001
        private const val CHANNEL_ID = "convert_foreground_service"
        private const val CHANNEL_NAME = "视频转换服务"

        // Intent extras 的 key
        const val EXTRA_TITLE = "title"
        const val EXTRA_CONTENT = "content"
        const val EXTRA_PROGRESS = "progress"       // 0~100
        const val EXTRA_SUBTEXT = "subtext"
        const val EXTRA_ACTION_TEXT = "action_text" // 停止按钮文字

        // 动作
        const val ACTION_START = "com.example.toolapp.ACTION_START_CONVERT"
        const val ACTION_UPDATE = "com.example.toolapp.ACTION_UPDATE_PROGRESS"
        const val ACTION_STOP = "com.example.toolapp.ACTION_STOP_CONVERT"
        const val ACTION_CANCEL = "com.example.toolapp.ACTION_CANCEL_CONVERT"

        // v1.6.56+ 修复：通知栏"停止"按钮点击后的回调
        // 通过 MethodChannel 通知 Flutter 端取消 FFmpeg 转换
        private var onCancelRequested: (() -> Unit)? = null

        /** 注册取消回调（由 MainActivity 通过 MethodChannel 设置） */
        fun setOnCancelRequestedListener(listener: (() -> Unit)?) {
            onCancelRequested = listener
        }

        /**
         * 启动前台服务
         */
        fun start(context: Context, title: String, content: String) {
            val intent = Intent(context, ConvertForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CONTENT, content)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 更新前台服务通知的进度
         */
        fun update(context: Context, title: String, content: String, progress: Int, subtext: String) {
            val intent = Intent(context, ConvertForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CONTENT, content)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_SUBTEXT, subtext)
            }
            context.startService(intent)
        }

        /**
         * 停止前台服务
         */
        fun stop(context: Context) {
            val intent = Intent(context, ConvertForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.i(TAG, "前台服务已创建")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "视频转换中…"
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: "正在转换"
                val notification = buildNotification(title, content, 0, null)
                startForeground(NOTIFICATION_ID, notification)
                Log.i(TAG, "前台服务已启动: $title - $content")
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "视频转换中…"
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: ""
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val subtext = intent.getStringExtra(EXTRA_SUBTEXT)
                val notification = buildNotification(title, content, progress, subtext)
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, notification)
            }
            ACTION_STOP -> {
                Log.i(TAG, "前台服务收到停止请求")
                stopForeground(true)
                stopSelf()
            }
            ACTION_CANCEL -> {
                Log.i(TAG, "前台服务收到取消请求（通知栏停止按钮）")
                // v1.6.56+ 修复：通知 Dart 端取消 FFmpeg 转换
                // 旧版只停前台服务，FFmpeg 进程仍在后台运行
                onCancelRequested?.invoke()
                stopForeground(true)
                stopSelf()
            }
        }
        // START_NOT_STICKY：如果系统杀了服务，不要自动重启（转换已中断，应由用户决定是否重试）
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "前台服务已销毁")
    }

    /** 创建通知渠道（Android 8+） */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW // 低优先级：不弹横幅、不响铃
        ).apply {
            description = "视频转换期间保持 App 运行"
            setShowBadge(false)
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    /** 构建通知 */
    private fun buildNotification(
        title: String,
        content: String,
        progress: Int,
        subtext: String?
    ): Notification {
        // 点击通知回到 App
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(content)
            .setContentIntent(pendingIntent)
            .setOngoing(true) // 不可滑动清除
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        // 进度条
        if (progress > 0) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(100, 0, true) // 不确定进度
        }

        // 子文本（剩余时间等）
        if (!subtext.isNullOrEmpty()) {
            builder.setSubText(subtext)
        }

        // 停止按钮
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ConvertForegroundService::class.java).apply {
                action = ACTION_CANCEL
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "停止",
            stopIntent
        )

        return builder.build()
    }
}
