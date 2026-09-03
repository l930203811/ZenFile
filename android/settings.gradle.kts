pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven { url = uri("C:/Users/admin/flutter-maven-repo") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.1" apply false
    // 固定 Kotlin 2.3.20，请勿降回 2.1.x：flutter_avif 3.1.0 的源码在 Kotlin 2.1.x 下
    // 会触发 "FlutterAvifPlugin Redeclaration" 编译错误（`flutter build apk` 直接失败）。
    // 2.2.20 已验证可正常编译 flutter_avif（详见 WORKLOG 2026-08-05「Kotlin 版本固定」）；
    // 2.3.20 为 Flutter 3.47 版本检查建议的最低版本（原 2.2.20 即将被弃用）。
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
