package com.sequl.zenfile

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.SocketFactory

/**
 * 自建 SOCKS5 [SocketFactory]，让原生 SMB（smbj）经由 SOCKS5 代理出网，
 * 访问虚拟内网里只有代理才可达的 SMB 服务器。
 *
 * 为什么不用 Java 内建的 [java.net.Proxy] + `Socket(proxy)`：JDK 自带的 SOCKS 客户端
 * 只协商「无鉴权（0x00）」一种方法，遇到需要用户名/口令（RFC 1929, 0x02）的代理会直接
 * 失败。本类自实现握手（与 Dart 侧 [com.sequl.zenfile.Socks5Socket] 同源逻辑），
 * 同时支持无鉴权与用户名/口令两种模式，且出口主机名交给代理解析（适配内网主机只在
 * 代理侧可解析的场景）。
 *
 * 仅 [createSocket(host, port)] 被 smbj 用于建立实际连接；其余重载统一委托到它。
 */
class Socks5SocketFactory(
    private val proxyHost: String,
    private val proxyPort: Int,
    private val proxyUser: String? = null,
    private val proxyPass: String? = null,
    private val connectTimeoutMs: Int = 15000,
) : SocketFactory() {

    override fun createSocket(): Socket {
        // smbj 不会用无参重载建立真实连接（它走 createSocket(host, port)），
        // 这里返回一个直连裸 socket 作为占位即可。
        return Socket()
    }

    override fun createSocket(host: String?, port: Int): Socket {
        val proxy = Socket()
        try {
            proxy.connect(InetSocketAddress(proxyHost, proxyPort), connectTimeoutMs)
            doHandshake(proxy, host, port)
            return proxy
        } catch (e: Throwable) {
            try { proxy.close() } catch (_: Throwable) {}
            throw IOException("SOCKS5 proxy connect failed: ${e.message}", e)
        }
    }

    override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket =
        createSocket(host, port)

    override fun createSocket(address: InetAddress?, port: Int): Socket =
        createSocket(address?.hostAddress, port)

    override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket =
        createSocket(address?.hostAddress, port)

    /** 在已连到代理的 [proxy] 之上完成 SOCKS5 握手，使其变成到 (targetHost, targetPort) 的透明通道。 */
    private fun doHandshake(proxy: Socket, targetHost: String?, targetPort: Int) {
        val out: OutputStream = proxy.getOutputStream()
        val `in`: InputStream = proxy.getInputStream()
        val useAuth = !proxyUser.isNullOrEmpty()

        // 1) 问候：VER + 方法数 + 方法列表
        val methods = if (useAuth) byteArrayOf(0x00, 0x02) else byteArrayOf(0x00)
        out.write(byteArrayOf(0x05, methods.size.toByte()))
        out.write(methods)
        out.flush()

        val greet = readExact(`in`, 2)
        if (greet[0] != 0x05.toByte()) throw IOException("SOCKS5 proxy returned unsupported version")
        val selected = greet[1].toInt() and 0xFF
        if (useAuth && selected == 0x02) {
            // 2) 用户名/口令鉴权（RFC 1929）
            val u = proxyUser!!.toByteArray(Charsets.UTF_8)
            val p = (proxyPass ?: "").toByteArray(Charsets.UTF_8)
            if (u.size > 255 || p.size > 255) throw IOException("SOCKS5 proxy auth too long")
            out.write(0x01)
            out.write(u.size); out.write(u)
            out.write(p.size); out.write(p)
            out.flush()
            val auth = readExact(`in`, 2)
            if (auth[0] != 0x01.toByte() || auth[1] != 0x00.toByte()) {
                throw IOException("SOCKS5 proxy authentication failed")
            }
        } else if (selected != 0x00) {
            throw IOException("SOCKS5 proxy requires unsupported method 0x${selected.toString(16)}")
        }

        // 3) CONNECT 请求（域名形式，交给代理解析）
        val h = (targetHost ?: "").toByteArray(Charsets.UTF_8)
        if (h.size > 255) throw IOException("SOCKS5 target host too long")
        out.write(0x05); out.write(0x01); out.write(0x00); out.write(0x03)
        out.write(h.size); out.write(h)
        out.write((targetPort shr 8) and 0xFF); out.write(targetPort and 0xFF)
        out.flush()

        // 4) 读取应答（VER REP RSV ATYP）
        val rep = readExact(`in`, 4)
        if (rep[0] != 0x05.toByte()) throw IOException("SOCKS5 proxy returned malformed reply")
        if (rep[1].toInt() and 0xFF != 0x00) {
            throw IOException("SOCKS5 proxy CONNECT failed (code 0x${(rep[1].toInt() and 0xFF).toString(16)})")
        }

        // 5) 丢弃绑定地址 + 端口
        val atyp = rep[3].toInt() and 0xFF
        val addrLen = when (atyp) {
            0x01 -> 4
            0x04 -> 16
            0x03 -> { val lenByte = readExact(`in`, 1); lenByte[0].toInt() and 0xFF }
            else -> throw IOException("SOCKS5 proxy returned unsupported ATYP 0x${atyp.toString(16)}")
        }
        readExact(`in`, addrLen + 2)
    }

    /** 从 [in] 精确读取 [n] 字节，受 [connectTimeoutMs] 限制。 */
    private fun readExact(`in`: InputStream, n: Int): ByteArray {
        val buf = ByteArray(n)
        var off = 0
        val deadline = System.currentTimeMillis() + connectTimeoutMs
        while (off < n) {
            val r = `in`.read(buf, off, n - off)
            if (r < 0) throw IOException("SOCKS5 handshake read EOF")
            off += r
            if (System.currentTimeMillis() > deadline) throw IOException("SOCKS5 handshake timeout")
        }
        return buf
    }
}
