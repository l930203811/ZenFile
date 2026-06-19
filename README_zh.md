[English](README.md) | 中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。感谢原作者的开源贡献！

---

## 🚀 v1.0.4 更新亮点

**文本编辑器 & 多语言大扩展** — ZenFile 新增全功能文本编辑器，支持新建文件、另存为、撤销/重做，编辑器设置自动持久化。多语言支持扩展至 10 种语言。

| | |
|---|---|
| 📝 **文本编辑器** | 新建文件、另存为、撤销/重做等完整编辑功能 |
| 💾 **编辑器设置持久化** | 自动换行、行号、阅读模式等偏好设置自动保存 |
| 🌍 **10 种语言支持** | 简体中文、英语、繁体中文、日语、韩语、德语、法语、西班牙语、俄语、阿拉伯语 |
| 🐛 **l10n 硬编码修复** | 修复多处未正确国际化的硬编码字符串 |
| 📜 **语言选择滚动优化** | 语言选择界面支持滚动，提升使用体验 |

---

## 🚀 v1.0.3 更新亮点

**SVG 支持 & 多语言国际化** — ZenFile 现已全面支持 `.svg` 矢量图形缩略图预览和全屏查看，并新增 **中文 / 英文** 双语界面支持。

| | |
|---|---|
| 🖼️ **SVG 缩略图** | 浏览页网格/列表视图均支持 SVG 文件缩略图展示 |
| 🔍 **SVG 查看器** | 全屏查看器完美渲染矢量图形，支持缩放 |
| 🌐 **双语界面** | 700+ 界面字符串全面覆盖中英文 |
| 🔄 **即时语言切换** | 设置 → 语言 一键切换，无需重启 |
| 💾 **记忆偏好** | 语言设置自动保存，下次启动自动恢复 |
| 🎨 **压缩包颜色** | 不同压缩格式显示专属颜色（zip 橙色 / rar 红色 / 7z 紫色 / tar 棕色 / gz 绿色） |
| 🌐 **远程文件播放** | 远程服务器文件先下载到本地再播放，支持远程缩略图预览 |
| 🐛 **多项修复** | 修复解压后页面卡死、远程文件无法打开等 BUG |

**v1.0.3 其他优化：**
- **日期格式优化** — 文件日期统一显示为 `yyyy-MM-dd`
- **时间制式** — 默认启用 24 小时制
- **缓存统一管理** — 远程文件缓存目录归一化为 `Download/ZenFile_Remote`

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
