[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器与离线媒体中心，基于 Flutter 打造。它将惊艳的毛玻璃美学与系统级媒体索引（Android MediaStore）相结合，实现零扫描、瞬时加载的浏览体验，并集成了全能工具箱、高速 FTP / WebDAV / SMB / SFTP 远程访问，以及点对点快传。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.35 更新内容

### ✨ 新功能

- **多标签页适用范围选择器**：开启「启用多标签页」后弹出三选项（仅在单窗口 / 仅在双窗口 / 全部），双窗口模式现支持独立多标签页，选择持久化。
- **SFTP SSH 密钥认证**：支持密码与 SSH 密钥认证切换，可选本地私钥（.pem / .key / .pub）与密码短语，兼容 OpenSSH / RSA / ED25519 / ECDSA。
- **SAF 系统授权访问 Android/data**：四级兜底策略，进入失败时显示「系统授权访问」按钮，授权后树形 URI 持久保存。
- **SMB 向导「扫描局域网共享设备」**：顶部带文字标题的按钮，无需输入 IP 即自动探测局域网 SMB 设备并自动填入地址与共享名。
- **图片查看器拍摄地点显示**：顶部显示拍摄 GPS 坐标，无位置信息自动隐藏，点击唤起系统地图。
- **图片编辑器「清除元数据」**：字节级无损剥离 EXIF / GPS / ICC，不重编码、不损失画质。

### 🐛 问题修复

- **快传大文件接收卡死 / 闪退**：接收端改为 Uint8List 分块队列 + TCP 背压水位（8MB / 1MB），≥1GB 文件稳定接收。
- **图片查看器「无 EXIF 却误显示拍摄参数标题」**：标题仅在含实际拍摄参数字段时显示。
- **多标签页设置缺陷修复**：接入范围选择弹窗、仅在开启时弹出、3 处硬编码中文改多语言。
- **构建失败（Java 堆内存不足）**：将 gradle -Xmx 从 1536M 提升至 6144M。

### 🎨 优化

- **快传分块缓冲 + TCP 背压**：内存占用稳定，≥1GB 文件不再卡死。
- **清除元数据字节级剥离**：结果确定且不损失画质。
- **SMB 扫描与向导复用同一过滤逻辑**：行为一致。

---

## ✨ 功能特性

- **精美 UI/UX** — 纹理与透明度融合的现代玻璃拟态设计
- **全量媒体索引** — 基于系统级索引（Android MediaStore），精准稳定地浏览图片、视频和音频，移动或重命名后的文件依然可见，无需全盘扫描。
- **内置媒体播放器**
  - 基于 `media_kit` 的高性能视频播放器
  - 支持专辑封面和精确进度控制的优雅音频播放器
  - 双指缩放图片查看器，流畅手势操控
- **内置文本编辑器** — 在应用内查看和编辑 `.txt`、`.md`、`.json` 等代码文件
- **高级排序** — 按最新、最旧或日期筛选，快速找到所需内容
- **完整文件操作** — 轻松复制、剪切、粘贴、重命名、删除文件和文件夹
- **快捷分类** — 一键访问已索引的媒体库
- **存储概览** — 直观展示内部存储使用情况
- **流畅动画** — 全应用 iOS 风格弹性物理效果和过渡动画
- **远程服务器** — 支持 FTP、SFTP、WebDAV、SMB/局域网，统一浏览体验
- **双面板浏览** — 两个目录并排显示，拖放传输文件
- **多标签页** — 打开多个文件夹标签，快速切换不丢失位置
- **加密保险柜** — 内置加密保护敏感文件
- 🌍 **多国语言支持**：支持简体中文、英语、繁体中文、日语、韩语、德语、法语、西班牙语、俄语、阿拉伯语共10种语言。

---

## 📸 截图

**中文界面：**

| | | | |
|:---:|:---:|:---:|:---:|
|<img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_1.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_2.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_3.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_4.jpg" width="200"> |

**英文界面：**

| | | | |
|:---:|:---:|:---:|:---:|
|<img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_1.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_2.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_3.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_4.jpg" width="200"> |

---

## 🔧 权限说明

- `MANAGE_EXTERNAL_STORAGE` — 跨设备全局文件操作
- `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO`、`READ_MEDIA_AUDIO` — 标准媒体读取权限

---

## 🏗️ 构建与运行

1. 克隆仓库
2. 运行 `flutter pub get` 安装依赖
3. 在 Android 设备运行 `flutter run`（需要 API 21+）

---

## 🛠️ 技术栈

- **Flutter & Dart**
- **状态管理** — `provider`
- **媒体引擎** — `media_kit`
- **索引** — 媒体分类采用系统级 MediaStore 索引（瞬时、零 I/O）；`photo_manager` 与 `on_audio_query` 保留用于音频模型兼容
- **权限** — `permission_handler`
- **查看器** — `photo_view` & `open_filex`

---

## 📡 联系我们

- **Telegram 频道**: [https://t.me/+47n76Au6mhg0MDA1](https://t.me/+47n76Au6mhg0MDA1)
- **QQ 群**: 792408214
- **邮箱**: 1@sequel.dpdns.org
- **GitHub**: [https://github.com/l930203811/ZenFile](https://github.com/l930203811/ZenFile)

---

## 🙏 致谢

基于 [Senzme/NFile](https://github.com/Senzme/NFile) 二次开发，感谢原作者提供优秀的代码基础！

---

## 📄 许可证

GNU GPL v3
