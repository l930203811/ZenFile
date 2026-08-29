# ZenFile 版本更新日志

## v1.x — 多标签页优化 + SFTP SSH 密钥认证 + SAF Android/data 访问

---

## ✨ 新增功能

### 1. 多标签页适用范围选择器

**问题**：此前「启用多标签页」开关只有开/关两种状态，无法控制双窗口（分屏）模式下的行为。

**修复**：点击多标签页开关时弹出范围选择器，提供三种模式：

| 选项 | 说明 |
|------|------|
| **仅在单窗口** | 多标签页仅在单窗口模式下生效（默认，历史行为） |
| **仅在双窗口** | 多标签页仅在分屏双窗口模式下生效 |
| **全部** | 单窗口与双窗口模式均启用多标签页 |

**体验优化**：
- 切换范围时自动收敛多余标签页（如切回「仅单窗口」时自动关闭超出 pane 数量的标签）
- 设置持久化，重启后保留上次选择

---

### 2. SFTP SSH 密钥认证

**背景**：许多现代 SFTP/SSH 服务器已禁用密码认证，仅允许 SSH 密钥登录。

**新增功能**：
- 连接类型选择 → 密码认证 / SSH 密钥认证 切换
- 支持文件选择器挑选本地私钥（`.pem` / `.key` / `.pub`）
- 可选密码短语输入（用于解密受保护的私钥）
- 支持所有标准格式：OpenSSH、RSA、ED25519、ECDSA

**使用场景**：
```
服务器配置：禁止密码登录，仅允许密钥认证
用户操作：选择私钥文件 → 输入密码短语（如有）→ 连接成功
```

---

### 3. SAF 系统授权访问 Android/data（vivo ROM 专项）

**问题**：部分厂商 ROM（如 vivo Android 11）的 FUSE 层完全拦截 Android/data 访问，Shizuku 和 shell 命令均返回空。

**解决方案**：通过 Android 官方 SAF（Storage Access Framework）绕过 FUSE 限制。

**工作流程**：
1. 进入 Android/data 时，自动尝试标准 API → 原始路径 → Shizuku shell
2. 全部失败后，显示「系统授权访问」按钮
3. 用户点击 → 系统文件选择器打开，直接定位到 Android/data
4. 授权后树形 URI 持久保存，下次打开无需重复授权

**优势**：
- 无需 Shizuku 或 Root 权限
- 符合 Android 11+ 官方推荐做法
- 适用于所有厂商 ROM 的 Android/data 访问限制

---

## 🔧 技术优化

### 四级兜底策略（Android/data 访问）

```
┌─────────────────────────────────────────────────────────────┐
│  优先级  │  方式                      │  适用场景              │
├─────────────────────────────────────────────────────────────┤
│   1     │  标准 API (/storage/...)   │  ROM 未加固 FUSE       │
│   2     │  Java File API (app 进程)  │  shell 被 SELinux 拦截  │
│   3     │  Shizuku / Root shell      │  常规 root/shizuku 设备 │
│   4     │  SAF 系统授权              │  vivo 等 FUSE 严格拦截  │
└─────────────────────────────────────────────────────────────┘
```

### SFTP 客户端重构

- 支持 `identities` 参数传入 SSH 私钥列表
- 私钥解析改用 `SSHKeyPair.fromPem()`，兼容更多格式
- 并行连接也支持密钥认证

---

## 📝 改动文件

| 文件 | 改动说明 |
|------|----------|
| `lib/providers/file_manager_provider.dart` | 四级 fallback 策略 + `_trySafAccess` 方法 |
| `lib/services/root_shizuku_service.dart` | 新增 `SafAndroidDataService` + `listRawPath` Kotlin 桥接 |
| `android/.../MainActivity.kt` | 新增 `requestSafWithInitialUri`（定位到 Android/data）|
| `lib/ui/widgets/restricted_folder_banner.dart` | 新增「系统授权访问」按钮 |
| `lib/ui/screens/directory_screen.dart` | 传入 `onEnableSaf` 回调 |
| `lib/ui/widgets/pane_browser.dart` | 传入 `onEnableSaf` 回调 |
| `lib/ui/screens/more_settings_screen.dart` | 新增 `_toggleMultiTabsWithScope` 函数 |
| `lib/models/network_connection_model.dart` | 新增 SSH 密钥认证字段 |
| `lib/services/remote/sftp_client.dart` | 支持密钥认证 |
| `lib/ui/screens/network_connection_wizard_screen.dart` | 新增 SSH 密钥选择 UI |
| `lib/l10n/*.arb` (10个) | 新增多语言键值 |
| `pubspec.yaml` | 新增 `file_picker ^11.0.3` |

---

## 🌍 多语言支持

本次更新为以下 10 种语言新增翻译：

| 语言 | 新增键值 |
|------|----------|
| 简体中文 | 仅在单窗口 / 仅在双窗口 / 全部 + SSH 认证相关 |
| 繁体中文 | 僅在單視窗 / 僅在雙視窗 / 全部 + SSH 認證相關 |
| 英语 | Single Window Only / Dual Window Only / All Windows |
| 俄语 | Только в одном окне / Только в разделённом окне / Во всех окнах |
| 韩语 | 단일 창에서만 / 분할 창에서만 / 모든 창 |
| 日语 | 単一ウィンドウのみ / 分割ウィンドウのみ / 全ウィンドウ |
| 法语 | Fenêtre unique uniquement / Écran partagé uniquement / Toutes les fenêtres |
| 西班牙语 | Solo ventana única / Solo pantalla dividida / Todas las ventanas |
| 德语 | Nur Einzelfenster / Nur Geteilter Bildschirm / Alle Fenster |
| 阿拉伯语 | نافذة واحدة فقط / شاشة مقسمة فقط / جميع النوافذ |

---

## 🧪 测试建议

### 多标签页双窗口模式
1. 设置 → 文件浏览器选项 → 启用多标签页
2. 点击开关，选择「仅在双窗口」
3. 启用分屏，确认左右 pane 可各自管理独立标签页
4. 切换到「全部」，确认单窗口也显示标签页栏

### SFTP SSH 密钥认证
1. 添加 SFTP 连接，选择 SSH 密钥认证
2. 选择一个本地私钥文件（如 `~/.ssh/id_ed25519`）
3. 如有密码短语则填写
4. 测试连接，确认认证成功

### SAF Android/data 访问（vivo 设备）
1. 进入 `/storage/emulated/0/Android/data`
2. 查看是否出现「系统授权访问」按钮
3. 点击后调起系统文件选择器
4. 选择「使用此文件夹」完成授权
5. 确认目录内容正常显示

---

## 📦 构建产物

```
build/app/outputs/flutter-apk/
  app-arm64-v8a-release.apk    (约 65 MB)
  app-armeabi-v7a-release.apk  (约 63 MB)
  app-x86_64-release.apk       (约 72 MB)
```

---

## 📌 Git 提交记录

| Commit | 说明 |
|--------|------|
| `98cb512` | feat: SFTP 添加 SSH 密钥认证支持 |
| `002a3c4` | fix: 补充多标签页适用范围的多语言 ARB 和生成文件 |
| `33488a0` | feat: 多标签页适用范围选择器 |
| `472cf61` | feat: SAF 系统授权访问 Android/data — vivo ROM 专用方案 |
| `f434a19` | fix: 改用 find 命令替代 shell glob，添加调试日志 |
| `77664f5` | feat: ES 方案绕过 FUSE 限制访问 Android/data |

---

*本版本重点解决 vivo 等设备 Android/data 访问问题，增强 SFTP 安全性（支持密钥认证），并完善多标签页双窗口体验。若您使用的是非 vivo 设备且此前正常使用，可选升级。*
