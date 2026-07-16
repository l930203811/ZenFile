package com.sequl.zenfile

import android.content.pm.PackageManager
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.graphics.BitmapFactory
import android.provider.DocumentsContract
import android.graphics.drawable.Icon
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.ByteArrayOutputStream
import java.io.BufferedOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import androidx.core.app.NotificationCompat
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.app.usage.StorageStatsManager
import android.app.AppOpsManager
import android.os.storage.StorageManager
import android.os.Process

import android.media.MediaMetadataRetriever
import androidx.core.content.FileProvider
class MainActivity : AudioServiceFragmentActivity() {
    private val CHANNEL = "com.sequl.zenfile/root_shizuku"
    private val SHIZUKU_REQUEST_CODE = 10001
    private val executor = Executors.newCachedThreadPool()
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var safPermissionResult: MethodChannel.Result? = null
    private val SAF_REQUEST_CODE = 10002

    private val ACTION_CANCEL_OPERATION = "com.sequl.zenfile.ACTION_CANCEL_OPERATION"
    private var notificationsChannel: MethodChannel? = null

    private val cancelReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_CANCEL_OPERATION) {
                notificationsChannel?.invokeMethod("cancelOperationFromNotification", null)
            }
        }
    }

    private val onRequestPermissionResultListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == SHIZUKU_REQUEST_CODE) {
            val granted = grantResult == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            Shizuku.addBinderReceivedListenerSticky {
                // Binder ready
            }
            Shizuku.addRequestPermissionResultListener(onRequestPermissionResultListener)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        try {
            val filter = IntentFilter(ACTION_CANCEL_OPERATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(cancelReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(cancelReceiver, filter)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        try {
            Shizuku.removeRequestPermissionResultListener(onRequestPermissionResultListener)
        } catch (e: Exception) {
            e.printStackTrace()
        }
        try {
            unregisterReceiver(cancelReceiver)
        } catch (e: Exception) {
            e.printStackTrace()
        }
        try {
            DesktopLyricService.unregister()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SAF_REQUEST_CODE) {
            val result = safPermissionResult
            safPermissionResult = null
            if (resultCode == RESULT_OK && data != null) {
                val treeUri = data.data
                if (treeUri != null) {
                    try {
                        val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        contentResolver.takePersistableUriPermission(treeUri, takeFlags)
                        
                        var name = "SAF Drive"
                        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
                        contentResolver.query(docUri, null, null, null, null)?.use { cursor ->
                            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                            if (nameIndex != -1 && cursor.moveToFirst()) {
                                name = cursor.getString(nameIndex)
                            }
                        }

                        result?.success(mapOf(
                            "uri" to treeUri.toString(),
                            "name" to name
                        ))
                    } catch (e: Exception) {
                        result?.error("PERMISSION_ERROR", e.message, null)
                    }
                } else {
                    result?.success(null)
                }
            } else {
                result?.success(null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkStatus" -> {
                    executor.execute {
                        val isRootAvailable = checkRootAvailable()
                        var isShizukuAvailable = false
                        var shizukuPermissionGranted = false

                        try {
                            if (!Shizuku.pingBinder()) {
                                try {
                                    rikka.shizuku.ShizukuProvider.requestBinderForNonProviderProcess(this)
                                } catch (e: Throwable) {}
                            }
                            isShizukuAvailable = Shizuku.pingBinder()
                            if (isShizukuAvailable) {
                                shizukuPermissionGranted = Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                            }
                        } catch (e: Throwable) {
                            // Shizuku not installed or unavailable
                        }

                        val res = mapOf(
                            "isRootAvailable" to isRootAvailable,
                            "isShizukuAvailable" to isShizukuAvailable,
                            "shizukuPermissionGranted" to shizukuPermissionGranted
                        )
                        runOnUiThread { result.success(res) }
                    }
                }
                "getStorageSpace" -> {
                    val pathArg = call.argument<String>("path")
                    executor.execute {
                        try {
                            val path = pathArg ?: Environment.getExternalStorageDirectory().path
                            val stat = StatFs(path)
                            val blockSize = stat.blockSizeLong
                            val totalBlocks = stat.blockCountLong
                            val availableBlocks = stat.availableBlocksLong

                            val totalBytes = totalBlocks * blockSize
                            val availableBytes = availableBlocks * blockSize
                            val usedBytes = totalBytes - availableBytes

                            val res = mapOf(
                                "totalBytes" to totalBytes,
                                "availableBytes" to availableBytes,
                                "usedBytes" to usedBytes
                            )
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("STORAGE_ERROR", e.message, null) }
                        }
                    }
                }
                "requestShizukuPermission" -> {
                    try {
                        if (!Shizuku.pingBinder()) {
                            try {
                                rikka.shizuku.ShizukuProvider.requestBinderForNonProviderProcess(this)
                            } catch (e: Throwable) {}
                        }
                        if (Shizuku.pingBinder()) {
                            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                                result.success(true)
                            } else {
                                pendingPermissionResult = result
                                Shizuku.requestPermission(SHIZUKU_REQUEST_CODE)
                            }
                        } else {
                            pendingPermissionResult = result
                            Shizuku.requestPermission(SHIZUKU_REQUEST_CODE)
                        }
                    } catch (e: Throwable) {
                        e.printStackTrace()
                        result.success(false)
                    }
                }
                "runCommand" -> {
                    val command = call.argument<String>("command") ?: ""
                    val useRoot = call.argument<Boolean>("useRoot") ?: false

                    executor.execute {
                        try {
                            val output = runShellCommand(command, useRoot)
                            runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("EXEC_ERROR", e.message, null) }
                        }
                    }
                }
                "resolveContentUri" -> {
                    val uriString = call.argument<String>("uri") ?: ""
                    executor.execute {
                        try {
                            val uri = Uri.parse(uriString)
                            val contentResolver = applicationContext.contentResolver
                            
                            var fileName = "temp_file"
                            var mimeType = contentResolver.getType(uri) ?: ""
                            
                            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                if (nameIndex != -1 && cursor.moveToFirst()) {
                                    fileName = cursor.getString(nameIndex)
                                }
                            }

                            if (mimeType.isEmpty()) {
                                val ext = MimeTypeMap.getFileExtensionFromUrl(uriString)
                                if (ext != null) {
                                    mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: ""
                                }
                            }

                            val cacheDir = applicationContext.cacheDir
                            val prefix = "incoming_" + System.currentTimeMillis() + "_"
                            val ext = if (fileName.contains(".")) {
                                "." + fileName.substringAfterLast(".")
                            } else {
                                ""
                            }
                            
                            val tempFile = File.createTempFile(prefix, ext, cacheDir)
                            
                            contentResolver.openInputStream(uri)?.use { inputStream ->
                                FileOutputStream(tempFile).use { outputStream ->
                                    inputStream.copyTo(outputStream)
                                }
                            }

                            val res = mapOf(
                                "success" to true,
                                "cachePath" to tempFile.absolutePath,
                                "fileName" to fileName,
                                "mimeType" to mimeType
                            )
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("RESOLVE_ERROR", e.message, null) }
                        }
                    }
                }
                "writeContentUri" -> {
                    val uriString = call.argument<String>("uri") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    executor.execute {
                        try {
                            val uri = Uri.parse(uriString)
                            val contentResolver = applicationContext.contentResolver
                            
                            contentResolver.openOutputStream(uri, "w")?.use { outputStream ->
                                outputStream.write(content.toByteArray(Charsets.UTF_8))
                            }

                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("WRITE_ERROR", e.message, null) }
                        }
                    }
                }
                "getInstalledApps" -> {
                    val includeSystem = call.argument<Boolean>("includeSystem") ?: false
                    executor.execute {
                        try {
                            val apps = getInstalledApps(includeSystem)
                            runOnUiThread { result.success(apps) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("APP_LIST_ERROR", e.message, null) }
                        }
                    }
                }
                "getAppIcon" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    executor.execute {
                        try {
                            val bytes = getAppIcon(packageName)
                            runOnUiThread { result.success(bytes) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ICON_ERROR", e.message, null) }
                        }
                    }
                }
                "getApkIcon" -> {
                    val apkPath = call.argument<String>("apkPath") ?: ""
                    executor.execute {
                        try {
                            val bytes = getApkIcon(apkPath)
                            runOnUiThread { result.success(bytes) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ICON_ERROR", e.message, null) }
                        }
                    }
                }
                "launchApp" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    executor.execute {
                        try {
                            val pm = packageManager
                            val intent = pm.getLaunchIntentForPackage(packageName)
                            if (intent != null) {
                                startActivity(intent)
                                runOnUiThread { result.success(true) }
                            } else {
                                runOnUiThread { result.error("LAUNCH_ERROR", "Launch intent not found", null) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("LAUNCH_ERROR", e.message, null) }
                        }
                    }
                }
                "openAppDetails" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    executor.execute {
                        try {
                            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DETAILS_ERROR", e.message, null) }
                        }
                    }
                }
                "uninstallApp" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    executor.execute {
                        try {
                            val intent = Intent(Intent.ACTION_DELETE).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("UNINSTALL_ERROR", e.message, null) }
                        }
                    }
                }
                "installSplitApks" -> {
                    val apkPaths = call.argument<List<String>>("apkPaths") ?: emptyList()
                    installSplitApks(apkPaths, result)
                }
                "checkUsageStatsPermission" -> {
                    val granted = isUsageStatsPermissionGranted()
                    result.success(granted)
                }
                "requestUsageStatsPermission" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PERMISSION_ERROR", e.message, null)
                    }
                }
                "changeAppIcon" -> {
                    val iconAlias = call.argument<String>("alias") ?: "com.sequl.zenfile.MainActivityDefault"
                    executor.execute {
                        try {
                            val aliases = listOf(
                                "com.sequl.zenfile.MainActivityDefault",
                                "com.sequl.zenfile.MainActivityDesign1",
                                "com.sequl.zenfile.MainActivityDesign2",
                                "com.sequl.zenfile.MainActivityDesign3",
                                "com.sequl.zenfile.MainActivityDesign4",
                                "com.sequl.zenfile.MainActivityDesign5",
                                "com.sequl.zenfile.MainActivityDesign6",
                                "com.sequl.zenfile.MainActivityDesign7",
                                "com.sequl.zenfile.MainActivityDesign8",
                                "com.sequl.zenfile.MainActivityDesign9",
                                "com.sequl.zenfile.MainActivityDesign10",
                                "com.sequl.zenfile.MainActivityDesign11",
                                "com.sequl.zenfile.MainActivityCustom"
                            )

                            for (alias in aliases) {
                                val componentName = android.content.ComponentName(packageName, alias)
                                val state = if (alias == iconAlias) {
                                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                                } else {
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                                }
                                packageManager.setComponentEnabledSetting(
                                    componentName,
                                    state,
                                    PackageManager.DONT_KILL_APP
                                )
                            }
                            
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ICON_ERROR", e.message, null) }
                        }
                    }
                }
                "generateMediaThumbnail" -> {
                    val filePath = call.argument<String>("filePath") ?: ""
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    executor.execute {
                        try {
                            val retriever = MediaMetadataRetriever()
                            retriever.setDataSource(filePath)
                            var bitmap: Bitmap? = null
                            if (isVideo) {
                                bitmap = retriever.getFrameAtTime(1000000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            } else {
                                val embeddedPicture = retriever.embeddedPicture
                                if (embeddedPicture != null) {
                                    bitmap = BitmapFactory.decodeByteArray(embeddedPicture, 0, embeddedPicture.size)
                                }
                            }
                            retriever.release()
                            if (bitmap != null) {
                                val scaledBitmap = if (bitmap.width > 300 || bitmap.height > 300) {
                                    val scale = 300f / maxOf(bitmap.width, bitmap.height)
                                    Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true)
                                } else {
                                    bitmap
                                }
                                val stream = ByteArrayOutputStream()
                                scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                                val bytes = stream.toByteArray()
                                runOnUiThread { result.success(bytes) }
                            } else {
                                runOnUiThread { result.success(null) }
                            }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.success(null) }
                        }
                    }
                }
                "addHomeScreenShortcut" -> {
                    executor.execute {
                        try {
                            val pathArg = call.argument<String>("path")
                            val customIconFile = if (!pathArg.isNullOrEmpty()) {
                                File(pathArg)
                            } else {
                                File(applicationContext.filesDir, "custom_icons/custom_app_icon.png")
                            }
                            if (!customIconFile.exists()) {
                                runOnUiThread { result.error("ICON_ERROR", "Custom icon not found", null) }
                                return@execute
                            }

                            val bitmap = android.graphics.BitmapFactory.decodeFile(customIconFile.absolutePath)
                            if (bitmap == null) {
                                runOnUiThread { result.error("ICON_ERROR", "Failed to decode custom icon", null) }
                                return@execute
                            }

                            runOnUiThread {
                                try {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        val shortcutManager = getSystemService(Context.SHORTCUT_SERVICE) as? ShortcutManager
                                    if (shortcutManager != null && shortcutManager.isRequestPinShortcutSupported) {
                                        val intent = Intent(this@MainActivity, MainActivity::class.java).apply {
                                            action = Intent.ACTION_MAIN
                                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                                        }
                                        val icon = Icon.createWithBitmap(bitmap)
                                        val shortcutInfo = ShortcutInfo.Builder(this@MainActivity, "zenfile_custom_shortcut")
                                            .setShortLabel("ZenFile")
                                            .setLongLabel("ZenFile")
                                            .setIcon(icon)
                                            .setIntent(intent)
                                            .build()
                                        shortcutManager.requestPinShortcut(shortcutInfo, null)
                                        result.success(true)
                                    } else {
                                        // Fallback for launchers that do not support pin shortcuts
                                        try {
                                            val shortcutIntent = Intent(this@MainActivity, MainActivity::class.java).apply {
                                                action = Intent.ACTION_MAIN
                                            }
                                            val intent = Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                                                putExtra(Intent.EXTRA_SHORTCUT_INTENT, shortcutIntent)
                                                putExtra(Intent.EXTRA_SHORTCUT_NAME, "ZenFile")
                                                putExtra(Intent.EXTRA_SHORTCUT_ICON, bitmap)
                                            }
                                            sendBroadcast(intent)
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("NOT_SUPPORTED", "Launcher does not support shortcut pinning", null)
                                        }
                                    }
                                    } else {
                                        // Fallback for older Android using broadcast
                                        val shortcutIntent = Intent(this@MainActivity, MainActivity::class.java).apply {
                                            action = Intent.ACTION_MAIN
                                        }
                                        val intent = Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                                            putExtra(Intent.EXTRA_SHORTCUT_INTENT, shortcutIntent)
                                            putExtra(Intent.EXTRA_SHORTCUT_NAME, "ZenFile")
                                            putExtra(Intent.EXTRA_SHORTCUT_ICON, bitmap)
                                        }
                                        sendBroadcast(intent)
                                        result.success(true)
                                    }
                                } catch (e: Exception) {
                                    result.error("SHORTCUT_ERROR", e.message, null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ICON_ERROR", e.message, null) }
                        }
                    }
                }
                "openWithChooser" -> {
                    val path = call.argument<String>("path") ?: ""
                    val mimeType = call.argument<String>("mimeType") ?: ""
                    executor.execute {
                        try {
                            val intent = Intent(Intent.ACTION_VIEW)
                            val uri: Uri
                            if (path.startsWith("http://") || path.startsWith("https://")) {
                                // HTTP(S) URL — 用于远程流式播放（VLC 等播放器可直接流式播放）
                                uri = Uri.parse(path)
                            } else if (path.startsWith("content://")) {
                                uri = Uri.parse(path)
                            } else {
                                // 本地文件路径 — 通过 FileProvider 转换为 content:// URI
                                val file = File(path)
                                if (!file.exists()) {
                                    runOnUiThread { result.error("FILE_NOT_FOUND", "File not found: $path", null) }
                                    return@execute
                                }
                                val authority = "${packageName}.fileprovider"
                                uri = FileProvider.getUriForFile(this@MainActivity, authority, file)
                                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }

                            if (mimeType.isNotEmpty()) {
                                intent.setDataAndType(uri, mimeType)
                            } else {
                                intent.data = uri
                            }
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

                            // 使用 Intent.createChooser 强制弹出系统选择器
                            // 即使已设默认应用也会弹出，让用户从所有可用应用中选择
                            val chooser = Intent.createChooser(intent, "打开方式").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(chooser)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("CHOOSER_ERROR", e.message, null) }
                        }
                    }
                }
                "openDirectory" -> {
                    val path = call.argument<String>("path") ?: ""
                    try {
                        val intent = Intent(Intent.ACTION_VIEW)
                        val uri = Uri.parse(path)
                        intent.setDataAndType(uri, "resource/folder")
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Fallback: try with DocumentsContract MIME type
                        try {
                            val intent = Intent(Intent.ACTION_VIEW)
                            val uri = Uri.parse(path)
                            intent.setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("OPEN_DIR_FAILED", "Failed to open directory: ${e2.message}", null)
                        }
                    }
                }
                "copyFile" -> {
                    val source = call.argument<String>("source") ?: ""
                    val dest = call.argument<String>("dest") ?: ""
                    executor.execute {
                        try {
                            val sourceFile = File(source)
                            val destFile = File(dest)
                            if (!destFile.parentFile?.exists()!!) {
                                destFile.parentFile?.mkdirs()
                            }
                            // 使用 cp 命令复制，比 Java I/O 更快更可靠
                            val process = ProcessBuilder("cp", source, dest).start()
                            val completed = process.waitFor(10, TimeUnit.MINUTES)
                            if (completed && process.exitValue() == 0) {
                                runOnUiThread { result.success(true) }
                            } else {
                                process.destroyForcibly()
                                // 降级到 Java I/O
                                try {
                                    sourceFile.inputStream().use { input ->
                                        destFile.outputStream().use { output ->
                                            input.copyTo(output, 65536)
                                        }
                                    }
                                    runOnUiThread { result.success(true) }
                                } catch (e2: Exception) {
                                    e2.printStackTrace()
                                    runOnUiThread { result.error("COPY_FAILED", e2.message, null) }
                                }
                            }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("COPY_FAILED", e.message, null) }
                        }
                    }
                }
                "createZip" -> {
                    val basePath = call.argument<String>("basePath") ?: ""
                    val splitPaths = call.argument<ArrayList<String>>("splitPaths") ?: ArrayList()
                    val destPath = call.argument<String>("destPath") ?: ""
                    executor.execute {
                        try {
                            val destFile = File(destPath)
                            if (!destFile.parentFile?.exists()!!) {
                                destFile.parentFile?.mkdirs()
                            }
                            val fos = FileOutputStream(destFile)
                            val zos = ZipOutputStream(BufferedOutputStream(fos))
                            val buffer = ByteArray(65536)
                            
                            val baseFile = File(basePath)
                            if (baseFile.exists()) {
                                val entry = ZipEntry("base.apk")
                                zos.putNextEntry(entry)
                                baseFile.inputStream().use { input ->
                                    var len: Int
                                    while (input.read(buffer).also { len = it } != -1) {
                                        zos.write(buffer, 0, len)
                                    }
                                }
                                zos.closeEntry()
                            }
                            
                            for (splitPath in splitPaths) {
                                val splitFile = File(splitPath)
                                if (splitFile.exists()) {
                                    val entry = ZipEntry(splitFile.name)
                                    zos.putNextEntry(entry)
                                    splitFile.inputStream().use { input ->
                                        var len: Int
                                        while (input.read(buffer).also { len = it } != -1) {
                                            zos.write(buffer, 0, len)
                                        }
                                    }
                                    zos.closeEntry()
                                }
                            }
                            
                            zos.close()
                            fos.close()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("ZIP_FAILED", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/saf").setMethodCallHandler { call, result ->
            when (call.method) {
                "requestSafDirectory" -> {
                    safPermissionResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        startActivityForResult(intent, SAF_REQUEST_CODE)
                    } catch (e: Exception) {
                        safPermissionResult = null
                        result.error("ACTIVITY_NOT_FOUND", "No application found to handle folder selection: ${e.message}", null)
                    }
                }
                "listDirectory" -> {
                    val rootUriStr = call.argument<String>("rootUri") ?: ""
                    val pathUriStr = call.argument<String>("pathUri") ?: ""
                    executor.execute {
                        try {
                            val rootUri = Uri.parse(rootUriStr)
                            val targetDocId = if (pathUriStr.isNotEmpty()) {
                                DocumentsContract.getDocumentId(Uri.parse(pathUriStr))
                            } else {
                                DocumentsContract.getTreeDocumentId(rootUri)
                            }
                            
                            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, targetDocId)
                            val resultList = mutableListOf<Map<String, Any>>()
                            
                            contentResolver.query(childrenUri, null, null, null, null)?.use { cursor ->
                                val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                                val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                                val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                                val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                                val dateIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                                
                                while (cursor.moveToNext()) {
                                    val childDocId = if (idIndex != -1) cursor.getString(idIndex) else ""
                                    val childName = if (nameIndex != -1) cursor.getString(nameIndex) else "unnamed"
                                    val mimeType = if (mimeIndex != -1) cursor.getString(mimeIndex) else ""
                                    val size = if (sizeIndex != -1) cursor.getLong(sizeIndex) else 0L
                                    val modified = if (dateIndex != -1) cursor.getLong(dateIndex) else 0L
                                    
                                    val childUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, childDocId)
                                    val isDir = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
                                    
                                    resultList.add(mapOf(
                                        "name" to childName,
                                        "path" to childUri.toString(),
                                        "isDirectory" to isDir,
                                        "size" to size,
                                        "modified" to modified
                                    ))
                                }
                            }
                            runOnUiThread { result.success(resultList) }
                        } catch (e: Exception) {
                            e.printStackTrace()
                            runOnUiThread { result.error("LIST_ERROR", e.message, null) }
                        }
                    }
                }
                "createDirectory" -> {
                    val rootUriStr = call.argument<String>("rootUri") ?: ""
                    val parentUriStr = call.argument<String>("parentUri") ?: ""
                    val name = call.argument<String>("name") ?: "New Folder"
                    executor.execute {
                        try {
                            val rootUri = Uri.parse(rootUriStr)
                            val parentDocId = if (parentUriStr.isNotEmpty()) {
                                DocumentsContract.getDocumentId(Uri.parse(parentUriStr))
                            } else {
                                DocumentsContract.getTreeDocumentId(rootUri)
                            }
                            val parentUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, parentDocId)
                            val newUri = DocumentsContract.createDocument(
                                contentResolver,
                                parentUri,
                                DocumentsContract.Document.MIME_TYPE_DIR,
                                name
                            )
                            runOnUiThread { result.success(newUri?.toString()) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CREATE_ERROR", e.message, null) }
                        }
                    }
                }
                "delete" -> {
                    val rootUriStr = call.argument<String>("rootUri") ?: ""
                    val uriStr = call.argument<String>("uri") ?: ""
                    executor.execute {
                        try {
                            val rootUri = Uri.parse(rootUriStr)
                            val docId = DocumentsContract.getDocumentId(Uri.parse(uriStr))
                            val docUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, docId)
                            val deleted = DocumentsContract.deleteDocument(contentResolver, docUri)
                            runOnUiThread { result.success(deleted) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DELETE_ERROR", e.message, null) }
                        }
                    }
                }
                "downloadFile" -> {
                    val rootUriStr = call.argument<String>("rootUri") ?: ""
                    val uriStr = call.argument<String>("uri") ?: ""
                    val localPath = call.argument<String>("localPath") ?: ""
                    executor.execute {
                        try {
                            val rootUri = Uri.parse(rootUriStr)
                            val docId = DocumentsContract.getDocumentId(Uri.parse(uriStr))
                            val docUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, docId)
                            
                            val file = File(localPath)
                            file.parentFile?.mkdirs()
                            
                            contentResolver.openInputStream(docUri)?.use { inputStream ->
                                FileOutputStream(file).use { outputStream ->
                                    inputStream.copyTo(outputStream)
                                }
                            }
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DOWNLOAD_ERROR", e.message, null) }
                        }
                    }
                }
                "uploadFile" -> {
                    val rootUriStr = call.argument<String>("rootUri") ?: ""
                    val parentUriStr = call.argument<String>("parentUri") ?: ""
                    val localPath = call.argument<String>("localPath") ?: ""
                    val fileName = call.argument<String>("fileName") ?: "file"
                    executor.execute {
                        try {
                            val rootUri = Uri.parse(rootUriStr)
                            val parentDocId = if (parentUriStr.isNotEmpty()) {
                                DocumentsContract.getDocumentId(Uri.parse(parentUriStr))
                            } else {
                                DocumentsContract.getTreeDocumentId(rootUri)
                            }
                            val parentUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, parentDocId)
                            
                            val ext = fileName.substringAfterLast(".", "")
                            val mimeType = if (ext.isNotEmpty()) {
                                MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase()) ?: "application/octet-stream"
                            } else {
                                "application/octet-stream"
                            }
                            
                            val docUri = DocumentsContract.createDocument(
                                contentResolver,
                                parentUri,
                                mimeType,
                                fileName
                            )
                            
                            if (docUri != null) {
                                val file = File(localPath)
                                contentResolver.openOutputStream(docUri)?.use { outputStream ->
                                    file.inputStream().use { inputStream ->
                                        inputStream.copyTo(outputStream)
                                    }
                                }
                                runOnUiThread { result.success(true) }
                            } else {
                                runOnUiThread { result.error("UPLOAD_ERROR", "Failed to create document in tree", null) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("UPLOAD_ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/gesture_exclusion").setMethodCallHandler { call, result ->
            if (call.method == "setSystemGestureExclusionRects") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val rectsArg = call.argument<List<Map<String, Int>>>("rects")
                    val exclusionRects = mutableListOf<android.graphics.Rect>()
                    if (rectsArg != null) {
                        for (r in rectsArg) {
                            val left = r["left"] ?: 0
                            val top = r["top"] ?: 0
                            val right = r["right"] ?: 0
                            val bottom = r["bottom"] ?: 0
                            exclusionRects.add(android.graphics.Rect(left, top, right, bottom))
                        }
                    }
                    runOnUiThread {
                        try {
                            window.decorView.systemGestureExclusionRects = exclusionRects
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                } else {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/ftp_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "startFtpService" -> {
                    val ip = call.argument<String>("ip") ?: "127.0.0.1"
                    val port = call.argument<Int>("port") ?: 9999
                    val title = call.argument<String>("title") ?: "ZenFile FTP Server"
                    val contentText = call.argument<String>("contentText") ?: "Running at ftp://$ip:$port"
                    try {
                        val intent = Intent(this, FtpForegroundService::class.java).apply {
                            putExtra("ip", ip)
                            putExtra("port", port)
                            putExtra("title", title)
                            putExtra("contentText", contentText)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopFtpService" -> {
                    try {
                        val intent = Intent(this, FtpForegroundService::class.java)
                        stopService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/web_sharing_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "startWebSharingService" -> {
                    val url = call.argument<String>("url") ?: "http://127.0.0.1:8080"
                    val isInternet = call.argument<Boolean>("isInternet") ?: false
                    val title = call.argument<String>("title") ?: if (isInternet) "ZenFile Internet Web Share" else "ZenFile Local Web Share"
                    val contentText = call.argument<String>("contentText") ?: "Running at $url"
                    try {
                        val intent = Intent(this, WebSharingForegroundService::class.java).apply {
                            putExtra("url", url)
                            putExtra("isInternet", isInternet)
                            putExtra("title", title)
                            putExtra("contentText", contentText)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopWebSharingService" -> {
                    try {
                        val intent = Intent(this, WebSharingForegroundService::class.java)
                        stopService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/permissions").setMethodCallHandler { call, result ->
            when (call.method) {
                "openManageExternalStorageSettings" -> {
                    try {
                        // 直接跳转到本应用的所有文件访问权限详情页
                        // 使用 ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION + package URI，
                        // 而不是 ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION（后者显示所有应用列表）
                        val intent = Intent(
                            android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:${packageName}")
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // 备用方案1：打开所有应用列表页面
                        try {
                            val intent = Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            // 备用方案2：打开应用详情设置页
                            try {
                                val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.parse("package:${packageName}")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (ex: Exception) {
                                result.error("OPEN_SETTINGS_FAILED", ex.message, null)
                            }
                        }
                    }
                }
                "isManageExternalStorageGranted" -> {
                    // 使用原生 Android API 直接检查权限，绕过 permission_handler 的缓存问题
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        android.os.Environment.isExternalStorageManager()
                    } else {
                        // Android 10 及以下不需要 MANAGE_EXTERNAL_STORAGE
                        true
                    }
                    result.success(granted)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/smb").setMethodCallHandler { call, result ->
            val smb = SmbService.instance
            executor.execute {
                try {
                    when (call.method) {
                        "connect" -> {
                            val host = call.argument<String>("host") ?: ""
                            val port = call.argument<Int>("port") ?: 445
                            val username = call.argument<String>("username") ?: ""
                            val password = call.argument<String>("password") ?: ""
                            val domain = call.argument<String>("domain") ?: ""
                            val sessionId = smb.connect(host, port, username, password, domain)
                            runOnUiThread { result.success(sessionId) }
                        }
                        "listDirectory" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val path = call.argument<String>("path") ?: "/"
                            val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
                            val items = smb.listDirectory(sessionId, path, forceRefresh)
                            runOnUiThread { result.success(items) }
                        }
                        "createDirectory" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val path = call.argument<String>("path") ?: ""
                            val res = smb.createDirectory(sessionId, path)
                            runOnUiThread { result.success(res) }
                        }
                        "createFile" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val path = call.argument<String>("path") ?: ""
                            val res = smb.createFile(sessionId, path)
                            runOnUiThread { result.success(res) }
                        }
                        "delete" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val path = call.argument<String>("path") ?: ""
                            val isDir = call.argument<Boolean>("isDir") ?: false
                            val res = smb.delete(sessionId, path, isDir)
                            runOnUiThread { result.success(res) }
                        }
                        "rename" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val oldPath = call.argument<String>("oldPath") ?: ""
                            val newPath = call.argument<String>("newPath") ?: ""
                            val res = smb.rename(sessionId, oldPath, newPath)
                            runOnUiThread { result.success(res) }
                        }
                        "downloadFile" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val remotePath = call.argument<String>("remotePath") ?: ""
                            val localPath = call.argument<String>("localPath") ?: ""
                            val res = smb.downloadFile(sessionId, remotePath, localPath)
                            runOnUiThread { result.success(res) }
                        }
                        "downloadRange" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val remotePath = call.argument<String>("remotePath") ?: ""
                            val localPath = call.argument<String>("localPath") ?: ""
                            val startByte = (call.argument<Number>("startByte") ?: 0).toLong()
                            val length = (call.argument<Number>("length") ?: 0).toLong()
                            val res = smb.downloadRange(sessionId, remotePath, localPath, startByte, length)
                            runOnUiThread { result.success(res) }
                        }
                        "uploadFile" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val localPath = call.argument<String>("localPath") ?: ""
                            val remotePath = call.argument<String>("remotePath") ?: ""
                            val res = smb.uploadFile(sessionId, localPath, remotePath)
                            runOnUiThread { result.success(res) }
                        }
                        "getFileSize" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val remotePath = call.argument<String>("remotePath") ?: ""
                            val size = smb.getFileSize(sessionId, remotePath)
                            runOnUiThread { result.success(size) }
                        }
                        "disconnect" -> {
                            val sessionId = call.argument<String>("sessionId") ?: ""
                            val res = smb.disconnect(sessionId)
                            runOnUiThread { result.success(res) }
                        }
                        else -> runOnUiThread { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                    runOnUiThread { result.error("SMB_ERROR", e.message, null) }
                }
            }
        }

        // 桌面歌词悬浮窗服务
        DesktopLyricService.register(this, flutterEngine.dartExecutor.binaryMessenger)

        notificationsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sequl.zenfile/notifications")
        notificationsChannel?.setMethodCallHandler { call, result ->
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channelId = "zenfile_archive_channel"
            val channelName = "ZenFile Archive Operations"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows progress of file compression and extraction"
                }
                notificationManager.createNotificationChannel(channel)
            }

            when (call.method) {
                "showProgressNotification" -> {
                    val id = call.argument<Int>("id") ?: 100
                    val title = call.argument<String>("title") ?: "Processing..."
                    val message = call.argument<String>("message") ?: ""
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    val indeterminate = call.argument<Boolean>("indeterminate") ?: false

                    var iconId = applicationContext.resources.getIdentifier("ic_launcher", "mipmap", packageName)
                    if (iconId == 0) {
                        iconId = android.R.drawable.ic_dialog_info
                    }

                    val cancelIntent = Intent(ACTION_CANCEL_OPERATION).apply {
                        setPackage(packageName)
                    }
                    val cancelPendingIntent = PendingIntent.getBroadcast(
                        this@MainActivity,
                        id,
                        cancelIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                    )

                    val openIntent = Intent(this@MainActivity, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    val openPendingIntent = PendingIntent.getActivity(
                        this@MainActivity,
                        0,
                        openIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                    )

                    val builder = NotificationCompat.Builder(this@MainActivity, channelId)
                        .setContentTitle(title)
                        .setContentText(message)
                        .setSmallIcon(iconId)
                        .setOngoing(progress < max)
                        .setAutoCancel(progress >= max)
                        .setContentIntent(openPendingIntent)

                    if (progress < max) {
                        builder.addAction(android.R.drawable.ic_menu_view, "Open", openPendingIntent)
                        builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelPendingIntent)
                    }

                    if (indeterminate) {
                        builder.setProgress(0, 0, true)
                    } else {
                        builder.setProgress(max, progress, false)
                    }

                    notificationManager.notify(id, builder.build())
                    result.success(true)
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: 100
                    notificationManager.cancel(id)
                    result.success(true)
                }
                "checkAudioChannelStatus" -> {
                    // 检查 audio_service 的通知渠道是否被禁用
                    // 返回 Map: {"enabled": bool, "importance": int, "exists": bool}
                    val audioChannelId = "com.sequl.zenfile.audio"
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val channel = notificationManager.getNotificationChannel(audioChannelId)
                        if (channel == null) {
                            // 渠道不存在，audio_service 可能尚未创建
                            result.success(mapOf("exists" to false, "enabled" to false, "importance" to -1))
                        } else {
                            val importance = channel.importance
                            val enabled = importance != NotificationManager.IMPORTANCE_NONE
                            result.success(mapOf("exists" to true, "enabled" to enabled, "importance" to importance))
                        }
                    } else {
                        // Android < 8.0 没有通知渠道概念，总是返回启用
                        result.success(mapOf("exists" to true, "enabled" to true, "importance" to 3))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installSplitApks(apkPaths: List<String>, result: MethodChannel.Result) {
        executor.execute {
            try {
                val pm = packageManager
                val packageInstaller = pm.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                
                val sessionId = packageInstaller.createSession(params)
                val session = packageInstaller.openSession(sessionId)
                
                for (path in apkPaths) {
                    val file = File(path)
                    if (!file.exists()) continue
                    val name = file.name
                    val size = file.length()
                    
                    val out = session.openWrite(name, 0, size)
                    file.inputStream().use { input ->
                        input.copyTo(out)
                    }
                    session.fsync(out)
                    out.close()
                }
                
                // Create a status intent
                val intent = Intent("com.sequl.zenfile.INSTALL_STATUS")
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pendingIntent = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                
                session.commit(pendingIntent.intentSender)
                session.close()
                
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                e.printStackTrace()
                runOnUiThread { result.error("INSTALL_ERROR", e.message, null) }
            }
        }
    }

    private fun getInstalledApps(includeSystem: Boolean): List<Map<String, Any>> {
        val pm = packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        val resultList = mutableListOf<Map<String, Any>>()
        
        val hasUsageStats = isUsageStatsPermissionGranted()
        var storageStatsManager: StorageStatsManager? = null
        var storageUuid: java.util.UUID? = null
        var user: android.os.UserHandle? = null

        if (hasUsageStats && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                storageStatsManager = getSystemService(Context.STORAGE_STATS_SERVICE) as? StorageStatsManager
                storageUuid = StorageManager.UUID_DEFAULT
                user = Process.myUserHandle()
            } catch (e: Exception) {}
        }

        for (appInfo in apps) {
            val isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (!includeSystem && isSystem) {
                continue
            }
            
            val packageName = appInfo.packageName
            val apkFile = File(appInfo.sourceDir)
            val apkSize = if (apkFile.exists()) apkFile.length() else 0L
            
            var totalSize = apkSize
            if (storageStatsManager != null && storageUuid != null && user != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    val stats = storageStatsManager.queryStatsForPackage(storageUuid, packageName, user)
                    totalSize = stats.appBytes + stats.dataBytes + stats.cacheBytes
                } catch (e: Exception) {}
            }
            
            val appName = appInfo.loadLabel(pm).toString()
            
            var versionName = ""
            var installTime = 0L
            try {
                val pkgInfo = pm.getPackageInfo(packageName, 0)
                versionName = pkgInfo.versionName ?: ""
                installTime = pkgInfo.firstInstallTime
            } catch (e: Exception) {}

            val splitDirs = appInfo.splitSourceDirs?.toList() ?: emptyList<String>()
            val appMap = mapOf(
                "name" to appName,
                "packageName" to packageName,
                "version" to versionName,
                "apkSize" to totalSize,
                "isSystem" to isSystem,
                "installTime" to installTime,
                "sourceDir" to appInfo.sourceDir,
                "splitSourceDirs" to splitDirs
            )
            resultList.add(appMap)
        }
        return resultList
    }

    private fun getAppIcon(packageName: String): ByteArray? {
        return try {
            val pm = packageManager
            val iconDrawable = pm.getApplicationIcon(packageName)
            val bitmap = when (iconDrawable) {
                is BitmapDrawable -> iconDrawable.bitmap
                else -> {
                    val width = iconDrawable.intrinsicWidth.coerceAtLeast(1)
                    val height = iconDrawable.intrinsicHeight.coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bitmap)
                    iconDrawable.setBounds(0, 0, canvas.width, canvas.height)
                    iconDrawable.draw(canvas)
                    bitmap
                }
            }
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun getApkIcon(apkPath: String): ByteArray? {
        val lowerPath = apkPath.lowercase()
        if (lowerPath.endsWith(".xapk") || lowerPath.endsWith(".apks") || lowerPath.endsWith(".apkm")) {
            return try {
                val zipFile = java.util.zip.ZipFile(apkPath)
                var iconBytes: ByteArray? = null
                
                // For XAPK, look for icon.png/icon.webp first
                if (lowerPath.endsWith(".xapk")) {
                    val entries = zipFile.entries()
                    while (entries.hasMoreElements()) {
                        val entry = entries.nextElement()
                        if (entry.name.equals("icon.png", ignoreCase = true) || 
                            entry.name.equals("icon.webp", ignoreCase = true)) {
                            val stream = zipFile.getInputStream(entry)
                            val outStream = ByteArrayOutputStream()
                            val buffer = ByteArray(1024)
                            var length: Int
                            while (stream.read(buffer).also { length = it } != -1) {
                                outStream.write(buffer, 0, length)
                            }
                            iconBytes = outStream.toByteArray()
                            stream.close()
                            break
                        }
                    }
                }
                
                // If icon is not found, extract base.apk or the first/largest apk
                if (iconBytes == null) {
                    var apkEntry: java.util.zip.ZipEntry? = null
                    val entries = zipFile.entries()
                    var maxApkSize = 0L
                    
                    while (entries.hasMoreElements()) {
                        val entry = entries.nextElement()
                        if (entry.name.endsWith(".apk", ignoreCase = true)) {
                            // base.apk is preferred, otherwise take largest apk
                            if (entry.name.equals("base.apk", ignoreCase = true) || 
                                entry.name.split("/").last().equals("base.apk", ignoreCase = true)) {
                                apkEntry = entry
                                break
                            } else if (entry.size > maxApkSize) {
                                apkEntry = entry
                                maxApkSize = entry.size
                            }
                        }
                    }
                    
                    if (apkEntry != null) {
                        val tempFile = java.io.File.createTempFile("temp_base", ".apk", cacheDir)
                        val stream = zipFile.getInputStream(apkEntry)
                        val outStream = java.io.FileOutputStream(tempFile)
                        val buffer = ByteArray(4096)
                        var length: Int
                        while (stream.read(buffer).also { length = it } != -1) {
                            outStream.write(buffer, 0, length)
                        }
                        outStream.close()
                        stream.close()
                        
                        iconBytes = getApkIconFromPath(tempFile.absolutePath)
                        tempFile.delete()
                    }
                }
                zipFile.close()
                iconBytes
            } catch (e: Exception) {
                null
            }
        }
        return getApkIconFromPath(apkPath)
    }

    private fun getApkIconFromPath(apkPath: String): ByteArray? {
        return try {
            val pm = packageManager
            val info = pm.getPackageArchiveInfo(apkPath, 0)
            if (info != null) {
                val appInfo = info.applicationInfo
                if (appInfo != null) {
                    appInfo.sourceDir = apkPath
                    appInfo.publicSourceDir = apkPath
                    val iconDrawable = appInfo.loadIcon(pm)
                    val bitmap = when (iconDrawable) {
                        is BitmapDrawable -> iconDrawable.bitmap
                        else -> {
                            val width = iconDrawable.intrinsicWidth.coerceAtLeast(1)
                            val height = iconDrawable.intrinsicHeight.coerceAtLeast(1)
                            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            val canvas = Canvas(bitmap)
                            iconDrawable.setBounds(0, 0, canvas.width, canvas.height)
                            iconDrawable.draw(canvas)
                            bitmap
                        }
                    }
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    stream.toByteArray()
                } else {
                    null
                }
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun isUsageStatsPermissionGranted(): Boolean {
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
            } else {
                appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    private fun checkRootAvailable(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val exitCode = process.waitFor()
            exitCode == 0
        } catch (e: Exception) {
            false
        }
    }

    private fun runShellCommand(command: String, useRoot: Boolean): String {
        val process: java.lang.Process = if (useRoot) {
            Runtime.getRuntime().exec(arrayOf("su", "-c", command))
        } else {
            val method = Shizuku::class.java.getDeclaredMethod("newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java)
            method.isAccessible = true
            method.invoke(null, arrayOf("sh", "-c", command), null, null) as java.lang.Process
        }

        val reader = BufferedReader(InputStreamReader(process.inputStream))
        val errReader = BufferedReader(InputStreamReader(process.errorStream))

        val output = StringBuilder()
        var line: String?
        while (reader.readLine().also { line = it } != null) {
            output.append(line).append("\n")
        }

        val errOutput = StringBuilder()
        while (errReader.readLine().also { line = it } != null) {
            errOutput.append(line).append("\n")
        }

        val exitCode = process.waitFor()
        if (exitCode != 0 && output.isEmpty() && errOutput.isNotEmpty()) {
            throw Exception(errOutput.toString().trim())
        }
        return output.toString()
    }
}
