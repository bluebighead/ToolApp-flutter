<template>
  <AppLayout>
    <div class="data-page">
      <div class="page-header">
        <h2>转换历史</h2>
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
          <el-table-column prop="input_value" label="输入值" min-width="120" />
          <el-table-column prop="input_unit" label="输入单位" width="100">
            <template #default="{ row }">{{ unitText(row.input_unit) }}</template>
          </el-table-column>
          <el-table-column prop="output_value" label="输出值" min-width="120" />
          <el-table-column prop="output_unit" label="输出单位" width="100">
            <template #default="{ row }">{{ unitText(row.output_unit) }}</template>
          </el-table-column>
          <el-table-column prop="category" label="转换类别" width="120">
            <template #default="{ row }">{{ categoryText(row.category) }}</template>
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
    const result = await api.getTableData('convert_history', {
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
    await api.deleteRecord('convert_history', id)
    ElMessage.success('删除成功')
    loadData()
  } catch (err) {
    ElMessage.error('删除失败: ' + err.message)
  }
}

function unitText(unit) {
  const map = {
    'm': '米', 'km': '千米', 'cm': '厘米', 'mm': '毫米',
    'kg': '千克', 'g': '克', 'lb': '磅',
    '℃': '摄氏度', '℉': '华氏度', 'K': '开尔文',
    'm/s': '米/秒', 'km/h': '千米/时', 'mph': '英里/时',
    's': '秒', 'min': '分钟', 'h': '小时',
    'm²': '平方米', 'km²': '平方千米', 'ha': '公顷', '亩': '亩',
    'L': '升', 'mL': '毫升',
    'B': '字节', 'KB': '千字节', 'MB': '兆字节', 'GB': '吉字节', 'TB': '太字节',
  }
  return map[unit] || unit
}

function categoryText(category) {
  const map = {
    'length': '长度', 'weight': '重量', 'temperature': '温度',
    'speed': '速度', 'time': '时间', 'area': '面积',
    'volume': '体积', 'data': '数据存储', 'currency': '货币',
  }
  return map[category] || category
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
