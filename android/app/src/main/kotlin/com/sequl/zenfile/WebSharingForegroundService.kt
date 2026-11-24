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

class WebSharingForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "web_sharing_channel"
        private const val NOTIFICATION_ID = 1003

        /**
         * Dart 侧 Web 分享通道。dataSync 6 小时额度到期时先回传 Dart 关掉
         * HttpServer/隧道，再摘通知 + stopSelf（issue #92）。
         */
        @Volatile
        var timeoutChannel: MethodChannel? = null
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getStringExtra("action") == "stop") {
            shutdown()
            return START_NOT_STICKY
        }

        val url = intent?.getStringExtra("url") ?: "http://127.0.0.1:8080"
        val isInternet = intent?.getBooleanExtra("isInternet", false) ?: false
        val title = intent?.getStringExtra("title") ?: if (isInternet) "ZenFile Internet Web Share" else "ZenFile Local Web Share"
        val contentText = intent?.getStringExtra("contentText") ?: "Running at $url"

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

        // issue #92：同 FTP 服务，dataSync 后台 6 小时到期必须几秒内 stopSelf，
        // 否则系统抛 ForegroundServiceDidNotStopInTimeException 杀进程。
        return START_NOT_STICKY
    }

    /** API 35+ 系统回调：先让 Dart 停掉真正的分享服务，再摘通知 + stopSelf。 */
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
            val name = "ZenFile Web Sharing"
            val descriptionText = "ZenFile Web Sharing Service"
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