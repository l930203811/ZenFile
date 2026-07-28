package com.sequl.zenfile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.annotation.OptIn
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 安卓 13+ 媒体通知控制面板（参照 Echo-Music 的 Media3 实现）。
 *
 * 旧方案用 audio_service 的 MediaSessionCompat(legacy)，在 Android 13+ 上媒体卡片
 * 注册脆弱、经常不显示。本服务改用 AndroidX Media3：
 *   - MediaSessionService + MediaSession（由自定义 SimpleBasePlayer 支撑）
 *   - DefaultMediaNotificationProvider 自动生成 MediaStyle 通知（系统媒体卡片）
 *   - 播放状态由 media_kit 经 Dart 桥接（com.sequl.zenfile/media3）实时推送
 *   - 用户在通知/锁屏/蓝牙耳机上的播放指令经同一通道回传 Dart，驱动 media_kit
 *
 * 注意：SimpleBasePlayer 属于 UnstableApi。
 */
@OptIn(UnstableApi::class)
class ZenMediaSessionService : MediaSessionService() {

    private lateinit var zenPlayer: ZenMediaPlayer
    private lateinit var mediaSession: MediaSession
    private var channel: MethodChannel? = null

    companion object {
        const val CHANNEL_ID = "com.sequl.zenfile.audio.v2"
        const val NOTIFICATION_ID = 888
        const val METHOD_CHANNEL = "com.sequl.zenfile/media3"
        // 由 MainActivity.configureFlutterEngine 注入的 Flutter 信使，用于与 Dart 双向通信
        var flutterMessenger: BinaryMessenger? = null
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()

        zenPlayer = ZenMediaPlayer(Looper.getMainLooper())

        val sessionIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val sessionActivity = PendingIntent.getActivity(
            this, 0, sessionIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        mediaSession = MediaSession.Builder(this, zenPlayer)
            .setSessionActivity(sessionActivity)
            .build()

        // 先放置一个占位前台通知，满足 startForegroundService 的 5 秒时限
        // （之后再交由 Media3 的 DefaultMediaNotificationProvider 接管更新）
        val placeholder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.zenfile_audio_channel))
            .setContentText("")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIFICATION_ID, placeholder)

        // Media3 自动生成 MediaStyle 通知（13+ 系统媒体卡片），无需手写 MediaStyle
        val provider = DefaultMediaNotificationProvider.Builder(this)
            .setNotificationId(NOTIFICATION_ID)
            .setChannelId(CHANNEL_ID)
            .setChannelName(R.string.zenfile_audio_channel)
            .build()
        provider.setSmallIcon(R.mipmap.ic_launcher)
        setMediaNotificationProvider(provider)

        flutterMessenger?.let { messenger ->
            channel = MethodChannel(messenger, METHOD_CHANNEL)
            channel?.setMethodCallHandler { call, result -> handleDartCall(call, result) }
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession {
        return mediaSession
    }

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        var ch = nm.getNotificationChannel(CHANNEL_ID)
        if (ch == null) {
            ch = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.zenfile_audio_channel),
                NotificationManager.IMPORTANCE_DEFAULT
            )
            ch.setShowBadge(true)
            nm.createNotificationChannel(ch)
        }
    }

    @OptIn(UnstableApi::class)
    private fun handleDartCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMetadata" -> {
                val title = call.argument<String>("title") ?: ""
                val artist = call.argument<String?>("artist")
                val durationMs = call.argument<Long>("durationMs") ?: 0L
                val artworkBytes = call.argument<ByteArray?>("artworkBytes")
                zenPlayer.updateMetadata(title, artist, durationMs, artworkBytes)
                result.success(null)
            }
            "setPlaybackState" -> {
                val playing = call.argument<Boolean>("playing") ?: false
                val positionMs = call.argument<Long>("positionMs") ?: 0L
                val bufferedMs = call.argument<Long>("bufferedMs") ?: positionMs
                zenPlayer.updatePlaybackState(playing, positionMs, bufferedMs)
                result.success(null)
            }
            "setQueue" -> {
                val items = call.argument<List<Map<String, Any>>>("items") ?: emptyList()
                val index = call.argument<Int>("index") ?: 0
                zenPlayer.updateQueue(items, index)
                result.success(null)
            }
            "stop" -> {
                zenPlayer.reset()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDestroy() {
        mediaSession.release()
        zenPlayer.release()
        super.onDestroy()
    }

    // ─── 自定义 Player：状态由 Dart 推送，指令回传 Dart ──────────────────
    @OptIn(UnstableApi::class)
    inner class ZenMediaPlayer(looper: Looper) : SimpleBasePlayer(looper) {

        private var playing = false
        private var positionMs: Long = 0
        private var bufferedMs: Long = 0
        private var durationMs: Long = 0
        private var title: String = ""
        private var artist: String? = null
        private var artworkBytes: ByteArray? = null
        private var playlist: List<SimpleBasePlayer.MediaItemData> = emptyList()
        private var currentIndex: Int = 0
        private var active: Boolean = false

        private val availableCommands = Player.Commands.Builder()
            .add(Player.COMMAND_PLAY_PAUSE)
            .add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
            .add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            .add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            .add(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)
            .add(Player.COMMAND_GET_METADATA)
            .add(Player.COMMAND_STOP)
            .build()

        fun updateMetadata(
            title: String,
            artist: String?,
            durationMs: Long,
            artworkBytes: ByteArray?
        ) {
            this.title = title
            this.artist = artist
            this.durationMs = durationMs
            this.artworkBytes = artworkBytes
            invalidateState()
        }

        fun updatePlaybackState(playing: Boolean, positionMs: Long, bufferedMs: Long) {
            this.playing = playing
            this.positionMs = positionMs
            this.bufferedMs = bufferedMs
            this.active = true
            invalidateState()
        }

        fun updateQueue(items: List<Map<String, Any>>, index: Int) {
            val list = items.map { m ->
                val t = (m["title"] as? String) ?: ""
                val a = m["artist"] as? String
                val mediaId = (m["id"] as? String) ?: t
                val metadata = MediaMetadata.Builder()
                    .setTitle(t)
                    .setArtist(a)
                    .build()
                SimpleBasePlayer.MediaItemData.Builder(mediaId)
                    .setMediaMetadata(metadata)
                    .setIsSeekable(true)
                    .build()
            }
            this.playlist = list
            this.currentIndex = index.coerceIn(0, (list.size - 1).coerceAtLeast(0))
            invalidateState()
        }

        fun reset() {
            this.active = false
            this.playing = false
            this.positionMs = 0
            invalidateState()
        }

        override fun getState(): SimpleBasePlayer.State {
            val metadata = MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(artist)
                .apply {
                    if (artworkBytes != null) {
                        setArtworkData(artworkBytes, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
                    }
                }
                .build()
            val durationUs = if (durationMs > 0) durationMs * 1000 else C.TIME_UNSET

            // 当前曲目数据始终以 Dart 实时推送为准（时长/封面等）
            val effectivePlaylist: List<SimpleBasePlayer.MediaItemData>
            val effectiveIndex: Int
            if (playlist.isNotEmpty() && currentIndex in playlist.indices) {
                effectivePlaylist = playlist.mapIndexed { i, item ->
                    if (i == currentIndex) {
                        item.buildUpon()
                            .setMediaMetadata(metadata)
                            .setIsSeekable(true)
                            .setDurationUs(durationUs)
                            .build()
                    } else item
                }
                effectiveIndex = currentIndex
            } else {
                effectivePlaylist = listOf(
                    SimpleBasePlayer.MediaItemData.Builder("zenfile_current")
                        .setMediaMetadata(metadata)
                        .setIsSeekable(true)
                        .setDurationUs(durationUs)
                        .build()
                )
                effectiveIndex = 0
            }

            return SimpleBasePlayer.State.Builder()
                .setAvailableCommands(availableCommands)
                .setPlayWhenReady(active && playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
                .setPlaybackState(if (active) Player.STATE_READY else Player.STATE_IDLE)
                .setPlaylist(effectivePlaylist)
                .setCurrentMediaItemIndex(effectiveIndex)
                .setContentPositionMs(positionMs)
                .setContentBufferedPositionMs(
                    SimpleBasePlayer.PositionSupplier.getConstant(bufferedMs)
                )
                .build()
        }

        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
            sendCommand(if (playWhenReady) "play" else "pause", null)
            return Futures.immediateVoidFuture()
        }

        override fun handleSeek(
            mediaItemIndex: Int,
            positionMs: Long,
            @Player.Command seekCommand: Int
        ): ListenableFuture<*> {
            when (seekCommand) {
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> sendCommand("next", null)
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> sendCommand("previous", null)
                else -> sendCommand("seek", positionMs)
            }
            return Futures.immediateVoidFuture()
        }

        override fun handleStop(): ListenableFuture<*> {
            sendCommand("stop", null)
            return Futures.immediateVoidFuture()
        }

        private fun sendCommand(action: String, positionMs: Long?) {
            val messenger = flutterMessenger ?: return
            val ch = MethodChannel(messenger, METHOD_CHANNEL)
            val args = HashMap<String, Any?>()
            args["action"] = action
            if (positionMs != null) args["positionMs"] = positionMs
            ch.invokeMethod("onCommand", args)
        }
    }
}
