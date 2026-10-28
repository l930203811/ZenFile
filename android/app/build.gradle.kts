import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sequl.zenfile"
    // compileSdk=37：permission_handler_android / receive_sharing_intent 要求 compileSdk≥37；
    // AGP 9.1.1 起官方支持 API 37（配套 Gradle 9.3.1）。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    defaultConfig {
        // ⚠️ v2.0.0 起保险箱不兼容旧版数据，改为独立包名以便与 1.x 共存安装，
        // 用户可在旧版导出保险箱备份后再卸载旧版。**此包名需长期沿用**，
        // 改回 com.sequl.zenfile 会导致用户再次全新安装并丢失数据。
        applicationId = "com.sequl.zenfile2"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resourceConfigurations.addAll(listOf("en"))
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    lint {
        // 禁用 release 的 lintVital 检查：AGP 9 下 lintVitalAnalyzeRelease 在 Windows 上会因
        // lint 缓存 jar 被系统实时扫描锁定（FileSystemException "另一个程序正在使用此文件"）反复失败。
        // lint 为静态检查，不影响 APK 产物与功能。
        checkReleaseBuilds = false
    }

    packaging {
        jniLibs.useLegacyPackaging = false
        // OSGi 元数据与 Android 运行时无关，多个依赖重复携带时直接排除即可。
        // mwiede/jsch(2.28.7) 与项目已有的 bcprov-jdk18on 都带有这些文件，
        // 不排除会让 mergeReleaseJavaResource 因「同路径多来源」而失败。
        resources.excludes.add("META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        resources.excludes.add("META-INF/versions/11/OSGI-INF/MANIFEST.MF")
        resources.excludes.add("META-INF/versions/15/OSGI-INF/MANIFEST.MF")
        resources.excludes.add("META-INF/versions/17/OSGI-INF/MANIFEST.MF")
    }


}

flutter {
    source = "../.."
}

dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("androidx.fragment:fragment:1.8.5")
    // SMB support (smbj pulls BouncyCastle bcprov-jdk15on transitively for NTLMSSP)
    // ≥0.14.0 修复上游 #792：匿名/guest 会话跳过 setSessionKey，而服务器又未按规范
    // 设置 IS_NULL/IS_GUEST 标志时，SMB 3.x 的 deriveKeys() 会对 null sessionKey
    // 调 getEncoded() 抛 NPE（Key.getEncoded() on a null object reference）——
    // 表现为「服务器明明接受了匿名登录，客户端却报连接失败」。
    implementation("com.hierynomus:smbj:0.14.0")
    implementation("com.rapid7.client:dcerpc:0.12.13") {
        exclude(group = "com.google.guava", module = "guava")
        exclude(group = "com.hierynomus", module = "smbj")
    }
    implementation("com.google.guava:guava:33.5.0-android")
    implementation("com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava")
    // 腾讯 Bugly 异常上报（国内直连）：crashreport 捕获 Java/Kotlin 崩溃与 ANR，
    // nativecrashreport 捕获 NDK 崩溃；Dart 层异常经 BuglyBridge 转发为非致命异常。
    implementation("com.tencent.bugly:crashreport:4.1.9.3")
    implementation("com.tencent.bugly:nativecrashreport:3.9.2")
    // xCrash：进程内 native 崩溃捕获，本地 tombstone 供无 USB 环境（云电脑）分析
    implementation("com.iqiyi.xcrash:xcrash-android-lib:3.1.0")
    // 原生 SSH/SFTP（JSch）：加解密走 Android JCE/OpenSSL 硬件加速，突破纯 Dart 加密速率上限
    //
    // 重要：官方 com.jcraft:jsch 停在 0.1.55（2018-11），既不支持 rsa-sha2-256/512，
    // 也不支持 ED25519 与 OpenSSH-v1 私钥格式；而 OpenSSH 8.8+ 已默认禁用
    // ssh-rsa(SHA-1)。结果是对较新服务器握手失败（Algorithm negotiation fail /
    // Auth fail / invalid privatekey），connect() 抛异常后静默回退 dartssh2
    // （纯 Dart 加密，约 2MB/s 天花板）——这正是「部分用户 SFTP 上传只有 2MB/s」的根因。
    //
    // 改用社区维护分支 mwiede/jsch：它保留 com.jcraft.jsch 包名与全部 API，
    // 是 drop-in 替换，并已适配新算法协议（rsa-sha2-*、ed25519、curve25519、
    // OpenSSH-v1 私钥）。注意该分支默认禁用 ssh-rsa，故 SshSftpService.connect
    // 里显式把新旧算法一并列入，以兼容老服务器（见 SshSftpService 注释）。
    implementation("com.github.mwiede:jsch:2.28.7")
    // 聚合网盘（夸克 / 阿里）的兜底网络栈 Cronet：本轮**故意不引入**，只留说明。
    // 兜底逻辑本身仍在（lib/services/remote/netdisk/netdisk_http.dart），会自行
    // 探测失败并永久停在 dart:io，属于安全的空转。
    //
    // ⚠️ 为什么不引：2026-09-30 实测在 **AGP 9.1.1** 下引入必构建失败
    //
    //   > Task :app:processReleaseMainManifest FAILED
    //   Namespace 'org.chromium.net' is used in multiple modules and/or libraries:
    //   org.chromium.net:cronet-embedded:113.5672.61,
    //   org.chromium.net:cronet-common:113.5672.61,
    //   org.chromium.net:cronet-api:113.5672.61
    //
    // 根因：这三个 AAR 的 AndroidManifest 都写着 package="org.chromium.net"；
    // AGP 8+ 由该属性推导 library 的 namespace，三者撞名 ⇒ 清单合并的
    // namespace 唯一性校验直接判失败。而且三者**缺一不可**（已实测类集合互补：
    //  - cronet-api      49 个顶层类：CronetEngine / CronetEngine.Builder /
    //                    UrlRequest / CronetProvider（纯 API，无实现）
    //  - cronet-common   3 个顶层类：CronetEngineBase / CronetEngineBuilderImpl
    //  - cronet-embedded 88 个顶层类：NativeCronetProvider 等 + 4 个 ABI 的
    //                    libcronet.113.0.5672.61.so
    // 且 cronet-embedded 的 POM 又传递依赖 cronet-common）⇒ 不存在「只留一个」的绕法。
    // 上游在 **143.7445.0** 才给这批 AAR 分配互不相同的 namespace（该版本在
    // Google Maven 上已核实可用）。
    //
    // 另外 cronet_http 插件（钉 1.3.0）自带的开关
    //   --dart-define=cronetHttpNoPlay=true   （见插件 android/build.gradle:79）
    // 只是把依赖换成 cronet-embedded:113.5672.61 —— 同一版本、同样撞名，
    // 在 AGP 9 上一样构建失败，故该开关在本项目同样不可用。
    //
    // 结论：先让真机验证 dart:io 是否能直连夸克/阿里（对照实现「文析助手」在同机型上
    // 就是纯 dart:io 且工作正常）。若确被掐断，再把 cronet-* 抬到 143.7445.0 重评。
}
