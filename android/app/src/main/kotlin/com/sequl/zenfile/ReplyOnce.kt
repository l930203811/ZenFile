package com.sequl.zenfile

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MethodChannel.Result 防重回复包装。
 *
 * 修复 issue #51：`IllegalStateException: Reply already submitted` 崩溃。
 * 某些 handler 存在多条执行路径（成功/失败/超时/Shizuku 回调 + onActivityResult
 * 等异步回调）可能对同一个 [MethodChannel.Result] 调用两次 success/error，
 * 第二次调用会直接抛 IllegalStateException 导致闪退。
 *
 * 此扩展返回一个只放行第一次回复的代理 Result：后续所有 success/error/
 * notImplemented 调用都被静默忽略。所有 method call handler 的 result
 * 都应经过 [replyOnce] 包装。
 */
fun MethodChannel.Result.replyOnce(): MethodChannel.Result {
    val replied = AtomicBoolean(false)
    return object : MethodChannel.Result {
        override fun success(res: Any?) {
            if (replied.compareAndSet(false, true)) {
                this@replyOnce.success(res)
            }
        }

        override fun error(code: String, msg: String?, details: Any?) {
            if (replied.compareAndSet(false, true)) {
                this@replyOnce.error(code, msg, details)
            }
        }

        override fun notImplemented() {
            if (replied.compareAndSet(false, true)) {
                this@replyOnce.notImplemented()
            }
        }
    }
}
