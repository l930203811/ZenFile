# AI 协作工作日志 (WORKLOG)

> 本文件用于 TRAE 与 WorkBuddy（或其他 AI 工具）协同优化本项目时的信息同步。
> **规则**：每次修改代码前先读本文件了解近期改动；修改完成后，在「改动记录」顶部追加一条记录。
> 格式：`### [日期] 工具名 - 简述【状态】`，下方列出改动的文件、内容、原因。
>
> **状态标记规则**（在标题末尾用方括号标注）：
> - 新改动完成后填 **【待验证】**
> - 用户验证通过后改为 **【已解决】**
> - 用户反馈仍未解决则改为 **【未解决】**，并在记录下方补充失败原因和后续方向

---

## 改动记录

### [2026-08-05] WorkBuddy - 修复部分安卓 15/16 设备 UI 卡顿（Impeller + 键盘 resize）【待验证】

**问题**：
- 部分安卓 15 用户反馈打开应用后 UI 很卡
- 安卓 16 用户反馈一旦打开输入框（重命名、配置远程客户端等）即出现 UI 卡顿
- 非所有安卓 15/16 用户复现；用户本人的安卓 11 老旧设备从未出现

**根因**：
1. 主因：Impeller 渲染器在部分新设备 GPU 驱动（Mali/Adreno/PowerVR 等）上 raster/着色性能回退，导致掉帧；旧设备驱动对 Impeller 友好故正常。Flutter 3.22+ 起 Impeller 为安卓默认渲染器（本项目 Flutter 3.44.1）。键盘弹起时的逐帧重绘把该回退放大，故"打开输入框"症状最明显。
2. 加重因素：`AndroidManifest` 的 `android:windowSoftInputMode="adjustResize"` 会让键盘弹起时整个 Flutter surface 被 OS resize，触发逐帧整屏重排+重绘；`home_screen` 虽已设 `resizeToAvoidBottomInset:false` 且缓存宽度，但底层 native surface resize 仍在。
3. 排除项：`home_screen` 未重写 `didChangeMetrics`，对话框均为轻量 `AlertDialog`+`TextField`，无应用层逐帧重建风暴——确认是渲染/inset 层面问题，非业务逻辑。

**修复**：
1. `android/app/src/main/AndroidManifest.xml`：新增 `io.flutter.embedding.android.EnableImpeller=false`，禁用 Impeller 回退 Skia 渲染器（可复现后改回 true）。
2. 同文件 activity：`android:windowSoftInputMode` 由 `adjustResize` 改为 `adjustPan`。避免键盘弹起整窗 resize 引发的逐帧重排；对话框仍凭 `MediaQuery.viewInsets` 自行上移，各屏幕已手动处理 inset（`more_settings`/`text_editor`/`wizard` 等），无视觉回退。

**验证**：需在安卓 15/16 受影响设备上本地 `assembleRelease` 安装验证：1) 打开应用是否流畅；2) 重命名/远程配置输入框弹起键盘是否不再卡顿。

### [2026-08-05] WorkBuddy - 移除备用图标功能（APK 体积优化）【已解决】

**问题**：
- 二次开发后 APK 由 NFile 的 52MB 涨到 68MB，用户怀疑备用图标导致体积膨胀（曾添加后又移除部分图标，疑有残留）。

**排查**：
- `android/app/src/main/res/drawable/design_1..11.png` 共 ~4.81MB；其中选择器 `_showAppIconPickerDialog` 实际只暴露 `default`、`design3`、`design7`、`custom` 四个选项，`design1/2/4/5/6/8/9/10/11` 九个 PNG 完全是死资源（未进 UI、未进 label），但被 `MainActivityDesign1-11` activity-alias 引用故未被 shrinkResources 剔除，真实进包。
- `assets/logo/zf_m3_expressive_3.png`(281KB)、`zf_neumorphism.png`(489KB) 仅作为 design3/design7 的预览图被选择器引用；assets 不被 shrinkResources 剔除，真实进包。
- `media_kit` 的 `libmpv.so`（约 12MB/架构）是最大单项，按用户选择**保留**。

**修复（移除备用图标功能）**：
1. 删除死资源：`res/drawable/design_1..11.png`（~4.81MB）、`assets/logo/zf_m3_expressive_3.png`、`zf_neumorphism.png`（~770KB）。合计约 5.58MB。
2. `AndroidManifest.xml`：移除 `MainActivityDesign1-11` 与 `MainActivityCustom` activity-alias，保留 `MainActivityDefault` + `ic_launcher_default.png`（默认图标）。自定义图标仍走桌面快捷方式（Option B），不受影响。
3. `MainActivity.kt`：
   - `changeAppIcon` 允许列表收窄为仅 `com.sequl.zenfile.MainActivityDefault`。
   - **新增启动修复**：`onCreate` 中强制 `PackageManager.setComponentEnabledSetting(..., ENABLED, DONT_KILL_APP)` 启用 `MainActivityDefault`。原因：旧版启用 design 别名时会把 `MainActivityDefault` 置为 DISABLED，而组件启用状态跨应用更新持久化；本版本移除 design 别名后，若不在启动时强制启用默认别名，之前启用过 design 图标的用户更新后将**失去桌面启动图标**。
4. `lib/providers/file_manager_provider.dart`：
   - init 时把持久化值 `design*` 归一为 `default` 并写回，避免界面状态与实际图标不一致。
   - `setActiveAppIcon` 删除 design1-11 的 switch 分支，仅保留 default 别名映射与 `custom` 早返回。
5. `lib/ui/screens/more_settings_screen.dart`：
   - `_getAppIconLabel` 删除 `design3`/`design7` 分支。
   - `_showAppIconPickerDialog` 删除 design3/design7 预览卡（保留 `default` + 自定义卡片）。

**校验**：`flutter analyze lib` 0 error（仅预存在的 info/warning 级 lint，与本改动无关）。

**说明**：`build/` 下的 mapping/manifest 缓存是构建产物、每次构建重建且不进 APK，并非"残留缓存"；移除源资源后重新打出的 APK 不再含 design 图标。

**验证**：本地 `assembleRelease` 重新打包，比对 APK 体积（预期 res/drawable 与 assets 减小约 5.5MB+）；并在一台**此前启用过备用图标**的设备上升级安装，确认桌面启动图标正常出现。

### [2026-08-02] TRAE - 修复 SMB 上传占用上行带宽+速率不达标，FTP 上传速率优化【待验证】

**问题**：
1. SMB 从本地上传到远程（飞牛 NAS），飞牛显示上行 70MB/s、下行仅 7-8MB/s，实际写入速率只有 7-8MB/s，且占用服务器上行带宽（正常应只显示下行）
2. FTP 本地上传到远程，飞牛显示 1-2MB/s 占用上行带宽
3. 下载方向均正常

**根因**：
1. SMB：`uploadFilePipelined` 使用 window=16 的 `writeAsync` 窗口化写入（16×256KB=4MB 数据同时在途），大量 WRITE 请求堆积导致服务器响应堆积和重传，带宽被协议开销吞掉。与之前下载端已修复的双缓冲问题同源
2. FTP：`localFile.openRead()` 默认 64KB 分块 + 每 512KB flush，chunk 过小影响吞吐
3. SMB 第二轮优化根因：`getOutputStream()` 内部按 maxWriteSize 拆分 1MB buffer 为多个 WRITE 请求，每个请求需服务器回送响应（走上行），响应数量多导致上行带宽仍有占用；且 `getOutputStream().close()` 会发送额外 FLUSH 请求

**修复**：
1. SMB `uploadFile` 直接调用 `uploadFileStreamed`，弃用 pipelined writeAsync 窗口化。与 `downloadFile` 的 streamed 架构对称
   - 文件：`android/app/src/main/kotlin/com/sequl/zenfile/SmbService.kt` L1300-1312
2. SMB `uploadFileStreamed` 最终方案：用 `file.write(buffer, offset, 0, bytesRead)` 同步方法替代 `writeAsync().get()` 和 `getOutputStream()`
   - writeAsync 的问题：内部 while 循环会自动发出多个异步请求并堆积，反而增加上行流量
   - getOutputStream 的问题：close() 时发送额外 FLUSH 请求
   - file.write() 是纯同步：发一个 WRITE 请求 → 等响应 → 返回，无额外开销
   - chunkSize = min(maxWriteSize, 1MB)，确保每次只发一个请求
   - 文件：`android/app/src/main/kotlin/com/sequl/zenfile/SmbService.kt` L1608-1643
3. **发现 pipelined 代码 bug**：`uploadFilePipelined` 中 `file.writeAsync(data, offset, data.size, data.size)` 的第三个参数（bufferOffset）= data.size 越界，导致 ArrayIndexOutOfBoundsException，被 uploadFile catch 后 fallback 到 streamed。所以用户之前看到的"SMB 上传成功"一直是 streamed fallback 在工作，pipelined 从未真正执行成功
4. FTP 上传改用 `RandomAccessFile.readInto` + 1MB `Uint8List` buffer 读取，flush 间隔从 512KB 增至 1MB，与下载路径对称
   - 文件：`lib/services/remote/ftp_client.dart` L710-748

**注意**：FTP 上传时飞牛显示上行带宽可能部分来自 openlist 内部处理（临时文件写入/复制），此部分非客户端代码可控。

### [2026-08-04] WorkBuddy - 复核 SMB/FTP 上传带宽问题：确认 TRAE 结论 + 定位"上传期下行"真正来源【待验证】

**与 TRAE 结论对齐**：TRAE 已发现同一 `writeAsync` 缓冲偏移越界 bug（L37）并决定 `uploadFile` 直接走同步 `uploadFileStreamed`、弃用 pipelined。WorkBuddy 此前实现的 pipelined 上传因该 bug 实际从未成功执行（首写越界→catch→回退 streamed），故当前行为本就是单飞同步写，与 TRAE 意图一致。WorkBuddy 已回退对 pipelined 的偏移修正，避免与 TRAE 决定冲突。

**关于"上传期还有下行流量"的真正来源（关键）**：SMB 写是纯写，WRITE 响应极小，物理上不可能产生 ~50MB/s 下行。而用户当前构建用的是单飞同步写（纯写）却仍显示 50MB/s 下行 → **反证该下行不是传输层，而是应用层把刚上传的文件又读回**。证据链：`media_provider.dart:320` 的 `downloadRange(...,0,2MB)` 失败会回退**完整下载**（L323「downloadRange 失败，回退完整下载」）；`file_item`/`file_grid_item` 的 `_loadVideoThumb` 也会读回远程文件。目录轮询刷新在上传中途揭示文件 → UI 立即触发缩略图读回 → 与上传重叠，表现为上下行同时占用。TRAE 归因为"writeAsync 响应堆积"对该构建不成立（构建未用 pipelined）。

**FTP 上传 ~1-2MB/s 下行 = 正常 TCP ACK 开销**：满速上传时服务端回送 ACK 约占 2-3% 带宽（≈1-2MB/s），不可避免，非 bug。SMB 的 50MB/s 远超 ACK 量级，故确认为上方"缩略图整文件读回"。

**待办 / 与 TRAE 协调**：
1. SMB 上传"速率不达标 + 双向占用"的真正修复点是**门控缩略图生成**：上传中或刚上传完成的文件暂不生成缩略图，待操作 settle 后再生成（消除读回与上传重叠，让上传独占带宽）。该改动涉及 media_provider/UI，属 TRAE 媒体域，建议先与 TRAE 沟通再动。
2. 若门控后单飞同步写上探不到 100MB/s（受 maxWriteSize 限制），再评估是否启用「偏移已修正的 pipelined」——届时需重新验证 pipelined 是否真引入额外下行（与 TRAE 原假设复核）。

### [2026-08-02] WorkBuddy - 修复 FTP 下载速率被限到 30-40MB/s（flush 间隔过小）【已解决】

**问题**：飞牛 NAS 上 SMB 两端 + FTP 下载均只有 30-40MB/s，而 FTP 上传满速 ~100MB/s。
- 排查：四协议上传代码均只写不读，无反向流量（前轮结论，已排除“读回校验”类假设）。
- 根因（FTP 下载）：`_downloadWithRawSocket` 每 **64KB** 就 `await sink.flush()` 写盘，卡住 `await for` 读循环 → TCP 接收窗口被收缩 → 服务端被限流。上传用 512KB flush 故满速。
- 修复：`lib/services/remote/ftp_client.dart` 将下载 `flushInterval` 由 64KB 改为 **1MB**，读循环不再频繁被打断，下载应跑满带宽（与上传同思路）。

**SMB 两端 30-40MB/s（已实施流水线化改造，待验证）**：
- 根因：原生 smbj 的 SMB2 READ/WRITE 为**同步单飞**（发一笔等响应再发下一笔），有效吞吐 ≈ 单次请求大小 / RTT。连接已 `withNegotiatedBufferSize()` 协商到服务端上限；若飞牛 NAS 的 SMB MTU 上限为 64KB（SMB2 默认值、未启用 Large MTU），单飞 ≈ 64KB/RTT ≈ 30-40MB/s，与实测吻合。
- 修复：`android/app/src/main/kotlin/com/sequl/zenfile/SmbService.kt` 改用底层 `File.writeAsync(byte[],long,int,int)`（**public**）保持多笔写请求在途；下载侧 `File.readAsync(long,int)` 是**包私有**，本应用不在该包内无法直接调用 → 用**反射**调用 `readAsync`（smbj 内部即如此实现 SMB2 多请求在途读），以滑动窗口（window=16）保持多笔读请求在途（吞吐 ≈ 窗口数 × 单请求大小 / RTT，可跑满 100MB/s）。每笔请求带绝对 offset，顺序无关；下载侧把乱序到达的块按 offset 顺序落盘。单请求大小取 `getNegotiatedProtocol().getMaxWriteSize()/getMaxReadSize()` 与 256KB 的较小者。
- 安全网：新增 `uploadFile`/`downloadFile` 分发器先走流水线化路径，异常时回退原 `uploadFileStreamed`/`downloadFileStreamed`（单线程）实现，保证 SMB 不会因异步路径异常而整体失效。下载侧 `readAsync` 反射 lazy 缓存 `Method`，并对 `SMBApiException`（读到 EOF）按文件尾处理。
- 诊断：`connect()` 新增 `Log.d` 打印协商到的 maxWrite/maxRead，验证 64KB 上限假设（也证明新代码路径已执行）。proguard 已有 `-keep class com.hierynomus.smbj.** { *; }`，`readAsync` 不会被混淆，反射在 release 也安全。
- 编译修正：首版直接用 `file.readAsync` 触发 `Cannot access 'readAsync': it is package-private` 编译错误；改为反射调用后已解决。反射 `getDeclaredMethod` 必须用基本类型 `long.class/int.class`（`Long::class.javaPrimitiveType`），否则匹配不到签名会运行时静默回退慢速路径。
- 编译未在此沙箱完整验证：gradle 报缺少 Flutter engine 的 `flutter-maven-repo` 本地构件（环境缺失，非代码错误）；所有 smbj API 已用 javap 对照 0.13.0 jar 核实。需用户在本地构建验证。

---

### [2026-08-02] WorkBuddy - 修复 openlist 本机储存 SFTP/FTP 上传后残留临时文件 + FTP 手动刷新闪退【已解决】

**问题**（TRAE 多次未解决，现由 WorkBuddy 接手）：
- 问题2：SFTP 上传完成、进度条关闭后，远程目录显示原文件 + 临时文件，临时文件大小=本地原文件，远程原文件大小从 0KB 随等待增长直到合并。
- 问题3：FTP 上传完成、进度条关闭后，原文件 + 临时文件残留，通知栏网速停几秒后又疯狂传输；此时手动刷新远程目录会闪退，重启后发现文件已上传。
- 问题4：问题2/3 仅出现在 openlist 挂载**本机储存**目录，上传到 openlist 挂载的网盘目录正常（故非 openlist 本身问题，是“服务端暂存 + 异步落盘”机制与客户端轮询策略冲突）。

**根因**：
1. 旧 `scheduleRemoteRefreshAfterUpload` 每 2s 调用 `loadDirectoryForTab` 刷新**可见目录**，把 openlist 本机储存的 staging 中间态（临时文件 + 目标文件流式增长）直接暴露给用户（问题2 的可见性根因）。
2. 对 FTP 而言每次刷新都是同一单连接 `_ftpConnect` 的 CWD+LIST；后台轮询与用户手动刷新并发时竞争同一连接 → CWD 状态错乱 → 闪退（问题3 根因）。“网速图标停后疯狂传输”是 openlist 本机储存后台异步把临时文件复制到最终文件（耗时≈重传），并非真的重传。

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - 重写 `scheduleRemoteRefreshAfterUpload`：后台轮询 `client.finalizeUpload()` 判断服务端是否已最终化，**轮询期间不刷新可见目录**；仅当 `finalizeUpload` 返回 true 后做一次 `loadDirectoryForTab` 一次性揭示。首轮 `i==0` 立即检测（不延迟），避免 WebDAV/SMB/网盘等原子上传出现揭示延迟。达到 maxAttempts 后做最后一次尽力刷新。
  - `_pasteLocalToRemote()` finally **移除**上传结束后的立即 `loadDirectoryForTab(targetTabIndex, currentPath, ...)`（旧逻辑会立刻暴露 staging），最终化揭示改由上述轮询统一负责。
  - 新增 `_pendingFinalizePaths`（每个 tab 正在最终化的路径集合）：`scheduleRemoteRefreshAfterUpload` 启动时注册、结束时注销；`loadDirectory` 远程分支若命中 pending 路径则直接跳过，防止手动下拉刷新 / 页面重入等入口把 staging 暴露出来（补充防御）。
  - 删除已无调用的 `_isLikelyTempFile`（provider 侧临时文件检测已被各客户端 `finalizeUpload` 取代）。
- `lib/services/remote/ftp_client.dart`
  - 新增 `_serialize`（Future 链异步互斥锁），串行化所有依赖单连接的 CWD 操作。
  - `listDirectory` → 公共方法仅加锁，实际逻辑抽到 `_listDirectoryInner`；`listDirectoryContentSafe` 改调 `_listDirectoryInner`（持锁内，避免死锁）。
  - `finalizeUpload` 包进 `_serialize(() => _finalizeUploadInner(...))`；`_finalizeUploadInner` 直接调 `_listDirectoryInner` 并在锁内执行 rename 分支（CWD 与并发 LIST 互斥，消除闪退）。
- `lib/services/remote/sftp_client.dart`
  - 同样新增 `_serialize` 互斥锁，`listDirectory` 加锁（逻辑抽到 `_listDirectoryInner`）；原生通道由 Java 侧自行处理并发，不在此列。

**协作边界**：仅改“最终化等待 = 后台静默轮询 finalizeUpload，期间不刷新可见目录”的策略，与 FTP/SFTP 的 `finalizeUpload` 既有判定逻辑（不主动 rename、流式等待等，属 TRAE 负责）无冲突；未触碰速率计算/精度。问题1（FTP/SFTP 同服务器剪切未瞬时）疑似与 rename 在 openlist 本机储存失败回退 download+upload 同源，待本修复验证后确认。

**校验**：`flutter analyze lib` = 0 error（1422 issues = 17 warning + 1405 info，比基线 1424 少 2：移除了 `_isLikelyTempFile` 与一处多余 `!`）。

### [2026-08-02] WorkBuddy - 远程→远程剪切优化为同服务器直接 rename 移动（免下载再上传）【已解决】

**问题**：远程目录剪切文件时，无论源与目标是否同一服务器，都先下载到本地临时目录再上传到目标远程（download+upload+delete），既慢又吃本地存储。应在同一远程服务器下直接 move（rename）。

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - 新增 `_isSameRemoteConnection(a, b)`：比较 `type/host/port/username` 判定两连接是否同一服务器（rootPath 不同也算同服务器）。
  - `_pasteRemoteToRemote()` 开头计算 `sameServerCut = _isCut && 源连接与目标 tab 连接同服务器`。
  - 统计分支：`sameServerCut` 时进度按**文件数**（不实际传输字节，`totalBytesAll=1`）；否则保留原远程递归字节统计 ×2。
  - 新增 `emitMoveProgress()`：按文件数发进度（无速率，移动是元数据操作）。
  - 循环体：先尝试 `targetClient.rename(源路径, 目标路径)` 直接移动；**rename 失败（个别协议/目录不支持）回退**到原 download+upload 流程。`ConflictResult.overwrite` 时先 `delete` 目标（WebDAV MOVE 默认不覆盖）。冲突 `skip/keepBoth` 逻辑保持不变。
  - 删除源步骤改为 `if (_isCut && !movedInPlace)`（rename 已移动源，不再删）。
  - finally：`sameServerCut` 时跳过 `scheduleRemoteRefreshAfterUpload`（rename 不产生服务端临时文件，无需 finalize 轮询）。
- 校验：`flutter analyze lib` = 0 error、0 warning（1425 issues 均为 info 级，与基线一致）。

**协作边界**：仅改动 `file_manager_provider.dart` 的远程→远程**剪切调度**逻辑，复用了各客户端既有 `RemoteClient.rename()`（ftp/sftp/webdav/lan/saf 均已实现）。**未触碰** TRAE 负责的速率计算/精度（`_TransferSpeedTracker`）、上传 `finalizeUpload`、SFTP 临时文件 rename 限制、刷新轮询逻辑本身；`scheduleRemoteRefreshAfterUpload` 仅增加跳过条件，未改其实现。注意：本次是移动**用户真实文件**，与 TRAE 所述「openlist 上传 finalize 时主动 rename 临时文件导致数据丢失」是不同场景，不冲突。

---

### [2026-08-02] WorkBuddy - 修复 FTP 远程→本地下载点击取消无法及时中断【已解决】

**问题**：FTP 客户端从远程复制文件到本地时，点击进度条取消按钮后无法及时中断，后台仍持续下载直到完成。

**根因**：
1. `FtpRemoteClient.cancel()` 只销毁**上传**使用的独立控制/数据 socket，未销毁**下载** socket。
2. 主下载路径 `_downloadWithRawSocket` 在 `await for` 循环顶部检查 `isCancelled`，但若 raw socket 抛异常会静默 **fallback 到 `ftpconnect.downloadFile` 缓冲路径**，而该 fallback 路径**完全没有 `isCancelled` 检查**，导致取消失效、后台下载至完成。

**改动文件**：
- `lib/services/remote/ftp_client.dart`
  - 新增实例字段 `_activeDownloadControlSocket` / `_activeDownloadDataSocket`，在 `_downloadWithRawSocket` 建立 socket 后赋值，供取消时销毁。
  - `cancel()`：补充销毁上述下载 socket，实现 fail-fast 中断。
  - `_downloadWithRawSocket` 的 `finally`：`sink/dataSocket/controlSocket` 的 `close()` 全部包 try/catch（取消已 destroy 时 close 会抛），并清空两个下载 socket 实例字段。
  - 公开 `downloadFile`：raw socket 路径若因取消抛异常，直接删半截文件并 `throw Exception('Cancelled')`，**不再回退**到不可取消的 ftpconnect 路径。
  - fallback（ftpconnect）路径：`onProgress` 回调内加 `if (isCancelled) throw Exception('Cancelled')`；下载完成后若 `isCancelled` 也删半截文件并抛出。
- 校验：`flutter analyze lib` = 0 error（1424 issues = 基线 17 warning + 1407 info，无新增 error）。

**协作边界**：本修复仅针对 FTP 客户端**下载取消机制**（`ftp_client.dart`），未触碰 TRAE 负责的 `file_manager_provider.dart` 速率计算/精度逻辑，也未改动 TRAE 的 SFTP/WebDAV/FTP 上传取消与刷新相关代码。

**影响说明**：取消 FTP 下载现在会立即销毁数据 socket 并删除半截文件；正常下载不受影响（仅多存两个 socket 引用，finally 已清空）。

---
## 改动记录

### [2026-08-02] TRAE - 修复浏览页本地视频缩略图回退到 PhotoManager【已解决】

**问题**：本地浏览页仍然不能显示部分 mp4 文件缩略图，但分类页能正常显示同样的视频。

**根因**：
- `MediaThumbnailService.generateVideoThumbnail` 通过原生 `MediaMetadataRetriever.setDataSource(filePath)` 直接读取文件，对某些视频编码或路径权限可能失败
- 分类页用 `AssetEntity.thumbnailDataWithSize`（系统媒体库 API，有预生成缓存，不直接读取文件），更可靠
- 浏览页的 `_loadVideoThumb` 在系统媒体库文件名匹配失败时，只回退到 `MediaThumbnailService`，缺少 `PhotoManager` 路径匹配回退

**改动文件**：
- `lib/ui/widgets/pane_browser.dart`
  - 新增 `import 'package:photo_manager/photo_manager.dart'`
  - `_loadVideoThumb()`：在 `MediaThumbnailService` 回退之前加 `PhotoManager.getAssetListRange` 按路径查找 AssetEntity 回退（走系统媒体库 API，更可靠）
- `lib/ui/widgets/file_grid_item.dart`
  - 新增 `import 'package:photo_manager/photo_manager.dart'`
  - `_loadVideoThumb()`：同上，加 `PhotoManager` 路径匹配回退
- `lib/ui/widgets/file_item.dart`
  - `_loadVideoThumbFromFile()`：调整顺序，先 `PhotoManager`（系统媒体库 API 更可靠），再 `MediaThumbnailService`（直接读取文件，覆盖不在相册中的文件）

**回退优先级**（三个文件统一）：
1. 从 `mediaProvider.videos` 按文件名匹配 → `ThumbnailCache.get`（最快，有缓存）
2. `PhotoManager.getAssetListRange` 按路径查找 AssetEntity → `thumbnailDataWithSize`（系统媒体库 API，不直接读取文件）
3. `MediaThumbnailService.generateVideoThumbnail`（原生 MediaMetadataRetriever，覆盖不在相册中的文件）

**协作边界**：仅修改 `pane_browser.dart`、`file_grid_item.dart`、`file_item.dart`，未触碰 WorkBuddy 改动的文件。

---

### [2026-08-02] TRAE - 修复浏览页缩略图开关失控和本地视频无缩略图【已解决】

**问题**：
1. 本地浏览页（双窗口分屏）的本地视频不显示缩略图，但分类页能正常显示
2. 关闭远程媒体缩略图开关后，远程目录的视频仍能在浏览页显示缩略图

**根因**：
1. **本地视频无缩略图**：`pane_browser.dart` 的 `_loadVideoThumb` 只从 `mediaProvider.videos`（系统媒体库）查询，未命中时直接返回不显示，缺少 `MediaThumbnailService` 回退（与 `file_item.dart`/`file_grid_item.dart` 同类问题）
2. **远程缩略图无视开关**：`pane_browser.dart` 的 `initState` 加载远程缩略图时没检查 `getRemoteMediaThumbnailPreview()`；`build` 方法只检查本地开关 `showMediaPreviews`，没检查远程开关

**改动文件**：
- `lib/ui/widgets/pane_browser.dart`
  - `_CompactMediaThumbnailState.initState()`：远程缩略图加载增加 `PreferencesService.getRemoteMediaThumbnailPreview()` 检查；本地视频/音频缩略图加载增加 `!widget.file.isRemote` 条件
  - `_loadVideoThumb()`：系统媒体库未命中时回退使用 `MediaThumbnailService.generateVideoThumbnail(widget.file.path)` 生成缩略图
  - `build()`：本地开关检查后新增远程开关检查，远程文件在远程开关关闭时显示默认图标
  - 新增 `import '../../services/preferences_service.dart'`

**协作边界**：仅修改 `pane_browser.dart`，未触碰 WorkBuddy 改动的文件。

---

### [2026-08-02] TRAE - 修复媒体缩略图开关控制和本地视频无缩略图问题【已解决】

**问题**：
1. 部分视频文件在本地没有显示缩略图预览，上传到远程目录后却显示缩略图
2. 设置—媒体偏好页面下的「本地媒体缩略图」和「远程媒体缩略图」开关无法控制分类页的缩略图显示

**根因**：
1. **本地视频无缩略图**：`file_item.dart` 和 `file_grid_item.dart` 的 `_loadVideoThumbFromFile`/`_loadVideoThumb` 仅依赖 `PhotoManager.getAssetListRange` 查询相册视频，但相册只收录 DCIM/Movies 等目录，下载目录、NAS 挂载目录等不在相册中的视频找不到匹配的 AssetEntity，导致无缩略图
2. **分类页开关失控**：`media_category_screen.dart` 完全没有使用本地开关 `showMediaPreviews`，本地视频/图片/音频缩略图不受开关控制；远程缩略图只检查远程开关，没检查本地开关

**改动文件**：
- `lib/ui/widgets/file_item.dart`
  - `_loadVideoThumbFromFile()`：改为优先使用 `MediaThumbnailService.generateVideoThumbnail(filePath)` 直接从文件路径生成首帧缩略图（与远程视频缩略图生成方式一致，不依赖系统媒体库），失败时回退到 `PhotoManager`
- `lib/ui/widgets/file_grid_item.dart`
  - `_loadVideoThumb()`：在系统媒体库未命中时，回退使用 `MediaThumbnailService.generateVideoThumbnail(widget.file.path)` 生成缩略图
- `lib/ui/screens/media_category_screen.dart`
  - `_buildVideoTile()`：新增 `showMediaPreviews` 和 `showRemoteThumb` 判断，本地开关关闭时不显示缩略图（显示默认图标），远程文件需同时开启本地和远程开关
  - `_buildVideoListTile()`：同上，列表视图也受开关控制
  - `_buildImageTile()`：图片分类页也受开关控制
  - `_buildAudioTile()`：音频封面受本地开关控制

**协作边界**：本次仅修改 `file_item.dart`、`file_grid_item.dart`、`media_category_screen.dart`，未触碰 WorkBuddy 改动的文件。

---

### [2026-08-02] TRAE - 修复 FTP 双后台任务竞争连接导致网络风暴和闪退【已解决】

**问题**：
1. SFTP 已正常（只显示原文件，大小从 0 增长到完整后停止）
2. FTP 上传完成后进度条关闭，但 Android 网络指示器持续疯狂传输，持续时间约等于重新上传时间
3. 手动刷新远程目录会导致应用闪退

**根因**：
FTP 有**两个后台任务同时高频操作同一个 FTP 连接**：
1. `_awaitUploadFinalized`：每 500ms 调用 `finalizeUpload`（内部做 FTP LIST + PASV 数据连接）
2. `scheduleRemoteRefreshAfterUpload`：每 300ms 调用 `finalizeUpload` + `loadDirectoryForTab`（也做 FTP LIST）

两者叠加 ≈ 每 190ms 做一次完整 FTP LIST（PASV 握手 + LIST 响应 + 关闭数据连接）。FTP 是**单连接协议**，不支持并发操作。两个任务竞争同一个 `_ftpConnect`，加上 `finalizeUpload` 内部自己 LIST 后 `loadDirectoryForTab` 又 LIST 一次（双倍请求），导致：
- 连接状态混乱 → **大量网络活动**（PASV 握手 + LIST 响应 + 重连）
- 手动刷新时三方竞争 → **应用闪退**

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - `_pasteLocalToRemote()` / `_pasteRemoteToRemote()`：移除 `_awaitUploadFinalized` 调用（功能已被 `scheduleRemoteRefreshAfterUpload` 取代，避免两个任务同时操作 FTP 连接）
  - `scheduleRemoteRefreshAfterUpload()`：
    - 轮询间隔 300ms → 2000ms，轮询次数 200 → 120（总时长 240s，覆盖 openlist 复制时间）
    - 移除 `finalizeUpload` 调用（它内部自己 LIST 与 `loadDirectoryForTab` 的 LIST 重复，双倍网络请求）
    - 直接用 `loadDirectoryForTab` 刷新后的 `tab.currentFiles` 判断临时文件和目标文件状态

**效果**：每 2 秒只做一次 FTP LIST（PASV 数据连接），不再有竞争，不再有闪退，网络活动大幅减少。

**协作边界**：仅修改 `file_manager_provider.dart`，未触碰 WorkBuddy 改动的文件。

---

### [2026-08-02] TRAE - 修复 SFTP 主动 rename 导致 openlist 文件丢失【已解决】

**问题**：
1. SFTP 上传完成后主动 rename 临时文件，导致**临时文件和目标文件都被删除**，重启应用后远程目录没有任何文件
2. FTP 上传完成后出现原文件和临时文件，等待一段时间或重启后正常显示

**根因**：
openlist 的 SFTP 服务端有内部状态机管理 `file-<数字>` 临时文件到目标文件的生命周期。客户端主动 rename 会破坏这个状态机：
- openlist 检测到临时文件被 rename/移走 → 中止复制流程
- openlist 自己生成的目标文件（从临时文件复制数据）也被中断
- 结果：临时文件被 rename 后消失，目标文件复制中断也被清理 → **数据丢失**

FTP 之前已修复（目标已存在时不主动 rename），SFTP 沿用了相同策略。

**改动文件**：
- `lib/services/remote/sftp_client.dart`
  - `finalizeUpload()`：**完全移除主动 rename 逻辑**，改为只做检测：
    - 有临时文件 → 返回 false，等待 openlist 自己处理
    - 临时文件消失、目标文件大小达标 → 返回 true
  - 添加详细注释说明为什么不能主动 rename

**对比**：SFTP 和 FTP 的 `finalizeUpload` 现在策略一致——都不主动 rename，等待 openlist 自己完成最终化。

**协作边界**：仅修改 `sftp_client.dart`，未触碰 WorkBuddy 改动的文件。

---

### [2026-08-02] TRAE - 修复 openlist 挂载本机储存时 SFTP/FTP 上传后远程目录残留临时文件【已解决】（已由 WorkBuddy「openlist 本机储存 SFTP/FTP 上传后残留临时文件 + FTP 手动刷新闪退」记录接手解决，同源问题）

**问题**：openlist 挂载本机储存时，SFTP/FTP 上传完成后远程目录同时显示临时文件和原文件，原文件大小一开始很小，慢慢变大直到最后变成完整的文件。挂载的网盘目录下没有出现此问题。

**根因**：
1. `scheduleRemoteRefreshAfterUpload` 的临时文件检测正则 `^file-\d+(\.|$)` 只匹配飞牛 NAS 风格（`file-数字`），**不匹配 openlist 的临时文件命名**（`.文件名.tmp` / `文件名.tmp` / `.文件名` 等）。导致 `hasTemp` 永远为 false，无法检测到 openlist 服务端创建的临时文件。
2. 对非 FTP 客户端（SFTP），`targetReady` 检查只在 `!isFtpCache` 条件下执行。虽然之前已改为检查目标文件大小，但 openlist 的原文件大小逐步增长（流式写入），当大小达到 95% 时轮询就停止了，此时临时文件尚未被 openlist 清理。
3. 轮询次数 80 次 × 300ms = 24 秒，可能不足以覆盖 openlist 本机储存的刷盘延迟。

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - 新增 `_isLikelyTempFile(fileName, targetName)` 静态方法：基于目标文件名动态检测临时文件，覆盖三种模式：
    1. 飞牛 NAS 风格：`file-<数字>`（兼容旧逻辑）
    2. 目标文件名 + 临时后缀：`movie.mp4.tmp`、`movie.mp4.part`、`movie.mp4.partial` 等
    3. 隐藏文件 + 目标文件名：`.movie.mp4`、`.movie.mp4.tmp`、`.movie.mp4.part` 等（openlist/alist 本机储存驱动常用）
  - `scheduleRemoteRefreshAfterUpload()`：
    - `hasTemp` 改用 `_isLikelyTempFile(e.name, targetName)` 替代固定正则
    - `targetReady` 检查去掉 `!isFtpCache` 条件，**所有客户端**都检查目标文件存在且大小达标（达期望大小 95%）才停止轮询
    - `maxAttempts` 从 80 增加到 200（200 × 300ms = 60 秒），覆盖 openlist 本机储存更长的刷盘延迟
    - 删除不再使用的 `isFtpCache` 变量

**协作边界**：本次仅修改 `file_manager_provider.dart` 的刷新轮询逻辑，未触碰 WorkBuddy 近期改动的 `file_operation_progress_dialog.dart`、`pane_browser.dart`、`utils.dart` 等文件。

---

### [2026-08-02] WorkBuddy - 进度条显示层实时速率（仅显示，速率精度归 TRAE）【已解决】

**问题**：进度条副标题「传输文件」改为实时速率显示，统一覆盖本地↔远程↔本地所有传输路径。

**改动文件**：
- `lib/ui/widgets/file_operation_progress_dialog.dart`
  - 副标题由「传输文件」改为实时速率：`progress.speedMBs > 0` 时显示 `X.X MB/s`（`FileUtils.formatBytes`），否则显示 `—`。
  - 数据源为 `provider.progressNotifier` 的 `FileOperationProgress.speedMBs`，覆盖所有 `_paste` 路径（本地到远程 / 远程到本地 / 本地到本地）。

**协作边界（重要）**：
- 本次**仅改显示层**。速率的**计算与精度**由 TRAE 在 `lib/providers/file_manager_provider.dart` 负责（见 TRAE 2026-08-01 多条记录：进度速率不准、`_TransferSpeedTracker`、WebDAV/FTP 精度等）。
- 用户反馈：**部分客户端实时速率不准的问题已交由 TRAE 解决**。`WorkBuddy 不再重复提交 / 修改速率计算逻辑`，避免覆盖 TRAE 改动。
- 状态：显示层【已解决】（用户确认进度条可显示实时速率）；速率精度问题属于 TRAE 范围。

---

### [2026-08-02] WorkBuddy - 双窗口分屏布局进一步压缩（第二轮，更紧凑）【已解决】

**问题**：上一轮紧凑化（内边距6/图标28/字号10 + 去年份日期 + 去空格大小）用户真机验证仍截断。需进一步压缩横向占用，确保窄分屏 pane 下日期+时间+大小完整显示。

**改动文件**：
- `lib/ui/widgets/pane_browser.dart`
  - `_buildCompactFileItem` / `_buildCompactFolderItem` 同步进一步压缩：
    - 水平内边距 6→4、垂直 6→5
    - 图标 28→24
    - 图标-文字间距 6→4
    - 右侧三点按钮预留 24→20，且按钮本身 `minWidth/minHeight` 24→18、`Broken.more` 图标 16→13（tap 区更小，文字区更宽）
    - 文件名 `bodyMedium` 字号 13→12
    - 日期/大小行 `bodySmall` 字号 10→9，并加 `letterSpacing: -0.2` 进一步收窄
    - 日期-大小间距 4→3
  - 文件夹日期行（含 items 计数）字号 10.5→10，配合更窄右留白仍完整显示
- 工具函数（上一轮已新增，本轮沿用）：`formatDateCompact`（今年 MM-dd HH:mm）、`formatBytesCompact`（117.6K）
- 校验：`flutter analyze lib` = 0 error

**空间估算**：单 pane 164 dp 时文本区 ≈ 164 - 8(pad) - 24(icon) - 4(spacing) - 20(button) = 108 dp；"07-27 17:58"(11字×~4.5dp@9sp) + 3 + "117.6K"(6字×~4.5dp) ≈ 78 dp，余量约 30 dp，可完整显示。对比上一轮（余量仅 ~7dp）更稳健。

**依赖/影响**：仅改分屏紧凑列表项视觉密度，未触碰 TRAE 近期改动的传输/SMB/地址栏等文件。

---

### [2026-08-01] TRAE - 修复 SFTP 刷新检查文件大小 + FTP 进度卡100%改异步【已解决】

**问题**：
1. SFTP 上传完成后远程目录显示文件大小在变化（服务端刷盘延迟），需等待一段时间才稳定
2. FTP 上传完成后进度条卡在 100% 不消失，远程目录也没刷新，需等待一段时间

**根因（共通问题）**：两者本质都是"上传完成后的最终化等待"逻辑有问题：
1. **SFTP**：`scheduleRemoteRefreshAfterUpload` 对非 FTP 客户端只检查 `targetName` 是否出现，**不检查大小是否达标**。飞牛 NAS 的 SFTP 上传后目标文件大小从 0 逐步增长，第一次刷新发现文件名存在就停止轮询，但大小还在变化。
2. **FTP**：`_awaitUploadFinalized` **同步阻塞最多 45s**（90×500ms）等 FTP 服务端把 `file-<随机>` 临时文件 rename 为目标文件。`_uploadFromLocalClipboard` 中也有同步阻塞最多 15s（30×500ms）。在此期间进度条已显示 100% 但 `_isPasting` 仍为 true，导致进度条不消失。

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - `scheduleRemoteRefreshAfterUpload()`：非 FTP 客户端检查 `targetName` 存在**且大小达标**（达期望大小 95%）才停止轮询，否则继续轮询直至文件大小稳定
  - `_awaitUploadFinalized()`：从 `Future<void>` 同步阻塞改为 `void` 后台 fire-and-forget（`unawaited(Future(...))`），不再阻塞进度条消失
  - `_pasteLocalToRemote()` / `_pasteRemoteToRemote()`：调用 `_awaitUploadFinalized` 不再 `await`
- `lib/ui/screens/remote_explorer_screen.dart`
  - `_uploadFromLocalClipboard()`：移除 FTP 同步阻塞等待循环（30×500ms），交给 provider 后台轮询

---

### [2026-08-02] WorkBuddy - 双窗口分屏文件项日期/大小完整显示（紧凑化优化）【已解决】

**问题**：双窗口模式下文件项时间仍被截断（如 "26-07-..."），同样设备/目录/文件 MT 可完整显示日期+时间+大小。根因：分屏单 pane 宽仅约 170–200 dp，原布局固定占用（内边距8×2 + 图标32 + 间距8 + 按钮预留24 = 80 dp）后剩余空间不足；`formatDateShort` 今年带两位年份（13 字符）、`formatBytes` 带空格（8 字符），叠加后日期被 ellipsis 截断。

**改动文件**：
- `lib/core/utils.dart`
  - 新增 `formatDateCompact()`：今年显示 `MM-dd HH:mm`（去年份），跨年显示 `yy-MM-dd`
  - 新增 `formatBytesCompact()`：去空格与 B 后缀，如 `117.6 KB` → `117.6K`、`68.1 MB` → `68.1M`
- `lib/ui/widgets/pane_browser.dart`
  - `_buildCompactFileItem`：水平内边距 8→6、图标 32→28、图标-文字间距 8→6、日期-大小间距 6→4、字号 10.5→10；日期改用 `formatDateCompact`、大小改用 `formatBytesCompact`
  - `_buildCompactFolderItem`：同步收紧水平内边距/图标尺寸保持一致（文件夹仍用完整 `formatDate`）
- 校验：`flutter analyze lib` = 0 error

**影响说明**：本次改动仅涉及分屏紧凑列表项的日期/大小显示格式与内边距，未触碰 TRAE 近期改动的 `file_manager_provider.dart`、`remote_explorer_screen.dart`、`zenfile_address_bar.dart`、`SmbService.kt` 等文件，无冲突。

**验证结果**：第一轮压缩幅度不足仍截断，由第二轮「双窗口分屏布局进一步压缩」最终解决。

---

### [2026-08-01] TRAE - SMB 下载提速：移除双缓冲预取，改为单线程顺序读写【已解决】

**问题**：SMB 下载速率只跑到带宽的 2/3，上传反而跑满带宽。

**根因**：`downloadFile` 使用「预取线程 + LinkedBlockingQueue(容量4) + 主线程消费」双缓冲模型，但 smbj 的 `SMB2FileInputStream` 内部已批量预取，外层双缓冲反而引入 `buf.copyOf(n)` 内存拷贝、队列锁竞争、`Thread.sleep(5)` 让步等开销。

**改动文件**：
- `android/app/src/main/kotlin/com/sequl/zenfile/SmbService.kt`
  - `downloadFile()`：移除预取线程和队列，改为与 `uploadFile()` 对称的单线程 `input.read(buffer)` → `output.write(buffer)` 循环
  - 删除 `SMB_EOF` 哨兵常量
  - 保留取消检查（每 1MB 检查一次 `isCancelled`）和取消时删除临时文件

---

### [2026-08-01] TRAE - 优化远程传输的进度条和实时速率计算【已解决】

**问题**：所有远程客户端从本地传输到远程时，进度条和速率不准确。

**验证结果**：SMB、SFTP 进度条和速率正常；WebDAV、FTP 进度条和速率仍不准确。需排查这两个协议的 `uploadFile` 进度回调实现。

**根因**：
1. 目录传输时字节级进度被丢弃（`onFileProgress` 传 `(_) {}` 空回调）
2. 总字节数用估算值（目录内文件用 `averageFileSize` 估算）
3. 速率是累计平均（`bytesDone / elapsedSeconds`），文件间停顿时持续衰减
4. 远程→远程 `percentage` 与 `bytesProcessed` 不一致（`totalBytesAll` 乘2但 `bytesDone` 只算单倍）

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - 新增 `_countLocalFilesAndBytes()` / `_countRemoteFilesAndBytes()`：递归遍历目录获取真实文件数和总字节数
  - 删除旧的 `_countLocalFiles()` 方法（已被替代）
  - 修改 `_uploadLocalDirectory()` / `_downloadRemoteDirectory()`：新增 `onFileProgress(fileName, fileSize, progress)` 回调，传递字节级进度
  - 新增 `_TransferSpeedTracker` 类（文件末尾）：基于 2 秒滑动窗口统计实时速率
  - 重写 `_pasteLocalToRemote()` 进度计算：用 `emitProgress()` 统一构造进度，`percentage = bytesDone / totalBytesAll`
  - 重写 `_pasteRemoteToRemote()` 进度计算：修复 `percentage` 一致性，`previousFilesBytes` 在下载和上传完成时分别累加 `fileSize`

---

### [2026-08-01] TRAE - 修复远程客户端取消上传和页面刷新问题【已解决】

**问题**：传输中点击取消无法及时中断并清理临时文件；上传完成后远程页面不刷新，仍显示临时文件，需重启应用。

**验证结果**：SFTP 上传完成后远程目录仍不刷新，仍显示临时文件。需排查 SFTP 上传后的刷新逻辑。

**改动文件**：
- `lib/providers/file_manager_provider.dart`
  - `cancelOperation()`：设置 `_isOperationCancelled` 并调用 `_activeTransferClient?.cancel()`
  - 新增 `setActiveTransferClient()` 方法管理活跃传输客户端
  - `_pasteLocalToRemote()` / `_pasteRemoteToRemote()` 的 `finally` 块重置 `_isOperationCancelled = false`，确保取消后仍能触发刷新
  - `scheduleRemoteRefreshAfterUpload()` 修复取消后提前退出的问题
- `lib/ui/screens/remote_explorer_screen.dart`
  - `_uploadFromLocalClipboard()`：添加 `_transferCancelled` 标志，设置活跃传输客户端，上传后调用 `scheduleRemoteRefreshAfterUpload`
  - 修复 `lastUploadedSize` 在文件删除后获取不到的问题（调整为删除前获取）
  - 确认 `_buildTransferOverlay` 无取消按钮（进度条弹窗 `FileOperationProgressDialog` 已有取消按钮）
- `lib/services/remote/lan_client.dart`
  - 修复重复的 `@override` 注解
