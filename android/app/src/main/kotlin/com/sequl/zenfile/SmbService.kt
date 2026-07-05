package com.sequl.zenfile

import android.util.Log
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.fileinformation.FileIdBothDirectoryInformation
import com.hierynomus.msfscc.fileinformation.FileStandardInformation
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import com.hierynomus.smbj.share.PipeShare
import com.hierynomus.smbj.share.Share
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Native SMB client backed by smbj. Exposes a small set of operations that are
 * dispatched from [MainActivity] through the `com.sequl.zenfile/smb` MethodChannel.
 *
 * Each session is identified by a UUID and holds the underlying [SMBClient],
 * [Connection], [Session] and a cache of connected [DiskShare] instances keyed
 * by share name. Paths coming from Dart use forward slashes and are translated
 * to backslash-separated paths before being handed to smbj.
 */
class SmbService {

    private class SmbSessionEntry(
        val client: SMBClient,
        val connection: Connection,
        val session: Session,
        val username: String,
        val host: String,
        val shares: ConcurrentHashMap<String, DiskShare> = ConcurrentHashMap()
    )

    private val sessions = ConcurrentHashMap<String, SmbSessionEntry>()

    companion object {
        val instance: SmbService = SmbService()

        // FILE_ATTRIBUTE_DIRECTORY bit (0x10) used to inspect FileIdBothDirectoryInformation.
        private const val FILE_ATTRIBUTE_DIRECTORY_BIT = 0x10L

        // SMB NTSTATUS codes for "share exists but current credentials can't access it".
        // These are handled in listSharesViaProbing as "accessible but access denied"
        // so the user knows the share is there even if they can't open it.
        private val ACCESS_EXISTS_STATUS_CODES = setOf(
            0xC0000022L,  // STATUS_ACCESS_DENIED
            0xC00000CAL,  // STATUS_NETWORK_ACCESS_DENIED
            0xC000006DL,  // STATUS_LOGON_FAILURE
            0xC000006AL,  // STATUS_WRONG_PASSWORD
            0xC000006EL,  // STATUS_ACCOUNT_RESTRICTION
            0xC000006FL,  // STATUS_INVALID_LOGON_HOURS
            0xC0000070L,  // STATUS_INVALID_WORKSTATION
            0xC0000071L,  // STATUS_PASSWORD_EXPIRED
            0xC0000072L,  // STATUS_ACCOUNT_DISABLED
            0xC0000193L,  // STATUS_LOGON_TYPE_NOT_GRANTED
        )
    }

    /**
     * Builds the share-access set that allows concurrent read/write/delete so
     * that other clients (and our own listing calls) do not get locked out.
     */
    private fun allShareAccess(): Set<SMB2ShareAccess> = EnumSet.of(
        SMB2ShareAccess.FILE_SHARE_READ,
        SMB2ShareAccess.FILE_SHARE_WRITE,
        SMB2ShareAccess.FILE_SHARE_DELETE
    )

    /**
     * Establishes a new SMB session against [host]:[port] using the supplied
     * credentials. When [username] is blank an anonymous context is used.
     *
     * @return a freshly generated sessionId that must be passed to subsequent calls.
     */
    fun connect(host: String, port: Int, username: String, password: String?, domain: String?): String {
        try {
            val config = SmbConfig.builder()
                .withSoTimeout(60, TimeUnit.SECONDS)
                .withDfsEnabled(true)
                .build()
            val client = SMBClient(config)
            val connection = client.connect(host, port)
            val authContext = if (username.isEmpty()) {
                // Some SMB servers (e.g. Samba) require a "guest" username for anonymous access
                AuthenticationContext("guest", CharArray(0), null)
            } else {
                AuthenticationContext(username, password?.toCharArray(), domain)
            }
            val session = connection.authenticate(authContext)
            val sessionId = UUID.randomUUID().toString()
            sessions[sessionId] = SmbSessionEntry(client, connection, session, username, host)
            return sessionId
        } catch (e: Exception) {
            throw Exception("Failed to connect to SMB server '${host}:${port}': ${e.message}", e)
        }
    }

    /**
     * Lists the contents of [path] within the session identified by [sessionId].
     *
     * When [path] is "/" (root), all available shares on the server are
     * enumerated and returned as directory entries. The user does not need
     * to specify a share name — the server is probed automatically.
     *
     * For paths like "/{share}/{dir}/...", the contents within that share
     * are listed. Each returned entry exposes: name, path (forward-slash form
     * for Dart), isDirectory, size (bytes), modified (epoch millis).
     */
    fun listDirectory(sessionId: String, path: String): List<Map<String, Any>> {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        if (path.isEmpty() || path == "/") {
            // Root listing: enumerate available shares on the server
            return listShares(sessionId)
        }

        val (shareName, pathInShare) = resolveShareAndPath(path)
        if (shareName.isEmpty()) return emptyList()

        return try {
            val share = getShare(entry, shareName)
            // smbj 的 list("") 在某些服务器上会失败,空路径时用 "\\" 替代
            val effectivePath = if (pathInShare.isEmpty()) "\\" else pathInShare
            val listing: List<FileIdBothDirectoryInformation> = share.list(effectivePath)
            val items = mutableListOf<Map<String, Any>>()
            val basePath = path.trimEnd('/')

            for (info in listing) {
                val name = info.fileName
                if (name == "." || name == "..") continue

                val isDirectory = (info.fileAttributes and FILE_ATTRIBUTE_DIRECTORY_BIT) != 0L
                val size = info.endOfFile
                val modified = try {
                    info.lastWriteTime?.toEpochMillis() ?: 0L
                } catch (e: Exception) {
                    0L
                }

                items.add(
                    mapOf(
                        "name" to name,
                        "path" to "$basePath/$name",
                        "isDirectory" to isDirectory,
                        "size" to size,
                        "modified" to modified
                    )
                )
            }
            items
        } catch (e: Exception) {
            throw Exception("Failed to list directory '$path': ${e.message}", e)
        }
    }

    /**
     * Lists the available shares on the connected SMB server.
     *
     * Tries proper DCE/RPC share enumeration via the `srvsvc` named pipe
     * first (NetShareEnumAll). This works on Windows servers and most modern
     * Samba installations. If DCE/RPC fails (e.g. IPC$ is inaccessible,
     * or the bind is rejected), falls back to the brute-force probing
     * approach which checks a comprehensive list of common share names.
     */
    fun listShares(sessionId: String): List<Map<String, Any>> {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        // Try DCE/RPC NetShareEnumAll first (proper enumeration)
        try {
            Log.i("SmbService", "Enumerating shares via DCE/RPC for ${entry.host}")
            val rpcResult = listSharesViaRpc(entry)
            if (rpcResult.isNotEmpty()) {
                return rpcResult
            }
        } catch (e: Exception) {
            Log.w("SmbService", "DCE/RPC failed, falling back to probing: ${e.message}")
        }
        // Fall back to brute-force probing
        Log.i("SmbService", "Enumerating shares via probing for ${entry.host}")
        return listSharesViaProbing(entry)
    }

    /**
     * Enumerates shares via DCE/RPC NetShareEnumAll (opnum 15) on the
     * `srvsvc` named pipe accessed through `IPC$`.
     *
     * Returns empty list on any failure so the caller can fall back to probing.
     */
    private fun listSharesViaRpc(entry: SmbSessionEntry): List<Map<String, Any>> {
        try {
            val ipcShare = entry.session.connectShare("IPC$")
            try {
                val pipeHandle = when (ipcShare) {
                    is DiskShare -> ipcShare.openFile(
                        "\\srvsvc",
                        EnumSet.of(AccessMask.GENERIC_READ, AccessMask.GENERIC_WRITE),
                        null,
                        allShareAccess(),
                        SMB2CreateDisposition.FILE_OPEN,
                        null
                    )
                    is PipeShare -> {
                        // smbj 0.13.0 PipeShare doesn't expose openFile.
                        // Use reflection to extract the TreeConnect and wrap it in
                        // a synthetic DiskShare for the IPC$ share, so we can send
                        // SMB2 CREATE requests to open the \srvsvc named pipe.
                        try {
                            val treeConnectField = Share::class.java.getDeclaredField("treeConnect")
                            treeConnectField.isAccessible = true
                            val treeConnect = treeConnectField.get(ipcShare)
                            val tcClass = Class.forName("com.hierynomus.smbj.session.TreeConnect")
                            val diskShareCtor = DiskShare::class.java.getDeclaredConstructor(
                                Session::class.java, tcClass, String::class.java
                            )
                            diskShareCtor.isAccessible = true
                            (diskShareCtor.newInstance(entry.session, treeConnect, "IPC$") as DiskShare).openFile(
                                "\\srvsvc",
                                EnumSet.of(AccessMask.GENERIC_READ, AccessMask.GENERIC_WRITE),
                                null,
                                allShareAccess(),
                                SMB2CreateDisposition.FILE_OPEN,
                                null
                            )
                        } catch (reflectionError: Exception) {
                            Log.w("SmbService", "Reflection to open IPC$ pipe failed: ${reflectionError.message}")
                            return emptyList()
                        }
                    }
                    else -> {
                        Log.w("SmbService", "IPC$ is ${ipcShare.javaClass.simpleName}, cannot open pipe")
                        return emptyList()
                    }
                }

                try {
                    val input = pipeHandle.inputStream
                    val output = pipeHandle.outputStream

                    // 1. Send DCE/RPC Bind request
                    val bindRequest = createDcerpcBindRequest()
                    output.write(bindRequest)
                    output.flush()

                    // 2. Read Bind Ack (with generous timeout)
                    val bindAck = readDcerpcResponse(input, 5000)
                    if (bindAck == null || bindAck.size < 68) {
                        Log.w("SmbService", "RPC bind ack too short or null")
                        return emptyList()
                    }
                    // Check packet type = 12 (bind_ack)
                    if (bindAck[2].toInt() and 0xFF != 12) {
                        Log.w("SmbService", "RPC unexpected response type: ${bindAck[2]}")
                        return emptyList()
                    }
                    // Check result = 0 (acceptance) at offset 68-69 in most responses
                    if (!verifyBindAckResult(bindAck)) {
                        Log.w("SmbService", "RPC bind rejected by server")
                        return emptyList()
                    }

                    // 3. Send NetShareEnumAll request (opnum 15)
                    val serverName = "\\\\${entry.host}"
                    val enumRequest = createNetShareEnumAllRequest(serverName)
                    output.write(enumRequest)
                    output.flush()

                    // 4. Read response (may be large)
                    val response = readDcerpcResponse(input, 15000)
                    if (response == null || response.size < 24) {
                        Log.w("SmbService", "RPC enum response too short or null")
                        return emptyList()
                    }

                    // Check packet type = 2 (response)
                    if (response[2].toInt() and 0xFF != 2) {
                        Log.w("SmbService", "RPC unexpected response type: ${response[2]}")
                        return emptyList()
                    }

                    // 5. Parse share list from NDR-encoded response
                    return parseNetShareEnumAllResponse(response)
                } finally {
                    try { pipeHandle.close() } catch (_: Exception) {}
                }
            } finally {
                try { ipcShare.close() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w("SmbService", "DCE/RPC enumeration via IPC$ failed: ${e.message}")
            return emptyList()
        }
    }

    /**
     * Creates a DCE/RPC Bind PDU for the srvsvc interface.
     *
     * Interface UUID: 12345788-1234-ABCD-EF00-0123456789AB (srvsvc v3.0)
     * Transfer syntax: 8a885d04-1ceb-11c9-9fe8-08002b104860 (NDR v2)
     */
    private fun createDcerpcBindRequest(): ByteArray {
        val buf = ByteBuffer.allocate(72).order(ByteOrder.LITTLE_ENDIAN)
        // RPC header
        buf.put(5)            // RPC version
        buf.put(0)            // RPC minor version
        buf.put(11)           // Packet type: Bind
        buf.put(0x03)         // Flags: First + Last fragment
        buf.put(0x10)         // Data rep: little-endian
        buf.put(0x00)
        buf.put(0x00)
        buf.put(0x00)
        buf.putShort(72)      // Frag length
        buf.putShort(0)       // Auth length
        buf.putInt(1)         // Call ID
        // Bind body
        buf.putShort(4280)    // Max transmit fragment
        buf.putShort(4280)    // Max receive fragment
        buf.putInt(0)         // Assoc group ID
        buf.put(1.toByte())   // Number of context elements
        buf.put(0)            // Padding
        buf.putShort(0)       // Padding
        buf.putShort(0)       // Context ID
        buf.put(1.toByte())   // Number of transfer syntaxes
        buf.put(0)            // Padding
        // Interface UUID (srvsvc): 12345788-1234-ABCD-EF00-0123456789AB
        // Stored in mixed-endian: LE32 LE16 LE16 BE16 BE48
        buf.putInt(0x12345788)
        buf.putShort(0x1234)
        buf.putShort(0xABCD.toShort())
        buf.put(0xEF.toByte()); buf.put(0x00)
        buf.put(0x01); buf.put(0x23); buf.put(0x45); buf.put(0x67)
        buf.put(0x89.toByte()); buf.put(0xAB.toByte())
        buf.putShort(3)       // Interface version
        buf.putShort(0)       // Interface version minor
        // Transfer syntax UUID (NDR): 8a885d04-1ceb-11c9-9fe8-08002b104860
        buf.putInt(0x045D888A.toInt())
        buf.putShort(0x1CEB.toShort())
        buf.putShort(0x11C9.toShort())
        buf.put(0x9F.toByte()); buf.put(0xE8.toByte())
        buf.put(0x08); buf.put(0x00); buf.put(0x2B); buf.put(0x10)
        buf.put(0x48); buf.put(0x60)
        buf.putInt(2)         // Transfer syntax version
        return buf.array()
    }

    /**
     * Creates a DCE/RPC Request PDU for NetShareEnumAll (opnum 15).
     *
     * Parameters (NDR-encoded):
     * - Server name (unique pointer to conformant string)
     * - Info level: 1 (SHARE_INFO_1)
     * - Prefered maximum length: 0xFFFFFFFF
     * - Enumerate handle: NULL
     */
    private fun createNetShareEnumAllRequest(serverName: String): ByteArray {
        // Encode server name as UTF-16LE
        val nameBytes = serverName.toByteArray(Charsets.UTF_16LE)
        val nameCount = serverName.length + 1  // include null terminator
        val nameDataLen = nameCount * 2
        val namePadding = (4 - (nameDataLen % 4)) % 4

        // Stub data layout:
        // 4  referent ID
        // 4  info level
        // 4  prefered max length
        // 4  enumerate handle (NULL)
        // --- deferred pointee ---
        // 4  max count
        // 4  offset
        // 4  actual count
        // N  string data
        // P  padding
        val stubLen = 16 + 12 + nameDataLen + namePadding
        val fragLen = 24 + stubLen  // 24 = DCE/RPC header

        val buf = ByteBuffer.allocate(fragLen).order(ByteOrder.LITTLE_ENDIAN)
        // DCE/RPC header
        buf.put(5)            // RPC version
        buf.put(0)            // RPC minor version
        buf.put(0)            // Packet type: Request
        buf.put(0x03)         // Flags: First + Last fragment
        buf.put(0x10)         // Data rep: little-endian
        buf.put(0x00); buf.put(0x00); buf.put(0x00)
        buf.putShort(fragLen.toShort())  // Frag length
        buf.putShort(0)       // Auth length
        buf.putInt(2)         // Call ID
        buf.putInt(stubLen)   // Alloc hint
        buf.putShort(0)       // Context ID
        buf.putShort(15)      // Opnum: NetShareEnumAll

        // --- Stub data ---
        // Top-level parameters
        buf.putInt(1)              // Server name referent ID
        buf.putInt(1)              // Info level: 1
        buf.putInt(0xFFFFFFFF.toInt())  // Prefered max length
        buf.putInt(0)              // Enumerate handle: NULL

        // Deferred pointee: server name conformant string
        buf.putInt(nameCount)      // Max count
        buf.putInt(0)              // Offset
        buf.putInt(nameCount)      // Actual count
        buf.put(nameBytes)         // String data (without null, but actual_count includes it)
        // Add null terminator
        buf.put(0); buf.put(0)
        // Padding
        for (i in 0 until namePadding) buf.put(0)

        return buf.array()
    }

    /**
     * Reads a DCE/RPC response PDU from the input stream.
     * Handles multi-fragment responses by reading and concatenating fragments.
     */
    private fun readDcerpcResponse(input: java.io.InputStream, timeoutMs: Int): ByteArray? {
        val bos = ByteArrayOutputStream()

        // Read first fragment
        // DCE/RPC header is 16 bytes; frag length is at offset 8-9
        val header = ByteArray(16)
        val headerRead = readFully(input, header, 0, 16, timeoutMs)
        if (headerRead < 16) return null

        val fragLen = ((header[9].toInt() and 0xFF) shl 8) or (header[8].toInt() and 0xFF)
        if (fragLen < 16 || fragLen > 65536) {
            Log.w("SmbService", "RPC invalid frag length: $fragLen")
            return null
        }

        // Read the rest of this fragment
        val body = ByteArray(fragLen - 16)
        val bodyRead = readFully(input, body, 0, fragLen - 16, timeoutMs)
        if (bodyRead < fragLen - 16) return null

        bos.write(header, 0, 16)
        bos.write(body, 0, bodyRead)

        // Check if there are more fragments (flags bit 0 = first, bit 1 = last)
        val flags = header[3].toInt() and 0xFF
        val isLast = (flags and 0x02) != 0

        while (!isLast) {
            // Read next fragment header
            val nextHeader = ByteArray(16)
            val nextHeaderRead = readFully(input, nextHeader, 0, 16, timeoutMs)
            if (nextHeaderRead < 16) break

            val nextFragLen = ((nextHeader[9].toInt() and 0xFF) shl 8) or (nextHeader[8].toInt() and 0xFF)
            if (nextFragLen < 16 || nextFragLen > 65536) break

            val nextBody = ByteArray(nextFragLen - 16)
            val nextBodyRead = readFully(input, nextBody, 0, nextFragLen - 16, timeoutMs)
            if (nextBodyRead < nextFragLen - 16) break

            bos.write(nextBody, 0, nextBodyRead)  // only body, header already in first fragment

            val nextFlags = nextHeader[3].toInt() and 0xFF
            if ((nextFlags and 0x02) != 0) break  // last fragment
        }

        return bos.toByteArray()
    }

    /**
     * Reads exactly [len] bytes from the input stream with a timeout.
     */
    private fun readFully(input: java.io.InputStream, buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int {
        var totalRead = 0
        val startTime = System.currentTimeMillis()
        while (totalRead < len) {
            if (System.currentTimeMillis() - startTime > timeoutMs) {
                Log.w("SmbService", "RPC read timeout: $totalRead/$len bytes")
                return totalRead
            }
            val read = input.read(buf, off + totalRead, len - totalRead)
            if (read < 0) {
                Log.w("SmbService", "RPC stream EOF: $totalRead/$len bytes")
                return totalRead
            }
            totalRead += read
        }
        return totalRead
    }

    /**
     * Verifies that the bind_ack response indicates acceptance.
     * Searches for result bytes (0x0000) in the bind_ack response.
     */
    private fun verifyBindAckResult(bindAck: ByteArray): Boolean {
        // The bind_ack has a variable-length secondary address before the result.
        // We search for the acceptance result pattern.
        // Result value of 0 (acceptance) followed by reason 0.
        for (i in 24 until bindAck.size - 3) {
            if (bindAck[i].toInt() and 0xFF == 0 &&
                bindAck[i + 1].toInt() and 0xFF == 0 &&
                bindAck[i + 2].toInt() and 0xFF == 0) {
                // Likely found the result section
                return true
            }
        }
        // If we can't find the pattern, assume success (some servers have
        // non-standard formats)
        return true
    }

    /**
     * Parses the NDR-encoded NetShareEnumAll response to extract share names.
     *
     * Response structure (after DCE/RPC header at offset 24):
     * - Windows error code (4 bytes, LE) — 0 = success
     * - Info level (2 bytes, LE)
     * - Padding (2 bytes)
     * - Share info referent ID (4 bytes)
     * - Count (4 bytes, LE) — number of shares
     * - Array of SHARE_INFO_1 entries (each: name ptr, type, comment ptr)
     * - Deferred strings (name and comment for each share)
     */
    private fun parseNetShareEnumAllResponse(response: ByteArray): List<Map<String, Any>> {
        val items = mutableListOf<Map<String, Any>>()

        try {
            val buf = ByteBuffer.wrap(response).order(ByteOrder.LITTLE_ENDIAN)

            // Skip DCE/RPC header (24 bytes)
            buf.position(24)

            // Read Windows error code
            val winError = buf.int
            if (winError != 0) {
                Log.w("SmbService", "RPC NetShareEnumAll returned error: 0x${winError.toString(16)}")
                return emptyList()
            }

            // Info level
            val infoLevel = buf.short.toInt() and 0xFFFF
            buf.position(buf.position() + 2)  // skip padding

            // Share info referent ID
            val referentId = buf.int

            // Count
            val count = buf.int
            if (count <= 0 || count > 1024) {
                Log.w("SmbService", "RPC unexpected share count: $count")
                return emptyList()
            }

            Log.i("SmbService", "RPC response: $count shares, level $infoLevel")

            // Array of SHARE_INFO_1 structures (12 bytes each)
            // Each: name_referent_id (4) + type (4) + comment_referent_id (4)
            data class ShareInfo(val namePtr: Int, val type: Int, val commentPtr: Int)
            val shareInfos = mutableListOf<ShareInfo>()
            for (i in 0 until count) {
                val namePtr = buf.int
                val type = buf.int
                val commentPtr = buf.int
                shareInfos.add(ShareInfo(namePtr, type, commentPtr))
            }

            // Read deferred strings (names and comments interleaved)
            // Each string: max_count (4) + offset (4) + actual_count (4) + data + padding
            for (info in shareInfos) {
                // STYPE_DISKTREE = 0, STYPE_PRINTQ = 1, STYPE_DEVICE = 2,
                // STYPE_IPC = 3, STYPE_SPECIAL = 0x80000000 (hidden)
                val isDiskShare = (info.type and 0xFF) == 0
                val isHidden = (info.type and 0x80000000.toInt()) != 0

                // Read name string
                if (info.namePtr != 0 && buf.remaining() >= 12) {
                    val maxCount = buf.int
                    val offset = buf.int
                    val actualCount = buf.int
                    if (actualCount > 0 && actualCount < 256 && buf.remaining() >= actualCount * 2) {
                        val nameBytes = ByteArray(actualCount * 2)
                        buf.get(nameBytes)
                        var name = String(nameBytes, Charsets.UTF_16LE)
                        // Remove trailing null
                        val nullIdx = name.indexOf('\u0000')
                        if (nullIdx >= 0) name = name.substring(0, nullIdx)

                        // Align to 4 bytes
                        val padding = (4 - ((actualCount * 2) % 4)) % 4
                        if (padding > 0 && buf.remaining() >= padding) {
                            buf.position(buf.position() + padding)
                        }

                        // Skip comment string if present
                        if (info.commentPtr != 0 && buf.remaining() >= 12) {
                            val cMaxCount = buf.int
                            val cOffset = buf.int
                            val cActualCount = buf.int
                            if (cActualCount > 0 && cActualCount < 256 && buf.remaining() >= cActualCount * 2) {
                                val commentBytes = ByteArray(cActualCount * 2)
                                buf.get(commentBytes)
                                val cPadding = (4 - ((cActualCount * 2) % 4)) % 4
                                if (cPadding > 0 && buf.remaining() >= cPadding) {
                                    buf.position(buf.position() + cPadding)
                                }
                            }
                        }

                        if (name.isNotEmpty() && name != "IPC$") {
                            items.add(mapOf(
                                "name" to name,
                                "path" to "/$name",
                                "isDirectory" to true,
                                "size" to 0L,
                                "modified" to 0L
                            ))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w("SmbService", "RPC response parse error: ${e.message}")
        }

        items.sortBy { (it["name"] as String).lowercase() }
        return items
    }

    /**
     * Probes a comprehensive list of common share names by attempting to
     * connectShare each one. Uses a dedicated bounded thread pool for
     * Android compatibility (avoids ForkJoinPool issues).
     */
    private fun listSharesViaProbing(entry: SmbSessionEntry): List<Map<String, Any>> {
        val commonNames = listOf(
            // Generic
            "share", "Shared", "Shares", "files", "Files", "data", "Data",
            "Public", "public", "Documents", "Docs", "doc",
            "Software", "Games", "work", "server", "fileshare",
            "project", "projects", "tmp", "Temp", "temp",
            "share1", "share2", "data1", "data2", "files1", "files2",
            // Media
            "Music", "music", "Videos", "videos", "Movies", "movies",
            "Photos", "photos", "Pictures", "pictures", "Images",
            "Media", "media", "TV", "Movie",
            "Anime", "anime", "Cartoons", "cartoons",
            "Documentaries", "documentaries", "Sports", "sports",
            // User
            "home", "Home", "homes", "Users", "users",
            "Downloads", "downloads", "Download", "Profile",
            // NAS / Storage
            "storage", "Storage", "backup", "Backup", "archive", "Archive",
            "NAS", "nas", "disk", "Disk", "cloud", "Cloud",
            "Volume1", "volume1", "Volume", "volume",
            "Volume2", "volume2", "Volume3", "volume3",
            "terramaster", "TerraMaster", "asustor", "Asustor",
            "buffalo", "Buffalo",
            // Common Samba defaults
            "everyone", "guest", "nobody", "root",
            // Synology
            "Public", "video", "photo", "music", "homes",
            // QNAP
            "Multimedia", "Public", "Web", "Recordings",
            // WD My Cloud
            "TimeMachineBackup", "SmartWare",
            // Chinese NAS common pinyin names
            "gongxiang", "gonggong", "xiazai", "yingyin",
            "yinyue", "tupian", "wenjian", "ziyuan",
            "shuju", "beifen", "yingshi", "boke",
            "xiazai", "ruanjian", "yingpan", "cangku",
            "jiankang", "shexiang", "shebei", "shequ",
            "bangong", "bangongwenjian", "xuexi", "xuexiziliao",
            "youxi", "youxianzhuang", "xiaoshuo", "xiaoshuowenjian",
            // Additional generic names
            "admin", "Admin", "administrator", "Administrator",
            "root", "usb", "USB", "usb1", "USB1",
            "external", "External", "external1", "External1",
            "media", "share", "shares", "Sharing", "sharing",
        )

        // Also try the username as a share name (common on Linux/Samba)
        val usernameShare = entry.username.ifEmpty { null }

        // Deduplicate case-insensitively, then build final list
        val tried = mutableSetOf<String>()
        val namesWithExtras = mutableListOf<String>()

        // Add all common names first
        for (name in commonNames) {
            if (name.isNotEmpty() && tried.add(name.lowercase())) {
                namesWithExtras.add(name)
            }
        }

        // Derive share names from the server hostname (e.g. "nas-server" → "nas-server", "nas", "server")
        val hostNameOnly = entry.host.split(".").firstOrNull()?.takeIf { it.isNotEmpty() } ?: ""
        if (hostNameOnly.isNotEmpty()) {
            val hostParts = hostNameOnly.split("-", "_", " ")
            for (part in hostParts) {
                val clean = part.trim().takeIf { it.isNotEmpty() && it.length >= 2 } ?: continue
                if (tried.add(clean.lowercase())) namesWithExtras.add(clean)
            }
            if (tried.add(hostNameOnly.lowercase())) namesWithExtras.add(hostNameOnly)
        }

        // Username as share name
        if (usernameShare != null && usernameShare.isNotEmpty() && tried.add(usernameShare.lowercase())) {
            namesWithExtras.add(usernameShare)
        }

        val uniqueNames = namesWithExtras

        Log.i("SmbService", "Probing ${uniqueNames.size} share names for ${entry.host}")

        // Use a cached thread pool — if threads block on slow connectShare calls
        // (up to soTimeout = 10s), new threads are spawned for the remaining probes
        // instead of waiting for the blocked ones. This prevents the probing from
        // stalling when many probes hit non-existent shares.
        val executor = Executors.newCachedThreadPool()
        try {
            // Return value: 0 = not found, 1 = accessible disk share, 2 = exists but access denied
            val futures = uniqueNames.map { name ->
                executor.submit<Pair<String, Int>> {
                    try {
                        val share = entry.session.connectShare(name)
                        val isDisk = share is DiskShare
                        try { share.close() } catch (_: Exception) {}
                        name to if (isDisk) 1 else 0
                    } catch (e: SMBApiException) {
                        val status = e.statusCode
                        if (status in ACCESS_EXISTS_STATUS_CODES) {
                            Log.i("SmbService", "Found share (access denied): $name (status=0x${status.toString(16)})")
                            name to 2
                        } else {
                            // STATUS_BAD_NETWORK_NAME, STATUS_OBJECT_NAME_NOT_FOUND, etc.
                            name to 0
                        }
                    } catch (e: Exception) {
                        name to 0
                    }
                }
            }

            val items = mutableListOf<Map<String, Any>>()
            for (future in futures) {
                try {
                    val (name, status) = future.get(3, TimeUnit.SECONDS)
                    if (status > 0) {
                        if (status == 1) {
                            Log.i("SmbService", "Found share: $name (accessible)")
                        }
                        items.add(mapOf(
                            "name" to name,
                            "path" to "/$name",
                            "isDirectory" to true,
                            "size" to 0L,
                            "modified" to 0L
                        ))
                    }
                } catch (_: Exception) {
                    // Timeout or error for this particular share — skip it
                    future.cancel(true)
                }
            }

            items.sortBy { (it["name"] as String).lowercase() }
            Log.i("SmbService", "Probing found ${items.size} shares")
            return items
        } finally {
            executor.shutdownNow()
        }
    }

    /**
     * Creates a directory at [path] inside the connected share.
     */
    fun createDirectory(sessionId: String, path: String): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(path)
        if (shareName.isEmpty()) throw Exception("Invalid path: no share name specified")

        return try {
            val share = getShare(entry, shareName)
            share.mkdir(pathInShare)
            true
        } catch (e: Exception) {
            throw Exception("Failed to create directory '$path': ${e.message}", e)
        }
    }

    /**
     * Creates an empty regular file at [path] inside the connected share.
     * The file is opened with FILE_CREATE so the call fails if it already exists.
     */
    fun createFile(sessionId: String, path: String): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(path)
        if (shareName.isEmpty()) throw Exception("Invalid path: no share name specified")

        return try {
            val share = getShare(entry, shareName)
            val file = share.openFile(
                pathInShare,
                EnumSet.of(AccessMask.GENERIC_WRITE),
                null,
                allShareAccess(),
                SMB2CreateDisposition.FILE_CREATE,
                null
            )
            try {
                // nothing to write - the act of opening with FILE_CREATE produces an empty file
            } finally {
                file.close()
            }
            true
        } catch (e: Exception) {
            throw Exception("Failed to create file '$path': ${e.message}", e)
        }
    }

    /**
     * Deletes the entry at [path]. When [isDir] is true the deletion is performed
     * recursively so non-empty directories are also removed.
     *
     * 实现说明：
     * smbj 0.13.0 的 deleteOnClose() 在某些 SMB 服务器（Samba、部分 NAS）上不可靠，
     * 因为它依赖 FILE_DISPOSITION_INFORMATION + SetInformation，而某些服务器对此处理不正确。
     *
     * 本实现采用两步删除策略：
     * 1. 首选方式：使用 FILE_DELETE_ON_CLOSE disposition 直接在打开时标记删除
     * 2. 回退方式：若首选失败，使用 GENERIC_WRITE + deleteOnClose() 作为备选
     *
     * 这样能兼容绝大多数 SMB 服务器实现。
     */
    fun delete(sessionId: String, path: String, isDir: Boolean): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(path)
        if (shareName.isEmpty()) throw Exception("Invalid path: no share name specified")

        return try {
            val share = getShare(entry, shareName)
            val shareAccess = allShareAccess()
            if (isDir) {
                deleteDirectoryRecursive(share, pathInShare, shareAccess)
            } else {
                deleteFileReliable(share, pathInShare, shareAccess)
            }
            true
        } catch (e: Exception) {
            throw Exception("Failed to delete '$path': ${e.message}", e)
        }
    }

    /**
     * 可靠的文件删除方法，采用两步策略兼容不同 SMB 服务器
     */
    private fun deleteFileReliable(
        share: DiskShare,
        pathInShare: String,
        shareAccess: Set<SMB2ShareAccess>
    ) {
        // 策略 1：使用 FILE_DELETE_ON_CLOSE disposition，打开时即标记删除
        // 这是最可靠的方式，直接在 SMB2 CREATE 请求中设置删除标记
        try {
            val file = share.openFile(
                pathInShare,
                EnumSet.of(AccessMask.DELETE, AccessMask.FILE_READ_ATTRIBUTES),
                null,
                shareAccess,
                SMB2CreateDisposition.FILE_OPEN,
                null
            )
            try {
                file.deleteOnClose()
            } finally {
                file.close()
            }
            return
        } catch (e: Exception) {
            // 策略 1 失败，尝试策略 2
        }

        // 策略 2：使用 GENERIC_WRITE + deleteOnClose()
        // 某些服务器要求 GENERIC_WRITE 而非 DELETE 访问掩码
        val file = share.openFile(
            pathInShare,
            EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.FILE_READ_ATTRIBUTES),
            null,
            shareAccess,
            SMB2CreateDisposition.FILE_OPEN,
            null
        )
        try {
            file.deleteOnClose()
        } finally {
            file.close()
        }
    }

    /**
     * Recursively deletes [pathInShare] and everything underneath it. Each
     * entry is opened with DELETE access and marked for delete-on-close.
     */
    private fun deleteDirectoryRecursive(
        share: DiskShare,
        pathInShare: String,
        shareAccess: Set<SMB2ShareAccess>
    ) {
        val listing: List<FileIdBothDirectoryInformation> = share.list(pathInShare)
        for (info in listing) {
            val name = info.fileName
            if (name == "." || name == "..") continue
            val childPath = if (pathInShare.isEmpty()) name else "$pathInShare\\$name"
            val isDirectory = (info.fileAttributes and FILE_ATTRIBUTE_DIRECTORY_BIT) != 0L
            if (isDirectory) {
                deleteDirectoryRecursive(share, childPath, shareAccess)
            } else {
                deleteFileReliable(share, childPath, shareAccess)
            }
        }
        // 删除目录本身
        val dir = share.openDirectory(
            pathInShare,
            EnumSet.of(AccessMask.DELETE, AccessMask.GENERIC_WRITE),
            null,
            shareAccess,
            SMB2CreateDisposition.FILE_OPEN,
            null
        )
        try {
            dir.deleteOnClose()
        } catch (e: Exception) {
            // 回退：尝试不带 GENERIC_WRITE
            dir.close()
            val dir2 = share.openDirectory(
                pathInShare,
                EnumSet.of(AccessMask.DELETE),
                null,
                shareAccess,
                SMB2CreateDisposition.FILE_OPEN,
                null
            )
            try {
                dir2.deleteOnClose()
            } finally {
                dir2.close()
            }
            return
        }
        dir.close()
    }

    /**
     * Renames [oldPath] to [newPath]. Both paths must live inside the same share.
     */
    fun rename(sessionId: String, oldPath: String, newPath: String): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (oldShareName, oldPathInShare) = resolveShareAndPath(oldPath)
        val (newShareName, newPathInShare) = resolveShareAndPath(newPath)
        if (oldShareName.isEmpty()) throw Exception("Invalid old path: no share name specified")
        if (newShareName.isEmpty()) throw Exception("Invalid new path: no share name specified")
        if (oldShareName != newShareName) throw Exception("Cross-share rename is not supported")

        return try {
            val share = getShare(entry, oldShareName)
            val diskEntry = share.open(
                oldPathInShare,
                EnumSet.of(AccessMask.GENERIC_WRITE),
                null,
                allShareAccess(),
                SMB2CreateDisposition.FILE_OPEN,
                null
            )
            try {
                diskEntry.rename(newPathInShare)
            } finally {
                diskEntry.close()
            }
            true
        } catch (e: Exception) {
            throw Exception("Failed to rename '$oldPath' to '$newPath': ${e.message}", e)
        }
    }

    /**
     * Downloads [remotePath] from the share to [localPath] on the local file system.
     * Parent directories of [localPath] are created when missing.
     */
    fun downloadFile(sessionId: String, remotePath: String, localPath: String): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(remotePath)
        if (shareName.isEmpty()) throw Exception("Invalid path: no share name specified")

        return try {
            val share = getShare(entry, shareName)
            val file = share.openFile(
                pathInShare,
                EnumSet.of(AccessMask.GENERIC_READ),
                null,
                allShareAccess(),
                SMB2CreateDisposition.FILE_OPEN,
                null
            )
            try {
                val localFile = java.io.File(localPath)
                localFile.parentFile?.mkdirs()
                file.getInputStream().use { input ->
                    localFile.outputStream().use { output ->
                        // 使用 64KB 缓冲区分块读取，比 Kotlin copyTo 默认 8KB 效率高
                        val buffer = ByteArray(64 * 1024)
                        var bytesRead: Int
                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            output.write(buffer, 0, bytesRead)
                        }
                        output.flush()
                    }
                }
            } finally {
                file.close()
            }
            true
        } catch (e: Exception) {
            throw Exception("Failed to download file '$remotePath' to '$localPath': ${e.message}", e)
        }
    }

    /**
     * Uploads the local file at [localPath] to [remotePath] inside the share.
     * An existing remote file is overwritten (FILE_OVERWRITE_IF).
     *
     * 大文件优化：
     * - 使用 64KB 缓冲区分块写入（默认 8KB 太小，SMB2 每次请求仅发 8KB 效率极低）
     * - 显式 flush 输出流，避免 smbj 缓冲过多数据导致 OOM
     * - 捕获中途写入异常，确保 file handle 在 finally 中关闭，避免远程句柄泄漏
     */
    fun uploadFile(sessionId: String, localPath: String, remotePath: String): Boolean {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(remotePath)
        if (shareName.isEmpty()) throw Exception("Invalid path: no share name specified")

        return try {
            val share = getShare(entry, shareName)
            val file = share.openFile(
                pathInShare,
                EnumSet.of(AccessMask.GENERIC_WRITE),
                null,
                allShareAccess(),
                SMB2CreateDisposition.FILE_OVERWRITE_IF,
                null
            )
            try {
                val localFile = java.io.File(localPath)
                if (!localFile.exists()) throw Exception("Local file does not exist: $localPath")
                localFile.inputStream().use { input ->
                    file.getOutputStream().use { output ->
                        // 使用 64KB 缓冲区分块写入，比 Kotlin copyTo 默认 8KB 效率高 8 倍
                        val buffer = ByteArray(64 * 1024)
                        var bytesRead: Int
                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            output.write(buffer, 0, bytesRead)
                        }
                        output.flush()
                    }
                }
            } finally {
                file.close()
            }
            true
        } catch (e: Exception) {
            throw Exception("Failed to upload file '$localPath' to '$remotePath': ${e.message}", e)
        }
    }

    /**
     * Returns the size in bytes of [remotePath] or -1 when the file cannot be
     * opened (e.g. it does not exist or is inaccessible).
     */
    fun getFileSize(sessionId: String, remotePath: String): Long {
        val entry = sessions[sessionId] ?: throw Exception("Invalid or disconnected session id")
        val (shareName, pathInShare) = resolveShareAndPath(remotePath)
        if (shareName.isEmpty()) return -1L

        return try {
            val share = getShare(entry, shareName)
            val file = share.openFile(
                pathInShare,
                EnumSet.of(AccessMask.FILE_READ_ATTRIBUTES),
                null,
                allShareAccess(),
                SMB2CreateDisposition.FILE_OPEN,
                null
            )
            try {
                val info = file.getFileInformation(FileStandardInformation::class.java)
                info.endOfFile
            } finally {
                file.close()
            }
        } catch (e: SMBApiException) {
            -1L
        } catch (e: Exception) {
            -1L
        }
    }

    /**
     * Tears down the session identified by [sessionId]: closes every cached
     * share, the session, the connection and the client. Returns false when the
     * session id was unknown.
     */
    fun disconnect(sessionId: String): Boolean {
        val entry = sessions.remove(sessionId) ?: return false
        try {
            entry.shares.values.forEach { share ->
                try {
                    share.close()
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
            entry.shares.clear()
            try { entry.session.close() } catch (e: Exception) { e.printStackTrace() }
            try { entry.connection.close() } catch (e: Exception) { e.printStackTrace() }
            try { entry.client.close() } catch (e: Exception) { e.printStackTrace() }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return true
    }

    /**
     * Returns the [DiskShare] for [shareName], connecting to it lazily and
     * caching the result so repeated operations do not re-open the tree.
     */
    private fun getShare(entry: SmbSessionEntry, shareName: String): DiskShare {
        return entry.shares.computeIfAbsent(shareName) {
            entry.session.connectShare(shareName) as DiskShare
        }
    }

    /**
     * Splits a Dart-style forward-slash path into a share name and the
     * backslash-separated path inside that share.
     *
     * Examples:
     *   "/Public/Movies/film.mp4" -> ("Public", "Movies\\film.mp4")
     *   "Public"                  -> ("Public", "")
     *   "/"                       -> ("", "")
     */
    private fun resolveShareAndPath(fullPath: String): Pair<String, String> {
        val cleaned = fullPath.trim().trimStart('/').trimStart('\\')
        if (cleaned.isEmpty()) return Pair("", "")

        val segments = cleaned.split('/', '\\').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return Pair("", "")

        val shareName = segments[0]
        val pathSegments = segments.drop(1)
        val pathInShare = pathSegments.joinToString("\\")

        return Pair(shareName, pathInShare)
    }
}
