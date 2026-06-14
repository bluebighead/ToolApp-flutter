// 应用信息常量
// 集中存放应用名称、版本、开发者、更新时间等元数据。
// 版本号规则见 PROJECT_RULES.md：每次发版必须同步更新 pubspec.yaml 与本文件。
class AppInfo {
  // 应用名称（与 pubspec.yaml 的 name 字段保持一致概念）
  static const String appName = '实用工具箱';

  // 应用包名（与 pubspec.yaml 的 name 字段保持一致）
  static const String packageName = 'toolapp';

  // 当前版本号（遵循 PROJECT_RULES.md 中的语义化版本规则）
  // 每次发版时同步更新 pubspec.yaml 中的 version 字段
  // v1.6.36+ 升级说明（bug22 修复：续转卡在FFmpeg启动中、暂停按钮状态优化）：
  //   - convert_coordinator.dart 的 resume() 方法中，不再传 onSessionStarting 回调，
  //     避免续转时 UI 进入"FFmpeg 启动中..."状态并卡住。续转期间 UI 保持显示
  //     "正在恢复转换..."直到 FFmpeg 出第一帧，然后切到"正在转换..."
  //   - video_convert_page.dart 的 _onCoordinatorEvent 中，_resuming 只在
  //     hasDuration=true 时才复位，确保"正在恢复转换..."一直显示到真正开始转换
  //   - video_convert_page.dart 的 _buildActionButtons 中，续转准备期间
  //     （_ffmpegSessionStarting 或 _resuming 为 true）暂停按钮不可点击，
  //     取消按钮随时可用
  //   - video_convert_page.dart 的 _syncFromCoordinatorSnapshot 中，状态切到
  //     paused 时复位 _resuming 和 _ffmpegSessionStarting 标志位
  // v1.6.55+ 升级说明（多项优化 + bug修复）：
  //   - 批量转换详情弹窗新增加速模式信息
  //   - 转换进行中锁定视频输出设置（加速模式、保存位置、并行数量），防止参数突变
  //   - 重做批量转换多选模式：进入多选后可全选/批量暂停/批量取消/批量删除
  //   - 移除正常模式下的"全部取消"按钮，改为多选模式下操作
  //   - 历史记录删除优化：询问仅删除记录还是同时删除输出文件
  //   - 修复设置界面"更换默认打开方式"：改用原生Intent选择器弹出播放器列表
  // v1.6.56+ 升级说明（质量预估优化 + 存储管理）：
  //   - 输出格式切换时质量预估随格式变化（MP4/MKV/MOV 压缩率不同）
  //   - 设置界面新增存储空间管理卡片：用户数据/视频输出/日志/缓存占用显示
  //   - 一键清理缓存按钮
  //   - 一键清理用户数据按钮（清理视频输出/日志/缓存，保留配置）
  // v1.6.57+ 升级说明（bug修复）：
  //   - 修复历史记录删除输出文件时SAF目录文件未被删除的bug
  //     原因：SAF模式下文件被复制到自定义目录，但删除只删了沙盒路径
  //     修复：删除时同时删除沙盒文件和SAF自定义目录中的文件
  // v1.6.58+ 升级说明（稳定性修复 + 安全加固）：
  //   - 修复批量转换多并行时暂停/取消操作错误FFmpeg实例的严重bug
  //     原因：_getActiveFfmpegForTask()始终返回列表第一个实例
  //     修复：维护任务索引到FFmpegService的映射表
  //   - 修复批量转换cancel()遍历列表时ConcurrentModificationError
  //     原因：await期间_runTask的finally块修改_activeFfmpegServices
  //     修复：先复制列表再遍历
  //   - 修复批量转换不管理前台服务导致后台被杀
  //     修复：start()启动前台服务，完成/取消时停止
  //   - 修复批量转换cancel()不停止前台服务导致通知栏残留
  //   - 修复信号量release()无下溢保护导致信号量失效
  //   - 修复批量转换输入文件不存在时显示FFmpeg原始错误
  //     修复：提前检查并返回清晰错误信息
  //   - 修复通知栏"停止"按钮只停前台服务不取消FFmpeg
  //     修复：Kotlin端通过MethodChannel回调通知Dart端取消
  //   - 修复ffmpeg_service.dart中未使用的局部变量warning
  // v1.7.0+ 升级说明（新增心率广播接收器功能）：
  //   - 新增心率广播接收器页面，支持BLE蓝牙低功耗和WiFi UDP两种连接方式
  //   - 支持数字显示、折线图、组合三种显示模式
  //   - BLE支持标准心率设备（Heart Rate Service UUID: 0x180D）
  //   - UDP支持端口8888接收心率数据
  // v1.7.1+ 升级说明（Bug修复）：
  //   - 修复BLE连接缺少bluetoothConnect权限（Android 12+连接必失败）
  //   - 修复BLE连接失败后UI状态不一致（_isScanning卡在true）
  //   - 修复UDP模式重复启动时旧实例未释放导致内存泄漏
  //   - 修复BLE扫描重复设备未更新RSSI
  //   - 修复UDP socket监听订阅未保存
  //   - 修复图表X轴滑动窗口冗余逻辑
  // v1.7.2+ 升级说明（设备连接记忆功能）：
  //   - 新增BLE设备连接记忆功能，首次连接成功后自动保存
  //   - 下次打开页面自动扫描并连接记忆设备
  //   - 设备未开机时持续扫描等待，设备出现后自动连接
  //   - 用户手动选择其他设备时自动更新记忆
  //   - 设备列表中标记"上次连接"的设备
  // v1.7.3+ 升级说明（UI优化）：
  //   - 心率页面顶部切换按钮改为下拉框形式，更加直观精准
  //   - AppBar右上角新增使用说明按钮，引导用户使用工具
  //   - 移除不再使用的切换按钮和冗余文字方法
  // v1.7.5+ 升级说明（Bug修复）：
  //   - 修复BLE断开连接后自动重连Bug（_isAutoConnecting标记+取消自动连接订阅）
  //   - 修复disconnect()未取消_autoConnectSubscription导致监听器泄漏
  //   - 修复connectToDevice()未终止自动连接流程导致重复触发
  // v1.7.6+ 升级说明（体验优化）：
  //   - 断开连接后心率显示归零，历史数据清空
  // v1.7.9+ 升级说明（Bug修复 - 存储空间统计与清理）：
  //   - 修复用户数据统计范围不完整，只统计了ToolApp/而非整个Documents/目录
  //   - 修复缓存统计遗漏了cache/目录（M3U8临时文件主要存放位置）
  //   - 修复清理用户数据时未清理Documents/下的断点续转状态文件
  //   - 修复清理用户数据时未清理cache/下的M3U8临时目录（7GB+占用的根因）
  //   - 修复心率历史记录多选模式下全选按钮不支持切换取消全选
  // v1.8.0+ 升级说明（游客模式）：
  //   - 登录页新增"以游客身份继续"按钮，无需注册/登录即可使用全部功能
  //   - 游客模式下数据仅保存在本地，登录后自动同步到服务器
  //   - 首页抽屉区分游客/已登录状态，游客模式下显示"登录账号"入口
  //   - 设置页账号与同步区域适配游客模式
  // v1.34.0+ 升级说明（JSON解析修复 + 设备参数自动上传）：
  //   - 增强经期记录和测速历史的 JSON 解析健壮性，损坏数据时自动清除并从备份恢复
  //   - 修复 FormatException: Unexpected character 导致的 App 异常
  //   - 设备参数上传增加 24 小时最小间隔和并发控制，避免频繁请求
  //   - App 启动后检测已有登录态时自动在后台上传设备参数
  //   - PC 管理端"用户设备参数"对话框正常显示数据
  // v1.51.0+ 升级说明（Bug修复 + 新增工具）：
  //   - 修复指纹检测 FragmentActivity 错误，MainActivity 改用 FlutterFragmentActivity
  //   - 修复麦克风检测波形异常（99% 音量）和录音无效问题
  //   - 修复安装包免压查看器点击大文件卡死问题（增加1MB预览限制）
  //   - 修复设置页存储空间显示异常大数字（字节格式化计算错误）
  //   - 管理员密码默认改为 666666
  //   - 新增电子元件计算工具（色环电阻/贴片电阻/电容换算/电感色码）
  //   - 新增转盘抽奖工具（自定义转盘/旋转动画/概率设置/历史记录）
  //   - 新增计分板小工具（全屏加减分/长按连续加减）
  // v1.52.13+ 升级说明（Bug修复 - AI输入框键盘弹出位置异常）：
  //   - 彻底修复键盘弹出时输入框飞出屏幕的问题
  //   - 根因：OverlayEntry 内手动计算键盘高度定位不可靠，不同设备/键盘高度下表现不一致
  //   - 修复：废弃 OverlayEntry 自定义输入面板，改用 showModalBottomSheet
  //   - showModalBottomSheet 自动处理键盘避让、Material上下文、动画，无需手动计算
  //   - 代码从 218 行精简到 168 行，删除整个 _AiInputSheet 类
  static const String version = '1.52.14';

  // 当前构建号（整数，每次发版递增）
  // 每次发版时同步更新 pubspec.yaml 中 version 字段的 + 号后的数字
  static const int buildNumber = 195;

  // 开发者署名
  static const String developer = 'SuperYH';

  // 最近一次发版的更新时间（格式：yyyy-MM-dd）
  // 每次发版时必须更新到当天日期
  static const String lastUpdate = '2026-06-14';

  // 完整版本字符串，UI 上直接显示使用
  static String get fullVersion => '$version (Build $buildNumber)';

  // APK 文件名（与服务器端 downloads/ 目录中的文件名保持一致）
  // 格式：toolapp-<version>-release.apk
  static String get apkFileName => 'toolapp-$version-release.apk';

  // 应用一句话简介
  static const String description = '一款轻量、好用的工具集合 App';

  // 版权信息
  static const String copyright = '© 2026 SuperYH. All rights reserved.';
}
