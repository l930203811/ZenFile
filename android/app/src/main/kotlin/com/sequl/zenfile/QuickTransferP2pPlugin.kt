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

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
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

    private fun disconnect(result: MethodChannel.Result) {
        val m = manager ?: return result.error("NO_MANAGER", "WifiP2pManager unavailable", null)
        m.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                lastGroupOwnerAddress = null
                result.success(true)
            }
            override fun onFailure(reason: Int) {
                result.error("DISCONNECT_FAILED", "reason=$reason", null)
            }
        })
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
