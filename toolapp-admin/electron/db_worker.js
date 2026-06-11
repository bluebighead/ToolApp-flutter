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
        result = await getStats();
        break;
      case 'getUsers':
        result = await getUsers(params || {});
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
      case 'createUser':
        result = createUser(params?.email, params?.password, params?.accountType);
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
        result = await getOnlineStatus();
        break;
      case 'getUserSessions':
        result = getUserSessions(params?.userId, params || {});
        break;
      case 'getUserActivity':
        result = getUserActivity(params?.userId, params || {});
        break;
      case 'getUserDeviceInfo':
        result = getUserDeviceInfo(params?.userId);
        break;
      case 'getSystemInfo':
        result = await getSystemInfo();
        break;
      case 'getLocalDatabaseInfo':
        result = getLocalDatabaseInfo();
        break;
      case 'version:getList':
        result = await getVersionList();
        break;
      case 'version:create':
        result = await createVersion(params);
        break;
      case 'version:update':
        result = await updateVersion(params?.id, params?.data);
        break;
      case 'version:delete':
        result = await deleteVersion(params);
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
  const candidates = [
    path.join(__dirname, '..', '..', 'toolapp-server', 'data'),
    path.join(__dirname, '..', 'toolapp-server', 'data'),
    path.join(process.cwd(), 'toolapp-server', 'data'),
    path.join(path.dirname(process.cwd()), 'toolapp-server', 'data'),
    path.join(process.cwd(), 'data'),
    path.join(__dirname, 'data'),
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
    
    // 迁移：为已存在的users表添加is_deleted字段
    try {
      db.exec('ALTER TABLE users ADD COLUMN is_deleted INTEGER DEFAULT 0');
    } catch(e) {
      // 字段已存在，忽略
    }
    
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
      let query = 'SELECT COUNT(*) as count FROM ' + table;
      if (table === 'users') {
        query += ' WHERE is_deleted IS NULL OR is_deleted = 0';
      }
      const r = db.prepare(query).get();
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
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE email LIKE ? AND (is_deleted IS NULL OR is_deleted = 0)').get('%' + search + '%').count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users WHERE email LIKE ? AND (is_deleted IS NULL OR is_deleted = 0) ORDER BY id LIMIT ? OFFSET ?').all('%' + search + '%', pageSize, offset);
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE is_deleted IS NULL OR is_deleted = 0').get().count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users WHERE is_deleted IS NULL OR is_deleted = 0 ORDER BY id LIMIT ? OFFSET ?').all(pageSize, offset);
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
  // 远程模式：调用服务器 API
  if (remoteMode && remoteUrl) {
    return new Promise((resolve) => {
      const http = require('http');
      const apiUrl = new URL('/api/admin/users/' + userId, remoteUrl);
      const req = http.request(apiUrl, {
        method: 'DELETE',
        headers: { 'x-admin-password': remotePassword },
        timeout: 10000,
      }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const result = JSON.parse(data);
            resolve(result.success ? { success: true } : { success: false, error: result.error || result.message });
          } catch(e) {
            resolve({ success: false, error: '服务器响应格式错误' });
          }
        });
      });
      req.on('error', (err) => resolve({ success: false, error: err.message }));
      req.on('timeout', () => { req.destroy(); resolve({ success: false, error: '连接超时' }); });
      req.end();
    });
  }
  
  if (!db) return { success: false, error: '未连接' };
  try {
    // 软删除：标记用户为已注销
    db.prepare('UPDATE users SET is_deleted = 1 WHERE id = ?').run(userId);
    
    // 清理关联数据
    const tables = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records', 'user_sessions', 'user_activity_logs', 'device_tokens'];
    for (const table of tables) {
      try {
        db.prepare('DELETE FROM ' + table + ' WHERE user_id = ?').run(userId);
      } catch(e) {}
    }
    // 清理该用户的邮箱验证码
    try {
      const user = db.prepare('SELECT email FROM users WHERE id = ?').get(userId);
      if (user) {
        db.prepare('DELETE FROM email_verification_codes WHERE email = ?').run(user.email);
      }
    } catch(e) {}
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

function createUser(email, password, accountType) {
  if (!email || !password) return { success: false, error: '账号和密码不能为空' };
  if (password.length < 6) return { success: false, error: '密码至少需要6位' };

  const isAdminType = accountType === 'admin';
  if (!isAdminType) {
    // 邮箱用户：严格校验邮箱格式
    const strictEmailRegex = /^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,10}$/;
    if (!strictEmailRegex.test(email.trim())) {
      return { success: false, error: '请输入有效的邮箱格式（例如：user@example.com）' };
    }
  } else {
    // 管理员账号：限制长度，不允许空格
    const trimmed = email.trim();
    if (trimmed.length > 64) return { success: false, error: '管理员账号名称不能超过64个字符' };
    if (/\s/.test(trimmed)) return { success: false, error: '管理员账号名称不能包含空格' };
  }

  // 远程模式：调用服务器 API（将账号类型传给服务器）
  if (remoteMode && remoteUrl) {
    return new Promise((resolve) => {
      const http = require('http');
      const apiUrl = new URL('/api/admin/users', remoteUrl);
      const body = JSON.stringify({ email, password, accountType });
      const req = http.request(apiUrl, {
        method: 'POST',
        headers: {
          'x-admin-password': remotePassword,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
        timeout: 10000,
      }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const result = JSON.parse(data);
            resolve(result.success ? { success: true, user: result.user } : { success: false, error: result.error || result.message });
          } catch(e) {
            resolve({ success: false, error: '服务器响应格式错误' });
          }
        });
      });
      req.on('error', (err) => resolve({ success: false, error: err.message }));
      req.on('timeout', () => { req.destroy(); resolve({ success: false, error: '连接超时' }); });
      req.write(body);
      req.end();
    });
  }

  // 本地模式
  if (!db) return { success: false, error: '未连接' };
  try {
    const bcrypt = require('bcryptjs');

    // 检查账号是否已注册
    const existing = db.prepare('SELECT id, is_deleted FROM users WHERE email = ?').get(email.trim());
    if (existing) {
      if (existing.is_deleted) {
        // 已注销账号：更新密码并激活
        const passwordHash = bcrypt.hashSync(password, 10);
        db.prepare('UPDATE users SET password_hash = ?, is_deleted = 0 WHERE id = ?').run(passwordHash, existing.id);
        return { success: true, user: { id: existing.id, email: email.trim() } };
      }
      return { success: false, error: '该账号已存在' };
    }

    // 创建新用户
    const passwordHash = bcrypt.hashSync(password, 10);
    const result = db.prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)').run(email, passwordHash);
    return { success: true, user: { id: result.lastInsertRowid, email } };
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

// ============ 用户设备参数 ============
async function getUserDeviceInfo(userId) {
  // 远程模式：从服务器 API 获取
  if (remoteMode && remoteUrl) {
    try {
      return await remoteGet('/api/admin/users/' + userId + '/device-info');
    } catch (err) {
      return { error: err.message };
    }
  }

  // 本地模式：从本地数据库查询
  if (!db) return { error: '未连接数据库' };

  try {
    if (!tableExists('user_device_info')) {
      return null; // 表不存在，返回 null
    }
    const deviceInfo = db.prepare(
      'SELECT * FROM user_device_info WHERE user_id = ? ORDER BY id DESC LIMIT 1'
    ).get(userId);
    return deviceInfo || null;
  } catch (err) {
    return { error: err.message };
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
        let sql = 'SELECT COUNT(*) as count FROM ' + name;
        if (name === 'users') {
          sql += ' WHERE is_deleted IS NULL OR is_deleted = 0';
        }
        const row = db.prepare(sql).get();
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

// ============ 版本管理 ============

// 获取版本列表
async function getVersionList() {
  if (remoteMode && remoteUrl) {
    try {
      return await remoteGet('/api/admin/app-versions');
    } catch (err) {
      return { error: err.message };
    }
  }
  // 本地模式
  if (!db) return { error: '数据库未连接' };
  try {
    return db.prepare('SELECT * FROM app_versions ORDER BY build_number DESC').all();
  } catch (err) {
    return { error: err.message };
  }
}

// 创建新版本（上传APK到远程服务器）
async function createVersion(data) {
  if (remoteMode && remoteUrl) {
    try {
      // 使用multipart/form-data上传APK文件
      const fs = require('fs');
      const path = require('path');
      const http = require('http');

      if (!data.apkFilePath || !data.version || !data.buildNumber) {
        return { error: '参数不完整' };
      }

      const filePath = data.apkFilePath;
      if (!fs.existsSync(filePath)) {
        return { error: 'APK文件不存在' };
      }

      const fileBuffer = fs.readFileSync(filePath);
      const fileName = path.basename(filePath);
      const boundary = '----FormBoundary' + Date.now();

      // 构建multipart body
      const parts = [];
      // version字段
      parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="version"\r\n\r\n${data.version}\r\n`));
      // build_number字段
      parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="build_number"\r\n\r\n${data.buildNumber}\r\n`));
      // update_notes字段
      if (data.updateNotes) {
        parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="update_notes"\r\n\r\n${data.updateNotes}\r\n`));
      }
      // force_update字段
      if (data.forceUpdate) {
        parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="force_update"\r\n\r\n1\r\n`));
      }
      // APK文件
      parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="apk"; filename="${fileName}"\r\nContent-Type: application/vnd.android.package-archive\r\n\r\n`));
      parts.push(fileBuffer);
      parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));

      const body = Buffer.concat(parts);

      return new Promise((resolve, reject) => {
        const apiUrl = new URL('/api/admin/app-version', remoteUrl);
        const req = http.request(apiUrl, {
          method: 'POST',
          headers: {
            'x-admin-password': remotePassword,
            'Content-Type': `multipart/form-data; boundary=${boundary}`,
            'Content-Length': body.length,
          },
          timeout: 300000, // 5分钟超时（大文件上传）
        }, (res) => {
          let responseData = '';
          res.on('data', chunk => responseData += chunk);
          res.on('end', () => {
            try {
              resolve(JSON.parse(responseData));
            } catch(e) {
              resolve({ error: '服务器响应格式错误' });
            }
          });
        });
        req.on('error', (err) => resolve({ error: err.message }));
        req.on('timeout', () => { req.destroy(); resolve({ error: '上传超时' }); });
        req.write(body);
        req.end();
      });
    } catch (err) {
      return { error: err.message };
    }
  }
  return { error: '本地模式暂不支持版本管理，请使用远程模式' };
}

// 更新版本信息
async function updateVersion(id, data) {
  if (remoteMode && remoteUrl) {
    try {
      return await remotePost(`/api/admin/app-version/${id}`, {
        version: data.version,
        build_number: data.buildNumber,
        update_notes: data.updateNotes,
        force_update: data.forceUpdate,
      });
    } catch (err) {
      return { error: err.message };
    }
  }
  return { error: '本地模式暂不支持版本管理' };
}

// 删除版本
async function deleteVersion(id) {
  if (remoteMode && remoteUrl) {
    try {
      return new Promise((resolve, reject) => {
        const http = require('http');
        const apiUrl = new URL(`/api/admin/app-version/${id}`, remoteUrl);
        const req = http.request(apiUrl, {
          method: 'DELETE',
          headers: { 'x-admin-password': remotePassword },
          timeout: 10000,
        }, (res) => {
          let data = '';
          res.on('data', chunk => data += chunk);
          res.on('end', () => {
            try {
              resolve(JSON.parse(data));
            } catch(e) {
              resolve({ error: '服务器响应格式错误' });
            }
          });
        });
        req.on('error', (err) => resolve({ error: err.message }));
        req.on('timeout', () => { req.destroy(); resolve({ error: '连接超时' }); });
        req.end();
      });
    } catch (err) {
      return { error: err.message };
    }
  }
  return { error: '本地模式暂不支持版本管理' };
}

// 发送就绪信号
sendMessage({ type: 'ready' });
