# ToolApp Admin 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 Electron + Vue 3 桌面端数据库管理软件，用于查看和管理 ToolApp 的用户数据。

**Architecture:** Electron 主进程负责数据库连接（本地 SQLite 直读 + 远程 HTTP API），通过 IPC 桥接与 Vue 3 渲染进程通信。渲染进程使用 Element Plus 构建 UI，ECharts 绘制图表，Pinia 管理状态。

**Tech Stack:** Electron 28+, Vue 3, Element Plus, ECharts, Pinia, Vite, better-sqlite3, axios

---

## 文件结构

```
ToolApp/toolapp-admin/
├── electron/
│   ├── main.js              # 主进程入口
│   ├── preload.js           # IPC 桥接
│   └── db.js                # 数据库连接管理
├── src/
│   ├── App.vue              # 根组件
│   ├── main.js              # 渲染进程入口
│   ├── views/
│   │   ├── ConnectView.vue  # 连接配置页
│   │   ├── DashboardView.vue # 仪表盘
│   │   ├── UsersView.vue    # 用户管理
│   │   ├── HeartRateView.vue # 心率数据
│   │   ├── NetworkSpeedView.vue # 网速数据
│   │   ├── ConvertHistoryView.vue # 转换历史
│   │   ├── DiceRecordsView.vue # 骰子记录
│   │   ├── PeriodRecordsView.vue # 经期记录
│   │   └── BackupView.vue   # 数据备份
│   ├── components/
│   │   ├── AppLayout.vue    # 主布局
│   │   └── StatsCard.vue    # 统计卡片
│   ├── stores/
│   │   └── connection.js    # 连接状态
│   ├── router/
│   │   └── index.js         # 路由配置
│   └── utils/
│       └── api.js           # IPC 调用封装
├── index.html               # HTML 入口
├── package.json
└── vite.config.js
```

---

### Task 1: 项目初始化与基础配置

**Files:**
- Create: `toolapp-admin/package.json`
- Create: `toolapp-admin/vite.config.js`
- Create: `toolapp-admin/index.html`

- [ ] **Step 1: 创建项目目录并初始化**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp
mkdir toolapp-admin
cd toolapp-admin
npm init -y
```

- [ ] **Step 2: 安装核心依赖**

```bash
npm install vue@3 vue-router@4 pinia element-plus @element-plus/icons-vue echarts axios
npm install -D vite @vitejs/plugin-vue electron@28 electron-builder concurrently wait-on
npm install better-sqlite3
```

- [ ] **Step 3: 编写 package.json**

替换 `toolapp-admin/package.json` 为：

```json
{
  "name": "toolapp-admin",
  "version": "1.0.0",
  "description": "ToolApp 数据库管理桌面端",
  "main": "electron/main.js",
  "scripts": {
    "dev": "concurrently \"vite\" \"wait-on http://localhost:5173 && electron .\"",
    "build": "vite build && electron-builder",
    "preview": "vite preview"
  },
  "dependencies": {
    "vue": "^3.4.0",
    "vue-router": "^4.3.0",
    "pinia": "^2.1.0",
    "element-plus": "^2.7.0",
    "@element-plus/icons-vue": "^2.3.0",
    "echarts": "^5.5.0",
    "axios": "^1.7.0",
    "better-sqlite3": "^11.0.0"
  },
  "devDependencies": {
    "vite": "^5.4.0",
    "@vitejs/plugin-vue": "^5.1.0",
    "electron": "^28.0.0",
    "electron-builder": "^24.13.0",
    "concurrently": "^8.2.0",
    "wait-on": "^7.2.0"
  }
}
```

- [ ] **Step 4: 编写 vite.config.js**

创建 `toolapp-admin/vite.config.js`：

```js
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import path from 'path'

export default defineConfig({
  plugins: [vue()],
  base: './',
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
    },
  },
  server: {
    port: 5173,
  },
  build: {
    outDir: 'dist',
  },
})
```

- [ ] **Step 5: 编写 index.html**

创建 `toolapp-admin/index.html`：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ToolApp Admin</title>
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.js"></script>
</body>
</html>
```

- [ ] **Step 6: 提交**

```bash
git add toolapp-admin/
git commit -m "feat: 初始化 toolapp-admin 项目结构"
```

---

### Task 2: Electron 主进程与 IPC 桥接

**Files:**
- Create: `toolapp-admin/electron/main.js`
- Create: `toolapp-admin/electron/preload.js`
- Create: `toolapp-admin/electron/db.js`

- [ ] **Step 1: 编写数据库连接模块 db.js**

创建 `toolapp-admin/electron/db.js`：

```js
// 数据库连接管理模块
// 支持两种模式：本地 SQLite 直读 和 远程 HTTP API
const Database = require('better-sqlite3');
const axios = require('axios');

let mode = null; // 'local' | 'remote' | null
let localDb = null;
let localDbPath = '';
let remoteConfig = { url: '', password: '' };

function connectLocal(dbPath) {
  try {
    if (localDb) { localDb.close(); }
    localDb = new Database(dbPath, { readonly: true });
    localDb.pragma('journal_mode = WAL');
    const table = localDb.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='users'").get();
    if (!table) {
      localDb.close();
      localDb = null;
      return { success: false, error: '该数据库不是 ToolApp 数据库（缺少 users 表）' };
    }
    mode = 'local';
    localDbPath = dbPath;
    return { success: true };
  } catch (err) {
    localDb = null;
    mode = null;
    return { success: false, error: `连接失败: ${err.message}` };
  }
}

async function connectRemote(serverUrl, password) {
  try {
    const url = serverUrl.replace(/\/$/, '');
    const res = await axios.get(`${url}/api/health`, { timeout: 5000 });
    if (res.data && res.data.status === 'ok') {
      mode = 'remote';
      remoteConfig = { url, password };
      return { success: true };
    }
    return { success: false, error: '服务器响应异常' };
  } catch (err) {
    mode = null;
    return { success: false, error: `连接失败: ${err.message}` };
  }
}

async function testConnection() {
  if (mode === 'local' && localDb) {
    try { localDb.prepare('SELECT 1').get(); return true; } catch { return false; }
  }
  if (mode === 'remote') {
    try {
      const res = await axios.get(`${remoteConfig.url}/api/health`, { timeout: 5000 });
      return res.data && res.data.status === 'ok';
    } catch { return false; }
  }
  return false;
}

function disconnect() {
  if (localDb) { localDb.close(); localDb = null; }
  mode = null;
  localDbPath = '';
  remoteConfig = { url: '', password: '' };
}

function getMode() { return mode; }

function queryLocal(sql, params = []) {
  if (!localDb) throw new Error('未连接本地数据库');
  return localDb.prepare(sql).all(...params);
}

function runLocal(sql, params = []) {
  if (!localDbPath) throw new Error('未连接本地数据库');
  const writeDb = new Database(localDbPath, { readonly: false });
  try {
    const result = writeDb.prepare(sql).run(...params);
    return { changes: result.changes };
  } finally {
    writeDb.close();
  }
}

async function requestRemote(endpoint, config = {}) {
  if (mode !== 'remote') throw new Error('未连接远程服务器');
  const url = `${remoteConfig.url}${endpoint}`;
  const headers = {};
  if (remoteConfig.password) { headers['X-Admin-Password'] = remoteConfig.password; }
  const res = await axios({ url, headers, ...config });
  return res.data;
}

function getLocalDbPath() { return localDbPath; }

module.exports = {
  connectLocal, connectRemote, testConnection, disconnect,
  getMode, queryLocal, runLocal, requestRemote, getLocalDbPath,
};
```

- [ ] **Step 2: 编写 preload.js**

创建 `toolapp-admin/electron/preload.js`：

```js
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  connectLocal: (dbPath) => ipcRenderer.invoke('db:connectLocal', dbPath),
  connectRemote: (serverUrl, password) => ipcRenderer.invoke('db:connectRemote', serverUrl, password),
  testConnection: () => ipcRenderer.invoke('db:testConnection'),
  disconnect: () => ipcRenderer.invoke('db:disconnect'),
  getMode: () => ipcRenderer.invoke('db:getMode'),
  getStats: () => ipcRenderer.invoke('db:getStats'),
  getUsers: (params) => ipcRenderer.invoke('db:getUsers', params),
  getTableData: (table, params) => ipcRenderer.invoke('db:getTableData', table, params),
  updateRecord: (table, id, data) => ipcRenderer.invoke('db:updateRecord', table, id, data),
  deleteRecord: (table, id) => ipcRenderer.invoke('db:deleteRecord', table, id),
  deleteUser: (userId) => ipcRenderer.invoke('db:deleteUser', userId),
  exportTable: (table, format) => ipcRenderer.invoke('db:exportTable', table, format),
  backupDatabase: () => ipcRenderer.invoke('db:backupDatabase'),
  selectDbFile: () => ipcRenderer.invoke('dialog:selectDbFile'),
  selectSavePath: (defaultName) => ipcRenderer.invoke('dialog:selectSavePath', defaultName),
  saveExport: (data) => ipcRenderer.invoke('file:saveExport', data),
});
```

- [ ] **Step 3: 编写 main.js**

创建 `toolapp-admin/electron/main.js`：

```js
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const db = require('./db');
const Database = require('better-sqlite3');

let mainWindow = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280, height: 800, minWidth: 1024, minHeight: 600,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'ToolApp Admin',
  });
  const isDev = !app.isPackaged;
  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
  }
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { db.disconnect(); if (process.platform !== 'darwin') app.quit(); });

// --- 连接管理 ---
ipcMain.handle('db:connectLocal', async (e, dbPath) => db.connectLocal(dbPath));
ipcMain.handle('db:connectRemote', async (e, url, pw) => await db.connectRemote(url, pw));
ipcMain.handle('db:testConnection', async () => await db.testConnection());
ipcMain.handle('db:disconnect', async () => { db.disconnect(); return { success: true }; });
ipcMain.handle('db:getMode', async () => db.getMode());

// --- 数据查询 ---
ipcMain.handle('db:getStats', async () => {
  const mode = db.getMode();
  if (mode === 'local') {
    const q = (sql) => db.queryLocal(sql)[0].count;
    return {
      users: q('SELECT COUNT(*) as count FROM users'),
      heartRate: q('SELECT COUNT(*) as count FROM heart_rate_sessions'),
      networkSpeed: q('SELECT COUNT(*) as count FROM network_speed_records'),
      convert: q('SELECT COUNT(*) as count FROM convert_history'),
      dice: q('SELECT COUNT(*) as count FROM dice_records'),
      period: q('SELECT COUNT(*) as count FROM period_records'),
    };
  }
  if (mode === 'remote') return await db.requestRemote('/api/admin/stats');
  throw new Error('未连接数据库');
});

ipcMain.handle('db:getUsers', async (e, params = {}) => {
  const { page = 1, pageSize = 20, search = '' } = params;
  const mode = db.getMode();
  if (mode === 'local') {
    let where = ''; const sp = [];
    if (search) { where = 'WHERE email LIKE ?'; sp.push(`%${search}%`); }
    const total = db.queryLocal(`SELECT COUNT(*) as count FROM users ${where}`, sp)[0].count;
    const offset = (page - 1) * pageSize;
    const rows = db.queryLocal(`SELECT id, email, created_at FROM users ${where} ORDER BY id LIMIT ? OFFSET ?`, [...sp, pageSize, offset]);
    const usersWithData = rows.map(u => {
      const c = (t) => db.queryLocal(`SELECT COUNT(*) as count FROM ${t} WHERE user_id = ?`, [u.id])[0].count;
      return { ...u, dataCount: { heartRate: c('heart_rate_sessions'), networkSpeed: c('network_speed_records'), convert: c('convert_history'), dice: c('dice_records'), period: c('period_records') } };
    });
    return { rows: usersWithData, total, page, pageSize };
  }
  if (mode === 'remote') return await db.requestRemote(`/api/admin/users?page=${page}&pageSize=${pageSize}&search=${encodeURIComponent(search)}`);
  throw new Error('未连接数据库');
});

const VALID_TABLES = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];

ipcMain.handle('db:getTableData', async (e, table, params = {}) => {
  if (!VALID_TABLES.includes(table)) throw new Error(`无效的数据表: ${table}`);
  const { page = 1, pageSize = 20, userId = '' } = params;
  const mode = db.getMode();
  if (mode === 'local') {
    const conds = []; const sp = [];
    if (userId) { conds.push('user_id = ?'); sp.push(userId); }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
    const total = db.queryLocal(`SELECT COUNT(*) as count FROM ${table} ${where}`, sp)[0].count;
    const offset = (page - 1) * pageSize;
    const rows = db.queryLocal(`SELECT * FROM ${table} ${where} ORDER BY id DESC LIMIT ? OFFSET ?`, [...sp, pageSize, offset]);
    return { rows, total, page, pageSize };
  }
  if (mode === 'remote') return await db.requestRemote(`/api/admin/${table}?page=${page}&pageSize=${pageSize}&userId=${userId}`);
  throw new Error('未连接数据库');
});

ipcMain.handle('db:updateRecord', async (e, table, id, data) => {
  if (!VALID_TABLES.includes(table)) throw new Error(`无效的数据表: ${table}`);
  const mode = db.getMode();
  if (mode === 'local') {
    const cols = Object.keys(data); const vals = Object.values(data);
    const set = cols.map(c => `${c} = ?`).join(', ');
    db.runLocal(`UPDATE ${table} SET ${set} WHERE id = ?`, [...vals, id]);
    return { success: true };
  }
  if (mode === 'remote') return await db.requestRemote(`/api/admin/${table}/${id}`, { method: 'PUT', data });
  throw new Error('未连接数据库');
});

ipcMain.handle('db:deleteRecord', async (e, table, id) => {
  if (!VALID_TABLES.includes(table)) throw new Error(`无效的数据表: ${table}`);
  const mode = db.getMode();
  if (mode === 'local') { db.runLocal(`DELETE FROM ${table} WHERE id = ?`, [id]); return { success: true }; }
  if (mode === 'remote') return await db.requestRemote(`/api/admin/${table}/${id}`, { method: 'DELETE' });
  throw new Error('未连接数据库');
});

ipcMain.handle('db:deleteUser', async (e, userId) => {
  const mode = db.getMode();
  if (mode === 'local') {
    for (const t of VALID_TABLES) db.runLocal(`DELETE FROM ${t} WHERE user_id = ?`, [userId]);
    db.runLocal('DELETE FROM users WHERE id = ?', [userId]);
    return { success: true };
  }
  if (mode === 'remote') return await db.requestRemote(`/api/admin/users/${userId}`, { method: 'DELETE' });
  throw new Error('未连接数据库');
});

// --- 导出备份 ---
ipcMain.handle('db:exportTable', async (e, table, format) => {
  const allTables = [...VALID_TABLES, 'users'];
  if (!allTables.includes(table)) throw new Error(`无效的数据表: ${table}`);
  const mode = db.getMode();
  let rows;
  if (mode === 'local') { rows = db.queryLocal(`SELECT * FROM ${table}`); }
  else if (mode === 'remote') { const r = await db.requestRemote(`/api/admin/${table}?pageSize=999999`); rows = r.rows; }
  else throw new Error('未连接数据库');

  if (format === 'csv') {
    if (rows.length === 0) return { data: '', format: 'csv' };
    const headers = Object.keys(rows[0]);
    const lines = [headers.join(',')];
    for (const row of rows) {
      const vals = headers.map(h => {
        const v = row[h]; if (v == null) return '';
        const s = String(v);
        return s.includes(',') || s.includes('"') || s.includes('\n') ? `"${s.replace(/"/g, '""')}"` : s;
      });
      lines.push(vals.join(','));
    }
    return { data: lines.join('\n'), format: 'csv' };
  }
  return { data: JSON.stringify(rows, null, 2), format: 'json' };
});

ipcMain.handle('db:backupDatabase', async () => {
  const mode = db.getMode();
  if (mode !== 'local') throw new Error('备份仅支持本地模式');
  const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
    title: '备份数据库',
    defaultPath: `toolapp_backup_${new Date().toISOString().slice(0, 10)}.db`,
    filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
  });
  if (canceled || !filePath) return { success: false, error: '用户取消' };
  const src = new Database(db.getLocalDbPath(), { readonly: true });
  const dest = new Database(filePath);
  src.backup(dest);
  src.close(); dest.close();
  return { success: true, path: filePath };
});

// --- 文件对话框 ---
ipcMain.handle('dialog:selectDbFile', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
    title: '选择 ToolApp 数据库文件',
    filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
    properties: ['openFile'],
  });
  return canceled ? null : filePaths[0] || null;
});

ipcMain.handle('dialog:selectSavePath', async (e, defaultName) => {
  const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
    title: '保存文件', defaultPath: defaultName || 'export.csv',
    filters: [{ name: 'CSV 文件', extensions: ['csv'] }, { name: 'JSON 文件', extensions: ['json'] }],
  });
  return canceled ? null : filePath;
});

ipcMain.handle('file:saveExport', async (e, { data, filePath }) => {
  fs.writeFileSync(filePath, data, 'utf-8');
  return { success: true, path: filePath };
});
```

- [ ] **Step 4: 提交**

```bash
git add toolapp-admin/electron/
git commit -m "feat: 添加 Electron 主进程与 IPC 桥接"
```

---

### Task 3: Vue 3 渲染进程基础框架

**Files:**
- Create: `toolapp-admin/src/main.js`
- Create: `toolapp-admin/src/App.vue`
- Create: `toolapp-admin/src/router/index.js`
- Create: `toolapp-admin/src/stores/connection.js`
- Create: `toolapp-admin/src/utils/api.js`

- [ ] **Step 1: 编写渲染进程入口 main.js**

创建 `toolapp-admin/src/main.js`：

```js
import { createApp } from 'vue'
import { createPinia } from 'pinia'
import ElementPlus from 'element-plus'
import 'element-plus/dist/index.css'
import zhCn from 'element-plus/dist/locale/zh-cn.mjs'
import * as ElementPlusIconsVue from '@element-plus/icons-vue'
import App from './App.vue'
import router from './router'

const app = createApp(App)
for (const [key, component] of Object.entries(ElementPlusIconsVue)) {
  app.component(key, component)
}
app.use(createPinia()).use(router).use(ElementPlus, { locale: zhCn }).mount('#app')
```

- [ ] **Step 2: 编写根组件 App.vue**

创建 `toolapp-admin/src/App.vue`：

```vue
<template>
  <router-view />
</template>

<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body, #app { height: 100%; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Microsoft YaHei', sans-serif; }
</style>
```

- [ ] **Step 3: 编写路由配置**

创建 `toolapp-admin/src/router/index.js`：

```js
import { createRouter, createWebHashHistory } from 'vue-router'

const routes = [
  { path: '/', name: 'connect', component: () => import('@/views/ConnectView.vue') },
  { path: '/dashboard', name: 'dashboard', component: () => import('@/views/DashboardView.vue') },
  { path: '/users', name: 'users', component: () => import('@/views/UsersView.vue') },
  { path: '/heart-rate', name: 'heartRate', component: () => import('@/views/HeartRateView.vue') },
  { path: '/network-speed', name: 'networkSpeed', component: () => import('@/views/NetworkSpeedView.vue') },
  { path: '/convert-history', name: 'convertHistory', component: () => import('@/views/ConvertHistoryView.vue') },
  { path: '/dice-records', name: 'diceRecords', component: () => import('@/views/DiceRecordsView.vue') },
  { path: '/period-records', name: 'periodRecords', component: () => import('@/views/PeriodRecordsView.vue') },
  { path: '/backup', name: 'backup', component: () => import('@/views/BackupView.vue') },
]

export default createRouter({ history: createWebHashHistory(), routes })
```

- [ ] **Step 4: 编写连接状态 store**

创建 `toolapp-admin/src/stores/connection.js`：

```js
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api } from '@/utils/api'

export const useConnectionStore = defineStore('connection', () => {
  const connected = ref(false)
  const mode = ref(null)
  const dbPath = ref('')
  const serverUrl = ref('')

  async function connectLocal(path) {
    const result = await api.connectLocal(path)
    if (result.success) { connected.value = true; mode.value = 'local'; dbPath.value = path; }
    return result
  }
  async function connectRemote(url, password) {
    const result = await api.connectRemote(url, password)
    if (result.success) { connected.value = true; mode.value = 'remote'; serverUrl.value = url; }
    return result
  }
  async function disconnect() {
    await api.disconnect()
    connected.value = false; mode.value = null; dbPath.value = ''; serverUrl.value = ''
  }

  return { connected, mode, dbPath, serverUrl, connectLocal, connectRemote, disconnect }
})
```

- [ ] **Step 5: 编写 IPC 调用封装**

创建 `toolapp-admin/src/utils/api.js`：

```js
const api = window.api
export { api }
```

- [ ] **Step 6: 提交**

```bash
git add toolapp-admin/src/
git commit -m "feat: 添加 Vue 3 渲染进程基础框架"
```

---

### Task 4: 主布局组件

**Files:**
- Create: `toolapp-admin/src/components/AppLayout.vue`
- Create: `toolapp-admin/src/components/StatsCard.vue`

- [ ] **Step 1: 编写 AppLayout.vue**

创建 `toolapp-admin/src/components/AppLayout.vue`：

```vue
<template>
  <el-container class="app-layout">
    <el-aside :width="isCollapsed ? '64px' : '220px'" class="sidebar">
      <div class="sidebar-header">
        <span v-if="!isCollapsed" class="sidebar-title">ToolApp Admin</span>
        <span v-else class="sidebar-title-short">TA</span>
      </div>
      <el-menu :default-active="activeMenu" :collapse="isCollapsed" background-color="#304156" text-color="#bfcbd9" active-text-color="#409EFF" router>
        <el-menu-item index="/dashboard"><el-icon><DataAnalysis /></el-icon><template #title>仪表盘</template></el-menu-item>
        <el-menu-item index="/users"><el-icon><User /></el-icon><template #title>用户管理</template></el-menu-item>
        <el-divider v-if="!isCollapsed" content-position="left">数据管理</el-divider>
        <el-menu-item index="/heart-rate"><el-icon><Monitor /></el-icon><template #title>心率数据</template></el-menu-item>
        <el-menu-item index="/network-speed"><el-icon><Connection /></el-icon><template #title>网速数据</template></el-menu-item>
        <el-menu-item index="/convert-history"><el-icon><VideoCamera /></el-icon><template #title>转换历史</template></el-menu-item>
        <el-menu-item index="/dice-records"><el-icon><Coin /></el-icon><template #title>骰子记录</template></el-menu-item>
        <el-menu-item index="/period-records"><el-icon><Calendar /></el-icon><template #title>经期记录</template></el-menu-item>
        <el-divider v-if="!isCollapsed" content-position="left">系统工具</el-divider>
        <el-menu-item index="/backup"><el-icon><FolderOpened /></el-icon><template #title>数据备份</template></el-menu-item>
      </el-menu>
    </el-aside>
    <el-container>
      <el-header class="app-header">
        <el-icon class="collapse-btn" @click="isCollapsed = !isCollapsed">
          <Fold v-if="!isCollapsed" /><Expand v-else />
        </el-icon>
        <div class="header-right">
          <el-tag :type="connectionStore.mode === 'local' ? 'success' : 'warning'" size="small">
            {{ connectionStore.mode === 'local' ? '本地模式' : '远程模式' }}
          </el-tag>
          <el-button text @click="handleDisconnect"><el-icon><SwitchButton /></el-icon>断开</el-button>
        </div>
      </el-header>
      <el-main class="app-main"><slot /></el-main>
    </el-container>
  </el-container>
</template>

<script setup>
import { ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useConnectionStore } from '@/stores/connection'

const route = useRoute(); const router = useRouter(); const connectionStore = useConnectionStore()
const isCollapsed = ref(false)
const activeMenu = computed(() => route.path)
async function handleDisconnect() { await connectionStore.disconnect(); router.push('/') }
</script>

<style scoped>
.app-layout { height: 100vh; }
.sidebar { background-color: #304156; transition: width 0.3s; overflow: hidden; }
.sidebar-header { height: 60px; display: flex; align-items: center; justify-content: center; color: #fff; font-size: 18px; font-weight: bold; border-bottom: 1px solid #3a4a5b; }
.sidebar-title { white-space: nowrap; }
.sidebar-title-short { font-size: 20px; }
.app-header { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #e6e6e6; background: #fff; padding: 0 20px; }
.collapse-btn { font-size: 20px; cursor: pointer; color: #606266; }
.collapse-btn:hover { color: #409EFF; }
.header-right { display: flex; align-items: center; gap: 12px; }
.app-main { background: #f5f7fa; padding: 20px; overflow-y: auto; }
.el-divider { margin: 8px 16px; border-color: #3a4a5b; }
:deep(.el-divider__text) { color: #7a8a9b; font-size: 12px; background-color: #304156; }
</style>
```

- [ ] **Step 2: 编写 StatsCard.vue**

创建 `toolapp-admin/src/components/StatsCard.vue`：

```vue
<template>
  <el-card class="stats-card" shadow="hover" @click="$emit('click')">
    <div class="stats-card-content">
      <div class="stats-card-info">
        <div class="stats-card-label">{{ label }}</div>
        <div class="stats-card-value">{{ value }}</div>
      </div>
      <div class="stats-card-icon" :style="{ backgroundColor: iconBg }">
        <el-icon :size="28" :color="iconColor"><component :is="icon" /></el-icon>
      </div>
    </div>
  </el-card>
</template>

<script setup>
defineProps({ label: String, value: [Number, String], icon: String, iconBg: { type: String, default: '#ecf5ff' }, iconColor: { type: String, default: '#409EFF' } })
defineEmits(['click'])
</script>

<style scoped>
.stats-card { cursor: pointer; transition: transform 0.2s; }
.stats-card:hover { transform: translateY(-2px); }
.stats-card-content { display: flex; align-items: center; justify-content: space-between; }
.stats-card-label { font-size: 14px; color: #909399; margin-bottom: 8px; }
.stats-card-value { font-size: 28px; font-weight: bold; color: #303133; }
.stats-card-icon { width: 56px; height: 56px; border-radius: 12px; display: flex; align-items: center; justify-content: center; }
</style>
```

- [ ] **Step 3: 提交**

```bash
git add toolapp-admin/src/components/
git commit -m "feat: 添加主布局和统计卡片组件"
```

---

### Task 5: 连接配置页

**Files:**
- Create: `toolapp-admin/src/views/ConnectView.vue`

- [ ] **Step 1: 编写 ConnectView.vue**

创建 `toolapp-admin/src/views/ConnectView.vue`：

```vue
<template>
  <div class="connect-page">
    <el-card class="connect-card" shadow="always">
      <template #header>
        <div class="connect-card-header">
          <h2>ToolApp Admin</h2>
          <p>数据库管理工具</p>
        </div>
      </template>
      <el-form label-width="100px" @submit.prevent>
        <el-form-item label="连接模式">
          <el-radio-group v-model="connectMode">
            <el-radio value="local">本地数据库</el-radio>
            <el-radio value="remote">远程服务器</el-radio>
          </el-radio-group>
        </el-form-item>
        <template v-if="connectMode === 'local'">
          <el-form-item label="数据库路径">
            <el-input v-model="localPath" placeholder="选择 toolapp.db 文件路径" readonly>
              <template #append><el-button @click="selectDbFile">浏览</el-button></template>
            </el-input>
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
          <el-button type="primary" @click="handleConnect" :loading="loading" style="width: 100%">连接</el-button>
        </el-form-item>
      </el-form>
      <el-result v-if="errorMsg" icon="error" :title="errorMsg" />
    </el-card>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { useConnectionStore } from '@/stores/connection'
import { api } from '@/utils/api'

const router = useRouter(); const connectionStore = useConnectionStore()
const connectMode = ref('local'); const localPath = ref(''); const remoteUrl = ref(''); const remotePassword = ref('')
const loading = ref(false); const errorMsg = ref('')

async function selectDbFile() { const p = await api.selectDbFile(); if (p) localPath.value = p }

async function handleConnect() {
  loading.value = true; errorMsg.value = ''
  try {
    let result
    if (connectMode.value === 'local') {
      if (!localPath.value) { ElMessage.warning('请选择数据库文件'); return }
      result = await connectionStore.connectLocal(localPath.value)
    } else {
      if (!remoteUrl.value) { ElMessage.warning('请输入服务器地址'); return }
      result = await connectionStore.connectRemote(remoteUrl.value, remotePassword.value)
    }
    if (result.success) { ElMessage.success('连接成功'); router.push('/dashboard') }
    else { errorMsg.value = result.error || '连接失败' }
  } catch (err) { errorMsg.value = err.message || '连接异常' }
  finally { loading.value = false }
}
</script>

<style scoped>
.connect-page { height: 100vh; display: flex; align-items: center; justify-content: center; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
.connect-card { width: 480px; }
.connect-card-header { text-align: center; }
.connect-card-header h2 { margin: 0 0 8px 0; color: #303133; }
.connect-card-header p { margin: 0; color: #909399; font-size: 14px; }
</style>
```

- [ ] **Step 2: 提交**

```bash
git add toolapp-admin/src/views/ConnectView.vue
git commit -m "feat: 添加连接配置页"
```

---

### Task 6: 仪表盘页面

**Files:**
- Create: `toolapp-admin/src/views/DashboardView.vue`

- [ ] **Step 1: 编写 DashboardView.vue**

创建 `toolapp-admin/src/views/DashboardView.vue`：

```vue
<template>
  <AppLayout>
    <div class="dashboard">
      <h2 class="page-title">仪表盘</h2>
      <el-row :gutter="20" class="stats-row">
        <el-col :span="4"><StatsCard label="用户数" :value="stats.users" icon="User" iconBg="#ecf5ff" iconColor="#409EFF" @click="$router.push('/users')" /></el-col>
        <el-col :span="4"><StatsCard label="心率记录" :value="stats.heartRate" icon="Monitor" iconBg="#f0f9eb" iconColor="#67C23A" @click="$router.push('/heart-rate')" /></el-col>
        <el-col :span="4"><StatsCard label="网速记录" :value="stats.networkSpeed" icon="Connection" iconBg="#fdf6ec" iconColor="#E6A23C" @click="$router.push('/network-speed')" /></el-col>
        <el-col :span="4"><StatsCard label="转换记录" :value="stats.convert" icon="VideoCamera" iconBg="#fef0f0" iconColor="#F56C6C" @click="$router.push('/convert-history')" /></el-col>
        <el-col :span="4"><StatsCard label="骰子记录" :value="stats.dice" icon="Coin" iconBg="#f4f4f5" iconColor="#909399" @click="$router.push('/dice-records')" /></el-col>
        <el-col :span="4"><StatsCard label="经期记录" :value="stats.period" icon="Calendar" iconBg="#fdf2f8" iconColor="#EC4899" @click="$router.push('/period-records')" /></el-col>
      </el-row>
      <el-row :gutter="20" class="charts-row">
        <el-col :span="16">
          <el-card shadow="hover"><template #header>数据分布</template><div ref="barChartRef" style="height: 320px;"></div></el-card>
        </el-col>
        <el-col :span="8">
          <el-card shadow="hover"><template #header>模块数据占比</template><div ref="pieChartRef" style="height: 320px;"></div></el-card>
        </el-col>
      </el-row>
      <el-card shadow="hover" class="recent-card">
        <template #header>最近注册用户</template>
        <el-table :data="recentUsers" stripe style="width: 100%">
          <el-table-column prop="id" label="ID" width="80" />
          <el-table-column prop="email" label="邮箱" />
          <el-table-column prop="created_at" label="注册时间" />
        </el-table>
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted, nextTick } from 'vue'
import * as echarts from 'echarts'
import AppLayout from '@/components/AppLayout.vue'
import StatsCard from '@/components/StatsCard.vue'
import { api } from '@/utils/api'

const stats = ref({ users: 0, heartRate: 0, networkSpeed: 0, convert: 0, dice: 0, period: 0 })
const recentUsers = ref([])
const barChartRef = ref(null); const pieChartRef = ref(null)

onMounted(async () => {
  try { stats.value = await api.getStats() } catch (e) { console.error(e) }
  try { const r = await api.getUsers({ page: 1, pageSize: 5 }); recentUsers.value = r.rows || [] } catch (e) { console.error(e) }
  await nextTick(); renderCharts()
})

function renderCharts() {
  if (barChartRef.value) {
    const c = echarts.init(barChartRef.value)
    c.setOption({
      tooltip: { trigger: 'axis' },
      xAxis: { type: 'category', data: ['心率', '网速', '转换', '骰子', '经期'] },
      yAxis: { type: 'value' },
      series: [{ type: 'bar', data: [stats.value.heartRate, stats.value.networkSpeed, stats.value.convert, stats.value.dice, stats.value.period],
        itemStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: '#409EFF' }, { offset: 1, color: '#79bbff' }]) } }],
    })
  }
  if (pieChartRef.value) {
    const c = echarts.init(pieChartRef.value)
    c.setOption({
      tooltip: { trigger: 'item' },
      series: [{ type: 'pie', radius: ['40%', '70%'],
        data: [{ value: stats.value.heartRate, name: '心率' }, { value: stats.value.networkSpeed, name: '网速' }, { value: stats.value.convert, name: '转换' }, { value: stats.value.dice, name: '骰子' }, { value: stats.value.period, name: '经期' }] }],
    })
  }
}
</script>

<style scoped>
.page-title { margin-bottom: 20px; color: #303133; }
.stats-row { margin-bottom: 20px; }
.charts-row { margin-bottom: 20px; }
</style>
```

- [ ] **Step 2: 提交**

```bash
git add toolapp-admin/src/views/DashboardView.vue
git commit -m "feat: 添加仪表盘页面"
```

---

### Task 7: 用户管理页面

**Files:**
- Create: `toolapp-admin/src/views/UsersView.vue`

- [ ] **Step 1: 编写 UsersView.vue**

创建 `toolapp-admin/src/views/UsersView.vue`：

```vue
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
                <template #reference><el-button type="danger" size="small" text>删除</el-button></template>
              </el-popconfirm>
            </template>
          </el-table-column>
        </el-table>
        <el-pagination v-if="total > 0" class="pagination" layout="total, prev, pager, next" :total="total" :page-size="pageSize" :current-page="currentPage" @current-change="handlePageChange" />
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import AppLayout from '@/components/AppLayout.vue'
import { api } from '@/utils/api'

const users = ref([]); const loading = ref(false); const searchText = ref('')
const currentPage = ref(1); const pageSize = ref(20); const total = ref(0)

onMounted(() => loadUsers())

async function loadUsers() {
  loading.value = true
  try {
    const r = await api.getUsers({ page: currentPage.value, pageSize: pageSize.value, search: searchText.value })
    users.value = r.rows || []; total.value = r.total || 0
  } catch (e) { ElMessage.error('加载用户失败: ' + e.message) }
  finally { loading.value = false }
}

function handlePageChange(p) { currentPage.value = p; loadUsers() }

async function handleDelete(id) {
  try { await api.deleteUser(id); ElMessage.success('删除成功'); loadUsers() }
  catch (e) { ElMessage.error('删除失败: ' + e.message) }
}
</script>

<style scoped>
.page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
.page-header h2 { margin: 0; color: #303133; }
.page-actions { display: flex; gap: 8px; }
.pagination { margin-top: 16px; justify-content: flex-end; }
.el-tag { margin-right: 4px; margin-bottom: 2px; }
</style>
```

- [ ] **Step 2: 提交**

```bash
git add toolapp-admin/src/views/UsersView.vue
git commit -m "feat: 添加用户管理页面"
```

---

### Task 8: 五个数据管理页面

**Files:**
- Create: `toolapp-admin/src/views/HeartRateView.vue`
- Create: `toolapp-admin/src/views/NetworkSpeedView.vue`
- Create: `toolapp-admin/src/views/ConvertHistoryView.vue`
- Create: `toolapp-admin/src/views/DiceRecordsView.vue`
- Create: `toolapp-admin/src/views/PeriodRecordsView.vue`

这五个页面结构相似，区别在于表名和列定义。每个页面都包含：用户筛选下拉框、数据表格、分页、删除操作、导出功能。

- [ ] **Step 1: 编写 HeartRateView.vue**

创建 `toolapp-admin/src/views/HeartRateView.vue`，表名 `heart_rate_sessions`，列：id, user_id, start_time, end_time, max_hr, min_hr, avg_hr, connection_mode

- [ ] **Step 2: 编写 NetworkSpeedView.vue**

创建 `toolapp-admin/src/views/NetworkSpeedView.vue`，表名 `network_speed_records`，列：id, user_id, test_time, server_url, min_latency, avg_latency, max_latency, jitter, loss_rate

- [ ] **Step 3: 编写 ConvertHistoryView.vue**

创建 `toolapp-admin/src/views/ConvertHistoryView.vue`，表名 `convert_history`，列：id, user_id, input_file, output_file, output_size, format, quality, status, timestamp_ms

- [ ] **Step 4: 编写 DiceRecordsView.vue**

创建 `toolapp-admin/src/views/DiceRecordsView.vue`，表名 `dice_records`，列：id, user_id, dice_type, result, timestamp_ms

- [ ] **Step 5: 编写 PeriodRecordsView.vue**

创建 `toolapp-admin/src/views/PeriodRecordsView.vue`，表名 `period_records`，列：id, user_id, start_date, end_date, record_mode, flow_level, symptoms, notes, local_id

- [ ] **Step 6: 提交**

```bash
git add toolapp-admin/src/views/
git commit -m "feat: 添加五个数据管理页面"
```

---

### Task 9: 数据备份页面

**Files:**
- Create: `toolapp-admin/src/views/BackupView.vue`

- [ ] **Step 1: 编写 BackupView.vue**

创建 `toolapp-admin/src/views/BackupView.vue`：

```vue
<template>
  <AppLayout>
    <div class="backup-page">
      <h2 class="page-title">数据备份</h2>
      <el-row :gutter="20">
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>数据库备份</template>
            <p style="color: #909399; margin-bottom: 16px;">将当前数据库文件备份到指定位置（仅本地模式可用）</p>
            <el-button type="primary" @click="handleBackup" :loading="backupLoading" :disabled="connectionStore.mode !== 'local'">
              <el-icon><Download /></el-icon>备份数据库
            </el-button>
          </el-card>
        </el-col>
        <el-col :span="12">
          <el-card shadow="hover">
            <template #header>数据表导出</template>
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
                <el-button type="primary" @click="handleExport" :loading="exportLoading">
                  <el-icon><Upload /></el-icon>导出
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
const backupLoading = ref(false); const exportLoading = ref(false)
const exportTable = ref('users'); const exportFormat = ref('csv')

async function handleBackup() {
  backupLoading.value = true
  try {
    const r = await api.backupDatabase()
    if (r.success) ElMessage.success('备份成功: ' + r.path)
    else ElMessage.warning(r.error || '备份取消')
  } catch (e) { ElMessage.error('备份失败: ' + e.message) }
  finally { backupLoading.value = false }
}

async function handleExport() {
  exportLoading.value = true
  try {
    const r = await api.exportTable(exportTable.value, exportFormat.value)
    const filePath = await api.selectSavePath(`${exportTable.value}_export.${exportFormat.value}`)
    if (filePath) { await api.saveExport({ data: r.data, filePath }); ElMessage.success('导出成功: ' + filePath) }
  } catch (e) { ElMessage.error('导出失败: ' + e.message) }
  finally { exportLoading.value = false }
}
</script>

<style scoped>
.page-title { margin-bottom: 20px; color: #303133; }
</style>
```

- [ ] **Step 2: 提交**

```bash
git add toolapp-admin/src/views/BackupView.vue
git commit -m "feat: 添加数据备份页面"
```

---

### Task 10: 远程模式服务器端 API 扩展

**Files:**
- Modify: `toolapp-server/server.js`

- [ ] **Step 1: 在 server.js 中添加管理端 API**

在 `toolapp-server/server.js` 的健康检查接口之前，添加管理端 API 路由：

```js
// ============================================================
// 管理端 API（需管理员密码认证）
// ============================================================
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'admin123';

function adminMiddleware(req, res, next) {
  const password = req.headers['x-admin-password'];
  if (!password || password !== ADMIN_PASSWORD) {
    return res.status(403).json({ error: '管理员密码错误' });
  }
  next();
}

// 全局统计
app.get('/api/admin/stats', adminMiddleware, (req, res) => {
  try {
    const q = (sql) => db.prepare(sql).get().count;
    res.json({
      users: q('SELECT COUNT(*) as count FROM users'),
      heartRate: q('SELECT COUNT(*) as count FROM heart_rate_sessions'),
      networkSpeed: q('SELECT COUNT(*) as count FROM network_speed_records'),
      convert: q('SELECT COUNT(*) as count FROM convert_history'),
      dice: q('SELECT COUNT(*) as count FROM dice_records'),
      period: q('SELECT COUNT(*) as count FROM period_records'),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 用户列表
app.get('/api/admin/users', adminMiddleware, (req, res) => {
  const { page = 1, pageSize = 20, search = '' } = req.query;
  try {
    let where = ''; const params = [];
    if (search) { where = 'WHERE email LIKE ?'; params.push(`%${search}%`); }
    const total = db.prepare(`SELECT COUNT(*) as count FROM users ${where}`).get(...params).count;
    const offset = (page - 1) * pageSize;
    const rows = db.prepare(`SELECT id, email, created_at FROM users ${where} ORDER BY id LIMIT ? OFFSET ?`).all(...params, pageSize, offset);
    const usersWithData = rows.map(u => {
      const c = (t) => db.prepare(`SELECT COUNT(*) as count FROM ${t} WHERE user_id = ?`).get(u.id).count;
      return { ...u, dataCount: { heartRate: c('heart_rate_sessions'), networkSpeed: c('network_speed_records'), convert: c('convert_history'), dice: c('dice_records'), period: c('period_records') } };
    });
    res.json({ rows: usersWithData, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 删除用户
app.delete('/api/admin/users/:id', adminMiddleware, (req, res) => {
  const userId = req.params.id;
  try {
    const tables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
    const transaction = db.transaction(() => {
      for (const t of tables) db.prepare(`DELETE FROM ${t} WHERE user_id = ?`).run(userId);
      db.prepare('DELETE FROM users WHERE id = ?').run(userId);
    });
    transaction();
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 查询表数据
app.get('/api/admin/:table', adminMiddleware, (req, res) => {
  const { table } = req.params;
  if (!SYNC_TABLES.includes(table)) return res.status(400).json({ error: '无效的数据表' });
  const { page = 1, pageSize = 20, userId = '' } = req.query;
  try {
    const conds = []; const params = [];
    if (userId) { conds.push('user_id = ?'); params.push(userId); }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
    const total = db.prepare(`SELECT COUNT(*) as count FROM ${table} ${where}`).get(...params).count;
    const offset = (page - 1) * pageSize;
    const rows = db.prepare(`SELECT * FROM ${table} ${where} ORDER BY id DESC LIMIT ? OFFSET ?`).all(...params, pageSize, offset);
    res.json({ rows, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 编辑记录
app.put('/api/admin/:table/:id', adminMiddleware, (req, res) => {
  const { table, id } = req.params;
  if (!SYNC_TABLES.includes(table)) return res.status(400).json({ error: '无效的数据表' });
  try {
    const data = req.body;
    const columns = Object.keys(data);
    const values = Object.values(data);
    const set = columns.map(c => `${c} = ?`).join(', ');
    db.prepare(`UPDATE ${table} SET ${set} WHERE id = ?`).run(...values, id);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 删除记录
app.delete('/api/admin/:table/:id', adminMiddleware, (req, res) => {
  const { table, id } = req.params;
  if (!SYNC_TABLES.includes(table)) return res.status(400).json({ error: '无效的数据表' });
  try {
    db.prepare(`DELETE FROM ${table} WHERE id = ?`).run(id);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
```

- [ ] **Step 2: 提交**

```bash
git add toolapp-server/server.js
git commit -m "feat: 添加管理端 API 接口"
```

---

### Task 11: 测试与调试

- [ ] **Step 1: 安装依赖并启动开发模式**

```bash
cd h:\Mycode\Trae\Flutter\ToolApp\toolapp-admin
npm install
npm run dev
```

- [ ] **Step 2: 测试本地模式连接**

1. 启动应用后选择本地模式
2. 浏览选择 `toolapp-server/data/toolapp.db`
3. 点击连接，验证是否成功跳转到仪表盘
4. 检查仪表盘统计数据是否正确

- [ ] **Step 3: 测试各页面功能**

1. 仪表盘：统计卡片、图表渲染
2. 用户管理：搜索、分页、删除
3. 各数据页面：筛选、分页、删除、导出
4. 数据备份：备份、导出

- [ ] **Step 4: 测试远程模式**

1. 先启动 toolapp-server
2. 在应用中选择远程模式，输入服务器地址和管理员密码
3. 验证连接和数据显示

- [ ] **Step 5: 修复发现的问题**

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "fix: 修复测试中发现的问题"
```
