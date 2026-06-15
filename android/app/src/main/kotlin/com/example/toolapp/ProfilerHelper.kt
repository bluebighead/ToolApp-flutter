package com.example.toolapp

import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.SystemClock
import android.net.TrafficStats
import android.provider.Settings
import android.util.Log
import java.io.File
import java.io.RandomAccessFile

/**
 * Android Profiler 原生数据采集工具类
 *
 * 提供 CPU、内存、网络、电量、进程排行等数据的采集方法，
 * 通过 MethodChannel 暴露给 Dart 层使用。
 *
 * 高版本兼容策略：
 * - 进程 CPU 占用：低版本读 /proc/<pid>/stat，高版本使用 UsageStatsManager
 * - 系统总 CPU：低版本读 /proc/stat，高版本通过 ActivityManager 概要 + 自身进程计算
 * - 进程内存：ActivityManager.getProcessMemoryInfo() + UsageStatsManager
 */
class ProfilerHelper(private val context: Context) {

    companion object {
        private const val TAG = "ProfilerHelper"
    }

    // ==================== CPU 相关 ====================

    /**
     * 获取 CPU 信息
     * 返回 Map：
     *   - totalUsage: double (0-100) 总 CPU 使用率
     *   - coreCount: int CPU 核心数
     *   - coreFreqs: List<int> 每核频率 MHz
     *   - temperature: double CPU 温度 ℃
     *   - appCpuUsage: double (0-100) 本 App 的 CPU 使用率
     */
    fun getCpuInfo(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()

        // CPU 核心数
        val coreCount = Runtime.getRuntime().availableProcessors()
        result["coreCount"] = coreCount

        // 每核频率（读取 sysfs）
        val coreFreqs = mutableListOf<Int>()
        for (i in 0 until coreCount) {
            val freqFile = File("/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq")
            if (freqFile.exists()) {
                try {
                    val freq = freqFile.readText().trim().toIntOrNull() ?: 0
                    coreFreqs.add(freq / 1000) // kHz -> MHz
                } catch (e: Exception) {
                    coreFreqs.add(0)
                }
            } else {
                coreFreqs.add(0)
            }
        }
        result["coreFreqs"] = coreFreqs

        // CPU 温度（尝试多个热区路径）
        result["temperature"] = readCpuTemperature()

        // 总 CPU 使用率（通过 /proc/stat 计算）
        result["totalUsage"] = calculateTotalCpuUsage()

        // 本 App CPU 使用率（通过 /proc/self/stat 计算）
        result["appCpuUsage"] = calculateAppCpuUsage()

        return result
    }

    /** 读取 CPU 温度，尝试多个热区路径 */
    private fun readCpuTemperature(): Double {
        val tempPaths = listOf(
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
            "/sys/class/hwmon/hwmon0/temp1_input",
        )
        for (path in tempPaths) {
            try {
                val file = File(path)
                if (file.exists()) {
                    val raw = file.readText().trim().toIntOrNull() ?: continue
                    // 大多数路径返回毫度（如 38000 = 38℃），部分返回度
                    return if (raw > 1000) raw / 1000.0 else raw.toDouble()
                }
            } catch (_: Exception) {}
        }
        return 0.0
    }

    // 上次 /proc/stat 采样的时间与数值
    private var lastStatIdle: Long = -1
    private var lastStatTotal: Long = -1

    /** 通过 /proc/stat 计算总 CPU 使用率，Android 12+ 受限时使用 fallback */
    private fun calculateTotalCpuUsage(): Double {
        // 方式1：尝试读 /proc/stat（Android 11 及以下可用）
        val procStatResult = calculateTotalCpuFromProcStat()
        if (procStatResult != null) return procStatResult

        // 方式2：fallback — 通过 /proc/self/stat 的总 CPU 时间 + 系统运行时间估算
        return calculateTotalCpuFallback()
    }

    /** 从 /proc/stat 计算总 CPU 使用率 */
    private fun calculateTotalCpuFromProcStat(): Double? {
        return try {
            val stat = RandomAccessFile("/proc/stat", "r")
            val line = stat.readLine()
            stat.close()

            val parts = line.split("\\s+".toRegex())
            // user nice system idle iowait irq softirq steal guest guest_nice
            val idle = parts[4].toLong()
            val total = parts.subList(1, 8).sumOf { it.toLong() }

            // 首次采样只记录基线，不返回值
            if (lastStatIdle < 0) {
                lastStatIdle = idle
                lastStatTotal = total
                return null // 首次无法计算差值，走 fallback
            }

            val diffIdle = idle - lastStatIdle
            val diffTotal = total - lastStatTotal
            lastStatIdle = idle
            lastStatTotal = total

            if (diffTotal == 0L) 0.0
            else ((diffTotal - diffIdle).toDouble() / diffTotal.toDouble() * 100.0)
                .coerceIn(0.0, 100.0)
        } catch (e: Exception) {
            Log.w(TAG, "读取 /proc/stat 失败（Android 12+ 受限）: ${e.message}")
            null
        }
    }

    // fallback：上次采样的 appCpuTime 和时间戳
    private var lastFallbackCpuTime: Long = -1
    private var lastFallbackTimestamp: Long = -1

    /**
     * Fallback 方案：通过本 App 的 CPU 时间占比 + 系统负载估算总 CPU
     * 原理：appCpuTime / elapsed = appCpuRatio，结合核心数估算总使用率
     */
    private fun calculateTotalCpuFallback(): Double {
        return try {
            val stat = RandomAccessFile("/proc/self/stat", "r")
            val line = stat.readLine()
            stat.close()

            val parts = line.split("\\s+".toRegex())
            val utime = parts[13].toLong()
            val stime = parts[14].toLong()
            val cutime = parts[15].toLong()
            val cstime = parts[16].toLong()
            val appCpuTime = utime + stime + cutime + cstime

            val now = SystemClock.elapsedRealtime()

            if (lastFallbackCpuTime < 0) {
                lastFallbackCpuTime = appCpuTime
                lastFallbackTimestamp = now
                return 0.0
            }

            val elapsed = now - lastFallbackTimestamp
            val diffCpu = appCpuTime - lastFallbackCpuTime
            lastFallbackCpuTime = appCpuTime
            lastFallbackTimestamp = now

            if (elapsed <= 0) return 0.0

            val ticksPerSec = 100L // Android 标准值 CLK_TCK=100
            val coreCount = Runtime.getRuntime().availableProcessors()

            // App CPU 使用率
            val appCpuPercent = (diffCpu.toDouble() / ticksPerSec / (elapsed / 1000.0) * 100.0)
                .coerceIn(0.0, 100.0)

            // 估算总 CPU：appCpuPercent / coreCount 是单核占比，
            // 假设其他核心也有类似负载，乘以一个经验系数（通常 2-3 倍）
            // 使用系统负载平均值来修正
            val loadAvg = readLoadAvg()
            val estimatedTotal = if (loadAvg > 0) {
                // loadAvg 是 1 分钟平均负载，直接乘以 100/coreCount 转为百分比
                (loadAvg / coreCount.toDouble() * 100.0).coerceIn(0.0, 100.0)
            } else {
                // 无负载信息时，用 app CPU 乘以经验系数
                (appCpuPercent * 3.0).coerceIn(0.0, 100.0)
            }

            estimatedTotal
        } catch (e: Exception) {
            Log.w(TAG, "Fallback CPU 计算失败: ${e.message}")
            0.0
        }
    }

    /** 读取系统负载平均值 /proc/loadavg */
    private fun readLoadAvg(): Double {
        return try {
            val content = File("/proc/loadavg").readText().trim()
            // 格式: 1.23 0.89 0.67 2/543 12345
            content.split("\\s+".toRegex())[0].toDouble()
        } catch (_: Exception) {
            0.0
        }
    }

    // 上次 /proc/self/stat 采样的时间与数值
    private var lastAppCpuTime: Long = -1
    private var lastAppTimeStamp: Long = -1

    /** 通过 /proc/self/stat 计算本 App CPU 使用率 */
    private fun calculateAppCpuUsage(): Double {
        return try {
            val stat = RandomAccessFile("/proc/self/stat", "r")
            val line = stat.readLine()
            stat.close()

            val parts = line.split("\\s+".toRegex())
            // utime=parts[13], stime=parts[14], cutime=parts[15], cstime=parts[16]
            val utime = parts[13].toLong()
            val stime = parts[14].toLong()
            val cutime = parts[15].toLong()
            val cstime = parts[16].toLong()
            val appCpuTime = utime + stime + cutime + cstime

            val now = SystemClock.elapsedRealtime()

            // 首次采样只记录基线
            if (lastAppCpuTime < 0) {
                lastAppCpuTime = appCpuTime
                lastAppTimeStamp = now
                return 0.0
            }

            val elapsed = now - lastAppTimeStamp
            val diffCpu = appCpuTime - lastAppCpuTime

            lastAppCpuTime = appCpuTime
            lastAppTimeStamp = now

            if (elapsed <= 0) return 0.0

            // Android 标准 CLK_TCK = 100
            val ticksPerSec = 100L
            // CPU时间(秒) = ticks / CLK_TCK
            // CPU使用率 = CPU时间 / 经过时间 * 100
            val coreCount = Runtime.getRuntime().availableProcessors()
            val cpuSeconds = diffCpu.toDouble() / ticksPerSec.toDouble()
            val elapsedSeconds = elapsed / 1000.0
            // 使用率 = cpuSeconds / (elapsedSeconds * coreCount) * 100
            // 这样可以得到 0-100% 的值（相对于所有核心）
            val usage = (cpuSeconds / elapsedSeconds / coreCount * 100.0)
                .coerceIn(0.0, 100.0)
            usage
        } catch (e: Exception) {
            Log.w(TAG, "读取 /proc/self/stat 失败: ${e.message}")
            0.0
        }
    }

    // ==================== 内存相关 ====================

    /**
     * 获取内存信息
     * 返回 Map：
     *   - totalMb: int 总内存 MB
     *   - availableMb: int 可用内存 MB
     *   - usedMb: int 已用内存 MB
     *   - appUsedMb: int 本 App 内存占用 MB
     *   - pressureLevel: String (low/medium/high) 内存压力等级
     */
    fun getMemoryInfo(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

        // 系统内存信息
        val memInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(memInfo)

        val totalMb = memInfo.totalMem / (1024 * 1024)
        val availableMb = memInfo.availMem / (1024 * 1024)
        val usedMb = totalMb - availableMb

        result["totalMb"] = totalMb.toInt()
        result["availableMb"] = availableMb.toInt()
        result["usedMb"] = usedMb.toInt()

        // 本 App 内存占用
        val pids = intArrayOf(android.os.Process.myPid())
        val memInfos = am.getProcessMemoryInfo(pids)
        if (memInfos.isNotEmpty()) {
            // getTotalPss() 返回 KB
            result["appUsedMb"] = memInfos[0].totalPss / 1024
        } else {
            result["appUsedMb"] = 0
        }

        // 内存压力等级
        result["pressureLevel"] = when {
            availableMb <= (memInfo.threshold / (1024 * 1024)) -> "high"
            availableMb < totalMb * 0.2 -> "medium"
            else -> "low"
        }

        return result
    }

    // ==================== 网络相关 ====================

    // 上次网络流量采样值
    private var lastRxBytes: Long = 0
    private var lastTxBytes: Long = 0
    private var lastNetTimestamp: Long = 0

    /**
     * 获取网络信息
     * 返回 Map：
     *   - downloadSpeedKbps: double 下行速率 Kbps
     *   - uploadSpeedKbps: double 上行速率 Kbps
     *   - totalDownloadKb: int 累计下载 KB
     *   - totalUploadKb: int 累计上传 KB
     *   - networkType: String (WiFi/Mobile/None) 网络类型
     */
    fun getNetworkInfo(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()

        // 当前流量
        val rxBytes = TrafficStats.getTotalRxBytes()
        val txBytes = TrafficStats.getTotalTxBytes()
        val now = System.currentTimeMillis()

        // 计算速率
        if (lastNetTimestamp > 0 && rxBytes >= 0 && lastRxBytes >= 0) {
            val elapsed = (now - lastNetTimestamp) / 1000.0 // 秒
            if (elapsed > 0) {
                val rxDiff = rxBytes - lastRxBytes
                val txDiff = txBytes - lastTxBytes
                result["downloadSpeedKbps"] = (rxDiff * 8.0 / 1000.0 / elapsed)
                result["uploadSpeedKbps"] = (txDiff * 8.0 / 1000.0 / elapsed)
            } else {
                result["downloadSpeedKbps"] = 0.0
                result["uploadSpeedKbps"] = 0.0
            }
        } else {
            result["downloadSpeedKbps"] = 0.0
            result["uploadSpeedKbps"] = 0.0
        }

        lastRxBytes = rxBytes
        lastTxBytes = txBytes
        lastNetTimestamp = now

        // 累计流量
        result["totalDownloadKb"] = if (rxBytes >= 0) (rxBytes / 1024).toInt() else 0
        result["totalUploadKb"] = if (txBytes >= 0) (txBytes / 1024).toInt() else 0

        // 网络类型（通过 ConnectivityManager 判断）
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
        val activeNetwork = cm?.activeNetworkInfo
        result["networkType"] = when {
            activeNetwork == null || !activeNetwork.isConnected -> "None"
            activeNetwork.type == android.net.ConnectivityManager.TYPE_WIFI -> "WiFi"
            activeNetwork.type == android.net.ConnectivityManager.TYPE_MOBILE -> "Mobile"
            else -> "Other"
        }

        return result
    }

    // ==================== 电量相关 ====================

    /**
     * 获取电量信息
     * 返回 Map：
     *   - level: int (0-100) 电量百分比
     *   - isCharging: bool 是否充电
     *   - chargeType: String (AC/USB/Wireless/None) 充电类型
     *   - temperature: double 电池温度 ℃
     *   - voltage: int 电压 mV
     *   - currentMa: int 电流 mA（负值=放电）
     */
    fun getBatteryInfo(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager

        // 电量百分比
        result["level"] = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

        // 通过 sticky Intent 获取充电状态和充电类型（比 BatteryManager.isCharging 更可靠）
        val filter = android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = context.registerReceiver(null, filter)

        // 充电状态：通过 status 字段判断
        val status = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        val isCharging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                status == android.os.BatteryManager.BATTERY_STATUS_FULL
        result["isCharging"] = isCharging

        // 充电类型
        val plugged = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val chargeType = when (plugged) {
            android.os.BatteryManager.BATTERY_PLUGGED_AC -> "AC"
            android.os.BatteryManager.BATTERY_PLUGGED_USB -> "USB"
            android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
            else -> if (isCharging) "未知" else "未充电"
        }
        result["chargeType"] = chargeType

        // 电池温度（sticky Intent 中的温度，单位 0.1℃）
        val tempRaw = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0
        result["temperature"] = tempRaw / 10.0

        // 电压（mV）
        val voltageRaw = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_VOLTAGE, 0) ?: 0
        result["voltage"] = voltageRaw

        // 电流（mA，多策略获取）
        var currentMa = 0
        // 策略1：BatteryManager API
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val raw = bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            if (raw != 0L) {
                // 值单位为微安(μA)，转为毫安；部分机型返回负值表示放电
                currentMa = (raw / 1000).toInt()
            }
        }
        // 策略2：如果 API 返回 0，尝试读取 sysfs
        if (currentMa == 0) {
            currentMa = readBatteryCurrentFromSysfs()
        }
        result["currentMa"] = currentMa

        return result
    }

    /** 从 sysfs 读取电池电流（多种路径尝试） */
    private fun readBatteryCurrentFromSysfs(): Int {
        // 常见电流文件路径，不同厂商路径不同
        val currentPaths = listOf(
            "/sys/class/power_supply/battery/current_now",
            "/sys/class/power_supply/bms/current_now",
            "/sys/class/power_supply/battery/current_avg",
            "/sys/class/power_supply/max170xx_battery/current_now",
            "/sys/class/power_supply/sm5504_charger/current_now",
        )
        for (path in currentPaths) {
            try {
                val file = File(path)
                if (file.exists()) {
                    val raw = file.readText().trim().toLongOrNull() ?: continue
                    if (raw != 0L) {
                        // 大多数路径返回微安(μA)，转为毫安
                        return if (raw > 10000 || raw < -10000) {
                            (raw / 1000).toInt()
                        } else {
                            raw.toInt() // 部分设备直接返回 mA
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return 0
    }

    // ==================== 进程排行 ====================

    /**
     * 获取进程排行（需要 PACKAGE_USAGE_STATS 权限）
     * 返回 List<Map>：
     *   - packageName: String 包名
     *   - appName: String 应用名
     *   - cpuUsage: double CPU 占用 %
     *   - memoryMb: int 内存占用 MB
     *   - foregroundTime: int 前台时间秒
     */
    fun getProcessList(): List<Map<String, Any?>> {
        if (!isUsageStatsGranted()) {
            return emptyList()
        }

        val result = mutableListOf<Map<String, Any?>>()
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

        // 查询最近 1 小时的使用统计
        val endTime = System.currentTimeMillis()
        val startTime = endTime - 3600000
        val usageStats: List<android.app.usage.UsageStats> = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, startTime, endTime)

        // 按前台时间排序，取 Top 10
        val sorted = usageStats.sortedByDescending { stat -> stat.totalTimeInForeground }

        // 构建 包名 -> 内存MB 的映射（多策略获取）
        val packageMemMap = mutableMapOf<String, Int>()

        // 策略1：通过 /proc/<pid>/ 扫描所有进程，读取 cmdline 和 status
        try {
            val procDir = File("/proc")
            val pidDirs = procDir.listFiles()?.filter { it.isDirectory && it.name.toIntOrNull() != null }
            if (pidDirs != null) {
                val pidList = mutableListOf<Int>()
                val pidToPackage = mutableMapOf<Int, String>()

                for (pidDir in pidDirs) {
                    val pid = pidDir.name.toInt()
                    try {
                        // 读取 cmdline 获取包名
                        val cmdline = File(pidDir, "cmdline").readText().trim('\u0000', ' ')
                        if (cmdline.isNotEmpty()) {
                            pidToPackage[pid] = cmdline
                            pidList.add(pid)
                        }
                    } catch (_: Exception) {}
                }

                // 批量获取内存（通过 ActivityManager）
                if (pidList.isNotEmpty()) {
                    try {
                        val pidsArray = pidList.toIntArray()
                        val memInfos = am.getProcessMemoryInfo(pidsArray)
                        for (i in memInfos.indices) {
                            val pkg = pidToPackage[pidList[i]] ?: continue
                            val memMb = memInfos[i].totalPss / 1024
                            if (memMb > 0) {
                                val existing = packageMemMap[pkg] ?: 0
                                if (memMb > existing) packageMemMap[pkg] = memMb
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "getProcessMemoryInfo 批量获取失败: ${e.message}")
                    }
                }

                // 策略1补充：对于 getProcessMemoryInfo 返回 0 的进程，尝试从 /proc/<pid>/status 读取 VmRSS
                for ((pid, pkg) in pidToPackage) {
                    if ((packageMemMap[pkg] ?: 0) > 0) continue
                    try {
                        val statusFile = File("/proc/$pid/status")
                        if (statusFile.exists()) {
                            val lines = statusFile.readLines()
                            for (line in lines) {
                                if (line.startsWith("VmRSS:")) {
                                    // VmRSS 格式: "VmRSS:    12345 kB"
                                    val kb = line.substringAfter("VmRSS:").trim()
                                        .substringBefore(" ").toIntOrNull()
                                    if (kb != null && kb > 0) {
                                        val memMb = kb / 1024
                                        if (memMb > 0) {
                                            val existing = packageMemMap[pkg] ?: 0
                                            if (memMb > existing) packageMemMap[pkg] = memMb
                                        }
                                    }
                                    break
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "扫描 /proc 获取进程内存失败: ${e.message}")
        }

        // 策略2：通过 getRunningAppProcesses 补充（Android 10+ 可能只返回自身）
        try {
            val runningProcesses = am.getRunningAppProcesses()
            if (!runningProcesses.isNullOrEmpty()) {
                val pids = runningProcesses.map { it.pid }.toIntArray()
                val memInfos = am.getProcessMemoryInfo(pids)
                for (i in memInfos.indices) {
                    val pkg = runningProcesses[i].processName
                    val memMb = memInfos[i].totalPss / 1024
                    if (memMb > 0 && (packageMemMap[pkg] ?: 0) < memMb) {
                        packageMemMap[pkg] = memMb
                    }
                }
            }
        } catch (_: Exception) {}

        // 策略3：确保自身进程有内存数据
        val myPid = android.os.Process.myPid()
        try {
            val myMemInfo = am.getProcessMemoryInfo(intArrayOf(myPid))
            if (myMemInfo.isNotEmpty() && myMemInfo[0].totalPss > 0) {
                packageMemMap[context.packageName] = myMemInfo[0].totalPss / 1024
            }
        } catch (_: Exception) {}

        val pm = context.packageManager
        for (stat in sorted.take(10)) {
            val map = mutableMapOf<String, Any?>()
            map["packageName"] = stat.packageName
            try {
                val appInfo = pm.getApplicationInfo(stat.packageName, 0)
                map["appName"] = pm.getApplicationLabel(appInfo).toString()
            } catch (e: Exception) {
                map["appName"] = stat.packageName.substringAfterLast(".")
            }
            map["foregroundTime"] = (stat.totalTimeInForeground / 1000).toInt()

            // 内存占用：从包名映射获取
            map["memoryMb"] = packageMemMap[stat.packageName] ?: -1

            // CPU 占用：基于前台时间占比近似
            val totalForeground = sorted.sumOf { it.totalTimeInForeground }
            map["cpuUsage"] = if (totalForeground > 0 && stat.totalTimeInForeground > 0) {
                (stat.totalTimeInForeground.toDouble() / totalForeground * 100.0)
                    .coerceIn(0.0, 100.0)
            } else {
                0.0
            }

            result.add(map)
        }

        return result
    }

    /**
     * 获取 App 耗电排行（基于 UsageStatsManager 的前台时间近似）
     * 返回 List<Map>：
     *   - packageName: String 包名
     *   - appName: String 应用名
     *   - foregroundTime: int 前台时间秒
     *   - lastUsed: long 最后使用时间戳
     */
    fun getAppBatteryUsage(): List<Map<String, Any?>> {
        if (!isUsageStatsGranted()) {
            return emptyList()
        }

        val result = mutableListOf<Map<String, Any?>>()
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager

        val endTime = System.currentTimeMillis()
        val startTime = endTime - 3600000
        val usageStats: List<android.app.usage.UsageStats> = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, startTime, endTime)

        // 按前台时间排序（前台时间越长，通常耗电越多）
        val sorted = usageStats
            .filter { stat -> stat.totalTimeInForeground > 0 }
            .sortedByDescending { stat -> stat.totalTimeInForeground }

        val pm = context.packageManager
        for (stat in sorted.take(10)) {
            val map = mutableMapOf<String, Any?>()
            map["packageName"] = stat.packageName
            try {
                val appInfo = pm.getApplicationInfo(stat.packageName, 0)
                map["appName"] = pm.getApplicationLabel(appInfo).toString()
            } catch (e: Exception) {
                map["appName"] = stat.packageName.substringAfterLast(".")
            }
            map["foregroundTime"] = (stat.totalTimeInForeground / 1000).toInt()
            map["lastUsed"] = stat.lastTimeUsed
            result.add(map)
        }

        return result
    }

    // ==================== 权限相关 ====================

    /** 检查是否有 PACKAGE_USAGE_STATS 权限 */
    fun isUsageStatsGranted(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** 打开 USAGE_STATS 权限设置页 */
    fun openUsageStatsSettings() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
