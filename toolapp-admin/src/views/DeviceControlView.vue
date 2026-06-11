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

      <!-- 用户选择 -->
      <el-card shadow="hover" class="user-card" v-if="wsConnected">
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
      <el-card shadow="hover" class="video-card" v-if="wsConnected">
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
      <el-card shadow="hover" class="save-card" v-if="wsConnected">
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
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onBeforeUnmount } from 'vue'
import { ElMessage } from 'element-plus'
import { Loading } from '@element-plus/icons-vue'
import AppLayout from '@/components/AppLayout.vue'
import { useConnectionStore } from '@/stores/connection'
import { api } from '@/utils/api'

const connectionStore = useConnectionStore()

// WebSocket连接
let ws = null

// 连接状态
const wsConnected = ref(false)
const connecting = ref(false)

// 自动重连
const reconnecting = ref(false)
const reconnectAttempts = ref(0)
let reconnectTimer = null
let intentionalDisconnect = false

// 用户列表
const onlineUsers = ref([])
const loadingUsers = ref(false)
const selectedUserId = ref(null)

// 推流状态
const streamingUserId = ref(null)
const streamStatus = ref('idle')

// 摄像头模式
const cameraMode = ref('front')
const frontStreamActive = ref(false)
const rearStreamActive = ref(false)

// 抓拍状态
const snapshotLoading = ref(false)
const snapshotUserId = ref(null)
const snapshotImages = ref([])
const snapshotSaveDir = ref(localStorage.getItem('snapshotSaveDir') || '')

// ---- 传输速度统计 ----
let bytesReceived = 0           // 总接收字节数
let lastSpeedBytes = 0          // 上次计算速度时的字节数
let lastSpeedTime = 0           // 上次计算速度的时间
const transferSpeed = ref(0)    // 当前传输速度 bytes/s
let frameCount = 0              // 帧计数
let lastFrameCountTime = 0      // 上次计算帧率的时间
let lastFrameCount = 0          // 上次计算帧率时的帧数
const frameRate = ref(0)        // 当前帧率 fps
let speedCalcTimer = null       // 速度计算定时器

// 抓拍进度
const snapshotProgress = ref(0)
const snapshotProgressText = ref('请求中...')

// 请求推流进度
const requestProgress = ref(0)
const requestProgressText = ref('发送请求...')
const requestElapsedText = ref('0s')
let requestStartTime = 0
let requestProgressTimer = null

// Canvas引用
const frontCanvasRef = ref(null)
const rearCanvasRef = ref(null)

// 格式化速度显示
const transferSpeedText = ref('0 B/s')
const frameRateText = ref('0 fps')
const totalReceivedText = ref('0 B')

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

// 启动速度计算定时器
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
    // 帧率计算
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

// 启动请求推流进度计时器
function startRequestProgress() {
  stopRequestProgress()
  requestStartTime = Date.now()
  requestProgress.value = 5
  requestProgressText.value = '发送请求...'
  requestElapsedText.value = '0s'

  requestProgressTimer = setInterval(() => {
    const elapsed = Math.round((Date.now() - requestStartTime) / 1000)
    requestElapsedText.value = elapsed + 's'

    // 分阶段推进进度（不会到100%，等实际推流开始才完成）
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

// 摄像头模式切换
function onCameraModeChange(mode) {
  if (streamingUserId.value && streamStatus.value === 'streaming') {
    requestCamera({ id: streamingUserId.value, email: '' })
  }
}

// 选择保存文件夹
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

// 保存抓拍图片到本地
async function saveSnapshotToLocal(base64Data, source) {
  if (!snapshotSaveDir.value) return
  try {
    const now = new Date()
    const timestamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}_${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}`
    const sourceLabel = source === 'rear' ? 'rear' : 'front'
    const filename = `snapshot_${sourceLabel}_${timestamp}.jpg`
    const result = await api.saveSnapshotImage({
      base64Data,
      saveDir: snapshotSaveDir.value,
      filename,
    })
    if (result.success) {
      ElMessage.success(`${sourceLabel === 'rear' ? '后置' : '前置'}照片已保存到: ${result.path}`)
    } else {
      ElMessage.error('保存失败: ' + result.error)
    }
  } catch (err) {
    ElMessage.error('保存图片失败: ' + err.message)
  }
}

// 加载在线用户列表
function loadOnlineUsers() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    ElMessage.warning('请先连接WebSocket')
    return
  }
  loadingUsers.value = true
  sendWsMessage('admin_get_online_users', {})
  setTimeout(() => {
    if (loadingUsers.value) {
      loadOnlineUsersFallback()
    }
  }, 3000)
}

async function loadOnlineUsersFallback() {
  try {
    const result = await api.getOnlineStatus()
    onlineUsers.value = (result.users || []).map(u => ({
      id: u.id,
      email: u.email,
      isOnline: u.isOnline || false,
    }))
  } catch (err) {
    ElMessage.error('加载用户列表失败: ' + err.message)
  } finally {
    loadingUsers.value = false
  }
}

function handleUserClick(row) {
  selectedUserId.value = row.id
}

function buildWsUrl(token) {
  const serverUrl = connectionStore.serverUrl
  const parsedUrl = new URL(serverUrl)
  const scheme = parsedUrl.protocol === 'https:' ? 'wss' : 'ws'
  return `${scheme}://${parsedUrl.host}/ws?token=${token}`
}

// 连接WebSocket
async function connectWs() {
  if (connectionStore.mode !== 'remote') {
    ElMessage.warning('设备控制仅支持远程模式')
    return
  }

  if (wsConnected.value) {
    ElMessage.info('已连接WebSocket')
    return
  }

  intentionalDisconnect = false
  connecting.value = true

  try {
    const tokenResult = await api.getAdminWsToken()
    if (!tokenResult.token) {
      ElMessage.error('获取WebSocket Token失败: ' + (tokenResult.error || '未知错误'))
      connecting.value = false
      return
    }

    const wsUrl = buildWsUrl(tokenResult.token)
    console.log('连接WebSocket:', wsUrl)

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
      // 统计接收字节数
      const msgSize = typeof event.data === 'string' ? event.data.length : 0
      bytesReceived += msgSize * 2  // UTF-16编码，每字符2字节

      try {
        const msgStr = typeof event.data === 'string' ? event.data.trim() : ''
        const msg = JSON.parse(msgStr)
        handleWsMessage(msg)
      } catch (err) {
        console.error('WebSocket消息解析失败:', err)
      }
    }

    ws.onerror = () => {
      connecting.value = false
    }

    ws.onclose = (event) => {
      console.log('WebSocket已关闭, code:', event.code, 'reason:', event.reason)
      wsConnected.value = false
      connecting.value = false
      ws = null

      // 非主动断开时自动重连
      if (!intentionalDisconnect) {
        scheduleReconnect()
      }
    }
  } catch (err) {
    ElMessage.error('连接失败: ' + err.message)
    connecting.value = false
  }
}

// 自动重连（指数退避：2s, 4s, 8s, 16s... 最大30s）
function scheduleReconnect() {
  if (intentionalDisconnect) return
  if (reconnectTimer) return

  reconnectAttempts.value++
  const delay = Math.min(2 * Math.pow(2, reconnectAttempts.value - 1), 30) * 1000
  reconnecting.value = true

  console.log(`WebSocket将在 ${delay / 1000}s 后重连 (第${reconnectAttempts.value}次)`)

  reconnectTimer = setTimeout(async () => {
    reconnectTimer = null
    if (intentionalDisconnect) {
      reconnecting.value = false
      return
    }
    console.log('开始自动重连...')
    await connectWs()
  }, delay)
}

// 取消重连
function cancelReconnect() {
  intentionalDisconnect = true
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  reconnecting.value = false
  reconnectAttempts.value = 0
  ElMessage.info('已取消自动重连')
}

// 断开WebSocket
function disconnectWs() {
  intentionalDisconnect = true
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  reconnecting.value = false
  reconnectAttempts.value = 0

  if (ws) {
    ws.close()
    ws = null
  }
  wsConnected.value = false
  streamingUserId.value = null
  streamStatus.value = 'idle'
  frontStreamActive.value = false
  rearStreamActive.value = false
  stopSpeedCalc()
  ElMessage.info('已断开WebSocket连接')
}

function sendWsMessage(type, data) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type, data }))
  }
}

// 请求实时推流
function requestCamera(user) {
  if (streamingUserId.value) {
    sendWsMessage('admin_camera_stop', {})
  }

  selectedUserId.value = user.id
  streamingUserId.value = user.id
  streamStatus.value = 'requesting'
  snapshotImages.value = []
  frontStreamActive.value = false
  rearStreamActive.value = false
  bytesReceived = 0
  frameCount = 0

  // 启动请求进度
  startRequestProgress()

  sendWsMessage('admin_camera_request', { userId: user.id, cameraMode: cameraMode.value })
  ElMessage.info(`已向 ${user.email || '用户'} 发送实时显示请求 (${cameraMode.value === 'front' ? '前置' : cameraMode.value === 'rear' ? '后置' : '双摄'})`)
}

// 请求抓拍
function requestSnapshot(user) {
  if (!user.isOnline) {
    ElMessage.warning('该用户不在线')
    return
  }

  snapshotLoading.value = true
  snapshotUserId.value = user.id
  selectedUserId.value = user.id
  streamStatus.value = 'snapshot_requesting'
  snapshotImages.value = []
  snapshotProgress.value = 10
  snapshotProgressText.value = '已发送抓拍请求...'

  // 启动速度计算（抓拍也需要统计传输速度）
  startSpeedCalc()

  sendWsMessage('admin_camera_snapshot', { userId: user.id, cameraMode: cameraMode.value })
  ElMessage.info(`已向 ${user.email} 发送抓拍请求 (${cameraMode.value === 'front' ? '前置' : cameraMode.value === 'rear' ? '后置' : '双摄'})`)

  // 模拟抓拍进度（App端处理+拍照+传输）
  simulateSnapshotProgress()

  setTimeout(() => {
    if (snapshotLoading.value && snapshotUserId.value === user.id) {
      snapshotLoading.value = false
      snapshotUserId.value = null
      snapshotProgress.value = 0
      if (streamStatus.value === 'snapshot_requesting') {
        streamStatus.value = 'idle'
      }
      if (streamStatus.value !== 'streaming') {
        stopSpeedCalc()
      }
      ElMessage.warning('抓拍超时，请重试')
    }
  }, 20000)
}

// 模拟抓拍进度
function simulateSnapshotProgress() {
  snapshotProgress.value = 10
  snapshotProgressText.value = '已发送抓拍请求...'

  // 阶段1：App端接收请求并打开摄像头 (10% → 40%)
  setTimeout(() => {
    if (!snapshotLoading.value) return
    snapshotProgress.value = 25
    snapshotProgressText.value = 'App端正在打开摄像头...'
  }, 500)

  setTimeout(() => {
    if (!snapshotLoading.value) return
    snapshotProgress.value = 40
    snapshotProgressText.value = 'App端正在拍照...'
  }, 1500)

  // 阶段2：拍照完成，数据传输中 (40% → 90%)
  setTimeout(() => {
    if (!snapshotLoading.value) return
    snapshotProgress.value = 60
    snapshotProgressText.value = '照片数据传输中...'
  }, 2500)

  setTimeout(() => {
    if (!snapshotLoading.value) return
    snapshotProgress.value = 80
    snapshotProgressText.value = '照片数据传输中...'
  }, 3500)
}

// 停止摄像头
function stopCamera() {
  if (streamingUserId.value) {
    sendWsMessage('admin_camera_stop', {})
    streamingUserId.value = null
    streamStatus.value = 'idle'
    frontStreamActive.value = false
    rearStreamActive.value = false
    stopSpeedCalc()
    stopRequestProgress()
  }
}

function downloadAllSnapshots() {
  for (const snap of snapshotImages.value) {
    const link = document.createElement('a')
    link.href = snap.dataUrl
    const sourceLabel = snap.source === 'rear' ? 'rear' : 'front'
    link.download = `snapshot_${sourceLabel}_${Date.now()}.jpg`
    link.click()
  }
}

// 处理WebSocket消息
function handleWsMessage(msg) {
  const { type, data } = msg

  switch (type) {
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
      ElMessage.error('摄像头错误: ' + (data.message || '未知错误'))
      if (streamStatus.value !== 'streaming') {
        streamingUserId.value = null
        streamStatus.value = 'idle'
      }
      snapshotLoading.value = false
      snapshotUserId.value = null
      snapshotProgress.value = 0
      break

    case 'online_users':
      handleOnlineUsers(data)
      break

    case 'user_online':
      handleUserOnline(data)
      break

    case 'user_offline':
      handleUserOffline(data)
      break

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

  // 如果不在推流状态，停止速度计算
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
    // 完成进度
    snapshotProgress.value = 100
    snapshotProgressText.value = '抓拍完成!'

    const imageSizeKB = Math.round(data.image.length * 3 / 4 / 1024)
    ElMessage.success(`${source === 'rear' ? '后置' : '前置'}抓拍成功 (${imageSizeKB}KB)`)
    saveSnapshotToLocal(data.image, source)

    // 2秒后隐藏进度条
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
}

// 渲染YUV画面帧到Canvas
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

  // 帧计数
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
.save-card {
  margin-bottom: 20px;
}
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}
.camera-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}
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
/* 抓拍进度条 */
.snapshot-progress {
  margin-top: 8px;
}
:deep(.selected-row) {
  background-color: #ecf5ff !important;
}
</style>
