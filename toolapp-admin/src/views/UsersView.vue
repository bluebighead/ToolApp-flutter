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
        <el-table :data="users" stripe v-loading="loading" style="width: 100%" border>
          <el-table-column prop="id" label="ID" width="80" resizable />
          <el-table-column prop="email" label="邮箱" min-width="200" resizable />
          <!-- 密码哈希列：默认隐藏，点击小眼睛切换显示，可复制 -->
          <el-table-column label="密码哈希" min-width="280" resizable>
            <template #default="{ row }">
              <div class="password-cell">
                <template v-if="visiblePasswords[row.id]">
                  <code class="hash-text" :title="row.password_hash">{{ row.password_hash || '—' }}</code>
                  <el-button
                    circle
                    size="small"
                    text
                    @click="copyHash(row.password_hash)"
                    title="复制哈希值"
                  >
                    <el-icon><DocumentCopy /></el-icon>
                  </el-button>
                </template>
                <span v-else class="password-mask">••••••••••••</span>
                <el-button
                  :icon="visiblePasswords[row.id] ? Hide : View"
                  circle
                  size="small"
                  text
                  @click="togglePassword(row.id)"
                  :title="visiblePasswords[row.id] ? '隐藏' : '显示'"
                  style="margin-left: 4px"
                />
              </div>
            </template>
          </el-table-column>
          <el-table-column prop="created_at" label="注册时间" min-width="180" resizable />
          <el-table-column label="数据量" min-width="320" resizable>
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

      <!-- 右下角刷新按钮 -->
      <div class="fab-refresh" @click="loadUsers" title="刷新用户列表">
        <el-icon :size="24" :class="{ 'is-loading': loading }"><Refresh /></el-icon>
      </div>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, reactive, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import { View, Hide, Refresh, Search, DocumentCopy } from '@element-plus/icons-vue'
import AppLayout from '@/components/AppLayout.vue'
import { api } from '@/utils/api'

const users = ref([])
const loading = ref(false)
const searchText = ref('')
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

// 密码可见性状态
const visiblePasswords = reactive({})

// 切换密码显示/隐藏
function togglePassword(userId) {
  visiblePasswords[userId] = !visiblePasswords[userId]
}

// 复制哈希值到剪贴板
async function copyHash(hash) {
  if (!hash) return
  try {
    await navigator.clipboard.writeText(hash)
    ElMessage.success('已复制到剪贴板')
  } catch {
    ElMessage.warning('复制失败，请手动选择复制')
  }
}

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
/* 密码单元格 */
.password-cell {
  display: flex;
  align-items: center;
  gap: 2px;
}
.password-mask {
  color: #c0c4cc;
  letter-spacing: 2px;
  font-size: 14px;
}
/* 哈希值文本样式 */
.hash-text {
  background: #f5f7fa;
  padding: 2px 6px;
  border-radius: 4px;
  font-family: Consolas, Monaco, monospace;
  font-size: 12px;
  color: #909399;
  word-break: break-all;
  max-width: 300px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  display: inline-block;
}
/* 右下角浮动刷新按钮 */
.fab-refresh {
  position: fixed;
  right: 40px;
  bottom: 40px;
  width: 56px;
  height: 56px;
  border-radius: 50%;
  background: #409eff;
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  box-shadow: 0 4px 12px rgba(64, 158, 255, 0.4);
  transition: all 0.3s;
  z-index: 100;
}
.fab-refresh:hover {
  background: #66b1ff;
  transform: scale(1.1);
  box-shadow: 0 6px 16px rgba(64, 158, 255, 0.5);
}
.fab-refresh:active {
  transform: scale(0.95);
}
</style>
