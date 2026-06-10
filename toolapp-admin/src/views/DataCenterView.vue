<template>
  <AppLayout>
  <div class="data-center">
    <h2 class="page-title">
      <el-icon><DataAnalysis /></el-icon>
      数据中心
    </h2>

    <!-- 数据概览 -->
    <el-row :gutter="20" class="overview-row">
      <el-col :span="4">
        <el-card shadow="hover" class="overview-card" @click="activeTab = 'heartRate'">
          <el-icon :size="30" class="icon heart"><Monitor /></el-icon>
          <div class="count">{{ dataStats.heart_rate_sessions || 0 }}</div>
          <div class="label">心率记录</div>
        </el-card>
      </el-col>
      <el-col :span="4">
        <el-card shadow="hover" class="overview-card" @click="activeTab = 'networkSpeed'">
          <el-icon :size="30" class="icon network"><Connection /></el-icon>
          <div class="count">{{ dataStats.network_speed_records || 0 }}</div>
          <div class="label">网速记录</div>
        </el-card>
      </el-col>
      <el-col :span="4">
        <el-card shadow="hover" class="overview-card" @click="activeTab = 'convert'">
          <el-icon :size="30" class="icon convert"><VideoCamera /></el-icon>
          <div class="count">{{ dataStats.convert_history || 0 }}</div>
          <div class="label">转换记录</div>
        </el-card>
      </el-col>
      <el-col :span="4">
        <el-card shadow="hover" class="overview-card" @click="activeTab = 'dice'">
          <el-icon :size="30" class="icon dice"><Coin /></el-icon>
          <div class="count">{{ dataStats.dice_records || 0 }}</div>
          <div class="label">骰子记录</div>
        </el-card>
      </el-col>
      <el-col :span="4">
        <el-card shadow="hover" class="overview-card" @click="activeTab = 'period'">
          <el-icon :size="30" class="icon period"><Calendar /></el-icon>
          <div class="count">{{ dataStats.period_records || 0 }}</div>
          <div class="label">经期记录</div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 用户筛选 -->
    <el-card shadow="hover" class="filter-card">
      <div class="filter-bar">
        <span class="filter-label">筛选用户：</span>
        <el-select
          v-model="selectedUserId"
          placeholder="全部用户"
          clearable
          style="width: 250px"
          @change="loadCurrentTab"
        >
          <el-option
            v-for="user in userList"
            :key="user.id"
            :label="user.email"
            :value="user.id"
          />
        </el-select>
        <el-button type="primary" @click="loadCurrentTab" :loading="loading" style="margin-left: 10px">
          <el-icon><Refresh /></el-icon>
          刷新
        </el-button>
      </div>
    </el-card>

    <!-- 数据分类标签页 -->
    <el-card shadow="hover" class="tabs-card">
      <el-tabs v-model="activeTab" @tab-change="handleTabChange">
        <!-- 心率数据 -->
        <el-tab-pane label="心率数据" name="heartRate">
          <el-table :data="tableData" stripe v-loading="loading">
            <el-table-column prop="id" label="ID" width="80" />
            <el-table-column prop="user_id" label="用户ID" width="100" />
            <el-table-column label="开始时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.start_time) }}</template>
            </el-table-column>
            <el-table-column label="结束时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.end_time) }}</template>
            </el-table-column>
            <el-table-column prop="max_hr" label="最高心率" width="100" />
            <el-table-column prop="min_hr" label="最低心率" width="100" />
            <el-table-column prop="avg_hr" label="平均心率" width="100" />
            <el-table-column prop="connection_mode" label="连接方式" width="120" />
          </el-table>
        </el-tab-pane>

        <!-- 网速数据 -->
        <el-tab-pane label="网速数据" name="networkSpeed">
          <el-table :data="tableData" stripe v-loading="loading">
            <el-table-column prop="id" label="ID" width="80" />
            <el-table-column prop="user_id" label="用户ID" width="100" />
            <el-table-column label="测试时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.test_time) }}</template>
            </el-table-column>
            <el-table-column prop="server_url" label="服务器地址" min-width="200" />
            <el-table-column label="最小延迟(ms)" width="120">
              <template #default="{ row }">{{ row.min_latency }}</template>
            </el-table-column>
            <el-table-column label="平均延迟(ms)" width="120">
              <template #default="{ row }">{{ row.avg_latency }}</template>
            </el-table-column>
            <el-table-column label="最大延迟(ms)" width="120">
              <template #default="{ row }">{{ row.max_latency }}</template>
            </el-table-column>
            <el-table-column label="抖动(ms)" width="100">
              <template #default="{ row }">{{ row.jitter }}</template>
            </el-table-column>
            <el-table-column label="丢包率(%)" width="100">
              <template #default="{ row }">{{ row.loss_rate }}</template>
            </el-table-column>
          </el-table>
        </el-tab-pane>

        <!-- 转换历史 -->
        <el-tab-pane label="转换历史" name="convert">
          <el-table :data="tableData" stripe v-loading="loading">
            <el-table-column prop="id" label="ID" width="80" />
            <el-table-column prop="user_id" label="用户ID" width="100" />
            <el-table-column label="时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.timestamp_ms) }}</template>
            </el-table-column>
            <el-table-column prop="input_file" label="输入文件" min-width="200" show-overflow-tooltip />
            <el-table-column prop="output_file" label="输出文件" min-width="200" show-overflow-tooltip />
            <el-table-column label="输出大小(KB)" width="120">
              <template #default="{ row }">{{ row.output_size ? (row.output_size / 1024).toFixed(2) : '—' }}</template>
            </el-table-column>
            <el-table-column prop="format" label="格式" width="100" />
            <el-table-column prop="quality" label="质量" width="100" />
            <el-table-column prop="status" label="状态" width="100">
              <template #default="{ row }">
                <el-tag :type="statusType(row.status)" size="small">{{ row.status }}</el-tag>
              </template>
            </el-table-column>
          </el-table>
        </el-tab-pane>

        <!-- 骰子记录 -->
        <el-tab-pane label="骰子记录" name="dice">
          <el-table :data="tableData" stripe v-loading="loading">
            <el-table-column prop="id" label="ID" width="80" />
            <el-table-column prop="user_id" label="用户ID" width="100" />
            <el-table-column label="时间" width="180">
              <template #default="{ row }">{{ formatDateTime(row.timestamp_ms) }}</template>
            </el-table-column>
            <el-table-column prop="dice_type" label="类型" width="120">
              <template #default="{ row }">
                <el-tag type="primary" size="small">{{ row.dice_type }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column label="结果" width="150">
              <template #default="{ row }">
                <span style="font-size: 16px; font-weight: bold; color: #409eff">{{ row.result }}</span>
              </template>
            </el-table-column>
          </el-table>
        </el-tab-pane>

        <!-- 经期记录 -->
        <el-tab-pane label="经期记录" name="period">
          <el-table :data="tableData" stripe v-loading="loading">
            <el-table-column prop="id" label="ID" width="80" />
            <el-table-column prop="user_id" label="用户ID" width="100" />
            <el-table-column label="开始日期" width="180">
              <template #default="{ row }">{{ formatDateTime(row.start_date) }}</template>
            </el-table-column>
            <el-table-column label="结束日期" width="180">
              <template #default="{ row }">{{ formatDateTime(row.end_date) }}</template>
            </el-table-column>
            <el-table-column prop="record_mode" label="模式" width="120" />
            <el-table-column prop="flow_level" label="流量等级" width="100" />
            <el-table-column prop="symptoms" label="症状" min-width="200" show-overflow-tooltip />
            <el-table-column prop="notes" label="备注" min-width="200" show-overflow-tooltip />
          </el-table>
        </el-tab-pane>
      </el-tabs>

      <!-- 分页 -->
      <div class="pagination-bar" v-if="total > 0">
        <el-pagination
          v-model:current-page="currentPage"
          :page-size="pageSize"
          :total="total"
          layout="total, prev, pager, next, jumper"
          @current-change="loadCurrentTab"
        />
      </div>
    </el-card>
  </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { api } from '@/utils/api'
import AppLayout from '@/components/AppLayout.vue'
import {
  DataAnalysis,
  Monitor,
  Connection,
  VideoCamera,
  Coin,
  Calendar,
  Refresh,
} from '@element-plus/icons-vue'

const activeTab = ref('heartRate')
const selectedUserId = ref('')
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)
const loading = ref(false)
const tableData = ref([])
const userList = ref([])
const dataStats = ref({
  heart_rate_sessions: 0,
  network_speed_records: 0,
  convert_history: 0,
  dice_records: 0,
  period_records: 0,
})

const tableMap = {
  heartRate: 'heart_rate_sessions',
  networkSpeed: 'network_speed_records',
  convert: 'convert_history',
  dice: 'dice_records',
  period: 'period_records',
}

const statsKeyMap = {
  heartRate: 'heartRate',
  networkSpeed: 'networkSpeed',
  convert: 'convert',
  dice: 'dice',
  period: 'period',
}

function formatDateTime(isoStr) {
  if (!isoStr) return '—'
  try {
    // 如果是时间戳（数字）
    if (typeof isoStr === 'number' || (!isNaN(isoStr) && String(isoStr).length >= 10)) {
      const d = new Date(Number(isoStr))
      if (!isNaN(d.getTime())) {
        const y = d.getFullYear()
        const m = String(d.getMonth() + 1).padStart(2, '0')
        const day = String(d.getDate()).padStart(2, '0')
        const h = String(d.getHours()).padStart(2, '0')
        const min = String(d.getMinutes()).padStart(2, '0')
        const s = String(d.getSeconds()).padStart(2, '0')
        return `${y}-${m}-${day} ${h}:${min}:${s}`
      }
    }
    // 如果是 ISO 字符串
    const d = new Date(isoStr)
    if (!isNaN(d.getTime())) {
      const y = d.getFullYear()
      const m = String(d.getMonth() + 1).padStart(2, '0')
      const day = String(d.getDate()).padStart(2, '0')
      const h = String(d.getHours()).padStart(2, '0')
      const min = String(d.getMinutes()).padStart(2, '0')
      const s = String(d.getSeconds()).padStart(2, '0')
      return `${y}-${m}-${day} ${h}:${min}:${s}`
    }
    return String(isoStr)
  } catch (e) {
    return String(isoStr)
  }
}

function statusType(status) {
  if (!status) return 'info'
  const s = String(status).toLowerCase()
  if (s.includes('success') || s.includes('完成') || s.includes('成功')) return 'success'
  if (s.includes('error') || s.includes('fail') || s.includes('失败')) return 'danger'
  if (s.includes('process') || s.includes('ing') || s.includes('进行')) return 'warning'
  return 'info'
}

async function loadUsers() {
  try {
    const result = await api.getUsers({ page: 1, pageSize: 100 })
    if (result && result.rows) {
      userList.value = result.rows
    }
  } catch (err) {
    console.error('加载用户列表失败:', err)
  }
}

async function loadStats() {
  try {
    const stats = await api.getStats()
    if (stats) {
      dataStats.value = {
        heart_rate_sessions: stats.heartRate || 0,
        network_speed_records: stats.networkSpeed || 0,
        convert_history: stats.convert || 0,
        dice_records: stats.dice || 0,
        period_records: stats.period || 0,
      }
    }
  } catch (err) {
    console.error('加载统计数据失败:', err)
  }
}

async function loadCurrentTab() {
  const tableName = tableMap[activeTab.value]
  if (!tableName) return

  loading.value = true
  try {
    const params = {
      page: currentPage.value,
      pageSize: pageSize.value,
    }
    if (selectedUserId.value) {
      params.userId = selectedUserId.value
    }
    const result = await api.getTableData(tableName, params)
    if (result) {
      tableData.value = result.rows || []
      total.value = result.total || 0
    }
  } catch (err) {
    console.error('加载数据失败:', err)
    tableData.value = []
    total.value = 0
  } finally {
    loading.value = false
  }
}

function handleTabChange() {
  currentPage.value = 1
  loadCurrentTab()
}

onMounted(async () => {
  await loadUsers()
  await loadStats()
  await loadCurrentTab()
})
</script>

<style scoped>
.data-center {
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
.overview-row {
  margin-bottom: 20px;
}
.overview-card {
  text-align: center;
  cursor: pointer;
  transition: all 0.3s;
}
.overview-card:hover {
  transform: translateY(-3px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
}
.overview-card .icon {
  margin-bottom: 10px;
  padding: 10px;
  border-radius: 10px;
  display: inline-block;
}
.overview-card .icon.heart {
  background: #fef0f0;
  color: #f56c6c;
}
.overview-card .icon.network {
  background: #ecf5ff;
  color: #409eff;
}
.overview-card .icon.convert {
  background: #fdf6ec;
  color: #e6a23c;
}
.overview-card .icon.dice {
  background: #f0f2f5;
  color: #909399;
}
.overview-card .icon.period {
  background: #fdf2f8;
  color: #ec4899;
}
.overview-card .count {
  font-size: 28px;
  font-weight: bold;
  color: #303133;
  margin-bottom: 5px;
}
.overview-card .label {
  color: #909399;
  font-size: 14px;
}
.filter-card {
  margin-bottom: 20px;
}
.filter-bar {
  display: flex;
  align-items: center;
}
.filter-label {
  color: #606266;
  margin-right: 10px;
}
.tabs-card {
  margin-bottom: 20px;
}
.pagination-bar {
  display: flex;
  justify-content: center;
  padding-top: 20px;
}
</style>
