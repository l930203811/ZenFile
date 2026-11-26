package com.lucasjosino.on_audio_query

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * ZenFile fork patch (issue #95): 防重回复包装。
 *
 * 上游存在多条路径对同一个 Result 回复两次（无权限分支 error 后未 return、
 * scan 空路径 success(false) 后未 return、权限回调读到被新请求覆盖的 result），
 * 第二次回复抛 IllegalStateException: Reply already submitted 直接闪退。
 * 此代理只放行第一次回复，后续 success/error/notImplemented 静默忽略。
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