allprojects {
    repositories {
        // Flutter engine 的 jar 合计约 430MB，官方源 storage.googleapis.com 在本机实测
        // 只有 ~40KB/s，会让构建卡十几分钟甚至看上去像卡死。这里把 io.flutter 这一组
        // 独占锁到本地离线仓库，彻底绕开网络。
        //
        // 注意：这段必须放在根工程的 allprojects 里，不能只写在 :app。
        // 插件子工程（android_file_picker / sqflite_android / shared_preferences_android …）
        // 也会解析 io.flutter:flutter_embedding_<variant>，它们不带这段就会跑去官方源。
        exclusiveContent {
            forRepository {
                maven { url = uri("file:///E:/AndroidDev/local-maven") }
            }
            filter { includeGroup("io.flutter") }
        }

        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
