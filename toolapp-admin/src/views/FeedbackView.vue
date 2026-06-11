<template>
  <AppLayout>
    <div class="feedback-page">
      <div class="page-header">
        <h2>用户反馈</h2>
        <div class="page-actions">
          <el-button type="primary" @click="loadFeedbacks">
            <el-icon><Refresh /></el-icon>
            刷新
          </el-button>
        </div>
      </div>

      <el-card shadow="hover">
        <el-table :data="feedbacks" stripe v-loading="loading" style="width: 100%" border>
          <el-table-column prop="id" label="ID" width="80" resizable />
          <el-table-column prop="user_email" label="用户邮箱" min-width="180" resizable />
          <el-table-column prop="content" label="反馈内容" min-width="400" resizable>
            <template #default="{ row }">
              <div class="feedback-content">{{ row.content }}</div>
            </template>
          </el-table-column>
          <el-table-column prop="contact" label="联系方式" min-width="160" resizable>
            <template #default="{ row }">
              <span v-if="row.contact">{{ row.contact }}</span>
              <span v-else class="text-muted">—</span>
            </template>
          </el-table-column>
          <el-table-column prop="device_info" label="设备信息" min-width="200" resizable>
            <template #default="{ row }">
              <span v-if="row.device_info" class="device-info">{{ row.device_info }}</span>
              <span v-else class="text-muted">—</span>
            </template>
          </el-table-column>
          <el-table-column prop="created_at" label="提交时间" min-width="180" resizable />
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
        <el-empty v-if="!loading && total === 0" description="暂无用户反馈" />
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import AppLayout from '@/components/AppLayout.vue'
import { ElMessage } from 'element-plus'
import { api } from '@/utils/api'

const loading = ref(false)
const feedbacks = ref([])
const total = ref(0)
const currentPage = ref(1)
const pageSize = 20

async function loadFeedbacks() {
  loading.value = true
  try {
    const result = await api.getFeedbacks({
      page: currentPage.value,
      pageSize: pageSize.value,
    })
    feedbacks.value = result.rows || []
    total.value = result.total || 0
  } catch (err) {
    ElMessage.error('加载反馈失败: ' + err.message)
  } finally {
    loading.value = false
  }
}

function handlePageChange(page) {
  currentPage.value = page
  loadFeedbacks()
}

onMounted(() => {
  loadFeedbacks()
})
</script>

<style scoped>
.feedback-page {
  width: 100%;
}
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
}
.page-header h2 {
  margin: 0;
  font-size: 22px;
  font-weight: 600;
  color: #303133;
}
.page-actions {
  display: flex;
  gap: 10px;
}
.pagination {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}
.feedback-content {
  white-space: pre-wrap;
  word-break: break-word;
  line-height: 1.6;
  color: #303133;
}
.device-info {
  font-size: 12px;
  color: #606266;
}
.text-muted {
  color: #c0c4cc;
}
</style>
