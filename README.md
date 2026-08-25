[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter to deliver ultimate performance and stunning glassmorphism aesthetics.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.33

### ✨ New Features

- **Quick Transfer (LAN)**: Independent send/receive modes, nearby-device radar discovery, connection states, pre-transfer confirmation, one-tap open in app browser after receiving, with permission hints. Fully localized in 10 languages.
- **Category icon label visibility toggle**.
- **AMOLED full-page pure-black theme**.
- **Background playback anti-sleep** (battery-optimization whitelist + wake lock).
- **Image editor**: physical dimensions (mm + DPI), preset templates (ID photo / passport / US visa), file size limit.
- **Audio equalizer with 5 presets** (Original / HD Vocals / Bass / Live / Jazz).
- **Video player**: built-in multi audio/subtitle track selection; gesture optimization (double-tap to pause/play, long-press for speed, swipe left/right to seek).
- **Drawer / Custom shortcuts**: added Quick Transfer entry.

### ⚙️ Optimizations

- **Image viewer**: top info bar rebuilt (dimensions/time/format/size/EXIF), rotate changed to preview-only (no save), live EXIF display, filename title restored.
- **Video player**: bottom button layout/ordering, portrait overflow fix, auto landscape on system rotation, scale (fill screen / cover), landscape camera black-bar fix.
- **Audio player**: equalizer preset switching takes effect, bass/vocal distortion fixed.
- **Video volume**: player slider now syncs in real time with system media volume.
- **Audio playback mode**: now persisted across app restarts.
- **Image editing**: crop ratio fix (square / 4:3 / 3:4 / ID photo).

### 🐛 Bug Fixes

- **Text editor**: hardcoded error toast when opening unknown files via "Open as text" is now localized.
- **Desktop lyrics**: hardcoded Chinese permission Toast is now localized.
- **Directory picker**: hardcoded Chinese "Pin selection" button is now localized.
- **Restricted directories** (Android/data | obb): fixed copy-to-local/remote errors (second fix).
- **Long-press menu**: restored v1.1.32 layout with high-contrast background and stroke.

---

## ✨ Features

- **Beautiful UI/UX** — Modern glassmorphism design with textures and transparency
- **Full Media Index** — Accurate, stable photo, video, and audio browsing via recursive filesystem scanning (unified with Web Sharing), so moved or renamed files always stay visible.
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
- `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO` — Standard media read permissions

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
- **Indexing:** Recursive filesystem scanning for media categories; `photo_manager` & `on_audio_query` retained for audio-model compatibility
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
