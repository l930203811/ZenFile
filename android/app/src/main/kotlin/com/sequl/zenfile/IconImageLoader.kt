package com.sequl.zenfile

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File

/**
 * 自定义图标图片的加载工具。
 *
 * 快捷方式图标与 1×1 小组件都需要把用户导入的任意图片处理成
 * 「正方形 + 已降采样」的位图：
 * - 正方形：图标容器是方的，非正方形图片必须居中裁剪，否则会被拉伸变形；
 * - 已降采样：避免把几千万像素的原图直接塞进 RemoteViews / Icon，
 *   否则会触发 binder 事务超限（TransactionTooLargeException）。
 */
object IconImageLoader {

    fun loadSquare(file: File, size: Int): Bitmap? {
        return try {
            if (!file.exists()) return null

            // 第一遍只读尺寸，用于计算采样率（不真正解码像素，内存安全）
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            var sampleSize = 1
            while (bounds.outWidth / (sampleSize * 2) >= size &&
                bounds.outHeight / (sampleSize * 2) >= size
            ) {
                sampleSize *= 2
            }

            val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            val decoded = BitmapFactory.decodeFile(file.absolutePath, decodeOptions) ?: return null

            // 居中裁剪成正方形
            val side = minOf(decoded.width, decoded.height)
            val square = if (decoded.width == decoded.height) {
                decoded
            } else {
                Bitmap.createBitmap(
                    decoded,
                    (decoded.width - side) / 2,
                    (decoded.height - side) / 2,
                    side,
                    side
                ).also { if (it !== decoded) decoded.recycle() }
            }

            if (square.width == size && square.height == size) {
                square
            } else {
                Bitmap.createScaledBitmap(square, size, size, true).also {
                    if (it !== square) square.recycle()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}
