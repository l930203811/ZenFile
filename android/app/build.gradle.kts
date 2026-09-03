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
        applicationId = "com.sequl.zenfile"
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
    implementation("com.hierynomus:smbj:0.13.0")
    implementation("com.rapid7.client:dcerpc:0.12.13") {
        exclude(group = "com.google.guava", module = "guava")
        exclude(group = "com.hierynomus", module = "smbj")
    }
    implementation("com.google.guava:guava:33.5.0-android")
    implementation("com.google.guava:listenablefuture:9999.0-empty-to-avoid-conflict-with-guava")
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
}
