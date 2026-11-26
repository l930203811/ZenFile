package com.lucasjosino.on_audio_query.controllers

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.lucasjosino.on_audio_query.PluginProvider
import com.lucasjosino.on_audio_query.interfaces.PermissionManagerInterface
import io.flutter.Log
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class PermissionController : PermissionManagerInterface,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val TAG: String = "PermissionController"

        private const val REQUEST_CODE: Int = 88560
    }

    var retryRequest: Boolean = false

    // ZenFile fork patch (issue #95): 发起请求时捕获本次 call 的 result。
    // 上游在回调里读 PluginProvider.result()（单例最新值），弹窗期间若 Dart
    // 又发来新请求，会把回复写到别的 call 上，造成该 call 二次回复崩溃。
    private var pendingResult: MethodChannel.Result? = null

    private var permissions: Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_AUDIO,
                Manifest.permission.READ_MEDIA_IMAGES
            )
        } else {
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            )
        }

    override fun permissionStatus(): Boolean = permissions.all {
        // After "leaving" this class, context will be null so, we need this context argument to
        // call the [checkSelfPermission].
        return ContextCompat.checkSelfPermission(
            PluginProvider.context(),
            it
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun requestPermission() {
        Log.d(TAG, "Requesting permissions.")
        Log.d(TAG, "SDK: ${Build.VERSION.SDK_INT}, Should retry request: $retryRequest")
        if (pendingResult == null) {
            pendingResult = PluginProvider.result()
        }
        val activity = PluginProvider.activity()
        ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE)
    }

    // Second requestPermission, this one with the option "Never Ask Again".
    override fun retryRequestPermission() {
        val activity = PluginProvider.activity()
        if (ActivityCompat.shouldShowRequestPermissionRationale(activity, permissions[0])
            || ActivityCompat.shouldShowRequestPermissionRationale(activity, permissions[1])
        ) {
            Log.d(TAG, "Retrying permission request")
            retryRequest = false
            requestPermission()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        // When the incoming request code doesn't match the request codes defined by the on_audio_query
        // plugin return [false] to indicate the [on_audio_query] plugin is not handling the request
        // result and Android should continue executing other registered handlers.
        if (REQUEST_CODE != requestCode) return false

        // Check permission
        val isPermissionGranted = (grantResults.isNotEmpty()
                && grantResults[0] == PackageManager.PERMISSION_GRANTED)

        Log.d(TAG, "Permission accepted: $isPermissionGranted")

        // After all checks, we can handle the permission request.
        val result = pendingResult ?: PluginProvider.result()
        when {
            isPermissionGranted -> {
                pendingResult = null
                result.success(true)
            }
            retryRequest -> retryRequestPermission()
            else -> {
                pendingResult = null
                result.success(false)
            }
        }

        // Return [true] here to indicate that the [on_audio_query] plugin handled the permission request
        // result and Android should not continue executing other registered handlers.
        return true
    }
}