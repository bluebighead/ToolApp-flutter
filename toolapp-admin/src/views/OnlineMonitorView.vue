<template>
  <AppLayout>
  <div class="online-monitor">
    <h2 class="page-title">
      <el-icon><Monitor /></el-icon>
      用户在线监控
    </h2>

    <!-- 概览卡片 -->
    <el-row :gutter="20" class="stats-row">
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-content">
            <el-icon :size="32" class="stat-icon online"><UserFilled /></el-icon>
            <div class="stat-text">
              <div class="stat-value">{{ onlineStatus.onlineCount || 0 }}</div>
              <div class="stat-label">在线用户</div>
            </div>
          </div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-content">
            <el-icon :size="32" class="stat-icon total"><Avatar /></el-icon>
            <div class="stat-text">
              <div class="stat-value">{{ onlineStatus.totalCount || 0 }}</div>
              <div class="stat-label">注册用户</div>
            </div>
          </div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-content">
            <el-icon :size="32" class="stat-icon time"><Clock /></el-icon>
            <div class="stat-text">
              <div class="stat-value">{{ formatTotalTime }}</div>
              <div class="stat-label">今日使用时长</div>
            </div>
          </div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-content">
            <el-icon :size="32" class="stat-icon refresh"><Refresh /></el-icon>
            <div class="stat-text">
              <div class="stat-value">{{ lastUpdateTime }}</div>
              <div class="stat-label">最后更新</div>
            </div>
          </div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 操作栏 -->
    <el-card shadow="hover" class="control-card">
      <div class="control-bar">
        <el-button type="primary" @click="loadData" :loading="loading">
          <el-icon><Refresh /></el-icon>
          刷新数据
        </el-button>
        <el-switch
          v-model="autoRefresh"
          active-text="自动刷新"
          inactive-text="手动刷新"
          @change="toggleAutoRefresh"
        />
        <el-select v-model="refreshInterval" :disabled="!autoRefresh" style="width: 120px" @change="restartAutoRefresh">
          <el-option label="10 秒" :value="10" />
          <el-option label="30 秒" :value="30" />
          <el-option label="1 分钟" :value="60" />
          <el-option label="5 分钟" :value="300" />
        </el-select>
      </div>
    </el-card>

    <!-- 用户在线列表 -->
    <el-card shadow="hover" class="table-card">
      <template #header>
        <div class="card-header">
          <span>用户在线状态</span>
          <el-tag :type="onlineStatus.onlineCount > 0 ? 'success' : 'info'">
            在线 {{ onlineStatus.onlineCount || 0 }} / 总计 {{ onlineStatus.totalCount || 0 }}
          </el-tag>
        </div>
      </template>

      <el-table :data="userList" stripe style="width: 100%" v-loading="loading">
        <el-table-column prop="id" label="ID" width="80" />
        <el-table-column prop="email" label="用户邮箱" min-width="200" />
        <el-table-column label="状态" width="100">
          <template #default="{ row }">
            <el-tag :type="row.isOnline ? 'success' : 'info'" size="small">
              {{ row.isOnline ? '在线' : '离线' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="最后活跃" width="180">
          <template #default="{ row }">
            <span v-if="row.lastSeen">{{ formatDateTime(row.lastSeen) }}</span>
            <span v-else style="color: #909399">—</span>
          </template>
        </el-table-column>
        <el-table-column label="今日使用" width="130">
          <template #default="{ row }">
            {{ formatDuration(row.todayUsageSeconds) }}
          </template>
        </el-table-column>
        <el-table-column label="累计使用" width="130">
          <template #default="{ row }">
            {{ formatDuration(row.totalUsageSeconds) }}
          </template>
        </el-table-column>
        <el-table-column label="会话次数" width="100">
          <template #default="{ row }">
            {{ row.sessionCount || 0 }}
          </template>
        </el-table-column>
        <el-table-column label="设备信息" min-width="150">
          <template #default="{ row }">
            <span v-if="row.deviceInfo" style="font-size: 12px">{{ row.deviceInfo }}</span>
            <span v-else style="color: #909399">—</span>
          </template>
        </el-table-column>
        <el-table-column label="注册时间" width="180">
          <template #default="{ row }">
            {{ formatDateTime(row.created_at) }}
          </template>
        </el-table-column>
      </el-table>

      <el-empty v-if="!loading && userList.length === 0" description="暂无用户数据" />
    </el-card>

    <!-- 会话详情弹窗 -->
    <el-dialog v-model="sessionDialogVisible" title="用户会话详情" width="800px">
      <div v-if="selectedUser">
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="用户邮箱">{{ selectedUser.email }}</el-descriptions-item>
          <el-descriptions-item label="状态">
            <el-tag :type="selectedUser.isOnline ? 'success' : 'info'">
              {{ selectedUser.isOnline ? '在线' : '离线' }}
            </el-tag>
          </el-descriptions-item>
          <el-descriptions-item label="今日使用">{{ formatDuration(selectedUser.todayUsageSeconds) }}</el-descriptions-item>
          <el-descriptions-item label="累计使用">{{ formatDuration(selectedUser.totalUsageSeconds) }}</el-descriptions-item>
        </el-descriptions>

        <div style="margin-top: 20px">
          <h4>最近会话记录</h4>
          <el-table :data="sessionList" size="small" v-loading="sessionLoading">
            <el-table-column prop="id" label="会话ID" width="80" />
            <el-table-column label="开始时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.session_start) }}</template>
            </el-table-column>
            <el-table-column label="结束时间" width="180">
              <template #default="{ row }">
                <span v-if="row.session_end">{{ formatDateTime(row.session_end) }}</span>
                <el-tag v-else type="success" size="small">进行中</el-tag>
              </template>
            </el-table-column>
            <el-table-column label="时长" width="120">
              <template #default="{ row }">
                {{ formatDuration(row.duration_seconds) }}
              </template>
            </el-table-column>
            <el-table-column label="设备信息" min-width="150">
              <template #default="{ row }">
                <span v-if="row.device_info" style="font-size: 12px">{{ row.device_info }}</span>
                <span v-else style="color: #909399">—</span>
              </template>
            </el-table-column>
          </el-table>
          <el-empty v-if="!sessionLoading && sessionList.length === 0" description="暂无会话记录" />
        </div>
      </div>
    </el-dialog>
  </div>
  </AppLayout>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import AppLayout from '@/components/AppLayout.vue'
import { ElMessage } from 'element-plus'
import { api } from '@/utils/api'
import {
  Monitor,
  UserFilled,
  Avatar,
  Clock,
  Refresh,
} from '@element-plus/icons-vue'

const loading = ref(false)
const autoRefresh = ref(true)
const refreshInterval = ref(30)
const userList = ref([])
const onlineStatus = ref({ onlineCount: 0, totalCount: 0 })
const lastUpdateTime = ref('—')

const sessionDialogVisible = ref(false)
const selectedUser = ref(null)
const sessionList = ref([])
const sessionLoading = ref(false)

let refreshTimer = null

function formatDateTime(isoStr) {
  if (!isoStr) return '—'
  try {
    const d = new Date(isoStr)
    const y = d.getFullYear()
    const m = String(d.getMonth() + 1).padStart(2, '0')
    const day = String(d.getDate()).padStart(2, '0')
    const h = String(d.getHours()).padStart(2, '0')
    const min = String(d.getMinutes()).padStart(2, '0')
    const s = String(d.getSeconds()).padStart(2, '0')
    return `${y}-${m}-${day} ${h}:${min}:${s}`
  } catch (e) {
    return isoStr
  }
}

function formatDuration(seconds) {
  if (!seconds || seconds <= 0) return '—'
  if (seconds < 60) return `${seconds} 秒`
  const minutes = Math.floor(seconds / 60)
  const secs = seconds % 60
  if (minutes < 60) return `${minutes}分${secs}秒`
  const hours = Math.floor(minutes / 60)
  const mins = minutes % 60
  if (hours < 24) return `${hours}小时${mins}分`
  const days = Math.floor(hours / 24)
  const hrs = hours % 24
  return `${days}天${hrs}小时`
}

const formatTotalTime = computed(() => {
  let total = 0
  for (const u of userList.value) {
    total += u.todayUsageSeconds || 0
  }
  return formatDuration(total)
})

async function loadData() {
  loading.value = true
  try {
    const data = await api.getOnlineStatus()
    if (data && data.users) {
      userList.value = data.users
      onlineStatus.value = {
        onlineCount: data.onlineCount,
        totalCount: data.totalCount,
      }
    }
    const now = new Date()
    const h = String(now.getHours()).padStart(2, '0')
    const m = String(now.getMinutes()).padStart(2, '0')
    const s = String(now.getSeconds()).padStart(2, '0')
    lastUpdateTime.value = `${h}:${m}:${s}`
  } catch (err) {
    console.error('加载在线状态失败:', err)
  } finally {
    loading.value = false
  }
}

function startAutoRefresh() {
  stopAutoRefresh()
  if (autoRefresh.value && refreshInterval.value > 0) {
    refreshTimer = setInterval(loadData, refreshInterval.value * 1000)
  }
}

function stopAutoRefresh() {
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
}

function toggleAutoRefresh() {
  startAutoRefresh()
}

function restartAutoRefresh() {
  startAutoRefresh()
}

onMounted(() => {
  loadData()
  startAutoRefresh()
})

onBeforeUnmount(() => {
  stopAutoRefresh()
})
</script>

<style scoped>
.online-monitor {
  padding: 20px;
}
.page-title {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 0 0 20px 0;
  color: #303133;
  font-size: 22px;
}
.stats-row {
  margin-bottom: 20px;
}
.stat-card {
  text-align: center;
}
.stat-content {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 15px;
}
.stat-icon {
  padding: 15px;
  border-radius: 10px;
}
.stat-icon.online {
  background: #f0f9eb;
  color: #67c23a;
}
.stat-icon.total {
  background: #ecf5ff;
  color: #409eff;
}
.stat-icon.time {
  background: #fdf6ec;
  color: #e6a23c;
}
.stat-icon.refresh {
  background: #f0f2f5;
  color: #909399;
}
.stat-value {
  font-size: 28px;
  font-weight: bold;
  color: #303133;
}
.stat-label {
  color: #909399;
  font-size: 14px;
  margin-top: 5px;
}
.control-card {
  margin-bottom: 20px;
}
.control-bar {
  display: flex;
  align-items: center;
  gap: 20px;
}
.table-card {
  margin-bottom: 20px;
}
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}
</style>
