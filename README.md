[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android, built with Flutter. It pairs stunning glassmorphism aesthetics with system-level media indexing (Android MediaStore) for instant, battery-friendly browsing, plus an all-in-one Toolbox, fast FTP / WebDAV / SMB / SFTP access, and peer-to-peer Quick Transfer.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.37

### 🐛 Bug Fixes

- **Remote media playback stutter / seek jumps to start**: rebuilt the local HTTP streaming proxy's seek cache and chunked prefetch; fixed a non-zero-region read offset bug so first-byte latency dropped from "whole 24 MB segment" to "first chunk". Dragging no longer jumps back to the start on SFTP/SMB/FTP.
- **SFTP upload capped at ~2MB/s**: upgraded JSch 0.1.55 to 2.28.7 to support rsa-sha2/ED25519/OpenSSH-v1 keys, eliminating the silent fallback to the pure-Dart dartssh2 (the root cause of the cap); setBulkRequests(128) raises in-flight requests.
- **SFTP symlink directory (e.g. /sdcard) recognition**: follow the symlink's real target type on listing so directories can be entered normally.
- **Compile error (progress-minimize state machine)**: a field initializer referencing an instance method failed to compile; moved the assignment into the constructor body and relaxed final.

### ✨ New Features / Improvements

- **Split-pane active window top highlight**: the entire top status bar of the active pane is highlighted (primary background + 2.5px accent edge) for clearer identification.
- **Progress minimized to floating widget**: after tapping "background" on copy/move or category backup progress, a clickable circular floating button (with a spinning progress ring) appears in the status/tool bar; tap to reopen the progress page; it auto-dismisses when transfer completes/cancels.
- **Remote tab cloud icon**: the left icon of a remote tab is now a cloud icon replacing the folder icon; local tabs keep the folder icon.
- **File-type icon polish**: when no media thumbnail is available, images/videos/audio/install-packages show a "type icon + format label" (MP4/MKV/MP3/FLAC/APK...); install packages use the Android-robot icon (green), archives use a bundle icon (Broken.box) with ZIP/7Z/RAR labels; the music category page also shows a format label under each music icon; browsing and category pages share consistent icons.
- **Remote thumbnail privacy**: remote media thumbnails moved into a .nomedia directory with a marker file so they are not indexed by the system media library / other file managers; default remote-cache auto-clean interval changed to 0 (disabled).

### 🎨 Performance

- **Remote media streaming proxy tuning**: multi-region seek cache (max 4 regions) avoids re-buffering on back-and-forth seeks; enlarged mpv buffering (cache-secs 60 / demuxer-max-bytes 300M) reduces periodic stutter; 16 MB prefetch and 24 MB on-demand fetch improve start-up and seek responsiveness.

---

## ✨ Features

- **Beautiful UI/UX** — Modern glassmorphism design with textures and transparency
- **Full Media Index** — Accurate, stable photo, video, and audio browsing powered by system-level indexing (Android MediaStore), so moved or renamed files always stay visible without full storage scans.
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
- **Indexing:** System-level MediaStore indexing for media categories (instant, zero I/O); `photo_manager` & `on_audio_query` retained for audio-model compatibility
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
