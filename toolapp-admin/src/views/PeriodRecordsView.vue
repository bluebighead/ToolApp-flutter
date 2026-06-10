<template>
  <AppLayout>
    <div class="data-page">
      <div class="page-header">
        <h2>经期记录</h2>
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
          <el-table-column prop="start_date" label="开始日期" width="130" />
          <el-table-column prop="end_date" label="结束日期" width="130" />
          <el-table-column prop="cycle_length" label="周期天数" width="100" />
          <el-table-column prop="period_length" label="持续天数" width="100" />
          <el-table-column prop="symptoms" label="症状" min-width="200">
            <template #default="{ row }">
              {{ row.symptoms || '-' }}
            </template>
          </el-table-column>
          <el-table-column prop="notes" label="备注" min-width="150">
            <template #default="{ row }">
              {{ row.notes || '-' }}
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
    const result = await api.getTableData('period_records', {
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
    await api.deleteRecord('period_records', id)
    ElMessage.success('删除成功')
    loadData()
  } catch (err) {
    ElMessage.error('删除失败: ' + err.message)
  }
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
