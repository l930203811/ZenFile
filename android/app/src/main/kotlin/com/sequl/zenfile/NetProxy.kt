package com.sequl.zenfile

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI

/**
 * 读取 Android **系统 HTTP 代理**（WiFi 高级设置里手填的代理）。
 *
 * 为什么需要原生实现：Dart 的 `HttpClient` 默认**不使用**系统代理，而
 * `HttpClient.findProxyFromEnvironment` 读的是进程环境变量（`http_proxy` 等）——
 * Android 应用进程没有这些变量，所以在 Android 上等于没生效。要拿系统代理只能走
 * Java 层的 `ProxySelector`，因此这里加了一个极小的原生接口。
 *
 * ⚠️ **VPN / 全局代理类工具不需要它**：那类工具在网络层透明拦截，应用无感知。
 * 本接口只服务「手动配置代理」这一种场景。
 *
 * 铁律（与 CrashForensics 一致）：**只用公开 API**、**全入口 try/catch(Throwable)**。
 * 读不到代理必须安静地返回 null（Dart 侧退回直连），绝不能因为读代理而影响更新检测。
 */
object NetProxy {

    private const val CHANNEL = "com.sequl.zenfile/net_proxy"

    /** 探测用的 URI：只需要一个 https 地址让 ProxySelector 判断走哪个代理。 */
    private const val PROBE_URL = "https://api.github.com"

    fun registerChannel(messenger: BinaryMessenger) {
        try {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getHttpProxy" -> result.success(querySystemProxy())
                        else -> result.notImplemented()
                    }
                } catch (t: Throwable) {
                    // 单次查询失败 ≠ 通道故障：返回 null（= 直连）比报错更有用
                    result.success(null)
                }
            }
        } catch (t: Throwable) {
            // 注册失败也不能影响应用启动
        }
    }

    /**
     * 返回 `"host:port"`；无代理 / 查询失败返回 `null`。
     *
     * 查询本身是「读系统设置」，无网络 I/O，可在主线程直接调用。
     */
    private fun querySystemProxy(): String? {
        // ① 首选 ProxySelector：Android 的默认实现会反映当前网络（WiFi）的代理设置。
        try {
            val selector = ProxySelector.getDefault()
            if (selector != null) {
                val proxies = selector.select(URI(PROBE_URL))
                val proxy = proxies?.firstOrNull()
                if (proxy != null && proxy.type() == Proxy.Type.HTTP) {
                    val address = proxy.address()
                    if (address is InetSocketAddress) {
                        val host = address.hostString
                        val port = address.port
                        if (!host.isNullOrBlank() && port > 0) {
                            return "$host:$port"
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            // 落到 ②
        }

        // ② 兜底：部分定制 ROM 只写 JVM 系统属性（Android 原生一般不写，但无害）。
        try {
            val host = System.getProperty("http.proxyHost")
            val port = System.getProperty("http.proxyPort")
            if (!host.isNullOrBlank() && !port.isNullOrBlank()) {
                return "$host:$port"
            }
        } catch (t: Throwable) {
            // 忽略
        }

        return null
    }
}
