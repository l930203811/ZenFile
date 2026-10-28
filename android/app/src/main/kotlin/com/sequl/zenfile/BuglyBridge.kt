package com.sequl.zenfile

import android.content.Context
import android.os.Environment
import android.util.Log
import com.tencent.bugly.crashreport.CrashReport
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import xcrash.XCrash

/**
 * 腾讯 Bugly 异常上报桥。
 *
 * ## 职责划分
 * - **原生崩溃（Java/Kotlin/NDK）**：Bugly SDK 自动捕获，无需任何桥接 ——
 *   [init] 完成后即生效（含 ANR）。
 * - **Dart 层异常**：Flutter 的 Dart 异常 Bugly 看不见，由 Dart 侧全局错误
 *   处理器（`lib/main.dart` 的 `FlutterError.onError` / `runZonedGuarded`）
 *   经本通道转发，以「非致命异常」形式上报，见 [registerChannel]。
 *
 * ## 时机
 * [init] 在 `MainActivity.onCreate` 的 `super` 之前调用（与
 * `CrashForensics.captureOnStartup` 同一位置之后）—— 越早安装默认处理器，
 * 引擎初始化 / libflutter.so 加载阶段的崩溃越可能被捕获。
 *
 * ## App ID
 * 需在 bugly.qq.com 注册应用（包名 `com.sequl.zenfile2`）后填入 [APP_ID]。
 * 为空时**完全跳过初始化与通道处理**，零开销、不产生任何网络请求 ——
 * 所以没有 App ID 也能正常构建发布。
 */
object BuglyBridge {
    private const val TAG = "BuglyBridge"

    /// App ID 来自 bugly.qq.com（产品 ZenFile，包名 com.sequl.zenfile2）。
    private const val APP_ID = "dbb3af8ad6"

    private var channel: MethodChannel? = null

    /** 初始化 SDK。App ID 为空时跳过 Bugly（xCrash 本地捕获不受影响）。 */
    fun init(context: Context) {
        // ① xCrash 本地 tombstone（不依赖 App ID）：
        //    云电脑环境无法 USB 调试，native 崩溃堆栈靠本地文件交付。
        //    必须先于 Bugly 初始化 —— 后装的信号处理器先执行，捕获后 rethrow
        //    会链到 xCrash 的处理器，双方都能记录。
        try {
            val logDir = File(Environment.getExternalStorageDirectory(), "ZenFile/crash")
            if (!logDir.exists()) logDir.mkdirs()
            XCrash.init(
                context.applicationContext,
                XCrash.InitParameters()
                    .setLogDir(logDir.absolutePath)
                    .setAnrCheckProcessState(false)
                    .setNativeDumpAllThreads(true)
                    .setNativeDumpAllThreadsCountMax(50)
                    // ART 的 abort 转储（线程快照）很长，200 行会把开头的
                    // 错误原因（如 JNI DETECTED ERROR）截掉，放大到 1000。
                    .setNativeLogcatMainLines(1000)
                    .setJavaLogcatMainLines(1000),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "xCrash init failed", t)
        }

        if (APP_ID.isBlank()) return
        try {
            // 第三个参数 isDebug=false：release/正式行为，不上报开发期噪音。
            // NDK 原生崩溃（SIGSEGV/SIGABRT 等）：4.x 无需单独初始化，
            // 只要 nativecrashreport 依赖在 classpath 上即随 initCrashReport 自动开启。
            CrashReport.initCrashReport(
                context.applicationContext, APP_ID, false)
        } catch (t: Throwable) {
            Log.e(TAG, "Bugly init failed", t)
        }
    }

    /**
     * 注册 Dart → 原生的异常转发通道。
     *
     * postException 传来的 Dart 异常以 `Exception(message + stack)` 形式交给
     * `CrashReport.postCatchedException`（非致命异常面板可见），不中断进程。
     */
    fun registerChannel(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "com.sequl.zenfile/bugly").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "postException" -> {
                        try {
                            val message = call.argument<String>("message").orEmpty()
                            val stack = call.argument<String>("stack").orEmpty()
                            val throwable = RuntimeException(
                                if (stack.isBlank()) message else "$message\n$stack"
                            )
                            CrashReport.postCatchedException(throwable)
                        } catch (t: Throwable) {
                            android.util.Log.e(TAG, "postException failed", t)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
