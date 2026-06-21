[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter for极致性能 and stunning glassmorphism aesthetics.

> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.0.41

**Web Sharing Portal Upgrade & Compression Improvements** — The web sharing portal now displays files in categorized sections with multi-language support. Compression workflow improvements include unified paths, multi-stage progress, and reliable auto-close.

| | |
|---|---|
| 📦 **Extract Dialog Redesign** | Redesigned with current directory / custom directory selection options |
| 🔒 **Vault Quick Category** | Added vault shortcut to quick categories (default off) |
| 🐛 **Vault l10n Fix** | Fixed vault screen hardcoded English text and multi-file freeze issue |
| 🗜️ **Compression Path Fix** | Unified compression paths for three-dot button and long-press menu, fixed archive name error |
| 📊 **Compression Progress** | Improved progress dialog with multi-stage progress display and reliable auto-close |
| 🌐 **Web Share Categories** | Web sharing portal now displays files in categorized sections (folders, videos, audio, images, documents, others) |
| 🌍 **Web Share l10n** | Web sharing portal supports multi-language display based on app locale |

---

## 🚀 What's New in v1.0.4

**Remote Media Streaming & Server-to-Server Transfer** — ZenFile now opens remote media files instantly with the player, caching in the background. Server-to-server copy/cut is also supported, along with improved audio scanning stability.

| | |
|---|---|
| 🎬 **Remote Media Instant Play** | Remote video/audio files open the player immediately with background caching and progress indicator |
| 📂 **Remote-to-Remote Transfer** | Copy/cut files between remote servers (same or different connections) |
| 📊 **Remote Cut Progress** | Fixed progress bar display for remote cut operations |
| 🎵 **Audio Scan Stability** | Improved audio category scanning reliability |
| 📝 **Text Editor** | Create new files, save-as, undo/redo in the built-in text editor |
| 💾 **Editor Settings Persistence** | Word wrap, line numbers, and read mode preferences are saved automatically |
| 🌍 **10-Language Support** | Simplified Chinese, English, Traditional Chinese, Japanese, Korean, German, French, Spanish, Russian, and Arabic |
| 🐛 **l10n Hardcode Fixes** | Fixed multiple hardcoded strings that were not properly localized |
| 📜 **Scrollable Language Picker** | Language selection UI now supports scrolling for better usability |

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
