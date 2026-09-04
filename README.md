[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android, built with Flutter. It pairs stunning glassmorphism aesthetics with system-level media indexing (Android MediaStore) for instant, battery-friendly browsing, plus an all-in-one Toolbox, fast FTP / WebDAV / SMB / SFTP access, and peer-to-peer Quick Transfer.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

> 📥 For users in China, download from any of the mirrors below (identical to the GitHub Release):

- ☁️ **123 Cloud Drive**: https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2
- ☁️ **115 Cloud**: https://115cdn.com/s/swsho4j3hc6?password=m490
- ☁️ **Baidu Netdisk**: https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94
- ☁️ **Quark**: https://pan.quark.cn/s/e6081a88d463
- ☁️ **PikPak**: https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2


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
