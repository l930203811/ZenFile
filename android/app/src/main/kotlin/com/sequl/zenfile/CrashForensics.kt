package com.sequl.zenfile

import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 启动期崩溃取证 —— 无 adb 环境下的「黑匣子」。
 *
 * ## 为什么要它
 * 用户反馈「打开应用就闪退」时，我们拿不到任何现场：云电脑没有无线 adb、release 包
 * 又不带 logcat。此前只能靠 `WebdavDebugLog` 的**启动里程碑**推断「崩在哪一步」，
 * 但它有两个盲区：
 *  1. 崩在 Dart 之前（引擎 / native / Activity 初始化）时，**一行日志都不会有**，
 *     解释不了原因；
 *  2. 用户装的是 release 包，日志开关默认关闭 —— 要他先开开关再复现，等于让他先
 *     装一个诊断版。
 *
 * 本模块用 Android 官方 [ApplicationExitInfo]（API 30+）把「上次进程为什么死」的
 * 权威记录在**下次启动的最早时机**落盘，用户零操作。关键点：**记录是系统留的，
 * 与我们的 Dart 代码是否跑得起来无关** —— 这正是「启动即崩」场景唯一的抓手。
 *
 * ## 时机
 * [capture] 在 `MainActivity.attachBaseContext()` 里调用（比 `onCreate` 更早，
 * 在 `super.onCreate()` 创建 FlutterEngine、加载 libflutter.so **之前**）。
 * 因此即使崩溃发生在 native 库加载/引擎初始化期间，本模块也已经把上一次的记录
 * 与**本次启动的尝试**写完了 —— 下次再启动就能看到「上次崩在这一段」。
 *
 * ## 落盘策略（双目录，互为兜底）
 * - 私有目录 `filesDir/crash_forensics/`：**无需任何权限、必然可写**，是权威存档。
 *   崩溃反复发生时报告也不会丢。
 * - 公共目录 `/storage/emulated/0/ZenFile/crash/`：与 `webdav_debug.log` 同处，
 *   用户用任意文件管理器即可取出。需要存储权限，故由 Dart 侧启动后主动触发导出
 *   （见 [exportToPublic]），失败也不影响私有存档。
 *
 * ## 幂等
 * 报告文件名含崩溃时间戳（`exit_<毫秒>_<reason>.txt`）。同一次崩溃在之后的每一次
 * 启动里都会被系统列出来，靠「文件已存在就跳过」天然去重。
 *
 * ## 「补拷」与「用户删了就别再补回来」（suppress 名单）
 * 私有存档是**唯一真相**，公共目录只是镜像 ⇒ 公共目录里缺什么就补什么。但这带来一个
 * 反直觉的后果：**用户把 `ZenFile/crash/` 清空后，下次启动会把旧报告原样补回来**
 * （2026-09-28 用户实测反馈「删了又出现一堆，以为又崩了」）。清空应用数据也治不好 ——
 * 私有文件一没，[collectViaExitInfo] 又会从系统历史里重新导入。
 *
 * 因此导出时接受一份 [suppress] 名单：**曾被交付过、但现在不在公共目录里**的报告名，
 * 视为「用户主动删掉的」，**不再补拷**。名单由 Dart 侧持久化维护（见
 * `CrashForensicsService.checkPreviousExit`），本类**不引入任何持久化状态** ——
 * 它的失败模式必须始终是「退化成本次多拷一份」，而不是「静默丢失证据」。
 *
 * ## 安全约束
 * - 全部入口 `try/catch (Throwable)`：取证绝不能成为新的崩溃源。
 * - API 30+ 的调用全部隔离在 [TargetApi] 方法内，且调用点有 `SDK_INT` 判断，
 *   保证 API<30 设备上 [ApplicationExitInfo] 这个类**永不被加载**。
 * - 只读、只写自己的目录，不申请新权限、不联网。
 */
object CrashForensics {

    private const val TAG = "ZenFileCrash"

    /** 私有存档目录名（位于 `filesDir` 下）。 */
    private const val DIR_NAME = "crash_forensics"

    /**
     * trace（ANR trace / native tombstone）最多写入的字节数。
     *
     * ⚠️ 曾是 48KB —— issue #50（TECNO KJ6 ANR）的教训：ANR trace 的线程按
     * tid 排序，Flutter 的 `1.ui`（Dart isolate）线程排在列表**中后段**，
     * 48KB 恰好把它截掉，导致「主线程空闲但 KeyEvent 5s 无回执」的 ANR
     * 无法看到 UI isolate 当时在忙什么。128KB 可完整覆盖典型 56 线程的
     * ANR trace（全量约 60~80KB），多读的几十 KB 内存对启动无感。
     */
    private const val MAX_TRACE_BYTES = 128 * 1024

    /** 私有目录最多保留的报告数（超出删最旧）。 */
    private const val MAX_PRIVATE_FILES = 40

    /** 公共目录最多保留的报告数。 */
    private const val MAX_PUBLIC_FILES = 20

    /** 单次取最多回溯多少条系统退出记录。 */
    private const val MAX_EXIT_RECORDS = 25

    /** 从报告文件名里抽时间戳用（见 [stampOf]）。 */
    private val DIGITS_REGEX = Regex("\\d+")

    // ── ApplicationExitInfo 的 reason 常量 ─────────────────────────────
    //
    // 刻意写成**字面量**而不是 `ApplicationExitInfo.REASON_*`：那些常量随 API 30
    // 的类一起出现，写成字面量可以让「本文件在 API<30 上绝不触碰该类」这件事
    // 一眼可查（常量引用虽会被内联，但代码审查时看不出差别，本项目已在 Android
    // 的 @hide / 版本差异上栽过跟头）。
    private const val REASON_EXIT_SELF = 1
    private const val REASON_SIGNALED = 2
    private const val REASON_LOW_MEMORY = 3
    private const val REASON_CRASH = 4
    private const val REASON_CRASH_NATIVE = 5
    private const val REASON_ANR = 6
    private const val REASON_INITIALIZATION_FAILURE = 7

    /**
     * 「值得出报告」的退出原因。
     *
     * 刻意**不包含** `REASON_EXIT_SELF`（正常自杀，如任务栈清空）、
     * `REASON_USER_REQUESTED`（用户要求停止）、`REASON_LOW_MEMORY`（系统回收，
     * 每个后台应用都会有，全是噪音）。只留真正代表「异常死亡」的四类。
     */
    private val INTERESTING = setOf(
        REASON_CRASH,               // Java/Kotlin 未捕获异常
        REASON_CRASH_NATIVE,        // native 崩溃（libflutter / libmpv / SIGSEGV）
        REASON_ANR,                 // 无响应被系统杀掉
        REASON_INITIALIZATION_FAILURE, // 进程初始化失败（含引擎/类加载层面）
    )

    // ══════════════════════════════════════════════════════════════════
    //  入口
    // ══════════════════════════════════════════════════════════════════

    /**
     * 在 `MainActivity.attachBaseContext()` 里调用：装上 Java 未捕获异常兜底，
     * 并把系统记录的上次异常退出落盘。
     *
     * 这个方法**同步**执行少量 IO（读 binder 列表 + 写几 KB 文件）。刻意如此：
     * 放进协程/线程会让「应用崩在取证之前」重新变成可能，而这点开销是毫秒级的。
     */
    @JvmStatic
    fun captureOnStartup(context: Context) {
        installJavaHandler(context)
        capture(context)
    }

    /**
     * 读取系统记录的异常退出并落盘（幂等，可重复调用）。
     *
     * 只读 [ActivityManager.getHistoricalProcessExitReasons]，不清理系统记录 ——
     * 去重靠文件名，因此重复调用是安全的。
     */
    @JvmStatic
    fun capture(context: Context) {
        try {
            // 写成 `>= R` 的正向判断（而不是早退）：Lint 的版本流分析对前者识别
            // 最可靠，能确保 API 30+ 的调用不会在低版本设备上被判为可达。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                collectViaExitInfo(context)
            } else {
                // API < 30 没有 ApplicationExitInfo。此时 Java 层崩溃仍由
                // [installJavaHandler] 覆盖，但 native 崩溃（SIGSEGV）取不到。
                writeUnsupportedNote(context)
            }
        } catch (t: Throwable) {
            // 取证失败绝不能影响启动。
            Log.w(TAG, "capture failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /**
     * 把私有存档复制到用户可取的公共目录（`/storage/emulated/0/ZenFile/crash/`）。
     *
     * 由 Dart 侧在启动后调用（那时存储权限的状态才是确定的）。**目标已存在就跳过**，
     * 于是返回值里的「新增份数」天然表示「本次真的冒出了新报告」，调用方据此决定
     * 要不要提示用户。
     *
     * [suppress] = **不要补回**的报告名（Dart 侧持久化的台账减去公共目录现状 ⇒
     * 即「用户已删过的那些」，详见类注释）。名单里的文件明知私有目录有、也**不拷**，
     * 并计入返回值的 `suppressed` 一项，便于事后解释「为什么我的报告没回来」。
     *
     * 返回：`ok:<新增>:<跳过>:<抑制>:<目录>` / `no-reports` / `mkdir-failed:<目录>` /
     * `error:<异常名>:<消息>`。**永不抛异常**。
     */
    @JvmStatic
    fun exportToPublic(context: Context, suppress: Set<String>): String {
        return try {
            val src = privateDir(context)
            if (!src.isDirectory) return "no-reports"
            val files = src.listFiles { f -> f.isFile && f.name.endsWith(".txt") }
            if (files.isNullOrEmpty()) return "no-reports"

            val dst = publicDir()
            if (!dst.isDirectory && !dst.mkdirs()) {
                return "mkdir-failed:${dst.absolutePath}"
            }
            var added = 0
            var skipped = 0
            var suppressed = 0
            for (f in files) {
                val target = File(dst, f.name)
                if (target.exists()) {
                    skipped++
                    continue
                }
                // 曾被交付、现在不在公共目录里 ⇒ 用户主动删的 ⇒ 不再补回。
                // 判定只看**文件名**：文件名含崩溃时间戳，同一份报告恒同名。
                if (f.name in suppress) {
                    suppressed++
                    continue
                }
                try {
                    f.copyTo(target, overwrite = false)
                    added++
                } catch (_: Throwable) {
                    // 单个文件失败不影响其余
                }
            }
            trimDir(dst, MAX_PUBLIC_FILES)
            "ok:$added:$skipped:$suppressed:${dst.absolutePath}"
        } catch (t: Throwable) {
            "error:${t.javaClass.simpleName}:${t.message}"
        }
    }

    /** 归档目录概况，供诊断日志使用（`private=12:filesDir/...;public=...`）。 */
    @JvmStatic
    fun describe(context: Context): String {
        return try {
            val p = privateDir(context)
            val n = p.listFiles { f -> f.isFile && f.name.endsWith(".txt") }?.size ?: 0
            "private=$n:${p.absolutePath};public=${publicDir().absolutePath}"
        } catch (t: Throwable) {
            "error:${t.javaClass.simpleName}:${t.message}"
        }
    }

    /**
     * 注册 Dart ↔ 原生通道。
     *
     * 放在本类而不是 `MainActivity` 里，是为了让 `MainActivity.kt`（CRLF、体积大、
     * 多 AI 并发的热点文件）只增加一行调用。
     *
     * `context` 由注册方传入并立刻取 `applicationContext` 保存 —— 通道回调里拿不到
     * Activity，也不该持有它。**刻意不用反射 `ActivityThread.currentApplication()`**：
     * 那是 `@hide` API，本项目已明文禁止（编译/运行期都可能炸，而 `flutter analyze`
     * 完全不覆盖 Kotlin，只在真机构建时才暴露）。
     */
    @JvmStatic
    fun registerChannel(messenger: BinaryMessenger, context: Context) {
        val appCtx = try {
            context.applicationContext ?: context
        } catch (_: Throwable) {
            context
        }
        MethodChannel(messenger, "com.sequl.zenfile/crash_forensics").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // 触发一次取证（幂等）+ 导出到公共目录，返回结果描述。
                    // 参数 = 「不要补回」的报告名列表（用户已删过的那些），见 [exportToPublic]。
                    "exportToPublicDir" ->
                        result.success(exportToPublic(appCtx, readSuppressNames(call.arguments)))
                    // Dart 侧未捕获错误落盘（Dart 自己也会直接写公共目录，这里是兜底）。
                    "recordDartError" -> {
                        val args = call.arguments as? Map<*, *>
                        val kind = args?.get("kind") as? String ?: "DartError"
                        val message = args?.get("message") as? String ?: ""
                        val stack = args?.get("stack") as? String ?: ""
                        result.success(recordDartError(appCtx, kind, message, stack))
                    }
                    "describe" -> result.success(describe(appCtx))
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("CRASH_FORENSICS_ERROR", t.message, null)
            }
        }
    }

    /**
     * 从通道参数里取「不要补回」的报告名集合（用户已删过的那些）。
     *
     * 刻意做得极其宽容：参数缺失、类型不对、甚至是别的形状，一律**退化成空集**
     * （= 维持旧的全量补拷行为）。取证链路上「多拷一份」是可接受的，
     * 「因为参数异常而少拷一份证据」才是不可接受的。
     */
    private fun readSuppressNames(args: Any?): Set<String> {
        return try {
            when (args) {
                null -> emptySet()
                // Dart 直接传 `List<String>`（最简形态）
                is List<*> -> args.filterIsInstance<String>().toSet()
                // 也接受 `{"suppress": [...]}`，便于将来加别的参数
                is Map<*, *> ->
                    (args["suppress"] as? List<*>)?.filterIsInstance<String>()?.toSet() ?: emptySet()
                else -> emptySet()
            }
        } catch (_: Throwable) {
            emptySet()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Java 未捕获异常兜底
    // ══════════════════════════════════════════════════════════════════
    private class JavaCrashHandler(
        private val appCtx: Context,
        private val previous: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(t: Thread, e: Throwable) {
            try {
                val body = buildString {
                    append(header(appCtx, "Java/Kotlin 未捕获异常"))
                    append("线程  : ${t.name}\n")
                    append("异常  : ${e.javaClass.name}\n")
                    append("消息  : ${e.message ?: "-"}\n")
                    append("\n--- stacktrace ---\n")
                    // Log.getStackTraceString 是 Android 公开 API，会把 cause 链一起打出来
                    append(Log.getStackTraceString(e))
                }
                writeReport(appCtx, "java_crash_${System.currentTimeMillis()}.txt", body)
            } catch (_: Throwable) {
                // 兜底的兜底
            }
            // 链式调用原有 handler：绝不吞掉系统/其它库的默认行为（否则会掩盖
            // 真正的崩溃对话框，让问题更难查）。
            previous?.uncaughtException(t, e)
        }
    }

    private fun installJavaHandler(context: Context) {
        try {
            val appCtx = context.applicationContext ?: context
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            // 幂等：重复安装会让 handler 链条越来越长
            if (previous is JavaCrashHandler) return
            Thread.setDefaultUncaughtExceptionHandler(JavaCrashHandler(appCtx, previous))
        } catch (t: Throwable) {
            Log.w(TAG, "installJavaHandler failed: ${t.message}")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  ApplicationExitInfo（API 30+）
    // ══════════════════════════════════════════════════════════════════

    @TargetApi(Build.VERSION_CODES.R)
    private fun collectViaExitInfo(context: Context) {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val records: List<ApplicationExitInfo> =
            am.getHistoricalProcessExitReasons(context.packageName, 0, MAX_EXIT_RECORDS)
        val dir = privateDir(context)
        for (info in records) {
            if (info.reason !in INTERESTING) continue
            val name = "exit_${info.timestamp}_${info.reason}.txt"
            // 幂等：同一次崩溃在之后的每次启动都会被列出，已取证过就跳过。
            if (File(dir, name).exists()) continue
            writeReport(context, name, buildExitReport(context, info))
        }
        trimDir(dir, MAX_PRIVATE_FILES)
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun buildExitReport(context: Context, info: ApplicationExitInfo): String {
        return buildString {
            append(header(context, "进程异常退出（${reasonName(info.reason)}）"))
            append("崩溃时间  : ${formatTime(info.timestamp)}\n")
            append("时间戳    : ${info.timestamp}\n")
            append("原因码    : ${info.reason}  (${reasonName(info.reason)})\n")
            append("status    : ${info.status}\n")
            append("importance: ${info.importance}\n")
            append("pid       : ${info.pid}\n")
            append("description: ${info.description ?: "-"}\n")
            append("\n--- trace（最多 ${MAX_TRACE_BYTES / 1024}KB）---\n")
            append(readTrace(info))
        }
    }

    /**
     * 读取崩溃 trace。
     *
     * `REASON_CRASH_NATIVE` 时这里是 **tombstone**（含崩溃线程的寄存器与调用栈），
     * `REASON_ANR` 时是 ANR trace（全部线程的栈）—— 这两样正是判断「崩在 native
     * 库还是 Dart」最直接的证据。截断到 [MAX_TRACE_BYTES] 仍是必要的：极端场景
     * （几百线程 + 巨型 ANR trace）全写会拖慢启动；上限已按 issue #50 教训从
     * 48KB 提到 128KB，保证 Flutter `1.ui` 线程段不被切掉（见常量注释）。
     */
    @TargetApi(Build.VERSION_CODES.R)
    private fun readTrace(info: ApplicationExitInfo): String {
        return try {
            val stream = info.traceInputStream ?: return "(系统未提供 trace)"
            stream.use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(8 * 1024)
                var total = 0
                while (total < MAX_TRACE_BYTES) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    val take = minOf(n, MAX_TRACE_BYTES - total)
                    out.write(buf, 0, take)
                    total += take
                }
                val text = String(out.toByteArray(), Charsets.UTF_8)
                if (text.isBlank()) "(trace 为空)" else text
            }
        } catch (t: Throwable) {
            "(读取 trace 失败: ${t.javaClass.simpleName}: ${t.message})"
        }
    }

    private fun reasonName(code: Int): String = when (code) {
        REASON_EXIT_SELF -> "EXIT_SELF（正常退出）"
        REASON_SIGNALED -> "SIGNALED（被信号杀死）"
        REASON_LOW_MEMORY -> "LOW_MEMORY（内存不足被回收）"
        REASON_CRASH -> "CRASH（Java/Kotlin 未捕获异常）"
        REASON_CRASH_NATIVE -> "CRASH_NATIVE（native 崩溃）"
        REASON_ANR -> "ANR（无响应）"
        REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE（进程初始化失败）"
        else -> "OTHER($code)"
    }

    // ══════════════════════════════════════════════════════════════════
    //  Dart 侧错误
    // ══════════════════════════════════════════════════════════════════

    /**
     * 记录一条 Dart 层未捕获错误。
     *
     * 说明：Dart 层错误通常**不会**杀死进程（Flutter 默认只打印），所以它多半不会
     * 出现在 [ApplicationExitInfo] 里；但它经常是「用户看到的异常表现」的根源，
     * 且可能发生在 native 崩溃之前（日志能给出时间顺序）。因此单独留档。
     */
    private fun recordDartError(ctx: Context, kind: String, message: String, stack: String): String {
        return try {
            val body = buildString {
                append(header(ctx, "Dart 未捕获错误（$kind）"))
                append("错误  : $message\n")
                append("\n--- stack ---\n")
                append(stack.ifBlank { "(无 stack)" })
            }
            val name = "dart_error_${System.currentTimeMillis()}.txt"
            writeReport(ctx, name, body)
            // ⚠️ 只镜像**这一份新报告**，刻意不做全量补拷：全量补拷必须带上 Dart 侧
            // 维护的抑制名单，而这里拿不到它 —— 若在此处全量补拷，就会把用户已经删掉
            // 的旧报告一并补回来，正是本次要修的那个现象。
            mirrorToPublic(File(privateDir(ctx), name))
            "ok:$name"
        } catch (t: Throwable) {
            "error:${t.javaClass.simpleName}:${t.message}"
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  通用工具
    // ══════════════════════════════════════════════════════════════════

    private fun privateDir(context: Context): File = File(context.filesDir, DIR_NAME)

    private fun publicDir(): File =
        File(Environment.getExternalStorageDirectory(), "ZenFile/crash")

    /**
     * 把**单个**私有报告镜像到公共目录（不触碰其余文件）。
     *
     * 与 [exportToPublic] 的全量补拷刻意分开：全量补拷必须携带 Dart 侧给的抑制名单
     * （用户删过的旧报告不再补回），而「刚写下一份新证据、让它立刻可见」这条路径不需要
     * 那个名单，也**绝不能**变成一次全量补拷 —— 否则会把用户删掉的旧报告一起带回来。
     *
     * 目标已存在、公共目录建不出来、单个文件拷失败，一律静默返回 false：
     * 私有存档才是权威，镜像失败不影响取证。
     */
    private fun mirrorToPublic(srcFile: File): Boolean {
        return try {
            if (!srcFile.isFile) return false
            val dst = publicDir()
            if (!dst.isDirectory && !dst.mkdirs()) return false
            val target = File(dst, srcFile.name)
            if (target.exists()) return false
            srcFile.copyTo(target, overwrite = false)
            trimDir(dst, MAX_PUBLIC_FILES)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** 报告统一抬头：把「哪个包、什么机型、哪个 Android」先钉死。 */
    private fun header(context: Context, title: String): String {
        return buildString {
            append("==================== ZenFile 崩溃取证 ====================\n")
            append("类型      : $title\n")
            append("生成时间  : ${formatTime(System.currentTimeMillis())}\n")
            append("包名      : ${context.packageName}\n")
            append("版本      : ${versionText(context)}\n")
            append("安装时间  : ${installTimeText(context)}\n")
            append("Android   : ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})\n")
            append("机型      : ${Build.MANUFACTURER} ${Build.MODEL}\n")
            append("ABI       : ${Build.SUPPORTED_ABIS.joinToString(",")}\n")
            append("product/hardware: ${Build.PRODUCT} / ${Build.HARDWARE}\n")
            append("==========================================================\n")
        }
    }

    private fun versionText(context: Context): String {
        return try {
            val pi = context.packageManager.getPackageInfo(context.packageName, 0)
            // ⚠️ longVersionCode 是 API 28+ 的 getter；minSdk 24，必须判版本，
            //    否则 24~27 的设备上会 NoSuchMethodError（本项目已规定：改原生
            //    侧必须逐条自查 API 可见性）。
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pi.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pi.versionCode.toLong()
            }
            "${pi.versionName ?: "?"} (code $code)"
        } catch (t: Throwable) {
            "?"
        }
    }

    private fun installTimeText(context: Context): String {
        return try {
            val pi = context.packageManager.getPackageInfo(context.packageName, 0)
            formatTime(pi.lastUpdateTime)
        } catch (t: Throwable) {
            "?"
        }
    }

    /**
     * 写一份报告到私有目录（固定文件名 ⇒ 天然幂等）。
     *
     * 刻意**不**在这里记录「每次启动都写一行」的时间线：那会制造噪音（每个正常
     * 启动都产出一个文件）。「本次启动走到哪一步」由 Dart 侧的 `[boot]` 里程碑
     * 日志负责，两份日志按时间戳对照即可还原「上次崩在哪一段」。
     */
    private fun writeReport(context: Context, name: String, body: String) {
        try {
            val dir = privateDir(context)
            if (!dir.isDirectory && !dir.mkdirs()) return
            File(dir, name).writeText(body, Charsets.UTF_8)
        } catch (t: Throwable) {
            Log.w(TAG, "writeReport($name) failed: ${t.message}")
        }
    }

    /** API<30 的设备写一份说明（固定文件名，只写一次）。 */
    private fun writeUnsupportedNote(context: Context) {
        try {
            val dir = privateDir(context)
            val f = File(dir, "unsupported_sdk${Build.VERSION.SDK_INT}.txt")
            if (f.exists()) return
            val body = buildString {
                append(header(context, "本机不支持自动取证"))
                append("\n本机 Android SDK = ${Build.VERSION.SDK_INT}，低于 30。\n")
                append("ApplicationExitInfo 自 API 30（Android 11）起才提供，")
                append("故无法读取系统记录的「上次异常退出原因」。\n")
                append("Java/Kotlin 未捕获异常仍会被记录（文件名以 java_crash_ 开头）；\n")
                append("但 native 崩溃（含 libflutter / libmpv 的 SIGSEGV）在本机取不到。\n")
            }
            if (!dir.isDirectory && !dir.mkdirs()) return
            f.writeText(body, Charsets.UTF_8)
        } catch (_: Throwable) {
        }
    }

    /**
     * 目录内 `*.txt` 超过 [max] 时删最旧的。
     *
     * ⚠️ **必须按文件名里的时间戳排，不能按 `lastModified()`**（2026-09-28 修）：
     * 公共目录里的文件基本是一次性镜像补拷出来的，mtime 几乎相同 ⇒ 排序退化成任意序
     * ⇒ 超限时可能**删掉最新那份、留下旧的**，恰好丢掉最有价值的那条证据。
     * 「私有存档攒到 [MAX_PRIVATE_FILES] 份 + 公共目录被清空」的场景正中这一点。
     */
    private fun trimDir(dir: File, max: Int) {
        try {
            val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".txt") } ?: return
            if (files.size <= max) return
            files.sortedBy { stampOf(it) }
                .take(files.size - max)
                .forEach { it.delete() }
        } catch (_: Throwable) {
        }
    }

    /**
     * 从文件名里取毫秒时间戳，取不到时退化成文件修改时间。
     *
     * 报告名形如 `exit_<毫秒>_<reason>.txt` / `java_crash_<毫秒>.txt` /
     * `dart_error_<毫秒>.txt`。**只取第一段数字**：若把后面的 reason 码也拼进来，
     * `exit_<13位>_10` 就成了 15 位数，会排在 `exit_<13位>_5` 这种 14 位数之后 ——
     * 于是「更旧的记录」反而被判成「更新」，排序又错回去了。
     */
    private fun stampOf(f: File): Long {
        return try {
            DIGITS_REGEX.find(f.name)?.value?.toLongOrNull() ?: f.lastModified()
        } catch (_: Throwable) {
            // 连 lastModified() 都抛（文件已消失等）：给 0，让它排在最前被优先删掉
            0L
        }
    }

    private fun formatTime(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(millis))
}
