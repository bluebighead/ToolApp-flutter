<template>
  <AppLayout>
    <div class="camera-test">
      <h2 class="page-title">摄像头测试</h2>

      <!-- 摄像头选择 -->
      <el-card shadow="hover" class="control-card">
        <template #header>
          <div class="card-header">
            <span>摄像头控制</span>
            <el-tag v-if="streaming" type="success" size="small">预览中</el-tag>
            <el-tag v-else type="info" size="small">未启动</el-tag>
          </div>
        </template>
        <el-row :gutter="16" align="middle">
          <el-col :span="8">
            <el-select v-model="selectedDeviceId" placeholder="选择摄像头" style="width: 100%" :disabled="streaming">
              <el-option
                v-for="device in videoDevices"
                :key="device.deviceId"
                :label="device.label || `摄像头 ${videoDevices.indexOf(device) + 1}`"
                :value="device.deviceId"
              />
            </el-select>
          </el-col>
          <el-col :span="16">
            <el-button v-if="!streaming" type="primary" @click="startPreview" :disabled="videoDevices.length === 0">
              <el-icon><VideoCamera /></el-icon>
              启动预览
            </el-button>
            <el-button v-else type="danger" @click="stopPreview">
              <el-icon><VideoPause /></el-icon>
              停止预览
            </el-button>
            <el-button @click="refreshDevices" :loading="refreshing">
              <el-icon><Refresh /></el-icon>
              刷新设备
            </el-button>
            <el-button v-if="streaming" type="success" @click="takePhoto" :loading="capturing">
              <el-icon><Camera /></el-icon>
              拍照测试
            </el-button>
          </el-col>
        </el-row>
      </el-card>

      <!-- 预览和拍照结果 -->
      <el-row :gutter="20" class="preview-row">
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>实时预览</template>
            <div class="video-container">
              <video ref="videoRef" autoplay playsinline muted class="preview-video" v-show="streaming"></video>
              <div v-if="!streaming" class="video-placeholder">
                <el-icon :size="64" color="#c0c4cc"><VideoCamera /></el-icon>
                <p>点击"启动预览"开始摄像头测试</p>
              </div>
            </div>
          </el-card>
        </el-col>
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>
              <div class="card-header">
                <span>拍照结果</span>
                <el-button v-if="capturedImage" text type="primary" size="small" @click="savePhoto">
                  <el-icon><Download /></el-icon>
                  保存
                </el-button>
              </div>
            </template>
            <div class="video-container">
              <img v-if="capturedImage" :src="capturedImage" class="captured-image" />
              <div v-else class="video-placeholder">
                <el-icon :size="64" color="#c0c4cc"><Picture /></el-icon>
                <p>点击"拍照测试"验证拍照功能</p>
              </div>
            </div>
          </el-card>
        </el-col>
      </el-row>

      <!-- 检测结果 -->
      <el-card shadow="hover" class="result-card">
        <template #header>检测结果</template>
        <el-descriptions :column="2" border>
          <el-descriptions-item label="摄像头数量">
            <el-tag :type="videoDevices.length > 0 ? 'success' : 'danger'" size="small">
              {{ videoDevices.length }} 个
            </el-tag>
          </el-descriptions-item>
          <el-descriptions-item label="预览功能">
            <el-tag :type="previewTested ? 'success' : 'info'" size="small">
              {{ previewTested ? '正常' : '未测试' }}
            </el-tag>
          </el-descriptions-item>
          <el-descriptions-item label="拍照功能">
            <el-tag :type="photoTested ? 'success' : 'info'" size="small">
              {{ photoTested ? '正常' : '未测试' }}
            </el-tag>
          </el-descriptions-item>
          <el-descriptions-item label="当前摄像头">
            {{ currentDeviceLabel || '未选择' }}
          </el-descriptions-item>
        </el-descriptions>
      </el-card>

      <!-- 隐藏的 canvas 用于拍照 -->
      <canvas ref="canvasRef" style="display: none;"></canvas>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount, computed } from 'vue'
import { ElMessage } from 'element-plus'
import AppLayout from '@/components/AppLayout.vue'

// 视频元素引用
const videoRef = ref(null)
const canvasRef = ref(null)

// 摄像头设备列表
const videoDevices = ref([])
const selectedDeviceId = ref('')
const refreshing = ref(false)

// 流状态
const streaming = ref(false)
let mediaStream = null

// 拍照状态
const capturing = ref(false)
const capturedImage = ref(null)

// 检测结果
const previewTested = ref(false)
const photoTested = ref(false)

// 当前设备标签
const currentDeviceLabel = computed(() => {
  const device = videoDevices.value.find(d => d.deviceId === selectedDeviceId.value)
  return device?.label || ''
})

// 刷新设备列表
async function refreshDevices() {
  refreshing.value = true
  try {
    // 先请求权限，否则 label 为空
    try {
      const tempStream = await navigator.mediaDevices.getUserMedia({ video: true })
      tempStream.getTracks().forEach(t => t.stop())
    } catch (e) {
      ElMessage.error('无法获取摄像头权限: ' + e.message)
      refreshing.value = false
      return
    }

    const devices = await navigator.mediaDevices.enumerateDevices()
    videoDevices.value = devices.filter(d => d.kind === 'videoinput')

    if (videoDevices.value.length > 0 && !selectedDeviceId.value) {
      selectedDeviceId.value = videoDevices.value[0].deviceId
    }

    ElMessage.success(`检测到 ${videoDevices.value.length} 个摄像头`)
  } catch (e) {
    ElMessage.error('获取设备列表失败: ' + e.message)
  } finally {
    refreshing.value = false
  }
}

// 启动预览
async function startPreview() {
  if (!selectedDeviceId.value) {
    ElMessage.warning('请先选择摄像头')
    return
  }

  try {
    mediaStream = await navigator.mediaDevices.getUserMedia({
      video: {
        deviceId: { exact: selectedDeviceId.value },
        width: { ideal: 1280 },
        height: { ideal: 720 },
      }
    })

    if (videoRef.value) {
      videoRef.value.srcObject = mediaStream
    }

    streaming.value = true
    previewTested.value = true
    ElMessage.success('摄像头预览已启动')
  } catch (e) {
    ElMessage.error('启动预览失败: ' + e.message)
  }
}

// 停止预览
function stopPreview() {
  if (mediaStream) {
    mediaStream.getTracks().forEach(t => t.stop())
    mediaStream = null
  }
  if (videoRef.value) {
    videoRef.value.srcObject = null
  }
  streaming.value = false
}

// 拍照
async function takePhoto() {
  if (!videoRef.value || !streaming.value) return

  capturing.value = true
  try {
    const video = videoRef.value
    const canvas = canvasRef.value
    canvas.width = video.videoWidth
    canvas.height = video.videoHeight

    const ctx = canvas.getContext('2d')
    ctx.drawImage(video, 0, 0)

    capturedImage.value = canvas.toDataURL('image/png')
    photoTested.value = true
    ElMessage.success('拍照成功')
  } catch (e) {
    ElMessage.error('拍照失败: ' + e.message)
  } finally {
    capturing.value = false
  }
}

// 保存照片
function savePhoto() {
  if (!capturedImage.value) return

  const link = document.createElement('a')
  link.href = capturedImage.value
  link.download = `camera_test_${Date.now()}.png`
  link.click()
  ElMessage.success('照片已保存')
}

onMounted(() => {
  refreshDevices()
})

onBeforeUnmount(() => {
  stopPreview()
})
</script>

<style scoped>
.page-title {
  margin-bottom: 20px;
  color: #303133;
}
.control-card {
  margin-bottom: 20px;
}
.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
}
.preview-row {
  margin-bottom: 20px;
}
.video-container {
  width: 100%;
  height: 300px;
  background: #000;
  border-radius: 4px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
}
.preview-video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.captured-image {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.video-placeholder {
  text-align: center;
  color: #c0c4cc;
}
.video-placeholder p {
  margin-top: 12px;
  font-size: 14px;
}
.result-card {
  margin-bottom: 20px;
}
</style>
