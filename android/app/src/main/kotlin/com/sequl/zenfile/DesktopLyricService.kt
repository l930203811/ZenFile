package com.sequl.zenfile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 桌面歌词悬浮窗管理服务
 *
 * 通过 [WindowManager] 在系统层级显示单行歌词悬浮窗，
 * 支持逐字高亮（SpannableStringBuilder）、拖动调整位置、
 * 右下角拖拽调整窗口大小、单击切换播放/暂停。
 *
 * 使用前必须先通过 [checkOverlayPermission] / [requestOverlayPermission] 获取
 * [Settings.canDrawOverlays] 权限（即 SYSTEM_ALERT_WINDOW）。
 */
object DesktopLyricService {

    private const val TAG = "DesktopLyricService"

    /** MethodChannel 名称，注册在 MainActivity 中 */
    const val CHANNEL = "com.sequl.zenfile/desktop_lyric"

    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var container: LinearLayout? = null
    private var lyricTextView: TextView? = null
    private var resizeHandle: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** 当前是否已显示悬浮窗 */
    private var isShowing = false

    /** 悬浮窗初始位置 */
    private var initX = 0
    private var initY = 200

    /** 当前窗口宽度（px），可由用户拖拽缩放 */
    private var windowWidthPx: Int = 0

    /** 当前文字大小（sp），随窗口宽度等比例缩放 */
    private var textSizeSp: Float = 16f

    /** 默认最小/最大文字大小 */
    private val minTextSizeSp = 12f
    private val maxTextSizeSp = 36f

    /** 默认窗口宽度（占屏幕宽度的比例） */
    private val defaultWidthRatio = 0.85f

    /** MethodChannel 引用，用于将悬浮窗上的点击事件回传 Flutter */
    private var channel: MethodChannel? = null

    /** 持有 Activity 引用，用于权限请求与 WindowManager 操作 */
    private var hostActivity: Activity? = null

    /** 当前高亮颜色（已唱部分） */
    private var highlightColor = 0xFFFF8800.toInt()

    /** 当前普通色（未唱部分） */
    private var normalColor = 0xCCFFFFFF.toInt()

    /** 当前歌词文本 */
    private var currentText: String = ""

    /** 当前高亮字符数（逐字高亮） */
    private var currentHighlightLen: Int = 0

    /**
     * 在 [MainActivity.configureFlutterEngine] 中调用，注册所有方法。
     */
    fun register(activity: Activity, messenger: BinaryMessenger) {
        hostActivity = activity
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> result.success(checkOverlayPermission(activity))
                "requestPermission" -> {
                    requestOverlayPermission(activity)
                    result.success(true)
                }
                "show" -> {
                    val text = call.argument<String>("text") ?: ""
                    val x = (call.argument<Number>("x")?.toInt()) ?: 0
                    val y = (call.argument<Number>("y")?.toInt()) ?: 200
                    (call.argument<Number>("highlightColor")?.toInt())?.let { highlightColor = it }
                    (call.argument<Number>("normalColor")?.toInt())?.let { normalColor = it }
                    initX = x
                    initY = y
                    show(activity, text)
                    result.success(true)
                }
                "hide" -> {
                    hide()
                    result.success(true)
                }
                "updateLyric" -> {
                    val text = call.argument<String>("text") ?: ""
                    val highlightLen = (call.argument<Number>("highlightLen")?.toInt()) ?: 0
                    (call.argument<Number>("highlightColor")?.toInt())?.let { highlightColor = it }
                    (call.argument<Number>("normalColor")?.toInt())?.let { normalColor = it }
                    updateLyric(text, highlightLen)
                    result.success(true)
                }
                "isShowing" -> result.success(isShowing)
                "setPosition" -> {
                    val x = (call.argument<Number>("x")?.toInt()) ?: 0
                    val y = (call.argument<Number>("y")?.toInt()) ?: 200
                    initX = x
                    initY = y
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 在 MainActivity.onDestroy 中调用，清理引用 */
    fun unregister() {
        hide()
        hostActivity = null
        channel = null
    }

    // ─── 权限相关 ─────────────────────────────────────────────────────────

    /** 是否已获取悬浮窗权限 */
    fun checkOverlayPermission(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    /** 跳转系统"显示在其他应用上层"设置页 */
    fun requestOverlayPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(activity)) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${activity.packageName}")
                )
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                Toast.makeText(activity, "请授予悬浮窗权限后重试", Toast.LENGTH_LONG).show()
            }
        }
    }

    // ─── 悬浮窗显示 / 隐藏 ──────────────────────────────────────────────

    /** 显示悬浮窗。若已显示则仅更新文本。 */
    @Synchronized
    fun show(context: Context, text: String) {
        if (isShowing) {
            updateLyric(text, 0)
            return
        }
        // 防御：清理可能残留的旧 View（系统 detach 后 rootView 仍非 null 的情况）
        if (rootView != null) {
            try {
                rootView?.let { windowManager?.removeView(it) }
            } catch (_: Exception) {
            }
            rootView = null
            container = null
            lyricTextView = null
            resizeHandle = null
            layoutParams = null
        }
        if (!checkOverlayPermission(context)) {
            Toast.makeText(context, "未授予悬浮窗权限", Toast.LENGTH_SHORT).show()
            return
        }

        currentText = text
        currentHighlightLen = 0

        windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

        // 计算默认窗口宽度
        val displayMetrics = context.resources.displayMetrics
        val screenWidth = displayMetrics.widthPixels
        windowWidthPx = (screenWidth * defaultWidthRatio).toInt().coerceAtLeast(200)

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        // 根容器：FrameLayout，包含歌词容器 + 缩放手柄
        rootView = FrameLayout(context).apply {
            background = createRoundedBackground()
        }

        // 歌词容器：LinearLayout 水平排列，包含一个 TextView
        container = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(28, 14, 28, 14)
            gravity = Gravity.CENTER_VERTICAL
        }

        lyricTextView = TextView(context).apply {
            setText(buildSpannableText(text, currentHighlightLen))
            textSize = textSizeSp
            typeface = Typeface.DEFAULT_BOLD
            setShadowLayer(6f, 1f, 1f, Color.BLACK)
            maxLines = 1
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.END
            gravity = Gravity.CENTER
        }
        container?.addView(
            lyricTextView,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { gravity = Gravity.CENTER_VERTICAL }
        )

        // 缩放手柄：右下角小方块
        resizeHandle = View(context).apply {
            background = createResizeHandleDrawable()
            visibility = View.GONE  // 默认隐藏，长按时显示
        }
        val handleSize = (24 * displayMetrics.density).toInt()

        // 将歌词容器添加到 FrameLayout（占满）
        rootView?.addView(
            container,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        // 将缩放手柄添加到 FrameLayout 右下角
        rootView?.addView(
            resizeHandle,
            FrameLayout.LayoutParams(handleSize, handleSize, Gravity.BOTTOM or Gravity.END)
        )

        val params = WindowManager.LayoutParams(
            windowWidthPx,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = initX
            y = initY
        }
        layoutParams = params

        // 拖动 + 点击 + 缩放事件
        setupTouchListener(rootView!!, params, context)
        setupResizeListener(resizeHandle!!, rootView!!, params, context)

        // 监听 View 被 WindowManager 意外 detach（系统回收、内存压力等），
        // 此时自动重置 isShowing，让 Flutter 端心跳检测到并恢复。
        rootView?.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {}
            override fun onViewDetachedFromWindow(v: View) {
                // 系统主动 detach（非 hide() 触发）→ 重置状态
                if (isShowing) {
                    isShowing = false
                    // 不主动置空 rootView 等，避免 hide() 二次 removeView 抛异常
                    // 下次 show() 会先清理再重建
                }
            }
        })

        try {
            windowManager?.addView(rootView, params)
            isShowing = true
        } catch (e: Exception) {
            // addView 失败时清理残留引用，避免下次 show() 误判
            rootView = null
            container = null
            lyricTextView = null
            resizeHandle = null
            layoutParams = null
            Toast.makeText(context, "悬浮窗显示失败：${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    /** 隐藏并销毁悬浮窗 */
    @Synchronized
    fun hide() {
        if (!isShowing && rootView == null) {
            // 已彻底清理，仅兜底
            isShowing = false
            return
        }
        try {
            rootView?.let { windowManager?.removeView(it) }
        } catch (_: Exception) {
        }
        rootView = null
        container = null
        lyricTextView = null
        resizeHandle = null
        layoutParams = null
        windowManager = null
        isShowing = false
    }

    /** 更新歌词文本与逐字高亮位置 */
    @Synchronized
    fun updateLyric(text: String, highlightLen: Int) {
        currentText = text
        currentHighlightLen = highlightLen
        // 防御：若悬浮窗已被系统回收，不做无意义操作，让 Flutter 心跳检测到并恢复
        if (!isShowing || rootView == null) return
        lyricTextView?.let { tv ->
            tv.post {
                tv.setText(buildSpannableText(text, highlightLen))
            }
        }
    }

    // ─── 私有：构建 Spannable 文本（逐字高亮） ────────────────────────────

    /**
     * 构建 [SpannableStringBuilder]，前 [highlightLen] 个字符使用高亮色，
     * 其余使用普通色。实现逐字卡拉OK效果。
     */
    private fun buildSpannableText(text: String, highlightLen: Int): SpannableStringBuilder {
        if (text.isEmpty()) return SpannableStringBuilder("")
        val ssb = SpannableStringBuilder(text)
        val safeLen = highlightLen.coerceIn(0, text.length)

        if (safeLen > 0) {
            ssb.setSpan(
                ForegroundColorSpan(highlightColor),
                0, safeLen,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        if (safeLen < text.length) {
            ssb.setSpan(
                ForegroundColorSpan(normalColor),
                safeLen, text.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        return ssb
    }

    // ─── 私有：创建圆角背景 ──────────────────────────────────────────────

    private fun createRoundedBackground(): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = 28f
            setColor(Color.parseColor("#80000000"))
            setStroke(1, Color.parseColor("#33FFFFFF"))
        }
    }

    private fun createResizeHandleDrawable(): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = 6f
            setColor(Color.parseColor("#66FFFFFF"))
        }
    }

    // ─── 私有：拖动与点击监听 ────────────────────────────────────────────

    /**
     * 触摸事件：
     * - 单击（未拖动）→ 通知 Flutter 切换播放/暂停
     * - 长按 → 显示缩放手柄
     * - 拖动 → 移动悬浮窗位置
     */
    private fun setupTouchListener(
        view: View,
        params: WindowManager.LayoutParams,
        context: Context
    ) {
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        var hasMoved = false
        var downTime = 0L

        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params.x
                    initialY = params.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    hasMoved = false
                    downTime = System.currentTimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (dx > 4 || dy > 4) hasMoved = true
                    params.x = initialX + dx.toInt()
                    params.y = initialY + dy.toInt()
                    windowManager?.updateViewLayout(view, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val elapsed = System.currentTimeMillis() - downTime
                    if (!hasMoved) {
                        if (elapsed > 500) {
                            // 长按：切换缩放手柄可见性
                            resizeHandle?.visibility = if (resizeHandle?.visibility == View.VISIBLE) View.GONE else View.VISIBLE
                        } else {
                            // 单击：通知 Flutter 切换播放/暂停
                            channel?.invokeMethod("onLyricClick", null)
                        }
                    }
                    true
                }
                else -> false
            }
        }
    }

    // ─── 私有：缩放手柄拖拽监听 ──────────────────────────────────────────

    /**
     * 缩放手柄拖拽：改变窗口宽度，文字大小等比例缩放。
     */
    private fun setupResizeListener(
        handle: View,
        root: View,
        params: WindowManager.LayoutParams,
        context: Context
    ) {
        var startWidth = 0
        var startTextSize = 0f
        var startTouchX = 0f

        handle.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startWidth = params.width
                    startTextSize = textSizeSp
                    startTouchX = event.rawX
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - startTouchX
                    val newWidth = (startWidth + dx).toInt().coerceAtLeast(180)

                    // 文字大小随宽度等比例缩放
                    val ratio = newWidth.toFloat() / startWidth.toFloat()
                    val newTextSize = (startTextSize * ratio).coerceIn(minTextSizeSp, maxTextSizeSp)

                    params.width = newWidth
                    windowWidthPx = newWidth
                    textSizeSp = newTextSize

                    lyricTextView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, newTextSize)
                    windowManager?.updateViewLayout(root, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    // 重新渲染以更新截断
                    lyricTextView?.let { tv ->
                        tv.post {
                            tv.text = buildSpannableText(currentText, currentHighlightLen)
                        }
                    }
                    true
                }
                else -> false
            }
        }
    }
}
