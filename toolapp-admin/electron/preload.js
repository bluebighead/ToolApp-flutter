// IPC 桥接：暴露安全的 API 给渲染进程
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  // 数据库扫描 & 连接管理
  autoScanDatabase: () => ipcRenderer.invoke('db:autoScanDatabase'),
  scanDatabase: (dirPath) => ipcRenderer.invoke('db:scanDatabase', dirPath),
  connectLocal: (dbPath) => ipcRenderer.invoke('db:connectLocal', dbPath),
  connectRemote: (serverUrl, password) => ipcRenderer.invoke('db:connectRemote', serverUrl, password),
  testConnection: () => ipcRenderer.invoke('db:testConnection'),
  disconnect: () => ipcRenderer.invoke('db:disconnect'),
  getMode: () => ipcRenderer.invoke('db:getMode'),
  getLocalDbPath: () => ipcRenderer.invoke('db:getLocalDbPath'),

  // 数据查询
  getStats: () => ipcRenderer.invoke('db:getStats'),
  getUsers: (params) => ipcRenderer.invoke('db:getUsers', params),
  getTableData: (table, params) => ipcRenderer.invoke('db:getTableData', table, params),
  updateRecord: (table, id, data) => ipcRenderer.invoke('db:updateRecord', table, id, data),
  deleteRecord: (table, id) => ipcRenderer.invoke('db:deleteRecord', table, id),
  deleteUser: (userId) => ipcRenderer.invoke('db:deleteUser', userId),
  createUser: (email, password, accountType) => ipcRenderer.invoke('db:createUser', { email, password, accountType }),

  // 在线状态 & 会话监控
  getOnlineStatus: () => ipcRenderer.invoke('db:getOnlineStatus'),
  getUserSessions: (userId, params) => ipcRenderer.invoke('db:getUserSessions', { userId, ...params }),
  getUserActivity: (userId, params) => ipcRenderer.invoke('db:getUserActivity', { userId, ...params }),
  getUserDeviceInfo: (userId) => ipcRenderer.invoke('db:getUserDeviceInfo', { userId }),

  // 系统信息
  getSystemInfo: () => ipcRenderer.invoke('db:getSystemInfo'),
  getLocalDatabaseInfo: () => ipcRenderer.invoke('db:getLocalDatabaseInfo'),
  changePassword: (newPassword) => ipcRenderer.invoke('db:changePassword', newPassword),

  // 导出备份
  exportTable: (table, format) => ipcRenderer.invoke('db:exportTable', table, format),
  backupDatabase: () => ipcRenderer.invoke('db:backupDatabase'),

  // 文件对话框
  selectDbFile: () => ipcRenderer.invoke('dialog:selectDbFile'),
  selectFolder: () => ipcRenderer.invoke('dialog:selectFolder'),
  selectSavePath: (defaultName) => ipcRenderer.invoke('dialog:selectSavePath', defaultName),
  saveExport: (data) => ipcRenderer.invoke('file:saveExport', data),

  // 版本管理
  getAppVersions: () => ipcRenderer.invoke('version:getList'),
  createAppVersion: (data) => ipcRenderer.invoke('version:create', data),
  updateAppVersion: (id, data) => ipcRenderer.invoke('version:update', { id, data }),
  deleteAppVersion: (id) => ipcRenderer.invoke('version:delete', id),
  selectApkFile: () => ipcRenderer.invoke('dialog:selectApkFile'),

  // 用户反馈
  getFeedbacks: (params) => ipcRenderer.invoke('feedback:getList', params),
});
