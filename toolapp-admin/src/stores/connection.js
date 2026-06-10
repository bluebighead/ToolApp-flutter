// 连接状态管理（Pinia store）
// 管理本地数据库连接 & 远程服务器连接的状态
import { defineStore } from 'pinia';
import { ref } from 'vue';
import { api } from '@/utils/api';

export const useConnectionStore = defineStore('connection', () => {
  // 从 localStorage 恢复连接状态
  function loadPersistedState() {
    try {
      const saved = localStorage.getItem('toolapp-admin-connection');
      if (saved) {
        const data = JSON.parse(saved);
        return data;
      }
    } catch (e) {}
    return null;
  }

  const persisted = loadPersistedState();

  // 是否已连接
  const connected = ref(persisted?.connected || false);
  // 连接模式：'local' | 'remote' | null
  const mode = ref(persisted?.mode || null);
  // 本地数据库路径
  const dbPath = ref(persisted?.dbPath || '');
  // 远程服务器地址
  const serverUrl = ref(persisted?.serverUrl || '');
  // 数据库信息（各表数据量）
  const dbInfo = ref(persisted?.dbInfo || null);

  // 持久化连接状态
  function persistState() {
    try {
      localStorage.setItem('toolapp-admin-connection', JSON.stringify({
        connected: connected.value,
        mode: mode.value,
        dbPath: dbPath.value,
        serverUrl: serverUrl.value,
        dbInfo: dbInfo.value,
      }));
    } catch (e) {}
  }

  // 自动扫描并连接数据库
  async function autoScanAndConnect() {
    try {
      const result = await api.autoScanDatabase();
      if (result.found && result.dbPath) {
        const connectResult = await connectLocal(result.dbPath);
        return connectResult;
      }
      return { success: false, error: '未找到数据库', scanResult: result };
    } catch (err) {
      return { success: false, error: err.message };
    }
  }

  // 扫描指定目录
  async function scanDirectory(dirPath) {
    try {
      const result = await api.scanDatabase(dirPath);
      if (result.found && result.dbPath) {
        const connectResult = await connectLocal(result.dbPath);
        return connectResult;
      }
      return { success: false, error: '该目录下未找到 ToolApp 数据库', scanResult: result };
    } catch (err) {
      return { success: false, error: err.message };
    }
  }

  // 连接本地数据库
  async function connectLocal(path) {
    const result = await api.connectLocal(path);
    if (result.success) {
      connected.value = true;
      mode.value = 'local';
      dbPath.value = path;
      dbInfo.value = result.info || null;
      persistState();
    }
    return result;
  }

  // 连接远程服务器
  async function connectRemote(url, password) {
    const result = await api.connectRemote(url, password);
    if (result.success) {
      connected.value = true;
      mode.value = 'remote';
      serverUrl.value = url;
      dbInfo.value = null;
      persistState();
    }
    return result;
  }

  // 断开连接
  async function disconnect() {
    await api.disconnect();
    connected.value = false;
    mode.value = null;
    dbPath.value = '';
    serverUrl.value = '';
    dbInfo.value = null;
    persistState();
  }

  return {
    connected,
    mode,
    dbPath,
    serverUrl,
    dbInfo,
    autoScanAndConnect,
    scanDirectory,
    connectLocal,
    connectRemote,
    disconnect,
  };
});
