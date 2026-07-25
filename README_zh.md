[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.23更新内容

### ✨ 新增功能

- 应用管理：点击应用弹窗新增「复制包名」选项，可一键复制应用包名。
- 路径栏：长按路径栏进入编辑模式，支持输入并跳转到指定路径。

### 🔧 优化

- 分类媒体浏览（图片、视频、音频、截图）改为递归文件系统扫描，不再依赖系统级媒体库索引（MediaStore）。类别识别更精准、稳定——文件移动或重命名后不再从分类中消失。扫描逻辑现已与 Web 共享页统一。
- 视频与音频缩略图改为原生生成（通过 MediaMetadataRetriever），不再依赖系统媒体缩略图。
- 回收站管理现已统一：启用开关与自动删除时长设置从「设置」迁移至「回收站」页面（抽屉 → 本地 → 回收站进入），开关与回收内容在同一处管理，更方便。

### 🐛 问题修复

- 修复全局搜索无法检索 data 目录下文件的问题。
- 修复应用管理弹窗中「卸载应用」按钮在部分机型上溢出屏幕底部、难以点击的问题。
- 修复浏览远程目录时返回本地空目录的问题。
- 修复列表视图下视频缩略图不显示的问题（网格视图原本已正常显示）。
- 修复分类页长按进入多选模式后，顶部「全选」按钮无法全选的问题。
- 优化分类页选中高亮效果：选中项现在显示清晰的主色边框与浅色底色，不再只是角落的小勾。
- 修复清除应用数据/缓存后启动闪退的问题（卡在语言选择页）。此场景下系统可能误报「所有文件管理」已授权、但实际访问被拒（权限状态不一致）；现已在授予访问前用真实目录枚举探测确认权限。
- 修复备份较大 APK 时后台已成功但无完成弹窗的问题。进度框现使用根导航的 Overlay context 且不可关闭，备份完成时必能弹出成功对话框。
- 修复视频播放器外挂字幕大小和位置调整不生效的问题。外挂字幕现改用基于解析后 SRT/ASS 时间轴的 Flutter 浮层渲染，字号与位置滑块对所有字幕格式都能稳定生效。
- 优化在线歌词搜索：现在会列出候选歌曲供手动选择，避免在歌名相同、歌手不同的情况下误匹配（此前会自动匹配首个结果）。
- 修复 FTP 共享后其他客户端连接成功却显示空目录的问题。被动模式（PASV）响应此前返回的是服务端 anyIPv4 地址（0.0.0.0），远程客户端无法回连该地址；现改为返回具体可达的局域网地址（同设备客户端返回 127.0.0.1），目录列表得以正确送达。

### ⚠️ 已知问题（预计下个版本修复）

- 目前仅 WebDAV 客户端支持媒体文件流式播放，其他客户端暂不支持。

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
