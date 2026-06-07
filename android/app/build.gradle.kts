plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.toolapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // 启用核心库脱糖：flutter_local_notifications 17.x 需要 java.time 等 Java 8+ API
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.toolapp"
        // 设置最低 Android SDK 版本为 24（Android 7.0），满足 ffmpeg_kit_flutter_new 插件要求
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // 启用 R8/ProGuard 混淆优化：减小 APK 体积、优化性能
            // 配套 proguard-rules.pro 中已添加对所有插件类的 keep 规则，
            // 防止 R8 误删平台通道相关代码而出现 MissingPluginException
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            // 调试包禁用混淆，便于堆栈跟踪与排错
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

// 显式声明 androidx.documentfile 依赖，供 MainActivity.kt 解析 SAF tree URI 使用
// 用于"选择 M3U8 文件夹"功能时把整棵目录树复制到沙盒
dependencies {
    implementation("androidx.documentfile:documentfile:1.0.1")
    // 核心库脱糖运行时：把 java.time / java.util.concurrent.* 等高版本 API 编译进 APK
    // 供 flutter_local_notifications 在 Android 7.0-9.0（API 24-28）上正常运行
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
