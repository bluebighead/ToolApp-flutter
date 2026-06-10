<template>
  <AppLayout>
  <div class="settings-view">
    <h2>系统设置</h2>

    <!-- 连接信息卡片 -->
    <el-card class="setting-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Link /></el-icon>
          <span>当前连接信息</span>
          <el-button text type="primary" @click="showHelpDialog = true" style="margin-left: auto">
            <el-icon><QuestionFilled /></el-icon>
            使用说明
          </el-button>
        </div>
      </template>

      <el-descriptions :column="1" border>
        <el-descriptions-item label="连接模式">
          <el-tag :type="connectionStore.mode === 'local' ? 'success' : 'warning'">
            {{ connectionStore.mode === 'local' ? '本地数据库' : connectionStore.mode === 'remote' ? '远程服务器' : '未连接' }}
          </el-tag>
        </el-descriptions-item>
        <el-descriptions-item label="数据库路径" v-if="connectionStore.mode === 'local'">
          <code>{{ connectionStore.dbPath }}</code>
        </el-descriptions-item>
        <el-descriptions-item label="服务器地址" v-if="connectionStore.mode === 'remote'">
          <code>{{ connectionStore.serverUrl }}</code>
        </el-descriptions-item>
        <!-- 实时显示当前使用的服务器地址 -->
        <el-descriptions-item label="当前服务器地址">
          <code>{{ currentServerAddress }}</code>
          <el-tag v-if="!currentServerAddress" type="info" size="small" style="margin-left: 8px">未连接</el-tag>
        </el-descriptions-item>
      </el-descriptions>
    </el-card>

    <!-- 数据库与服务器信息 -->
    <el-card class="setting-card" v-if="systemInfo">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Coin /></el-icon>
          <span>数据库与服务器信息</span>
        </div>
      </template>

      <el-descriptions :column="2" border>
        <template v-if="connectionStore.mode === 'remote' && systemInfo.server">
          <el-descriptions-item label="服务器端口">{{ systemInfo.server.port }}</el-descriptions-item>
          <el-descriptions-item label="服务器平台">{{ systemInfo.server.platform }}</el-descriptions-item>
          <el-descriptions-item label="主机名">{{ systemInfo.server.hostname }}</el-descriptions-item>
          <el-descriptions-item label="Node.js 版本">{{ systemInfo.server.nodeVersion }}</el-descriptions-item>
          <el-descriptions-item label="运行时长">{{ formatUptime(systemInfo.server.uptime) }}</el-descriptions-item>
          <el-descriptions-item label="内存使用">
            {{ formatBytes(systemInfo.server.memory.total - systemInfo.server.memory.free) }} / {{ formatBytes(systemInfo.server.memory.total) }}
          </el-descriptions-item>
          <el-descriptions-item label="局域网 IP" :span="2">
            <el-tag v-for="ip in systemInfo.server.ips" :key="ip" type="info" class="mr-5">{{ ip }}</el-tag>
          </el-descriptions-item>
        </template>

        <template v-if="dbInfo">
          <el-descriptions-item label="数据库路径" :span="2">
            <code>{{ dbInfo.path }}</code>
          </el-descriptions-item>
          <el-descriptions-item label="数据库大小">{{ formatBytes(dbInfo.size) }}</el-descriptions-item>
          <el-descriptions-item label="用户数">{{ dbInfo.tables?.users || 0 }}</el-descriptions-item>
          <el-descriptions-item label="心率记录">{{ dbInfo.tables?.heart_rate_sessions || 0 }}</el-descriptions-item>
          <el-descriptions-item label="网速记录">{{ dbInfo.tables?.network_speed_records || 0 }}</el-descriptions-item>
          <el-descriptions-item label="转换记录">{{ dbInfo.tables?.convert_history || 0 }}</el-descriptions-item>
          <el-descriptions-item label="骰子记录">{{ dbInfo.tables?.dice_records || 0 }}</el-descriptions-item>
          <el-descriptions-item label="经期记录">{{ dbInfo.tables?.period_records || 0 }}</el-descriptions-item>
          <el-descriptions-item label="用户会话">{{ dbInfo.tables?.user_sessions || 0 }}</el-descriptions-item>
          <el-descriptions-item label="活动日志">{{ dbInfo.tables?.user_activity_logs || 0 }}</el-descriptions-item>
        </template>
      </el-descriptions>
    </el-card>

    <!-- 连接模式设置 -->
    <el-card class="setting-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Monitor /></el-icon>
          <span>连接模式设置</span>
        </div>
      </template>

      <el-form label-width="150px">
        <el-form-item label="连接模式">
          <el-radio-group v-model="connectionMode" @change="handleModeChange">
            <el-radio value="auto">自动检测</el-radio>
            <el-radio value="local">本地模式</el-radio>
            <el-radio value="remote">远程模式</el-radio>
          </el-radio-group>
        </el-form-item>

        <el-form-item label="自动检测说明" v-if="connectionMode === 'auto'">
          <span class="form-tip">优先连接本地数据库，若本地数据库不可用则尝试远程连接</span>
        </el-form-item>

        <!-- 远程模式配置 -->
        <template v-if="connectionMode === 'remote' || (connectionMode === 'auto' && !connectionStore.connected)">
          <el-form-item label="服务器地址">
            <el-input v-model="remoteServerUrl" placeholder="http://192.168.1.100:3000" style="width: 300px" />
          </el-form-item>
          <el-form-item label="管理密码">
            <el-input v-model="remotePasswordInput" type="password" show-password placeholder="输入管理员密码" style="width: 200px" />
          </el-form-item>
          <el-form-item>
            <el-button type="primary" @click="handleConnectRemote" :loading="connecting">
              连接服务器
            </el-button>
          </el-form-item>
        </template>

        <!-- 本地模式配置 -->
        <template v-if="connectionMode === 'local' && !connectionStore.connected">
          <el-form-item>
            <el-button type="primary" @click="handleScanLocal" :loading="connecting">
              自动扫描本地数据库
            </el-button>
            <el-button @click="handleSelectDbFile">
              手动选择数据库文件
            </el-button>
          </el-form-item>
        </template>
      </el-form>
    </el-card>

    <!-- 远程模式密码修改 -->
    <el-card class="setting-card" v-if="connectionStore.mode === 'remote'">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Lock /></el-icon>
          <span>远程管理密码</span>
        </div>
      </template>

      <el-form label-width="150px">
        <el-form-item label="当前密码">
          <el-input v-model="passwordForm.current" type="password" show-password placeholder="输入当前密码" style="width: 200px" />
        </el-form-item>
        <el-form-item label="新密码">
          <el-input v-model="passwordForm.newPass" type="password" show-password placeholder="输入新密码（至少4位）" style="width: 200px" />
        </el-form-item>
        <el-form-item label="确认新密码">
          <el-input v-model="passwordForm.confirm" type="password" show-password placeholder="再次输入新密码" style="width: 200px" />
        </el-form-item>
        <el-form-item>
          <el-button type="warning" @click="handleChangePassword" :loading="changingPassword">
            修改密码
          </el-button>
        </el-form-item>
      </el-form>
    </el-card>

    <!-- 内网穿透设置（预留） -->
    <el-card class="setting-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Connection /></el-icon>
          <span>内网穿透设置</span>
          <el-tag type="info" size="small" style="margin-left: 8px">预留功能</el-tag>
        </div>
      </template>

      <el-form label-width="150px">
        <el-form-item label="穿透服务">
          <el-select v-model="tunnelSettings.provider" @change="saveTunnelSettings" style="width: 200px" disabled>
            <el-option label="未启用" value="none" />
            <el-option label="frp" value="frp" />
            <el-option label="ngrok" value="ngrok" />
            <el-option label="cpolar" value="cpolar" />
            <el-option label="自定义" value="custom" />
          </el-select>
          <span class="form-tip" style="margin-left: 10px">内网穿透功能尚未启用，后续版本开放</span>
        </el-form-item>
        <el-form-item label="外网访问地址">
          <el-input v-model="tunnelSettings.publicUrl" placeholder="启用后将显示外网访问地址" style="width: 300px" disabled />
        </el-form-item>
        <el-form-item label="穿透服务器地址">
          <el-input v-model="tunnelSettings.serverAddr" placeholder="如: frp.example.com:7000" style="width: 300px" disabled />
        </el-form-item>
        <el-form-item label="穿透令牌">
          <el-input v-model="tunnelSettings.token" type="password" show-password placeholder="穿透服务认证令牌" style="width: 300px" disabled />
        </el-form-item>
      </el-form>
    </el-card>

    <!-- 应用设置 -->
    <el-card class="setting-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><Setting /></el-icon>
          <span>应用设置</span>
        </div>
      </template>

      <el-form label-width="150px">
        <el-form-item label="自动刷新间隔">
          <el-select v-model="refreshInterval" @change="saveSettings" style="width: 200px">
            <el-option label="手动刷新" :value="0" />
            <el-option label="10 秒" :value="10" />
            <el-option label="30 秒" :value="30" />
            <el-option label="1 分钟" :value="60" />
            <el-option label="5 分钟" :value="300" />
          </el-select>
        </el-form-item>

        <el-form-item label="每页显示条数">
          <el-select v-model="pageSize" @change="saveSettings" style="width: 200px">
            <el-option label="10 条" :value="10" />
            <el-option label="20 条" :value="20" />
            <el-option label="50 条" :value="50" />
            <el-option label="100 条" :value="100" />
          </el-select>
        </el-form-item>
      </el-form>

      <div class="action-buttons">
        <el-button type="primary" @click="refreshData">
          <el-icon><Refresh /></el-icon>
          刷新数据
        </el-button>
        <el-button type="danger" @click="handleDisconnect">
          <el-icon><SwitchButton /></el-icon>
          断开连接
        </el-button>
      </div>
    </el-card>

    <!-- 关于 -->
    <el-card class="setting-card">
      <template #header>
        <div class="card-header">
          <el-icon :size="20"><InfoFilled /></el-icon>
          <span>关于</span>
        </div>
      </template>

      <el-descriptions :column="1">
        <el-descriptions-item label="软件名称">ToolApp 管理工具</el-descriptions-item>
        <el-descriptions-item label="版本">v1.3.0</el-descriptions-item>
        <el-descriptions-item label="技术栈">Electron + Vue 3 + Element Plus</el-descriptions-item>
        <el-descriptions-item label="用途">管理 ToolApp 应用的用户数据，包括心率、网速、转换记录等</el-descriptions-item>
      </el-descriptions>
    </el-card>

    <!-- 使用说明对话框 -->
    <el-dialog v-model="showHelpDialog" title="使用说明" width="600px">
      <div class="help-content">
        <h4>本地模式</h4>
        <p>直接读取本地的 SQLite 数据库文件（toolapp.db），适用于管理软件与服务器在同一台电脑上运行的场景。</p>
        <ul>
          <li>启动管理软件后会自动扫描 <code>toolapp-server/data/toolapp.db</code></li>
          <li>也可手动选择数据库文件的位置</li>
          <li>本地模式下无法查看服务器运行状态（CPU、内存等）</li>
          <li>适合开发调试和单机部署使用</li>
        </ul>

        <h4>远程模式</h4>
        <p>通过 HTTP API 连接远程服务器，适用于管理软件与服务器不在同一台电脑上的场景。</p>
        <ul>
          <li>需要输入服务器地址（如 <code>http://192.168.1.100:3000</code>）</li>
          <li>需要输入管理员密码（默认密码：<code>666666</code>）</li>
          <li>远程模式下可查看服务器运行状态和局域网 IP</li>
          <li>支持修改管理员密码</li>
          <li>适合局域网内多设备管理</li>
        </ul>

        <h4>自动检测模式</h4>
        <p>优先尝试本地数据库连接，若本地不可用则使用远程连接。适合大多数使用场景。</p>

        <h4>内网穿透（预留）</h4>
        <p>未来版本将支持通过 frp、ngrok 等工具实现外网访问，方便在外出时也能管理服务器。</p>
      </div>
    </el-dialog>

    <!-- 加载状态 -->
    <el-dialog v-model="loadingVisible" width="300px" :close-on-click-modal="false" :show-close="false">
      <div style="text-align: center; padding: 20px">
        <el-icon class="is-loading" :size="40"><Loading /></el-icon>
        <p style="margin-top: 15px; color: #606266">正在加载系统信息...</p>
      </div>
    </el-dialog>
  </div>
  </AppLayout>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { useRouter } from 'vue-router'
import AppLayout from '@/components/AppLayout.vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { useConnectionStore } from '@/stores/connection'
import { api } from '@/utils/api'
import {
  Link,
  Coin,
  Setting,
  Refresh,
  SwitchButton,
  InfoFilled,
  Loading,
  QuestionFilled,
  Monitor,
  Lock,
  Connection,
} from '@element-plus/icons-vue'

const router = useRouter()
const connectionStore = useConnectionStore()

const systemInfo = ref(null)
const loadingVisible = ref(false)
const refreshInterval = ref(30)
const pageSize = ref(20)

// 连接模式相关
const connectionMode = ref('auto')
const remoteServerUrl = ref('')
const remotePasswordInput = ref('')
const connecting = ref(false)

// 密码修改相关
const passwordForm = ref({ current: '', newPass: '', confirm: '' })
const changingPassword = ref(false)

// 使用说明对话框
const showHelpDialog = ref(false)

// 内网穿透设置
const tunnelSettings = ref({
  provider: 'none',
  publicUrl: '',
  serverAddr: '',
  token: '',
})

// 实时显示当前服务器地址
const currentServerAddress = computed(() => {
  if (connectionStore.mode === 'remote' && connectionStore.serverUrl) {
    return connectionStore.serverUrl
  }
  if (connectionStore.mode === 'local' && connectionStore.dbPath) {
    return '本地: ' + connectionStore.dbPath
  }
  return ''
})

// 统一提取数据库信息（兼容本地和远程模式）
const dbInfo = computed(() => {
  if (!systemInfo.value) return null
  if (systemInfo.value.database) return systemInfo.value.database
  if (systemInfo.value.path) return systemInfo.value
  return null
})

// 加载设置
function loadSettings() {
  try {
    const saved = localStorage.getItem('toolapp-admin-settings')
    if (saved) {
      const settings = JSON.parse(saved)
      refreshInterval.value = settings.refreshInterval ?? 30
      pageSize.value = settings.pageSize ?? 20
      connectionMode.value = settings.connectionMode ?? 'auto'
      remoteServerUrl.value = settings.remoteServerUrl ?? ''
      tunnelSettings.value = settings.tunnelSettings || { provider: 'none', publicUrl: '', serverAddr: '', token: '' }
    }
  } catch (e) {
    // 使用默认值
  }
}

// 保存设置
function saveSettings() {
  try {
    localStorage.setItem(
      'toolapp-admin-settings',
      JSON.stringify({
        refreshInterval: refreshInterval.value,
        pageSize: pageSize.value,
        connectionMode: connectionMode.value,
        remoteServerUrl: remoteServerUrl.value,
        tunnelSettings: tunnelSettings.value,
      })
    )
    ElMessage.success('设置已保存')
  } catch (e) {
    ElMessage.error('设置保存失败')
  }
}

// 保存内网穿透设置
function saveTunnelSettings() {
  saveSettings()
}

// 处理连接模式切换
async function handleModeChange(mode) {
  saveSettings()

  if (mode === 'auto') {
    // 自动模式：尝试本地连接
    if (!connectionStore.connected || connectionStore.mode !== 'local') {
      await handleScanLocal()
    }
  } else if (mode === 'local') {
    if (!connectionStore.connected || connectionStore.mode !== 'local') {
      await handleScanLocal()
    }
  }
  // remote 模式需要用户手动点击连接
}

// 扫描本地数据库
async function handleScanLocal() {
  connecting.value = true
  try {
    const result = await connectionStore.autoScanAndConnect()
    if (result.success) {
      ElMessage.success('已连接本地数据库')
      refreshData()
    } else {
      ElMessage.warning('未找到本地数据库: ' + (result.error || ''))
    }
  } catch (err) {
    ElMessage.error('扫描失败: ' + err.message)
  } finally {
    connecting.value = false
  }
}

// 手动选择数据库文件
async function handleSelectDbFile() {
  try {
    const dbPath = await api.selectDbFile()
    if (dbPath) {
      const result = await connectionStore.connectLocal(dbPath)
      if (result.success) {
        ElMessage.success('已连接本地数据库')
        refreshData()
      } else {
        ElMessage.error('连接失败: ' + result.error)
      }
    }
  } catch (err) {
    ElMessage.error('选择文件失败')
  }
}

// 连接远程服务器
async function handleConnectRemote() {
  if (!remoteServerUrl.value) {
    ElMessage.warning('请输入服务器地址')
    return
  }
  if (!remotePasswordInput.value) {
    ElMessage.warning('请输入管理密码')
    return
  }

  connecting.value = true
  try {
    const result = await connectionStore.connectRemote(remoteServerUrl.value, remotePasswordInput.value)
    if (result.success) {
      ElMessage.success('已连接远程服务器')
      saveSettings()
      refreshData()
    } else {
      ElMessage.error('连接失败: ' + (result.error || '未知错误'))
    }
  } catch (err) {
    ElMessage.error('连接异常: ' + err.message)
  } finally {
    connecting.value = false
  }
}

// 修改管理员密码
async function handleChangePassword() {
  const { current, newPass, confirm } = passwordForm.value
  if (!current) {
    ElMessage.warning('请输入当前密码')
    return
  }
  if (!newPass || newPass.length < 4) {
    ElMessage.warning('新密码长度至少4位')
    return
  }
  if (newPass !== confirm) {
    ElMessage.warning('两次输入的新密码不一致')
    return
  }

  changingPassword.value = true
  try {
    const result = await api.changePassword(newPass)
    if (result.success) {
      ElMessage.success('密码修改成功')
      passwordForm.value = { current: '', newPass: '', confirm: '' }
    } else {
      ElMessage.error('密码修改失败: ' + (result.error || '未知错误'))
    }
  } catch (err) {
    ElMessage.error('密码修改异常: ' + err.message)
  } finally {
    changingPassword.value = false
  }
}

// 刷新系统信息
async function refreshData() {
  loadingVisible.value = true
  try {
    let mode = connectionStore.mode
    if (!mode) {
      try {
        mode = await api.getMode()
        if (mode) {
          connectionStore.mode = mode
        }
      } catch (e) {
        // 忽略
      }
    }

    if (mode === 'remote') {
      const info = await api.getSystemInfo()
      if (info && !info.error) {
        systemInfo.value = info
      } else {
        systemInfo.value = null
        ElMessage.warning('获取系统信息失败: ' + (info?.error || '未知错误'))
      }
    } else if (mode === 'local') {
      const info = await api.getLocalDatabaseInfo()
      if (info && !info.error) {
        systemInfo.value = info
      } else {
        systemInfo.value = null
        ElMessage.warning('获取数据库信息失败: ' + (info?.error || '未知错误'))
      }
    } else {
      systemInfo.value = null
    }
    if (systemInfo.value) {
      ElMessage.success('数据已刷新')
    }
  } catch (err) {
    ElMessage.error('刷新失败: ' + (err.message || String(err)))
    systemInfo.value = null
  } finally {
    loadingVisible.value = false
  }
}

// 格式化运行时长
function formatUptime(seconds) {
  if (!seconds) return '未知'
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return `${days}天 ${hours}小时 ${minutes}分钟`
  if (hours > 0) return `${hours}小时 ${minutes}分钟`
  return `${minutes}分钟`
}

// 格式化字节
function formatBytes(bytes) {
  if (!bytes) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let size = bytes
  let unitIndex = 0
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex++
  }
  return size.toFixed(2) + ' ' + units[unitIndex]
}

// 断开连接
async function handleDisconnect() {
  await connectionStore.disconnect()
  router.push('/')
}

// 自动刷新定时器
let autoRefreshTimer = null

function startAutoRefresh() {
  stopAutoRefresh()
  if (refreshInterval.value > 0) {
    autoRefreshTimer = setInterval(() => {
      refreshData()
    }, refreshInterval.value * 1000)
  }
}

function stopAutoRefresh() {
  if (autoRefreshTimer) {
    clearInterval(autoRefreshTimer)
    autoRefreshTimer = null
  }
}

onMounted(() => {
  loadSettings()
  refreshData()
  startAutoRefresh()
})

onBeforeUnmount(() => {
  stopAutoRefresh()
})
</script>

<style scoped>
.settings-view {
  padding: 20px;
}
.settings-view h2 {
  margin: 0 0 20px 0;
  color: #303133;
  font-size: 22px;
}
.setting-card {
  margin-bottom: 20px;
}
.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 600;
  color: #303133;
}
code {
  background: #f5f7fa;
  padding: 4px 8px;
  border-radius: 4px;
  font-family: Consolas, Monaco, monospace;
  font-size: 13px;
  color: #e6a23c;
}
.action-buttons {
  display: flex;
  gap: 10px;
  margin-top: 20px;
}
.mr-5 {
  margin-right: 8px;
  margin-bottom: 4px;
}
.form-tip {
  color: #909399;
  font-size: 13px;
}
.help-content h4 {
  margin: 16px 0 8px 0;
  color: #303133;
  font-size: 15px;
}
.help-content h4:first-child {
  margin-top: 0;
}
.help-content p {
  color: #606266;
  font-size: 14px;
  line-height: 1.6;
  margin: 4px 0;
}
.help-content ul {
  padding-left: 20px;
  margin: 4px 0 12px 0;
}
.help-content li {
  color: #606266;
  font-size: 13px;
  line-height: 1.8;
}
.help-content code {
  font-size: 12px;
  padding: 2px 6px;
}
</style>
