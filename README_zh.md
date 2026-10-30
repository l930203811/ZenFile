[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器与离线媒体中心，基于 Flutter 打造。它将惊艳的毛玻璃美学与系统级媒体索引（Android MediaStore）相结合，实现零扫描、瞬时加载的浏览体验，并集成了全能工具箱、高速 FTP / WebDAV / SMB / SFTP 远程访问，以及点对点快传。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

> 📥 国内用户可任选以下网盘下载（与 GitHub Release 内容一致）：

- ☁️ **123 云盘**：https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2
- ☁️ **115 网盘**：https://115cdn.com/s/swsho4j3hc6?password=m490
- ☁️ **百度网盘**：https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94
- ☁️ **夸克网盘**：https://pan.quark.cn/s/e6081a88d463
- ☁️ **PikPak**：https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2



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

### 原作者

基于 [Senzme/NFile](https://github.com/Senzme/NFile) 二次开发，感谢原作者提供优秀的代码基础！

### 打赏者

衷心感谢以下朋友的支持与信任：**𝗖𝗵𝗲𝗻𝗴𝗵𝘂𝗮**、**被窝一级避难所**、**季风**、**从前有座山**、**羁客**、**无处安放**、**你没急吧** —— 你们的支持是 ZenFile 持续更新的最大动力。

### 开源项目

ZenFile 站在以下优秀开源项目的肩膀上（排名不分先后）：

- [media_kit](https://github.com/media-kit/media-kit)（mpv）— 音视频播放引擎
- [audio_service](https://pub.dev/packages/audio_service) — 后台播放与系统媒体会话
- [on_audio_query](https://github.com/MSOB7YY/on_audio_query) — 媒体库查询
- [dartssh2](https://github.com/TerminalStudio/dartssh2) — SFTP 协议实现
- [cronet_http](https://pub.dev/packages/cronet_http) — 高性能网络传输
- Syncfusion — PDF / 文档渲染
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — 凭据安全存储
- [audioMotion-analyzer](https://github.com/hvianna/audioMotion-analyzer) — 音频频谱可视化算法参考（AGPL-3.0）
- 腾讯 Bugly — 崩溃统计

### 建议与反馈

感谢所有为 ZenFile 提出宝贵建议与问题反馈的用户 —— 应用内：𝗖𝗵𝗲𝗻𝗴𝗵𝘂𝗮、越界、YC影尘、猕猴桃、大手拉小手、小熊猫[自重率0%]、SAS、Dr. Homi J. Bhabha、sky、Aps、Oxlne、Jankst；GitHub：[KamrulShahed](https://github.com/KamrulShahed)、[0xlne](https://github.com/0xlne)、[SASlobby93](https://github.com/SASlobby93)、[aand1015](https://github.com/aand1015)、[LorianL98](https://github.com/LorianL98)、[qwertti123](https://github.com/qwertti123)。

每一条反馈都让 ZenFile 变得更好 —— 欢迎继续通过 [Issues](https://github.com/l930203811/ZenFile/issues) 提出建议！

---

## 📄 许可证

GNU GPL v3
