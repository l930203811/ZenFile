[English](README.md) | 中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。感谢原作者的开源贡献！

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

## 🚀 v1.0.2 更新亮点

**远程浏览页重构** — 迄今为止最大的架构变更。远程服务器浏览页全面采用本地浏览页同款 `DirectoryScreen` 组件，彻底解决了远程↔本地切换时页面错乱、文件列表消失的头号 BUG。

| | |
|---|---|
| 🔄 **统一浏览架构** | 远程（FTP/SFTP/WebDAV/SMB）与本地共享同一套浏览引擎 |
| 🪟 **双窗格远程** | 本地与远程并排浏览，双窗格间自由拖放文件 |
| 📋 **全局剪贴板** | 远程复制/剪切 → 本地粘贴，无需独立剪贴板 |
| 🗑️ **完整文件操作** | 远程服务器上删除、重命名、新建文件夹，操作手势与本地一致 |
| 🐛 **BUG 修复** | 修复从远程返回后本地文件列表异常消失的问题 |

**v1.0.2 其他优化：**
- **滑动切换页面** — 左右滑动手势在分类页与浏览页之间切换
- **紧凑界面** — 面包屑栏、标签标题栏全面瘦身，腾出30%屏幕空间
- **圆环进度条** — 文件传输时显示精美圆环进度指示器
- **跨平台路径修复** — 修复 Windows 平台远程拖放路径解析问题

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
