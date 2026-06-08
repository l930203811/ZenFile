# ZenFile

一款基于 Flutter 构建的精美文件管理器。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

## 概述

ZenFile 旨在为 Android 提供极致美观的文件管理体验。拥有独家 "Broken" 图标包、动态 AMOLED 深色模式和流畅的用户体验。

最新版本中，ZenFile 从简单的文件浏览器升级为综合性媒体中心，内置高性能播放器和查看器。

## 二次开发亮点

在原版基础上，我们进行了以下优化和改进：

### 🎨 UI/UX 优化
- **远程服务器页面布局优化**：将抽屉、分类、浏览按钮从右侧移到左侧，与首页/浏览页保持一致
- **关于页面全面汉化**：所有英文文本已翻译为中文

### 🚀 功能增强
- **左右滑动切换页面**：在分类页与浏览页之间支持左右滑动手势切换
- **远程服务器粘贴优化**：修复从远程服务器复制文件到本地后页面卡死的问题
- **进度条可视化**：从远程服务器复制/剪切文件到本地时，显示圆形进度条和百分比

### 🛠️ 导航优化
- **修复返回/下一级按钮**：在权限受限页面（如 `/storage/emulated`）时，返回和下一级按钮仍然可用
- **修复下一级按钮逻辑**：点击上一级后，下一级按钮可以正确返回到之前的路径



## 功能特性

- **精美 UI/UX：** 纹理与透明度融合的现代玻璃拟态界面设计。
- **原生媒体索引：** 利用设备原生索引实现闪电般的图片、视频和音频库浏览，无需慢速递归扫描。
- **内置媒体播放器：**
- **高性能视频播放器：** 基于 'media_kit' 驱动，流畅播放高分辨率视频。
    - **优雅音频播放器：** 简洁的播放界面，支持专辑封面和精确进度控制。
    - **双指缩放图片查看器：** 流畅手势操控，查看每一个细节。
- **内置文本编辑器：** 直接在应用内查看和编辑 `.txt`、`.md`、`.json` 等代码文件。
- **高级排序：** 按最新、最旧或日期筛选媒体文件，快速找到所需内容。
- **完整文件操作：** 轻松复制、剪切、粘贴、重命名和删除文件或文件夹。
- **快捷分类：** 一键访问已索引的媒体库。
- **存储概览：** 直观展示设备内部存储使用情况。
- **流畅界面：** 全应用采用 iOS 风格弹性物理效果和流畅过渡动画。
- **远程服务器支持：** 支持 FTP、SFTP、WebDAV、局域网/SMB 等多种远程连接方式。

## 截图

| | | | |
|:---:|:---:|:---:|:---:|
|<img src=“https://github.com/l930203811/ZenFile/blob/main/assets/screenshots/screenshot_4.jpg” width=“200”> | <img src=“https://github.com/l930203811/ZenFile/blob/main/assets/screenshots/screenshot_2.jpg” width=“200”> | <img SRC=”https://github.com/l930203811/ZenFile/blob/main/assets/screenshots/screenshot_3.jpg“ width=”200“> | <img src=”https://github.com/l930203811/ZenFile/blob/main/assets/screenshots/screenshot_1.png“> |

## 权限说明

应用需要以下权限以实现完整功能：
- `MANAGE_EXTERNAL_STORAGE`：用于跨设备全局的文件操作。
- `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO`、`READ_MEDIA_AUDIO`：用于高速原生媒体索引。

## 构建与运行

1. 克隆此仓库。
2. 运行 `flutter pub get` 安装依赖。
3. 在 Android 设备上运行 `flutter run`（需要 API 21+）。

## 技术栈

- **Flutter & Dart**
- **状态管理：** `provider`
- **媒体引擎：** `media_kit`（视频和音频播放）
- **索引：** `photo_manager` & `on_audio_query`
- **权限：** `permission_handler`
- **查看器：** `photo_view` & `open_filex`

## 联系我们

- **Telegram 频道：** [https://t.me/+47n76Au6mhg0MDA1](https://t.me/+47n76Au6mhg0MDA1)
- **QQ 群：** 792408214
- **邮箱：** 1@sequel.dpdns.org
- **GitHub：** [https://github.com/l930203811/ZenFile](https://github.com/l930203811/ZenFile)

## 致谢

感谢 [Senzme/NFile](https://github.com/Senzme/NFile) 原作者的开源贡献，为本项目提供了优秀的基础代码。

## 许可证

GNU GPL v3 许可证
