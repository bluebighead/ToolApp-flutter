# Flutter 引擎与插件基类保留规则
# 这些是所有 Flutter 插件通用的保留规则，防止 R8/ProGuard 在 release 模式下
# 误删插件注册类或平台通道处理代码，进而导致 MissingPluginException

# 保留 Flutter 引擎核心类
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 保留 AndroidX Lifecycle 组件（Flutter 插件依赖）
-keep class androidx.lifecycle.** { *; }
-keepclassmembernames class androidx.lifecycle.* { *; }
-keepclassmembers class * implements androidx.lifecycle.LifecycleObserver {
    <init>(...);
}
-keepclassmembers class * extends androidx.lifecycle.ViewModel {
    <init>(...);
}
-keepclassmembers class androidx.lifecycle.Lifecycle$State { *; }
-keepclassmembers class androidx.lifecycle.Lifecycle$Event { *; }
-keepclassmembers class * {
    @androidx.lifecycle.OnLifecycleEvent *;
}

# 文件选择器（file_picker）插件
# 防止 com.mr.flutter.plugin.filepicker.FilePickerPlugin 被裁剪
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keepclassmembernames class com.mr.flutter.plugin.filepicker.** { *; }

# FFmpeg 视频转换插件（ffmpeg_kit_flutter_new）
# 该插件含 JNI 桥接层，必须保留 native 方法与注册逻辑
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keepclassmembernames class com.antonkarpenko.ffmpegkit.** { *; }
-keep class com.arthenica.** { *; }
-keepclassmembernames class com.arthenica.** { *; }

# 麦克风/分贝测试（audio_streamer）插件
-keep class com.lukaspallas.audio_streamer.** { *; }
-keepclassmembernames class com.lukaspallas.audio_streamer.** { *; }
-keep class net.no_mad.tts.** { *; }

# 权限请求（permission_handler_android）插件
-keep class com.baseflow.permissionhandler.** { *; }
-keepclassmembernames class com.baseflow.permissionhandler.** { *; }

# SharedPreferences（shared_preferences_android）插件
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keepclassmembernames class io.flutter.plugins.sharedpreferences.** { *; }

# JNI 桥接插件（ffmpeg_kit_flutter_new 的间接依赖）
-keep class com.github.dart_lang.jni.** { *; }
-keepclassmembernames class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }
-keepclassmembernames class com.github.dart_lang.jni_flutter.** { *; }

# 通用：保留所有带 native 方法的类及其方法（FFmpeg JNI 桥接所需）
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# 通用：保留所有枚举类的 values()/valueOf() 方法（部分插件反射使用）
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# 通用：保留 Parcelable 序列化所需的 CREATOR 字段
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# 忽略 Google Play Core 拆分组件相关类的告警
# Flutter 引擎引用了这些类，但仅在启用 deferred components 时才真正使用
# 当前项目未启用该特性，因此 -dontwarn 即可，不会影响功能
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# MainActivity 与 SAF 助手（com.example.toolapp.MainActivity）
# 自定义 MethodChannel 处理 SAF tree URI 复制 M3U8 整棵子树
# 必须保留 MainActivity 类名与 configureFlutterEngine 方法
# 否则 R8 混淆后 Flutter 端 invokeMethod 会抛 MissingPluginException
-keep class com.example.toolapp.MainActivity { *; }
-keepclassmembers class com.example.toolapp.MainActivity {
    public *;
    private *;
}

# AndroidX FileProvider（用于"打开视频"功能，把 App 私有目录文件以 content:// 暴露给系统播放器/文件管理器）
# 保留 androidx.core.content.FileProvider 类与 androidx.core 核心包，
# 防止 R8 混淆后 FileProvider.getUriForFile 调用失败导致 FileUriExposedException
-keep class androidx.core.content.FileProvider { *; }
-keep class androidx.core.** { *; }
-keepclassmembers class * extends androidx.core.content.FileProvider {
    public *;
}
