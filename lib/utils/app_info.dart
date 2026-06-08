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
  static const String version = '1.6.58';

  // 当前构建号（整数，每次发版递增）
  // 每次发版时同步更新 pubspec.yaml 中 version 字段的 + 号后的数字
  static const int buildNumber = 86;

  // 开发者署名
  static const String developer = 'SuperYH';

  // 最近一次发版的更新时间（格式：yyyy-MM-dd）
  // 每次发版时必须更新到当天日期
  static const String lastUpdate = '2026-06-09';

  // 完整版本字符串，UI 上直接显示使用
  static String get fullVersion => '$version (Build $buildNumber)';

  // 应用一句话简介
  static const String description = '一款轻量、好用的工具集合 App';

  // 版权信息
  static const String copyright = '© 2026 SuperYH. All rights reserved.';
}
