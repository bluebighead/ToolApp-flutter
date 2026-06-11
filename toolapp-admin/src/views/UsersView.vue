<template>
  <AppLayout>
    <div class="users-page">
      <div class="page-header">
        <h2>用户管理</h2>
        <div class="page-actions">
          <el-button type="success" @click="openCreateDialog">
            <el-icon><Plus /></el-icon>
            添加用户
          </el-button>
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
          <el-table-column label="操作" width="160" fixed="right">
            <template #default="{ row }">
              <el-button type="primary" size="small" text @click="openDeviceDialog(row.id)">设备参数</el-button>
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

      <!-- 添加用户对话框 -->
      <el-dialog v-model="createDialogVisible" title="添加用户" width="420px">
        <el-form :model="createForm" label-width="100px" ref="createFormRef" :rules="createRules">
          <el-form-item label="账号类型" prop="accountType">
            <el-radio-group v-model="createForm.accountType">
              <el-radio value="email">邮箱用户</el-radio>
              <el-radio value="admin">管理员账号</el-radio>
            </el-radio-group>
          </el-form-item>
          <el-form-item :label="createForm.accountType === 'admin' ? '账号名' : '邮箱'" prop="email">
            <el-input
              v-model="createForm.email"
              :placeholder="createForm.accountType === 'admin' ? '请输入账号名（如 admin01）' : '请输入邮箱（如 user@example.com）'"
            />
          </el-form-item>
          <el-form-item label="密码" prop="password">
            <el-input v-model="createForm.password" type="password" placeholder="请输入密码（至少6位）" show-password />
          </el-form-item>
          <el-form-item label="确认密码" prop="confirmPassword">
            <el-input v-model="createForm.confirmPassword" type="password" placeholder="请再次输入密码" show-password />
          </el-form-item>
        </el-form>
        <template #footer>
          <el-button @click="createDialogVisible = false">取消</el-button>
          <el-button type="primary" :loading="creating" @click="handleCreate">确定</el-button>
        </template>
      </el-dialog>

      <!-- 设备参数对话框 -->
      <el-dialog v-model="deviceDialogVisible" title="用户设备参数" width="560px">
        <div v-loading="deviceLoading">
          <el-descriptions v-if="currentDeviceInfo && !currentDeviceInfo.error" :column="1" border>
            <el-descriptions-item label="平台">{{ currentDeviceInfo.platform || '—' }}</el-descriptions-item>
            <el-descriptions-item label="设备型号">{{ currentDeviceInfo.model || '—' }}</el-descriptions-item>
            <el-descriptions-item label="品牌">{{ currentDeviceInfo.brand || '—' }}</el-descriptions-item>
            <el-descriptions-item label="系统版本">{{ currentDeviceInfo.os_version || '—' }}</el-descriptions-item>
            <el-descriptions-item label="SDK 版本">{{ currentDeviceInfo.sdk_version || '—' }}</el-descriptions-item>
            <el-descriptions-item label="屏幕尺寸">
              {{ currentDeviceInfo.screen_width && currentDeviceInfo.screen_height 
                ? currentDeviceInfo.screen_width + ' × ' + currentDeviceInfo.screen_height 
                : '—' }}
            </el-descriptions-item>
            <el-descriptions-item label="总内存 (MB)">{{ currentDeviceInfo.total_memory || '—' }}</el-descriptions-item>
            <el-descriptions-item label="总存储 (MB)">{{ currentDeviceInfo.total_storage || '—' }}</el-descriptions-item>
            <el-descriptions-item label="CPU 架构">{{ currentDeviceInfo.cpu_arch || '—' }}</el-descriptions-item>
            <el-descriptions-item label="CPU 核心数">{{ currentDeviceInfo.cpu_cores || '—' }}</el-descriptions-item>
            <el-descriptions-item label="物理设备">
              {{ currentDeviceInfo.is_physical_device === 1 ? '是' : (currentDeviceInfo.is_physical_device === 0 ? '否' : '—') }}
            </el-descriptions-item>
            <el-descriptions-item label="App 版本">{{ currentDeviceInfo.app_version || '—' }}</el-descriptions-item>
            <el-descriptions-item label="更新时间">{{ currentDeviceInfo.updated_at || '—' }}</el-descriptions-item>
          </el-descriptions>
          <el-empty v-else-if="!deviceLoading" :description="currentDeviceInfo?.error ? '加载失败: ' + currentDeviceInfo.error : '该用户暂无设备参数数据'" />
        </div>
        <template #footer>
          <el-button @click="deviceDialogVisible = false">关闭</el-button>
        </template>
      </el-dialog>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, reactive, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import { View, Hide, Refresh, Search, DocumentCopy, Plus } from '@element-plus/icons-vue'
import AppLayout from '@/components/AppLayout.vue'
import { api } from '@/utils/api'

const users = ref([])
const loading = ref(false)
const searchText = ref('')
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

// 设备参数对话框相关
const deviceDialogVisible = ref(false)
const currentDeviceInfo = ref(null)
const deviceLoading = ref(false)

// 打开设备参数对话框
async function openDeviceDialog(userId) {
  deviceDialogVisible.value = true
  currentDeviceInfo.value = null
  deviceLoading.value = true
  try {
    const result = await api.getUserDeviceInfo(userId)
    currentDeviceInfo.value = result
  } catch (err) {
    currentDeviceInfo.value = { error: err.message }
  } finally {
    deviceLoading.value = false
  }
}

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

// 添加用户相关
const createDialogVisible = ref(false)
const creating = ref(false)
const createFormRef = ref(null)
const createForm = reactive({
  accountType: 'email', // email: 邮箱用户, admin: 管理员账号
  email: '',
  password: '',
  confirmPassword: '',
})

// 邮箱正则：必须是有效的邮箱格式（如 user@example.com）
// - 用户名部分：字母、数字、下划线、点号、连字符
// - 域名部分：必须包含至少一个点号，后缀为2-10个字母
const strictEmailRegex = /^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,10}$/

const validateCreateEmail = (rule, value, callback) => {
  if (!value || !value.trim()) {
    callback(new Error('请输入账号'))
    return
  }
  const trimmed = value.trim()
  if (createForm.accountType === 'email') {
    // 邮箱用户：严格校验邮箱格式
    if (!strictEmailRegex.test(trimmed)) {
      callback(new Error('邮箱格式不正确，请输入有效的邮箱（如 user@example.com）'))
      return
    }
  } else {
    // 管理员账号：限制长度，且不允许包含空格或特殊字符
    if (trimmed.length > 64) {
      callback(new Error('账号名称不能超过64个字符'))
      return
    }
    if (/\s/.test(trimmed)) {
      callback(new Error('账号名称不能包含空格'))
      return
    }
  }
  callback()
}

const validateConfirmPassword = (rule, value, callback) => {
  if (!value) {
    callback(new Error('请再次输入密码'))
  } else if (value !== createForm.password) {
    callback(new Error('两次输入的密码不一致'))
  } else {
    callback()
  }
}

const createRules = {
  email: [{ validator: validateCreateEmail, trigger: 'blur' }],
  password: [{ required: true, min: 6, message: '密码至少需要6位', trigger: 'blur' }],
  confirmPassword: [{ validator: validateConfirmPassword, trigger: 'blur' }],
}

function openCreateDialog() {
  createForm.accountType = 'email'
  createForm.email = ''
  createForm.password = ''
  createForm.confirmPassword = ''
  createDialogVisible.value = true
}

async function handleCreate() {
  if (!createFormRef.value) return
  await createFormRef.value.validate(async (valid) => {
    if (!valid) return
    creating.value = true
    try {
      const result = await api.createUser(createForm.email.trim(), createForm.password, createForm.accountType)
      if (result && result.success) {
        ElMessage.success('用户添加成功')
        createDialogVisible.value = false
        loadUsers()
      } else {
        ElMessage.error('添加失败: ' + (result?.error || '未知错误'))
      }
    } catch (err) {
      ElMessage.error('添加失败: ' + err.message)
    } finally {
      creating.value = false
    }
  })
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
