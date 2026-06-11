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
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * WebSocket连接保活前台服务
 *
 * 作用：App切到后台时，Android系统会限制后台进程的网络和CPU使用，
 * 导致WebSocket连接被系统杀掉。此前台服务通过通知栏常驻通知，
 * 告知系统该进程正在执行重要网络操作，不应被限制。
 *
 * 设计要点：
 *   1) 使用 FOREGROUND_SERVICE_DATA_SYNC 类型（Android 10+ 要求）
 *   2) 通知栏显示"设备连接中"状态，用户可随时查看
 *   3) 点击通知可回到App
 *   4) 获取WakeLock防止CPU休眠导致WebSocket心跳中断
 *   5) WebSocket断开时自动停止服务
 */
class WebSocketForegroundService : Service() {

    companion object {
        private const val TAG = "WebSocketFgService"
        private const val NOTIFICATION_ID = 3001
        private const val CHANNEL_ID = "websocket_foreground_service"
        private const val CHANNEL_NAME = "设备连接服务"

        // Intent动作
        const val ACTION_START = "com.example.toolapp.ACTION_START_WS"
        const val ACTION_STOP = "com.example.toolapp.ACTION_STOP_WS"
        const val EXTRA_CONTENT = "content"

        // WakeLock：防止CPU休眠导致WebSocket心跳中断
        private var wakeLock: PowerManager.WakeLock? = null

        /**
         * 启动WebSocket保活前台服务
         */
        fun start(context: Context, content: String = "设备连接保持中") {
            val intent = Intent(context, WebSocketForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONTENT, content)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 停止WebSocket保活前台服务
         */
        fun stop(context: Context) {
            val intent = Intent(context, WebSocketForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.i(TAG, "WebSocket保活前台服务已创建")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val content = intent.getStringExtra(EXTRA_CONTENT) ?: "设备连接保持中"
                val notification = buildNotification(content)
                startForeground(NOTIFICATION_ID, notification)
                acquireWakeLock()
                Log.i(TAG, "WebSocket保活前台服务已启动: $content")
            }
            ACTION_STOP -> {
                Log.i(TAG, "WebSocket保活前台服务收到停止请求")
                releaseWakeLock()
                stopForeground(true)
                stopSelf()
            }
        }
        // START_STICKY：如果系统杀了服务，自动重启以保持连接
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
        Log.i(TAG, "WebSocket保活前台服务已销毁")
    }

    /** 获取WakeLock防止CPU休眠 */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "ToolApp::WebSocketWakeLock"
            ).apply {
                acquire(4 * 60 * 60 * 1000L) // 最长4小时
            }
            Log.i(TAG, "WakeLock已获取")
        } catch (e: Exception) {
            Log.e(TAG, "WakeLock获取失败: ${e.message}")
        }
    }

    /** 释放WakeLock */
    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.i(TAG, "WakeLock已释放")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "WakeLock释放失败: ${e.message}")
        }
    }

    /** 创建通知渠道（Android 8+） */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW // 低优先级：不弹横幅、不响铃
        ).apply {
            description = "保持设备WebSocket连接稳定"
            setShowBadge(false)
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    /** 构建通知 */
    private fun buildNotification(content: String): Notification {
        // 点击通知回到App
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ToolApp")
            .setContentText(content)
            .setContentIntent(pendingIntent)
            .setOngoing(true) // 不可滑动清除
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .build()
    }
}
