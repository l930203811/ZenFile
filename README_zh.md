[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。感谢原作者的开源贡献！

---

## 🚀 v1.1.0 更新内容

**快捷操作面板 & 收藏夹 & 抽屉页重构 & 视频播放器 & 分类页 & 进度条 & 传输优化** — 新增快捷操作面板，在浏览页可左滑弹出。新增收藏夹功能，可将本地或远程文件/文件夹添加到快捷操作面板的收藏夹中。抽屉页重构，更简洁美观，持久化记住所有展开/折叠状态。视频播放器新增顺时针旋转画面和缩放比例调节。分类页支持长按类别图标拖动排序、3/4 列布局、类别重命名。进度条窗口样式重新设计。传输稳定性和速度显示优化。

| | |
|---|---|
| ⚡ **快捷操作面板** | 重新调整顶部导航栏按钮，新增快捷操作页面，在浏览页可左滑弹出快捷操作面板 |
| ⭐ **收藏夹** | 支持将本地或远程文件/文件夹收藏到快捷操作面板的收藏夹中 |
| 🗂️ **抽屉页重构** | 抽屉页更加简洁美观，持久化记住抽屉页所有展开/折叠状态，操作更加便捷 |
| 🎬 **视频播放器旋转** | 视频播放器新增顺时针旋转画面，新增缩放比例调节 |
| 🎨 **分类页排序** | 优化分类页可长按类别图标拖动调整位置顺序，新增每行 3 列/4 列可选，支持重命名类别名称 |
| 📊 **进度条重设计** | 重新设计了进度条窗口样式 |
| 🪟 **双窗口状态栏** | 双窗口模式顶部新增状态栏，显示激活窗口指示器和剪贴板内容摘要 |
| 🐛 **传输修复** | 修复 FTP/SFTP/SMB/WebDAV 传输进度条不更新、无法取消、远程列表空白、传输速度不显示等问题 |
| 🔤 **抽屉页字体** | 修复抽屉页「设置」按钮字体与其他栏目不一致的问题 |
| 📐 **横屏布局** | 优化平板和车机横屏模式下的文件网格布局 |
| 🗜️ **压缩修复** | 修复了压缩过程中的一些问题 |
| 🌍 **多语言** | 进度条窗口新增完整的多语言翻译支持 |

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
