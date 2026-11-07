package com.sequl.zenfile

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * HEIC/HEIF 的「安全解码」桥（issue #61）。
 *
 * 背景：Flutter engine 在 Android 上对 Skia 不认识的格式（相机 HEIC/HEIF）会
 * 交给 `AndroidImageGenerator`：Java 侧 `ImageDecoder` **整幅全尺寸解码**，
 * 忽略 Dart 传下来的 cacheWidth / ResizeImage；一旦 Java 抛异常（OOM、
 * 10-bit HDR、损坏数据），engine 的
 * `android_image_generator.cc(117) FML_CHECK(fml::jni::CheckException(env))`
 * 直接 SIGABRT —— Dart 侧 try/catch、errorBuilder、ResizeImage 全都兜不住。
 *
 * 这里绕开 engine 那条路径：自己在**单线程**里用 `ImageDecoder` 降采样解码，
 * `try/catch (Throwable)` 把包括 OutOfMemoryError 在内的异常全部吃掉，再把
 * 结果压成普通 JPEG 字节交回 Dart（Skia 解码，绝不再触发 ImageGenerator）。
 *
 * 关键点：
 *  1. `ALLOCATOR_SOFTWARE` —— 避免 HARDWARE bitmap，且能被 setTargetSampleSize 采样；
 *  2. `MEMORY_POLICY_LOW_RAM` —— 降低解码期间的堆峰值；
 *  3. 单线程 executor —— 列表里几十张 HEIC 并发全尺寸解码正是 OOM 的元凶；
 *  4. `Throwable` 全捕获 —— 失败只返回 null（Dart 显示格式图标），绝不 abort。
 */
object HeifDecoderBridge {
    private const val CHANNEL = "com.sequl.zenfile/heif_decoder"
    private const val MAX_SOURCE_BYTES = 120L * 1024 * 1024

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "zenfile-heif").apply { isDaemon = true }
    }

    fun registerChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "decode") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val side = call.argument<Int>("side") ?: 2048
            if (path.isNullOrEmpty()) {
                result.success(null)
                return@setMethodCallHandler
            }
            worker.execute {
                // decodeToJpeg 内部已捕异常；外层再兜一层，保证 result 一定被回复。
                val reply = try {
                    decodeToJpeg(path, side.coerceIn(64, 4096))
                } catch (_: Throwable) {
                    null
                }
                mainHandler.post { result.success(reply) }
            }
        }
    }

    /**
     * 返回 `[bytes, width, height]`：bytes 为降采样后的 JPEG，width/height 为
     * **原始**尺寸（供「适应高度」显示模式计算缩放，不受降采样影响）。
     * 任何失败都返回 null。
     */
    @SuppressLint("NewApi")
    private fun decodeToJpeg(path: String, targetSide: Int): Map<String, Any>? {
        // ImageDecoder 需要 API 28；更低版本上系统本身也不会产生 HEIC 照片。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val file = File(path)
        if (!file.isFile || file.length() > MAX_SOURCE_BYTES) return null

        var decoded: Bitmap? = null
        var converted: Bitmap? = null
        return try {
            var sourceWidth = 0
            var sourceHeight = 0
            decoded = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                sourceWidth = info.size.width
                sourceHeight = info.size.height
                val longest = max(sourceWidth, sourceHeight)
                // sample 必须是 2 的幂；按长边把目标位图限制在 targetSide 内，
                // 峰值内存 ≈ targetSide² × 4B，与原始像素数无关。
                var sample = 1
                while (longest / sample > targetSide && sample < 64) sample *= 2
                if (sample > 1) decoder.setTargetSampleSize(sample)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.memorySizePolicy = ImageDecoder.MEMORY_POLICY_LOW_RAM
            }
            val src = decoded ?: return null

            // 10-bit HDR HEIF 可能给到 RGBA_F16 / HARDWARE，不能直接压 JPEG；
            // 统一落到 ARGB_8888（带 alpha 的先铺白底）。此时尺寸已降采样，
            // 这次额外分配最多十几 MB，安全。
            val target = if (src.config == Bitmap.Config.ARGB_8888 && !src.hasAlpha()) {
                src
            } else {
                val flat = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(flat)
                canvas.drawColor(Color.WHITE)
                canvas.drawBitmap(src, 0f, 0f, null)
                converted = flat
                flat
            }

            val out = ByteArrayOutputStream()
            if (!target.compress(Bitmap.CompressFormat.JPEG, 88, out)) return null
            mapOf(
                "bytes" to out.toByteArray(),
                "width" to sourceWidth,
                "height" to sourceHeight,
            )
        } catch (_: Throwable) {
            null
        } finally {
            try { converted?.recycle() } catch (_: Throwable) {}
            try { decoded?.recycle() } catch (_: Throwable) {}
        }
    }
}
