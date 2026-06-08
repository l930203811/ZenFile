allprojects {
    repositories {
        maven { url = uri("C:/Users/admin/flutter-maven-repo") }
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
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
    if (project.name == "media_kit_libs_android_video") {
        project.afterEvaluate {
            // Disable the downloadDependencies task that tries to download all ABI jars from GitHub
            project.tasks.matching { it.name == "downloadDependencies" }.configureEach {
                enabled = false
            }
            // Copy the arm64-v8a jar into the output dir (jar is already in root build dir)
            val copyJarTask = project.tasks.register("copyMediaKitJar") {
                doLast {
                    val outputDir = project.file("${project.buildDir}/output")
                    outputDir.mkdirs()
                    val arm64Jar = project.rootProject.file("build/media_kit_libs_android_video/v1.1.7/default-arm64-v8a.jar")
                    if (arm64Jar.exists()) {
                        arm64Jar.copyTo(project.file("${outputDir}/default-arm64-v8a.jar"), true)
                        println("Copied arm64-v8a jar (${arm64Jar.length()} bytes) to output dir")
                    } else {
                        throw GradleException("arm64-v8a jar not found at ${arm64Jar.absolutePath}")
                    }
                }
            }
            project.tasks.matching { it.name == "assemble" }.configureEach {
                dependsOn(copyJarTask)
            }
        }
    }
    if (project.name != "app") {
        project.afterEvaluate {
            project.plugins.withId("com.android.library") {
                project.extensions.configure<com.android.build.gradle.LibraryExtension> {
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
