package com.sequl.zenfile

import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jcraft.jsch.SftpATTRS
import com.jcraft.jsch.SftpProgressMonitor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Properties
import java.util.UUID
import java.util.Vector
import java.util.concurrent.ConcurrentHashMap

/**
 * 原生 SSH/SFTP 传输服务（替代 dartssh2 的纯 Dart 加解密）。
 *
 * 为什么能提速：dartssh2 用 pointycastle 纯 Dart 实现 AES，所有 SSH 加解密挤在
 * Dart 单线程事件循环上串行跑，局域网下约 2MB/s 即触及单核算力天花板。本服务改用
 * JSch（com.jcraft:jsch），其加解密走 Android 的 javax.crypto（JCE），在 Android 上
 * 经 AndroidOpenSSL 提供方落到 **硬件 AES 指令（ARMv8 Cryptography Extensions）**，
 * 真正跑满千兆/万兆链路（50–100MB/s 级）。
 *
 * 线程模型：本类的方法只在 MainActivity 的 executor 线程上被调用（与 SmbService 一致），
 * 因此方法体内一律不触碰 UI 线程；长耗时传输在调用线程上阻塞，结果由 MainActivity 经
 * runOnUiThread 回传。所有状态用并发容器保存，支持「主连接 + 独立 seek 连接」等多会话并发。
 */
class SshSftpService {

    companion object {
        val instance = SshSftpService()
    }

    private data class SessionHolder(
        val session: Session,
        var sftp: ChannelSftp?,
    )

    /** sessionId -> 会话持有者（一条 SSH 连接 + 复用的 sftp 子通道） */
    private val sessions = ConcurrentHashMap<String, SessionHolder>()

    /** 传输进度（字节数 / 总大小），按 sessionId 区分当前活动传输 */
    private val progressBytes = ConcurrentHashMap<String, Long>()
    private val progressTotal = ConcurrentHashMap<String, Long>()

    /** 取消哨兵：置 true 后正在进行的传输通过 monitor 立即中止 */
    private val cancelFlags = ConcurrentHashMap<String, Boolean>()

    // ── 连接管理 ────────────────────────────────────────────────────────────

    /** 建立密码登录的 SSH 连接，返回 sessionId。 */
    fun connect(host: String, port: Int, username: String, password: String): String {
        val jsch = JSch()
        val session = jsch.getSession(username, host, if (port > 0) port else 22)
        session.setPassword(password)
        val config = Properties().apply {
            // 不校验主机密钥（内网 NAS 场景；若需严格校验可改为 ask/known_hosts）
            put("StrictHostKeyChecking", "no")
            // 启用保活，避免长传输被中间设备掐断
            put("ServerAliveInterval", "30")
            put("ServerAliveCountMax", "3")
        }
        session.setConfig(config)
        session.connect(15000)
        val id = UUID.randomUUID().toString()
        sessions[id] = SessionHolder(session, null)
        return id
    }

    /** 取得（或惰性打开）指定会话的 sftp 子通道。 */
    private fun sftp(id: String): ChannelSftp {
        val holder = sessions[id] ?: throw JSchException("SFTP session not found: $id")
        var ch = holder.sftp
        if (ch == null || !ch.isConnected) {
            ch = holder.session.openChannel("sftp") as ChannelSftp
            ch.connect(15000)
            holder.sftp = ch
        }
        return ch
    }

    fun disconnect(id: String) {
        val holder = sessions.remove(id) ?: return
        try { holder.sftp?.disconnect() } catch (_: Throwable) {}
        try { holder.session.disconnect() } catch (_: Throwable) {}
        progressBytes.remove(id)
        progressTotal.remove(id)
        cancelFlags.remove(id)
    }

    // ── 目录 / 文件操作 ───────────────────────────────────────────────────────

    /** 列目录，返回 RemoteFileItem 风格的 Map 列表（与 Dart 端 RemoteFileItem 字段对应）。 */
    fun listDirectory(id: String, path: String, forceRefresh: Boolean): List<Map<String, Any?>> {
        val ch = sftp(id)
        val target = if (path.isEmpty()) "/" else path
        val entries = try {
            ch.ls(target) as Vector<ChannelSftp.LsEntry>
        } catch (e: Throwable) {
            if (target == "/") ch.ls(".") as Vector<ChannelSftp.LsEntry> else throw e
        }
        val result = mutableListOf<Map<String, Any?>>()
        for (entry in entries) {
            val name = entry.filename
            if (name == "." || name == "..") continue
            val attrs: SftpATTRS = entry.attrs
            val isDir = attrs.isDir
            val size = if (isDir) 0 else attrs.size
            // attrs.mTime：修改时间（秒）。longname 首字符也可辅助判断类型，但 attrs 已可靠。
            val modified = (attrs.mTime.toLong()) * 1000L
            val fullPath = if (path == "/" || path.isEmpty()) {
                "/$name"
            } else {
                val base = if (path.endsWith("/")) path.substring(0, path.length - 1) else path
                "$base/$name"
            }
            result.add(
                mapOf(
                    "name" to name,
                    "path" to fullPath,
                    "isDirectory" to isDir,
                    "size" to size,
                    "modified" to modified,
                )
            )
        }
        return result
    }

    fun createDirectory(id: String, path: String) {
        sftp(id).mkdir(path)
    }

    /** 创建空文件（截断式 put）。 */
    fun createFile(id: String, path: String) {
        val ch = sftp(id)
        ch.put(path).close() // 打开输出流即创建空文件，关闭时落盘
    }

    fun delete(id: String, path: String, isDir: Boolean) {
        val ch = sftp(id)
        if (isDir) ch.rmdir(path) else ch.rm(path)
    }

    fun rename(id: String, oldPath: String, newPath: String) {
        sftp(id).rename(oldPath, newPath)
    }

    fun getFileSize(id: String, remotePath: String): Long {
        return try {
            val attrs = sftp(id).stat(remotePath)
            attrs.size
        } catch (_: Throwable) {
            -1L
        }
    }

    // ── 传输（下载 / 上传 / 区间） ───────────────────────────────────────────

    /** 进度监视器：累计已传字节到并发容器；cancelFlags 置位时返回 false 立即中止。 */
    private fun makeMonitor(id: String): SftpProgressMonitor {
        return object : SftpProgressMonitor {
            private var transferred: Long = 0
            override fun init(op: Int, src: String?, dst: String?, max: Long) {
                transferred = 0
                if (max > 0) progressTotal[id] = max
            }
            override fun count(c: Long): Boolean {
                transferred += c
                progressBytes[id] = transferred
                return !(cancelFlags[id] ?: false)
            }
            override fun end() {}
        }
    }

    /**
     * 下载整个远程文件到本地路径（直接落盘，不经 MethodChannel 传字节）。
     * 返回 false 表示被取消。
     */
    fun downloadFile(id: String, remotePath: String, localPath: String): Boolean {
        val ch = sftp(id)
        File(localPath).parentFile?.mkdirs()
        val size = try { ch.stat(remotePath).size } catch (_: Throwable) { -1L }
        progressTotal[id] = size
        progressBytes[id] = 0L
        cancelFlags[id] = false
        val monitor = makeMonitor(id)
        try {
            // 修复D（问题2）：放弃 JSch 内部 ch.get(remotePath, fos, monitor) 的整体传输
            // （其内部无显式 flush，数据落盘时机不透明，lengthSync 看到的增长与真正
            // 可读字节脱节，导致流媒体代理周期性饥饿卡顿）。改为显式读循环 + 定期
            // flush，与 downloadRange 风格一致：数据每落盘一批立即可被代理读到。
            ch.get(remotePath).use { remote ->
                FileOutputStream(localPath).use { fos ->
                    val buf = ByteArray(64 * 1024)
                    var sinceFlush: Long = 0
                    while (true) {
                        if (cancelFlags[id] ?: false) break
                        val n = remote.read(buf, 0, buf.size)
                        if (n < 0) break
                        fos.write(buf, 0, n)
                        sinceFlush += n
                        // 每约 256KB 强制刷盘一次，缩短「已下载但仍在 OS page cache」的窗口。
                        if (sinceFlush >= 256 * 1024) {
                            fos.flush()
                            sinceFlush = 0
                        }
                        // 进度由 monitor.count 统一累计；返回 false 表示被取消，立即中止。
                        if (!(monitor.count(n.toLong()))) break
                    }
                    fos.flush()
                }
            }
        } finally {
            // 传输结束后重建 sftp 子通道，保证后续 listDirectory/stat 在干净通道上进行。
            // 否则 JSch 单通道在 get/put 后可能残留未消费响应，使下次 ls 返回空/异常
            //（表现为“上传/下载完成后远程目录为空，重启应用才恢复”）。
            resetChannelAfterTransfer(id)
        }
        return !(cancelFlags[id] ?: false)
    }

    /**
     * 下载远程文件的指定字节区间 [startByte, startByte+length) 到本地路径（用于缩略图头部、
     * 流媒体按需 seek）。使用 get 返回的 InputStream 精确 skip + 拷贝，避免整文件下载。
     */
    fun downloadRange(id: String, remotePath: String, localPath: String, startByte: Long, length: Long) {
        val ch = sftp(id)
        File(localPath).parentFile?.mkdirs()
        progressTotal[id] = length
        progressBytes[id] = 0L
        cancelFlags[id] = false
        val monitor = makeMonitor(id)
        try {
            ch.get(remotePath).use { remote ->
                // skip 可能一次跳不足，循环直到跳够 startByte
                var toSkip = startByte
                while (toSkip > 0) {
                    val skipped = remote.skip(toSkip)
                    if (skipped <= 0) break
                    toSkip -= skipped
                }
                FileOutputStream(localPath).use { fos ->
                    val buf = ByteArray(32 * 1024)
                    var remaining = length
                    while (remaining > 0) {
                        if (cancelFlags[id] ?: false) break
                        val toRead = if (remaining > buf.size) buf.size else remaining.toInt()
                        val n = remote.read(buf, 0, toRead)
                        if (n < 0) break
                        fos.write(buf, 0, n)
                        remaining -= n
                        // 进度由 monitor.count 统一累计（避免重复累加）
                        if (!(monitor.count(n.toLong()))) break
                    }
                }
            }
        } finally {
            // 与 downloadFile 同理：区间读取后重建通道，避免污染浏览会话的 ls。
            resetChannelAfterTransfer(id)
        }
    }

    /**
     * 上传本地文件到远程路径（流式读取，经硬件加速加密发出）。
     * 返回 false 表示被取消。
     */
    fun uploadFile(id: String, localPath: String, remotePath: String): Boolean {
        val total = File(localPath).length()
        progressTotal[id] = total
        progressBytes[id] = 0L
        cancelFlags[id] = false
        val monitor = makeMonitor(id)
        var cancelled = false
        try {
            FileInputStream(localPath).use { fis ->
                sftp(id).put(fis, remotePath, monitor, ChannelSftp.OVERWRITE)
            }
        } catch (e: Throwable) {
            // 仅在“被取消”时清理远端残留的部分文件；其它异常（网络/权限）不删，
            // 交由上层决定。
            cancelled = cancelFlags[id] ?: false
            if (cancelled) cleanupPartialRemoteFile(id, remotePath)
            throw e
        }
        cancelled = cancelFlags[id] ?: false
        if (cancelled) {
            // 取消上传：JSch OVERWRITE 已把部分数据写到 remotePath，删除残留的
            // 半截/临时文件，避免“取消后仍留下部分文件”且目录出现临时条目。
            cleanupPartialRemoteFile(id, remotePath)
        } else {
            // 传输成功：重建 sftp 子通道，保证后续 listDirectory 在干净通道上进行，
            // 修复“上传完成后远程目录为空，需重启应用才恢复”的问题。
            resetChannelAfterTransfer(id)
        }
        return !cancelled
    }

    /** 删除远端上传残留的部分/临时文件。put 可能让当前通道处于异常态，先重置再删。 */
    private fun cleanupPartialRemoteFile(id: String, remotePath: String) {
        try {
            val holder = sessions[id] ?: return
            try { holder.sftp?.disconnect() } catch (_: Throwable) {}
            holder.sftp = null
            sftp(id).rm(remotePath)
        } catch (_: Throwable) {
            // 文件可能尚未真正创建（部分服务器先写临时名再 rename），删除失败可忽略
        }
    }

    /** 传输（get/put/downloadRange）结束后重建 sftp 子通道，使后续控制命令在干净通道上执行。 */
    private fun resetChannelAfterTransfer(id: String) {
        val holder = sessions[id] ?: return
        try { holder.sftp?.disconnect() } catch (_: Throwable) {}
        holder.sftp = null
    }

    // ── 进度 / 取消查询 ─────────────────────────────────────────────────────

    /** 当前活动传输的进度（字节）。 */
    fun getProgress(id: String): Map<String, Any?> {
        return mapOf(
            "downloaded" to (progressBytes[id] ?: 0L),
            "total" to (progressTotal[id] ?: 0L),
        )
    }

    fun cancelTransfer(id: String) {
        cancelFlags[id] = true
    }

    fun resetCancel(id: String) {
        cancelFlags[id] = false
    }
}
