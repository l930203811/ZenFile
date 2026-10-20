allprojects {
    repositories {
        maven { url = uri("C:/Users/admin/flutter-maven-repo") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// flutter_avif_android 3.1.0 上游打包缺陷（pub 上已是最新版，无升级空间）：
// 同一个 com.teknorota.flutter_avif.FlutterAvifPlugin 被打包了两份完全相同的实现——
//   android/src/main/java/com/teknorota/flutter_avif/FlutterAvifPlugin.java
//   android/src/main/kotlin/com/teknorota/flutter_avif/FlutterAvifPlugin.kt
// 旧版 AGP 会静默忽略多余的 Java 文件；AGP 8.9+ 起两个源集都会被编译，Kotlin 侧直接报
// "Redeclaration: class FlutterAvifPlugin" 导致 `flutter build apk` 失败（本项目 AGP 9.1.1 必踩）。
// 这里把 Java 源集收敛为只剩 src/main/kotlin：保留 pluginClass 实际注册的 Kotlin 实现，
// 丢弃多余的 Java 副本。两者是同一个 getPlatformVersion 桩，AVIF 解码走原生 Rust 库、
// 不经过它们，行为完全不变。上游修复后整块删除。
subprojects {
    if (project.name == "flutter_avif_android") {
        project.plugins.withId("com.android.library") {
            project.extensions.configure<com.android.build.gradle.LibraryExtension> {
                sourceSets.getByName("main") {
                    java.setSrcDirs(listOf("src/main/kotlin"))
                }
            }
        }
    }
}

subprojects {
    if (project.name != "app") {
        project.plugins.withId("com.android.library") {
            project.extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 37
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        project.afterEvaluate {
            project.plugins.withId("com.android.library") {
                project.extensions.configure<com.android.build.gradle.LibraryExtension> {
                    // AGP 9：部分插件（如 flutter_avif_android 硬编码 compileSdkVersion 31）会在
                    // withId 回调之后覆盖 compileSdk，需在 afterEvaluate 阶段最终强制为 37
                    //（与 app 一致，同时满足 permission_handler_android 需要的 API 37 常量）。
                    compileSdk = 37
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
            // 双保险：即便上面的源集收敛被后续插件覆盖，也确保 javac / kotlinc 都不会
            // 看到那个多余的 FlutterAvifPlugin.java，从编译入口根除 Redeclaration。
            if (project.name == "flutter_avif_android") {
                project.tasks.withType<JavaCompile>().configureEach {
                    exclude("**/FlutterAvifPlugin.java")
                }
                project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                    exclude("**/FlutterAvifPlugin.java")
                }
            }
            project.tasks.withType<JavaCompile>().configureEach {
                sourceCompatibility = "17"
                targetCompatibility = "17"
            }
            project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
