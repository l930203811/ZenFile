[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。感谢原作者的开源贡献！

---

## 🚀 v1.0.43 更新内容

**原生 SMB 重写 & 桌面歌词悬浮窗 & 流式播放修复** — SMB 客户端通过 Android 原生 smbj 库完全重写，实现真实 SMB 协议。新增桌面歌词悬浮窗，支持逐字卡拉OK 高亮与拖拽缩放。修复 FTP/SFTP 流式播放、通知栏控制面板、后台播放连续性。优化面包屑边框、三点按钮位置与分类选择返回行为。

🙏 **感谢反馈** — 感谢以下用户反馈与建议：越界、猕猴桃、Sir Jagadeesh Chandra Bose、Silence

| | |
|---|---|
| 🌐 **原生 SMB 客户端** | SMB 客户端完全重写，通过 Android 原生 smbj 库实现真实 SMB 协议，支持自动探测共享名 |
| 📡 **FTP/SFTP 流式播放修复** | 修复 FTP/SFTP 流式播放，使用原生 Socket 独立数据连接，支持边缓存边播放 |
| 🌐 **远程页国际化修复** | 修复远程连接页硬编码字符串，新增 SMB 协议描述与连接名称后缀的 l10n 翻译 |
| 🖼️ **图片浏览器菜单** | 图片浏览器右上角菜单改为底部弹窗，9 个操作项，黑色半透明背景提升可见性 |
| 🔲 **面包屑边框** | 面包屑按钮新增 V 形完整边框，使用 CustomPaint 绘制，相邻按钮无缝衔接且有清晰边界 |
| ⋮ **三点按钮位置** | 文件/文件夹三点操作按钮调整到卡片右上角，避免拖动时误触 |
| ⚙️ **三点按钮设置** | 三点操作按钮设置项改为「显示三点操作按钮」，支持全部显示/仅单窗口/仅双窗口三种模式 |
| ↩️ **分类返回行为** | 分类页多选模式下按返回键取消选择，而不是退出类别 |
| 🎤 **桌面歌词悬浮窗** | 新增桌面歌词悬浮窗，支持权限检查、拖动位置、单击切换播放/暂停 |
| 🔔 **通知栏面板修复** | 修复下拉通知栏不显示播放控制面板，暂停时保留通知，权限拒绝时提示用户 |
| 🎶 **歌词逐字高亮** | 悬浮歌词支持逐字高亮，使用 SpannableStringBuilder 实现卡拉OK效果 |
| ↔️ **悬浮窗缩放** | 悬浮歌词窗口支持长按显示缩放手柄，拖拽调整窗口大小与文字大小 |
| ▶️ **后台播放修复** | 修复开启后台播放时暂停音乐的问题，attach 复用 player 实例不中断播放 |
| 🔄 **分类按钮同步** | 修复未开启后台播放时音频类别页播放按钮显示旧音频信息，返回时刷新按钮状态 |
| 🛠️ **构建稳定性** | 修复 R8 编译 OOM、x86_64/armv7 启动白屏，调整 Gradle JVM 内存与 ABI 下载 |
| ✨ **歌词缩放动画** | 逐字歌词过渡动画新增放大效果，修复同步问题，固定 300ms 过渡时长 |

---

## 🚀 v1.0.42 更新亮点

**音乐播放器增强 & 文件图标重设计 & 导航栏自定义** — 音乐播放器现支持 LRC 歌词加载、播放进度记忆，音乐分类页新增快捷播放按钮。图片、文档和压缩包文件图标已重新设计，显示格式标签。新增导航栏位置设置，支持顶部或底部显示，浏览页布局同步优化。

| | |
|---|---|
| 🎵 **移除歌词全屏面板** | 移除歌词全屏面板，提供更简洁的播放体验 |
| 🎵 **当前歌词居中显示** | 当前播放歌词行改为居中对齐，提升可读性 |
| 🎵 **音乐分类页快捷播放** | 音乐分类页顶部新增播放器快捷按钮，方便继续收听 |
| 🎵 **播放进度记忆** | 音乐播放器记住播放进度，下次自动续播 |
| 🖼️ **图片图标重设计** | 重新设计图片文件图标，显示格式标签（jpg、png 等） |
| 📄 **文档图标重设计** | 重新设计文档文件图标，显示格式标签 |
| 🗜️ **压缩包图标重设计** | 重新设计压缩包图标，显示格式标签（zip、7z、rar 等） |
| 🎶 **LRC 歌词支持** | 音乐播放器支持自动加载 LRC 歌词及手动选择歌词文件 |
| 🐛 **远程粘贴修复** | 修复远程服务器复制文件到本地粘贴时进度条无响应且文件未出现的问题 |
| 📍 **导航栏位置设置** | 新增导航栏位置设置，支持顶部或底部显示导航栏 |
| 📐 **浏览页布局优化** | 启用底部导航栏时，优化浏览页顶部区域布局，增加文件列表显示空间 |

---

## ✨ 功能特性

- **精美 UI/UX** — 纹理与透明度融合的现代玻璃拟态设计
- **原生媒体索引** — 利用设备原生索引，闪电般浏览图片、视频和音频
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
- `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO`、`READ_MEDIA_AUDIO` — 高速原生媒体索引

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
- **索引** — `photo_manager` & `on_audio_query`
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
