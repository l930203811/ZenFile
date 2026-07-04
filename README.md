[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter for极致性能 and stunning glassmorphism aesthetics.

> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.0.43

**Native SMB Rewrite & Desktop Lyric Floating Window & Streaming Playback Fixes** — SMB client completely rewritten with native Android smbj library for real SMB protocol. Added desktop lyric floating window with word-by-word karaoke highlighting and drag-to-resize. Fixed FTP/SFTP streaming playback, notification panel, and background play continuity. Refined breadcrumb borders, three-dot button positions, and category selection back behavior.

🙏 **Thanks for Feedback** — Thanks to the following users for feedback and suggestions: 越界, 猕猴桃, Sir Jagadeesh Chandra Bose

| | |
|---|---|
| 🌐 **Native SMB Client** | Completely rewrote SMB client using native Android smbj library for real SMB protocol, with automatic share name detection |
| 📡 **FTP/SFTP Streaming Fix** | Fixed FTP/SFTP streaming playback using raw Socket with independent data connection, supporting progressive caching |
| 🌐 **Remote Page i18n Fix** | Fixed hardcoded strings in remote connection page, added l10n keys for SMB protocol description and connection name suffix |
| 🖼️ **Image Viewer Menu** | Image viewer top-right menu changed to bottom sheet with 9 action items, black semi-transparent background for visibility |
| 🔲 **Breadcrumb Border** | Added V-shaped complete border to breadcrumb buttons using CustomPaint, ensuring seamless connection and clear boundaries |
| ⋮ **Three-dot Button Position** | Moved file/folder three-dot action buttons to top-right corner of cards to avoid accidental touches during drag |
| ⚙️ **Three-dot Button Setting** | Renamed three-dot button setting to 'Show three-dot buttons' with three modes: all/single-window only/dual-window only |
| ↩️ **Category Back Behavior** | In category multi-select mode, back button now cancels selection instead of exiting the category |
| 🎤 **Desktop Lyric Floating Window** | Added desktop lyric floating window with permission check, draggable position, and tap to toggle play/pause |
| 🔔 **Notification Panel Fix** | Fixed notification panel not showing playback controls, retained notification on pause, with permission denial prompts |
| 🎶 **Word-by-word Lyric Highlight** | Floating lyric supports word-by-word highlighting using SpannableStringBuilder for karaoke effect |
| ↔️ **Floating Window Resize** | Floating lyric window supports long-press to show resize handle, drag to adjust window and text size |
| ▶️ **Background Play Fix** | Fixed music pausing when enabling background play, attach reuses player instance without interruption |
| 🔄 **Category Button Sync** | Fixed category page play button showing stale audio info when background play is off, refreshes on return |
| 🛠️ **Build Stability** | Fixed R8 compilation OOM, x86_64/armv7 startup white screen, adjusted Gradle JVM memory and ABI downloads |
| ✨ **Lyric Scale Animation** | Added scale effect to word-by-word lyric transition animation, fixed sync issues, fixed 300ms transition duration |

---

## 🚀 What's New in v1.0.42

**Music Player Enhancements & Redesigned File Icons & Navigation Bar Customization** — The music player now supports LRC lyrics loading, playback progress memory, and a quick shortcut on the music category page. File icons for images, documents, and archives have been redesigned with format labels. Added navigation bar position setting with top/bottom options, plus optimized browse page layout.

| | |
|---|---|
| 🎵 **Lyrics Fullscreen Panel Removed** | Removed the lyrics fullscreen panel for a cleaner playback experience |
| 🎵 **Current Lyrics Center-Aligned** | Current playing lyric line now displays centered for better readability |
| 🎵 **Music Category Quick Player** | Added a music player shortcut button at the top of the music category page for quick access |
| 🎵 **Playback Progress Memory** | Music player remembers playback position and auto-resumes on next launch |
| 🖼️ **Image Icon Redesign** | Redesigned image file icons with format labels (jpg, png, etc.) |
| 📄 **Document Icon Redesign** | Redesigned document file icons with format labels |
| 🗜️ **Archive Icon Redesign** | Redesigned archive icons with format labels (zip, 7z, rar, etc.) |
| 🎶 **LRC Lyrics Support** | Music player supports auto-loading LRC lyrics and manual lyrics file selection |
| 🐛 **Remote Paste Fix** | Fixed remote server copy-to-local paste operation where progress bar was unresponsive and files were not appearing |
| 📍 **Navigation Bar Position** | Added navigation bar position setting, support top or bottom display |
| 📐 **Browse Page Layout Optimized** | Optimized browse page top area layout when bottom navigation bar is enabled, increasing file list display space |

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
