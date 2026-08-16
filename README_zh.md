[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.30 更新内容

### ✨ 新功能

- **远程保护 PIN 码**：设置 4 位 PIN 后，访问已保存远程服务器、进入编辑页、分类页切换到远程范围时需先解锁，保护远程数据隐私
- **分类页「本地/远程」切换**：所有支持远程目录的类别可独立切换本地/远程内容
- **备份功能（本地→远程）**：支持「自动备份」与「立即备份」，新增文件检测自动触发，只备份该类别格式文件
- 远程连接向导新增「测试」按钮，可先验证连接再保存配置
- 视频/音频类别菜单新增「播放器控制器显隐」开关
- 统一「打开方式」弹窗：浏览页/最近页/分类页 三点与长按菜单均弹应用内选择弹窗
- 未知格式文件选「本应用打开」后弹出类型选择器（文本/音频/视频/图像）并以内置查看器打开

### 🔧 优化

- 分类页/浏览页「分类」「浏览」按钮合二为一，居中翻转切换
- 重命名自动选中文件名主体（不含扩展名），光标落扩展名前
- 网格/列表视图切换整合进排序菜单
- 每个类别独立记忆「文件夹/全部项目」查看模式，视频/音频默认文件夹查看
- 下载类别支持远程备份
- 远程图片/视频缩略图按需下载显示
- 本地扫描排除应用缓存目录，修复打开远程缩略图后本地图片重复
- 远程文件三点菜单与长按批量删除/重命名/复制/剪切/定位操作生效
- 远程文件夹下钻保留目录结构（DCIM/Pictures 等顶层目录）

### 🐛 问题修复

- 修复 MIUI 存储权限误判导致启动弹窗循环卡死
- 修复分类页长按拖动类别图标误触左右切页
- 修复截图在图片类别「按文件夹」下钻后消失

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
