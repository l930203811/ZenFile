[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器与离线媒体中心，基于 Flutter 打造。它将惊艳的毛玻璃美学与系统级媒体索引（Android MediaStore）相结合，实现零扫描、瞬时加载的浏览体验，并集成了全能工具箱、高速 FTP / WebDAV / SMB / SFTP 远程访问，以及点对点快传。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.39 更新内容

> 📥 国内用户可任选以下网盘下载（与 GitHub Release 内容一致）：

- ☁️ **123 云盘**：https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2
- ☁️ **115 网盘**：https://115cdn.com/s/swsho4j3hc6?password=m490
- ☁️ **百度网盘**：https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94
- ☁️ **夸克网盘**：https://pan.quark.cn/s/e6081a88d463
- ☁️ **PikPak**：https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2

### ✨ 新增功能

- **图片编辑器绘图工具**：新增 7 种绘图工具（画笔 / 文本 / 矩形 / 椭圆 / 直线 / 箭头 / 马赛克）；文本实时完整显示（不再被省略截断），矩形 / 椭圆即时预览，辅助框自动隐藏（仅点击选中项才显示），切换工具自动保存且可经顶部按钮撤回。
- **保险箱指纹解锁 + 导出 / 导入备份**：支持指纹解锁；可一键导出 / 导入整库备份，避免卸载重装后数据丢失。

### 🐛 问题修复

- **从其它应用分享不再复制进应用私有缓存**：图库 / 文件管理器 / 媒体库的文件保留在原位置打开，不额外占空间；「打开文件所在位置」直达真实文件夹并高亮。私有内容分享（如 WhatsApp）因系统不暴露真实路径仍会缓存。
- **分享入口选择框**：无权限读取分享文件时直接弹权限提示；外部打开方式选择框改为左对齐，顺序为「打开 → 打开文件所在位置 → 取消」。
- **分享后「打开文件所在位置」精准跳转**：先切到浏览页，再加载父目录并居中高亮目标文件。
- **视频无声修复**：首次打开即有声音；软解 / 硬解切换后均衡器重新挂载且仍有声；退出重开不再丢失声音。
- **均衡器修复**：视频切回音频时预设生效；从后台返回不再被重置为 Flat，预设重新应用且后台播放保持挂载。
- **点击媒体通知栏**可正确跳转到对应播放页。
- **Android/data 根目录显示 0 项**：回退到 Shizuku 原始路径列举。
- **双窗口浏览器文件夹项**：修复大小 / 数量 / 日期缺失与英文硬编码，现以紧凑的「数量 • 大小 • 日期」展示并跟随多语言。
- **卸载重装后保险箱恢复失败**：备份包内嵌 V2 密码校验参数，重装后可用原密码解锁恢复；跨设备导入时把记录重新指向真实保险箱路径。

### 🔧 其它优化

- **分类页多选栏**：修复窄语言下的文字溢出；**图片查看器操作栏**：修复俄语等较长语言标签的溢出。

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
