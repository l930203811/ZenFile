[中文](README_zh.md) | English

# ZenFile

A beautifully crafted, open-source file manager and offline media center for Android. Built with Flutter to deliver ultimate performance and stunning glassmorphism aesthetics.
> **Note**: This project is a fork of [Senzme/NFile](https://github.com/Senzme/NFile). Thanks to the original author!

---

## 🚀 What's New in v1.1.29

### 🔧 Optimizations

- Merged the separate "Categories" and "Browse" buttons in the category/browse page navigation into a single centered toggle (shows "Browse" on the categories page, "Categories" on the browse page).
- When renaming a file, the filename body (without extension) is now auto-selected with the cursor placed before the extension, preventing accidental extension changes. Covers all entry points: 3-dot menu, long-press menu, image viewer, global search, selection mode, remote, and conflict dialog.
- Fixed preview of large archive images (>4MB) and added swipe-to-switch between images; a single failed preview no longer breaks the whole group.
- Remote media thumbnails now use concurrency throttling and unique temp filenames for more stable loading without cross-mixing.
- Hide the remote cloud badge in split-screen (dual-pane) mode for a cleaner UI.
- Swapped the icons of the "Images" and "Screenshots" categories (Images now shows a camera icon, Screenshots shows an image icon).

### 🐛 Bug Fixes

- Fixed thumbnails not refreshing for same-named files, and cross-mixing of thumbnails between remote and local same-named files.
- Fixed the issue where tapping "OK" after extracting an archive did not navigate to the extracted folder.
- Fixed the remote folder "item count" always showing 0.
- Fixed single-pane mode overwriting an already-open remote connection when opening a new one, and the remote tab title not being fixed to the connection name.
- Fixed breadcrumb horizontal swipe accidentally triggering page switching in the browse page.
- Fixed long-press dragging of category tiles accidentally triggering left/right page switching.
- Fixed screenshots disappearing after drilling into a folder under the Images category's folder view.
- Fixed archive image preview failing entirely due to name normalization mismatch, and missing feedback on extraction failure.
- Global search empty state and delete confirmation texts now support multiple languages (removed hardcoded English).

### ⚠️ Known Issues

- SMB / FTP / SFTP remote video playback may still stutter in some scenarios; optimization is ongoing.

---

## 🚀 What's New in v1.1.28

### ✨ New Features

- Quick Actions page adds a single/dual-window toggle, synced with Settings → File Browser → Split Screen.
- Sort & filter options support multi-select category filtering (images/videos/audio/docs/archives/packages/others, combinable) with a remember-filter option.
- Categories page adds a Backup/Restore shortcut, enabled by default.
- Remote files and folders now show a cloud badge; added a 'Show remote cloud badge' toggle.

### 🔧 Optimizations

- Compressing large or many files no longer crashes or freezes: streaming compress/extract with ~1MB resident memory, plus memory-threshold guard and split/merge volumes.
- Smoother remote video playback (SMB/FTP/SFTP), eliminating stuttering.
- In dual-window mode, sorting, size/spacing and category filter now apply to both panes.
- Category icons unified to the app theme color; each category shows its storage usage size.
- Global search now starts from the current folder (falls back to global search at storage root).

### 🐛 Bug Fixes

- Fixed the filter persisting after 'Remember filter' is turned off.

### ⚠️ Known Issues

- Size/spacing adjustment is not yet effective in dual-window mode; to be improved in a later release.

---

## 🚀 What's New in v1.1.27

### ✨ New Features

- Favorites: added a '+' button to manually add custom paths/names as favorites, grouped by category.
- Favorites: favorites items can now be edited (name/path/group); groups support collapse/expand with persistence.
- Favorites: all add-to-favorites entry points (three-dot menu / long-press / top '+' button) can now choose a group; long-press a group to rename/delete, long-press an item to edit/delete.

### 🔧 Optimizations

- Systematically fixed UI lag on Android 15/16 (rendering-layer Impeller fallback avoidance + IO layer + decode-layer, three-dimensional optimization).

### 🐛 Bug Fixes

- Fixed the selection mode 'Favorite' action not showing the group picker.

### ⚠️ Known Issues

- SMB / FTP / SFTP remote video playback may still stutter in some scenarios; optimization is ongoing.

---

## 🚀 What's New in v1.1.26

### 🔧 Optimizations

- SMB download acceleration: removed double-buffer prefetch and switched to single-threaded sequential read/write, greatly improving large-file transfer speed.
- Removed the backup icon set, significantly reducing the app (APK) install size.
- Polished details: the "Network" drawer list's three-dot button is now right-aligned, and quick-action page titles wrap automatically.

### 🐛 Bug Fixes

- Fixed FTP download speed being wrongly capped at 30–40 MB/s (caused by an overly small write-flush interval).
- Fixed three remote-client issues (SMB/FTP/SFTP): transfer cancellation, list stuttering, and page refresh.
- Fixed anomalies caused by leftover openlist references.

### ⚠️ Known Issues

- SMB / FTP / SFTP remote video playback may still stutter in some scenarios; optimization is ongoing.

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
