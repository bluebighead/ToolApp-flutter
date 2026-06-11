// Electron 主进程 - 使用子进程处理数据库
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

console.log('=== ToolApp Admin 启动 ===');

// ============ 数据库子进程管理 ============
let dbWorker = null;
let requestIdCounter = 0;
const pendingRequests = new Map();
let isWorkerReady = false;
let workerReadyPromise = null;

// 查找系统上的 Node.js 可执行文件
function findNodeExecutable() {
  const { execSync } = require('child_process');
  try {
    // 尝试使用 where 查找 node
    const result = execSync('where node', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    const paths = result.trim().split('\n').filter(p => p.trim());
    if (paths.length > 0) {
      console.log('找到 Node.js:', paths[0]);
      return paths[0].trim();
    }
  } catch (err) {
    console.log('where node 失败:', err.message);
  }
  // 尝试常见路径
  const candidates = [
    'C:\\Program Files\\nodejs\\node.exe',
    'C:\\Program Files (x86)\\nodejs\\node.exe',
    process.env.APPDATA + '\\npm\\node.exe',
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      console.log('找到 Node.js:', candidate);
      return candidate;
    }
  }
  // 如果找不到，返回 process.execPath（Electron）
  console.log('未找到独立的 Node.js，使用 Electron 自身');
  return process.execPath;
}

function startDbWorker() {
  return new Promise((resolve, reject) => {
    const workerPath = path.join(__dirname, 'db_worker.js');
    console.log('启动数据库工作进程:', workerPath);
    
    // 使用 Electron 自带的 Node.js 运行 db_worker，确保 better-sqlite3 兼容
    const nodeExe = process.execPath;
    console.log('使用 Node.js 可执行文件:', nodeExe);
    
    dbWorker = spawn(nodeExe, [workerPath], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env
    });
    
    let stdoutBuffer = '';
    
    dbWorker.stdout.setEncoding('utf8');
    dbWorker.stdout.on('data', (chunk) => {
      stdoutBuffer += chunk;
      const lines = stdoutBuffer.split('\n');
      stdoutBuffer = lines.pop();
      
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const msg = JSON.parse(trimmed);
          handleWorkerMessage(msg);
        } catch (err) {
          console.error('解析工作进程消息失败:', err.message, line);
        }
      }
    });
    
    dbWorker.stderr.on('data', (chunk) => {
      console.error('[DB Worker stderr]:', chunk.toString());
    });
    
    dbWorker.on('exit', (code, signal) => {
      console.log('数据库工作进程退出:', code, signal);
      isWorkerReady = false;
      // 拒绝所有未完成的请求
      for (const [id, { reject }] of pendingRequests) {
        reject(new Error('数据库工作进程已退出'));
      }
      pendingRequests.clear();
    });
    
    dbWorker.on('error', (err) => {
      console.error('数据库工作进程错误:', err.message);
      reject(err);
    });
    
    // 等待就绪消息
    workerReadyPromise = new Promise((readyResolve) => {
      const checkReady = (msg) => {
        if (msg.type === 'ready') {
          isWorkerReady = true;
          console.log('✓ 数据库工作进程就绪');
          readyResolve();
          resolve();
        }
      };
      // 临时监听器，等待就绪消息
      const originalHandler = handleWorkerMessage;
      handleWorkerMessage = (msg) => {
        if (msg.type === 'ready') {
          isWorkerReady = true;
          console.log('✓ 数据库工作进程就绪');
          handleWorkerMessage = originalHandler;
          readyResolve();
          resolve();
        } else {
          originalHandler(msg);
        }
      };
    });
  });
}

function handleWorkerMessage(msg) {
  if (msg.type === 'result' || msg.type === 'error') {
    const id = msg.id;
    const pending = pendingRequests.get(id);
    if (pending) {
      pendingRequests.delete(id);
      if (msg.type === 'result') {
        pending.resolve(msg.result);
      } else {
        pending.reject(new Error(msg.error?.message || '未知错误'));
      }
    }
  }
}

function sendToWorker(method, params) {
  return new Promise((resolve, reject) => {
    if (!dbWorker || !isWorkerReady) {
      reject(new Error('数据库工作进程未就绪'));
      return;
    }
    
    const id = ++requestIdCounter;
    pendingRequests.set(id, { resolve, reject });
    
    const msg = JSON.stringify({ id, method, params }) + '\n';
    dbWorker.stdin.write(msg, (err) => {
      if (err) {
        pendingRequests.delete(id);
        reject(err);
      }
    });
    
    // 超时处理（30秒）
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error('请求超时'));
      }
    }, 30000);
  });
}

// ============ 创建窗口 ============
let mainWindow = null;

function createWindow() {
  console.log('创建主窗口...');
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 1024,
    minHeight: 600,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'ToolApp Admin',
  });

  const isDev = !app.isPackaged;
  if (isDev) {
    console.log('开发模式，加载 http://localhost:5173');
    mainWindow.loadURL('http://localhost:5173').then(() => {
      console.log('✓ 页面加载成功');
    }).catch(err => {
      console.error('加载页面失败:', err.message);
    });
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
  }

  mainWindow.on('closed', () => {
    console.log('窗口已关闭');
    mainWindow = null;
  });
}

// ============ IPC 处理器 ============
const validTables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];

async function handleIpc(event, method, params) {
  try {
    return await sendToWorker(method, params);
  } catch (err) {
    console.error('IPC 处理错误 [' + method + ']:', err.message);
    return { success: false, error: err.message };
  }
}

// 数据库连接相关
ipcMain.handle('db:autoScanDatabase', () => sendToWorker('autoScanDatabase'));
ipcMain.handle('db:scanDatabase', (event, dir) => sendToWorker('scanDatabase', { dir }));
ipcMain.handle('db:connectLocal', (event, dbPath) => sendToWorker('connectLocal', { dbPath }));
ipcMain.handle('db:connectRemote', (event, serverUrl, password) => sendToWorker('connectRemote', { serverUrl, password }));
ipcMain.handle('db:testConnection', () => sendToWorker('testConnection'));
ipcMain.handle('db:getMode', () => sendToWorker('getMode'));
ipcMain.handle('db:getLocalDbPath', () => sendToWorker('getLocalDbPath'));
ipcMain.handle('db:disconnect', () => sendToWorker('disconnect'));

// 数据查询相关
ipcMain.handle('db:getStats', () => sendToWorker('getStats'));
ipcMain.handle('db:getUsers', (event, params) => sendToWorker('getUsers', params));
ipcMain.handle('db:getTableData', (event, table, params) => sendToWorker('getTableData', { table, ...params }));

// 在线状态 & 会话监控
ipcMain.handle('db:getOnlineStatus', () => sendToWorker('getOnlineStatus'));
ipcMain.handle('db:getUserSessions', (event, params) => sendToWorker('getUserSessions', params));
ipcMain.handle('db:getUserActivity', (event, params) => sendToWorker('getUserActivity', params));

// 系统信息
ipcMain.handle('db:getSystemInfo', () => sendToWorker('getSystemInfo'));
ipcMain.handle('db:getLocalDatabaseInfo', () => sendToWorker('getLocalDatabaseInfo'));
ipcMain.handle('db:changePassword', (event, newPassword) => sendToWorker('changePassword', { newPassword }));

// 数据修改相关
ipcMain.handle('db:updateRecord', (event, table, id, data) => sendToWorker('updateRecord', { table, id, data }));
ipcMain.handle('db:deleteRecord', (event, table, id) => sendToWorker('deleteRecord', { table, id }));
ipcMain.handle('db:deleteUser', (event, userId) => sendToWorker('deleteUser', { userId }));

// 导出备份相关
ipcMain.handle('db:exportTable', (event, table, format) => sendToWorker('exportTable', { table, format }));
ipcMain.handle('db:backupDatabase', async () => {
  const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
    title: '备份数据库',
    defaultPath: 'toolapp_backup_' + new Date().toISOString().slice(0, 10) + '.db',
    filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
  });
  if (canceled || !filePath) return { success: false, error: '用户取消' };
  return sendToWorker('backupDatabase', { outputPath: filePath });
});

// 文件对话框
ipcMain.handle('dialog:selectDbFile', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
    title: '选择 ToolApp 数据库文件',
    filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
    properties: ['openFile'],
  });
  return (canceled || filePaths.length === 0) ? null : filePaths[0];
});

ipcMain.handle('dialog:selectFolder', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
    title: '选择数据库所在目录',
    properties: ['openDirectory'],
  });
  return (canceled || filePaths.length === 0) ? null : filePaths[0];
});

ipcMain.handle('dialog:selectSavePath', async (event, defaultName) => {
  const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
    title: '保存文件',
    defaultPath: defaultName || 'export.csv',
    filters: [
      { name: 'CSV 文件', extensions: ['csv'] },
      { name: 'JSON 文件', extensions: ['json'] },
    ],
  });
  return (canceled || !filePath) ? null : filePath;
});

ipcMain.handle('file:saveExport', (event, { data, filePath }) => {
  try {
    fs.writeFileSync(filePath, data, 'utf-8');
    return { success: true, path: filePath };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// ============ 应用生命周期 ============
app.whenReady().then(async () => {
  console.log('✓ Electron 已就绪');
  
  try {
    await startDbWorker();
    console.log('✓ 数据库工作进程启动成功');
  } catch (err) {
    console.error('启动数据库工作进程失败:', err.message);
  }
  
  createWindow();
});

app.on('window-all-closed', () => {
  console.log('所有窗口已关闭');
  if (dbWorker) {
    dbWorker.kill();
    dbWorker = null;
  }
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

console.log('=== 主进程初始化完成 ===');
