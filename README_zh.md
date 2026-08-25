[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.33 更新内容

### ✨ 新功能

- **快传功能（局域网传输）**：独立快传页面（发送/接收双模式）、附近设备雷达扫描发现、设备连接/已连接状态、传输前确认机制、接收完成后一键在本应用浏览页打开、权限说明，全 10 语言。
- **分类图标标签显隐开关**
- **AMOLED 全页纯黑主题**
- **后台播放防休眠**（电池优化白名单 + 唤醒锁）
- **图片编辑器**：物理尺寸(mm+DPI)、预设模板(证件照/护照/美签)、文件大小限制
- **音频均衡器 5 预设**（原声/HD人声/低音/现场/爵士）
- **视频播放器**：内嵌多音轨/多字幕轨选择；手势优化（双击暂停/播放、长按倍速、左右滑快进/快退）
- **抽屉 / 自定义快捷方式**：入口新增「快传」

### ⚙️ 优化

- **图片查看器**：顶部信息条重构（尺寸/时间/格式/大小/EXIF）、旋转改为纯预览不保存、EXIF 实时显示、文件名标题恢复
- **视频播放器**：底部按钮布局/排序、竖屏溢出修复、系统自动横屏进全屏、缩放比例(填充屏幕 cover)、全屏横屏摄像头黑边修复
- **音频播放器**：均衡器预设切换生效、低音/人声失真修复
- **视频音量**：播放器滑块与系统媒体音量实时同步
- **音频播放模式**：重启后持久化记忆
- **图片编辑**：裁剪比例（正方形/4:3/3:4/证件照）修复

### 🐛 问题修复

- **文本编辑器**：打开未知文件「文本打开」错误提示硬编码 → 多语言
- **桌面歌词**：权限提示中文硬编码 Toast → 多语言
- **目录选择器**：「固定所选」按钮硬编码中文 → 多语言
- **受限目录**（Android/data｜obb）复制到本地/远程报错二次修复
- **长按菜单**：复刻 v1.1.32 显示结构 + 高对比背景 + 描边

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
