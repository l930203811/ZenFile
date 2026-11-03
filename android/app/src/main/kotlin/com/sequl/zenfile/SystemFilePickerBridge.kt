package com.sequl.zenfile

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统文件选择器桥接：让第三方 App（QQ / 微信等）用 ACTION_GET_CONTENT 选文件时，
 * 直接使用 ZenFile **自己的**文件浏览器，而不是系统选择器里由 DocumentsUI 渲染的
 * 简陋「ZenFile Storage」列表页。
 *
 * 流程：
 * 1. 第三方 App 发起 ACTION_GET_CONTENT → 系统 chooser 里出现 ZenFile → 启动 MainActivity；
 * 2. Activity.onCreate 之前调用 [onLaunchIntent] 记下本次是「选文件」启动；
 * 3. Dart 侧查询 getPickerInfo 后打开 InternalFilePickerScreen 让用户选；
 * 4. Dart 调 finishPick(paths) → 这里把路径转成 ZenFileDocumentsProvider 的
 *    document URI 回传给调起方，并结束本页。
 *
 * 🔴 必须是**进程级单例（object）**，不能像早期版本那样按 Activity 实例持有状态。
 * 原因：MainActivity 继承 audio_service 的 AudioServiceFragmentActivity，后者用
 * **缓存引擎**（getCachedEngineId() = "audio_service_engine"，shouldDestroyEngineWithHost()
 * 返回 false）。于是「ZenFile 在后台未关闭」时系统会销毁 Activity，但进程、FlutterEngine
 * 与 Dart isolate 全部存活：
 *   - Flutter 对 cached engine 会**跳过 Dart 入口**（doInitialFlutterViewRun 直接 return），
 *     ⇒ Dart **不会**重新执行 main() / initState，只在 initState 里查一次 picker 状态的
 *     写法会永远停在上一次的结果。这就是「冷启动能进选择器、后台复用却进不去」的根因。
 *   - 新的 MainActivity 实例会重新走 onCreate / configureFlutterEngine，它写下的状态必须
 *     能被 Dart 立刻读到；而注册 channel 的可能是旧实例、读状态的可能是新实例，
 *     所以状态与 channel 必须共享（静态）。
 * Dart 侧配合：回到前台（AppLifecycleState.resumed）时主动补查一次 getPickerInfo。
 */
object SystemFilePickerBridge {

    /** 当前活跃的 Activity 实例（setResult / finish 用）。随每个实例的 onCreate 更新。 */
    @Volatile
    private var activity: Activity? = null

    @Volatile
    private var channel: MethodChannel? = null

    /** 本次是否由第三方 App 以「选文件」为目的调起。 */
    @Volatile
    var isPickerLaunch = false
        private set

    /** 调起方是否允许多选（Intent.EXTRA_ALLOW_MULTIPLE）。 */
    @Volatile
    var allowMultiple = false
        private set

    /** 调起方要求的 MIME 类型（可能是通配类型或 null，即不限制）。 */
    @Volatile
    var mimeType: String? = null
        private set

    /** 登记当前 Activity 实例，保证 setResult / finish 打到最新的那个。 */
    fun attach(activity: Activity) {
        this.activity = activity
    }

    /** 主动把 picker 请求推给 Dart 侧；Dart 未注册处理器时静默忽略。 */
    private fun pushToDart() {
        val ch = channel
        ch?.invokeMethod(
            "onPickerIntent",
            mapOf(
                "isPicker" to true,
                "allowMultiple" to allowMultiple,
                "mime" to mimeType
            )
        )
    }

    /**
     * 读取 intent，判定是否为系统文件选择器模式。
     *
     * [notifyDart] 为 true 时，若 Dart 侧已经注册了处理器，还会主动把这次的 picker
     * 请求推给它。用于 `onNewIntent`：MainActivity 是 singleTask，ZenFile 已在后台时
     * 第三方调起不会走 onCreate，只有靠主动推送才能让 Dart 侧切到选文件界面。
     * ⚠️ 推送只是「快一步」的优化，**不是**唯一通路 —— Activity 被系统销毁后重建时
     * 不会回调 onNewIntent，只能靠 Dart 回到前台时补查（见文件头说明）。
     */
    fun onLaunchIntent(activity: Activity, intent: Intent?, notifyDart: Boolean = false) {
        attach(activity)
        val action = intent?.action
        val isPicker = action == Intent.ACTION_GET_CONTENT ||
            action == Intent.ACTION_PICK ||
            action == Intent.ACTION_OPEN_DOCUMENT
        if (!isPicker) {
            // 🔴 这个 else 分支不能省：缓存引擎下 Dart isolate 会跨多次启动存活，
            // 若上一轮的选择器状态不复位，下次普通启动（点桌面图标 / 通知）就会被
            // Dart 的补查误判成「又来选文件了」，界面卡在选择器宿主页。
            resetLaunchState()
            return
        }
        isPickerLaunch = true
        allowMultiple = intent?.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false) ?: false
        mimeType = intent?.type
        if (notifyDart) pushToDart()
    }

    /**
     * 选文件流程结束后复位，避免「已完成的请求」被下一次补查误判成仍在进行中
     * （Dart 侧回到前台会补查 getPickerInfo）。
     */
    private fun resetLaunchState() {
        isPickerLaunch = false
        allowMultiple = false
        mimeType = null
    }

    /** 注册供 Dart 侧调用的通道。 */
    fun registerChannel(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        channel?.setMethodCallHandler { call, rawResult ->
            val result = rawResult.replyOnce()
            when (call.method) {
                "getPickerInfo" -> {
                    result.success(
                        mapOf(
                            "isPicker" to isPickerLaunch,
                            "allowMultiple" to allowMultiple,
                            "mime" to mimeType
                        )
                    )
                }
                "finishPick" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    result.success(deliverPickedFiles(paths))
                }
                "cancelPick" -> {
                    activity?.setResult(Activity.RESULT_CANCELED)
                    resetLaunchState()
                    activity?.finish()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把 Dart 侧选中的文件路径转成 ZenFileDocumentsProvider 的 document URI 回传给调起方。
     * 仅支持 /storage/emulated/0 下的路径 —— 与 provider 暴露的 root 保持一致。
     * @return 是否成功回传；false 表示没有任何可用 URI（已按「取消」处理）。
     */
    private fun deliverPickedFiles(paths: List<String>): Boolean {
        val act = activity ?: return false
        val limited = if (allowMultiple) paths else paths.take(1)
        val uris = limited.mapNotNull { path -> buildDocumentUriForPath(act, path) }
        if (uris.isEmpty()) {
            // 选中的文件不在 provider 暴露的内部存储 root 下，无法回传可读取的 URI。
            Toast.makeText(act, R.string.picker_only_internal_storage, Toast.LENGTH_LONG).show()
            act.setResult(Activity.RESULT_CANCELED)
            resetLaunchState()
            act.finish()
            return false
        }
        val data = Intent()
        if (uris.size == 1) {
            data.data = uris[0]
        } else {
            // 多选：ClipData 承载全部 URI，同时保留 data 指向第一个
            // （兼容只读 Intent.data 的老调用方）。
            val clip = ClipData.newUri(act.contentResolver, "ZenFile", uris[0])
            for (i in 1 until uris.size) {
                clip.addItem(ClipData.Item(uris[i]))
            }
            data.clipData = clip
            data.data = uris[0]
        }
        // OPEN_DOCUMENT 的调用方通常会 takePersistableUriPermission() 长期持有这个 URI
        // （例如把选中的文件记进自己的数据库），少了 PERSISTABLE 标记那次调用会失败。
        // GET_CONTENT 场景带上也无害。
        data.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        data.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        act.setResult(Activity.RESULT_OK, data)
        resetLaunchState()
        act.finish()
        return true
    }

    /**
     * 文件路径 → ZenFileDocumentsProvider 的 document URI。
     * docId 规则与 ZenFileDocumentsProvider.getDocIdForFile() 严格一致（rootId = "primary"）。
     */
    private fun buildDocumentUriForPath(act: Activity, path: String): Uri? {
        val abs = File(path).absolutePath
        if (!abs.startsWith(ROOT)) return null
        var rel = abs.substring(ROOT.length)
        if (rel.startsWith("/")) rel = rel.substring(1)
        if (rel.isEmpty()) return null
        val authority = "${act.packageName}$DOCUMENTS_AUTHORITY_SUFFIX"
        return DocumentsContract.buildDocumentUri(authority, "primary:$rel")
    }

    private const val CHANNEL = "com.sequl.zenfile/file_picker"
    private const val ROOT = "/storage/emulated/0"
    // 与 AndroidManifest 中 provider 的 android:authorities="${applicationId}.documents" 一致
    private const val DOCUMENTS_AUTHORITY_SUFFIX = ".documents"
}
