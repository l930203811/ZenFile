# ZenFile 版本更新日志

## v1.1.35 — 多标签页增强 · SFTP 密钥认证 · SAF 访问 · SMB 局域网设备扫描 · 快传与图片查看器修复

> 本版本整合了图片查看器/编辑器、快传传输稳定性、多标签页适用范围、远程连接（SFTP/SMB/SAF）等一系列增强与修复。

---

### ✨ 新增功能 (New Features)

#### 1. 多标签页适用范围选择器
- 开启「启用多标签页」后弹出三选项：**仅在单窗口** / **仅在双窗口** / **全部**（默认）
- 双窗口（分屏）模式现已支持独立的多标签页（此前仅单窗口生效）
- 切换范围时自动收敛多余标签页；选择持久化，重启后保留

#### 2. SFTP SSH 密钥认证
- 连接类型支持切换 **密码认证 / SSH 密钥认证**
- 支持选择本地私钥（`.pem` / `.key` / `.pub`），可选密码短语；兼容 OpenSSH / RSA / ED25519 / ECDSA
- 适用于禁用密码登录、仅允许密钥的 SFTP/SSH 服务器

#### 3. SAF 系统授权访问 Android/data（vivo 等 ROM 专项）
- 四级兜底策略：标准 API → Java File API → Shizuku/Root → **SAF 系统授权**
- 进入 Android/data 失败时显示「系统授权访问」按钮，用户授权后树形 URI 持久保存，下次免重复授权
- 无需 Shizuku/Root，符合 Android 11+ 官方推荐，适用于各厂商 ROM 的访问限制

#### 4. SMB 向导「扫描局域网共享设备」（无需输入 IP）
- SMB 添加页顶部新增带文字标题的「扫描局域网共享设备」按钮，点击即自动探测局域网内开放 445 端口的 SMB 设备，**无需预先填写 IP 地址**
- 底层复用 `LanClient.scanSubnet` 子网探测 + 逐台列出根共享名（复用 `detectSmbShare` / `listSmbShares` 的过滤逻辑，自动过滤 `IPC$` / `ADMIN$` 等系统隐藏共享）
- 扫描结果以设备卡片展示：点击设备 IP 自动填入「主机地址 + 端口(445)」；设备下共享名以可点击标签展示，点击即自动填入「主机 + 端口 + 共享名」，无需手动输入

#### 5. 图片查看器拍摄地点显示
- 顶部元信息条显示拍摄 **GPS 坐标**（经纬度），无位置信息的照片自动隐藏该行
- 点击坐标以 `geo:` URI 唤起系统地图（离线可用，无需密钥/网络反编码）

#### 6. 图片编辑器「清除元数据」
- 编辑器 tab 栏「裁剪」右侧新增「清除元数据」入口
- 采用**字节级无损剥离**（删除 EXIF / GPS / ICC 等嵌入数据），不重新编码、不损失画质

---

### 🐛 问题修复 (Bug Fixes)

#### 1. 快传大文件接收卡死 / 闪退（严重）
- **根因**：接收端 `SocketReader` 缺少背压（socket 数据无阻塞塞入内存）+ `List<int>` 每字节占 4~8 字节导致内存膨胀 4~8 倍 + `removeRange(0,n)` 头删 O(n) → 大文件时 Dart 堆溢出（OOM）
- **修复**：缓冲改为 `Uint8List` 分块队列 + 8MB/1MB 背压水位（缓冲超 8MB 暂停底层读取，低于 1MB 恢复），背压经 TCP 窗口传导回发送端；接收端内存稳定在数 MB，≥1GB 文件可稳定接收

#### 2. 图片查看器「无 EXIF 却误显示拍摄参数标题」
- **根因**：`readExifOnly` 只要 EXIF 块非空即判 `hasExif`，导致「有 EXIF 块但无拍摄参数字段」的图片也显示标题，与无 EXIF 块的图表现不一致
- **修复**：标题仅在含实际拍摄参数字段（光圈 / 快门 / ISO / 设备）时显示，10 张图表现统一

#### 3. 多标签页设置缺陷修复（3 处）
- 「文件浏览器选项」页开关此前未接范围选择弹窗（直接开关），已接入范围选择器
- 弹窗触发逻辑改为**仅开启时弹出**（关闭时不打扰），并移除未使用的状态变量
- 弹窗内 3 处硬编码中文（两个选项描述 + 副标题）改为多语言

#### 4. 构建失败：Java 堆内存不足
- split-per-abi 打包阶段 `:app:packageRelease` 报 `Java heap space`；已将 `android/gradle.properties` 的 `-Xmx` 从 `1536M` 提升至 `6144M`（同时放宽 `MaxMetaspaceSize` / `ReservedCodeCacheSize`）
- AGP 8.11.1 / Kotlin 2.2.20 的 "will soon be dropped" 仅为弃用警告，非阻塞

---

### 🔧 技术优化 (Technical)

- 快传接收端改为分块缓冲 + TCP 背压，发送端 `flush()` 限流自动传导，内存占用稳定
- 清除元数据改用字节级剥离（对比重新编码方案），无损且结果确定
- SMB 共享名探测与向导扫描复用同一过滤逻辑（`_ignoredSmbShareNames` + `$` 结尾过滤），行为一致

---

### 🌍 多语言 (Localization)

本次新增/补全以下键（覆盖简/繁中文、English、日本語、한국어、Deutsch、Français、Español、Русский、العربية）：

- 多标签页范围：`ui_multi_tab_scope_title` / `single_only` / `split_only` / `all` / `split_only_desc` / `all_desc` / `subtitle`
- SMB 局域网扫描：`ui_scan_lan_devices` / `ui_scanning_lan` / `ui_lan_no_devices` / `ui_lan_scan_hint`（复用 `ui_share_scan_failed` / `ui_no_shares_found`）
- SSH 认证相关键（连接类型、私钥选择、密码短语等）

> ⚠️ 已知项：`lib/l10n/generated/` 下**没有 `app_localizations_zh_TW.dart`**（zh_TW.arb 源存在但未生成）。新增键已写入 9 个语言实现 + 基类，繁体中文需本机跑一次 `flutter gen-l10n` 才补全并生成该缺失文件。

---

### 📝 改动文件 (Changed Files)

| 文件 | 说明 |
|------|------|
| `lib/providers/file_manager_provider.dart` | 多标签页范围枚举/持久化 + SAF 四级兜底 + `listSmbShares` / `discoverSmbDevices` 公开方法 |
| `lib/services/root_shizuku_service.dart` | 新增 `SafAndroidDataService` + `listRawPath` Kotlin 桥接 |
| `android/app/src/main/kotlin/.../MainActivity.kt` | 新增 `requestSafWithInitialUri`（定位 Android/data）|
| `lib/ui/widgets/restricted_folder_banner.dart` | 「系统授权访问」按钮 |
| `lib/ui/screens/directory_screen.dart` | 传入 `onEnableSaf` 回调 + `showTabBar` 控制标签栏 |
| `lib/ui/widgets/pane_browser.dart` | 传入 `onEnableSaf` 回调 |
| `lib/ui/widgets/directory_tab_bar.dart` | 双窗口多标签渲染（焦点/次级高亮）|
| `lib/ui/screens/more_settings_screen.dart` | 多标签页范围弹窗与 3 处缺陷修复 + 多语言 |
| `lib/models/network_connection_model.dart` | SSH 密钥认证字段 |
| `lib/services/remote/sftp_client.dart` | 支持 SSH 密钥认证（`identities` / `SSHKeyPair.fromPem`）|
| `lib/ui/screens/network_connection_wizard_screen.dart` | SMB「扫描局域网共享设备」顶部文字按钮 + 设备卡片(自动填 IP 与共享名) + SSH 密钥选择 UI |
| `lib/services/quick_transfer_service.dart` | 快传接收端背压修复（分块队列 + 水位）|
| `lib/ui/screens/image_viewer_screen.dart` | 拍摄地点显示 + EXIF 标题判定修复 + 去除位置图标 |
| `lib/services/image_metadata_service.dart` | GPS 解析（readExifOnly）+ `stripMetadataBytes` 字节级剥离 |
| `lib/ui/screens/image_editor_screen.dart` | 「清除元数据」tab 入口 |
| `android/gradle.properties` | `-Xmx6144M` 构建堆内存调优 |
| `lib/l10n/app_*.arb` + `generated/*` | 多语言键（多标签页 / SMB 扫描 / SSH 认证）|
| `pubspec.yaml` | 新增 `file_picker ^11.0.3` |

---

### 🧪 测试建议 (Test Suggestions)

**多标签页双窗口**
1. 设置 → 文件浏览器选项 → 启用多标签页
2. 点击开关，弹出三选项，默认勾选「全部」
3. 选「仅在双窗口」→ 单窗口无标签栏、双窗口有；选「全部」→ 两模式均有
4. 关闭开关时不弹窗直接生效

**SFTP SSH 密钥认证**
1. 添加 SFTP 连接，选择 SSH 密钥认证
2. 选择本地私钥（如 `id_ed25519`），有密码短语则填写
3. 测试连接，确认认证成功

**SAF Android/data（vivo 等）**
1. 进入 `/Android/data`，查看是否出现「系统授权访问」按钮
2. 点击调起系统选择器 → 选「使用此文件夹」完成授权 → 目录内容正常显示

**SMB 扫描局域网共享设备**
1. SMB 向导（无需填主机）→ 点顶部「扫描局域网共享设备」
2. 自动列出局域网内 SMB 设备与共享名 → 点击设备或共享名自动填入地址与共享名 → 保存连接成功

**图片查看器 / 编辑器**
1. 打开带 GPS 照片：顶部显示坐标、点击唤起地图
2. 无拍摄参数的图：不显示「拍摄参数」标题
3. 编辑器「清除元数据」：另存副本后 EXIF/GPS 已被剥离

**快传大文件**
1. 两机互传 ≥1GB 文件：不再卡死/闪退，接收完整可打开

---

### 📦 构建产物 (Build Artifacts)

`flutter build apk --release --split-per-abi` 产出：

```
build/app/outputs/flutter-apk/
  app-arm64-v8a-release.apk
  app-armeabi-v7a-release.apk
  app-x86_64-release.apk
```

> 发布前铁律：Glob 确认 3 个 APK 时间戳为本次 + `aapt dump badging` 核验 `versionName=1.1.35`，再传 GitHub Release。

---

*本版本重点提升传输稳定性（快传大文件不再闪退）与远程/本地浏览体验（多标签页双窗口、SFTP 密钥、SAF 访问、SMB 共享名扫描、图片拍摄地点与元数据清理）。建议所有用户升级。*
