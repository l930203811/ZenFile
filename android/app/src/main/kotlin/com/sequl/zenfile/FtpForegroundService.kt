package com.sequl.zenfile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

class FtpForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "ftp_server_channel"
        private const val NOTIFICATION_ID = 1002

        /**
         * Dart 侧 FTP 通道。系统因 dataSync 6 小时额度到期调用 onTimeout 时，
         * 先回传 Dart 关掉真正的 FTP socket，再摘通知 + stopSelf（issue #92）。
         * 由 MainActivity 在引擎就绪后赋值。
         */
        @Volatile
        var timeoutChannel: MethodChannel? = null
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 兼容通过 startService(action=stop) 停止的调用方
        if (intent?.getStringExtra("action") == "stop") {
            shutdown()
            return START_NOT_STICKY
        }

        val ip = intent?.getStringExtra("ip") ?: "127.0.0.1"
        val port = intent?.getIntExtra("port", 9999) ?: 9999
        val title = intent?.getStringExtra("title") ?: "ZenFile FTP Server"
        val contentText = intent?.getStringExtra("contentText") ?: "Running at ftp://$ip:$port"

        val notificationIntent = Intent(this, MainActivity::class.java).apply {
            this.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            else
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        val iconResId = resources.getIdentifier("ic_launcher", "mipmap", packageName).let {
            if (it != 0) it else android.R.drawable.ic_dialog_info
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(iconResId)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        startForeground(NOTIFICATION_ID, notification)

        // issue #92：Android 15+/target 35 起 dataSync 前台服务在后台每 24 小时
        // 累计 6 小时后会被系统要求停止，onTimeout 里必须几秒内 stopSelf，否则
        // 系统抛 ForegroundServiceDidNotStopInTimeException 直接杀进程。
        // FTP 的 socket 在 Dart 侧，进程被杀后重建服务只会留下「幽灵通知」，
        // 因此不再 STICKY，由用户重新开启。
        return START_NOT_STICKY
    }

    /**
     * API 35+ 系统回调（低版本永远不会被调用，无需版本判断）。
     * dataSync 类型 6 小时额度到期：先通知 Dart 关闭 FTP 服务，
     * 然后立刻摘通知 + stopSelf，避免被系统硬杀。
     */
    override fun onTimeout(startId: Int, reason: Int) {
        try {
            timeoutChannel?.invokeMethod("onServiceTimeout", mapOf("reason" to reason))
        } catch (_: Exception) {
        }
        shutdown(startId)
    }

    private fun shutdown(startId: Int? = null) {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        if (startId != null) {
            stopSelf(startId)
        } else {
            stopSelf()
        }
    }

    override fun onDestroy() {
        // 任何销毁路径都必须摘掉前台通知，否则系统会认为服务仍在运行
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "ZenFile FTP Server"
            val descriptionText = "ZenFile FTP Service"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = descriptionText
                setShowBadge(false)
            }
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
}