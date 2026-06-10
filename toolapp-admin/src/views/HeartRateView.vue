<template>
  <AppLayout>
    <div class="data-page">
      <div class="page-header">
        <h2>心率数据</h2>
        <div class="page-actions">
          <el-select v-model="filterUserId" placeholder="按用户筛选" clearable style="width: 200px" @change="loadData">
            <el-option v-for="u in userOptions" :key="u.id" :label="u.email" :value="u.id" />
          </el-select>
        </div>
      </div>

      <el-card shadow="hover">
        <el-table :data="rows" stripe v-loading="loading" style="width: 100%">
          <el-table-column prop="id" label="ID" width="70" />
          <el-table-column prop="user_id" label="用户ID" width="80" />
          <el-table-column prop="bpm" label="心率(BPM)" width="120" />
          <el-table-column prop="status" label="状态" width="100">
            <template #default="{ row }">
              <el-tag :type="statusType(row.status)" size="small">{{ statusText(row.status) }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="timestamp" label="记录时间" min-width="180" />
          <el-table-column label="操作" width="120" fixed="right">
            <template #default="{ row }">
              <el-popconfirm title="确定删除该记录？" @confirm="handleDelete(row.id)">
                <template #reference>
                  <el-button type="danger" size="small" text>删除</el-button>
                </template>
              </el-popconfirm>
            </template>
          </el-table-column>
        </el-table>

        <el-pagination
          v-if="total > 0"
          class="pagination"
          layout="total, prev, pager, next"
          :total="total"
          :page-size="pageSize"
          :current-page="currentPage"
          @current-change="handlePageChange"
        />
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import AppLayout from '@/components/AppLayout.vue'
import { api } from '@/utils/api'

const rows = ref([])
const loading = ref(false)
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)
const filterUserId = ref('')
const userOptions = ref([])

onMounted(async () => {
  await loadUserOptions()
  loadData()
})

async function loadUserOptions() {
  try {
    const result = await api.getUsers({ page: 1, pageSize: 1000 })
    userOptions.value = result.rows || []
  } catch { /* ignore */ }
}

async function loadData() {
  loading.value = true
  try {
    const result = await api.getTableData('heart_rate_sessions', {
      page: currentPage.value,
      pageSize: pageSize.value,
      userId: filterUserId.value,
    })
    rows.value = result.rows || []
    total.value = result.total || 0
  } catch (err) {
    ElMessage.error('加载数据失败: ' + err.message)
  } finally {
    loading.value = false
  }
}

function handlePageChange(page) {
  currentPage.value = page
  loadData()
}

async function handleDelete(id) {
  try {
    await api.deleteRecord('heart_rate_sessions', id)
    ElMessage.success('删除成功')
    loadData()
  } catch (err) {
    ElMessage.error('删除失败: ' + err.message)
  }
}

function statusType(status) {
  const map = { normal: 'success', elevated: 'warning', high: 'danger' }
  return map[status] || 'info'
}

function statusText(status) {
  const map = { normal: '正常', elevated: '偏高', high: '过高' }
  return map[status] || status
}
</script>

<style scoped>
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
}
.page-header h2 { margin: 0; }
.pagination { margin-top: 16px; justify-content: flex-end; }
</style>
