[英语]（README.md） |中文

# ZenFile

一款精美绝伦的开源文件管理器和离线媒体中心。基于 Flutter 构建，拥有极致性能和惊艳的毛玻璃美学。

> **声明**：本项目基于 [Senzme/NFile](https://github.com/Senzme/NFile) 进行二次开发优化。 感谢原作者的开源贡献！

---

## 🚀 v1.1.32 更新内容

### ✨ 新功能

- **局域网唤醒（WOL）**：抽屉页「工具」栏新增入口，支持添加/编辑/删除设备（名称、MAC 地址、广播地址、端口），一键发送魔术包唤醒局域网内的电脑/设备，设备列表本地持久化存储，10 语言完整本地化
- **图片编辑器**：内置图片编辑器，支持裁剪（自由/比例预设/证件照尺寸）、旋转、翻转、滤镜（灰度/棕褐/反相/对比度/亮度/饱和度）和元数据查看。纯 Dart `image` 包实现，无原生依赖
- **一键去元数据**：图片查看页 3 点菜单新增「清除元数据」，重新编码剥离 EXIF/GPS/ICC 等全部元数据，另存为新文件
- **沉浸式信息条**：图片查看页触摸后底部显示文件名·尺寸·大小·格式；属性弹窗新增 Dimensions 行

### 🐛 问题修复

- 修复分类页按文件夹查看时全选按钮跨文件夹全选：图片/视频/音频/截图/文档/压缩包/下载/安装包共 8 个类别，进入文件夹多选后点全选不再选中其他文件夹的文件；仅在「全部项目」查看时全选所有文件
- 修复图片类别按文件夹查看时截图文件夹（DCIM/Screenshots）全选按钮失效
- 修复图片/截图查看页「在位置中显示」无法跳转到浏览页（本地与远程路径均适用）
- 修复应用管理批量操作备份按钮标题显示「正在备份...」（已改为「备份」，10 语言同步更新）
- 修复图片查看器 Dismissible 滑动块缺失闭合括号导致的编译错误
- 修复分类页全选按钮混入远程/本地文件（按当前范围过滤）
- 修复非媒体类别（文档/压缩包/下载/安装包）浏览页删除或移动后分类页残留空白图标
- 修复远程图片删除后缩略图残留、siblingItems 列表未同步更新
- 修复分类页媒体总大小启动后「显示约 1 秒 → 归零 → 重新加载恢复」的闪烁问题
- 修复标签页左右滑动误触切换页面（新增 tabBarInteracting 标志位保护）
- 修复自动备份开关不生效（新增 _autoSyncTriggered 守卫 + isLoaded 状态检查）
- 修复备份逻辑错乱（远程缺失文件时重新上传而非丢弃记录）
- 修复「打开所在位置」需手动按返回键才能看到跳转（改为 popUntil(isFirst) 一次性弹回首页）
- 修复刷新按钮扫描不到非媒体文件（如 APK 加载不出），补充 onlyApk 参数并修正分类分支逻辑
- 修复批量备份进度对话框卡住不消失（改用 rootNavigator 模式 + backupDialogOpen 标志位）

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
