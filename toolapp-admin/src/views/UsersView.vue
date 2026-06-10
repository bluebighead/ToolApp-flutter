<template>
  <AppLayout>
    <div class="users-page">
      <div class="page-header">
        <h2>用户管理</h2>
        <div class="page-actions">
          <el-input v-model="searchText" placeholder="搜索邮箱" clearable style="width: 240px" @clear="loadUsers" @keyup.enter="loadUsers">
            <template #prefix><el-icon><Search /></el-icon></template>
          </el-input>
          <el-button type="primary" @click="loadUsers">搜索</el-button>
        </div>
      </div>

      <el-card shadow="hover">
        <el-table :data="users" stripe v-loading="loading" style="width: 100%">
          <el-table-column prop="id" label="ID" width="80" />
          <el-table-column prop="email" label="邮箱" min-width="200" />
          <el-table-column prop="created_at" label="注册时间" width="180" />
          <el-table-column label="数据量" width="320">
            <template #default="{ row }">
              <el-tag size="small" type="success">心率{{ row.dataCount?.heartRate || 0 }}</el-tag>
              <el-tag size="small" type="warning">网速{{ row.dataCount?.networkSpeed || 0 }}</el-tag>
              <el-tag size="small" type="danger">转换{{ row.dataCount?.convert || 0 }}</el-tag>
              <el-tag size="small" type="info">骰子{{ row.dataCount?.dice || 0 }}</el-tag>
              <el-tag size="small">经期{{ row.dataCount?.period || 0 }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="120" fixed="right">
            <template #default="{ row }">
              <el-popconfirm title="确定删除该用户及其所有数据？" @confirm="handleDelete(row.id)">
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

const users = ref([])
const loading = ref(false)
const searchText = ref('')
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

onMounted(() => {
  loadUsers()
})

async function loadUsers() {
  loading.value = true
  try {
    const result = await api.getUsers({
      page: currentPage.value,
      pageSize: pageSize.value,
      search: searchText.value,
    })
    users.value = result.rows || []
    total.value = result.total || 0
  } catch (err) {
    ElMessage.error('加载用户失败: ' + err.message)
  } finally {
    loading.value = false
  }
}

function handlePageChange(page) {
  currentPage.value = page
  loadUsers()
}

async function handleDelete(userId) {
  try {
    await api.deleteUser(userId)
    ElMessage.success('删除成功')
    loadUsers()
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
.page-header h2 {
  margin: 0;
  color: #303133;
}
.page-actions {
  display: flex;
  gap: 8px;
}
.pagination {
  margin-top: 16px;
  justify-content: flex-end;
}
.el-tag {
  margin-right: 4px;
  margin-bottom: 2px;
}
</style>
