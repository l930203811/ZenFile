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
