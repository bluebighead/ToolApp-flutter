<template>
  <div class="connect-page">
    <el-card class="connect-card" shadow="always">
      <template #header>
        <div class="connect-card-header">
          <h2>ToolApp Admin</h2>
          <p>数据库管理工具</p>
        </div>
      </template>

      <!-- 自动扫描状态 -->
      <div v-if="scanning" class="scan-status">
        <el-icon :size="40" class="loading-icon">
          <Loading />
        </el-icon>
        <p>正在自动扫描数据库...</p>
        <p class="scan-path">扫描项目目录</p>
      </div>

      <!-- 扫描结果 -->
      <div v-else>
        <!-- 自动扫描成功 -->
        <div v-if="scanResult && scanResult.found" class="found-result">
          <el-result icon="success" title="已自动连接数据库">
            <template #sub-title>
              <div>
                <p>数据库路径：
                  <el-tag type="info">{{ scanResult.dbPath }}</el-tag>
                </p>
                <p v-if="scanResult.info" style="margin-top: 12px;">
                  数据量：
                  <el-tag size="small" type="success" style="margin-left: 8px;">users: {{ scanResult.info.users || 0 }}</el-tag>
                  <el-tag size="small" type="success" style="margin-left: 8px;">heart_rate: {{ scanResult.info.heart_rate_sessions || 0 }}</el-tag>
                  <el-tag size="small" type="success" style="margin-left: 8px;">network_speed: {{ scanResult.info.network_speed_records || 0 }}</el-tag>
                </p>
              </div>
            </template>
            <el-button type="primary" size="large" @click="goToDashboard">
              进入管理界面
              <el-icon class="el-icon--right"><ArrowRight /></el-icon>
            </el-button>
          </el-result>
        </div>

        <!-- 未找到数据库 - 手动连接 -->
        <div v-else class="manual-connect">
          <el-alert
            v-if="scanError" :title="scanError" type="warning" show-icon :closable="false" style="margin-bottom: 16px;" />

          <el-form label-width="100px" @submit.prevent>
            <el-form-item label="连接模式">
              <el-radio-group v-model="connectMode">
                <el-radio value="local">本地数据库</el-radio>
                <el-radio value="remote">远程服务器</el-radio>
              </el-radio-group>
            </el-form-item>

            <template v-if="connectMode === 'local'">
              <el-form-item label="数据库路径">
                <el-input v-model="localPath" placeholder="选择或输入数据库文件路径">
                  <template #append>
                    <el-button @click="selectDbFile">浏览</el-button>
                  </template>
                </el-input>
              </el-form-item>
              <el-form-item label="扫描目录">
                <el-input v-model="scanDir" placeholder="可选：指定目录自动扫描">
                  <template #append>
                    <el-button @click="selectFolder">选择目录</el-button>
                  </template>
                </el-input>
              </el-form-item>
              <el-form-item>
                <el-button @click="scanFolder" :disabled="!scanDir" style="width: 100%;">
                  扫描目录查找数据库
                </el-button>
              </el-form-item>
            </template>

            <template v-if="connectMode === 'remote'">
              <el-form-item label="服务器地址">
                <el-input v-model="remoteUrl" placeholder="http://192.168.1.100:3000" />
              </el-form-item>
              <el-form-item label="管理员密码">
                <el-input v-model="remotePassword" type="password" placeholder="服务器管理员密码" show-password />
              </el-form-item>
            </template>

            <el-form-item>
              <el-button type="primary" @click="handleConnect" :loading="loading" style="width: 100%">
                连接
              </el-button>
            </el-form-item>

            <el-form-item>
              <el-button @click="startAutoScan" style="width: 100%">
                重新自动扫描
              </el-button>
            </el-form-item>
          </el-form>
        </div>

        <el-result v-if="errorMsg" icon="error" :title="errorMsg" />
      </div>
    </el-card>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Loading, ArrowRight } from '@element-plus/icons-vue';
import { useConnectionStore } from '@/stores/connection';
import { api } from '@/utils/api';
import { markConnected } from '@/router';

const router = useRouter();
const connectionStore = useConnectionStore();

const scanning = ref(false);
const scanResult = ref(null);
const scanError = ref('');
const connectMode = ref('local');
const localPath = ref('');
const scanDir = ref('');
const remoteUrl = ref('');
const remotePassword = ref('');
const loading = ref(false);
const errorMsg = ref('');

async function startAutoScan() {
  scanning.value = true;
  errorMsg.value = '';
  scanError.value = '';
  scanResult.value = null;

  try {
    const result = await connectionStore.autoScanAndConnect();
    scanning.value = false;

    if (result.success) {
      scanResult.value = {
        found: true,
        dbPath: connectionStore.dbPath,
        info: connectionStore.dbInfo
      };
      markConnected();
      ElMessage.success('自动连接成功');
      setTimeout(() => {
        router.push('/dashboard');
      }, 800);
    } else {
      scanError.value = result.error || '未找到数据库';
    }
  } catch (err) {
    scanning.value = false;
    scanError.value = '扫描出错: ' + err.message;
  }
}

async function selectDbFile() {
  const filePath = await api.selectDbFile();
  if (filePath) {
    localPath.value = filePath;
  }
}

async function selectFolder() {
  const folderPath = await api.selectFolder();
  if (folderPath) {
    scanDir.value = folderPath;
  }
}

async function scanFolder() {
  if (!scanDir.value) return;
  loading.value = true;
  errorMsg.value = '';
  try {
    const result = await connectionStore.scanDirectory(scanDir.value);
    if (result.success) {
      scanResult.value = {
        found: true,
        dbPath: connectionStore.dbPath,
        info: connectionStore.dbInfo
      };
      markConnected();
      ElMessage.success('连接成功');
      setTimeout(() => {
        router.push('/dashboard');
      }, 800);
    } else {
      errorMsg.value = result.error || '连接失败';
    }
  } catch (err) {
    errorMsg.value = err.message || '连接异常';
  } finally {
    loading.value = false;
  }
}

async function handleConnect() {
  loading.value = true;
  errorMsg.value = '';
  try {
    let result;
    if (connectMode.value === 'local') {
      if (!localPath.value) {
        ElMessage.warning('请选择数据库文件');
        loading.value = false;
        return;
      }
      result = await connectionStore.connectLocal(localPath.value);
    } else {
      if (!remoteUrl.value) {
        ElMessage.warning('请输入服务器地址');
        loading.value = false;
        return;
      }
      result = await connectionStore.connectRemote(remoteUrl.value, remotePassword.value);
    }

    if (result.success) {
      markConnected();
      ElMessage.success('连接成功');
      router.push('/dashboard');
    } else {
      errorMsg.value = result.error || '连接失败';
    }
  } catch (err) {
    errorMsg.value = err.message || '连接异常';
  } finally {
    loading.value = false;
  }
}

function goToDashboard() {
  router.push('/dashboard');
}

onMounted(async () => {
  // 尝试自动恢复之前的连接
  const saved = localStorage.getItem('toolapp-admin-connection');
  if (saved) {
    try {
      const data = JSON.parse(saved);
      if (data.connected) {
        scanning.value = true;
        let result;
        if (data.mode === 'remote' && data.serverUrl) {
          // 恢复远程连接（使用保存的密码）
          result = await connectionStore.connectRemote(data.serverUrl, data.remotePassword || '');
        } else if (data.mode === 'local' && data.dbPath) {
          // 恢复本地连接
          result = await connectionStore.connectLocal(data.dbPath);
        } else {
          // 没有有效连接信息，执行自动扫描
          scanning.value = false;
          startAutoScan();
          return;
        }

        scanning.value = false;
        if (result.success) {
          markConnected();
          ElMessage.success('已自动恢复连接');
          router.push('/dashboard');
          return;
        }
        // 恢复失败，清除连接状态，执行自动扫描
        await connectionStore.disconnect();
      }
    } catch (e) {
      scanning.value = false;
    }
  }
  // 没有保存的连接或恢复失败，执行自动扫描
  startAutoScan();
});
</script>

<style scoped>
.connect-page {
  height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
}
.connect-card {
  width: 560px;
  max-width: 90vw;
}
.connect-card-header {
  text-align: center;
}
.connect-card-header h2 {
  margin: 0 0 8px 0;
  color: #303133;
}
.connect-card-header p {
  margin: 0;
  color: #909399;
  font-size: 14px;
}
.scan-status {
  text-align: center;
  padding: 40px 20px;
}
.scan-status .loading-icon {
  color: #409eff;
  animation: spin 1s linear infinite;
}
.scan-status p {
  margin: 16px 0;
  color: #606266;
}
.scan-path {
  color: #909399;
  font-size: 13px;
}
.found-result {
  padding: 20px 0;
}
@keyframes spin {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}
</style>
