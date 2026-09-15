package com.sequl.zenfile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import java.io.File

/**
 * 1×1 启动小组件：用用户导入的图片作为桌面图标，点击即启动 App。
 *
 * 为什么用小组件而不是直接换主图标：
 * Android 的桌面主图标必须是打包进 APK 的**编译期资源**（`android:icon` 只能引用
 * 资源 ID），系统没有公开 API 允许用运行时图片替换它。而小组件由启动器自己绘制，
 * 图片走 RemoteViews 传给启动器，因此可以承载任意用户图片 —— 这是绕开该限制的
 * 唯一通用方案（Shortcut 快捷方式在部分 ROM 上会被禁，小组件则全启动器可用）。
 */
class ZenFileIconWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context))
        }
    }

    companion object {
        /** 与 Flutter 端 shared_preferences 的存储约定一致（文件 + 前缀）。 */
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_KEY_CUSTOM_ICON_PATH = "flutter.custom_app_icon_path"

        /**
         * 1×1 小组件在最高密度屏上约 240px，256 足够清晰，
         * 同时远低于 binder 事务上限（约 1MB），不会有 TransactionTooLargeException。
         */
        private const val IMAGE_SIZE = 256

        /**
         * 解析用户自定义图标文件：
         * 优先读 Flutter 端保存的路径；读不到再回退到约定目录，保证小组件单独
         * 被系统拉起（进程重建、Dart 未跑起来）时也能拿到图片。
         */
        fun resolveCustomIconFile(context: Context): File? {
            val saved = try {
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .getString(PREF_KEY_CUSTOM_ICON_PATH, null)
            } catch (e: Exception) {
                null
            }
            if (!saved.isNullOrEmpty()) {
                val file = File(saved)
                if (file.exists()) return file
            }
            val fallback = File(context.filesDir, "custom_icons/custom_app_icon.png")
            return if (fallback.exists()) fallback else null
        }

        fun buildViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_launcher_icon)

            resolveCustomIconFile(context)?.let { iconFile ->
                IconImageLoader.loadSquare(iconFile, IMAGE_SIZE)?.let { bitmap ->
                    views.setImageViewBitmap(R.id.widget_icon_image, bitmap)
                }
            }

            // 点击启动 App（API 31+ 起 PendingIntent 必须显式声明可变性）
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_IMMUTABLE else 0)
            val pendingIntent = PendingIntent.getActivity(context, 0, launchIntent, pendingFlags)
            views.setOnClickPendingIntent(R.id.widget_icon_root, pendingIntent)

            return views
        }

        /** 换图后刷新桌面上所有已添加的本小组件。 */
        fun refreshAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, ZenFileIconWidgetProvider::class.java)
                )
                if (ids.isEmpty()) return
                val views = buildViews(context)
                for (id in ids) {
                    manager.updateAppWidget(id, views)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
