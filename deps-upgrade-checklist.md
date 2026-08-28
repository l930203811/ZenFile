# ZenFile 依赖升级裁决清单（v1.1.34+60 → 全部最新）

> 用途：对照升级依赖时逐项裁决。所有"最新版本号"必须先在**已装 Flutter 的本机**跑 `flutter pub outdated` 获取真实值，本清单只给风险分级与动作建议，不臆造版本号。
>
> 原则（来自项目约定）：不要盲目 `flutter pub upgrade --major-versions`。先处理 🔴，再 🟡，🟢 可顺带。fork/git/原生/license 类一律人工评估。

## 风险图例
- 🔴 **高危**：原生编译失败 / 包未维护可能不满足 Dart `^3.11.5` SDK 约束 → 禁止自动 bump，必须单独验证
- 🟡 **中危**：跨大版本即破坏性 API 变更 → 需读 migration guide 后人工升级
- 🟢 **低危**：可安全小版本升级（补丁/小版本），`flutter pub upgrade <pkg>` 即可

## 动作代码
- `GET` ＝ 仅 `flutter pub get` 拉兼容补丁，不改约束（最稳）
- `MIN` ＝ 安全升级到最新兼容小版本 `flutter pub upgrade <pkg>`
- `MAJ` ＝ 需评估破坏性变更后再升（读 changelog/migration）
- `HOLD` ＝ 保持当前，不要自动 bump（fork/git/原生/license/未维护）

---

## 一、主依赖

| 包 | 当前约束 | 风险 | 动作 | 备注 |
|---|---|---|---|---|
| flutter | sdk | – | GET | SDK 自身 |
| flutter_localizations | sdk | – | GET | – |
| flutter_avif | ^3.1.0 | 🔴 | HOLD | 含原生代码，升级易触发 KGP/CMake 构建失败 |
| cupertino_icons | ^1.0.8 | 🟢 | MIN | 稳定 |
| path_provider | ^2.1.3 | 🟢 | MIN | 稳定 |
| shared_preferences | ^2.2.3 | 🟢 | MIN | 稳定 |
| permission_handler | ^12.0.1 | 🟡 | MAJ | v12 大版本，跨 v13 破坏性 |
| provider | ^6.1.2 | 🟡 | MAJ | v6→v7 破坏性 |
| open_filex | ^4.4.0 | 🟡 | MAJ | v4 大版本 |
| intl | ^0.20.2 | 🟢 | MIN | 已在 0.20（0.19→0.20 已破，勿回退） |
| mime | ^2.0.0 | 🟢 | MIN | 稳定 |
| path | ^1.9.0 | 🟢 | MIN | 稳定 |
| photo_manager | ^3.3.0 | 🟡 | MAJ | v3 大版本，跨 v4 破坏性 |
| on_audio_query | git | 🟠 | HOLD | git 依赖，无固定版本；升级＝切 git ref，需验证 |
| photo_view | ^0.15.0 | 🟢 | MIN | 稳定 |
| image | ^4.0.0 | 🟢 | MIN | 纯 Dart，稳定 |
| media_kit | any | 🔴 | HOLD | 原生视频库，`any` 会随上游飘；升最新可能拉高 NDK/CMake 要求 |
| media_kit_video | any | 🔴 | HOLD | 同上（原生） |
| media_kit_libs_video | any | 🔴 | HOLD | 同上（原生，体积大、版本敏感） |
| syncfusion_flutter_pdfviewer | ^33.2.6 | 🟡 | MAJ | 大版本破坏性 + **需商业 license key** |
| flutter_svg | ^2.0.0 | 🟢 | MIN | v2 稳定，跨 v3 才破 |
| archive | ^3.6.1 | 🟢 | MIN | 稳定 |
| dart_lz4 | ^1.0.0 | 🔴 | HOLD | 疑似未维护，需验证是否满足 Dart 3.11 SDK 约束 |
| just_zstd | ^0.2.0 | 🔴 | HOLD | 年轻/小众，需验证 SDK 约束 |
| flutter_markdown | ^0.7.3 | 🟢 | MIN | 稳定 |
| flutter_widget_from_html | ^0.17.2 | 🟡 | MAJ | 偏旧 minor，跨大版本破坏性 |
| docx_to_text | ^1.0.1 | 🟢 | MIN | 稳定 |
| excel | ^4.0.6 | 🟢 | MIN | v4 稳定 |
| xml | ^6.6.1 | 🟢 | MIN | 稳定 |
| excel2003 | ^1.0.0 | 🔴 | HOLD | 长期未维护，极可能不满足 Dart `^3.11.5` → `pub get` 报错 |
| receive_sharing_intent | ^1.8.1 | 🟡 | MAJ | Android 13+ intent 变更，跨大版本破坏性 |
| dynamic_color | ^1.7.0 | 🟢 | MIN | 稳定 |
| url_launcher | ^6.2.6 | 🟢 | MIN | 稳定 |
| sqflite | ^2.4.2+1 | 🟢 | MIN | 稳定 |
| share_plus | ^12.0.2 | 🟡 | MAJ | v12 大版本（v7→v12 已多次破） |
| google_fonts | ^6.2.1 | 🟡 | MAJ | v6 大版本 |
| crypto | ^3.0.3 | 🟢 | MIN | 稳定 |
| ftpconnect | ^2.0.10 | 🟡 | MAJ | 网络库，跨大版本 socket API 变更 |
| dartssh2 | ^2.8.2 | 🟡 | MAJ | SFTP 库，跨大版本破坏性 |
| audio_service | ^0.18.17 | 🟠 | HOLD | 被本地 fork override（plugins/audio_service）锁版本修 Android 13+ 通知栏；fork 同步上游 API 后才能升 |
| device_info_plus | ^12.4.0 | 🟡 | MAJ | v12 大版本 |
| charset | ^2.0.0 | 🟢 | MIN | 稳定 |
| auto_size_text | ^3.0.0 | 🟡 | MAJ | v3 大版本 |
| exif | ^3.3.0 | 🟢 | MIN | 稳定 |

## 二、dev_dependencies
| 包 | 当前约束 | 风险 | 动作 | 备注 |
|---|---|---|---|---|
| flutter_test | sdk | – | GET | – |
| flutter_lints | ^6.0.0 | 🟢 | MIN | v6 对齐 Dart 3.x |

## 三、dependency_overrides（务必保持）
| 包 | 来源 | 动作 | 备注 |
|---|---|---|---|
| on_audio_query_platform_interface | git | HOLD | 与 on_audio_query 配对，勿单独升 |
| audio_service | path: plugins/audio_service | HOLD | 本地 fork，升级需同步 fork 内 AudioService.java |

## 四、本机执行流程（手动）
```bat
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
cd /d/Xiangmu/ZenFile-main

:: 1) 先看真实最新版本（不要猜）
flutter pub outdated

:: 2) 只拉兼容补丁（最稳，不改约束）
flutter pub get

:: 3) 对 🟢 项逐个安全升级
flutter pub upgrade cupertino_icons path_provider shared_preferences intl mime path photo_view image flutter_svg archive flutter_markdown docx_to_text excel xml dynamic_color url_launcher sqflite crypto charset exif flutter_lints

:: 4) 对 🟡/🔴 项单独评估后再决定（先改 pubspec 再 pub get）
:: 5) 最终构建
flutter build apk --release --split-per-abi
```
> 发布前铁律：Glob 确认 3 个 APK 时间戳为本次 + `aapt dump badging` 核验 `versionName`，再传 GitHub Release。

## 五、升级后若 `pub get` 失败，优先排查
1. `excel2003` / `dart_lz4` / `just_zstd` 是否满足 `sdk: ^3.11.5`（不满足→暂时 HOLD 或找替代）
2. `media_kit*` 三包 `any` 是否拉到需要新 NDK 的版本（锁具体版本号替代 `any`）
3. `audio_service` fork 与 `on_audio_query` git ref 是否仍兼容
