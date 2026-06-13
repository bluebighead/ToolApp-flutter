<template>
  <AppLayout>
  <div class="version-view">
    <h2>版本管理</h2>

    <!-- 提示信息 -->
    <el-alert
      v-if="connectionStore.mode !== 'remote'"
      title="版本管理仅支持远程模式"
      description="请先连接远程服务器后再使用版本管理功能。发布新版本需要将APK上传到服务器。"
      type="warning"
      show-icon
      :closable="false"
      style="margin-bottom: 16px"
    />

    <!-- 发布新版本 -->
    <el-card v-if="connectionStore.mode === 'remote'" class="version-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Upload /></el-icon>
          <span>发布新版本</span>
        </div>
      </template>

      <el-form :model="form" label-width="100px" :disabled="uploading">
        <el-form-item label="版本号" required>
          <el-input v-model="form.version" placeholder="例如：1.32.0" />
        </el-form-item>
        <el-form-item label="构建号" required>
          <el-input-number v-model="form.buildNumber" :min="1" :step="1" />
        </el-form-item>
        <el-form-item label="APK文件" required>
          <div class="apk-select">
            <el-button @click="selectApkFile" :disabled="uploading">
              <el-icon><FolderOpened /></el-icon>
              选择文件
            </el-button>
            <span v-if="form.apkFilePath" class="file-name">{{ form.apkFileName }}</span>
            <span v-else class="file-hint">未选择文件</span>
          </div>
        </el-form-item>
        <el-form-item label="更新说明">
          <el-input
            v-model="form.updateNotes"
            type="textarea"
            :rows="4"
            placeholder="请输入更新说明，每行一条"
          />
        </el-form-item>
        <el-form-item label="强制更新">
          <el-switch v-model="form.forceUpdate" />
          <span class="switch-hint">开启后，用户必须更新才能继续使用</span>
        </el-form-item>
        <el-form-item>
          <el-button type="primary" @click="handlePublish" :loading="uploading" :disabled="uploading">
            {{ uploading ? '上传中...' : '发布版本' }}
          </el-button>
        </el-form-item>
      </el-form>

      <!-- 上传进度 -->
      <div v-if="uploading" style="margin-top: 16px">
        <!-- 重试状态提示 -->
        <el-alert
          v-if="retryStatus"
          :title="retryStatus"
          type="warning"
          show-icon
          :closable="false"
          style="margin-bottom: 8px"
        />
        <el-progress
          :percentage="uploadProgress"
          :status="retryStatus ? 'warning' : undefined"
          :format="() => `${uploadProgress}%`"
          style="margin-bottom: 4px"
        />
        <!-- 上传速率和文件大小显示 -->
        <div style="display: flex; justify-content: space-between; font-size: 12px; color: #909399;">
          <span v-if="uploadSpeed">上传速率：{{ uploadSpeed }}</span>
          <span v-if="uploadFileSize">文件大小：{{ uploadFileSize }}</span>
        </div>
      </div>
    </el-card>

    <!-- 版本列表 -->
    <el-card class="version-card" style="margin-top: 16px">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><List /></el-icon>
          <span>版本历史</span>
          <el-button text type="primary" @click="loadVersions" style="margin-left: auto">
            <el-icon><Refresh /></el-icon>
            刷新
          </el-button>
        </div>
      </template>

      <el-table :data="versions" stripe v-loading="loading" empty-text="暂无版本记录">
        <el-table-column prop="version" label="版本号" width="120" />
        <el-table-column prop="build_number" label="构建号" width="100" />
        <el-table-column label="文件大小" width="120">
          <template #default="{ row }">
            {{ formatFileSize(row.file_size) }}
          </template>
        </el-table-column>
        <el-table-column label="强制更新" width="100">
          <template #default="{ row }">
            <el-tag :type="row.force_update ? 'danger' : 'info'" size="small">
              {{ row.force_update ? '是' : '否' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="update_notes" label="更新说明" min-width="200" show-overflow-tooltip />
        <el-table-column prop="created_at" label="发布时间" width="180" />
        <el-table-column label="操作" width="150" fixed="right">
          <template #default="{ row }">
            <el-button text type="primary" size="small" @click="handleEdit(row)">编辑</el-button>
            <el-popconfirm title="确定删除此版本？APK文件也将被删除。" @confirm="handleDelete(row)">
              <template #reference>
                <el-button text type="danger" size="small">删除</el-button>
              </template>
            </el-popconfirm>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 编辑版本对话框 -->
    <el-dialog v-model="editDialogVisible" title="编辑版本信息" width="500px">
      <el-form :model="editForm" label-width="100px">
        <el-form-item label="版本号">
          <el-input v-model="editForm.version" />
        </el-form-item>
        <el-form-item label="构建号">
          <el-input-number v-model="editForm.build_number" :min="1" :step="1" />
        </el-form-item>
        <el-form-item label="更新说明">
          <el-input v-model="editForm.update_notes" type="textarea" :rows="4" />
        </el-form-item>
        <el-form-item label="强制更新">
          <el-switch v-model="editForm.force_update" :active-value="1" :inactive-value="0" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="editDialogVisible = false">取消</el-button>
        <el-button type="primary" @click="handleSaveEdit" :loading="savingEdit">保存</el-button>
      </template>
    </el-dialog>
  </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { ElMessage } from 'element-plus'
import AppLayout from '@/components/AppLayout.vue'
import { api } from '@/utils/api'
import { useConnectionStore } from '@/stores/connection'

const connectionStore = useConnectionStore()

const versions = ref([])
const loading = ref(false)
const uploading = ref(false)
const uploadProgress = ref(0)
const uploadSpeed = ref('')        // 当前上传速率文本（如 "2.5 MB/s"）
const uploadFileSize = ref('')     // 文件总大小文本（如 "128.0 MB"）
const retryStatus = ref('')        // 重试状态文本（如 "网络波动，正在重试 (1/2)"）
let removeProgressListener = null  // 取消监听的函数

// 发布表单
const form = ref({
  version: '',
  buildNumber: 1,
  apkFilePath: '',
  apkFileName: '',
  updateNotes: '',
  forceUpdate: false,
})

// 编辑对话框
const editDialogVisible = ref(false)
const editForm = ref({})
const savingEdit = ref(false)

onMounted(() => {
  loadVersions()
})

onUnmounted(() => {
  // 组件销毁时取消进度监听
  if (removeProgressListener) {
    removeProgressListener()
    removeProgressListener = null
  }
})

// 格式化文件大小/速率
function formatSpeed(bytesPerSec) {
  if (bytesPerSec <= 0) return ''
  if (bytesPerSec < 1024) return bytesPerSec + ' B/s'
  if (bytesPerSec < 1024 * 1024) return (bytesPerSec / 1024).toFixed(1) + ' KB/s'
  return (bytesPerSec / (1024 * 1024)).toFixed(1) + ' MB/s'
}

function formatFileSize(bytes) {
  if (!bytes || bytes === 0) return '-'
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}

// 加载版本列表
async function loadVersions() {
  loading.value = true
  try {
    const result = await api.getAppVersions()
    if (Array.isArray(result)) {
      versions.value = result
    } else if (result && !result.error) {
      versions.value = Array.isArray(result) ? result : []
    } else {
      ElMessage.error(result?.error || '获取版本列表失败')
    }
  } catch (err) {
    ElMessage.error('获取版本列表失败: ' + err.message)
  } finally {
    loading.value = false
  }
}

// 选择APK文件
async function selectApkFile() {
  try {
    const result = await api.selectApkFile()
    if (result) {
      form.value.apkFilePath = result.filePath
      // 提取文件名
      const parts = result.filePath.replace(/\\/g, '/').split('/')
      form.value.apkFileName = parts[parts.length - 1]
      
      // 自动填充从pubspec.yaml读取的版本号
      if (result.versionInfo) {
        form.value.version = result.versionInfo.version
        form.value.buildNumber = result.versionInfo.buildNumber
      }
    }
  } catch (err) {
    ElMessage.error('选择文件失败')
  }
}

// 发布新版本
async function handlePublish() {
  if (!form.value.version) {
    ElMessage.warning('请输入版本号')
    return
  }
  if (!form.value.buildNumber) {
    ElMessage.warning('请输入构建号')
    return
  }
  if (!form.value.apkFilePath) {
    ElMessage.warning('请选择APK文件')
    return
  }

  uploading.value = true
  uploadProgress.value = 0
  uploadSpeed.value = ''
  uploadFileSize.value = ''
  retryStatus.value = ''

  // 注册真实上传进度监听（从底层 db_worker 上报）
  removeProgressListener = api.onUploadProgress((data) => {
    const { loaded, total, speed, retryAttempt, maxRetries } = data

    // speed === -1 表示重试状态（网络波动，正在自动重试）
    if (speed === -1 && retryAttempt !== undefined && maxRetries !== undefined) {
      retryStatus.value = `网络波动，正在自动重试 (${retryAttempt}/${maxRetries})...`
      return
    }

    // 正常进度上报时清除重试状态
    retryStatus.value = ''

    // 计算百分比
    const pct = total > 0 ? Math.round((loaded / total) * 100) : 0
    uploadProgress.value = Math.min(pct, 100)
    // 更新速率显示
    uploadSpeed.value = formatSpeed(speed)
    // 保存文件总大小（只在首次设置）
    if (!uploadFileSize.value && total > 0) {
      uploadFileSize.value = formatFileSize(total)
    }
  })

  try {
    const result = await api.createAppVersion({
      version: form.value.version,
      buildNumber: form.value.buildNumber,
      apkFilePath: form.value.apkFilePath,
      updateNotes: form.value.updateNotes,
      forceUpdate: form.value.forceUpdate,
    })

    // 上传完成，进度设为100%
    uploadProgress.value = 100

    if (result.success) {
      ElMessage.success('版本发布成功')
      // 重置表单
      form.value = {
        version: '',
        buildNumber: 1,
        apkFilePath: '',
        apkFileName: '',
        updateNotes: '',
        forceUpdate: false,
      }
      // 刷新列表
      await loadVersions()
    } else {
      ElMessage.error(result.error || '发布失败')
    }
  } catch (err) {
    ElMessage.error('发布失败: ' + err.message)
  } finally {
    uploading.value = false
    // 清理进度监听
    if (removeProgressListener) {
      removeProgressListener()
      removeProgressListener = null
    }
    // 延迟重置进度显示
    setTimeout(() => {
      uploadProgress.value = 0
      uploadSpeed.value = ''
      uploadFileSize.value = ''
      retryStatus.value = ''
    }, 2000)
  }
}

// 编辑版本
function handleEdit(row) {
  editForm.value = { ...row }
  editDialogVisible.value = true
}

// 保存编辑
async function handleSaveEdit() {
  savingEdit.value = true
  try {
    const result = await api.updateAppVersion(editForm.value.id, {
      version: editForm.value.version,
      buildNumber: editForm.value.build_number,
      updateNotes: editForm.value.update_notes,
      forceUpdate: editForm.value.force_update === 1,
    })
    if (result.success) {
      ElMessage.success('更新成功')
      editDialogVisible.value = false
      await loadVersions()
    } else {
      ElMessage.error(result.error || '更新失败')
    }
  } catch (err) {
    ElMessage.error('更新失败: ' + err.message)
  } finally {
    savingEdit.value = false
  }
}

// 删除版本
async function handleDelete(row) {
  try {
    const result = await api.deleteAppVersion(row.id)
    if (result.success) {
      ElMessage.success('删除成功')
      await loadVersions()
    } else {
      ElMessage.error(result.error || '删除失败')
    }
  } catch (err) {
    ElMessage.error('删除失败: ' + err.message)
  }
}

</script>

<style scoped>
.version-view {
  max-width: 900px;
}
.version-card {
  border-radius: 8px;
}
.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 500;
}
.apk-select {
  display: flex;
  align-items: center;
  gap: 12px;
}
.file-name {
  color: #409EFF;
  font-size: 13px;
}
.file-hint {
  color: #909399;
  font-size: 13px;
}
.switch-hint {
  margin-left: 12px;
  color: #909399;
  font-size: 12px;
}
</style>
