package com.sequl.zenfile

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 分享意图桥接：接收第三方 App 以 ACTION_SEND / ACTION_SEND_MULTIPLE / ACTION_VIEW
 * 分享到 ZenFile 的文件（URI），原样交给 Dart 处理。
 *
 * 🔴 为什么不用 receive_sharing_intent 插件：该插件在原生层就把 content:// 流
 * **复制进应用 cache** 再把缓存路径返回给 Dart —— 普通目录的文件也被无谓复制
 * （「打开所在位置」定位到的是缓存目录而非原位置）。本桥只透传**原始 URI**，
 * 是否复制、复制与否由 Dart 在用户选完「打开 / 打开所在位置」后再决定
 * （普通目录直接用原路径；受限目录如 Android/data 才按需复制）。
 *
 * 🔴 必须是**进程级单例（object）**，原因与 [SystemFilePickerBridge] 相同：
 * MainActivity 继承 audio_service 的 AudioServiceFragmentActivity，使用缓存引擎，
 * Activity 可能被销毁重建而 FlutterEngine / Dart isolate 存活——
 * 状态与 channel 必须跨实例共享（静态）。Dart 侧配合：回到前台（resumed）
 * 时主动补查一次 getShareIntent。
 *
 * 生命周期：
 *  · onCreate / onNewIntent → [onLaunchIntent]：解析 intent，**重置** pending
 *    状态（无分享 URI 的启动会清掉旧值，避免「已完成请求」被补查误判）；
 *  · Dart 查 [getShareIntent]（幂等，不消费）→ 弹「打开 / 打开所在位置」对话框；
 *  · Dart 调 [consume]（开始处理时即消费）→ 清空 pending，避免 resumed 补查重复弹窗。
 */
object ShareIntentBridge {

    @Volatile
    private var channel: MethodChannel? = null

    /** 待处理的分享 URI（原始 content:// 或 file://，未做任何复制）。 */
    @Volatile
    private var pendingUris: List<String> = emptyList()

    /** 分享方声明的 MIME 类型（可能为 null）。 */
    @Volatile
    private var pendingMime: String? = null

    /**
     * 解析调起 intent。由 MainActivity 在 onCreate（notifyDart=false，此时
     * channel 多半尚未注册，Dart 权限就绪后会补查）与 onNewIntent
     * （notifyDart=true，后台复用时主动推送）调用。
     */
    fun onLaunchIntent(intent: Intent?, notifyDart: Boolean) {
        val uris = mutableListOf<String>()
        var mime: String? = intent?.type
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val stream = getStreamExtra(intent)
                if (stream != null) uris.add(stream.toString())
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                }
                streams?.forEach { s -> uris.add(s.toString()) }
            }
            Intent.ACTION_VIEW -> {
                intent.data?.let { uris.add(it.toString()) }
                if (mime == null) mime = intent.type
            }
            else -> {
                // 普通启动：清掉上一轮残留，防止 Dart 补查误判。
                pendingUris = emptyList()
                pendingMime = null
                return
            }
        }
        if (uris.isEmpty()) {
            pendingUris = emptyList()
            pendingMime = null
            return
        }
        pendingUris = uris
        pendingMime = mime
        if (notifyDart) pushToDart()
    }

    private fun getStreamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun pushToDart() {
        val uris = pendingUris
        if (uris.isEmpty()) return
        channel?.invokeMethod(
            "onShareIntent",
            mapOf("uris" to uris, "mime" to pendingMime)
        )
    }

    /** 注册 Dart 侧通道。 */
    fun registerChannel(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getShareIntent" -> {
                    val uris = pendingUris
                    result.success(
                        if (uris.isEmpty()) {
                            null
                        } else {
                            mapOf("uris" to uris, "mime" to pendingMime)
                        }
                    )
                }
                "consume" -> {
                    pendingUris = emptyList()
                    pendingMime = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private const val CHANNEL = "com.sequl.zenfile/share_intent"
}
