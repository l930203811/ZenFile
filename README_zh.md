[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器与离线媒体中心，基于 Flutter 打造。它将惊艳的毛玻璃美学与系统级媒体索引（Android MediaStore）相结合，实现零扫描、瞬时加载的浏览体验，并集成了全能工具箱、高速 FTP / WebDAV / SMB / SFTP 远程访问，以及点对点快传。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.34 更新内容

### 🐛 问题修复

- **网页共享卡死**：修复网页共享被其他设备访问时应用界面卡死的问题——全量扫描已改为异步执行，不再阻塞 UI 线程。
- **FTP 连不上/选错网卡**：重写本地 IP 选择逻辑，优先 wlan/eth 接口，跳过 Docker/VPN/虚拟网卡，避免回退到不可达地址。
- **FTP 自定义端口**：支持设置并持久化自定义端口，运行中修改自动重启监听。
- **FTP 控制端口绑定与 PASV**：用具体局域网 IP 绑定控制端口、简化 PASV 地址解析，修复 VPN/代理场景连接失败。
- **FTP 停止提示错误**：新增「FTP 服务器已停止」提示，替换原先错误的「更改端口 未激活」。
- **文本编辑器保存/另存为**：合并为单一保存按钮，点击弹出菜单选择「保存」或「另存为」。

### ✨ 新功能

- **分类页工具箱入口**：在分类页新增工具箱快捷入口。
- **工具箱整合**：将私人保险箱、局域网唤醒、快传整合进工具箱，集中管理。
- **快传记住设备**：自动记住已连接设备，下次一键点击连接重连；已记住列表支持单独删除设备。

### 🎨 优化

- **快传对称化传输**：连接成功后双方均可主动发送，移除收发模式切换与顶部切换按钮。
- **快传 UI 整体美化**：分区卡片化、设备行卡片化、图标徽章、填充式选择框、进度页圆形徽章，视觉更统一。
- **快传主界面紧凑化**：收紧卡片内边距与各项间距，减少首屏滚动，进入即可看到雷达/设备列表。

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
