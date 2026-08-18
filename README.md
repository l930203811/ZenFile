[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter to deliver ultimate performance and stunning glassmorphism aesthetics.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.30

### ✨ New Features

- **Remote Protection PIN**: Set a 4-digit PIN to protect access to saved remote servers, edit pages, and remote scope in category pages
- **Category Local/Remote Toggle**: All categories with remote directory support can independently switch local/remote content
- **Backup (Local→Remote)**: Auto-backup and manual backup with new file detection, only backs up files of the category's format
- Remote connection wizard adds "Test" button to verify connection before saving
- Video/Audio category menu adds "Player Controller Visibility" toggle
- Unified "Open With" dialog: Browse/Recent/Category pages all show in-app selection popup
- Unknown format files show type picker (Text/Audio/Video/Image) when "Open with App" is selected
- Video player adds a Soft/Hard decode toggle, balancing quality and performance by device decode capability
- Category page shows a "Refresh complete" toast after refresh, with multilingual support

### 🔧 Optimizations

- Category/Browse page buttons merged into single centered toggle
- Rename auto-selects filename body (without extension), cursor placed before extension
- Grid/List view toggle integrated into sort menu
- Each category independently remembers "Folder/All Items" view mode; Video/Audio default to Folder view
- Download category supports remote backup
- Remote image/video thumbnails downloaded on demand
- Local scan excludes app cache directory, fixing duplicate images after enabling remote thumbnails
- Remote file 3-dot menu and long-press batch delete/rename/copy/cut/location operations now work
- Remote folder drill-down preserves directory structure (DCIM/Pictures etc.)
- Images/Videos/Screenshots now use a disk cache: categories appear instantly on launch without re-scanning the media library every time (fixes ~1-minute wait on large-storage devices with many files)
- Category counts are now accurate immediately after cache restore, no longer showing stale numbers from the previous launch
- Audio loading is now exclusive-first: audio loads before video/images, preventing media-library contention on large devices from wiping audio to zero
- Audio index cache now uses atomic writes + isolated-thread decoding: a killed-mid-write won't corrupt the cache, and the main thread no longer stutters or OOMs on huge caches
- Audio load retries now keep the largest result set, preventing a partial result from overwriting already-shown content

### 🐛 Bug Fixes

- Fixed MIUI storage permission false positive causing startup popup loop
- Fixed category page long-press drag accidentally triggering page switch
- Fixed screenshots disappearing after drilling into folder in Images category
- Fixed large-storage devices (e.g. 512 GB, tens of thousands of media files) where the audio category was emptied after launch and disappeared once video/image loading finished
- Fixed release build compile errors (SongModel.getMap usage, VideoController has no dispose())

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
