[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter to deliver ultimate performance and stunning glassmorphism aesthetics.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.24

### ✨ New Features

- Category pages now offer a "Group by Folder" view, so media files can be browsed grouped by their source folders for quick location.

### 🔧 Optimizations

- All remote clients (SMB / FTP / SFTP / WebDAV) now support streaming media playback without downloading the whole file; streaming uses an independent connection so seeking is instant and no longer affects the remote browsing session.
- SMB downloads now use an 8MB SMB2 read/write window (SMB2 large MTU limit), drastically cutting RTT round-trips so the link can be saturated on fast LANs.

### 🐛 Bug Fixes

- Fixed an issue where, after cutting/moving a file from a remote location to local (or local to remote), the source directory still showed the original file until manually refreshed.
- Fixed the audio player's "Play in background" toggle not refreshing its on/off state immediately in the menu (previously required reopening the menu).
- Fixed media playback control buttons not showing in the notification shade on Android 13+. Patched a local fork of `audio_service` 0.18.18 so compact-view action buttons are set on all API versions and the `MediaSession`/foreground service is activated for any non-idle playback state, ensuring the Android 13+ media card appears.

---

## 🚀 What's New in v1.1.23

### ✨ New Features

- App Management: Added a 'Copy Package Name' option in the app popup menu, allowing one-tap copy of the app's package name.
- Path bar: Long-press the path bar to enter edit mode, allowing you to input and navigate to a specified path.

### 🔧 Optimizations

- Category media browsing (images, videos, audio, screenshots) now uses recursive filesystem scanning instead of system-level media library indexing (MediaStore). Category recognition is now more accurate and stable — files that are moved or renamed no longer disappear from their category. The scanning logic is unified with the Web Sharing page.
- Video and audio thumbnails are now generated natively (via MediaMetadataRetriever) instead of relying on system media thumbnails.
- Recycle Bin management is now unified: the enable switch and auto-delete duration setting were moved out of Settings into the Recycle Bin page (opened from Drawer → Local → Recycle Bin), so the toggle and the bin contents are managed in one place.

### 🐛 Bug Fixes

- Fixed the issue where the global search could not find files in the data directory.
- Fixed the issue where the 'Uninstall' button in the App Management popup overflowed the bottom of the screen on some devices, making it hard to tap.
- Fixed an issue where browsing a remote directory would return an empty local directory.
- Fixed missing video thumbnails in list view (thumbnails already worked in grid view).
- Fixed the "Select All" button failing to select all items after long-pressing to enter selection mode on category pages.
- Improved selection highlighting on category pages: selected items now show a clear colored border and tinted background instead of only a small corner checkmark.
- Fixed an issue where the app would crash on launch (at the language selection page) after clearing app data/cache. The system could report the all-files permission as granted while actual storage access was denied (permission state inconsistency); permission is now verified with a real directory probe before granting access.
- Fixed an issue where backing up a large APK succeeded in the background but showed no completion dialog. The progress dialog now uses the root navigator's overlay context and is non-dismissible, so the success dialog always appears when the backup finishes.
- Fixed external subtitle size and position not taking effect. External subtitles are now rendered via a Flutter overlay driven by parsed SRT/ASS cues, so the size and position sliders work reliably for all subtitle formats.
- Improved online lyrics search: it now lists candidate songs so you can manually pick the correct one, avoiding wrong matches when songs share the same title but have different artists (previously it auto-matched the first result).
- Fixed FTP sharing showing an empty directory to other clients after a successful connection. The PASV passive-mode response previously returned the server's anyIPv4 address (0.0.0.0), which a remote client cannot connect back to; it now returns a concrete, reachable LAN address (or loopback for same-device clients), so the directory listing is delivered correctly.

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
