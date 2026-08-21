[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter to deliver ultimate performance and stunning glassmorphism aesthetics.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.32

### ✨ New Features

- **Wake on LAN (WOL)**: New entry in Drawer → Tools. Add/Edit/Delete devices (name, MAC address, broadcast address, port), send magic packets to wake devices on LAN. Device list persisted locally. Full 10-language localization.
- **Image Editor**: Built-in image editor with crop (free/ratio presets/ID photo sizes), rotate, flip, filters (grayscale/sepia/invert/contrast/brightness/saturation), and metadata viewer. Pure Dart implementation using `image` package — no native dependencies.
- **One-tap Metadata Removal**: New "Remove Metadata" option in image viewer 3-dot menu. Re-encodes image stripping EXIF/GPS/ICC metadata, saves as new file.
- **Immersive Info Bar**: Image viewer shows filename·dimensions·size·format on touch; Properties dialog adds Dimensions row.

### 🐛 Bug Fixes

- Fixed Select All button in category page cross-selecting files from other folders when browsing by folder: Images/Videos/Audios/Screenshots/Documents/Archives/Downloads/APKs — 8 categories now only select files within the current folder when in folder view; Select All selects all files only in "All Items" view.
- Fixed Select All button failing to select files in the Screenshots folder (DCIM/Screenshots) when browsing by folder in the Images category.
- Fixed "Show in Location" not navigating to the browse page for images/screenshots (works for both local and remote paths).
- Fixed batch operation backup button title showing "Backing up..." (changed to "Backup", updated across all 10 languages).
- Fixed image viewer Dismissible widget missing closing bracket causing compile errors.
- Fixed Select All in category page mixing remote/local files (now filters by current scope).
- Fixed residual blank icons on category page after deleting or moving files in non-media categories (Documents/Archives/Downloads/APKs).
- Fixed residual thumbnails and unsynchronized siblingItems after deleting remote images.
- Fixed category total size flickering "shows ~1s → zeros out → reload restores" on startup.
- Fixed tab bar horizontal swipe accidentally triggering page switch (new tabBarInteracting flag).
- Fixed auto-backup toggle not taking effect (new _autoSyncTriggered guard + isLoaded check).
- Fixed backup logic errors (re-uploads missing remote files instead of discarding records).
- Fixed "Open Location" requiring manual back press to see navigation (now uses popUntil(isFirst) to navigate home directly).
- Fixed refresh button not scanning non-media files (APKs not loading), corrected category branch logic and added onlyApk parameter.
- Fixed batch backup progress dialog stuck and not dismissing (switched to rootNavigator mode + backupDialogOpen flag).

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
