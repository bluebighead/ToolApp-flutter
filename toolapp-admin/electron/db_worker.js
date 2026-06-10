// 数据库工作进程 - 在独立的 Node.js 进程中运行
// 使用 better-sqlite3 进行同步数据库操作
const fs = require('fs');
const path = require('path');

console.error = (...args) => {
  // 重定向 stderr 到控制台
  process.stderr.write(args.join(' ') + '\n');
};

// ============ 数据库状态 ============
let db = null;
let dbPath = null;
let Database = null;

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
      case 'testConnection':
        result = testConnection();
        break;
      case 'getMode':
        result = db ? 'local' : 'none';
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
      case 'disconnect':
        if (db) {
          try { db.close(); } catch(e) {}
          db = null;
          dbPath = null;
        }
        result = { success: true };
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

function testConnection() {
  if (!db) return { success: false, error: '未连接' };
  try {
    db.prepare('SELECT 1').get();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

function getStats() {
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

function getUsers(params) {
  if (!db) return { rows: [], total: 0, error: '未连接' };
  const { page = 1, pageSize = 20, search = '' } = params;
  const offset = (page - 1) * pageSize;
  
  try {
    let total;
    let rows;
    if (search) {
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE email LIKE ?').get('%' + search + '%').count;
      rows = db.prepare('SELECT id, email, created_at FROM users WHERE email LIKE ? ORDER BY id LIMIT ? OFFSET ?').all('%' + search + '%', pageSize, offset);
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
      rows = db.prepare('SELECT id, email, created_at FROM users ORDER BY id LIMIT ? OFFSET ?').all(pageSize, offset);
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

// 发送就绪信号
sendMessage({ type: 'ready' });
