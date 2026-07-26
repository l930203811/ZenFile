[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.24 更新内容

### ✨ 新增功能

- 分类页新增「按文件夹分组」显示模式，媒体文件可按所在文件夹归组浏览，方便按来源目录快速定位。
- 关于页新增多语言版权署名，保留 NFile 原署名并增加 ZenFile 修改署名。

### 🔧 优化

- 所有远程客户端（SMB / FTP / SFTP / WebDAV）均支持媒体文件流式播放，无需下载完整文件即可边下边播；流式播放使用独立连接，拖动进度条可即时跳转，且不再影响远程浏览会话。
- SMB 下载提升 SMB2 单请求读/写窗口至 8MB（SMB2 大 MTU 上限），显著减少 RTT 往返次数，在高速局域网下可跑满带宽。
- 构建产物改为按 ABI 分包（`--split-per-abi`），arm64 安装包体积显著减小。

### 🐛 问题修复

- 修复从远程剪切/移动到本地（或本地剪切/移动到远程）后，来源目录仍显示原文件、必须手动刷新才消失的问题。
- 修复音频播放器「后台播放」开关在菜单中点击后状态不即时刷新（需重开菜单才更新）的问题。
- 进一步适配安卓 13 及以上版本通知栏媒体控制按钮：本地 fork `audio_service` 并修正前台服务类型与 `MediaSession` 激活逻辑（部分国产 ROM 仍可能因系统限制无法显示媒体卡片，仍在持续调研）。
- 修复关闭「远程媒体缩略图」开关后，SMB / FTP / SFTP / WebDAV 浏览页仍显示远程缩略图的问题；同时所有远程缩略图加载路径均尊重该开关。
- 修复音频播放器在播放无歌词曲目时，界面显示硬编码中文占位提示的问题；该提示现已加入多语言翻译（中文/繁中/英/德/西/法/日/韩/阿/俄）。
- 修复 FTP 客户端传输文件时进度条瞬间满格、不准确的问题（修正 SIZE 响应解析）。
- 修复 SFTP 连接飞牛 NAS 时只显示部分共享目录的问题（根路径列表解析）。
- 修复 SFTP 远程视频播放约 1 秒后停止、进度条不走、拖动进度条后一直卡在「正在缓存中」的问题（恢复兼容的读取策略并正确传递文件大小）。

---

## ✨ 功能特性

- **精美 UI/UX** — 纹理与透明度融合的现代玻璃拟态设计
- **全量媒体索引** — 基于递归文件系统扫描（与 Web 共享统一），精准稳定地浏览图片、视频和音频，移动或重命名后的文件依然可见。
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
- **索引** — 媒体分类采用递归文件系统扫描；`photo_manager` 与 `on_audio_query` 保留用于音频模型兼容
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
