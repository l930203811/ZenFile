[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter for极致 performance and stunning glassmorphism aesthetics.

> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.0.3

**Full SVG Support** — ZenFile now fully supports `.svg` vector graphics with thumbnail previews and full-screen viewing, while maintaining complete support for images, videos, audio, and archives.

| | |
|---|---|
| 🖼️ **SVG Thumbnails** | Grid and list views both support SVG thumbnail rendering |
| 🔍 **SVG Viewer** | Full-screen viewer renders vector graphics perfectly with zoom support |
| 🎨 **Archive Colors** | Different compression formats display with their own color (zip orange / rar red / 7z purple / tar brown / gz green) |
| 🌐 **Remote File Playback** | Remote server files are downloaded locally before playback, with remote thumbnail preview support |
| 🐛 **Bug Fixes** | Fixed page freeze after extraction, remote file open failure and other issues |

**Other v1.0.3 improvements:**
- **Date Format** — Unified to `yyyy-MM-dd`
- **Time Format** — 24-hour format enabled by default
- **Cache Consolidation** — Remote file cache unified to `Download/ZenFile_Remote`

---

## 🚀 What's New in v1.0.2

**Remote Browser Rebuilt** — The biggest architectural change yet. The remote server browser now uses the same `DirectoryScreen` component as local browsing, completely eliminating the stale UI bug when switching between remote and local views.

| | |
|---|---|
| 🔄 **Unified Browser** | Remote (FTP/SFTP/WebDAV/SMB) now shares the same UI engine as local browsing |
| 🪟 **Dual-Pane Remote** | Browse local + remote side by side, drag files freely between panes |
| 📋 **Global Clipboard** | Copy/cut from remote, paste to local — no separate clipboard |
| 🗑️ **Full File Ops** | Delete, rename, create folders on remote servers, same gestures as local |
| 🐛 **Crash Fix** | Fixed the bug where navigating back from remote caused local file list to disappear |

**Other v1.0.2 improvements:**
- **Swipe Navigation** — Swipe left/right to switch between Category and Browse tabs
- **Compact UI** — Slimmed breadcrumb bar, tab headers — 30% more screen space
- **Ring Progress** — Elegant circular progress indicator during file transfers
- **Cross-Platform Path Fix** — Fixed remote path parsing on Windows for drag-and-drop

---

## ✨ Features

- **Beautiful UI/UX** — Modern glassmorphism design with textures and transparency
- **Native Media Index** — Lightning-fast photo, video, and audio browsing via device-native indexes
- **Built-in Media Player**
  - High-performance video player powered by `media_kit`
  - Elegant audio player with album art and precise progress control
  - Pinch-to-zoom image viewer with smooth gesture controls
- **Built-in Text Editor** — View and edit `.txt`, `.md`, `.json`, and code files in-app
- **Advanced Sorting** — Filter by newest, oldest, or date to quickly find content
- **Full File Operations** — Copy, cut, paste, rename, and delete files or folders
- **Quick Categories** — One-tap access to indexed media libraries
- **Storage Overview** — Visual display of internal storage usage
- **Smooth Animations** — iOS-style spring physics and fluid transitions throughout
- **Remote Server Support** — FTP, SFTP, WebDAV, SMB/LAN — all with unified browsing experience
- **Dual-Pane Browsing** — Two directories side-by-side with drag-and-drop transfers
- **Multi-Tab Support** — Open multiple folders in tabs for quick navigation
- **Encrypted Vault** — Protect sensitive files with built-in encryption

---

## 📸 Screenshots

| | | | |
|:---:|:---:|:---:|:---:|
|<img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_4.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_2.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_3.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_1.png" width="200"> |

---

## 🔧 Permissions

Required for full functionality:
- `MANAGE_EXTERNAL_STORAGE` — Global file operations across device
- `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO` — Fast native media indexing

---

## 🏗️ Build & Run

1. Clone this repository
2. Run `flutter pub get` to install dependencies
3. Run `flutter run` on an Android device (API 21+ required)

---

## 🛠️ Tech Stack

- **Flutter & Dart**
- **State Management:** `provider`
- **Media Engine:** `media_kit`
- **Indexing:** `photo_manager` & `on_audio_query`
- **Permissions:** `permission_handler`
- **Viewers:** `photo_view` & `open_filex`

---

## 📡 Contact

- **Telegram:** [https://t.me/+47n76Au6mhg0MDA1](https://t.me/+47n76Au6mhg0MDA1)
- **QQ Group:** 792408214
- **Email:** 1@sequel.dpdns.org
- **GitHub:** [https://github.com/l930203811/ZenFile](https://github.com/l930203811/ZenFile)

---

## 🙏 Acknowledgements

Based on [Senzme/NFile](https://github.com/Senzme/NFile) — thank you for the excellent foundation!

---

## 📄 License

GNU GPL v3
