// 数据库工作进程 - 在独立的 Node.js 进程中运行
// 使用 better-sqlite3 进行同步数据库操作
const fs = require('fs');
const path = require('path');

console.error = (...args) => {
  // 重定向 stderr 到控制台
  process.stderr.write(args.join(' ') + '\n');
};

// 远程 API 请求通用方法
function remoteGet(apiPath) {
  return new Promise((resolve, reject) => {
    if (!remoteUrl) return reject(new Error('未连接远程服务器'));
    const http = require('http');
    const apiUrl = new URL(apiPath, remoteUrl);
    const req = http.request(apiUrl, {
      method: 'GET',
      headers: { 'x-admin-password': remotePassword },
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch(e) {
          reject(new Error('服务器响应格式错误'));
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('连接超时')); });
    req.end();
  });
}

// 远程 API POST 请求通用方法
function remotePost(apiPath, body) {
  return new Promise((resolve, reject) => {
    if (!remoteUrl) return reject(new Error('未连接远程服务器'));
    const http = require('http');
    const apiUrl = new URL(apiPath, remoteUrl);
    const postData = JSON.stringify(body || {});
    const req = http.request(apiUrl, {
      method: 'POST',
      headers: {
        'x-admin-password': remotePassword,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
      },
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch(e) {
          reject(new Error('服务器响应格式错误'));
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('连接超时')); });
    req.write(postData);
    req.end();
  });
}

// ============ 数据库状态 ============
let db = null;
let dbPath = null;
let Database = null;

// 远程连接状态
let remoteMode = false;
let remoteUrl = '';
let remotePassword = '';

try {
  Database = require('better-sqlite3');
} catch (err) {
  try {
    // 如果 better-sqlite3 不可用，回退到 sqlite3
    const sqlite3 = require('sqlite3').verbose();
    Database = function(dbPath, options) {
      this._db = new sqlite3.Database(dbPath, options?.readonly ? sqlite3.OPEN_READONLY : sqlite3.OPEN_READWRITE);
      return this;
    };
    Database.prototype.prepare = function(sql) {
      const stmt = this._db.prepare(sql);
      return {
        get: (...params) => new Promise((resolve, reject) => {
          stmt.get(...params, (err, row) => err ? reject(err) : resolve(row));
        }),
        all: (...params) => new Promise((resolve, reject) => {
          stmt.all(...params, (err, rows) => err ? reject(err) : resolve(rows));
        }),
        run: (...params) => new Promise((resolve, reject) => {
          stmt.run(...params, (err) => err ? reject(err) : resolve());
        })
      };
    };
    Database.prototype.exec = function(sql) {
      return new Promise((resolve, reject) => {
        this._db.exec(sql, (err) => err ? reject(err) : resolve());
      });
    };
    Database.prototype.close = function() {
      return new Promise((resolve, reject) => {
        this._db.close((err) => err ? reject(err) : resolve());
      });
    };
  } catch (err2) {
    sendError('NO_SQLITE', '无法加载 better-sqlite3 或 sqlite3');
    process.exit(1);
  }
}

// ============ 消息通信 ============
function sendMessage(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function sendResult(id, result) {
  sendMessage({ id, type: 'result', result });
}

function sendError(id, code, message) {
  sendMessage({ id, type: 'error', error: { code, message } });
}

// 读取 stdin 中的 JSON 行消息
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  const lines = buffer.split('\n');
  buffer = lines.pop();
  
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const msg = JSON.parse(trimmed);
      handleMessage(msg);
    } catch (err) {
      sendError(null, 'PARSE_ERROR', '无法解析消息: ' + err.message);
    }
  }
});

process.stdin.on('end', () => {
  if (db) {
    try { db.close(); } catch(e) {}
  }
});

// ============ 消息处理 ============
async function handleMessage(msg) {
  const { id, method, params } = msg;
  
  try {
    let result;
    switch (method) {
      case 'ping':
        result = { ok: true, time: Date.now() };
        break;
      case 'autoScanDatabase':
        result = autoScanDatabase();
        break;
      case 'scanDatabase':
        result = scanDatabase(params?.dir);
        break;
      case 'connectLocal':
        result = await connectLocal(params?.dbPath);
        break;
      case 'connectRemote':
        result = await connectRemote(params?.serverUrl, params?.password);
        break;
      case 'testConnection':
        result = testConnection();
        break;
      case 'getMode':
        result = remoteMode ? 'remote' : (db ? 'local' : 'none');
        break;
      case 'getLocalDbPath':
        result = dbPath;
        break;
      case 'getStats':
        result = getStats();
        break;
      case 'getUsers':
        result = getUsers(params || {});
        break;
      case 'getTableData':
        result = getTableData(params?.table, params || {});
        break;
      case 'updateRecord':
        result = updateRecord(params?.table, params?.id, params?.data);
        break;
      case 'deleteRecord':
        result = deleteRecord(params?.table, params?.id);
        break;
      case 'deleteUser':
        result = deleteUser(params?.userId);
        break;
      case 'exportTable':
        result = exportTable(params?.table, params?.format);
        break;
      case 'backupDatabase':
        result = await backupDatabase(params?.outputPath);
        break;
      case 'changePassword':
        result = await changePassword(params?.newPassword);
        break;
      case 'disconnect':
        if (db) {
          try { db.close(); } catch(e) {}
          db = null;
          dbPath = null;
        }
        remoteMode = false;
        remoteUrl = '';
        remotePassword = '';
        result = { success: true };
        break;
      case 'getOnlineStatus':
        result = getOnlineStatus();
        break;
      case 'getUserSessions':
        result = getUserSessions(params?.userId, params || {});
        break;
      case 'getUserActivity':
        result = getUserActivity(params?.userId, params || {});
        break;
      case 'getSystemInfo':
        result = getSystemInfo();
        break;
      case 'getLocalDatabaseInfo':
        result = getLocalDatabaseInfo();
        break;
      default:
        sendError(id, 'UNKNOWN_METHOD', '未知方法: ' + method);
        return;
    }
    sendResult(id, result);
  } catch (err) {
    sendError(id, 'ERROR', err.message);
  }
}

// ============ 数据库操作实现 ============

function autoScanDatabase() {
  // 尝试多个位置找到 toolapp.db
  const candidates = [
    // 从 electron/ 目录向上两级（最常见的项目结构）
    path.join(__dirname, '..', '..', 'toolapp-server', 'data'),
    // 从 electron/ 目录向上一级
    path.join(__dirname, '..', 'toolapp-server', 'data'),
    // 当前工作目录的 toolapp-server/data
    path.join(process.cwd(), 'toolapp-server', 'data'),
    // 当前工作目录的父目录中的 toolapp-server/data
    path.join(path.dirname(process.cwd()), 'toolapp-server', 'data'),
    // 简单的 data 目录
    path.join(process.cwd(), 'data'),
    path.join(__dirname, 'data'),
    // 尝试从项目根目录的常见位置
  ];
  
  for (const dir of candidates) {
    const result = scanDatabase(dir);
    if (result && result.found) {
      return result;
    }
  }
  return { found: false, scannedPaths: candidates };
}

function scanDatabase(dir) {
  if (!dir || !fs.existsSync(dir)) {
    return { found: false, info: null };
  }
  
  const dbFile = path.join(dir, 'toolapp.db');
  if (!fs.existsSync(dbFile)) {
    return { found: false, info: null };
  }
  
  // 验证数据库
  try {
    const testDb = new Database(dbFile, { readonly: true });
    const row = testDb.prepare("SELECT COUNT(*) as count FROM sqlite_master WHERE type='table' AND name='users'").get();
    const hasUsers = row.count > 0;
    
    if (!hasUsers) {
      testDb.close();
      return { found: false, error: '数据库缺少 users 表' };
    }
    
    const info = {};
    const tables = ['users', 'heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
    for (const table of tables) {
      try {
        const r = testDb.prepare('SELECT COUNT(*) as count FROM ' + table).get();
        info[table] = r.count;
      } catch(e) { info[table] = 0; }
    }
    
    testDb.close();
    return { found: true, dbPath: dbFile, info };
  } catch (err) {
    return { found: false, error: err.message };
  }
}

async function connectLocal(newDbPath) {
  if (!newDbPath || !fs.existsSync(newDbPath)) {
    return { success: false, error: '数据库文件不存在' };
  }
  
  try {
    // 关闭旧连接
    if (db) {
      try { db.close(); } catch(e) {}
    }
    
    db = new Database(newDbPath);
    dbPath = newDbPath;
    
    // 验证
    const row = db.prepare('SELECT COUNT(*) as count FROM users').get();
    
    const info = {};
    const tables = ['users', 'heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
    for (const table of tables) {
      try {
        const r = db.prepare('SELECT COUNT(*) as count FROM ' + table).get();
        info[table] = r.count;
      } catch(e) { info[table] = 0; }
    }
    
    return { success: true, info };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

// 连接远程服务器
async function connectRemote(url, password) {
  try {
    // 关闭本地数据库连接
    if (db) {
      try { db.close(); } catch(e) {}
      db = null;
      dbPath = null;
    }

    // 测试远程连接
    const http = require('http');
    const testUrl = new URL('/api/admin/system-info', url);

    const info = await new Promise((resolve, reject) => {
      const req = http.request(testUrl, {
        method: 'GET',
        headers: { 'x-admin-password': password || '' },
        timeout: 10000,
      }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json.error) {
              reject(new Error(json.error));
            } else {
              resolve(json);
            }
          } catch(e) {
            reject(new Error('服务器响应格式错误'));
          }
        });
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('连接超时')); });
      req.end();
    });

    // 连接成功，保存远程状态
    remoteMode = true;
    remoteUrl = url;
    remotePassword = password || '';

    return { success: true, info };
  } catch (err) {
    remoteMode = false;
    remoteUrl = '';
    remotePassword = '';
    return { success: false, error: err.message };
  }
}

function testConnection() {
  if (!db) return { success: false, error: '未连接' };
  try {
    db.prepare('SELECT 1').get();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

async function getStats() {
  // 远程模式：从服务器 API 获取
  if (remoteMode && remoteUrl) {
    try {
      return await remoteGet('/api/admin/stats');
    } catch (err) {
      return { users: 0, error: err.message };
    }
  }

  if (!db) return { users: 0, error: '未连接' };
  const stats = {};
  const tableMap = {
    'users': 'users',
    'heart_rate_sessions': 'heartRate',
    'network_speed_records': 'networkSpeed',
    'convert_history': 'convert',
    'dice_records': 'dice',
    'period_records': 'period',
  };
  for (const [table, key] of Object.entries(tableMap)) {
    try {
      const r = db.prepare('SELECT COUNT(*) as count FROM ' + table).get();
      stats[key] = r.count;
    } catch(e) { stats[key] = 0; }
  }
  return stats;
}

async function getUsers(params) {
  // 远程模式：从服务器 API 获取
  if (remoteMode && remoteUrl) {
    try {
      const query = new URLSearchParams();
      if (params?.page) query.set('page', params.page);
      if (params?.pageSize) query.set('pageSize', params.pageSize);
      if (params?.search) query.set('search', params.search);
      return await remoteGet('/api/admin/users?' + query.toString());
    } catch (err) {
      return { rows: [], total: 0, error: err.message };
    }
  }

  if (!db) return { rows: [], total: 0, error: '未连接' };
  const { page = 1, pageSize = 20, search = '' } = params;
  const offset = (page - 1) * pageSize;
  
  try {
    let total;
    let rows;
    if (search) {
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE email LIKE ?').get('%' + search + '%').count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users WHERE email LIKE ? ORDER BY id LIMIT ? OFFSET ?').all('%' + search + '%', pageSize, offset);
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users ORDER BY id LIMIT ? OFFSET ?').all(pageSize, offset);
    }
    
    const usersWithData = rows.map(user => {
      const dataCount = {};
      const tables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
      const keyMap = {
        'heart_rate_sessions': 'heartRate',
        'network_speed_records': 'networkSpeed',
        'convert_history': 'convert',
        'dice_records': 'dice',
        'period_records': 'period',
      };
      for (const table of tables) {
        try {
          const r = db.prepare('SELECT COUNT(*) as count FROM ' + table + ' WHERE user_id = ?').get(user.id);
          dataCount[keyMap[table]] = r.count;
        } catch(e) { dataCount[keyMap[table]] = 0; }
      }
      return { ...user, dataCount };
    });
    
    return { rows: usersWithData, total, page, pageSize };
  } catch (err) {
    return { rows: [], total: 0, error: err.message };
  }
}

function getTableData(table, params) {
  if (!db) return { rows: [], total: 0, error: '未连接' };
  const validTables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
  if (!validTables.includes(table)) return { rows: [], total: 0, error: '无效的表名' };
  
  const { page = 1, pageSize = 20, userId = '' } = params;
  const offset = (page - 1) * pageSize;
  
  try {
    let total;
    let rows;
    if (userId) {
      total = db.prepare('SELECT COUNT(*) as count FROM ' + table + ' WHERE user_id = ?').get(userId).count;
      rows = db.prepare('SELECT * FROM ' + table + ' WHERE user_id = ? ORDER BY id DESC LIMIT ? OFFSET ?').all(userId, pageSize, offset);
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM ' + table).get().count;
      rows = db.prepare('SELECT * FROM ' + table + ' ORDER BY id DESC LIMIT ? OFFSET ?').all(pageSize, offset);
    }
    return { rows, total, page, pageSize };
  } catch (err) {
    return { rows: [], total: 0, error: err.message };
  }
}

function updateRecord(table, id, data) {
  if (!db) return { success: false, error: '未连接' };
  const validTables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
  if (!validTables.includes(table)) return { success: false, error: '无效的表名' };
  
  try {
    const cols = Object.keys(data);
    const setClause = cols.map(c => c + ' = ?').join(', ');
    const vals = [...Object.values(data), id];
    db.prepare('UPDATE ' + table + ' SET ' + setClause + ' WHERE id = ?').run(...vals);
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

function deleteRecord(table, id) {
  if (!db) return { success: false, error: '未连接' };
  const validTables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
  if (!validTables.includes(table)) return { success: false, error: '无效的表名' };
  
  try {
    db.prepare('DELETE FROM ' + table + ' WHERE id = ?').run(id);
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

function deleteUser(userId) {
  if (!db) return { success: false, error: '未连接' };
  try {
    const tables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];
    for (const table of tables) {
      try {
        db.prepare('DELETE FROM ' + table + ' WHERE user_id = ?').run(userId);
      } catch(e) {}
    }
    db.prepare('DELETE FROM users WHERE id = ?').run(userId);
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

function exportTable(table, format) {
  if (!db) return { success: false, error: '未连接' };
  const allTables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records', 'users'];
  if (!allTables.includes(table)) return { success: false, error: '无效的表名' };
  
  try {
    const rows = db.prepare('SELECT * FROM ' + table).all();
    
    if (format === 'csv') {
      if (rows.length === 0) return { data: '', format: 'csv' };
      const headers = Object.keys(rows[0]);
      const csvLines = [headers.join(',')];
      for (const row of rows) {
        const values = headers.map(h => {
          const val = row[h];
          if (val === null || val === undefined) return '';
          const str = String(val);
          return (str.includes(',') || str.includes('"') || str.includes('\n'))
            ? '"' + str.replace(/"/g, '""') + '"'
            : str;
        });
        csvLines.push(values.join(','));
      }
      return { data: csvLines.join('\n'), format: 'csv' };
    }
    
    return { data: JSON.stringify(rows, null, 2), format: 'json' };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

async function backupDatabase(outputPath) {
  if (!db) return { success: false, error: '未连接' };
  try {
    // 使用文件复制方式进行备份
    const source = dbPath;
    const dest = outputPath;
    fs.copyFileSync(source, dest);
    return { success: true, path: dest };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

// ============ 在线状态 & 会话监控 ============
function tableExists(tableName) {
  if (!db) return false;
  try {
    const row = db.prepare("SELECT COUNT(*) as count FROM sqlite_master WHERE type='table' AND name=?").get(tableName);
    return row.count > 0;
  } catch (e) {
    return false;
  }
}

async function getOnlineStatus() {
  // 远程模式：从服务器 API 获取
  if (remoteMode && remoteUrl) {
    try {
      return await remoteGet('/api/admin/users/online-status');
    } catch (err) {
      return { users: [], onlineCount: 0, totalCount: 0, timestamp: Date.now(), error: err.message };
    }
  }

  if (!db) return { users: [], onlineCount: 0, totalCount: 0, timestamp: Date.now() };

  try {
    // 获取所有用户
    const users = db.prepare('SELECT id, email, created_at FROM users ORDER BY id').all();

    const hasSessionsTable = tableExists('user_sessions');
    const hasActivityTable = tableExists('user_activity_logs');
    const now = Date.now();

    const result = users.map(user => {
      let isOnline = false;
      let lastSeen = null;
      let currentSessionStart = null;
      let todayUsageSeconds = 0;
      let totalUsageSeconds = 0;
      let sessionCount = 0;
      let deviceInfo = null;
      let ipAddress = null;

      if (hasSessionsTable) {
        try {
          // 获取用户最新的会话
          const latestSession = db.prepare(`
            SELECT * FROM user_sessions
            WHERE user_id = ?
            ORDER BY id DESC
            LIMIT 1
          `).get(user.id);

          if (latestSession) {
            const heartbeatTime = latestSession.last_heartbeat
              ? new Date(latestSession.last_heartbeat).getTime()
              : 0;
            // 判断在线：is_online=1 且心跳时间在5分钟内
            // 只有同时满足这两个条件才视为在线，避免用户退出后仍显示在线
            const ONLINE_THRESHOLD = 5 * 60 * 1000;
            isOnline = latestSession.is_online === 1
              && latestSession.last_heartbeat
              && (now - heartbeatTime) < ONLINE_THRESHOLD;
            lastSeen = latestSession.last_heartbeat || latestSession.session_start;
            currentSessionStart = latestSession.session_start;
            deviceInfo = latestSession.device_info;
            ipAddress = latestSession.ip_address;
          }

          // 统计今日使用时长
          const today = new Date();
          today.setHours(0, 0, 0, 0);
          const todayStr = today.toISOString().slice(0, 10);

          const todayStats = db.prepare(`
            SELECT COALESCE(SUM(
              CASE
                WHEN session_end IS NOT NULL THEN duration_seconds
                ELSE CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER)
              END
            ), 0) as total_seconds
            FROM user_sessions
            WHERE user_id = ? AND date(session_start) >= ?
          `).get(user.id, todayStr);
          todayUsageSeconds = todayStats.total_seconds || 0;

          // 统计总使用时长
          const totalStats = db.prepare(`
            SELECT COALESCE(SUM(
              CASE
                WHEN session_end IS NOT NULL THEN duration_seconds
                ELSE CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER)
              END
            ), 0) as total_seconds
            FROM user_sessions
            WHERE user_id = ?
          `).get(user.id);
          totalUsageSeconds = totalStats.total_seconds || 0;

          // 统计会话次数
          const countRow = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(user.id);
          sessionCount = countRow.count;
        } catch (e) {
          // 表可能不存在或字段不匹配
        }
      }

      return {
        ...user,
        isOnline,
        lastSeen,
        currentSessionStart,
        todayUsageSeconds,
        totalUsageSeconds,
        sessionCount,
        deviceInfo,
        ipAddress,
      };
    });

    // 按在线状态排序（在线用户在前）
    result.sort((a, b) => (b.isOnline ? 1 : 0) - (a.isOnline ? 1 : 0));

    const onlineCount = result.filter(u => u.isOnline).length;

    return {
      users: result,
      onlineCount,
      totalCount: result.length,
      timestamp: new Date().toISOString(),
    };
  } catch (err) {
    return { users: [], onlineCount: 0, totalCount: 0, error: err.message };
  }
}

function getUserSessions(userId, params) {
  if (!db) return { rows: [], total: 0, error: '未连接' };
  if (!tableExists('user_sessions')) return { rows: [], total: 0, error: '会话表不存在' };

  const { page = 1, pageSize = 20 } = params;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(userId).count;
    const sessions = db.prepare(`
      SELECT * FROM user_sessions
      WHERE user_id = ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    `).all(userId, pageSize, offset);

    return { rows: sessions, total, page, pageSize };
  } catch (err) {
    return { rows: [], total: 0, error: err.message };
  }
}

function getUserActivity(userId, params) {
  if (!db) return { rows: [], total: 0, error: '未连接' };
  if (!tableExists('user_activity_logs')) return { rows: [], total: 0, error: '活动日志表不存在' };

  const { page = 1, pageSize = 50 } = params;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_activity_logs WHERE user_id = ?').get(userId).count;
    const logs = db.prepare(`
      SELECT * FROM user_activity_logs
      WHERE user_id = ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    `).all(userId, pageSize, offset);

    return { rows: logs, total, page, pageSize };
  } catch (err) {
    return { rows: [], total: 0, error: err.message };
  }
}

// ============ 系统信息 ============
async function getSystemInfo() {
  // 远程模式：从服务器 API 获取
  if (remoteMode && remoteUrl) {
    try {
      const http = require('http');
      const apiUrl = new URL('/api/admin/system-info', remoteUrl);

      return await new Promise((resolve, reject) => {
        const req = http.request(apiUrl, {
          method: 'GET',
          headers: { 'x-admin-password': remotePassword },
          timeout: 10000,
        }, (res) => {
          let data = '';
          res.on('data', chunk => data += chunk);
          res.on('end', () => {
            try {
              const json = JSON.parse(data);
              if (json.error) {
                resolve({ error: json.error });
              } else {
                resolve(json);
              }
            } catch(e) {
              resolve({ error: '服务器响应格式错误' });
            }
          });
        });
        req.on('error', (e) => resolve({ error: e.message }));
        req.on('timeout', () => { req.destroy(); resolve({ error: '连接超时' }); });
        req.end();
      });
    } catch (err) {
      return { error: err.message };
    }
  }

  // 本地模式：直接读取数据库
  if (!db) return { error: '未连接' };

  try {
    const os = require('os');
    const tableInfo = {};
    const tables = [
      { name: 'users', key: 'users' },
      { name: 'heart_rate_sessions', key: 'heart_rate_sessions' },
      { name: 'network_speed_records', key: 'network_speed_records' },
      { name: 'convert_history', key: 'convert_history' },
      { name: 'dice_records', key: 'dice_records' },
      { name: 'period_records', key: 'period_records' },
      { name: 'user_sessions', key: 'user_sessions' },
      { name: 'user_activity_logs', key: 'user_activity_logs' },
    ];

    for (const { name, key } of tables) {
      if (tableExists(name)) {
        const row = db.prepare('SELECT COUNT(*) as count FROM ' + name).get();
        tableInfo[key] = row.count;
      } else {
        tableInfo[key] = 0;
      }
    }

    return {
      server: {
        platform: os.platform(),
        hostname: os.hostname(),
        uptime: process.uptime(),
        memory: {
          total: os.totalmem(),
          free: os.freemem(),
        },
        nodeVersion: process.version,
      },
      database: {
        path: dbPath,
        size: (() => {
          let s = 0;
          if (dbPath && fs.existsSync(dbPath)) {
            s += fs.statSync(dbPath).size;
            if (fs.existsSync(dbPath + '-wal')) s += fs.statSync(dbPath + '-wal').size;
            if (fs.existsSync(dbPath + '-shm')) s += fs.statSync(dbPath + '-shm').size;
          }
          return s;
        })(),
        tables: tableInfo,
      },
    };
  } catch (err) {
    return { error: err.message };
  }
}

function getLocalDatabaseInfo() {
  if (!db) return { error: '未连接' };

  try {
    const tableInfo = {};
    const tables = [
      { name: 'users', key: 'users' },
      { name: 'heart_rate_sessions', key: 'heart_rate_sessions' },
      { name: 'network_speed_records', key: 'network_speed_records' },
      { name: 'convert_history', key: 'convert_history' },
      { name: 'dice_records', key: 'dice_records' },
      { name: 'period_records', key: 'period_records' },
      { name: 'user_sessions', key: 'user_sessions' },
      { name: 'user_activity_logs', key: 'user_activity_logs' },
    ];

    for (const { name, key } of tables) {
      if (tableExists(name)) {
        const row = db.prepare('SELECT COUNT(*) as count FROM ' + name).get();
        tableInfo[key] = row.count;
      } else {
        tableInfo[key] = 0;
      }
    }

    // 计算数据库总大小（包括 WAL 和 SHM 文件）
    let totalSize = 0;
    if (dbPath && fs.existsSync(dbPath)) {
      totalSize += fs.statSync(dbPath).size;
      const walPath = dbPath + '-wal';
      const shmPath = dbPath + '-shm';
      if (fs.existsSync(walPath)) totalSize += fs.statSync(walPath).size;
      if (fs.existsSync(shmPath)) totalSize += fs.statSync(shmPath).size;
    }

    return {
      path: dbPath,
      size: totalSize,
      tables: tableInfo,
    };
  } catch (err) {
    return { error: err.message };
  }
}

// 修改管理员密码（仅远程模式）
async function changePassword(newPassword) {
  if (remoteMode && remoteUrl) {
    try {
      const result = await remotePost('/api/admin/change-password', { newPassword });
      if (result.success) {
        // 更新本地保存的密码
        remotePassword = newPassword;
      }
      return result;
    } catch (err) {
      return { error: err.message };
    }
  }
  return { error: '仅远程模式支持修改密码' };
}

// 发送就绪信号
sendMessage({ type: 'ready' });
