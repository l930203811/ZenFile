[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android, built with Flutter. It pairs stunning glassmorphism aesthetics with system-level media indexing (Android MediaStore) for instant, battery-friendly browsing, plus an all-in-one Toolbox, fast FTP / WebDAV / SMB / SFTP access, and peer-to-peer Quick Transfer.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.36 (Bug Fixes)

### 🐛 Bug Fixes

- **Single-pane active tab background highlight**: the active (current) tab button now shows a highlighted background instead of only the title text.
- **Split-pane multi-tab display/switch reworked**: tab A stays in the left pane, B in the right; when creating or switching to another tab, the active tab keeps its pane position while only the inactive pane gets replaced.
- **Split-pane can close the last two tabs**: either of the last two tabs can now be closed; closing auto-creates a replacement tab in the closed position so both panes always show content.
- **Split-pane remote tab title**: now always shows the saved remote client name (no longer changes with the opened directory).
- **Remote tab cloud badge**: the icon on the left of a remote tab title is now a cloud badge to distinguish remote vs. local tabs.

---

## 🚀 What's New in v1.1.35

### ✨ New Features

- **Multi-tab pane scope selector**: enabling "Multi-tab" pops a 3-option dialog (Single window only / Split window only / All); split mode now has its own tabs; selection persists.
- **SFTP SSH key auth**: switch between password and SSH key; pick a local private key (.pem / .key / .pub) with optional passphrase; compatible with OpenSSH / RSA / ED25519 / ECDSA.
- **SAF system authorization for Android/data**: four-tier fallback; a "System authorized access" button appears on failure; the tree URI is persisted after grant.
- **SMB wizard "Scan LAN devices"**: a titled top button auto-discovers LAN SMB devices without IP entry and auto-fills host and share name.
- **Image viewer shooting location**: the top bar shows capture GPS coordinates and auto-hides when none; tap to open the system map.
- **Image editor "Clear metadata"**: byte-level lossless strip of EXIF / GPS / ICC without re-encoding or quality loss.

### 🐛 Bug Fixes

- **Quick Transfer large-file crash**: the receiver now uses a chunked Uint8List queue + TCP backpressure (8MB / 1MB watermark); files ≥1GB are received stably.
- **Image viewer wrong EXIF title**: the title now shows only when real capture-parameter fields exist.
- **Multi-tab settings fixes**: wired the scope picker, pops only when enabling, and localized 3 hardcoded Chinese strings.
- **Build failed (Java heap space)**: raised gradle -Xmx from 1536M to 6144M.

### 🎨 Improvements

- **Quick Transfer chunked buffer + TCP backpressure**: stable memory, no freeze on ≥1GB files.
- **Clear metadata byte-level strip**: deterministic and lossless.
- **SMB scan reuses the same filter logic as the wizard**: consistent behavior.

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
