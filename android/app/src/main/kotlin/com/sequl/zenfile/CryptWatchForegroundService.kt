package com.sequl.zenfile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * 原地加密目录实时监听前台服务 —— ZenFile 本地补丁（2026-10-02）。
 *
 * 背景：原地加密是一次性动作，此后相机等外部 App 写进已加密目录的新文件
 * 会永远是明文（见 WORKLOG 2026-10-02「加密新增文件」条目）。本服务用
 * FileObserver（inotify）监听已注册的原地加密目录，把新文件事件推回 Dart，
 * 由 Dart 侧 [静默期 → 判定明文 → 就地加密]，实现「新文件自动加密」。
 *
 * 通道协议（MethodChannel `com.sequl.zenfile/crypt_watch`）：
 *  - Dart → 原生：`start(paths, pendingPaths, title, contentText)` / `stop()`
 *  - 原生 → Dart：`onFileChanged {dir, name, event}`
 *
 * ⚠️ FileObserver 是**非递归**的（只监控单层目录），因此每个注册目录各建一个
 * observer；子目录内的写入暂不监听（相机目录是扁平的，覆盖主场景）。
 * 事件回调线程是 FileObserver 的工作线程，必须 post 到主线程才能调用 channel
 * 和改动 observer 表。
 *
 * ## pending 监听（2026-10-02 用户报障）
 * 目录名加密（standard）的原地加密会把 `/DCIM/Camera` 换成密文目录名 ⇒ 相机
 * 检测不到原目录 ⇒ **重建同名明文目录**继续写照片。该目录在服务启动时往往
 * 还不存在，Dart 会把它放进 `pendingPaths`：这里先监控其**父目录**，一旦
 * CREATE/MOVED_TO 出现同名子目录就「转正」为直接监听并通知 Dart —— 否则
 * 新照片要等到下次 App 打开的兜底扫描才会被并入（一直明文暴露）。
 */
class CryptWatchForegroundService : Service() {

    companion object {
        private const val TAG = "CryptWatchService"
        private const val CHANNEL_ID = "crypt_watch_channel"
        private const val NOTIFICATION_ID = 1004

        /** 监听的事件掩码：写入完成 / 移入 / 新建 / 删除（删除仅用于维护 observer 表） */
        private const val WATCH_MASK = FileObserver.CREATE or
                FileObserver.CLOSE_WRITE or
                FileObserver.MOVED_TO or
                FileObserver.DELETE or
                FileObserver.DELETE_SELF or
                FileObserver.MOVE_SELF

        /** Dart 侧注册的事件回传通道（由 MainActivity 在引擎就绪后赋值） */
        @Volatile
        var eventChannel: MethodChannel? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var isRunning = false
    }

    /** 正在直接监听的目录（仅主线程读写） */
    private val observers = HashMap<String, FileObserver>()

    /** pending 父目录监听表：parentPath -> observer（仅主线程改动） */
    private val pendingParentWatchers = HashMap<String, FileObserver>()

    /** 尚不存在的 pending 子路径：parentPath -> (childName -> childPath)。
     *  onEvent 在工作线程读、主线程写 ⇒ 用并发容器。 */
    private val pendingByParent =
        ConcurrentHashMap<String, ConcurrentHashMap<String, String>>()

    /** 由 pending 转正而来的直接监听目录：其 delete_self 后要重新挂回 pending */
    private val promotedPending: MutableSet<String> =
        ConcurrentHashMap.newKeySet()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.getStringExtra("action") ?: "start"
        if (action == "stop") {
            stopWatchers()
            isRunning = false
            try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra("title") ?: "ZenFile 自动加密"
        val contentText = intent?.getStringExtra("contentText") ?: "正在保护已加密目录"
        startForeground(NOTIFICATION_ID, buildNotification(title, contentText))

        @Suppress("UNCHECKED_CAST")
        val paths = intent?.getStringArrayExtra("paths")?.toList() ?: emptyList()
        val pendingPaths =
            intent?.getStringArrayExtra("pendingPaths")?.toList() ?: emptyList()
        applyPaths(paths, pendingPaths)
        isRunning = true
        // issue #92：dataSync 前台服务 6 小时额度到期被系统要求停止时，
        // 重建一个没有 paths 的空监听服务毫无意义，反而会再次触发超时。
        return START_NOT_STICKY
    }

    /**
     * API 35+ 系统回调：dataSync 后台累计 6 小时到期。先通知 Dart 关掉
     * 自动加密开关，再停监听、摘通知、stopSelf，避免系统硬杀进程。
     */
    override fun onTimeout(startId: Int, reason: Int) {
        Log.w(TAG, "dataSync foreground timeout reason=$reason, stopping crypt watch")
        try {
            eventChannel?.invokeMethod("onServiceTimeout", mapOf("reason" to reason))
        } catch (_: Exception) {
        }
        stopWatchers()
        isRunning = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        stopSelf(startId)
    }

    /** 用 Flutter 传入的目录表重建所有 observer */
    private fun applyPaths(paths: List<String>, pendingPaths: List<String>) {
        stopWatchers()
        pendingByParent.clear()
        promotedPending.clear()
        for (path in paths) {
            watchDir(path)
        }
        for (path in pendingPaths) {
            val f = File(path)
            when {
                f.isDirectory -> {
                    // 服务运行期间已被重建：直接监听
                    promotedPending.add(path)
                    watchDir(path)
                }
                f.exists() -> Log.w(TAG, "pending path exists but not a dir: $path")
                else -> registerPending(path)
            }
        }
        Log.i(
            TAG,
            "watching ${observers.size} directories, " +
                    "${pendingByParent.values.sumOf { it.size }} pending"
        )
    }

    /** 对单个已存在目录建直接监听（observer 表仅主线程改动） */
    private fun watchDir(path: String) {
        val observer = object : FileObserver(path, WATCH_MASK) {
            override fun onEvent(event: Int, relativePath: String?) {
                if (relativePath == null) return
                // ⚠️ inotify 原始 mask 会 OR 上标志位（目录事件必带 IN_ISDIR
                // 0x40000000）：`event == FileObserver.CREATE` 这类**精确等值
                // 比较**对目录级事件全部失配 ⇒ mkdir 重建的同名目录永远匹配
                // 不上 ⇒ pending 永不转正（2026-10-03 用户实测）。先掩掉
                // 标志位只留事件类型，再比较。
                val type = event and FileObserver.ALL_EVENTS
                val eventName = when (type) {
                    FileObserver.CLOSE_WRITE -> "close_write"
                    FileObserver.MOVED_TO -> "moved_to"
                    FileObserver.CREATE -> "create"
                    FileObserver.DELETE -> "delete"
                    FileObserver.DELETE_SELF -> "delete_self"
                    FileObserver.MOVE_SELF -> "move_self"
                    else -> return
                }
                if (type == FileObserver.DELETE_SELF || type == FileObserver.MOVE_SELF) {
                    // 被监听目录自身没了（可能是 Dart merge 完并入后删掉了
                    // 明文兄弟目录）：停掉 observer；pending 转正而来的要重新
                    // 挂回 pending 监听，等相机下次重建。
                    mainHandler.post {
                        observers.remove(path)?.let {
                            try {
                                it.stopWatching()
                            } catch (_: Exception) {
                            }
                        }
                        if (promotedPending.remove(path)) {
                            // 重新挂回 pending 前先看目录是否已被相机重建：merge
                            // 删除与相机 mkdir 之间存在竞态 —— 相机可能在 DELETE_SELF
                            // 之前就重建了同名目录（新照片已经在里面）。此时目录已
                            // 存在，pending 的 CREATE 永远不会来，必须直接转正监听
                            // （后续文件事件的 CLOSE_WRITE 会触发 Dart 侧并入）。
                            val f = File(path)
                            if (f.isDirectory) {
                                promotedPending.add(path)
                                watchDir(path)
                                deliverEvent(path, f.name, "create")
                            } else {
                                registerPending(path)
                            }
                        }
                    }
                    return
                }
                deliverEvent(path, relativePath, eventName)
            }
        }
        try {
            observer.startWatching()
            observers[path] = observer
        } catch (e: Exception) {
            Log.e(TAG, "startWatching failed: $path", e)
        }
    }

    /** 登记一个尚不存在的目录：监控其父目录，出现同名子目录即转正 */
    private fun registerPending(path: String) {
        val f = File(path)
        val parent = f.parent ?: return
        pendingByParent
            .getOrPut(parent) { ConcurrentHashMap() }[f.name] = path
        armParentWatcher(parent)
    }

    /** 给 pending 的父目录挂 CREATE/MOVED_TO 监听（已有直接监听则不重复挂） */
    private fun armParentWatcher(parent: String) {
        if (observers.containsKey(parent)) return
        if (pendingParentWatchers.containsKey(parent)) return
        val mask = FileObserver.CREATE or FileObserver.MOVED_TO
        val observer = object : FileObserver(parent, mask) {
            override fun onEvent(event: Int, relativePath: String?) {
                if (relativePath == null) return
                val child = pendingByParent[parent]?.get(relativePath) ?: return
                // mkdir 触发的 CREATE 带 IN_ISDIR 标志位 ⇒ 精确等值比较失配
                // ⇒ 转正永不触发；先掩掉标志位再比较（同 watchDir）。
                val type = event and FileObserver.ALL_EVENTS
                if (type != FileObserver.CREATE && type != FileObserver.MOVED_TO) return
                mainHandler.post {
                    val map = pendingByParent[parent] ?: return@post
                    if (map.remove(relativePath) == null) return@post
                    if (map.isEmpty()) pendingByParent.remove(parent)
                    // 父目录监听完成使命：后续事件由子目录自己的 observer 承接
                    pendingParentWatchers.remove(parent)?.let {
                        try {
                            it.stopWatching()
                        } catch (_: Exception) {
                        }
                    }
                    val childPath = File(parent, relativePath).absolutePath
                    if (File(childPath).isDirectory) {
                        promotedPending.add(childPath)
                        watchDir(childPath)
                        deliverEvent(childPath, relativePath, "create")
                    }
                }
            }
        }
        try {
            observer.startWatching()
            pendingParentWatchers[parent] = observer
        } catch (e: Exception) {
            Log.e(TAG, "parent startWatching failed: $parent", e)
        }
    }

    /** 把文件事件投递回 Dart（主线程；channel 未就绪时静默丢弃，由兜底扫描补上） */
    private fun deliverEvent(watchedDir: String, relativePath: String, event: String) {
        mainHandler.post {
            val channel = eventChannel ?: return@post
            val args = mapOf(
                "dir" to watchedDir,
                "name" to relativePath,
                "event" to event,
            )
            channel.invokeMethod("onFileChanged", args)
        }
    }

    private fun stopWatchers() {
        for ((path, observer) in observers) {
            try {
                observer.stopWatching()
            } catch (e: Exception) {
                Log.e(TAG, "stopWatching failed: $path", e)
            }
        }
        observers.clear()
        for ((parent, observer) in pendingParentWatchers) {
            try {
                observer.stopWatching()
            } catch (e: Exception) {
                Log.e(TAG, "stop parent watching failed: $parent", e)
            }
        }
        pendingParentWatchers.clear()
    }

    private fun buildNotification(title: String, contentText: String): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
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
        return builder
            .setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(iconResId)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "ZenFile 自动加密"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = "ZenFile encrypted directory watch service"
                setShowBadge(false)
            }
            val notificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        stopWatchers()
        isRunning = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
