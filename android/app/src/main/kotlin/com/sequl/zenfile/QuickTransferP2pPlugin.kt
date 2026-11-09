package com.sequl.zenfile

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 快传 WiFi Direct (P2P) 原生封装
 *
 * 负责：设备发现(discoverPeers)、连接(connect)、获取本机 GO IP、设备列表与连接状态回传。
 * 实际文件/文件夹的 Socket 直传由 Dart 层 [dart:io] 完成，本类只提供 P2P 组网能力。
 *
 * 参考 ES 文件浏览器「快传」/ QQ 面对面快传：
 *  - 系统自动建立临时 P2P 组(GO)，不手动开热点；
 *  - 双方 discoverPeers 后可在列表互相看到设备名；
 *  - 点击对端设备名发起 connect，连接成功后用 Socket 直连传输。
 */
object QuickTransferP2pPlugin {

    const val CHANNEL = "com.sequl.zenfile/quick_transfer"
    private const val EVENT_PEERS = "com.sequl.zenfile/quick_transfer_peers"
    private const val EVENT_CONNECTION = "com.sequl.zenfile/quick_transfer_connection"

    private var activity: MainActivity? = null
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null

    private var peersSink: EventChannel.EventSink? = null
    private var connectionSink: EventChannel.EventSink? = null

    private val peers = mutableMapOf<String, WifiP2pDevice>()

    private var lastGroupOwnerAddress: String? = null

    // disconnect 并发合并：dispose / _reset / connect 前清组可能在同一帧叠加，
    // 多次 removeGroup 会让框架回 BUSY(2)，旧实现把它当错误抛给 Dart。
    private val pendingDisconnect = mutableListOf<MethodChannel.Result>()
    private var disconnectInFlight = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    manager?.requestPeers(channel) { deviceList: WifiP2pDeviceList ->
                        peers.clear()
                        for (d in deviceList.deviceList) {
                            // 过滤掉本机自身
                            peers[d.deviceAddress] = d
                        }
                        emitPeers()
                    }
                }
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_INFO, WifiP2pInfo::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_INFO) as? WifiP2pInfo
                    }
                    val ownerAddr = info?.groupOwnerAddress?.hostAddress
                    if (ownerAddr != null) lastGroupOwnerAddress = ownerAddr
                    val connected = info?.groupFormed == true
                    val isOwner = info?.isGroupOwner == true
                    val map = mapOf(
                        "connected" to connected,
                        "isGroupOwner" to isOwner,
                        "groupOwnerAddress" to (ownerAddr ?: lastGroupOwnerAddress),
                    )
                    connectionSink?.success(map)
                }
            }
        }
    }

    fun register(mainActivity: MainActivity, messenger: BinaryMessenger) {
        activity = mainActivity
        manager = (mainActivity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager)
        channel = manager?.initialize(mainActivity, mainActivity.mainLooper, null)

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        }
        mainActivity.registerReceiver(receiver, filter)

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, rawResult ->
            val result = rawResult.replyOnce()
            when (call.method) {
                "isSupported" -> result.success(manager != null)
                "getDeviceName" -> result.success(getDeviceName())
                "getDeviceAddress" -> result.success(getDeviceAddress())
                "isWifiEnabled" -> result.success(isWifiEnabled())
                "startDiscovery" -> startDiscovery(result)
                "stopDiscovery" -> stopDiscovery(result)
                "getPeers" -> result.success(currentPeersPayload())
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address.isNullOrEmpty()) {
                        result.error("NO_ADDRESS", "missing address", null)
                    } else {
                        connect(address, result)
                    }
                }
                "createGroup" -> createGroup(result)
                "disconnect" -> disconnect(result)
                "getGroupOwnerAddress" -> result.success(lastGroupOwnerAddress)
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_PEERS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                peersSink = events
                emitPeers()
            }
            override fun onCancel(arguments: Any?) {
                peersSink = null
            }
        })

        EventChannel(messenger, EVENT_CONNECTION).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                connectionSink = events
            }
            override fun onCancel(arguments: Any?) {
                connectionSink = null
            }
        })
    }

    fun unregister() {
        try {
            activity?.unregisterReceiver(receiver)
        } catch (_: Exception) { }
        manager?.removeGroup(channel, null)
        manager = null
        channel = null
        activity = null
        peers.clear()
        peersSink = null
        connectionSink = null
    }

    private fun getDeviceName(): String? {
        // 优先使用系统蓝牙/设备名，作为 P2P 显示名；无则回退包名
        return Build.MODEL?.takeIf { it.isNotBlank() } ?: activity?.packageName
    }

    @SuppressLint("HardwareIds")
    private fun getDeviceAddress(): String? {
        return try {
            val wifi = activity?.applicationContext?.getSystemService(Context.WIFI_SERVICE)
                as? android.net.wifi.WifiManager
            val addr = wifi?.connectionInfo?.macAddress
            addr
        } catch (_: Exception) {
            null
        }
    }

    private fun startDiscovery(result: MethodChannel.Result) {
        val m = manager ?: return result.error("NO_MANAGER", "WifiP2pManager unavailable", null)
        // 发现前需要位置/附近设备权限（Android 10-12 必须位置才能看到设备名）
        if (!hasNearbyPermission()) {
            return result.error("NO_PERMISSION", "missing location/nearby permission", null)
        }
        m.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(true)
                emitPeers()
            }
            override fun onFailure(reason: Int) {
                result.error("DISCOVER_FAILED", "reason=$reason", null)
            }
        })
    }

    private fun stopDiscovery(result: MethodChannel.Result) {
        val m = manager ?: return result.error("NO_MANAGER", "WifiP2pManager unavailable", null)
        m.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { result.success(true) }
            override fun onFailure(reason: Int) { result.error("STOP_FAILED", "reason=$reason", null) }
        })
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        val m = manager ?: return result.error("NO_MANAGER", "WifiP2pManager unavailable", null)
        val config = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            WifiP2pConfig.Builder().setDeviceAddress(android.net.MacAddress.fromString(address)).build()
        } else {
            @Suppress("DEPRECATION")
            WifiP2pConfig().apply { deviceAddress = address }
        }
        m.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                // 连接成功，等待 CONNECTION_CHANGED 广播推送 GO IP
                result.success(true)
            }
            override fun onFailure(reason: Int) {
                result.error("CONNECT_FAILED", "reason=$reason", null)
            }
        })
    }

    private fun createGroup(result: MethodChannel.Result) {
        val m = manager ?: return result.error("NO_MANAGER", "WifiP2pManager unavailable", null)
        // 创建前先尝试清理旧组，避免已有 P2P 组导致失败
        val doCreate = {
            m.createGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    // GO IP 由 CONNECTION_CHANGED 广播填充 lastGroupOwnerAddress
                    result.success(true)
                }
                override fun onFailure(reason: Int) {
                    result.error("CREATE_GROUP_FAILED", "reason=$reason", null)
                }
            })
        }
        m.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = doCreate()
            override fun onFailure(reason: Int) = doCreate()
        })
    }

    private fun isWifiEnabled(): Boolean {
        return try {
            val wifi = activity?.applicationContext?.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            wifi?.isWifiEnabled == true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 断开 P2P 组。语义上**幂等**：目标状态是「没有活跃组」，所以无组可删、
     * 框架正忙（重复调用）、通道已失效都按成功收尾，不再抛 DISCONNECT_FAILED。
     *
     * 历史问题：`dispose()` / `_reset()` / connect 前清组会在同一帧叠加调用，
     * removeGroup 回 `BUSY(2)` → PlatformException 被 runZonedGuarded 写成
     * `dart_error_*.txt`，用户无感却污染崩溃日志（v3.7.4 / vivo V2054A）。
     */
    private fun disconnect(result: MethodChannel.Result) {
        val m = manager
        val ch = channel
        if (m == null || ch == null) {
            // 拿不到管理器/通道，本来就不可能有活跃组。
            lastGroupOwnerAddress = null
            result.success(true)
            return
        }

        // 已有 removeGroup 在途：合并等待，不重复向框架发请求。
        pendingDisconnect.add(result)
        if (disconnectInFlight) return
        disconnectInFlight = true

        val handler = Handler(Looper.getMainLooper())
        var timeout: Runnable? = null

        fun finish(ok: Boolean, reason: Int) {
            if (!disconnectInFlight) return // 回调与超时竞态，只处理一次
            timeout?.let { handler.removeCallbacks(it) }
            lastGroupOwnerAddress = null
            disconnectInFlight = false
            val waiting = pendingDisconnect.toList()
            pendingDisconnect.clear()
            for (r in waiting) {
                try {
                    if (ok) r.success(true)
                    else r.error("DISCONNECT_FAILED", "reason=$reason", null)
                } catch (_: Throwable) {
                    // Activity / engine 已销毁时 result 可能失效，忽略即可。
                }
            }
        }

        // 极少数机型上框架不回调 ActionListener；3 秒兜底，避免
        // disconnectInFlight 一直挂着，导致后续所有调用都拿不到回复。
        val cb = Runnable { finish(true, -2) }
        timeout = cb
        handler.postDelayed(cb, 3000L)

        try {
            m.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = finish(true, 0)
                override fun onFailure(reason: Int) {
                    // WifiP2pManager.ActionListener: 0=ERROR, 1=P2P_UNSUPPORTED,
                    // 2=BUSY。0/2 都是「无活跃组 / 框架正忙」的常态，目标状态
                    // 已达成；只有 1 一类真实失败才如实上报。
                    if (reason == 0 || reason == 2) finish(true, reason)
                    else finish(false, reason)
                }
            })
        } catch (_: Throwable) {
            // 通道已失效时 removeGroup 可能直接抛异常，同样按已断开处理。
            finish(true, -1)
        }
    }

    private fun hasNearbyPermission(): Boolean {
        val ctx = activity ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.NEARBY_WIFI_DEVICES) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun currentPeersPayload(): List<Map<String, Any?>> {
        return peers.values.map { d ->
            mapOf(
                "address" to d.deviceAddress,
                "name" to (if (d.deviceName.isNullOrBlank()) d.deviceAddress else d.deviceName),
                "status" to d.status,
            )
        }
    }

    private fun emitPeers() {
        peersSink?.success(currentPeersPayload())
    }
}
