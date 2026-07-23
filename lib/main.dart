import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:media_kit/media_kit.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'core/theme.dart';
import 'core/icon_fonts/broken_icons.dart';
import 'core/navigator_key.dart';
import 'providers/file_manager_provider.dart';
import 'providers/media_provider.dart';
import 'services/preferences_service.dart';
import 'services/network_connections_service.dart';
import 'services/intent_handler_service.dart';
import 'services/pin_service.dart';
import 'services/recycle_bin_service.dart';
import 'services/audio_background_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'ui/screens/home_screen.dart';

final GlobalKey<_ZenFileAppState> appStateKey = GlobalKey<_ZenFileAppState>();

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 捕获 Flutter 框架错误，防止 release 模式闪退
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint('[ZenFile] Flutter error: ${details.exception}');
    };

    // MediaKit.ensureInitialized() loads libmpv.so. On armv7 devices where the
    // native library may be missing (e.g. when media_kit jars for armeabi-v7a
    // are not packaged), an uncaught error here would prevent runApp() from
    // executing, resulting in a white screen. Wrap in try-catch so the app
    // always launches; media playback will simply be unavailable if it fails.
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      debugPrint('[ZenFile] MediaKit.ensureInitialized failed: $e');
    }

    try {
      await PreferencesService.init();
    } catch (e) {
      debugPrint('[ZenFile] PreferencesService.init failed: $e');
    }

    try {
      await PinService.init();
    } catch (e) {
      debugPrint('[ZenFile] PinService.init failed: $e');
    }

    try {
      await NetworkConnectionsService.init();
    } catch (e) {
      debugPrint('[ZenFile] NetworkConnectionsService.init failed: $e');
    }

    try {
      await RecycleBinService.init();
    } catch (e) {
      debugPrint('[ZenFile] RecycleBinService.init failed: $e');
    }

    // Load custom font dynamically if configured
    try {
      final customFontPath = PreferencesService.getCustomFontPath();
      if (customFontPath != null && customFontPath.isNotEmpty) {
        final file = File(customFontPath);
        if (file.existsSync()) {
          final loader = FontLoader('CustomFont');
          final bytes = await file.readAsBytes();
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          debugPrint('Successfully loaded custom font at startup');
        }
      }
    } catch (e) {
      debugPrint('Error loading custom font at startup: $e');
    }

    // Initialize audio_service for background media notification
    // Wrapped in try-catch — app must still launch even if this fails
    try {
      await AudioService.init(
        builder: () => getAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.sequl.zenfile.audio',
          androidNotificationChannelName: 'ZenFile Audio Player',
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidShowNotificationBadge: true,
          androidStopForegroundOnPause: false,
          notificationColor: Color(0xFF6200EE),
        ),
      );
      isAudioServiceInitialized = true;
    } catch (e) {
      // audio_service init failed – background playback unavailable but app continues
      // 标记未初始化，后续 _enableBackgroundMode 会在诊断中检测到并提示用户
      isAudioServiceInitialized = false;
      debugPrint('[ZenFile] AudioService.init failed: $e');
    }

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => FileManagerProvider()),
          ChangeNotifierProvider(create: (_) => MediaProvider()),
        ],
        child: ZenFileApp(key: appStateKey),
      ),
    );
  }, (error, stackTrace) {
    // 捕获所有未处理的异步错误，防止 release 模式闪退
    debugPrint('[ZenFile] Unhandled async error: $error\n$stackTrace');
  });
}

const _gestureExclusionChannel = MethodChannel('com.sequl.zenfile/gesture_exclusion');

Future<void> _updateSystemGestureExclusion(bool disableLeftBack, double width, double screenHeight, double devicePixelRatio) async {
  if (!Platform.isAndroid) return;
  try {
    final List<Map<String, int>> rects = [];
    if (disableLeftBack) {
      // Android enforces a strict vertical limit of 200dp per edge for gesture exclusions.
      // We center a 200dp zone along the left edge of the screen.
      const double exclusionHeight = 200.0;
      final double topDp = (screenHeight - exclusionHeight) / 2.0;

      final left = 0;
      final top = (topDp * devicePixelRatio).toInt();
      final right = (width * devicePixelRatio).toInt();
      final bottom = ((topDp + exclusionHeight) * devicePixelRatio).toInt();
      rects.add({
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      });
    }
    await _gestureExclusionChannel.invokeMethod('setSystemGestureExclusionRects', {
      'rects': rects,
    });
  } catch (e) {
    debugPrint('Failed to set system gesture exclusion: $e');
  }
}

class ZenFileApp extends StatefulWidget {
  const ZenFileApp({super.key});

  @override
  State<ZenFileApp> createState() => _ZenFileAppState();
}

class _ZenFileAppState extends State<ZenFileApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en', 'US');
  bool? _hasPermission;
  bool _isPermanentlyDenied = false;
  bool _isMediaOnlyPermission = false;
  bool _sharingObserverSetup = false;
  bool _isResolvingIntent = false;
  // 首次启动标志：未选择语言时为 true，用于延迟权限申请直到语言选择完成
  bool _isFirstLaunch = false;
  StreamSubscription<List<SharedMediaFile>>? _sharingIntentSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final hideNav = PreferencesService.getHideNavigationBar();
    if (hideNav) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    SystemChrome.setSystemUIChangeCallback((bool visible) async {
      if (visible) {
        if (PreferencesService.getHideNavigationBar()) {
          await Future.delayed(const Duration(milliseconds: 1500));
          if (PreferencesService.getHideNavigationBar()) {
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
          }
        }
      }
    });
    _themeMode = PreferencesService.getThemeMode();
    final savedLocale = PreferencesService.getAppLocale();
    _locale = _localeFromCode(savedLocale);
    _initializeApplication();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 首次启动（语言选择流程中）不触发权限检查，避免与语言选择器冲突
    if (state == AppLifecycleState.resumed && _hasPermission != true && !_isFirstLaunch) {
      _checkStoragePermission();
    }
  }

  @override
  void dispose() {
    _cancelAutoCleanTimer();
    WidgetsBinding.instance.removeObserver(this);
    _sharingIntentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeApplication() async {
    // 检查是否为首次启动（未选择语言）
    _isFirstLaunch = !PreferencesService.hasSelectedLanguage();

    if (_isFirstLaunch) {
      // 首次启动：保持 _hasPermission = null，让 build 显示空白 Scaffold。
      // 不设置 _hasPermission = true，避免 HomeScreen 被创建并触发
      // refreshMediaBackground() 在无权限时访问文件系统导致闪退。
      // 与 NFile 原项目逻辑一致：权限检查是异步的，在此之前不显示任何功能页面。
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showFirstTimeLanguagePicker();
        });
      }
      return;
    }

    // 非首次启动：正常检查权限
    await _checkStoragePermission();
    // Only run cache cleanup and intent observer after permission is granted
    if (_hasPermission == true) {
      _migrateOldCacheDir();
      _startAutoCleanTimer();
      _setupSharingIntentObserver();
    }
  }

  /// 迁移旧的 Download/ZenFile_Remote 缓存目录到新的 /ZenFile 目录。
  /// 旧目录已废弃，缓存文件不需要保留，直接删除旧目录。
  void _migrateOldCacheDir() {
    try {
      final oldDir = Directory('/storage/emulated/0/Download/ZenFile_Remote');
      if (oldDir.existsSync()) {
        oldDir.deleteSync(recursive: true);
        debugPrint('[ZenFile] 已移除旧的 Download/ZenFile_Remote 缓存目录');
      }
    } catch (e) {
      debugPrint('[ZenFile] 移除旧缓存目录失败: $e');
    }
  }

  void _showFirstTimeLanguagePicker() {
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    String selectedLocale = 'zh';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Column(
                children: [
                  Text(
                    L10n.of(ctx).ui_select_language_title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Select Language / 选择语言',
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        L10n.of(ctx).ui_select_language_desc,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                      const SizedBox(height: 20),
                      _buildLanguageOption(ctx, 'zh', '简体中文', 'Simplified Chinese', selectedLocale == 'zh', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'en', 'English', 'English', selectedLocale == 'en', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'zh_TW', '繁體中文', 'Traditional Chinese', selectedLocale == 'zh_TW', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'ja', '日本語', 'Japanese', selectedLocale == 'ja', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'ko', '한국어', 'Korean', selectedLocale == 'ko', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'de', 'Deutsch', 'German', selectedLocale == 'de', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'fr', 'Français', 'French', selectedLocale == 'fr', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'es', 'Español', 'Spanish', selectedLocale == 'es', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'ru', 'Русский', 'Russian', selectedLocale == 'ru', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                      const SizedBox(height: 12),
                      _buildLanguageOption(ctx, 'ar', 'العربية', 'Arabic', selectedLocale == 'ar', (val) {
                        setDialogState(() => selectedLocale = val);
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    PreferencesService.saveAppLocale(selectedLocale);
                    PreferencesService.setHasSelectedLanguage(true);
                    Navigator.of(ctx).pop();
                    if (mounted) {
                      setState(() {
                        _locale = _localeFromCode(selectedLocale);
                        _isFirstLaunch = false;
                      });
                      // 语言选择完成后，检查并申请存储权限
                      // 应用已完全启动到首页，此时询问权限不会导致闪退
                      _checkPermissionAfterLanguageSelection();
                    }
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('确定 / Confirm', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 语言选择完成后，检查并申请存储权限。
  /// 此方法在应用完全启动到首页后被调用，避免启动过程中权限弹窗导致闪退。
  Future<void> _checkPermissionAfterLanguageSelection() async {
    // 先标记 _isFirstLaunch = false，让 didChangeAppLifecycleState 能正常工作
    _isFirstLaunch = false;

    // 检查权限
    await _checkStoragePermission();

    // 如果检测到有权限，可能是清除数据后权限状态不一致（系统显示有权限但实际无权限）。
    // 调用 request() 重新确认权限，确保权限真正生效。
    if (_hasPermission == true) {
      try {
        // 重新请求权限以激活它（如果已授予，request() 会立即返回 granted）
        final status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          // request() 返回未授予，说明权限实际未生效
          if (mounted) {
            setState(() {
              _hasPermission = false;
              _isPermanentlyDenied = status.isPermanentlyDenied;
            });
          }
          return;
        }
      } catch (e) {
        debugPrint('[ZenFile] Permission re-confirm failed: $e');
      }

      _migrateOldCacheDir();
      _startAutoCleanTimer();
      _setupSharingIntentObserver();
      _loadMediaAfterPermission();
    }
    // 无权限时：_hasPermission = false 会触发 build 方法显示 _StoragePermissionShield 页面，
    // 由用户主动点击按钮来请求权限（与原项目 NFile 的交互方式一致）。
  }

  /// 在获得完整权限后加载媒体数据。
  void _loadMediaAfterPermission() {
    try {
      final context = navigatorKey.currentContext;
      if (context != null && context.mounted) {
        context.read<MediaProvider>().loadMedia();
      }
    } catch (_) {}
  }

  Widget _buildLanguageOption(BuildContext ctx, String locale, String label, String subtitle, bool isSelected, ValueChanged<String> onTap) {
    final theme = Theme.of(ctx);
    return InkWell(
      onTap: () => onTap(locale),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary.withOpacity(0.1) : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkStoragePermission() async {
    if (Platform.isAndroid) {
      bool manageStorageGranted = false;
      bool mediaOnlyPermission = false;
      try {
        // 与 NFile 原项目一致：使用 permission_handler 检查权限
        manageStorageGranted = await Permission.manageExternalStorage.isGranted;

        // 检查媒体权限
        final standardStorageGranted = await Permission.storage.isGranted;
        bool audioGranted = true;
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          final sdk = info.version.sdkInt;
          if (sdk >= 33) {
            audioGranted = await Permission.audio.isGranted;
          }
        } catch (_) {}

        mediaOnlyPermission = !manageStorageGranted && (standardStorageGranted && audioGranted);
      } catch (e) {
        debugPrint('[ZenFile] Permission check failed: $e');
        manageStorageGranted = false;
        mediaOnlyPermission = false;
      }

      // 与 NFile 原项目一致：manageExternalStorage 或 媒体权限 都可以进入首页
      final hasPermission = manageStorageGranted || mediaOnlyPermission;

      final wasPermissionDenied = _hasPermission == false || _hasPermission == null;

      if (mounted) {
        setState(() {
          _hasPermission = hasPermission;
          _isMediaOnlyPermission = mediaOnlyPermission && !manageStorageGranted;
        });
      }

      if (wasPermissionDenied && hasPermission) {
        if (manageStorageGranted) {
          _migrateOldCacheDir();
          _startAutoCleanTimer();
        }
        _setupSharingIntentObserver();
        _loadMediaAfterPermission();
      }
    } else {
      if (mounted) {
        setState(() => _hasPermission = true);
      }
    }
  }

  Future<void> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      try {
        // 与 NFile 原项目一致：使用 permission_handler 的 request() 方法
        final manageStorageGranted = await Permission.manageExternalStorage.request().isGranted;
        bool standardStorageGranted = false;
        bool audioGranted = true;
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          final sdk = info.version.sdkInt;
          if (sdk >= 33) {
            audioGranted = await Permission.audio.request().isGranted;
          } else {
            standardStorageGranted = await Permission.storage.request().isGranted;
          }
        } catch (_) {}

        final mediaOnlyPermission = !manageStorageGranted && (standardStorageGranted && audioGranted);
        final hasPermission = manageStorageGranted || mediaOnlyPermission;

        if (mounted) {
          setState(() {
            _hasPermission = hasPermission;
            _isMediaOnlyPermission = mediaOnlyPermission && !manageStorageGranted;
            if (!hasPermission) {
              _isPermanentlyDenied = true;
            }
          });
        }

        if (hasPermission) {
          if (manageStorageGranted) {
            _migrateOldCacheDir();
            _startAutoCleanTimer();
          }
          _setupSharingIntentObserver();
          _loadMediaAfterPermission();
        }
      } catch (e) {
        debugPrint('[ZenFile] Permission request failed: $e');
        if (mounted) {
          setState(() {
            _hasPermission = false;
            _isPermanentlyDenied = true;
            _isMediaOnlyPermission = false;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() => _hasPermission = true);
      }
    }
  }

  /// 打开系统的「所有文件访问权限」设置页面。
  /// 使用 ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION intent 直接跳转到特定页面，
  /// 而不是通用的应用设置页面。
  Future<void> _openManageExternalStorageSettings() async {
    try {
      const channel = MethodChannel('com.sequl.zenfile/permissions');
      await channel.invokeMethod('openManageExternalStorageSettings');
    } catch (_) {
      await openAppSettings();
    }
  }

  void _setupSharingIntentObserver() {
    if (_sharingObserverSetup) return;
    _sharingObserverSetup = true;
    _sharingIntentSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> incomingFiles) {
        if (incomingFiles.isNotEmpty) {
          _dispatchExternalMediaOpen(incomingFiles.first.path);
        }
      },
      onError: (_) {},
    );

    ReceiveSharingIntent.instance.getInitialMedia().then(
      (List<SharedMediaFile> initialFiles) {
        if (initialFiles.isNotEmpty) {
          setState(() {
            _isResolvingIntent = true;
          });
          _dispatchExternalMediaOpen(initialFiles.first.path);
          ReceiveSharingIntent.instance.reset();
        }
      },
      onError: (_) {},
    );
  }

  void _dispatchExternalMediaOpen(String absoluteFilePath) {
    if (absoluteFilePath.isEmpty) {
      if (mounted && _isResolvingIntent) {
        setState(() => _isResolvingIntent = false);
      }
      return;
    }

    // Guard: don't attempt to open files before storage permission is confirmed
    if (_hasPermission != true) {
      debugPrint('[ZenFile] Skipping external media open: no storage permission');
      if (mounted) {
        setState(() => _isResolvingIntent = false);
      }
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final primaryContext = navigatorKey.currentContext;
      if (primaryContext != null && primaryContext.mounted) {
        try {
          await IntentHandlerService.handleIncomingIntent(primaryContext, absoluteFilePath);
        } finally {
          if (mounted) {
            setState(() {
              _isResolvingIntent = false;
            });
          }
        }
      } else {
        Future.delayed(const Duration(milliseconds: 300), () async {
          final fallbackContext = navigatorKey.currentContext;
          if (fallbackContext != null && fallbackContext.mounted) {
            try {
              await IntentHandlerService.handleIncomingIntent(fallbackContext, absoluteFilePath);
            } finally {
              if (mounted) {
                setState(() {
                  _isResolvingIntent = false;
                });
              }
            }
          } else {
            if (mounted) {
              setState(() {
                _isResolvingIntent = false;
              });
            }
          }
        });
      }
    });
  }

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
    PreferencesService.saveThemeMode(_themeMode);
  }

  Locale _getLocale() => _locale;


  Locale _localeFromCode(String code) {
    switch (code) {
      case 'en': return const Locale('en', 'US');
      case 'zh_TW': return const Locale('zh', 'TW');
      case 'ja': return const Locale('ja', 'JP');
      case 'ko': return const Locale('ko', 'KR');
      case 'de': return const Locale('de', 'DE');
      case 'fr': return const Locale('fr', 'FR');
      case 'es': return const Locale('es', 'ES');
      case 'ru': return const Locale('ru', 'RU');
      case 'ar': return const Locale('ar', 'SA');
      default: return const Locale('zh', 'CN');
    }
  }

  void setLocale(String localeCode) {
    setState(() {
      _locale = _localeFromCode(localeCode);
    });
    PreferencesService.saveAppLocale(localeCode);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FileManagerProvider>(
      builder: (context, fileManager, _) {
        final currentAccentOption = fileManager.accentColorOption;
        final baseSeedColor = PreferencesService.getSeedColor(currentAccentOption);

        return DynamicColorBuilder(
          builder: (ColorScheme? dynamicLight, ColorScheme? dynamicDark) {
            final activeLightScheme = currentAccentOption == 'dynamic' ? dynamicLight : null;
            final activeDarkScheme = currentAccentOption == 'dynamic' ? dynamicDark : null;

            return MaterialApp(
              navigatorKey: navigatorKey,
              title: 'ZenFile',
              debugShowCheckedModeBanner: false,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                L10n.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: L10n.supportedLocales,
              locale: _getLocale(),
              localeResolutionCallback: (locale, supportedLocales) {
                if (locale == null) return const Locale('en', 'US');
                // 优先精确匹配 languageCode + countryCode（如 zh_TW）
                for (final supported in supportedLocales) {
                  if (supported.languageCode == locale.languageCode &&
                      supported.countryCode == locale.countryCode) {
                    return supported;
                  }
                }
                // 回退：仅匹配 languageCode
                for (final supported in supportedLocales) {
                  if (supported.languageCode == locale.languageCode) {
                    return supported;
                  }
                }
                return const Locale('en', 'US');
              },
              theme: AppTheme.getAppTheme(light: true, seed: baseSeedColor, customScheme: activeLightScheme, fontFamily: fileManager.fontFamilyOption),
              darkTheme: AppTheme.getAppTheme(light: false, pitchBlack: fileManager.amoledMode, seed: baseSeedColor, customScheme: activeDarkScheme, fontFamily: fileManager.fontFamilyOption),
              themeMode: _themeMode,
              builder: (context, child) {
                final isDark = _themeMode == ThemeMode.system
                    ? (MediaQuery.platformBrightnessOf(context) == Brightness.dark)
                    : (_themeMode == ThemeMode.dark);
                
                final theme = isDark
                    ? AppTheme.getAppTheme(light: false, pitchBlack: fileManager.amoledMode, seed: baseSeedColor, customScheme: activeDarkScheme, fontFamily: fileManager.fontFamilyOption)
                    : AppTheme.getAppTheme(light: true, seed: baseSeedColor, customScheme: activeLightScheme, fontFamily: fileManager.fontFamilyOption);

                final navBarColor = theme.scaffoldBackgroundColor;

                final style = SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
                  statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
                  systemNavigationBarColor: navBarColor,
                  systemNavigationBarDividerColor: Colors.transparent,
                  systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
                  systemNavigationBarContrastEnforced: false,
                  systemStatusBarContrastEnforced: false,
                );

                SystemChrome.setSystemUIOverlayStyle(style);

                if (fileManager.hideNavigationBar) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
                } else {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
                }

                final disableLeftBack = fileManager.disableLeftBackGesture;
                final size = MediaQuery.of(context).size;
                final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _updateSystemGestureExclusion(disableLeftBack, 40.0, size.height, devicePixelRatio);
                });

                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: style,
                  child: child!,
                );
              },
              home: _isResolvingIntent
                  ? const _IntentLoadingScreen()
                  : (_hasPermission == null
                      ? const Scaffold()
                      : (_hasPermission == true
                          ? HomeScreen(toggleTheme: _toggleTheme)
                          : _StoragePermissionShield(
                              onRequestPermission: _requestStoragePermission,
                              onOpenSettings: _openManageExternalStorageSettings,
                              isPermanentlyDenied: _isPermanentlyDenied,
                              isMediaOnly: _isMediaOnlyPermission,
                            ))),
            );
          },
        );
      },
    );
  }
}

class _IntentLoadingScreen extends StatelessWidget {
  const _IntentLoadingScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0D0D1A) : const Color(0xFFF9F9FF),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Broken.document,
                size: 48,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 48,
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
                color: theme.colorScheme.primary,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              L10n.of(context).msg6f3e533a,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L10n.of(context).msgbca59325,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoragePermissionShield extends StatelessWidget {
  final VoidCallback onRequestPermission;
  final VoidCallback onOpenSettings;
  final bool isPermanentlyDenied;
  final bool isMediaOnly;

  const _StoragePermissionShield({
    required this.onRequestPermission,
    required this.onOpenSettings,
    required this.isPermanentlyDenied,
    this.isMediaOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isMediaOnly ? Broken.document_sketch : Broken.folder_cross,
                    size: 72,
                    color: isMediaOnly
                        ? Theme.of(context).colorScheme.primary.withOpacity(0.8)
                        : Theme.of(context).colorScheme.error.withOpacity(0.8),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    isMediaOnly
                        ? L10n.of(context).msg_media_only_permission_title
                        : L10n.of(context).msga1b2c3d6,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isMediaOnly
                        ? L10n.of(context).msg_media_only_permission_desc
                        : (isPermanentlyDenied
                            ? L10n.of(context).ui_open_settings_desc
                            : L10n.of(context).zenfile),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  if (isPermanentlyDenied || isMediaOnly) ...[
                    FilledButton.icon(
                      onPressed: onOpenSettings,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: const Icon(Broken.setting),
                      label: Text(L10n.of(context).msg_grant_full_storage_permission,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: onRequestPermission,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: const Icon(Broken.shield_tick),
                      label: Text(L10n.of(context).msga1b2c3d7,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: onOpenSettings,
                      icon: const Icon(Broken.setting, size: 18),
                      label: Text(L10n.of(context).ui_open_settings),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自动清理缓存的定时器（顶层变量）
Timer? _autoCleanTimer;

/// 启动自动清理缓存的定时器
void startAutoCleanTimer() {
  _autoCleanTimer?.cancel();
  final autoCleanMinutes = PreferencesService.getRemoteCacheAutoCleanMinutes();
  if (autoCleanMinutes <= 0) return; // 未启用自动清理

  // 立即执行一次清理
  _autoCleanRemoteCache();

  // 启动定时器，按设定间隔周期性清理
  _autoCleanTimer = Timer.periodic(
    Duration(minutes: autoCleanMinutes),
    (_) => _autoCleanRemoteCache(),
  );
}

/// 内部启动函数（权限通过后调用）
void _startAutoCleanTimer() => startAutoCleanTimer();

/// 取消自动清理定时器
void _cancelAutoCleanTimer() {
  _autoCleanTimer?.cancel();
  _autoCleanTimer = null;
}

/// 自动清理过期缓存
void _autoCleanRemoteCache() {
  try {
    final autoCleanMinutes = PreferencesService.getRemoteCacheAutoCleanMinutes();
    if (autoCleanMinutes <= 0) return; // 未启用自动清理

    // Restrict cleanup to the cache/ subtree to avoid deleting user
    // settings/APK backups that live alongside the cache.
    final baseDir = Directory('/storage/emulated/0/ZenFile');
    if (!baseDir.existsSync()) return;

    final now = DateTime.now();
    final threshold = now.subtract(Duration(minutes: autoCleanMinutes));

    // 遍历缓存目录，删除过期文件
    int deletedCount = 0;
    int deletedSize = 0;

    void cleanDirectory(Directory dir) {
      try {
        for (final entity in dir.listSync()) {
          if (entity is File) {
            final stat = entity.statSync();
            if (stat.modified.isBefore(threshold)) {
              deletedSize += entity.lengthSync();
              entity.deleteSync();
              deletedCount++;
            }
          } else if (entity is Directory) {
            // 递归清理子目录
            cleanDirectory(entity);
          }
        }
      } catch (e) {
        debugPrint('清理缓存目录失败: {e}');
      }
    }

    final cacheRoot = Directory('${baseDir.path}/cache');
    if (cacheRoot.existsSync()) {
      cleanDirectory(cacheRoot);
    }

    if (deletedCount > 0) {
      debugPrint('自动清理缓存: 删除 $deletedCount 个文件，释放 ${(deletedSize / 1024 / 1024).toStringAsFixed(1)} MB');
    }
    // 记录本次清理时间
    PreferencesService.saveRemoteCacheLastCleanTime(now.millisecondsSinceEpoch);
  } catch (e) {
    debugPrint('自动清理缓存失败: $e');
  }
}
