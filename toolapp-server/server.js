// ToolApp 轻量认证与数据同步服务器
// 技术栈：Express + better-sqlite3 + JWT
// 无需 Docker，直接在 Windows 上运行：npm install && npm start
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const path = require('path');

// ============================================================
// 配置
// ============================================================
const PORT = 3000;
const JWT_SECRET = 'toolapp-secret-key-change-in-production';
const JWT_EXPIRES_IN = '7d';
const DB_PATH = path.join(__dirname, 'data', 'toolapp.db');

// ============================================================
// 数据库初始化
// ============================================================
// 确保 data 目录存在
const fs = require('fs');
const dataDir = path.join(__dirname, 'data');
if (!fs.existsSync(dataDir)) {
  fs.mkdirSync(dataDir, { recursive: true });
}

const Database = require('better-sqlite3');
const db = new Database(DB_PATH);

// 启用 WAL 模式提升并发性能
db.pragma('journal_mode = WAL');

// 创建用户表
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  )
`);

// 创建数据同步表
db.exec(`
  CREATE TABLE IF NOT EXISTS heart_rate_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    start_time TEXT,
    end_time TEXT,
    max_hr INTEGER,
    min_hr INTEGER,
    avg_hr INTEGER,
    samples TEXT,
    connection_mode TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS network_speed_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    test_time TEXT,
    server_url TEXT,
    min_latency REAL,
    avg_latency REAL,
    max_latency REAL,
    jitter REAL,
    loss_rate REAL,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS convert_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    input_file TEXT,
    output_file TEXT,
    output_size INTEGER,
    format TEXT,
    quality TEXT,
    status TEXT,
    timestamp_ms INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS dice_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    dice_type TEXT,
    result TEXT,
    timestamp_ms INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS period_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    start_date TEXT,
    end_date TEXT,
    record_mode TEXT,
    flow_level INTEGER,
    symptoms TEXT,
    notes TEXT,
    local_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- 用户会话表 - 记录用户在线状态和使用时长
  CREATE TABLE IF NOT EXISTS user_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    session_start TEXT,
    session_end TEXT,
    duration_seconds INTEGER DEFAULT 0,
    device_info TEXT,
    ip_address TEXT,
    last_heartbeat TEXT,
    is_online INTEGER DEFAULT 0,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- 用户活动日志表 - 记录用户在App中的操作
  CREATE TABLE IF NOT EXISTS user_activity_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    activity_type TEXT,
    page_name TEXT,
    details TEXT,
    timestamp TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  )
`);

// ============================================================
// Express 应用
// ============================================================
const app = express();

// 中间件
app.use(cors());
app.use(express.json({ limit: '50mb' }));

// ============================================================
// JWT 认证中间件
// ============================================================
function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: '未提供认证令牌' });
  }

  const token = authHeader.substring(7);
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    req.userId = decoded.userId;
    req.email = decoded.email;
    next();
  } catch (err) {
    return res.status(401).json({ error: '认证令牌无效或已过期' });
  }
}

// ============================================================
// 认证接口
// ============================================================

// 注册
app.post('/api/auth/register', (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: '邮箱和密码不能为空' });
  }

  if (password.length < 6) {
    return res.status(400).json({ error: '密码至少需要6位' });
  }

  // 检查邮箱是否已注册
  const existing = db.prepare('SELECT id FROM users WHERE email = ?').get(email);
  if (existing) {
    return res.status(400).json({ error: '该邮箱已被注册' });
  }

  // 加密密码并插入
  const passwordHash = bcrypt.hashSync(password, 10);
  const result = db.prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)').run(email, passwordHash);

  // 生成 JWT
  const token = jwt.sign({ userId: result.lastInsertRowid, email }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

  res.status(201).json({
    user: { id: result.lastInsertRowid, email },
    token,
  });
});

// 登录
app.post('/api/auth/login', (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: '邮箱和密码不能为空' });
  }

  // 查找用户
  const user = db.prepare('SELECT id, email, password_hash FROM users WHERE email = ?').get(email);
  if (!user) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  // 验证密码
  if (!bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  // 生成 JWT
  const token = jwt.sign({ userId: user.id, email: user.email }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

  res.json({
    user: { id: user.id, email: user.email },
    token,
  });
});

// 获取当前用户信息
app.get('/api/auth/me', authMiddleware, (req, res) => {
  const user = db.prepare('SELECT id, email, created_at FROM users WHERE id = ?').get(req.userId);
  if (!user) {
    return res.status(404).json({ error: '用户不存在' });
  }
  res.json({ user });
});

// ============================================================
// 数据同步接口
// 采用"全量覆盖"策略：客户端上传所有数据，服务端先删后插
// ============================================================

// 同步数据通用接口
// POST /api/sync/:table - 上传全量数据
// GET /api/sync/:table - 下载全量数据
const SYNC_TABLES = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];

// ============================================================
// 用户会话与活动API - 在线状态上报和使用时长统计
// ============================================================

// 开始新会话（App启动时调用）
app.post('/api/session/start', authMiddleware, (req, res) => {
  const userId = req.userId;
  const { deviceInfo } = req.body || {};
  const ipAddress = req.headers['x-forwarded-for'] || req.ip || '';
  const now = new Date().toISOString();

  try {
    // 先将该用户之前的在线会话标记为离线
    db.prepare('UPDATE user_sessions SET is_online = 0, session_end = ? WHERE user_id = ? AND is_online = 1').run(now, userId);

    // 创建新会话
    const result = db.prepare(`
      INSERT INTO user_sessions (user_id, session_start, device_info, ip_address, last_heartbeat, is_online)
      VALUES (?, ?, ?, ?, ?, 1)
    `).run(userId, now, deviceInfo || '', ipAddress, now);

    res.json({ sessionId: result.lastInsertRowid, startTime: now });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 心跳上报（App定期调用，表明用户仍在线）
app.post('/api/session/heartbeat', authMiddleware, (req, res) => {
  const userId = req.userId;
  const { sessionId } = req.body || {};
  const now = new Date().toISOString();

  try {
    if (sessionId) {
      // 更新指定会话的心跳时间
      db.prepare('UPDATE user_sessions SET last_heartbeat = ?, is_online = 1 WHERE id = ? AND user_id = ?').run(now, sessionId, userId);
    } else {
      // 更新用户最新的在线会话
      db.prepare('UPDATE user_sessions SET last_heartbeat = ?, is_online = 1 WHERE user_id = ? AND is_online = 1').run(now, userId);
    }
    res.json({ received: true, timestamp: now });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 结束会话（App退出时调用）
app.post('/api/session/end', authMiddleware, (req, res) => {
  const userId = req.userId;
  const now = new Date().toISOString();

  try {
    // 计算会话时长并标记为离线
    const sessions = db.prepare('SELECT id, session_start FROM user_sessions WHERE user_id = ? AND is_online = 1').all(userId);

    for (const session of sessions) {
      const start = new Date(session.session_start).getTime();
      const end = new Date(now).getTime();
      const duration = Math.floor((end - start) / 1000);
      db.prepare('UPDATE user_sessions SET session_end = ?, duration_seconds = ?, is_online = 0 WHERE id = ?').run(now, duration, session.id);
    }

    res.json({ ended: true, endTime: now });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 上报用户活动
app.post('/api/activity/log', authMiddleware, (req, res) => {
  const userId = req.userId;
  const { activityType, pageName, details } = req.body || {};
  const now = new Date().toISOString();

  try {
    db.prepare(`
      INSERT INTO user_activity_logs (user_id, activity_type, page_name, details, timestamp)
      VALUES (?, ?, ?, ?, ?)
    `).run(userId, activityType || '', pageName || '', details || '', now);
    res.json({ logged: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 上传同步数据
app.post('/api/sync/:table', authMiddleware, (req, res) => {
  const { table } = req.params;

  if (!SYNC_TABLES.includes(table)) {
    return res.status(400).json({ error: '无效的数据表' });
  }

  const { rows } = req.body;
  if (!Array.isArray(rows)) {
    return res.status(400).json({ error: '数据格式错误，需要 rows 数组' });
  }

  const userId = req.userId;

  try {
    // 在事务中执行：先删后插
    const deleteStmt = db.prepare(`DELETE FROM ${table} WHERE user_id = ?`);
    let insertStmt;

    if (rows.length === 0) {
      deleteStmt.run(userId);
      return res.json({ uploaded: 0 });
    }

    // 根据表名构建 INSERT 语句
    const columns = Object.keys(rows[0]);
    // 确保每行都有 user_id
    if (!columns.includes('user_id')) {
      columns.unshift('user_id');
    }
    const placeholders = columns.map(() => '?').join(', ');
    insertStmt = db.prepare(`INSERT INTO ${table} (${columns.join(', ')}) VALUES (${placeholders})`);

    const transaction = db.transaction(() => {
      deleteStmt.run(userId);
      let count = 0;
      for (const row of rows) {
        const values = columns.map(col => {
          if (col === 'user_id') return userId;
          return row[col] !== undefined ? row[col] : null;
        });
        insertStmt.run(...values);
        count++;
      }
      return count;
    });

    const count = transaction();
    res.json({ uploaded: count });
  } catch (err) {
    console.error(`同步 ${table} 失败:`, err.message);
    res.status(500).json({ error: `同步失败: ${err.message}` });
  }
});

// 下载同步数据
app.get('/api/sync/:table', authMiddleware, (req, res) => {
  const { table } = req.params;

  if (!SYNC_TABLES.includes(table)) {
    return res.status(400).json({ error: '无效的数据表' });
  }

  try {
    const rows = db.prepare(`SELECT * FROM ${table} WHERE user_id = ?`).all(req.userId);
    res.json({ rows });
  } catch (err) {
    console.error(`获取 ${table} 失败:`, err.message);
    res.status(500).json({ error: `获取失败: ${err.message}` });
  }
});

// ============================================================
// 管理员 API（供 ToolApp Admin 桌面端使用）
// ============================================================
// 管理员密码（默认 666666，可通过 API 修改）
let adminPassword = process.env.ADMIN_PASSWORD || '666666';

// 管理员认证中间件
function adminMiddleware(req, res, next) {
  const password = req.headers['x-admin-password'];
  if (!password || password !== adminPassword) {
    return res.status(403).json({ error: '管理员密码错误' });
  }
  next();
}

// 修改管理员密码
app.post('/api/admin/change-password', adminMiddleware, (req, res) => {
  const { newPassword } = req.body || {};
  if (!newPassword || newPassword.length < 4) {
    return res.status(400).json({ error: '密码长度至少4位' });
  }
  adminPassword = newPassword;
  res.json({ success: true, message: '密码修改成功' });
});

// 获取用户在线状态（用于在线监控页面）
app.get('/api/admin/users/online-status', adminMiddleware, (req, res) => {
  const now = Date.now();
  const ONLINE_THRESHOLD = 5 * 60 * 1000; // 5分钟内心跳视为在线

  try {
    // 获取所有用户及其最新会话信息
    const users = db.prepare('SELECT id, email, created_at FROM users ORDER BY id').all();

    const result = users.map(user => {
      // 获取用户最新会话
      const latestSession = db.prepare(`
        SELECT * FROM user_sessions
        WHERE user_id = ?
        ORDER BY id DESC
        LIMIT 1
      `).get(user.id);

      // 计算用户今日使用时长
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const todayStart = today.toISOString();

      const todayStats = db.prepare(`
        SELECT COALESCE(SUM(
          CASE
            WHEN session_end IS NOT NULL THEN duration_seconds
            ELSE CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER)
          END
        ), 0) as total_seconds
        FROM user_sessions
        WHERE user_id = ? AND session_start >= ?
      `).get(user.id, todayStart);

      // 计算总使用时长
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

      // 计算会话次数
      const sessionCount = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(user.id).count;

      // 判断是否在线
      let isOnline = false;
      let lastSeen = null;
      let currentSessionStart = null;

      if (latestSession) {
        const lastHeartbeat = latestSession.last_heartbeat ? new Date(latestSession.last_heartbeat).getTime() : 0;
        // 判断在线：is_online=1 且有有效心跳且心跳在5分钟内
        isOnline = latestSession.is_online === 1
          && latestSession.last_heartbeat
          && (now - lastHeartbeat) < ONLINE_THRESHOLD;
        lastSeen = latestSession.last_heartbeat;
        currentSessionStart = latestSession.session_start;
      }

      return {
        ...user,
        isOnline,
        lastSeen,
        currentSessionStart,
        todayUsageSeconds: todayStats.total_seconds,
        totalUsageSeconds: totalStats.total_seconds,
        sessionCount,
        deviceInfo: latestSession ? latestSession.device_info : null,
        ipAddress: latestSession ? latestSession.ip_address : null,
      };
    });

    // 按在线状态排序（在线用户在前）
    result.sort((a, b) => (b.isOnline ? 1 : 0) - (a.isOnline ? 1 : 0));

    const onlineCount = result.filter(u => u.isOnline).length;
    const totalCount = result.length;

    res.json({
      users: result,
      onlineCount,
      totalCount,
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 获取用户会话历史
app.get('/api/admin/users/:id/sessions', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  const { page = 1, pageSize = 20 } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(userId).count;
    const sessions = db.prepare(`
      SELECT * FROM user_sessions
      WHERE user_id = ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    `).all(userId, Number(pageSize), Number(offset));

    res.json({ rows: sessions, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 获取用户活动日志
app.get('/api/admin/users/:id/activity', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  const { page = 1, pageSize = 50 } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_activity_logs WHERE user_id = ?').get(userId).count;
    const logs = db.prepare(`
      SELECT * FROM user_activity_logs
      WHERE user_id = ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    `).all(userId, Number(pageSize), Number(offset));

    res.json({ rows: logs, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 获取系统信息（用于设置页面）
app.get('/api/admin/system-info', adminMiddleware, (req, res) => {
  const os = require('os');
  const path = require('path');

  try {
    const q = (sql) => db.prepare(sql).get().count;
    const ips = [];
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
      for (const iface of interfaces[name]) {
        if (iface.family === 'IPv4' && !iface.internal) {
          ips.push(iface.address);
        }
      }
    }

    res.json({
      server: {
        port: PORT,
        uptime: process.uptime(),
        platform: os.platform(),
        hostname: os.hostname(),
        ips,
        memory: {
          total: os.totalmem(),
          free: os.freemem(),
        },
        nodeVersion: process.version,
      },
      database: {
        path: DB_PATH,
        size: (() => {
          let s = 0;
          if (fs.existsSync(DB_PATH)) {
            s += fs.statSync(DB_PATH).size;
            if (fs.existsSync(DB_PATH + '-wal')) s += fs.statSync(DB_PATH + '-wal').size;
            if (fs.existsSync(DB_PATH + '-shm')) s += fs.statSync(DB_PATH + '-shm').size;
          }
          return s;
        })(),
        tables: {
          users: q('SELECT COUNT(*) as count FROM users'),
          heart_rate_sessions: q('SELECT COUNT(*) as count FROM heart_rate_sessions'),
          network_speed_records: q('SELECT COUNT(*) as count FROM network_speed_records'),
          convert_history: q('SELECT COUNT(*) as count FROM convert_history'),
          dice_records: q('SELECT COUNT(*) as count FROM dice_records'),
          period_records: q('SELECT COUNT(*) as count FROM period_records'),
          user_sessions: q('SELECT COUNT(*) as count FROM user_sessions'),
          user_activity_logs: q('SELECT COUNT(*) as count FROM user_activity_logs'),
        },
      },
      adminPassword: adminPassword,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

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

// 用户列表（分页+搜索）
app.get('/api/admin/users', adminMiddleware, (req, res) => {
  const { page = 1, pageSize = 20, search = '' } = req.query;
  const offset = (page - 1) * pageSize;

  let where = '';
  const sp = [];
  if (search) {
    where = 'WHERE email LIKE ?';
    sp.push(`%${search}%`);
  }

  try {
    const total = db.prepare(`SELECT COUNT(*) as count FROM users ${where}`).get(...sp).count;
    const rows = db.prepare(`SELECT id, email, password_hash, created_at FROM users ${where} ORDER BY id LIMIT ? OFFSET ?`).all(...sp, Number(pageSize), Number(offset));

    const usersWithData = rows.map(user => {
      const c = (table) => db.prepare(`SELECT COUNT(*) as count FROM ${table} WHERE user_id = ?`).get(user.id).count;
      return {
        ...user,
        dataCount: {
          heartRate: c('heart_rate_sessions'),
          networkSpeed: c('network_speed_records'),
          convert: c('convert_history'),
          dice: c('dice_records'),
          period: c('period_records'),
        },
      };
    });

    res.json({ rows: usersWithData, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 删除用户及其所有数据
app.delete('/api/admin/users/:id', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  try {
    for (const table of SYNC_TABLES) {
      db.prepare(`DELETE FROM ${table} WHERE user_id = ?`).run(userId);
    }
    db.prepare('DELETE FROM users WHERE id = ?').run(userId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 通用数据表查询（分页+用户筛选）
const ADMIN_TABLES = [...SYNC_TABLES];
app.get('/api/admin/:table', adminMiddleware, (req, res) => {
  const { table } = req.params;
  if (!ADMIN_TABLES.includes(table)) {
    return res.status(400).json({ error: '无效的数据表' });
  }

  const { page = 1, pageSize = 20, userId = '' } = req.query;
  const offset = (page - 1) * pageSize;

  const conditions = [];
  const sp = [];
  if (userId) {
    conditions.push('user_id = ?');
    sp.push(Number(userId));
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  try {
    const total = db.prepare(`SELECT COUNT(*) as count FROM ${table} ${where}`).get(...sp).count;
    const rows = db.prepare(`SELECT * FROM ${table} ${where} ORDER BY id DESC LIMIT ? OFFSET ?`).all(...sp, Number(pageSize), Number(offset));
    res.json({ rows, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 更新记录
app.put('/api/admin/:table/:id', adminMiddleware, (req, res) => {
  const { table, id } = req.params;
  if (!ADMIN_TABLES.includes(table)) {
    return res.status(400).json({ error: '无效的数据表' });
  }

  const data = req.body;
  const cols = Object.keys(data);
  const vals = Object.values(data);
  const setClause = cols.map(c => `${c} = ?`).join(', ');

  try {
    db.prepare(`UPDATE ${table} SET ${setClause} WHERE id = ?`).run(...vals, Number(id));
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 删除记录
app.delete('/api/admin/:table/:id', adminMiddleware, (req, res) => {
  const { table, id } = req.params;
  if (!ADMIN_TABLES.includes(table)) {
    return res.status(400).json({ error: '无效的数据表' });
  }

  try {
    db.prepare(`DELETE FROM ${table} WHERE id = ?`).run(Number(id));
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 健康检查
// ============================================================
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', time: new Date().toISOString() });
});

// ============================================================
// 启动服务器
// ============================================================
const os = require('os');

// 获取本机所有局域网 IP 地址
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const ips = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      // 跳过内部和非 IPv4 地址
      if (iface.family === 'IPv4' && !iface.internal) {
        ips.push(iface.address);
      }
    }
  }
  return ips;
}

app.listen(PORT, '0.0.0.0', () => {
  const ips = getLocalIPs();
  console.log(`========================================`);
  console.log(`  ToolApp 服务器已启动`);
  console.log(`  本机: http://localhost:${PORT}`);
  if (ips.length > 0) {
    ips.forEach(ip => {
      console.log(`  局域网: http://${ip}:${PORT}`);
    });
  } else {
    console.log(`  局域网: 未检测到局域网 IP`);
  }
  console.log(`  数据库: ${DB_PATH}`);
  console.log(`========================================`);
  console.log(`  请在 App 中设置服务器地址为上面的局域网地址`);
  console.log(`========================================`);

  // 定期清理过期会话：每分钟检查一次，将超过10分钟没有心跳的会话标记为离线
  setInterval(() => {
    try {
      const result = db.prepare(`
        UPDATE user_sessions
        SET is_online = 0,
            session_end = datetime('now'),
            duration_seconds = CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER)
        WHERE is_online = 1
          AND last_heartbeat IS NOT NULL
          AND julianday('now') - julianday(last_heartbeat) > 0.007
      `).run();
      if (result.changes > 0) {
        console.log(`[会话清理] 已将 ${result.changes} 个过期会话标记为离线`);
      }
    } catch (err) {
      // 忽略清理错误
    }
  }, 60 * 1000);
});
