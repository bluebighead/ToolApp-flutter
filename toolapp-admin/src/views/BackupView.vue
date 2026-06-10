<template>
  <AppLayout>
    <div class="backup-page">
      <h2 class="page-title">数据备份与导出</h2>

      <el-row :gutter="20">
        <!-- 数据库备份（仅本地模式） -->
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>
              <div class="card-header">
                <el-icon><FolderOpened /></el-icon>
                <span>数据库备份</span>
              </div>
            </template>
            <p class="card-desc">将整个数据库文件备份到指定位置（仅本地模式可用）</p>
            <el-button
              type="primary"
              :disabled="connectionStore.mode !== 'local'"
              :loading="backupLoading"
              @click="handleBackup"
            >
              备份数据库
            </el-button>
            <el-tag v-if="connectionStore.mode !== 'local'" type="info" size="small" style="margin-left: 8px">
              仅本地模式
            </el-tag>
          </el-card>
        </el-col>

        <!-- 数据表导出 -->
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>
              <div class="card-header">
                <el-icon><Download /></el-icon>
                <span>数据表导出</span>
              </div>
            </template>
            <el-form label-width="80px">
              <el-form-item label="选择表">
                <el-select v-model="exportTable" style="width: 100%">
                  <el-option label="用户表" value="users" />
                  <el-option label="心率数据" value="heart_rate_sessions" />
                  <el-option label="网速数据" value="network_speed_records" />
                  <el-option label="转换历史" value="convert_history" />
                  <el-option label="骰子记录" value="dice_records" />
                  <el-option label="经期记录" value="period_records" />
                </el-select>
              </el-form-item>
              <el-form-item label="导出格式">
                <el-radio-group v-model="exportFormat">
                  <el-radio value="csv">CSV</el-radio>
                  <el-radio value="json">JSON</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item>
                <el-button type="success" :loading="exportLoading" @click="handleExport">
                  导出数据
                </el-button>
              </el-form-item>
            </el-form>
          </el-card>
        </el-col>
      </el-row>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref } from 'vue'
import { ElMessage } from 'element-plus'
import AppLayout from '@/components/AppLayout.vue'
import { useConnectionStore } from '@/stores/connection'
import { api } from '@/utils/api'

const connectionStore = useConnectionStore()
const backupLoading = ref(false)
const exportLoading = ref(false)
const exportTable = ref('users')
const exportFormat = ref('csv')

// 备份数据库
async function handleBackup() {
  backupLoading.value = true
  try {
    const result = await api.backupDatabase()
    if (result.success) {
      ElMessage.success(`备份成功: ${result.path}`)
    } else {
      ElMessage.info('已取消备份')
    }
  } catch (err) {
    ElMessage.error('备份失败: ' + err.message)
  } finally {
    backupLoading.value = false
  }
}

// 导出数据表
async function handleExport() {
  exportLoading.value = true
  try {
    const result = await api.exportTable(exportTable.value, exportFormat.value)
    const ext = exportFormat.value
    const defaultName = `${exportTable.value}_${new Date().toISOString().slice(0, 10)}.${ext}`
    const filePath = await api.selectSavePath(defaultName)
    if (!filePath) {
      ElMessage.info('已取消导出')
      return
    }
    await api.saveExport({ data: result.data, filePath })
    ElMessage.success(`导出成功: ${filePath}`)
  } catch (err) {
    ElMessage.error('导出失败: ' + err.message)
  } finally {
    exportLoading.value = false
  }
}
</script>

<style scoped>
.page-title {
  margin-bottom: 20px;
  color: #303133;
}
.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
}
.card-desc {
  color: #909399;
  font-size: 14px;
  margin-bottom: 16px;
}
</style>
