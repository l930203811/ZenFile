import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L10n
/// returned by `L10n.of(context)`.
///
/// Applications need to include `L10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L10n.localizationsDelegates,
///   supportedLocales: L10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L10n.supportedLocales
/// property.
abstract class L10n {
  L10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L10n of(BuildContext context) {
    return Localizations.of<L10n>(context, L10n)!;
  }

  static const LocalizationsDelegate<L10n> delegate = _L10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// main.dart
  ///
  /// In zh, this message translates to:
  /// **'正在打开共享文档...'**
  String get msg6f3e533a;

  /// main.dart
  ///
  /// In zh, this message translates to:
  /// **'正在解析安全内容流'**
  String get msgbca59325;

  /// main.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 需要存储权限才能无缝管理、组织和显示您的媒体文件。'**
  String get zenfile;

  /// main.dart
  ///
  /// In zh, this message translates to:
  /// **'清理缓存目录失败: {e}'**
  String e(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'内部存储'**
  String get msg21cefa9b;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'局域网/SMB'**
  String get smb;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'成功移动项目'**
  String get msg05d3c93c;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'传输失败：{e}'**
  String e1(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'操作已取消'**
  String get msga45bac47;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'连接远程服务器失败：{e}'**
  String e2(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'创建文件夹出错：{e}'**
  String e3(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩超出限制'**
  String get msg3df5ef6c;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'未知艺术家'**
  String get msg5e32276d;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'本地文件夹'**
  String get msg497ec49d;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'下载远程文件失败: {e}'**
  String e4(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'无法将文件夹移动到自身或相同位置'**
  String get msg6b9ca1dd;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'移动项目失败：{e}'**
  String e5(Object e);

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'无法将文件夹复制到自身或相同位置'**
  String get msg5238524c;

  /// providers\file_manager_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'复制项目失败：{e}'**
  String e6(Object e);

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩包'**
  String get msgc806d0fa;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'安装包'**
  String get msg03070d08;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'FTP共享'**
  String get ftp;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'Web共享'**
  String get web;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'设备相册（自动）'**
  String get msge86bd662;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'设备音频库（自动）'**
  String get msg16166a01;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'内部存储（扫描所有文件夹）'**
  String get msgbb34b7ec;

  /// providers\media_provider.dart
  ///
  /// In zh, this message translates to:
  /// **'设备相册（截图）'**
  String get msg26a1f2d9;

  /// services\apk_installer_service.dart
  ///
  /// In zh, this message translates to:
  /// **'正在解压安装包...'**
  String get msg39e11368;

  /// services\apk_installer_service.dart
  ///
  /// In zh, this message translates to:
  /// **'安装包中未找到可安装的APK'**
  String get apk;

  /// services\apk_installer_service.dart
  ///
  /// In zh, this message translates to:
  /// **'无法启动分包APK安装器'**
  String get apk1;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'正在压缩文件'**
  String get msg2f0138ad;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩包创建成功'**
  String get msga2292820;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'正在解压压缩包'**
  String get msg0683ca6b;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩包解压成功'**
  String get msg1f216eda;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get msg5fa802be;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'是/否'**
  String get msg8fccf382;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'解压成功，是否打开所在位置？'**
  String get msgc18fb099;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到可压缩的文件'**
  String get msg4367e85a;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'不支持的格式'**
  String get msg60a4545d;

  /// services\background_archive_service.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到压缩包文件'**
  String get msg226519e7;

  /// services\folder_share_service.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到可分享的项目。'**
  String get msg88d150c7;

  /// services\intent_handler_service.dart
  ///
  /// In zh, this message translates to:
  /// **'读取共享文件出错：{e}'**
  String e7(Object e);

  /// services\remote\lan_client.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 局域网/SMB Virtual Storage Bridge\\n'**
  String get zenfilesmbvirtualstoragebridgen;

  /// services\remote\saf_client.dart
  ///
  /// In zh, this message translates to:
  /// **'新建文件夹'**
  String get msgf3a485df;

  /// services\remote\saf_client.dart
  ///
  /// In zh, this message translates to:
  /// **'新建文件'**
  String get msge48a7157;

  /// services\settings_backup_service.dart
  ///
  /// In zh, this message translates to:
  /// **'设置已备份到 ZenFile/Backups/Settings/'**
  String get zenfilebackupssettings;

  /// services\settings_backup_service.dart
  ///
  /// In zh, this message translates to:
  /// **'请选择有效的 .json 设置备份文件'**
  String get json;

  /// services\settings_backup_service.dart
  ///
  /// In zh, this message translates to:
  /// **'设置恢复失败: {e}'**
  String e8(Object e);

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接 {url}'**
  String url(Object url);

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'关于 ZenFile'**
  String get zenfile1;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'v1.0.3 (查看)'**
  String get v103;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 是一款基于 Flutter 构建的精美、流畅、开源的文件管理器和离线媒体中心。专为极致性能、干净的毛玻璃美学和无缝用户体验而设计。'**
  String get zenfileflutter;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'极速体验'**
  String get msga12ebf50;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无状态缓存与异步扫描'**
  String get msgfccb5a01;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加密安全工作区'**
  String get msg6d8fbdac;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'支持 FTP、局域网、SFTP 和 WebDAV'**
  String get ftpsftpwebdav;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'精美界面'**
  String get msge8f352b9;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'AMOLED 纯黑 & 绚丽主题'**
  String get amoled;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在仓库中加星'**
  String get msge8069659;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加入 Telegram 频道'**
  String get telegram;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'与好友分享应用'**
  String get msg5f84adea;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'推荐 ZenFile，一款精美的离线文件管理器和媒体中心：https://github.com/l930203811/ZenFile/releases'**
  String get zenfilehttpsgithubcoml930203811zenfilereleases;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'查看 GitHub 源代码'**
  String get github;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'联系邮箱：1@sequel.dpdns.org'**
  String get sequeldpdnsorg;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'邮箱已复制到剪贴板'**
  String get msged8518d7;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'QQ 群号已复制到剪贴板'**
  String get qq;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'用心打造 ❤️ by Sequel'**
  String get bysequel;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'版权所有 © 2026 ZenFile。保留所有权利。'**
  String get zenfile2;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'您的支持是我持续更新的动力 ❤️'**
  String get msg138d3725;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'支付宝'**
  String get msgccd097a7;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'微信支付'**
  String get msgbffe28c8;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'长按图片可保存到相册，感谢您的支持！'**
  String get msg0537b04e;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下载 ZenFile v1.0.3'**
  String get zenfilev103;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'123云盘'**
  String get msg9d287020;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'115网盘'**
  String get msgb2b41b6a;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'百度网盘'**
  String get msg77ee718b;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'夸克网盘'**
  String get msgbff1432a;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'小飞机网盘'**
  String get msge03395d0;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新增 SVG 文件完整支持（缩略图预览与查看）'**
  String get svg;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新增压缩包格式颜色区分（zip/rar/7z/tar/gz 各有专属颜色）'**
  String get ziprar7ztargz;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新增远程文件先下载再播放功能'**
  String get msg09a6e11b;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'修复分类页解压后无法跳转到浏览页的问题'**
  String get msg1c3206b8;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'修复「查看缓存目录」和「解压后打开所在位置」导致页面卡死的问题'**
  String get msgb1e4da91;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'优化文件日期格式为 yyyy-MM-dd'**
  String get yyyymmdd;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'优化默认启用 24 小时制时间显示'**
  String get msg4c425252;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'路径栏全面优化（更紧凑的面包屑按钮和箭头样式）'**
  String get msg1eaf4abb;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'标签栏和路径栏整体上移，为文件列表留出更多空间'**
  String get msgd3381817;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'双窗口头部区域精简（高度缩减30%）'**
  String get msg342688b2;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'双窗口模式下远程服务器替换未激活标签页'**
  String get msg8954452f;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'返回手势优化：选中状态下返回清除选中而非退出页面'**
  String get msgac5a0315;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'双指右滑打开抽屉页，双指左滑切换分类/浏览页'**
  String get msg1904388e;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新增双指滑动开关（常规与行为设置中可关闭）'**
  String get msg2762c070;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'进度条改为圆环线条样式，中心显示百分比数字'**
  String get msg48dca69a;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程路径兼容性修复（Windows平台路径分隔符问题）'**
  String get windows;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'地址栏开关改为控制美化后的路径面包屑'**
  String get msg65eefc98;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认主页设置（可选择分类页或浏览页作为启动页）'**
  String get msg96a6856a;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'全新安装包图标（自然禅意风格）'**
  String get msg250213fd;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'圆形百分比进度条（复制/移动文件时显示）'**
  String get msg7f53e8b1;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'操作成功后自动关闭进度条，无需手动确认'**
  String get msg051469b5;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件操作菜单改为底部弹出（不再遮挡标签栏）'**
  String get msge4c4d5e2;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择模式操作栏移至屏幕底部（含已选数量指示器）'**
  String get msga33dbb51;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'修复：切换图标后点击进入应用详情'**
  String get msge6c84f11;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'修复：远程复制后切换本地页面异常'**
  String get msg46b8ca8f;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文本查看器长按菜单支持复制和全选（已汉化）'**
  String get msgb3dea5f5;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'拖放弹窗布局优化（更紧凑）'**
  String get msga4c92214;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类页图标支持圆形/方形背景切换'**
  String get msg32854144;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类图标形状设置（外观与主题中切换）'**
  String get msg3a93e257;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 首次发布'**
  String get zenfile3;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'多标签页支持'**
  String get msg47b760ed;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程服务器连接（FTP/SFTP/WebDAV/SMB）'**
  String get ftpsftpwebdavsmb;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件加密保险柜'**
  String get msg4b736dfb;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'FTP/WebDAV 服务器功能'**
  String get ftpwebdav;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义主题与外观设置'**
  String get msg03257c2d;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程服务器文件拖放操作优化'**
  String get msg5cce42e6;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义应用桌面图标功能完善'**
  String get msg074f1ce7;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程服务器文件列表中长按可能触发拖放操作弹窗（下版本修复）'**
  String get msg5c66ffab;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'如果您有任何优化建议或发现Bug，欢迎通过邮箱 1@sequel.dpdns.org 或QQ群 792408214 反馈给我们。'**
  String get bug1sequeldpdnsorgqq792408214;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'长按保存图片'**
  String get msgd054a84c;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'图片加载失败'**
  String get msgb3b83e12;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'需要存储权限才能保存图片'**
  String get msgc2790d54;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'图片已保存到相册'**
  String get msg1292d351;

  /// ui\screens\about_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'保存失败: {e}'**
  String e9(Object e);

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'没有可分享的文件'**
  String get msg7a4ee0c7;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'成功删除项目'**
  String get msg45326802;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分享出错：{e}'**
  String e10(Object e);

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get msg4fb42e6e;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已剪切到剪贴板'**
  String get msge5212c58;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'重命名'**
  String get msgc8ce4b36;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'输入新名称'**
  String get msgf139c5cf;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除文件'**
  String get msg53518c22;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无最近文件'**
  String get msg47809e5d;

  /// ui\screens\all_recent_files_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新创建或下载的文件将显示在这里。'**
  String get msg7a7e6c25;

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除所选项目'**
  String get msg765d1698;

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'项目删除成功 ✓'**
  String get msg365f2f0a;

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已成功添加 {successCount} 个项目到压缩包 ✓'**
  String successcount(Object successCount);

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已粘贴 {count} 个项目到压缩包 ✓'**
  String count(Object count);

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无法读取压缩包'**
  String get msg39cb3352;

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'解压到当前文件夹'**
  String get msg99abedc6;

  /// ui\screens\archive_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'添加文件'**
  String get msg8d0cfb58;

  /// ui\screens\audio_player\audio_artwork_widget.dart
  ///
  /// In zh, this message translates to:
  /// **'无损音频'**
  String get msg5bf1fb72;

  /// ui\screens\audio_player\audio_controls_widget.dart
  ///
  /// In zh, this message translates to:
  /// **'定时关闭'**
  String get msg47cab5ae;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'后台播放已停止'**
  String get msg50c1b248;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'后台播放已启用'**
  String get msg6d16d396;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'随机播放: 关'**
  String get msg3038d9b8;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'后台播放'**
  String get msg29eed1da;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'点击停止后台播放'**
  String get msg4aa059f7;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示带控制按钮的通知'**
  String get msg8f7f4490;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'音效与均衡器'**
  String get msgb7c87215;

  /// ui\screens\audio_player\audio_player_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'音频文件信息'**
  String get msgfc449780;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'备份与恢复'**
  String get msgb4fbc92c;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'将所有当前设置保存到 ZenFile/Backups/Settings/'**
  String get zenfilebackupssettings1;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择并恢复 JSON 备份文件中的设置'**
  String get json1;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'备份目录'**
  String get msg534c621a;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件大小'**
  String get msg396b7d3f;

  /// ui\screens\backup_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最后备份时间'**
  String get msgc047ee32;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'没有可导出的数据。'**
  String get msg917fd6ef;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'SQLite数据库阅读器'**
  String get sqlite;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'表结构'**
  String get msg03a0d224;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'SQL控制台'**
  String get sql;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'打开数据库失败'**
  String get msge2f0fe67;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'此数据库中未找到表。'**
  String get msg8bb11da4;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'搜索行...'**
  String get msg7796aa3e;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到行'**
  String get msg15f26697;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未加载结构详情。'**
  String get msg0eaa935b;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'SQL 编辑器'**
  String get sql1;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'SELECT模板'**
  String get select;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'导出结果为CSV'**
  String get csv;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'执行SELECT查询以查看结果。'**
  String get select1;

  /// ui\screens\database_reader_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'执行查询出错。'**
  String get msgd1ad9002;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已复制路径: {targetPath}'**
  String targetpath(Object targetPath);

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下一级'**
  String get msg6ed14da7;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除选中'**
  String get msgcd0b9aca;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要删除此项目吗？此操作无法撤销。'**
  String get msgee14ee27;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'\"{fileName}\" 已存在，已创建 \"{createdName}\"。'**
  String filenamecreatedname(Object createdName, Object fileName);

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'\"{folderName}\" 已存在，已创建 \"{createdName}\"。'**
  String foldernamecreatedname(Object createdName, Object folderName);

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'创建新的空白文本文档'**
  String get msgbd165c40;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新建压缩包'**
  String get msg68ac91eb;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩当前文件夹内容'**
  String get msg881f6a80;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'查看和排序选项'**
  String get msg97301f64;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'列表视图'**
  String get msg829cb1dd;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'大小和间距选项'**
  String get msg0a4ebb8d;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'图标和文件夹大小'**
  String get msg88062f93;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'大小和间距'**
  String get msga7c781f5;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'排序方式'**
  String get msga2946a1a;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'名称 (Z-A)'**
  String get za;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'大小（大）'**
  String get msg2e2a26bb;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'仅此文件夹'**
  String get msgf437ace4;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启用此文件夹的自定义排序'**
  String get msg4dfc167a;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'添加快捷方式'**
  String get msge4c84f81;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'系统根目录'**
  String get msgd730e478;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'网络连接'**
  String get msg35546526;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'添加网络连接'**
  String get msg67a6ea5e;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'移除连接'**
  String get msgcc51d6c2;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'首页分类'**
  String get msg6e0f9cef;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'空文件夹'**
  String get msge9691076;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'此目录不包含任何文件或子文件夹。'**
  String get msg551f98ba;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'取消操作'**
  String get msg17093362;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'全局搜索'**
  String get msg681c0f39;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'仅文档'**
  String get msg0c36f64f;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'仅音频'**
  String get msg26b041dd;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'仅压缩包'**
  String get msge632ba85;

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'{label} 筛选已激活'**
  String label(Object label);

  /// ui\screens\directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏文件夹'**
  String get msg0e77af8a;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加载出错：{e}'**
  String e11(Object e);

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'（空白幻灯片）'**
  String get msg5937f822;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'保存成功 ✓'**
  String get msg360d0b37;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'PDF显示设置'**
  String get pdf;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'优化大型、设计复杂或扫描文档的渲染性能。'**
  String get msg09c933bf;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'标准模式'**
  String get msg701a85d4;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最适合文本文档'**
  String get msg2722d1a7;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'适合宣传册和照片'**
  String get msgb2b08d54;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'页面布局'**
  String get msg8b519c02;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'连续（垂直滚动列表）'**
  String get msg7f2cd152;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'滚动方向'**
  String get msg151ea324;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'垂直（从上到下滚动）'**
  String get msg7d45ded6;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启用文本选择'**
  String get msg176ef589;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'关闭可显著提升页面渲染速度并消除滚动卡顿。'**
  String get msg864f8706;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新建文档'**
  String get msgd28847a2;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'更多选项'**
  String get msg3007c452;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自动换行'**
  String get msg452dba7c;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示行号'**
  String get msgc31f9440;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'用其他应用打开'**
  String get msg1d93c30b;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'（空文件）'**
  String get msgace80573;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'用应用打开'**
  String get msg030f48bd;

  /// ui\screens\document_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分享功能即将推出'**
  String get msgfd96af00;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'FTP服务器已成功停止'**
  String get ftp1;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启动FTP服务器出错：{e}'**
  String ftpe(Object e);

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请在更改配置前停止服务器'**
  String get msg5c202e56;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'更改端口'**
  String get msgfca29cb3;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无效的端口号'**
  String get msg8a0b5bf5;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'设置用户名'**
  String get msg3bce2199;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'用户名不能为空'**
  String get msg0b62b5ce;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'FTP 服务器'**
  String get ftp2;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'编辑设置前请先停止服务器'**
  String get msg5ab96a6d;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'更改目录'**
  String get msgc400f106;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'设置用户'**
  String get msgb5eb59fc;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'匿名访问'**
  String get msg70c53afb;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'创建快捷方式'**
  String get msg8e2021aa;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未激活'**
  String get msgd70e9bdf;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'网络状态'**
  String get msg7ae644e4;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get msg5d57821d;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'主目录'**
  String get msgfefea1b3;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示隐藏文件'**
  String get msg124d9054;

  /// ui\screens\ftp_server_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'基于显式 TLS 的安全 FTP 连接'**
  String get tlsftp;

  /// ui\screens\global_search_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get msg1f4c1042;

  /// ui\screens\global_search_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在此文件夹中搜索...'**
  String get msgf2ef53c0;

  /// ui\screens\global_search_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get msgfff96ede;

  /// ui\screens\global_search_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'搜索您的存储'**
  String get msg88e45bb8;

  /// ui\screens\global_search_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配 \"{_query}\" 的内容'**
  String query(Object _query);

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'仪表盘刷新成功'**
  String get msge109d1ea;

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'再按一次退出应用'**
  String get msg05cea075;

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'退出应用'**
  String get msg7498c202;

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要退出吗？再次按返回键或点击退出以关闭应用。'**
  String get msg03247b17;

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'刷新仪表盘'**
  String get msg354c1c9a;

  /// ui\screens\home_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义快捷分类'**
  String get msg19021d08;

  /// ui\screens\html_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'HTML 预览'**
  String get html;

  /// ui\screens\internal_file_picker_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'输入文件夹名称'**
  String get msgfba1f416;

  /// ui\screens\internal_file_picker_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择并固定文件夹'**
  String get msg33b0b21c;

  /// ui\screens\internal_file_picker_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'清除选择'**
  String get msgff3200cc;

  /// ui\screens\internal_file_picker_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹为空'**
  String get msg4614630a;

  /// ui\screens\internal_file_picker_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'固定此文件夹'**
  String get msg5dc1fa7b;

  /// ui\screens\markdown_viewer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'Markdown 预览'**
  String get markdown;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要永久删除选中的 {count} 个项目吗？'**
  String count1(Object count);

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已成功删除 {count} 个项目'**
  String count2(Object count);

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已粘贴 {pastedCount} 个项目到 {destDir}'**
  String pastedcountdestdir(Object destDir, Object pastedCount);

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'没有可分享的文件。'**
  String get msgfadbb0bc;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到可重命名的物理文件'**
  String get msg3ad97542;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'修改时间'**
  String get msg1303e638;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'媒体信息'**
  String get msg5bab3781;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已选择项目'**
  String get msg880a18f3;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'总大小'**
  String get msgea9ecb93;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'长按打开方式...'**
  String get msg5556baa3;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get msg631cd220;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已删除 {name}'**
  String name(Object name);

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在位置中显示'**
  String get msgcd8264f1;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'打开方式...'**
  String get msg2a4cfb07;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件未找到或不可分享。'**
  String get msg8bf52387;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'粘贴到此处'**
  String get msg419be096;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最新优先'**
  String get msg5093bc80;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'按日期'**
  String get msgbc74b5a8;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最新优先（按月分组）'**
  String get msgef7ae768;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最旧优先（按月分组）'**
  String get msgb8140039;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'未知日期'**
  String get msg424a0110;

  /// ui\screens\media_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'全部项目'**
  String get msgb19671d6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'日期和时间'**
  String get msg11fea612;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件大小 / 项目数'**
  String get msg12e86877;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无 / 隐藏信息'**
  String get msg7908038f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'不在右侧显示额外信息'**
  String get msg9136d4dc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示最后修改日期和时间'**
  String get msg84986f91;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件显示大小，文件夹显示项目数'**
  String get msgfc000737;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择尾部信息样式'**
  String get msg83de16cc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择当三点操作按钮隐藏时，文件和文件夹右侧显示的内容。'**
  String get msgaa2a18a1;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示地址栏'**
  String get msg26e4c5d6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在文件列表顶部显示可编辑的Windows资源管理器风格地址栏'**
  String get windows1;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'直接以文件夹（相册）首选视图打开图片/视频快捷分类'**
  String get msg74e86197;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏安卓导航栏'**
  String get msga1fbf3c6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏底部导航栏以最大化屏幕空间（上滑可显示）'**
  String get msg02dddc02;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'清除所有已记住的\"打开方式\"关联'**
  String get msg50923c95;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'跳过\"打开方式\"对话框'**
  String get msg6fdc09ac;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'绕过应用选择对话框，直接使用默认查看器打开文件'**
  String get msg0a4b0442;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择启动时进入分类页或浏览页'**
  String get msge1157984;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择单指或双指左右滑动切换页面'**
  String get msgae1854a2;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在浏览页底部启用快速创建（+）按钮'**
  String get msg11b1ec65;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示以点(.)开头的系统文件和文件夹'**
  String get msg7e7765b6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示文件夹和文件计数标题'**
  String get msg86f3d70f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在存储标题栏下显示文件夹和文件总数'**
  String get msg40e9c325;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在列表中切换12小时（AM/PM）和24小时时间格式'**
  String get ampm24;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在列表中隐藏时间和日期'**
  String get msg25ee6612;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'完全隐藏文件和文件夹的修改日期和时间'**
  String get msg337359a6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'计算并显示目录中的文件和文件夹总数'**
  String get msga517863e;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'计算并显示目录中所有文件的总大小（可能影响列表性能）'**
  String get msg59a24fcb;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在浏览页启用底部操作栏'**
  String get msg309e2a28;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在浏览和媒体页面的选择操作栏中仅显示图标'**
  String get msg9b7639ac;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'返回时短暂闪烁并滚动到刚退出的文件夹'**
  String get msgdd69671b;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示实际的图片和视频缩略图而非通用文件图标'**
  String get msg57736228;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'允许文件名换行显示3行而非截断'**
  String get msg1eda8a50;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏文件夹和文件旁边的三点菜单按钮'**
  String get msgc7196afd;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'长按并拖动文件夹或文件将其移动到其他文件夹'**
  String get msgad54815d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'拖放文件时显示选项弹窗（复制、移动、压缩）'**
  String get msg5dff8f2d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'允许在单独的标签页中打开多个文件夹以便快速导航'**
  String get msg4b0a7063;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'并排浏览两个目录并轻松传输文件'**
  String get msgf04ac00d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启动应用时打开上次浏览的文件夹'**
  String get msgd1591ba4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'将删除的文件和文件夹移至隐藏的回收站而非永久删除'**
  String get msg25792550;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'主题色 / 动态主题'**
  String get msg1b9633fe;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹图标样式'**
  String get msg64db4c2d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用抽屉按钮样式'**
  String get msgece44aa5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'AMOLED 纯黑模式'**
  String get amoled1;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在深色模式下为AMOLED屏幕使用纯黑背景'**
  String get amoled2;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用排版 / 字体'**
  String get msg5228b59f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义快捷方式'**
  String get msge7d18d73;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'重新排列和切换快捷分类项目的可见性'**
  String get msg036fe6a4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'搜索设置...'**
  String get msgead3e5c5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'设置分类'**
  String get msg2590095f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'常规与行为'**
  String get msgfdae44c3;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认屏幕、导航控制和快捷方式'**
  String get msgeae34685;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'主题、应用图标、文件夹样式和排版'**
  String get msg91b228b8;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件浏览器选项'**
  String get msgad6e8bb8;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'地址栏、隐藏文件、标签页和拖放'**
  String get msg8ddc4963;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹大小、计数和时间/日期格式'**
  String get msg45db4e2a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认相册视图和缩略图预览'**
  String get msg09ca4d86;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'打开操作和默认查看器配置'**
  String get msgeb3693fb;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'回收站开关和自动删除时长'**
  String get msg3a6a39ae;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'备份或恢复所有应用设置'**
  String get msg9edfaff3;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'尝试搜索其他关键词'**
  String get msg99c9cc56;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认主页'**
  String get msga432d127;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类页'**
  String get msg226fc6ae;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'滑动切换页面'**
  String get msgd48a082d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'单指滑动'**
  String get msgaac01f32;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'记住上次打开的文件夹'**
  String get msg59c7debc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏底部栏（首页/浏览）的文字标签，更简洁紧凑'**
  String get msgce732d8a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件浏览器与导航'**
  String get msg1cfeaace;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'高亮退出文件夹'**
  String get msgd33e3082;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'媒体与默认操作'**
  String get msga4333788;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认相册首选视图'**
  String get msg20c87c8e;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'所有默认查看器选择已重置'**
  String get msg72b1f919;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启用回收站'**
  String get msge99f4762;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'浏览页'**
  String get msg2c8a394a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类图标形状'**
  String get msg2c3c5a35;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'每3天'**
  String get msg267fcd86;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'每两周'**
  String get msg9104c0c5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'每{days}天'**
  String days(Object days);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程服务器缓存已清除'**
  String get msg673ad9d4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自动清理缓存'**
  String get msgd9f142c4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'立即清除网络服务器下载的缓存文件'**
  String get msg5472ef41;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'浏览远程服务器缓存文件所在目录'**
  String get msgac7687d9;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'为网络服务器上的图片和视频显示缩略图预览'**
  String get msg225f6249;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'Material You（动态壁纸取色）'**
  String get materialyou;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'活力橙'**
  String get msg05cff3ad;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'皇家紫'**
  String get msg5ed35657;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'琥珀金'**
  String get msge74a7283;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'赛博粉'**
  String get msg3904ba87;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'蓝宝石'**
  String get msgd58d230a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'森林绿'**
  String get msg508b005e;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'日落桃'**
  String get msgefdde083;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认蓝（标志性蓝色）'**
  String get msg628e73a9;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'经典实心'**
  String get msg8244d240;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'现代圆角'**
  String get msgf08d9b15;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'星标特别'**
  String get msge5fba3dd;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文档片段'**
  String get msgfe4254dc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'极简描边'**
  String get msg84719fd5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 断线描边'**
  String get zenfile4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类网格 / Vuesax 网格'**
  String get vuesax;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'汉堡菜单 / 经典菜单'**
  String get msg5dc988f4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'极简风'**
  String get msgd06ba04f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'玻璃拟态'**
  String get msg5090469e;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'3D 可爱'**
  String get d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'赛博朋克'**
  String get msg67836b24;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自然禅意'**
  String get msgf08c8dc4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义图标'**
  String get msg7372dc9f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认标志（自然禅意）'**
  String get msg3004e40a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'点阵与无衬线'**
  String get msgc540e940;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'欧菲特现代无衬线'**
  String get msg00ea5776;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'捷脑科技等宽'**
  String get msg7bdbfaa5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'蒙特都市无衬线'**
  String get msgdcb4082d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义导入字体'**
  String get msg9d7001d9;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'标志性默认'**
  String get msgc2f5e9e4;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'从不（禁用自动删除）'**
  String get msg6a7c758f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'{days} 天后'**
  String days1(Object days);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择启动应用时默认显示的页面'**
  String get msgfe76ae54;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启动时显示快捷分类页面'**
  String get msg8af2412a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启动时显示文件浏览页面'**
  String get msg245c3258;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择用单指或双指左右滑动切换页面'**
  String get msg4439669d;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'单指左右滑动切换分类页、浏览页或打开抽屉'**
  String get msg46978666;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'双指滑动'**
  String get msgbc9bf336;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'双指左右滑动切换分类页、浏览页或打开抽屉'**
  String get msg563871d3;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择主题色'**
  String get msgca71ac0c;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择文件夹图标样式'**
  String get msg732630c1;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择抽屉按钮样式'**
  String get msgf9224d98;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择分类图标形状'**
  String get msgc337ecfa;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用启动器图标'**
  String get msgf18bc3d9;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'为应用启动器图标选择一个自定义Logo。注意某些启动器可能需要几秒钟才能更新。'**
  String get logo;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'默认标志'**
  String get msg64a6476a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用图标已切换为 {title}'**
  String title(Object title);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择自定义图标'**
  String get msgad76161f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请选择图片文件（PNG/JPG/WEBP）'**
  String get pngjpgwebp;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义图标已应用'**
  String get msgb06c5c34;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用自定义图标失败: {e}'**
  String e12(Object e);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'原始简洁几何风格'**
  String get msg375c9eb8;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'高科技复古点阵标题 + 简洁正文'**
  String get msg817e321b;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'超流畅、极简且高级的几何美学'**
  String get msg3c2a24cc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'干净且未来感的开发者等宽风格'**
  String get msg978f8d11;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'大胆、现代且醒目的字体排版'**
  String get msg93b657aa;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'您加载的自定义字体文件'**
  String get msg9db40ad6;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择一种精美的字体来自定义ZenFile的整体视觉主题'**
  String get zenfile5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'替换自定义字体文件'**
  String get msg7372efa5;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加载所选字体文件失败。'**
  String get msg3186839b;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请选择有效的 OpenType (.otf) 或 TrueType (.ttf) 字体文件.'**
  String get opentypeotftruetypettf;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'移除自定义字体'**
  String get msgcf42dedc;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义字体已移除。'**
  String get msg2b9abfaa;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'7 天'**
  String get msgfdef8c23;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'15 天'**
  String get msg25436ba3;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'30 天（推荐）'**
  String get msg85e7f60c;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'从不（手动清理）'**
  String get msgd61e706f;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自动删除回收站时长'**
  String get msgf0ef894a;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'回收站中的项目将在此时长后被永久删除。'**
  String get msg1200d6b7;

  /// ui\screens\network_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除连接'**
  String get msg432fbb31;

  /// ui\screens\network_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'添加连接'**
  String get msg3358aa10;

  /// ui\screens\network_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'暂无远程连接'**
  String get msgc9c900d0;

  /// ui\screens\network_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'添加 FTP、SFTP、WebDav 或 SMB 连接'**
  String get ftpsftpwebdavsmb1;

  /// ui\screens\network_category_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'连接失败：{e}'**
  String e13(Object e);

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在解析主机地址...'**
  String get msgb5bc0bf1;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在验证凭据...'**
  String get msg3005ba4d;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在挂载存储卷...'**
  String get msgab36a8c6;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'\"{name}\" 添加成功！'**
  String name1(Object name);

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'系统应用已禁用'**
  String get msgdf434415;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'您的设备没有启用默认的系统文件/文档应用（DocumentsUI），'**
  String get documentsui;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'这是 Android 选择和挂载目录所必需的。\\n\\n'**
  String get androidnn;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请检查\"文件\"或\"文档\"系统应用是否在设备设置中被禁用，'**
  String get msgb2af4e30;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请求 SAF 文件夹失败：{e}'**
  String safe(Object e);

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请输入连接名称'**
  String get msg65c7ecb6;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请输入服务器地址/主机名'**
  String get msg69e3963c;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程连接'**
  String get msgce1ec2ce;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'标准文件传输协议'**
  String get msg25557d1f;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'SSH安全文件传输服务器'**
  String get ssh;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'HTTP网页分布式创作'**
  String get http;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'Android 存储访问框架 (SD 卡 / 外部存储)'**
  String get androidsd;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择网络服务'**
  String get msg8486035b;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'将远程服务器或 NAS 共享挂载为 ZenFile 存储列表中的动态驱动器。'**
  String get naszenfile;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'{_selectedType} 设置'**
  String selectedtype(Object _selectedType);

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'输入连接详情以链接此网络存储卷。'**
  String get msg5c808d9a;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'例如：办公室 NAS、家庭共享'**
  String get nas;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'例如：192.168.1.100 或 192.168.1.100/dav'**
  String get dav;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'例如：192.168.1.100 或 nas.local'**
  String get naslocal;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'例如：/dav 或 /'**
  String get dav1;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'例如：anonymous 或 admin'**
  String get anonymousadmin;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'密码（可选）'**
  String get msgeec70cd2;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在创建挂载点...'**
  String get msgf1fa9d44;

  /// ui\screens\network_connection_wizard_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请稍候，我们正在建立与 {_selectedType} 服务器的可靠连接。'**
  String selectedtype1(Object _selectedType);

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'恢复项目出错：{e}'**
  String e14(Object e);

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除项目出错：{e}'**
  String e15(Object e);

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要永久删除回收站中的所有项目吗？此操作不可逆。'**
  String get msg62187f1b;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'清空回收站'**
  String get msg8cd6bc18;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'回收站已成功清空'**
  String get msga4dfc0c6;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'搜索已删除文件...'**
  String get msg07d80ac5;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'永久删除'**
  String get msg96d2b75f;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'回收站为空'**
  String get msg0d824a24;

  /// ui\screens\recycle_bin_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'原始位置'**
  String get msg4c478216;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在下载文本...'**
  String get msgc44a57b6;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在缓冲媒体...'**
  String get msgd6d8292d;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下载失败：{e}'**
  String e16(Object e);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'缓冲超时，请检查网络连接'**
  String get msg66d723c5;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'无法粘贴到相同位置'**
  String get msg53082c55;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在复制...'**
  String get msg108feeed;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'成功粘贴项目'**
  String get msg2d4b44ec;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'上传\"{fileName}\"失败：{e}'**
  String filenamee(Object e, Object fileName);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已重命名为 \"{newName}\"'**
  String newname(Object newName);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除项目'**
  String get msg4b342999;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除失败：{e}'**
  String e17(Object e);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新建远程文件夹'**
  String get msg79d7fef7;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹名称'**
  String get msga98473f2;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'创建文件夹失败：{e}'**
  String e18(Object e);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'远程目录'**
  String get msg5ca05a9b;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'复制到本地设备'**
  String get msga636c09d;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下载文件到本地剪贴板'**
  String get msga4c461a4;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下载并从服务器删除'**
  String get msg425502fa;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'根目录'**
  String get msgc2b9f4b9;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'上传本地剪贴板到服务器'**
  String get msg2f7cd487;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'粘贴远程剪贴板'**
  String get msg905c34fa;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'连接已断开'**
  String get msg8439c155;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'重试连接'**
  String get msgda43df27;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'空目录'**
  String get msga21f6ab1;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'在此上传剪贴板内容'**
  String get msge1c538b8;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'下载失败: {e}'**
  String e19(Object e);

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'删除确认'**
  String get msg50eaf94d;

  /// ui\screens\remote_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在删除...'**
  String get msgcb0da17b;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'应用管理'**
  String get msg4805c385;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'刷新列表'**
  String get msg93bc1f09;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已安装的用户应用'**
  String get msg32e490fe;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已备份的APK'**
  String get apk2;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'搜索包名或名称...'**
  String get msg8936ded6;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'按大小排序'**
  String get msgd8b3fc58;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'按字母排序'**
  String get msgbe1399f0;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'按备份日期排序'**
  String get msg9ad67f11;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'精确存储计算'**
  String get msgb0681bd4;

  /// ui\screens\storage_analyzer\app_manager_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'授予使用情况访问权限'**
  String get msg34cd846c;

  /// ui\screens\storage_analyzer\storage_analyzer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'存储分析'**
  String get msga22ddaae;

  /// ui\screens\storage_analyzer\storage_analyzer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'重新扫描存储'**
  String get msgaae779d4;

  /// ui\screens\storage_analyzer\storage_analyzer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在扫描设备存储'**
  String get msg7ae97495;

  /// ui\screens\storage_analyzer\storage_analyzer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'总存储'**
  String get msga5e5bf71;

  /// ui\screens\storage_analyzer\storage_analyzer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'分类明细'**
  String get msg652be256;

  /// ui\screens\storage_analyzer\widgets\app_batch_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'卸载应用'**
  String get msgeb3d7d70;

  /// ui\screens\storage_analyzer\widgets\app_batch_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'正在备份所选应用...'**
  String get msg6eb319a1;

  /// ui\screens\storage_analyzer\widgets\app_list_tab.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到应用'**
  String get msg7fbfdce6;

  /// ui\screens\storage_analyzer\widgets\app_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'启动应用'**
  String get msg753cdb55;

  /// ui\screens\storage_analyzer\widgets\app_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'备份APK'**
  String get apk3;

  /// ui\screens\storage_analyzer\widgets\app_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'正在备份APK...'**
  String get apk4;

  /// ui\screens\storage_analyzer\widgets\app_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'备份APK失败'**
  String get apk5;

  /// ui\screens\storage_analyzer\widgets\app_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'分享APK文件'**
  String get apk6;

  /// ui\screens\storage_analyzer\widgets\backup_list_tab.dart
  ///
  /// In zh, this message translates to:
  /// **'分享备份文件'**
  String get msga0b18169;

  /// ui\screens\storage_analyzer\widgets\backup_list_tab.dart
  ///
  /// In zh, this message translates to:
  /// **'删除备份文件'**
  String get msgb443cd06;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加载文件出错：{e}'**
  String e20(Object e);

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件保存成功'**
  String get msg24c6ab0f;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已替换 {count} 处'**
  String count3(Object count);

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'纯文本'**
  String get msgffb01e5b;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择语法'**
  String get msg7902d9c0;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'查找 / 替换'**
  String get msgc856a077;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'保存文件'**
  String get msg7f2c95cd;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'解锁缩放'**
  String get msg084e9388;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自动换行: 开'**
  String get msgf387265a;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自动换行: 关'**
  String get msg1045ba75;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'编辑锁定: 开'**
  String get msg96f0ad7d;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'编辑锁定: 关'**
  String get msg349ab61d;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏行号'**
  String get msg0cee3cd1;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'语法 ({_selectedLanguage})'**
  String selectedlanguage(Object _selectedLanguage);

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'替换为...'**
  String get msg0dac421f;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'全部替换'**
  String get msg52709ae1;

  /// ui\screens\text_editor_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'制表符'**
  String get msg4ecba8f6;

  /// ui\screens\vault_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'加载保险箱出错：{e}'**
  String e21(Object e);

  /// ui\screens\vault_explorer_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'隐藏文件'**
  String get msg4828116a;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'输入密码解锁'**
  String get msg3bf31dfe;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'输入PIN码解锁钱包'**
  String get pin;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'设置您的4位钱包PIN码'**
  String get pin1;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确认您的4位PIN码'**
  String get pin2;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'私人保险箱'**
  String get msgbb590f19;

  /// ui\screens\vault_lock_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'全部清除'**
  String get msgaa43fa46;

  /// ui\screens\video_player\video_controls_overlay.dart
  ///
  /// In zh, this message translates to:
  /// **'播放速度'**
  String get msgc16eed0e;

  /// ui\screens\video_player\video_controls_overlay.dart
  ///
  /// In zh, this message translates to:
  /// **'锁定控制'**
  String get msg8f106217;

  /// ui\screens\video_player\video_controls_overlay.dart
  ///
  /// In zh, this message translates to:
  /// **'重复模式'**
  String get msg1f41f25d;

  /// ui\screens\video_player\video_controls_overlay.dart
  ///
  /// In zh, this message translates to:
  /// **'媒体路径已复制到剪贴板。'**
  String get msg4d2abc8c;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'本地 HTTP 共享服务器已停止。'**
  String get http1;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'正在建立安全代理中继...'**
  String get msg2904d894;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'互联网云隧道已上线！临时链接已激活。'**
  String get msg2c146598;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'链接已复制到剪贴板！'**
  String get msg4a5d26f4;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'使用其他设备扫描以立即打开 {type}。'**
  String type(Object type);

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'网页共享中心'**
  String get msgc8390d74;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'互联网分享链接'**
  String get msg5345cdce;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'HTTP本地共享服务器'**
  String get http2;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'允许同一 Wi-Fi 下的其他设备通过网页浏览器访问、查看和流式传输您的文件。'**
  String get wifi;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'服务器在线并流式传输中'**
  String get msg73c512df;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'复制 URL'**
  String get url1;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'二维码'**
  String get msg22b03c02;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'共享目录：{shareDir}'**
  String sharedir(Object shareDir);

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'服务器空闲'**
  String get msge6a29aa4;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'请确保其他设备与此设备处于同一 Wi-Fi 网络，然后启动服务器。'**
  String get wifi1;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'启动网页服务器'**
  String get msg974465c1;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'生成一个安全的临时公共隧道链接。与互联网上任何地方的任何人分享此链接，让他们高速下载文件，无论文件大小。'**
  String get msg27d5bd3c;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'临时分享链接（有效期 24 小时）：'**
  String get msg66a09a42;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get msg879058ce;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'已连接的浏览器客户端'**
  String get msg7ed199f8;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'等待传入的互联网下载...'**
  String get msgb77e4adf;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'互联网共享未激活'**
  String get msga61778bc;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'停用云共享'**
  String get msga3c80551;

  /// ui\screens\web_sharing_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'激活互联网分享链接'**
  String get msg6466e61e;

  /// ui\widgets\background_operation_progress_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'正在处理...'**
  String get msg67bd9375;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'正在重命名文件...'**
  String get msg3fa72416;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'请稍候，正在更新文件夹内容'**
  String get msg7dbbef0e;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'原始名称 (%)'**
  String get msg1a2d9a44;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'顺序编号 (#)'**
  String get msgcb029197;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'三位顺序编号 (###)'**
  String get msgb6d8a14f;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'不带扩展名的文件名 ({n})'**
  String n(Object n);

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'带点的扩展名 ({de})'**
  String de(Object de);

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'不带点的扩展名 ({e})'**
  String e22(Object e);

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'带扩展名的完整文件名 ({N})'**
  String n1(Object N);

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'名称模式'**
  String get msg0e9dc63a;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'扩展名'**
  String get msg4a63edba;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'起始编号'**
  String get msga420ad79;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'查找文本'**
  String get msg9857973d;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'替换为'**
  String get msg1605701e;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'替换内容'**
  String get msgd35f80c8;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'重命名预览'**
  String get msg32c61dab;

  /// ui\widgets\batch_rename_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'返回编辑'**
  String get msg92642e0e;

  /// ui\widgets\conflict_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'文件已存在'**
  String get msgde88d67a;

  /// ui\widgets\conflict_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'应用于所有剩余冲突'**
  String get msge59e35b5;

  /// ui\widgets\conflict_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'保留两者'**
  String get msg27dfaae5;

  /// ui\widgets\conflict_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'重命名文件'**
  String get msg6cfbf05d;

  /// ui\widgets\create_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'创建压缩包'**
  String get msg25f747ce;

  /// ui\widgets\create_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'压缩格式'**
  String get msged5f808e;

  /// ui\widgets\create_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'分卷大小（MB，可选）'**
  String get mb;

  /// ui\widgets\create_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'留空则创建单个压缩包'**
  String get msgac52af6a;

  /// ui\widgets\create_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'为每个文件创建单独的压缩包'**
  String get msgdf2ef7f5;

  /// ui\widgets\directory_tab_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'新建标签页'**
  String get msgb52d4a73;

  /// ui\widgets\directory_tab_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'复制标签页'**
  String get msg4e9c344a;

  /// ui\widgets\directory_tab_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'关闭其他标签页'**
  String get msg7716532d;

  /// ui\widgets\directory_tab_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'双击关闭标签页'**
  String get msgd78603eb;

  /// ui\widgets\drag_drop_action_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'{selectedCount} 个项目'**
  String selectedcount(Object selectedCount);

  /// ui\widgets\drag_drop_action_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'创建压缩包失败：{e}'**
  String e23(Object e);

  /// ui\widgets\extract_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'解压压缩包'**
  String get msgc4d7eece;

  /// ui\widgets\extract_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'解压到文件夹'**
  String get msgf15821d0;

  /// ui\widgets\extract_archive_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'密码（如果已加密）'**
  String get msgff69affd;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'全部文件'**
  String get msg67eda5e6;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'显示此目录中的所有文件和文件夹'**
  String get msg8b2fcb31;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'PDF、Word 文档、电子表格、文本和电子书'**
  String get pdfword;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'JPEG、PNG、WebP 和原始照片格式'**
  String get jpegpngwebp;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'MP3、WAV、AAC 和高保真音频'**
  String get mp3wavaac;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'MP4、MKV、WebM 和高分辨率视频片段'**
  String get mp4mkvwebm;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'ZIP、7Z、RAR 和其他压缩文件'**
  String get zip7zrar;

  /// ui\widgets\file_filter_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'选择一个类别以仅显示匹配的文件'**
  String get msg6d3e48cc;

  /// ui\widgets\file_item.dart
  ///
  /// In zh, this message translates to:
  /// **'远程缩略图加载失败: {e}'**
  String e24(Object e);

  /// ui\widgets\file_item.dart
  ///
  /// In zh, this message translates to:
  /// **'1 项'**
  String get msg32a1bd25;

  /// ui\widgets\file_item.dart
  ///
  /// In zh, this message translates to:
  /// **'{count} 项'**
  String count4(Object count);

  /// ui\widgets\file_operation_progress_dialog.dart
  ///
  /// In zh, this message translates to:
  /// **'正在移动文件...'**
  String get msg9d69d7a0;

  /// ui\widgets\open_with_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'ZenFile 自定义原生体验'**
  String get zenfile6;

  /// ui\widgets\open_with_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'系统外部应用'**
  String get msg42be43e6;

  /// ui\widgets\open_with_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'使用设备上的第三方应用打开'**
  String get msgd1fca831;

  /// ui\widgets\open_with_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'仅一次'**
  String get msgdb75b769;

  /// ui\widgets\premium_storage_overview.dart
  ///
  /// In zh, this message translates to:
  /// **'浏览设备文件'**
  String get msg959429a5;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'添加新连接'**
  String get msgc31116e3;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get msgf1d4ff50;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'未固定快捷方式。点击自定义添加。'**
  String get msg490ac572;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'拖动手柄 (=) 可重新排列首页图标。'**
  String get msg445a43cb;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'添加文件夹/文件快捷方式'**
  String get msg944d5ecd;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义路径'**
  String get msg4f356348;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'删除快捷方式'**
  String get msg94733bec;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'恢复位置'**
  String get msg5c29ad2f;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义扫描位置：'**
  String get msg21de5dd7;

  /// ui\widgets\quick_categories_grid.dart
  ///
  /// In zh, this message translates to:
  /// **'未添加自定义路径。'**
  String get msg4bb81f99;

  /// ui\widgets\recent_files_section.dart
  ///
  /// In zh, this message translates to:
  /// **'10月'**
  String get msgf544c399;

  /// ui\widgets\recent_files_section.dart
  ///
  /// In zh, this message translates to:
  /// **'12月'**
  String get msgc0615eb3;

  /// ui\widgets\recent_files_section.dart
  ///
  /// In zh, this message translates to:
  /// **'最近文件'**
  String get msg54355dd8;

  /// ui\widgets\restricted_folder_banner.dart
  ///
  /// In zh, this message translates to:
  /// **'受限系统文件夹'**
  String get msgd5eac3a3;

  /// ui\widgets\restricted_folder_banner.dart
  ///
  /// In zh, this message translates to:
  /// **'Android 11+ 限制了对 Android/data 和 Android/obb 文件夹的标准访问，以保护应用数据。要查看和修改这些文件，ZenFile 需要高级权限。'**
  String get android11androiddataandroidobbzenfile;

  /// ui\widgets\restricted_folder_banner.dart
  ///
  /// In zh, this message translates to:
  /// **'使用 Root 访问（超级用户）'**
  String get root;

  /// ui\widgets\restricted_folder_banner.dart
  ///
  /// In zh, this message translates to:
  /// **'授予Shizuku访问权限（无需Root）'**
  String get shizukuroot;

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'已选择 {selectedCount} 项'**
  String selectedcount1(Object selectedCount);

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要删除 {selectedCount} 个项目吗？此操作无法撤销。'**
  String selectedcount2(Object selectedCount);

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'已取消置顶所选项目'**
  String get msga9b87614;

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'取消置顶'**
  String get msg84e4fac9;

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'正在计算大小...'**
  String get msg3be9abab;

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'已选择路径：'**
  String get msg7704aa2c;

  /// ui\widgets\selection_action_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'已复制 {label} 到剪贴板'**
  String label1(Object label);

  /// ui\widgets\selection_context_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'已选择 {selectedCount} 个项目'**
  String selectedcount3(Object selectedCount);

  /// ui\widgets\selection_context_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'文件（长按选择打开方式）'**
  String get msg8b73264b;

  /// ui\widgets\selection_context_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'复制所选'**
  String get msgc5c0646c;

  /// ui\widgets\selection_context_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'剪切所选'**
  String get msg8e6d4604;

  /// ui\widgets\selection_context_bottom_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'属性与信息'**
  String get msg1058354c;

  /// ui\widgets\storage_overview.dart
  ///
  /// In zh, this message translates to:
  /// **'已使用 {usedStorageStr}'**
  String usedstoragestr(Object usedStorageStr);

  /// ui\widgets\swipable_storage_overview.dart
  ///
  /// In zh, this message translates to:
  /// **'{freeStorageStr} 可用'**
  String freestoragestr(Object freeStorageStr);

  /// ui\widgets\tab_options_sheet.dart
  ///
  /// In zh, this message translates to:
  /// **'取消固定标签页'**
  String get msgc823e21b;

  /// ui\widgets\zenfile_address_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配的目录或文件'**
  String get msg7d6c1284;

  /// ui\widgets\zenfile_address_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'路径不存在: {path}'**
  String path(Object path);

  /// ui\widgets\zenfile_address_bar.dart
  ///
  /// In zh, this message translates to:
  /// **'输入绝对路径...'**
  String get msg6cbbf7d9;

  /// ui\widgets\zenfile_drawer.dart
  ///
  /// In zh, this message translates to:
  /// **'服务器与工具'**
  String get msgf13fc21c;

  /// ui\widgets\zenfile_drawer.dart
  ///
  /// In zh, this message translates to:
  /// **'添加远程连接'**
  String get msg41e625d1;

  /// ui\widgets\zenfile_drawer.dart
  ///
  /// In zh, this message translates to:
  /// **'浅色模式'**
  String get msg8755e992;

  /// ui\widgets\zenfile_drawer.dart
  ///
  /// In zh, this message translates to:
  /// **'更多设置'**
  String get msg1cf6fcd3;

  /// ui\widgets\zenfile_drawer.dart
  ///
  /// In zh, this message translates to:
  /// **'精品媒体套件'**
  String get msgeef7e30c;

  /// No description provided for @msg2ad64aa7.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接：{urlString}'**
  String msg2ad64aa7(Object urlString);

  /// No description provided for @msg30d17f96.
  ///
  /// In zh, this message translates to:
  /// **'核心亮点'**
  String get msg30d17f96;

  /// No description provided for @msgaba638c4.
  ///
  /// In zh, this message translates to:
  /// **'保险箱安全'**
  String get msgaba638c4;

  /// No description provided for @msgd309e9ea.
  ///
  /// In zh, this message translates to:
  /// **'服务器中心'**
  String get msgd309e9ea;

  /// No description provided for @msg4a5f936c.
  ///
  /// In zh, this message translates to:
  /// **'联系与分享'**
  String get msg4a5f936c;

  /// No description provided for @msg4d48a010.
  ///
  /// In zh, this message translates to:
  /// **'ZenFile - 精美文件管理器'**
  String get msg4d48a010;

  /// No description provided for @msg1f4c0192.
  ///
  /// In zh, this message translates to:
  /// **'请作者喝杯咖啡 ☕'**
  String get msg1f4c0192;

  /// No description provided for @msg2eceaa85.
  ///
  /// In zh, this message translates to:
  /// **'打赏作者'**
  String get msg2eceaa85;

  /// No description provided for @msg305734ce.
  ///
  /// In zh, this message translates to:
  /// **'更新日志'**
  String get msg305734ce;

  /// No description provided for @msg1c80891a.
  ///
  /// In zh, this message translates to:
  /// **'新增浏览页远程文件缩略图预览'**
  String get msg1c80891a;

  /// No description provided for @msg212f8f9e.
  ///
  /// In zh, this message translates to:
  /// **'修复远程文件无法打开播放的问题'**
  String get msg212f8f9e;

  /// No description provided for @msgd0cf310e.
  ///
  /// In zh, this message translates to:
  /// **'优化远程文件缓存目录统一管理'**
  String get msgd0cf310e;

  /// No description provided for @msg072f2022.
  ///
  /// In zh, this message translates to:
  /// **'单指滑动切换页面改为双指滑动（避免误触返回手势）'**
  String get msg072f2022;

  /// No description provided for @msg66517dc4.
  ///
  /// In zh, this message translates to:
  /// **'字体选项标题全面汉化'**
  String get msg66517dc4;

  /// No description provided for @msgacad92c8.
  ///
  /// In zh, this message translates to:
  /// **'移除\"阻止左侧返回手势打开抽屉\"功能'**
  String get msgacad92c8;

  /// No description provided for @msg09d0e1b6.
  ///
  /// In zh, this message translates to:
  /// **'修复：备用图标切换不生效'**
  String get msg09d0e1b6;

  /// No description provided for @msg2d1872c8.
  ///
  /// In zh, this message translates to:
  /// **'文本编辑器菜单全面汉化'**
  String get msg2d1872c8;

  /// No description provided for @msg2e35eef7.
  ///
  /// In zh, this message translates to:
  /// **'双面板文件浏览器'**
  String get msg2e35eef7;

  /// No description provided for @msge96aa2cd.
  ///
  /// In zh, this message translates to:
  /// **'内置媒体播放器'**
  String get msge96aa2cd;

  /// No description provided for @msg49a6c41e.
  ///
  /// In zh, this message translates to:
  /// **'应用图标切换（多种风格可选）'**
  String get msg49a6c41e;

  /// No description provided for @msg4d82be7c.
  ///
  /// In zh, this message translates to:
  /// **'下版本更新计划'**
  String get msg4d82be7c;

  /// No description provided for @msg2c8957dd.
  ///
  /// In zh, this message translates to:
  /// **'已知问题'**
  String get msg2c8957dd;

  /// No description provided for @msg11cb01fc.
  ///
  /// In zh, this message translates to:
  /// **'远程服务器边缓存边播放视频'**
  String get msg11cb01fc;

  /// No description provided for @msg60a4d643.
  ///
  /// In zh, this message translates to:
  /// **'自定义图标上传后桌面图标不会更改（下版本完善）'**
  String get msg60a4d643;

  /// No description provided for @msg9e68ea42.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get msg9e68ea42;

  /// No description provided for @cat_images.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get cat_images;

  /// No description provided for @cat_videos.
  ///
  /// In zh, this message translates to:
  /// **'视频'**
  String get cat_videos;

  /// No description provided for @cat_audios.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get cat_audios;

  /// No description provided for @cat_documents.
  ///
  /// In zh, this message translates to:
  /// **'文档'**
  String get cat_documents;

  /// No description provided for @cat_downloads.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get cat_downloads;

  /// No description provided for @cat_screenshots.
  ///
  /// In zh, this message translates to:
  /// **'截图'**
  String get cat_screenshots;

  /// No description provided for @cat_recent.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get cat_recent;

  /// No description provided for @cat_network.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get cat_network;

  /// No description provided for @cat_apps.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get cat_apps;

  /// No description provided for @cat_settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get cat_settings;

  /// No description provided for @cat_storage.
  ///
  /// In zh, this message translates to:
  /// **'存储'**
  String get cat_storage;

  /// No description provided for @cat_service.
  ///
  /// In zh, this message translates to:
  /// **'服务'**
  String get cat_service;

  /// No description provided for @cat_manage.
  ///
  /// In zh, this message translates to:
  /// **'管理'**
  String get cat_manage;

  /// No description provided for @cat_config.
  ///
  /// In zh, this message translates to:
  /// **'配置'**
  String get cat_config;

  /// No description provided for @cat_analyze.
  ///
  /// In zh, this message translates to:
  /// **'分析'**
  String get cat_analyze;

  /// No description provided for @cat_quick_categories.
  ///
  /// In zh, this message translates to:
  /// **'快捷分类'**
  String get cat_quick_categories;

  /// No description provided for @ui_nav.
  ///
  /// In zh, this message translates to:
  /// **'导航'**
  String get ui_nav;

  /// No description provided for @ui_home.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get ui_home;

  /// No description provided for @ui_recycle_bin.
  ///
  /// In zh, this message translates to:
  /// **'回收站'**
  String get ui_recycle_bin;

  /// No description provided for @ui_dark_mode.
  ///
  /// In zh, this message translates to:
  /// **'深色模式'**
  String get ui_dark_mode;

  /// No description provided for @ui_personalize_settings.
  ///
  /// In zh, this message translates to:
  /// **'个性化和设置'**
  String get ui_personalize_settings;

  /// No description provided for @ui_compress.
  ///
  /// In zh, this message translates to:
  /// **'压缩'**
  String get ui_compress;

  /// No description provided for @ui_copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get ui_copy;

  /// No description provided for @ui_cut.
  ///
  /// In zh, this message translates to:
  /// **'剪切'**
  String get ui_cut;

  /// No description provided for @ui_delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get ui_delete;

  /// No description provided for @ui_select_all.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get ui_select_all;

  /// No description provided for @ui_cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get ui_cancel;

  /// No description provided for @ui_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get ui_confirm;

  /// No description provided for @ui_share.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get ui_share;

  /// No description provided for @ui_move_here.
  ///
  /// In zh, this message translates to:
  /// **'移动到此处'**
  String get ui_move_here;

  /// No description provided for @ui_properties.
  ///
  /// In zh, this message translates to:
  /// **'属性'**
  String get ui_properties;

  /// No description provided for @ui_info.
  ///
  /// In zh, this message translates to:
  /// **'信息'**
  String get ui_info;

  /// No description provided for @ui_open.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get ui_open;

  /// No description provided for @ui_close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get ui_close;

  /// No description provided for @ui_more.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get ui_more;

  /// No description provided for @ui_appearance_theme.
  ///
  /// In zh, this message translates to:
  /// **'外观与主题'**
  String get ui_appearance_theme;

  /// No description provided for @ui_list_layout_style.
  ///
  /// In zh, this message translates to:
  /// **'列表与布局样式'**
  String get ui_list_layout_style;

  /// No description provided for @ui_media_preferences.
  ///
  /// In zh, this message translates to:
  /// **'媒体偏好'**
  String get ui_media_preferences;

  /// No description provided for @ui_file_actions_viewers.
  ///
  /// In zh, this message translates to:
  /// **'文件操作与查看器'**
  String get ui_file_actions_viewers;

  /// No description provided for @ui_no_settings_found.
  ///
  /// In zh, this message translates to:
  /// **'未找到设置'**
  String get ui_no_settings_found;

  /// No description provided for @ui_show_floating_button.
  ///
  /// In zh, this message translates to:
  /// **'显示浮动按钮'**
  String get ui_show_floating_button;

  /// No description provided for @ui_use_24h_format.
  ///
  /// In zh, this message translates to:
  /// **'使用24小时制'**
  String get ui_use_24h_format;

  /// No description provided for @ui_show_folder_contents_count.
  ///
  /// In zh, this message translates to:
  /// **'显示文件夹内容计数'**
  String get ui_show_folder_contents_count;

  /// No description provided for @ui_show_folder_size.
  ///
  /// In zh, this message translates to:
  /// **'显示文件夹大小'**
  String get ui_show_folder_size;

  /// No description provided for @ui_show_bottom_action_bar.
  ///
  /// In zh, this message translates to:
  /// **'显示底部导航栏'**
  String get ui_show_bottom_action_bar;

  /// No description provided for @ui_hide_action_text.
  ///
  /// In zh, this message translates to:
  /// **'隐藏操作栏文字标签'**
  String get ui_hide_action_text;

  /// No description provided for @ui_show_media_previews.
  ///
  /// In zh, this message translates to:
  /// **'显示媒体预览'**
  String get ui_show_media_previews;

  /// No description provided for @ui_adaptive_multiline_names.
  ///
  /// In zh, this message translates to:
  /// **'自适应多行文件名'**
  String get ui_adaptive_multiline_names;

  /// No description provided for @ui_hide_action_menu_buttons.
  ///
  /// In zh, this message translates to:
  /// **'隐藏三点操作按钮'**
  String get ui_hide_action_menu_buttons;

  /// No description provided for @ui_enable_drag_drop.
  ///
  /// In zh, this message translates to:
  /// **'启用拖放'**
  String get ui_enable_drag_drop;

  /// No description provided for @ui_confirm_drag_drop.
  ///
  /// In zh, this message translates to:
  /// **'确认拖放操作'**
  String get ui_confirm_drag_drop;

  /// No description provided for @ui_enable_multi_tabs.
  ///
  /// In zh, this message translates to:
  /// **'启用多标签页'**
  String get ui_enable_multi_tabs;

  /// No description provided for @ui_enable_split_screen.
  ///
  /// In zh, this message translates to:
  /// **'启用分屏'**
  String get ui_enable_split_screen;

  /// No description provided for @ui_app_icon.
  ///
  /// In zh, this message translates to:
  /// **'应用图标'**
  String get ui_app_icon;

  /// No description provided for @ui_emerald_green.
  ///
  /// In zh, this message translates to:
  /// **'翠绿'**
  String get ui_emerald_green;

  /// No description provided for @ui_deep_red.
  ///
  /// In zh, this message translates to:
  /// **'深红'**
  String get ui_deep_red;

  /// No description provided for @ui_square.
  ///
  /// In zh, this message translates to:
  /// **'方形'**
  String get ui_square;

  /// No description provided for @ui_circle.
  ///
  /// In zh, this message translates to:
  /// **'圆形'**
  String get ui_circle;

  /// No description provided for @ui_1_day_after.
  ///
  /// In zh, this message translates to:
  /// **'1 天后'**
  String get ui_1_day_after;

  /// No description provided for @ui_no_auto_clean.
  ///
  /// In zh, this message translates to:
  /// **'不自动清理'**
  String get ui_no_auto_clean;

  /// No description provided for @ui_daily.
  ///
  /// In zh, this message translates to:
  /// **'每天'**
  String get ui_daily;

  /// No description provided for @ui_weekly.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get ui_weekly;

  /// No description provided for @ui_monthly.
  ///
  /// In zh, this message translates to:
  /// **'每月'**
  String get ui_monthly;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'每{days}天'**
  String ui_every_n_days(Object days);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'清除缓存失败: {e}'**
  String ui_clear_cache_failed(Object e);

  /// No description provided for @ui_clear_remote_cache.
  ///
  /// In zh, this message translates to:
  /// **'清除远程缓存'**
  String get ui_clear_remote_cache;

  /// No description provided for @ui_view_cache_dir.
  ///
  /// In zh, this message translates to:
  /// **'查看缓存目录'**
  String get ui_view_cache_dir;

  /// No description provided for @ui_remote_media_thumbnail.
  ///
  /// In zh, this message translates to:
  /// **'远程媒体缩略图'**
  String get ui_remote_media_thumbnail;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'定期自动清理远程服务器缓存文件: {label}'**
  String ui_auto_clean_remote_cache(Object label);

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义字体（{name}）'**
  String ui_custom_font_with_name(Object name);

  /// No description provided for @ui_import_custom_font.
  ///
  /// In zh, this message translates to:
  /// **'导入自定义字体文件 (.ttf/.otf)'**
  String get ui_import_custom_font;

  /// ui\screens\more_settings_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'自定义字体\"{name}\"已成功应用！'**
  String ui_custom_font_applied(Object name);

  /// No description provided for @ui_invalid_file_type.
  ///
  /// In zh, this message translates to:
  /// **'无效的文件类型'**
  String get ui_invalid_file_type;

  /// No description provided for @ui_language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get ui_language;

  /// No description provided for @ui_hide_nav_labels.
  ///
  /// In zh, this message translates to:
  /// **'隐藏底部导航标签'**
  String get ui_hide_nav_labels;

  /// No description provided for @ui_reset_default_viewers.
  ///
  /// In zh, this message translates to:
  /// **'重置默认文件查看器'**
  String get ui_reset_default_viewers;

  /// No description provided for @ui_trailing_info_when_hidden.
  ///
  /// In zh, this message translates to:
  /// **'三点禁用尾部信息'**
  String get ui_trailing_info_when_hidden;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'上一级'**
  String get ui_go_up;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'{prefix} · {count} 项'**
  String ui_cut_copy_items(String prefix, int count);

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get ui_clear;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get ui_paste;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件名'**
  String get ui_file_name;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get ui_create;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'创建新目录'**
  String get ui_create_new_directory;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'布局模式'**
  String get ui_layout_mode;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'网格视图'**
  String get ui_grid_view;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'名称 (A-Z)'**
  String get ui_name_asc;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最新'**
  String get ui_newest;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'最旧'**
  String get ui_oldest;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'大小（小）'**
  String get ui_size_small;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get ui_type;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'存储卷'**
  String get ui_storage_volume;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'浏览'**
  String get ui_browse;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'新建'**
  String get ui_new;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件夹：{count}'**
  String ui_folders_count(int count);

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件：{count}'**
  String ui_files_count(int count);

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'选择模式'**
  String get ui_selection_mode;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'存储卷和SD卡'**
  String get ui_storage_and_sd;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'仅图片'**
  String get ui_images_only;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'仅视频'**
  String get ui_videos_only;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'显示文件夹'**
  String get ui_show_folders;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get ui_files;

  /// directory_screen.dart
  ///
  /// In zh, this message translates to:
  /// **'确定要删除此文件吗？此操作无法撤销。'**
  String get ui_delete_file_confirm;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get ui_done;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get ui_name;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'路径'**
  String get ui_path;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'大小'**
  String get ui_size;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'权限'**
  String get ui_permissions;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'包含'**
  String get ui_contains;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'解压'**
  String get ui_extract;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'置顶'**
  String get ui_pin_to_top;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'已将所选项目置顶'**
  String get ui_pinned_selected;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'按类型筛选文件'**
  String get ui_filter_by_type;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'默认扫描位置：'**
  String get ui_default_scan_locations;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'排除位置'**
  String get ui_exclude_location;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'添加自定义路径'**
  String get ui_add_custom_path;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'已添加 {count} 个自定义路径'**
  String ui_added_custom_paths(int count);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'关闭标签页'**
  String get ui_close_tab;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'未找到 {title}'**
  String ui_not_found_title(String title);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'最旧优先'**
  String get ui_oldest_first;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'排序选项'**
  String get ui_sort_options;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get ui_refresh;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'{count} 已选择'**
  String ui_selected_count(int count);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'永久删除\"{name}\"？'**
  String ui_permanently_delete_name(String name);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'已复制 {count} 个项目到剪贴板'**
  String ui_copied_count(int count);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'已剪切 {count} 个项目到剪贴板'**
  String ui_cut_count(int count);

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'读取'**
  String get ui_read;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'写入'**
  String get ui_write;

  /// ui widgets
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get ui_file;

  /// No description provided for @ui_backup_settings.
  ///
  /// In zh, this message translates to:
  /// **'备份设置'**
  String get ui_backup_settings;

  /// No description provided for @ui_restore_settings.
  ///
  /// In zh, this message translates to:
  /// **'恢复设置'**
  String get ui_restore_settings;

  /// No description provided for @ui_backup_info.
  ///
  /// In zh, this message translates to:
  /// **'备份信息'**
  String get ui_backup_info;

  /// No description provided for @ui_backup_file.
  ///
  /// In zh, this message translates to:
  /// **'备份文件'**
  String get ui_backup_file;

  /// No description provided for @ui_no_backup_file.
  ///
  /// In zh, this message translates to:
  /// **'暂无备份文件'**
  String get ui_no_backup_file;

  /// No description provided for @ui_remote_connection.
  ///
  /// In zh, this message translates to:
  /// **'远程连接'**
  String get ui_remote_connection;

  /// No description provided for @ui_step_n_of_3.
  ///
  /// In zh, this message translates to:
  /// **'第 {step} / 3 步'**
  String ui_step_n_of_3(Object step);

  /// No description provided for @ui_choose_network_service.
  ///
  /// In zh, this message translates to:
  /// **'选择网络服务'**
  String get ui_choose_network_service;

  /// No description provided for @ui_connection_name.
  ///
  /// In zh, this message translates to:
  /// **'连接名称'**
  String get ui_connection_name;

  /// No description provided for @ui_protocol.
  ///
  /// In zh, this message translates to:
  /// **'协议'**
  String get ui_protocol;

  /// No description provided for @ui_port.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get ui_port;

  /// No description provided for @ui_path_label.
  ///
  /// In zh, this message translates to:
  /// **'路径'**
  String get ui_path_label;

  /// No description provided for @ui_username_optional.
  ///
  /// In zh, this message translates to:
  /// **'用户名（可选）'**
  String get ui_username_optional;

  /// No description provided for @ui_back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get ui_back;

  /// No description provided for @ui_connect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get ui_connect;

  /// No description provided for @ui_web_share.
  ///
  /// In zh, this message translates to:
  /// **'网页共享'**
  String get ui_web_share;

  /// No description provided for @ui_network.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get ui_network;

  /// No description provided for @log_i18n_full.
  ///
  /// In zh, this message translates to:
  /// **'全面国际化中英文界面'**
  String get log_i18n_full;

  /// No description provided for @log_fix_selection_count.
  ///
  /// In zh, this message translates to:
  /// **'修复文件选择数量不显示的问题'**
  String get log_fix_selection_count;

  /// No description provided for @log_fix_remote_title.
  ///
  /// In zh, this message translates to:
  /// **'修复远程连接页面标题显示异常'**
  String get log_fix_remote_title;

  /// No description provided for @log_svg_thumbnail_category.
  ///
  /// In zh, this message translates to:
  /// **'SVG 缩略图在分类页面中正常显示'**
  String get log_svg_thumbnail_category;

  /// No description provided for @log_language_btn_top.
  ///
  /// In zh, this message translates to:
  /// **'语言切换按钮移至设置页顶部'**
  String get log_language_btn_top;

  /// No description provided for @log_fix_category_missing.
  ///
  /// In zh, this message translates to:
  /// **'修复英文模式下部分分类不显示'**
  String get log_fix_category_missing;
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
  const _L10nDelegate();

  @override
  Future<L10n> load(Locale locale) {
    return SynchronousFuture<L10n>(lookupL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_L10nDelegate old) => false;
}

L10n lookupL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return L10nEn();
    case 'zh':
      return L10nZh();
  }

  throw FlutterError(
    'L10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
