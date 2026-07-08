[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter for极致性能 and stunning glassmorphism aesthetics.

> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.0

**Quick Action Panel & Favorites & Drawer Redesign & Video Player & Category Page & Progress Bar & Transfers** — Added a new quick action panel accessible by swiping left on the browse page, and introduced a Favorites feature to bookmark local or remote files/folders. The drawer has been redesigned for a cleaner look and remembers all expand/collapse state persistently. The video player now supports clockwise rotation and zoom ratio adjustment. The category page supports long-press drag-and-drop reordering, 3/4 column layouts, and category renaming. The progress dialog has been completely redesigned. Transfer stability and speed display have been improved.

| | |
|---|---|
| ⚡ **Quick Action Panel** | New quick action page accessible by swiping left on the browse page |
| ⭐ **Favorites** | Bookmark local or remote files/folders, pinned to the quick action panel |
| 🗂️ **Drawer Redesign** | Cleaner, more beautiful drawer that persists all expand/collapse state |
| 🎬 **Video Player Rotation** | Added clockwise rotation and zoom ratio adjustment for video playback |
| 🎨 **Category Page Reordering** | Long-press category icons to drag-and-drop reorder; supports 3/4 columns; supports renaming category names |
| 📊 **Progress Bar Redesign** | Brand-new circular progress dialog with a clean, modern look |
| 🪟 **Dual-Pane Status Bar** | New top status bar in dual-pane mode showing active window indicator and clipboard summary |
| 🐛 **Transfer Fixes** | Fixed FTP/SFTP/SMB/WebDAV progress bar not updating, cancel not working, remote list going blank, and missing real-time speed display |
| 🔤 **Drawer Font Consistency** | Fixed "Settings" font size to match other drawer entries |
| 📐 **Landscape Layout** | Optimized file grid layout for tablets and car infotainment systems in landscape mode |
| 🗜️ **Archive Fixes** | Fixed several archive-related issues |
| 🌍 **i18n** | Added complete multi-language support for the progress dialog |

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
- 🌍 **Multi-language Support**: Supports 10 languages including Simplified Chinese, English, Traditional Chinese, Japanese, Korean, German, French, Spanish, Russian, and Arabic.

---

## 📸 Screenshots

**中文界面：**

| | | | |
|:---:|:---:|:---:|:---:|
|<img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_1.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_2.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_3.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/screenshot_4.jpg" width="200"> |

**English Interface：**

| | | | |
|:---:|:---:|:---:|:---:|
|<img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_1.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_2.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_3.jpg" width="200"> | <img src="https://raw.githubusercontent.com/l930203811/ZenFile/main/assets/screenshots/en_screenshot_4.jpg" width="200"> |

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
