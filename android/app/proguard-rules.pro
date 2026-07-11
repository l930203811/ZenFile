# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class com.media_kit.** { *; }
-keep class com.open_filex.** { *; }
-keep class com.receive_sharing_intent.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.media_kit.**

# audio_service — keep all classes needed for MediaBrowserService and notification
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.** { *; }
-dontwarn com.ryanheise.**

# audio_session — keep audio focus classes
-keep class com.ryanheise.audiosession.** { *; }
-dontwarn com.ryanheise.audiosession.**

# device_info_plus
-keep class dev.fluttercommunity.plus.device_info.** { *; }
-dontwarn dev.fluttercommunity.plus.device_info.**

# AndroidX Media / MediaBrowserServiceCompat — must not be obfuscated
-keep class androidx.media.** { *; }
-keep class android.support.v4.media.** { *; }
-dontwarn androidx.media.**

# smbj SMB client
-keep class com.hierynomus.smbj.** { *; }
-keep class com.hierynomus.mssmb2.** { *; }
-keep class com.hierynomus.mstype.** { *; }
-keep class com.hierynomus.protocol.** { *; }
-keep class com.hierynomus.security.** { *; }
-dontwarn com.hierynomus.**

# BouncyCastle
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# smbj 传递依赖 mbassy 事件总线,引用了 Android 上不存在的 javax.el.* 类
# 这些类仅在 EL 表达式解析功能中使用,SMB 操作不会触发,可安全忽略
-dontwarn javax.el.**
-dontwarn net.engio.mbassy.**
-keep class net.engio.mbassy.** { *; }

# dcerpc 依赖 RMI 相关类
-dontwarn java.rmi.**
-dontwarn com.rapid7.client.dcerpc.**

