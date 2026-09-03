[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android, built with Flutter. It pairs stunning glassmorphism aesthetics with system-level media indexing (Android MediaStore) for instant, battery-friendly browsing, plus an all-in-one Toolbox, fast FTP / WebDAV / SMB / SFTP access, and peer-to-peer Quick Transfer.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.39

> 📥 For users in China, download from any of the mirrors below (identical to the GitHub Release):

- ☁️ **123 Cloud Drive**: https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2
- ☁️ **115 Cloud**: https://115cdn.com/s/swsho4j3hc6?password=m490
- ☁️ **Baidu Netdisk**: https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94
- ☁️ **Quark**: https://pan.quark.cn/s/e6081a88d463
- ☁️ **PikPak**: https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2

### ✨ New Features

- **Image editor drawing tool**: 7 tools added (brush / text / rectangle / ellipse / line / arrow / mosaic). Text renders fully live (no ellipsis truncation), rectangles / ellipses preview instantly, helper boxes auto-hide (shown only for the tapped item), and switching tools auto-saves with the top undo button available.
- **Vault fingerprint unlock + export / import backup**: unlock with fingerprint; export / import a full vault backup in one tap so data survives uninstall & reinstall.

### 🐛 Bug Fixes

- **Sharing from other apps no longer copies into the app-private cache**: files from gallery / file manager / media library open in place with no extra space; "Open file location" jumps to the real folder and highlights the file. Private-content shares (e.g. WhatsApp) still cache because the system hides the real path.
- **Share dialog polish**: lacking permission to read a shared file now prompts for permission directly (no doomed copy); the external-open chooser is left-aligned and ordered "Open → Open file location → Cancel".
- **Precise "Open file location" after sharing**: it now switches to the browse tab, loads the parent directory, and highlights the target file.
- **Video no-audio fixed**: video now has sound on first open; toggling soft / hard decode re-attaches the equalizer and keeps audio; reopening the player no longer loses sound.
- **Equalizer fixes**: preset applies when switching from video back to audio; returning from background no longer resets to Flat — the preset is reapplied and stays attached during background playback.
- **Media notification tap** now correctly jumps to the relevant player screen.
- **Android/data root showing 0 items**: now falls back to raw Shizuku path listing.
- **Split-pane browser folder items**: fixed missing size / count / date and hardcoded English; now shown as compact "count • size • date" and localized.
- **Vault restore failure after reinstall**: the backup now embeds V2 password parameters so the original password unlocks after reinstall; cross-device import redirects records to the real vault path.

### 🔧 Other

- **Category multi-select bar**: fixed text overflow under narrow languages; **image viewer action bar**: fixed overflow of long-language labels (e.g. Russian).

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
