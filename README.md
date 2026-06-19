[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter for极致 performance and stunning glassmorphism aesthetics.

> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.0.4

**Text Editor & Multi-Language Expansion** — ZenFile adds a full-featured text editor with file creation, save-as, undo/redo, and persistent settings. Multi-language support is expanded to 10 languages.

| | |
|---|---|
| 📝 **Text Editor** | Create new files, save-as, undo/redo in the built-in text editor |
| 💾 **Editor Settings Persistence** | Word wrap, line numbers, and read mode preferences are saved automatically |
| 🌍 **10-Language Support** | Simplified Chinese, English, Traditional Chinese, Japanese, Korean, German, French, Spanish, Russian, and Arabic |
| 🐛 **l10n Hardcode Fixes** | Fixed multiple hardcoded strings that were not properly localized |
| 📜 **Scrollable Language Picker** | Language selection UI now supports scrolling for better usability |

---

## 🚀 What's New in v1.0.3

**SVG Support & i18n Multi-Language** — ZenFile now fully supports `.svg` vector graphics with thumbnail previews and full-screen viewing, and adds **Chinese & English** bilingual interface support.

| | |
|---|---|
| 🖼️ **SVG Thumbnails** | Grid and list views both support SVG thumbnail rendering |
| 🔍 **SVG Viewer** | Full-screen viewer renders vector graphics perfectly with zoom support |
| 🌐 **i18n Bilingual UI** | Full Chinese & English support across all 700+ UI strings |
| 🔄 **Instant Language Switch** | Change language on-the-fly in Settings → Language |
| 💾 **Persistent Preference** | Selected language is saved and restored on next launch |
| 🎨 **Archive Colors** | Different compression formats display with their own color (zip orange / rar red / 7z purple / tar brown / gz green) |
| 🌐 **Remote File Playback** | Remote server files are downloaded locally before playback, with remote thumbnail preview support |
| 🐛 **Bug Fixes** | Fixed page freeze after extraction, remote file open failure and other issues |

**Other v1.0.3 improvements:**
- **Date Format** — Unified to `yyyy-MM-dd`
- **Time Format** — 24-hour format enabled by default
- **Cache Consolidation** — Remote file cache unified to `Download/ZenFile_Remote`

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
