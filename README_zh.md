[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器与离线媒体中心，基于 Flutter 打造。它将惊艳的毛玻璃美学与系统级媒体索引（Android MediaStore）相结合，实现零扫描、瞬时加载的浏览体验，并集成了全能工具箱、高速 FTP / WebDAV / SMB / SFTP 远程访问，以及点对点快传。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.37 更新内容

### 🐛 问题修复

- **远程媒体播放卡顿 / 拖动跳回原点**：重构本地 HTTP 流式代理的 seek 缓存与分块填充，修复非零偏移区域读取 bug；拖动后首字节延迟由整段 24MB 降为首个分块，SFTP/SMB/FTP 拖动不再跳回原点。
- **SFTP 上传限速约 2MB/s**：升级 JSch 0.1.55 → 2.28.7 以支持 rsa-sha2/ED25519/OpenSSH-v1 密钥，避免静默回退到纯 Dart 的 dartssh2（限速根因）；setBulkRequests(128) 提升在途请求数。
- **SFTP 符号链接目录（如 /sdcard）识别**：列表时跟随符号链接真实目标类型，目录可正常进入。
- **编译错误（进度最小化状态机）**：字段初始化器引用实例方法导致编译失败，改为构造函数体内赋值并放宽 final。

### ✨ 新功能 / 功能优化

- **双窗口激活窗口顶部高亮**：激活窗口的整个顶部状态栏高亮（primary 背景 + 2.5px 高亮边），更易识别。
- **进度后台最小化为浮窗**：复制/剪切与分类页备份进度点「后台」后，在状态栏/工具栏显示可点击的圆形浮窗按钮（带旋转进度环），点击重开进度页；传输完成/取消后自动消失。
- **远程 Tab 云图标**：远程浏览页 Tab 左侧图标直接用云图标替换原文件夹图标，本地 Tab 仍为文件夹图标。
- **文件类型图标优化**：未获取媒体缩略图时，图片/视频/音频/安装包显示「类型图标 + 格式标签」（MP4/MKV/MP3/FLAC/APK 等）；安装包用安卓机器人图标（绿色），压缩包用捆绑包图标（Broken.box）并显示 ZIP/7Z/RAR 格式；分类页音乐页音乐图标下方也显示格式标签；浏览页与分类页图标显示一致。
- **远程缩略图缓存隐私保护**：远程媒体缩略图缓存迁入 .nomedia 目录并写入标记文件，避免被系统媒体库/其他文件管理器索引；默认远程缓存自动清理间隔改为 0（不自动清理）。

### 🎨 性能优化

- **远程媒体流式代理调优**：多段独立 seek 缓存（上限 4 段）避免来回拖动反复缓冲；mpv 缓冲参数放大（cache-secs 60 / demuxer-max-bytes 300M）减少周期卡顿；引导预取 16MB、按需抓取 24MB 提升起播与拖动跟手度。

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
