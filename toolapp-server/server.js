// ToolApp 轻量认证与数据同步服务器
// 技术栈：Express + better-sqlite3 + JWT
// 无需 Docker，直接在 Windows 上运行：npm install && npm start
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const path = require('path');
const nodemailer = require('nodemailer');
const axios = require('axios');
const cheerio = require('cheerio');
const { spawn } = require('child_process');

// ============================================================
// 配置
// ============================================================
const PORT = parseInt(process.env.PORT || '3000');
// JWT密钥：优先使用环境变量，否则使用固定密钥（生产环境务必设置环境变量）
const JWT_SECRET = process.env.JWT_SECRET || 'toolapp-secret-key-change-in-production';
const JWT_EXPIRES_IN = '7d';
const DB_PATH = path.join(__dirname, 'data', 'toolapp.db');

// 邮箱验证码配置（优先使用环境变量，否则使用默认QQ邮箱）
const EMAIL_USER = process.env.EMAIL_USER || '3456975755@qq.com';
const EMAIL_PASS = process.env.EMAIL_PASS || 'gskzusfokbjldahh';
const EMAIL_HOST = process.env.EMAIL_HOST || 'smtp.qq.com';
const EMAIL_PORT = parseInt(process.env.EMAIL_PORT || '465');

// 创建邮件发送器（QQ邮箱 SMTP）
let mailTransporter = null;
try {
  mailTransporter = nodemailer.createTransport({
    host: EMAIL_HOST,
    port: EMAIL_PORT,
    secure: true,
    auth: {
      user: EMAIL_USER,
      pass: EMAIL_PASS,
    },
    connectionTimeout: 10000,
    greetingTimeout: 5000,
    socketTimeout: 15000,
  });
  console.log('邮箱服务已配置: ' + EMAIL_USER);
} catch (e) {
  console.warn('邮箱服务配置失败: ' + e.message);
}

// ============================================================
// 数据库初始化
// ============================================================
const fs = require('fs');
const dataDir = path.join(__dirname, 'data');
if (!fs.existsSync(dataDir)) {
  fs.mkdirSync(dataDir, { recursive: true });
}

const Database = require('better-sqlite3');
const db = new Database(DB_PATH);

db.pragma('journal_mode = WAL');

// 迁移：为已存在的users表添加is_deleted字段
try {
  db.exec(`ALTER TABLE users ADD COLUMN is_deleted INTEGER DEFAULT 0`);
  console.log('数据库迁移：已添加 is_deleted 字段');
} catch (e) {
  // 字段已存在，忽略错误
}

// 通用表字段迁移辅助函数（v1.51.2+）
// 安全地为已存在的表添加新列，如果列已存在则忽略
function _migrateTableColumn(tableName, columnName, columnType = 'TEXT') {
  try {
    db.exec(`ALTER TABLE ${tableName} ADD COLUMN ${columnName} ${columnType}`);
    console.log(`数据库迁移：${tableName} 表已添加 ${columnName} 字段`);
  } catch (e) {
    // 字段已存在，忽略错误
  }
}

// 创建用户表
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    is_deleted INTEGER DEFAULT 0,
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

  -- 用户活动日志表
  CREATE TABLE IF NOT EXISTS user_activity_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    activity_type TEXT,
    page_name TEXT,
    details TEXT,
    timestamp TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- 邮箱验证码表 - 用于注册时验证邮箱真实性
  CREATE TABLE IF NOT EXISTS email_verification_codes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    code TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL,
    is_used INTEGER DEFAULT 0
  );

  -- 设备令牌表 - 用于顶号机制，记录每个用户当前登录的设备
  CREATE TABLE IF NOT EXISTS device_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    device_token TEXT NOT NULL,
    device_info TEXT,
    login_time TEXT DEFAULT (datetime('now')),
    last_active TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- 用户设备参数表 - 记录用户设备详细参数，供优化参考
  CREATE TABLE IF NOT EXISTS user_device_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    device_token TEXT,
    platform TEXT,
    model TEXT,
    brand TEXT,
    os_version TEXT,
    sdk_version INTEGER,
    screen_width INTEGER,
    screen_height INTEGER,
    total_memory INTEGER,
    total_storage INTEGER,
    cpu_arch TEXT,
    cpu_cores INTEGER,
    is_physical_device INTEGER,
    app_version TEXT,
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- 应用版本表 - 用于App检查更新和版本管理
  CREATE TABLE IF NOT EXISTS app_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    version TEXT NOT NULL,
    build_number INTEGER NOT NULL,
    download_url TEXT NOT NULL,
    file_size INTEGER DEFAULT 0,
    update_notes TEXT DEFAULT '',
    force_update INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now'))
  );

  -- 用户反馈表 - 记录App用户提交的意见建议和反馈信息
  CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    user_email TEXT,
    content TEXT NOT NULL,
    contact TEXT,
    device_info TEXT,
    created_at TEXT DEFAULT (datetime('now'))
  );

  -- v1.35.0+ 设备编解码器信息表 - 记录App端编解码器检测结果
  CREATE TABLE IF NOT EXISTS device_codec_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    device_token TEXT,
    platform TEXT,
    model TEXT,
    brand TEXT,
    os_version TEXT,
    app_version TEXT,
    supports_hardware_encoding INTEGER DEFAULT 0,
    supports_ultrafast INTEGER DEFAULT 0,
    cpu_hardware_name TEXT,
    cpu_cores INTEGER,
    cpu_max_freq_mhz INTEGER,
    detected_at TEXT DEFAULT (datetime('now')),
    synced_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  -- v1.35.0+ 指纹数据表 - 记录设备指纹硬件检测数据（个人学习研究用）
  CREATE TABLE IF NOT EXISTS fingerprint_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    device_token TEXT,
    platform TEXT,
    model TEXT,
    brand TEXT,
    os_version TEXT,
    app_version TEXT,
    has_fingerprint_hardware INTEGER DEFAULT 0,
    has_enrolled_fingerprints INTEGER DEFAULT 0,
    sensor_type TEXT,
    enrolled_count INTEGER DEFAULT 0,
    sdk_version INTEGER,
    build_fingerprint TEXT,
    board TEXT,
    bootloader TEXT,
    device TEXT,
    display TEXT,
    hardware TEXT,
    product TEXT,
    is_keyguard_secure INTEGER,
    is_device_secure INTEGER,
    verify_attempt_count INTEGER DEFAULT 0,
    verify_success_count INTEGER DEFAULT 0,
    verify_failure_count INTEGER DEFAULT 0,
    verify_history TEXT,
    captured_data TEXT,
    detected_at TEXT DEFAULT (datetime('now')),
    synced_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );
`);

// ============================================================
// Express 应用
// ============================================================
const app = express();

app.use(cors());
app.use(express.json({ limit: '50mb' }));

// APK文件静态下载路由（必须在认证中间件之前，允许匿名下载）

const DOWNLOADS_DIR = path.join(__dirname, 'downloads');
// 确保downloads目录存在
if (!fs.existsSync(DOWNLOADS_DIR)) {
  fs.mkdirSync(DOWNLOADS_DIR, { recursive: true });
}
app.use('/downloads', express.static(DOWNLOADS_DIR));

// 官网静态文件托管
// 支持两种访问方式：
//   1. /website/styles.css （带前缀）
//   2. /styles.css （直接根路径，配合 index.html 的相对路径引用）
const WEBSITE_DIR = path.join(__dirname, 'website');
if (!fs.existsSync(WEBSITE_DIR)) {
  try {
    fs.mkdirSync(WEBSITE_DIR, { recursive: true });
  } catch (_) {}
}
app.use('/website', express.static(WEBSITE_DIR));

// 根路径：优先返回官网首页（index.html）
app.get('/', (req, res) => {
  const indexFile = path.join(WEBSITE_DIR, 'index.html');
  if (fs.existsSync(indexFile)) {
    res.sendFile(indexFile);
  } else {
    res.status(200).send('ToolApp 服务器已启动 ✅ <a href="/downloads/">下载 APK</a>');
  }
});

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
    // 检查用户是否已被软删除
    const user = db.prepare('SELECT id, is_deleted FROM users WHERE id = ?').get(decoded.userId);
    if (!user || user.is_deleted) {
      return res.status(401).json({ error: '账号已被注销，请重新注册' });
    }
    req.userId = decoded.userId;
    req.email = decoded.email;
    next();
  } catch (err) {
    return res.status(401).json({ error: '认证令牌无效或已过期' });
  }
}

// ============================================================
// 工具函数
// ============================================================

// 生成6位数字验证码
function generateVerificationCode() {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

// 发送邮件验证码（含超时保护，防止SMTP错误阻塞API）
async function sendVerificationEmail(email, code) {
  if (!mailTransporter) {
    console.warn('邮件发送器未配置，验证码已生成但未发送');
    return false;
  }

  // 带超时的发送逻辑（双重超时保护：nodemailer内部超时 + Promise外层超时）
  const sendWithTimeout = new Promise((resolve) => {
    const timeoutId = setTimeout(() => {
      console.warn(`发送邮件超时 (${email})，跳过邮件发送`);
      resolve(false);
    }, 8000); // 8秒硬性超时

    mailTransporter.sendMail({
      from: `"ToolApp" <${EMAIL_USER}>`,
      to: email,
      subject: 'ToolApp 注册验证码',
      html: `
        <h2>ToolApp 注册验证码</h2>
        <p>您的验证码是：<strong style="font-size: 24px; color: #1890ff;">${code}</strong></p>
        <p>验证码有效期为 10 分钟，请勿泄露给他人。</p>
        <p>如果这不是您的操作，请忽略此邮件。</p>
      `,
    }).then(() => {
      clearTimeout(timeoutId);
      console.log(`验证码邮件已发送到 ${email}`);
      resolve(true);
    }).catch((err) => {
      clearTimeout(timeoutId);
      console.error(`发送邮件失败到 ${email}: ${err.message}`);
      resolve(false);
    });
  });

  return sendWithTimeout;
}

// ============================================================
// 邮箱验证码接口
// ============================================================

// 发送验证码到邮箱
app.post('/api/auth/send-code', async (req, res) => {
  const { email } = req.body;

  if (!email) {
    return res.status(400).json({ error: '邮箱不能为空' });
  }

  // 检查邮箱格式
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(email)) {
    return res.status(400).json({ error: '邮箱格式不正确' });
  }

  // 频率限制：同一邮箱60秒内只能发送一次验证码
  const recentCode = db.prepare(
    "SELECT created_at FROM email_verification_codes WHERE email = ? ORDER BY id DESC LIMIT 1"
  ).get(email);
  if (recentCode && recentCode.created_at) {
    const lastSent = new Date(recentCode.created_at).getTime();
    const elapsed = Date.now() - lastSent;
    if (elapsed < 60000) {
      const waitSeconds = Math.ceil((60000 - elapsed) / 1000);
      return res.status(429).json({ error: `请${waitSeconds}秒后再试` });
    }
  }

  // 检查邮箱是否已注册（已注销账号允许重新注册）
  const existing = db.prepare('SELECT id, is_deleted FROM users WHERE email = ?').get(email);
  if (existing && !existing.is_deleted) {
    return res.status(400).json({ error: '该邮箱已被注册，请直接登录' });
  }

  // 生成验证码
  const code = generateVerificationCode();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 10 * 60 * 1000); // 10分钟有效

  // 删除该邮箱旧的未使用验证码
  db.prepare('DELETE FROM email_verification_codes WHERE email = ? AND is_used = 0').run(email);

  // 保存验证码
  db.prepare(
    'INSERT INTO email_verification_codes (email, code, expires_at) VALUES (?, ?, ?)'
  ).run(email, code, expiresAt.toISOString());

  // 发送邮件
  const sent = await sendVerificationEmail(email, code);

  // 邮件发送失败时，删除已保存的验证码记录并返回错误
  if (!sent) {
    db.prepare('DELETE FROM email_verification_codes WHERE email = ? AND code = ? AND is_used = 0').run(email, code);
    return res.status(500).json({ error: '验证码已生成，但邮件发送失败，请稍后重试' });
  }

  res.json({ success: true, message: '验证码已发送到您的邮箱' });
});

// 验证邮箱验证码
app.post('/api/auth/verify-code', (req, res) => {
  const { email, code } = req.body;

  if (!email || !code) {
    return res.status(400).json({ error: '邮箱和验证码不能为空' });
  }

  // 查找未过期的验证码（使用单引号，SQLite要求字符串字面量用单引号）
  const record = db.prepare(
    "SELECT * FROM email_verification_codes WHERE email = ? AND code = ? AND is_used = 0 AND expires_at > datetime('now') ORDER BY id DESC LIMIT 1"
  ).get(email, code);

  if (!record) {
    return res.status(400).json({ error: '验证码无效或已过期' });
  }

  // 标记为已使用
  db.prepare('UPDATE email_verification_codes SET is_used = 1 WHERE id = ?').run(record.id);

  res.json({ success: true, message: '验证通过' });
});

// ============================================================
// 认证接口
// ============================================================

// 注册（需要验证码）
app.post('/api/auth/register', (req, res) => {
  const { email, password, verificationCode } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: '邮箱和密码不能为空' });
  }

  if (password.length < 6) {
    return res.status(400).json({ error: '密码至少需要6位' });
  }

  // 检查邮箱是否已注册（已注销账号允许重新注册）
  const existing = db.prepare('SELECT id, is_deleted FROM users WHERE email = ?').get(email);
  if (existing && !existing.is_deleted) {
    return res.status(400).json({ error: '该邮箱已被注册，请直接登录' });
  }

  // 验证码验证（邮箱服务已配置，验证码必填）
  if (!verificationCode) {
    return res.status(400).json({ error: '请提供邮箱验证码' });
  }

  if (verificationCode) {
    const codeRecord = db.prepare(
      "SELECT * FROM email_verification_codes WHERE email = ? AND code = ? AND is_used = 0 AND expires_at > datetime('now') ORDER BY id DESC LIMIT 1"
    ).get(email, verificationCode);

    if (!codeRecord) {
      return res.status(400).json({ error: '验证码无效或已过期' });
    }

    // 标记验证码为已使用
    db.prepare('UPDATE email_verification_codes SET is_used = 1 WHERE id = ?').run(codeRecord.id);
  }

  // 加密密码并插入
  const passwordHash = bcrypt.hashSync(password, 10);

  let userId;
  // 如果是已注销账号重新注册，更新原账号
  if (existing && existing.is_deleted) {
    db.prepare('UPDATE users SET password_hash = ?, is_deleted = 0 WHERE id = ?').run(passwordHash, existing.id);
    userId = existing.id;
  } else {
    const result = db.prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)').run(email, passwordHash);
    userId = result.lastInsertRowid;
  }

  // 生成 JWT
  const token = jwt.sign({ userId: userId, email }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

  res.status(201).json({
    user: { id: userId, email },
    token,
  });
});

// 登录（带顶号机制）
app.post('/api/auth/login', (req, res) => {
  const { email, password, deviceToken } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: '邮箱和密码不能为空' });
  }

  // 查找用户（排除已注销的）
  const user = db.prepare('SELECT id, email, password_hash, is_deleted FROM users WHERE email = ?').get(email);
  if (!user || user.is_deleted) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  // 验证密码
  if (!bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: '邮箱或密码错误' });
  }

  // 顶号机制：新设备登录时，删除该用户的所有旧设备记录
  if (deviceToken) {
    // 删除该用户的所有旧设备令牌记录
    db.prepare(
      'DELETE FROM device_tokens WHERE user_id = ? AND device_token != ?'
    ).run(user.id, deviceToken);

    // 插入或更新当前设备的令牌记录
    const existing = db.prepare(
      'SELECT id FROM device_tokens WHERE user_id = ? AND device_token = ?'
    ).get(user.id, deviceToken);

    if (existing) {
      db.prepare(
        'UPDATE device_tokens SET last_active = datetime(\'now\'), device_info = ? WHERE id = ?'
      ).run(req.body.deviceInfo || '', existing.id);
    } else {
      db.prepare(
        'INSERT INTO device_tokens (user_id, device_token, device_info) VALUES (?, ?, ?)'
      ).run(user.id, deviceToken, req.body.deviceInfo || '');
    }
  }

  // 生成 JWT
  const token = jwt.sign({ userId: user.id, email: user.email }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

  res.json({
    user: { id: user.id, email: user.email },
    token,
  });
});

// 检查当前设备是否被踢出
app.get('/api/auth/check-kicked', authMiddleware, (req, res) => {
  const { deviceToken } = req.query;

  if (!deviceToken) {
    return res.json({ kicked: false });
  }

  // 检查该用户的最新设备令牌是否是当前设备
  const latestDevice = db.prepare(
    'SELECT device_token FROM device_tokens WHERE user_id = ? ORDER BY last_active DESC LIMIT 1'
  ).get(req.userId);

  const kicked = latestDevice && latestDevice.device_token !== deviceToken;

  res.json({ kicked, message: kicked ? '您的账号已在其他设备登录' : null });
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
// 忘记密码：通过邮箱验证码重置密码
// ============================================================
app.post('/api/auth/reset-password', (req, res) => {
  const { email, verificationCode, newPassword } = req.body;

  if (!email || !verificationCode || !newPassword) {
    return res.status(400).json({ error: '邮箱、验证码和新密码不能为空' });
  }

  if (newPassword.length < 6) {
    return res.status(400).json({ error: '密码至少需要6位' });
  }

  // 检查用户是否存在
  const user = db.prepare('SELECT id, email, is_deleted FROM users WHERE email = ?').get(email);
  if (!user || user.is_deleted) {
    return res.status(404).json({ error: '该邮箱未注册' });
  }

  // 检查邮箱服务是否已配置
  if (!mailTransporter) {
    return res.status(503).json({ error: '邮箱服务未配置，请联系管理员重置密码' });
  }

  // 验证验证码
  const codeRecord = db.prepare(
    "SELECT * FROM email_verification_codes WHERE email = ? AND code = ? AND is_used = 0 AND expires_at > datetime('now') ORDER BY created_at DESC LIMIT 1"
  ).get(email, verificationCode);

  if (!codeRecord) {
    return res.status(400).json({ error: '验证码无效或已过期' });
  }

  // 标记验证码为已使用
  db.prepare('UPDATE email_verification_codes SET is_used = 1 WHERE id = ?').run(codeRecord.id);

  // 更新密码
  const passwordHash = bcrypt.hashSync(newPassword, 10);
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(passwordHash, user.id);

  // 清除该用户所有设备的登录令牌（强制所有设备重新登录）
  db.prepare('DELETE FROM device_tokens WHERE user_id = ?').run(user.id);

  res.json({ success: true, message: '密码重置成功，请使用新密码登录' });
});

// ============================================================
// 查询当前账号登录过的设备列表
// ============================================================
app.get('/api/auth/devices', authMiddleware, (req, res) => {
  try {
    const devices = db.prepare(
      'SELECT id, device_token, device_info, last_active FROM device_tokens WHERE user_id = ? ORDER BY last_active DESC'
    ).all(req.userId);

    // 标记当前设备
    const currentDeviceToken = req.query.deviceToken;
    const result = devices.map(d => ({
      ...d,
      isCurrentDevice: d.device_token === currentDeviceToken,
    }));

    res.json({ devices: result });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 踢出指定设备（顶号操作）
// ============================================================
app.delete('/api/auth/devices/:deviceToken', authMiddleware, (req, res) => {
  const { deviceToken } = req.params;

  // 不允许踢出自己
  if (deviceToken === req.query.currentDeviceToken) {
    return res.status(400).json({ error: '不能踢出当前设备' });
  }

  try {
    const result = db.prepare(
      'DELETE FROM device_tokens WHERE user_id = ? AND device_token = ?'
    ).run(req.userId, deviceToken);

    if (result.changes === 0) {
      return res.status(404).json({ error: '设备不存在' });
    }

    res.json({ success: true, message: '已踢出该设备' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员查询用户登录设备列表
// ============================================================
app.get('/api/admin/users/:id/devices', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);

  try {
    const devices = db.prepare(
      'SELECT id, device_token, device_info, last_active FROM device_tokens WHERE user_id = ? ORDER BY last_active DESC'
    ).all(userId);

    res.json({ devices });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员踢出用户指定设备
// ============================================================
app.delete('/api/admin/users/:id/devices/:deviceToken', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  const { deviceToken } = req.params;

  try {
    const result = db.prepare(
      'DELETE FROM device_tokens WHERE user_id = ? AND device_token = ?'
    ).run(userId, deviceToken);

    if (result.changes === 0) {
      return res.status(404).json({ error: '设备不存在' });
    }

    res.json({ success: true, message: '已踢出该设备' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 用户修改自己的密码
// ============================================================
app.post('/api/auth/change-password', authMiddleware, (req, res) => {
  const { oldPassword, newPassword } = req.body;

  if (!oldPassword || !newPassword) {
    return res.status(400).json({ error: '旧密码和新密码不能为空' });
  }

  if (newPassword.length < 6) {
    return res.status(400).json({ error: '新密码至少需要6位' });
  }

  const user = db.prepare('SELECT id, password_hash FROM users WHERE id = ?').get(req.userId);
  if (!user) {
    return res.status(404).json({ error: '用户不存在' });
  }

  // 验证旧密码
  if (!bcrypt.compareSync(oldPassword, user.password_hash)) {
    return res.status(400).json({ error: '旧密码不正确' });
  }

  // 更新密码
  const passwordHash = bcrypt.hashSync(newPassword, 10);
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(passwordHash, user.id);

  res.json({ success: true, message: '密码修改成功' });
});

// ============================================================
// App检查更新接口（公开接口，无需认证）
// ============================================================
app.get('/api/app/version/check', (req, res) => {
  const platform = req.query.platform || 'android';
  const buildNumber = parseInt(req.query.buildNumber) || 0;

  try {
    // 查询最新版本（按build_number降序取第一条）
    const latest = db.prepare(
      'SELECT * FROM app_versions ORDER BY build_number DESC LIMIT 1'
    ).get();

    if (!latest) {
      return res.json({ hasUpdate: false, message: '暂无版本信息' });
    }

    if (latest.build_number <= buildNumber) {
      return res.json({ hasUpdate: false, message: '已是最新版本' });
    }

    // 有新版本
    res.json({
      hasUpdate: true,
      version: latest.version,
      buildNumber: latest.build_number,
      downloadUrl: latest.download_url,
      fileSize: latest.file_size,
      updateNotes: latest.update_notes,
      forceUpdate: latest.force_update === 1,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 健康检查接口（用于流量网络测试连接）
// ============================================================
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ============================================================
// 数据同步接口
// ============================================================

const SYNC_TABLES = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];

// ============================================================
// 用户会话与活动API
// ============================================================

app.post('/api/session/start', authMiddleware, (req, res) => {
  const userId = req.userId;
  const { deviceInfo } = req.body || {};
  const ipAddress = req.headers['x-forwarded-for'] || req.ip || '';
  const now = new Date().toISOString();

  try {
    db.prepare('UPDATE user_sessions SET is_online = 0, session_end = ? WHERE user_id = ? AND is_online = 1').run(now, userId);

    const result = db.prepare(`
      INSERT INTO user_sessions (user_id, session_start, device_info, ip_address, last_heartbeat, is_online)
      VALUES (?, ?, ?, ?, ?, 1)
    `).run(userId, now, deviceInfo || '', ipAddress, now);

    res.json({ sessionId: result.lastInsertRowid, startTime: now });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/session/heartbeat', authMiddleware, (req, res) => {
  const userId = req.userId;
  const { sessionId } = req.body || {};
  const now = new Date().toISOString();

  try {
    if (sessionId) {
      // 仅更新存在的且未结束的session
      db.prepare('UPDATE user_sessions SET last_heartbeat = ?, is_online = 1 WHERE id = ? AND user_id = ? AND session_end IS NULL').run(now, sessionId, userId);
    } else {
      // 仅更新未结束的session
      db.prepare('UPDATE user_sessions SET last_heartbeat = ?, is_online = 1 WHERE user_id = ? AND is_online = 1 AND session_end IS NULL').run(now, userId);
    }
    res.json({ received: true, timestamp: now });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/session/end', authMiddleware, (req, res) => {
  const userId = req.userId;
  const now = new Date().toISOString();

  try {
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

// 用户端上传设备参数（登录后调用，记录设备详细信息供优化参考）
app.post('/api/device-info', authMiddleware, (req, res) => {
  const userId = req.userId;
  const {
    deviceToken, platform, model, brand, deviceName, manufacturer, osVersion, sdkVersion,
    screenWidth, screenHeight, screenInches, totalMemory, totalStorage,
    cpuArch, cpuCores, isPhysicalDevice, appVersion
  } = req.body || {};
  const now = new Date().toISOString();

  try {
    // 检查用户是否已有设备记录，有则更新，无则插入
    const existing = db.prepare('SELECT id FROM user_device_info WHERE user_id = ?').get(userId);

    // 检查表结构是否需要迁移（v1.51.2+ 增加 device_name/manufacturer/screen_inches）
    _migrateTableColumn('user_device_info', 'device_name');
    _migrateTableColumn('user_device_info', 'manufacturer');
    _migrateTableColumn('user_device_info', 'screen_inches');

    if (existing) {
      db.prepare(`
        UPDATE user_device_info SET
          device_token = ?, platform = ?, model = ?, brand = ?,
          device_name = ?, manufacturer = ?,
          os_version = ?, sdk_version = ?, screen_width = ?, screen_height = ?,
          screen_inches = ?,
          total_memory = ?, total_storage = ?, cpu_arch = ?, cpu_cores = ?,
          is_physical_device = ?, app_version = ?, updated_at = ?
        WHERE user_id = ?
      `).run(
        deviceToken || '', platform || '', model || '', brand || '',
        deviceName || '', manufacturer || '',
        osVersion || '', sdkVersion || null, screenWidth || null, screenHeight || null,
        screenInches || null,
        totalMemory || null, totalStorage || null, cpuArch || '', cpuCores || null,
        isPhysicalDevice ? 1 : 0, appVersion || '', now, userId
      );
      res.json({ success: true, action: 'updated', message: '设备参数更新成功' });
    } else {
      db.prepare(`
        INSERT INTO user_device_info (
          user_id, device_token, platform, model, brand,
          device_name, manufacturer,
          os_version, sdk_version, screen_width, screen_height,
          screen_inches,
          total_memory, total_storage, cpu_arch, cpu_cores,
          is_physical_device, app_version, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        userId, deviceToken || '', platform || '', model || '', brand || '',
        deviceName || '', manufacturer || '',
        osVersion || '', sdkVersion || null, screenWidth || null, screenHeight || null,
        screenInches || null,
        totalMemory || null, totalStorage || null, cpuArch || '', cpuCores || null,
        isPhysicalDevice ? 1 : 0, appVersion || '', now
      );
      res.json({ success: true, action: 'created', message: '设备参数记录成功' });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// v1.35.0+ 设备编解码器信息同步 - 接收App端编解码器检测数据
app.post('/api/device-codec-info', authMiddleware, (req, res) => {
  const userId = req.userId;
  const {
    deviceToken, platform, model, brand, osVersion, appVersion,
    supportsHardwareEncoding, supportsUltrafast,
    cpuHardwareName, cpuCores, cpuMaxFreqMhz, detectedAt
  } = req.body || {};
  const now = detectedAt || new Date().toISOString();

  try {
    const existing = db.prepare('SELECT id FROM device_codec_info WHERE user_id = ?').get(userId);

    if (existing) {
      db.prepare(`
        UPDATE device_codec_info SET
          device_token = ?, platform = ?, model = ?, brand = ?,
          os_version = ?, app_version = ?,
          supports_hardware_encoding = ?, supports_ultrafast = ?,
          cpu_hardware_name = ?, cpu_cores = ?, cpu_max_freq_mhz = ?,
          detected_at = ?, synced_at = ?
        WHERE user_id = ?
      `).run(
        deviceToken || '', platform || '', model || '', brand || '',
        osVersion || '', appVersion || '',
        supportsHardwareEncoding ? 1 : 0, supportsUltrafast ? 1 : 0,
        cpuHardwareName || '', cpuCores || null, cpuMaxFreqMhz || null,
        detectedAt || now, now, userId
      );
    } else {
      db.prepare(`
        INSERT INTO device_codec_info (
          user_id, device_token, platform, model, brand,
          os_version, app_version, supports_hardware_encoding, supports_ultrafast,
          cpu_hardware_name, cpu_cores, cpu_max_freq_mhz, detected_at, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        userId, deviceToken || '', platform || '', model || '', brand || '',
        osVersion || '', appVersion || '',
        supportsHardwareEncoding ? 1 : 0, supportsUltrafast ? 1 : 0,
        cpuHardwareName || '', cpuCores || null, cpuMaxFreqMhz || null,
        detectedAt || now, now
      );
    }
    res.json({ success: true, message: '编解码器信息同步成功' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// v1.35.0+ 指纹数据同步 - 接收App端指纹检测数据（个人学习研究用）
app.post('/api/fingerprint-data', authMiddleware, (req, res) => {
  const userId = req.userId;
  const {
    deviceToken, platform, model, brand, osVersion, appVersion,
    fingerprint, capturedData, verifyHistory,
    attemptCount, successCount, failureCount, syncedAt
  } = req.body || {};
  const now = syncedAt || new Date().toISOString();

  try {
    const fp = fingerprint || {};
    const existing = db.prepare('SELECT id FROM fingerprint_data WHERE user_id = ?').get(userId);

    if (existing) {
      db.prepare(`
        UPDATE fingerprint_data SET
          device_token = ?, platform = ?, model = ?, brand = ?,
          os_version = ?, app_version = ?,
          has_fingerprint_hardware = ?, has_enrolled_fingerprints = ?,
          sensor_type = ?, enrolled_count = ?, sdk_version = ?,
          build_fingerprint = ?, board = ?, bootloader = ?,
          device = ?, display = ?, hardware = ?, product = ?,
          is_keyguard_secure = ?, is_device_secure = ?,
          verify_attempt_count = ?, verify_success_count = ?, verify_failure_count = ?,
          verify_history = ?, captured_data = ?, synced_at = ?
        WHERE user_id = ?
      `).run(
        deviceToken || '', platform || '', model || '', brand || '',
        osVersion || '', appVersion || '',
        fp.hasHardware ? 1 : 0, fp.hasEnrolledFingerprints ? 1 : 0,
        fp.sensorType || '', fp.enrolledCount || 0, fp.sdkVersion || null,
        fp.deviceFingerprint || '', fp.board || '', fp.bootloader || '',
        fp.device || '', fp.display || '', fp.hardware || '', fp.product || '',
        fp.isKeyguardSecure ? 1 : 0, fp.isDeviceSecure ? 1 : 0,
        attemptCount || 0, successCount || 0, failureCount || 0,
        verifyHistory ? JSON.stringify(verifyHistory) : null,
        capturedData ? JSON.stringify(capturedData) : null,
        now, userId
      );
    } else {
      db.prepare(`
        INSERT INTO fingerprint_data (
          user_id, device_token, platform, model, brand,
          os_version, app_version,
          has_fingerprint_hardware, has_enrolled_fingerprints,
          sensor_type, enrolled_count, sdk_version,
          build_fingerprint, board, bootloader,
          device, display, hardware, product,
          is_keyguard_secure, is_device_secure,
          verify_attempt_count, verify_success_count, verify_failure_count,
          verify_history, captured_data, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        userId, deviceToken || '', platform || '', model || '', brand || '',
        osVersion || '', appVersion || '',
        fp.hasHardware ? 1 : 0, fp.hasEnrolledFingerprints ? 1 : 0,
        fp.sensorType || '', fp.enrolledCount || 0, fp.sdkVersion || null,
        fp.deviceFingerprint || '', fp.board || '', fp.bootloader || '',
        fp.device || '', fp.display || '', fp.hardware || '', fp.product || '',
        fp.isKeyguardSecure ? 1 : 0, fp.isDeviceSecure ? 1 : 0,
        attemptCount || 0, successCount || 0, failureCount || 0,
        verifyHistory ? JSON.stringify(verifyHistory) : null,
        capturedData ? JSON.stringify(capturedData) : null,
        now
      );
    }
    res.json({ success: true, message: '指纹数据同步成功' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

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

  // 各表允许的列名白名单（防止SQL注入）
  const TABLE_COLUMNS = {
    'heart_rate_sessions': ['user_id', 'start_time', 'end_time', 'max_hr', 'min_hr', 'avg_hr', 'samples', 'connection_mode'],
    'network_speed_records': ['user_id', 'test_time', 'server_url', 'min_latency', 'avg_latency', 'max_latency', 'jitter', 'loss_rate'],
    'convert_history': ['user_id', 'input_file', 'output_file', 'output_size', 'format', 'quality', 'status', 'timestamp_ms'],
    'dice_records': ['user_id', 'dice_type', 'result', 'timestamp_ms'],
    'period_records': ['user_id', 'start_date', 'end_date', 'record_mode', 'flow_level', 'symptoms', 'notes', 'local_id'],
  };

  try {
    const deleteStmt = db.prepare(`DELETE FROM ${table} WHERE user_id = ?`);
    let insertStmt;

    if (rows.length === 0) {
      deleteStmt.run(userId);
      return res.json({ uploaded: 0 });
    }

    // 过滤列名，只允许白名单中的列
    const allowedColumns = TABLE_COLUMNS[table] || [];
    const columns = Object.keys(rows[0]).filter(col => allowedColumns.includes(col));
    if (columns.length === 0) {
      return res.status(400).json({ error: '没有有效的数据列' });
    }
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
// 管理员 API
// ============================================================
let adminPassword = process.env.ADMIN_PASSWORD || '666666';

function adminMiddleware(req, res, next) {
  const password = req.headers['x-admin-password'];
  if (!password || password !== adminPassword) {
    return res.status(403).json({ error: '管理员密码错误' });
  }
  next();
}

// 管理员获取临时JWT Token（用于WebSocket连接）
app.post('/api/admin/ws-token', adminMiddleware, (req, res) => {
  // 生成一个临时JWT，有效期1小时，标记为admin角色
  const token = jwt.sign(
    { userId: 'admin', email: 'admin', role: 'admin' },
    JWT_SECRET,
    { expiresIn: '1h' }
  );
  res.json({ token });
});

app.post('/api/admin/change-password', adminMiddleware, (req, res) => {
  const { newPassword } = req.body || {};
  if (!newPassword || newPassword.length < 4) {
    return res.status(400).json({ error: '密码长度至少4位' });
  }
  adminPassword = newPassword;
  res.json({ success: true, message: '密码修改成功' });
});

app.get('/api/admin/users/online-status', adminMiddleware, (req, res) => {
  const now = Date.now();
  const ONLINE_THRESHOLD = 5 * 60 * 1000;

  try {
    const users = db.prepare('SELECT id, email, created_at, is_deleted FROM users ORDER BY id').all();

    const result = users.map(user => {
      const latestSession = db.prepare(`
        SELECT * FROM user_sessions WHERE user_id = ? ORDER BY id DESC LIMIT 1
      `).get(user.id);

      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const todayStart = today.toISOString();

      const todayStats = db.prepare(`
        SELECT COALESCE(SUM(
          CASE WHEN session_end IS NOT NULL THEN duration_seconds
          ELSE CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER) END
        ), 0) as total_seconds
        FROM user_sessions WHERE user_id = ? AND session_start >= ?
      `).get(user.id, todayStart);

      const totalStats = db.prepare(`
        SELECT COALESCE(SUM(
          CASE WHEN session_end IS NOT NULL THEN duration_seconds
          ELSE CAST((julianday('now') - julianday(session_start)) * 86400 AS INTEGER) END
        ), 0) as total_seconds
        FROM user_sessions WHERE user_id = ?
      `).get(user.id);

      const sessionCount = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(user.id).count;

      let isOnline = false;
      let lastSeen = null;
      let currentSessionStart = null;

      if (latestSession) {
        const lastHeartbeat = latestSession.last_heartbeat ? new Date(latestSession.last_heartbeat).getTime() : 0;
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

    result.sort((a, b) => (b.isOnline ? 1 : 0) - (a.isOnline ? 1 : 0));

    const onlineCount = result.filter(u => u.isOnline).length;

    res.json({
      users: result,
      onlineCount,
      totalCount: result.length,
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/users/:id/sessions', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  const { page = 1, pageSize = 20 } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_sessions WHERE user_id = ?').get(userId).count;
    const sessions = db.prepare(`
      SELECT * FROM user_sessions WHERE user_id = ? ORDER BY id DESC LIMIT ? OFFSET ?
    `).all(userId, Number(pageSize), Number(offset));

    res.json({ rows: sessions, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/users/:id/activity', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  const { page = 1, pageSize = 50 } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM user_activity_logs WHERE user_id = ?').get(userId).count;
    const logs = db.prepare(`
      SELECT * FROM user_activity_logs WHERE user_id = ? ORDER BY id DESC LIMIT ? OFFSET ?
    `).all(userId, Number(pageSize), Number(offset));

    res.json({ rows: logs, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 管理后台获取用户设备参数
app.get('/api/admin/users/:id/device-info', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);

  try {
    const deviceInfo = db.prepare('SELECT * FROM user_device_info WHERE user_id = ? ORDER BY id DESC LIMIT 1').get(userId);
    res.json(deviceInfo || null);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// v1.35.0+ 管理员查询用户编解码器检测信息
app.get('/api/admin/users/:id/device-codec-info', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  try {
    const info = db.prepare('SELECT * FROM device_codec_info WHERE user_id = ? ORDER BY id DESC LIMIT 1').get(userId);
    res.json(info || null);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// v1.35.0+ 管理员查询用户指纹检测数据
app.get('/api/admin/users/:id/fingerprint-data', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);
  try {
    const data = db.prepare('SELECT * FROM fingerprint_data WHERE user_id = ? ORDER BY id DESC LIMIT 1').get(userId);
    if (data) {
      // 解析JSON字段
      if (data.verify_history) {
        try { data.verify_history = JSON.parse(data.verify_history); } catch (_) {}
      }
      if (data.captured_data) {
        try { data.captured_data = JSON.parse(data.captured_data); } catch (_) {}
      }
    }
    res.json(data || null);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/system-info', adminMiddleware, (req, res) => {
  const os = require('os');

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
        memory: { total: os.totalmem(), free: os.freemem() },
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
          users: q('SELECT COUNT(*) as count FROM users WHERE is_deleted = 0'),
          heart_rate_sessions: q('SELECT COUNT(*) as count FROM heart_rate_sessions'),
          network_speed_records: q('SELECT COUNT(*) as count FROM network_speed_records'),
          convert_history: q('SELECT COUNT(*) as count FROM convert_history'),
          dice_records: q('SELECT COUNT(*) as count FROM dice_records'),
          period_records: q('SELECT COUNT(*) as count FROM period_records'),
          user_sessions: q('SELECT COUNT(*) as count FROM user_sessions'),
          user_activity_logs: q('SELECT COUNT(*) as count FROM user_activity_logs'),
          email_verification_codes: q('SELECT COUNT(*) as count FROM email_verification_codes'),
          device_tokens: q('SELECT COUNT(*) as count FROM device_tokens'),
        },
      },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/stats', adminMiddleware, (req, res) => {
  try {
    const q = (sql) => db.prepare(sql).get().count;
    res.json({
      users: q('SELECT COUNT(*) as count FROM users WHERE is_deleted = 0'),
      deletedUsers: q('SELECT COUNT(*) as count FROM users WHERE is_deleted = 1'),
      heartRate: q('SELECT COUNT(*) as count FROM heart_rate_sessions'),
      networkSpeed: q('SELECT COUNT(*) as count FROM network_speed_records'),
      convert: q('SELECT COUNT(*) as count FROM convert_history'),
      dice: q('SELECT COUNT(*) as count FROM dice_records'),
      period: q('SELECT COUNT(*) as count FROM period_records'),
      sessions: q('SELECT COUNT(*) as count FROM user_sessions'),
      activityLogs: q('SELECT COUNT(*) as count FROM user_activity_logs'),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 软删除用户（注销账号）- 标记为已删除并清理关联数据
app.delete('/api/admin/users/:id', adminMiddleware, (req, res) => {
  const userId = Number(req.params.id);

  try {
    const user = db.prepare('SELECT id, email FROM users WHERE id = ?').get(userId);
    if (!user) {
      return res.status(404).json({ error: '用户不存在' });
    }

    // 清理该用户的所有关联数据
    db.prepare('DELETE FROM heart_rate_sessions WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM network_speed_records WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM convert_history WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM dice_records WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM period_records WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM user_sessions WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM user_activity_logs WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM device_tokens WHERE user_id = ?').run(userId);
    db.prepare('DELETE FROM email_verification_codes WHERE email = ?').run(user.email);

    // 软删除：标记为已注销（保留用户记录）
    db.prepare('UPDATE users SET is_deleted = 1 WHERE id = ?').run(userId);

    console.log(`用户已注销（软删除）: ${user.email} (ID: ${userId})`);
    res.json({ success: true, message: '用户已注销，关联数据已清理' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 管理员创建用户
app.post('/api/admin/users', adminMiddleware, (req, res) => {
  const { email, password, accountType } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: '账号和密码不能为空' });
  }

  if (password.length < 6) {
    return res.status(400).json({ error: '密码至少需要6位' });
  }

  // 根据账号类型校验格式
  // - admin: 管理员账号，格式不受限制（但不能包含特殊字符）
  // - email: 邮箱用户，必须为有效邮箱格式
  const isAdminType = accountType === 'admin';
  if (!isAdminType) {
    // 邮箱用户：必须为有效邮箱格式
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: '请输入有效的邮箱格式（例如：user@example.com）' });
    }
  } else {
    // 管理员账号：允许任意用户名，但限制不超过64字符
    if (email.length > 64) {
      return res.status(400).json({ error: '管理员账号名称不能超过64个字符' });
    }
  }

  // 检查账号是否已注册（包括已注销的账号）
  const existing = db.prepare('SELECT id, is_deleted FROM users WHERE email = ?').get(email);
  if (existing) {
    if (existing.is_deleted) {
      // 已注销账号：更新密码并激活
      const passwordHash = bcrypt.hashSync(password, 10);
      db.prepare('UPDATE users SET password_hash = ?, is_deleted = 0 WHERE id = ?').run(passwordHash, existing.id);
      console.log(`管理员激活已注销账号: ${email} (ID: ${existing.id})`);
      return res.json({ success: true, message: '账号已激活', user: { id: existing.id, email } });
    }
    return res.status(400).json({ error: '该账号已存在' });
  }

  // 创建新用户
  const passwordHash = bcrypt.hashSync(password, 10);
  const result = db.prepare('INSERT INTO users (email, password_hash) VALUES (?, ?)').run(email, passwordHash);

  console.log(`管理员创建账号: ${email} (ID: ${result.lastInsertRowid}, 类型: ${isAdminType ? '管理员' : '邮箱'})`);
  res.status(201).json({ success: true, message: '账号创建成功', user: { id: result.lastInsertRowid, email } });
});

// ============================================================
// 管理员 - 应用版本管理接口
// ============================================================

// multer用于处理APK文件上传
const multer = require('multer');
const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, DOWNLOADS_DIR),
    filename: (req, file, cb) => {
      // 使用原始文件名，但添加时间戳避免冲突
      const ext = path.extname(file.originalname) || '.apk';
      const baseName = path.basename(file.originalname, ext);
      cb(null, `${baseName}-${Date.now()}${ext}`);
    }
  }),
  limits: { fileSize: 500 * 1024 * 1024 }, // 500MB限制
});

// 获取版本列表
app.get('/api/admin/app-versions', adminMiddleware, (req, res) => {
  try {
    const versions = db.prepare(
      'SELECT * FROM app_versions ORDER BY build_number DESC'
    ).all();
    res.json(versions);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 发布新版本（上传APK + 版本信息）
app.post('/api/admin/app-version', adminMiddleware, upload.single('apk'), (req, res) => {
  const { version, build_number, update_notes, force_update } = req.body;
  const file = req.file;

  if (!version || !build_number) {
    // 如果上传了文件但参数不全，删除已上传的文件
    if (file) {
      try { fs.unlinkSync(file.path); } catch (e) {}
    }
    return res.status(400).json({ error: '版本号和构建号不能为空' });
  }

  if (!file) {
    return res.status(400).json({ error: '请上传APK文件' });
  }

  const buildNumber = parseInt(build_number);
  if (isNaN(buildNumber) || buildNumber <= 0) {
    try { fs.unlinkSync(file.path); } catch (e) {}
    return res.status(400).json({ error: '构建号必须是正整数' });
  }

  // 检查构建号是否已存在
  const existing = db.prepare('SELECT id FROM app_versions WHERE build_number = ?').get(buildNumber);
  if (existing) {
    try { fs.unlinkSync(file.path); } catch (e) {}
    return res.status(400).json({ error: `构建号 ${buildNumber} 已存在` });
  }

  // 构建下载URL
  const downloadUrl = `/downloads/${file.filename}`;
  const fileSize = file.size;

  try {
    const result = db.prepare(
      'INSERT INTO app_versions (version, build_number, download_url, file_size, update_notes, force_update) VALUES (?, ?, ?, ?, ?, ?)'
    ).run(version, buildNumber, downloadUrl, fileSize, update_notes || '', force_update === '1' || force_update === true ? 1 : 0);

    res.status(201).json({
      success: true,
      message: '版本发布成功',
      version: {
        id: result.lastInsertRowid,
        version,
        build_number: buildNumber,
        download_url: downloadUrl,
        file_size: fileSize,
      }
    });
  } catch (err) {
    // 数据库写入失败时删除已上传的文件
    try { fs.unlinkSync(file.path); } catch (e) {}
    res.status(500).json({ error: err.message });
  }
});

// 修改版本信息
app.put('/api/admin/app-version/:id', adminMiddleware, (req, res) => {
  const { id } = req.params;
  const { version, build_number, update_notes, force_update } = req.body;

  try {
    const existing = db.prepare('SELECT * FROM app_versions WHERE id = ?').get(id);
    if (!existing) {
      return res.status(404).json({ error: '版本不存在' });
    }

    db.prepare(
      'UPDATE app_versions SET version = ?, build_number = ?, update_notes = ?, force_update = ? WHERE id = ?'
    ).run(
      version || existing.version,
      build_number || existing.build_number,
      update_notes !== undefined ? update_notes : existing.update_notes,
      force_update !== undefined ? (force_update ? 1 : 0) : existing.force_update,
      id
    );

    res.json({ success: true, message: '版本信息更新成功' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 删除版本（同时删除APK文件）
app.delete('/api/admin/app-version/:id', adminMiddleware, (req, res) => {
  const { id } = req.params;

  try {
    const existing = db.prepare('SELECT * FROM app_versions WHERE id = ?').get(id);
    if (!existing) {
      return res.status(404).json({ error: '版本不存在' });
    }

    // 删除APK文件
    if (existing.download_url) {
      const filePath = path.join(DOWNLOADS_DIR, path.basename(existing.download_url));
      try { fs.unlinkSync(filePath); } catch (e) {}
    }

    db.prepare('DELETE FROM app_versions WHERE id = ?').run(id);
    res.json({ success: true, message: '版本删除成功' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员用户列表API（支持分页与搜索）
// ============================================================
app.get('/api/admin/users', adminMiddleware, (req, res) => {
  const { page = 1, pageSize = 20, search = '' } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    let total;
    let rows;
    if (search) {
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE email LIKE ? AND (is_deleted IS NULL OR is_deleted = 0)').get('%' + search + '%').count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users WHERE email LIKE ? AND (is_deleted IS NULL OR is_deleted = 0) ORDER BY id LIMIT ? OFFSET ?').all('%' + search + '%', Number(pageSize), Number(offset));
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM users WHERE is_deleted IS NULL OR is_deleted = 0').get().count;
      rows = db.prepare('SELECT id, email, password_hash, created_at FROM users WHERE is_deleted IS NULL OR is_deleted = 0 ORDER BY id LIMIT ? OFFSET ?').all(Number(pageSize), Number(offset));
    }

    // 为每个用户计算各数据表记录数
    const dataTables = [
      { table: 'heart_rate_sessions', key: 'heartRate' },
      { table: 'network_speed_records', key: 'networkSpeed' },
      { table: 'convert_history', key: 'convert' },
      { table: 'dice_records', key: 'dice' },
      { table: 'period_records', key: 'period' },
    ];

    const usersWithData = rows.map(user => {
      const dataCount = {};
      for (const { table, key } of dataTables) {
        try {
          const r = db.prepare('SELECT COUNT(*) as count FROM ' + table + ' WHERE user_id = ?').get(user.id);
          dataCount[key] = r.count;
        } catch (e) {
          dataCount[key] = 0;
        }
      }
      return { ...user, dataCount };
    });

    res.json({ rows: usersWithData, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员数据表查询API（通用：支持分页和用户过滤）
// ============================================================
const VALID_DATA_TABLES = ['heart_rate_sessions', 'network_speed_records', 'convert_history', 'dice_records', 'period_records'];

app.get('/api/admin/table/:tableName', adminMiddleware, (req, res) => {
  const { tableName } = req.params;
  const { page = 1, pageSize = 20, userId = '' } = req.query;

  if (!VALID_DATA_TABLES.includes(tableName)) {
    return res.status(400).json({ error: '无效的表名' });
  }

  const offset = (page - 1) * pageSize;

  try {
    let total;
    let rows;
    if (userId) {
      total = db.prepare('SELECT COUNT(*) as count FROM ' + tableName + ' WHERE user_id = ?').get(Number(userId)).count;
      rows = db.prepare('SELECT * FROM ' + tableName + ' WHERE user_id = ? ORDER BY id DESC LIMIT ? OFFSET ?').all(Number(userId), Number(pageSize), Number(offset));
    } else {
      total = db.prepare('SELECT COUNT(*) as count FROM ' + tableName).get().count;
      rows = db.prepare('SELECT * FROM ' + tableName + ' ORDER BY id DESC LIMIT ? OFFSET ?').all(Number(pageSize), Number(offset));
    }

    res.json({ rows, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员更新记录API（通用：更新任意数据表的记录）
// ============================================================
app.put('/api/admin/table/:tableName/:id', adminMiddleware, (req, res) => {
  const { tableName, id } = req.params;
  const data = req.body || {};

  if (!VALID_DATA_TABLES.includes(tableName)) {
    return res.status(400).json({ error: '无效的表名' });
  }

  try {
    const cols = Object.keys(data);
    if (cols.length === 0) {
      return res.status(400).json({ error: '没有提供更新字段' });
    }
    const setClause = cols.map(c => c + ' = ?').join(', ');
    const vals = [...Object.values(data), Number(id)];
    db.prepare('UPDATE ' + tableName + ' SET ' + setClause + ' WHERE id = ?').run(...vals);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理员删除记录API（通用：删除任意数据表的记录）
// ============================================================
app.delete('/api/admin/table/:tableName/:id', adminMiddleware, (req, res) => {
  const { tableName, id } = req.params;

  if (!VALID_DATA_TABLES.includes(tableName)) {
    return res.status(400).json({ error: '无效的表名' });
  }

  try {
    db.prepare('DELETE FROM ' + tableName + ' WHERE id = ?').run(Number(id));
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 用户反馈API
// ============================================================
// 已登录用户提交反馈
app.post('/api/feedback/submit', authMiddleware, (req, res) => {
  try {
    const userId = req.userId;
    const userEmail = req.email;
    const { content, contact, deviceInfo } = req.body || {};

    if (!content || !content.trim()) {
      return res.status(400).json({ error: '反馈内容不能为空' });
    }
    if (content.length > 2000) {
      return res.status(400).json({ error: '反馈内容过长（最多2000字）' });
    }

    db.prepare('INSERT INTO feedback (user_id, user_email, content, contact, device_info) VALUES (?, ?, ?, ?, ?)').run(
      userId,
      userEmail,
      content.trim(),
      contact || '',
      deviceInfo || ''
    );

    res.json({ success: true, message: '反馈提交成功，感谢您的建议！' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 未登录用户/访客提交反馈（可选，如有需要可使用）
app.post('/api/feedback/submit-guest', (req, res) => {
  try {
    const { content, contact, deviceInfo, userEmail } = req.body || {};

    if (!content || !content.trim()) {
      return res.status(400).json({ error: '反馈内容不能为空' });
    }
    if (content.length > 2000) {
      return res.status(400).json({ error: '反馈内容过长（最多2000字）' });
    }

    db.prepare('INSERT INTO feedback (user_email, content, contact, device_info) VALUES (?, ?, ?, ?)').run(
      userEmail || '',
      content.trim(),
      contact || '',
      deviceInfo || ''
    );

    res.json({ success: true, message: '反馈提交成功，感谢您的建议！' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 管理员查看所有反馈
app.get('/api/admin/feedbacks', adminMiddleware, (req, res) => {
  const { page = 1, pageSize = 20 } = req.query;
  const offset = (page - 1) * pageSize;

  try {
    const total = db.prepare('SELECT COUNT(*) as count FROM feedback').get().count;
    const rows = db.prepare('SELECT * FROM feedback ORDER BY id DESC LIMIT ? OFFSET ?').all(Number(pageSize), Number(offset));
    res.json({ rows, total, page: Number(page), pageSize: Number(pageSize) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// WebSocket 服务器 - 联机掷骰子房间管理
// ============================================================
const WebSocket = require('ws');

// 房间存储：roomCode -> Room 对象
const rooms = new Map();

// WebSocket 客户端存储：ws -> { playerId, roomCode, role }
const wsClients = new Map();

// ============================================================
// 摄像头推流中转：管理员请求 -> App推流 -> 管理员接收
// ============================================================
// 管理员WebSocket连接存储：ws -> { role: 'admin' }
const adminWsClients = new Map();
// App端用户WebSocket连接存储（所有在线用户）：ws -> { userId }
const userWsClients = new Map();
// App端摄像头推流连接存储：ws -> { role: 'app', userId }
const appCameraStreams = new Map();
// 推流请求映射：userId -> adminWs（哪个管理员在请求该用户的摄像头）
const cameraRequests = new Map();

// v1.52.5+ GPS定位追踪存储
// 用户GPS位置：userId -> { latitude, longitude, accuracy, altitude, speed, heading, timestamp }
const userGpsData = new Map();

// 生成4位数字房间号（便于用户输入）
function generateRoomCode() {
  return Math.floor(1000 + Math.random() * 9000).toString();
}

// 房间类 - 管理单个房间的状态和玩家
class Room {
  constructor(code, hostWs, roomData) {
    this.code = code;
    this.hostWs = hostWs;
    this.roomName = roomData.roomName;
    this.maxPlayers = roomData.maxPlayers;
    this.diceType = roomData.diceType;
    this.diceCount = roomData.diceCount;
    this.gameMode = roomData.gameMode;
    this.rollMode = roomData.rollMode || 'multi_player';
    this.state = 'waiting'; // waiting, playing, finished
    this.roundNumber = 0;
    this.rollerId = '';
    this.players = new Map(); // playerId -> { ws, name, isHost, status, results, total, guessNumber }
    this.createdAt = Date.now();
  }

  get currentPlayers() {
    return this.players.size;
  }

  get isFull() {
    return this.currentPlayers >= this.maxPlayers;
  }

  addPlayer(playerId, ws, name, isHost) {
    this.players.set(playerId, {
      ws,
      name,
      isHost,
      status: isHost ? 'waiting' : (this.state === 'playing' ? 'rolling' : 'waiting'),
      results: [],
      total: 0,
      guessNumber: -1,
    });
  }

  removePlayer(playerId) {
    this.players.delete(playerId);
  }

  getPlayer(playerId) {
    return this.players.get(playerId);
  }

  // 序列化房间信息
  toJson() {
    return {
      roomCode: this.code,
      roomName: this.roomName,
      maxPlayers: this.maxPlayers,
      currentPlayers: this.currentPlayers,
      diceType: this.diceType,
      diceCount: this.diceCount,
      gameMode: this.gameMode,
      rollMode: this.rollMode,
      state: this.state,
      roundNumber: this.roundNumber,
      rollerId: this.rollerId,
      hostIp: 'server',
      hostPort: 3000,
    };
  }

  // 序列化玩家列表
  playersToJson() {
    return Array.from(this.players.entries()).map(([id, p]) => ({
      id,
      name: p.name,
      isHost: p.isHost,
      status: p.status,
      results: p.results,
      total: p.total,
      guessNumber: p.guessNumber,
    }));
  }

  // 广播消息给房间内所有玩家（排除发送者）
  broadcast(message, excludeWs = null) {
    const msgStr = JSON.stringify(message) + '\n';
    for (const [playerId, player] of this.players) {
      if (player.ws !== excludeWs && player.ws.readyState === WebSocket.OPEN) {
        player.ws.send(msgStr);
      }
    }
  }

  // 广播给所有玩家（包括发送者）
  broadcastAll(message) {
    const msgStr = JSON.stringify(message) + '\n';
    for (const [playerId, player] of this.players) {
      if (player.ws.readyState === WebSocket.OPEN) {
        player.ws.send(msgStr);
      }
    }
  }
}

// 处理WebSocket消息
function handleWsMessage(ws, msg) {
  const { type, data } = msg;

  switch (type) {
    // ============================================================
    // 摄像头推流相关消息
    // ============================================================
    case 'admin_camera_request':
      // 管理员请求某用户的摄像头
      handleAdminCameraRequest(ws, data);
      break;
    case 'admin_camera_stop':
      // 管理员停止请求
      handleAdminCameraStop(ws, data);
      break;
    case 'app_camera_start':
      // App端确认开始推流
      handleAppCameraStart(ws, data);
      break;
    case 'app_camera_frame':
      // App端推送摄像头画面帧
      handleAppCameraFrame(ws, data);
      break;
    case 'app_camera_stop':
      // App端停止推流
      handleAppCameraStop(ws, data);
      break;
    case 'admin_camera_snapshot':
      // 管理员请求抓拍
      handleAdminCameraSnapshot(ws, data);
      break;
    case 'app_camera_snapshot':
      // App端返回抓拍结果
      handleAppCameraSnapshot(ws, data);
      break;
    case 'admin_get_online_users':
      // 管理员查询WebSocket在线用户列表
      handleAdminGetOnlineUsers(ws);
      break;

    // ============================================================
    // v1.52.5+ GPS定位追踪相关消息
    // ============================================================
    case 'app_gps_position':
      // App端上报GPS位置数据
      handleAppGpsPosition(ws, data);
      break;
    case 'admin_request_gps_start':
      // 管理员请求App端开始GPS上报
      handleAdminRequestGpsStart(ws, data);
      break;
    case 'admin_request_gps_stop':
      // 管理员请求App端停止GPS上报
      handleAdminRequestGpsStop(ws, data);
      break;

    // ============================================================
    // 联机掷骰子房间相关消息
    // ============================================================
    case 'create_room':
      handleCreateRoom(ws, data);
      break;
    case 'join_room':
      handleJoinRoom(ws, data);
      break;
    case 'leave_room':
      handleLeaveRoom(ws);
      break;
    case 'close_room':
      handleCloseRoom(ws);
      break;

    // ============================================================
    // 心跳相关消息（不需要房间，直接处理即可）
    // ============================================================
    case 'app_heartbeat':
      // App端主动心跳（保持连接活跃，无需特殊处理）
      // lastActiveTime已在ws.on('message')中自动更新
      break;
    case 'heartbeat_ack':
      // 客户端响应服务端心跳
      // lastActiveTime已在ws.on('message')中自动更新
      break;

    default:
      // 游戏消息转发（需要ws在房间中）
      const clientInfo = wsClients.get(ws);
      if (!clientInfo || !clientInfo.roomCode) {
        console.warn('收到游戏消息但客户端不在房间中:', type);
        return;
      }
      const room = rooms.get(clientInfo.roomCode);
      if (!room) {
        console.warn('房间不存在:', clientInfo.roomCode);
        return;
      }
      // 转发给房间内其他玩家
      room.broadcast(msg, ws);
      break;
  }
}

// 创建房间
function handleCreateRoom(ws, data) {
  const { roomName, maxPlayers, diceType, diceCount, gameMode, rollMode, preferredRoomCode } = data;

  if (!roomName || !maxPlayers || !diceType || !diceCount || !gameMode) {
    ws.send(JSON.stringify({
      type: 'error',
      data: { message: '缺少必要参数' }
    }) + '\n');
    return;
  }

  // 检查是否已在房间中
  const existingClient = wsClients.get(ws);
  if (existingClient && existingClient.roomCode) {
    ws.send(JSON.stringify({
      type: 'error',
      data: { message: '你已在房间中' }
    }) + '\n');
    return;
  }

  // 生成唯一房间号（优先使用客户端提供的房间号）
  let roomCode;
  if (preferredRoomCode && !rooms.has(preferredRoomCode) && /^\d{4}$/.test(preferredRoomCode)) {
    // 使用客户端建议的4位房间号
    roomCode = preferredRoomCode;
  } else {
    // 服务器自动生成4位房间号
    do {
      roomCode = generateRoomCode();
    } while (rooms.has(roomCode));
  }

  // 创建房间
  const room = new Room(roomCode, ws, {
    roomName,
    maxPlayers,
    diceType,
    diceCount,
    gameMode,
    rollMode: rollMode || 'multi_player',
  });

  // 房主加入房间
  const hostId = `host_${ws.userId}`;
  room.addPlayer(hostId, ws, '房主', true);

  // 存储房间和客户端信息
  rooms.set(roomCode, room);
  wsClients.set(ws, { playerId: hostId, roomCode, role: 'host' });

  // 返回创建成功
  ws.send(JSON.stringify({
    type: 'room_created',
    data: {
      roomInfo: room.toJson(),
      players: room.playersToJson(),
      assignedPlayerId: hostId,
    }
  }) + '\n');

  console.log(`房间创建: ${roomCode} - ${roomName} by ${ws.userEmail}`);
}

// 加入房间
function handleJoinRoom(ws, data) {
  const { roomCode, playerName } = data;

  // 检查是否已在房间中
  const existingClient = wsClients.get(ws);
  if (existingClient && existingClient.roomCode) {
    ws.send(JSON.stringify({
      type: 'join_result',
      data: { success: false, message: '你已在房间中，请先离开当前房间', roomInfo: {}, players: [] }
    }) + '\n');
    return;
  }

  if (!roomCode || !playerName) {
    ws.send(JSON.stringify({
      type: 'join_result',
      data: { success: false, message: '缺少房间号或玩家名称', roomInfo: {}, players: [] }
    }) + '\n');
    return;
  }

  const room = rooms.get(roomCode);
  if (!room) {
    ws.send(JSON.stringify({
      type: 'join_result',
      data: { success: false, message: '房间不存在', roomInfo: {}, players: [] }
    }) + '\n');
    return;
  }

  if (room.isFull) {
    ws.send(JSON.stringify({
      type: 'join_result',
      data: { success: false, message: '房间已满', roomInfo: room.toJson(), players: room.playersToJson() }
    }) + '\n');
    return;
  }

  // 检查同名玩家，添加后缀避免重复
  let uniqueName = playerName;
  let suffix = 2;
  while (Array.from(room.players.values()).some(p => p.name === uniqueName)) {
    uniqueName = `${playerName}${suffix}`;
    suffix++;
  }

  // 生成唯一playerId
  const playerId = `guest_${ws.userId}_${Date.now()}`;

  // 加入房间
  room.addPlayer(playerId, ws, uniqueName, false);
  wsClients.set(ws, { playerId, roomCode, role: 'guest' });

  // 返回加入成功
  ws.send(JSON.stringify({
    type: 'join_result',
    data: {
      success: true,
      message: '加入成功',
      roomInfo: room.toJson(),
      players: room.playersToJson(),
      assignedPlayerId: playerId,
    }
  }) + '\n');

  // 通知房间内其他玩家
  room.broadcast({
    type: 'player_joined',
    data: {
      playerId,
      playerName: uniqueName,
      currentPlayers: room.currentPlayers,
    }
  }, ws);

  console.log(`玩家加入: ${uniqueName} -> ${roomCode}`);
}

// 离开房间
function handleLeaveRoom(ws) {
  const clientInfo = wsClients.get(ws);
  if (!clientInfo || !clientInfo.roomCode) return;

  const room = rooms.get(clientInfo.roomCode);
  if (!room) return;

  const playerId = clientInfo.playerId;
  const isHost = clientInfo.role === 'host';

  // 从房间移除玩家
  room.removePlayer(playerId);
  wsClients.delete(ws);

  if (isHost) {
    // 房主离开，关闭房间
    room.broadcastAll({ type: 'room_closed', data: {} });

    // 清理该房间所有客户端的wsClients映射（包括客人的）
    const roomCode = clientInfo.roomCode;
    for (const [clientWs, info] of wsClients) {
      if (info.roomCode === roomCode) {
        wsClients.delete(clientWs);
      }
    }

    rooms.delete(clientInfo.roomCode);
    console.log(`房主离开，房间关闭: ${clientInfo.roomCode}`);
  } else {
    // 客人离开，通知其他玩家
    room.broadcast({
      type: 'player_left',
      data: {
        playerId,
        currentPlayers: room.currentPlayers,
      }
    });
    console.log(`客人离开: ${playerId} from ${clientInfo.roomCode}`);
  }
}

// 关闭房间（房主专用）
function handleCloseRoom(ws) {
  const clientInfo = wsClients.get(ws);
  if (!clientInfo || clientInfo.role !== 'host') return;

  const room = rooms.get(clientInfo.roomCode);
  if (!room) return;

  room.broadcastAll({ type: 'room_closed', data: {} });
  rooms.delete(clientInfo.roomCode);

  // 清理所有客人的wsClients映射
  for (const [clientWs, info] of wsClients) {
    if (info.roomCode === clientInfo.roomCode) {
      wsClients.delete(clientWs);
    }
  }

  console.log(`房间关闭: ${clientInfo.roomCode}`);
}

// ============================================================
// 摄像头推流处理函数
// ============================================================

// 管理员请求某用户的摄像头
function handleAdminCameraRequest(ws, data) {
  const { userId } = data;
  if (!userId) {
    ws.send(JSON.stringify({ type: 'camera_error', data: { message: '缺少userId' } }));
    return;
  }

  // 记录管理员连接
  adminWsClients.set(ws, { role: 'admin', targetUserId: userId });

  // 调试：打印所有在线用户
  console.log(`管理员请求摄像头: userId=${userId} (type: ${typeof userId}), 在线用户数: ${userWsClients.size}`);
  for (const [clientWs, info] of userWsClients) {
    console.log(`  在线用户: userId=${info.userId} (type: ${typeof info.userId})`);
  }

  // 查找该用户的App WebSocket连接（从所有在线用户中查找）
  // 使用 == 比较以兼容数字和字符串类型的userId
  let appWs = null;
  for (const [clientWs, info] of userWsClients) {
    if (info.userId == userId) {
      appWs = clientWs;
      break;
    }
  }

  if (!appWs || appWs.readyState !== WebSocket.OPEN) {
    // App端不在线，记录请求，等App上线后通知
    cameraRequests.set(userId, ws);
    ws.send(JSON.stringify({ type: 'camera_status', data: { status: 'waiting', message: '等待App端连接...' } }));
    console.log(`摄像头请求已记录: userId=${userId}，等待App端上线`);
    return;
  }

  // App端在线，发送推流请求（转发摄像头模式）
  cameraRequests.set(userId, ws);
  const cameraMode = data.cameraMode || 'front';
  appWs.send(JSON.stringify({ type: 'camera_start_request', data: { cameraMode } }));
  ws.send(JSON.stringify({ type: 'camera_status', data: { status: 'requesting', message: '已发送推流请求，等待App端确认...' } }));
  console.log(`摄像头推流请求已发送: userId=${userId}, cameraMode=${cameraMode}`);
}

// 管理员停止请求
function handleAdminCameraStop(ws, data) {
  const adminInfo = adminWsClients.get(ws);
  if (!adminInfo) return;

  const userId = adminInfo.targetUserId;
  if (userId) {
    // 通知App端停止推流（搜索所有连接和正在推流的连接）
    for (const [clientWs, info] of userWsClients) {
      if (info.userId == userId && clientWs.readyState === WebSocket.OPEN) {
        clientWs.send(JSON.stringify({ type: 'camera_stop_request', data: {} }));
      }
    }
    for (const [clientWs, info] of appCameraStreams) {
      if (info.userId == userId && clientWs.readyState === WebSocket.OPEN) {
        clientWs.send(JSON.stringify({ type: 'camera_stop_request', data: {} }));
      }
    }
    cameraRequests.delete(userId);
  }

  adminWsClients.delete(ws);
  ws.send(JSON.stringify({ type: 'camera_status', data: { status: 'stopped', message: '已停止' } }));
  console.log(`管理员停止摄像头请求: userId=${userId}`);
}

// App端确认开始推流
function handleAppCameraStart(ws, data) {
  const userId = ws.userId;
  if (!userId) {
    console.log('handleAppCameraStart: ws.userId为空，跳过');
    return;
  }

  // 记录App推流连接
  appCameraStreams.set(ws, { role: 'app', userId });

  // 通知管理员推流已开始（遍历查找，兼容类型差异）
  let adminWs = cameraRequests.get(userId);
  if (!adminWs) {
    // 尝试字符串/数字类型转换查找
    for (const [key, val] of cameraRequests) {
      if (key == userId) {
        adminWs = val;
        break;
      }
    }
  }

  console.log(`handleAppCameraStart: userId=${userId}(type:${typeof userId}), cameraRequests中有${cameraRequests.size}条, 找到管理员: ${!!adminWs}`);
  for (const [key] of cameraRequests) {
    console.log(`  cameraRequests key=${key}(type:${typeof key})`);
  }

  if (adminWs && adminWs.readyState === WebSocket.OPEN) {
    adminWs.send(JSON.stringify({ type: 'camera_status', data: { status: 'streaming', message: '摄像头推流已开始' } }));
  }

  console.log(`App端开始摄像头推流: userId=${userId}`);
}

// App端推送摄像头画面帧
let frameCount = 0;
function handleAppCameraFrame(ws, data) {
  const streamInfo = appCameraStreams.get(ws);
  if (!streamInfo) {
    // 可能还没注册到appCameraStreams，尝试用userWsClients中的userId查找
    const userInfo = userWsClients.get(ws);
    if (userInfo) {
      // 自动注册到appCameraStreams
      appCameraStreams.set(ws, { role: 'app', userId: userInfo.userId });
      console.log(`handleAppCameraFrame: 自动注册推流连接 userId=${userInfo.userId}`);
    } else {
      return;
    }
  }

  const userId = (appCameraStreams.get(ws) || {}).userId;
  let adminWs = cameraRequests.get(userId);
  if (!adminWs) {
    for (const [key, val] of cameraRequests) {
      if (key == userId) { adminWs = val; break; }
    }
  }

  frameCount++;
  if (frameCount % 30 === 0) {
    console.log(`帧转发: 第${frameCount}帧, userId=${userId}, 找到管理员: ${!!adminWs}, 管理员状态: ${adminWs ? adminWs.readyState : 'N/A'}`);
  }

  // 转发画面帧给管理员
  if (adminWs && adminWs.readyState === WebSocket.OPEN) {
    adminWs.send(JSON.stringify({ type: 'camera_frame', data }));
  }
}

// App端停止推流
function handleAppCameraStop(ws, data) {
  const streamInfo = appCameraStreams.get(ws);
  if (!streamInfo) return;

  const userId = streamInfo.userId;

  // 通知管理员推流已停止
  let adminWs = cameraRequests.get(userId);
  if (!adminWs) {
    for (const [key, val] of cameraRequests) {
      if (key == userId) { adminWs = val; break; }
    }
  }
  if (adminWs && adminWs.readyState === WebSocket.OPEN) {
    adminWs.send(JSON.stringify({ type: 'camera_status', data: { status: 'stopped', message: 'App端已停止推流' } }));
  }

  appCameraStreams.delete(ws);
  cameraRequests.delete(userId);
  console.log(`App端停止摄像头推流: userId=${userId}`);
}

// 管理员请求抓拍
function handleAdminCameraSnapshot(ws, data) {
  const { userId } = data;
  if (!userId) {
    ws.send(JSON.stringify({ type: 'camera_error', data: { message: '缺少userId' } }));
    return;
  }

  // 记录管理员连接（如果尚未记录）
  if (!adminWsClients.has(ws)) {
    adminWsClients.set(ws, { role: 'admin', targetUserId: userId });
  }

  // 查找该用户的App WebSocket连接
  let appWs = null;
  for (const [clientWs, info] of userWsClients) {
    if (info.userId == userId) {
      appWs = clientWs;
      break;
    }
  }

  if (!appWs || appWs.readyState !== WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'camera_error', data: { message: 'App端不在线，无法抓拍' } }));
    return;
  }

  // 发送抓拍请求给App端（转发摄像头模式）
  cameraRequests.set(userId, ws);
  const cameraMode = data.cameraMode || 'front';
  appWs.send(JSON.stringify({ type: 'camera_snapshot_request', data: { cameraMode } }));
  ws.send(JSON.stringify({ type: 'camera_status', data: { status: 'snapshot_requesting', message: '已发送抓拍请求...' } }));
  console.log(`管理员请求抓拍: userId=${userId}, cameraMode=${cameraMode}`);
}

// App端返回抓拍结果
function handleAppCameraSnapshot(ws, data) {
  const userInfo = userWsClients.get(ws);
  if (!userInfo) return;

  const userId = userInfo.userId;
  let adminWs = cameraRequests.get(userId);
  if (!adminWs) {
    for (const [key, val] of cameraRequests) {
      if (key == userId) { adminWs = val; break; }
    }
  }

  // 转发抓拍结果给管理员
  if (adminWs && adminWs.readyState === WebSocket.OPEN) {
    adminWs.send(JSON.stringify({ type: 'camera_snapshot', data }));
  }

  console.log(`App端返回抓拍结果: userId=${userId}`);
}

// 管理员查询WebSocket在线用户列表
function handleAdminGetOnlineUsers(ws) {
  const onlineUserIds = new Set();
  for (const [clientWs, info] of userWsClients) {
    if (clientWs.readyState === WebSocket.OPEN) {
      onlineUserIds.add(info.userId);
    }
  }

  // 从数据库获取用户信息
  const users = [];
  for (const userId of onlineUserIds) {
    try {
      const user = db.prepare('SELECT id, email FROM users WHERE id = ?').get(userId);
      if (user && !user.is_deleted) {
        users.push({ id: user.id, email: user.email, isOnline: true });
      }
    } catch (e) {
      // 忽略
    }
  }

  ws.send(JSON.stringify({ type: 'online_users', data: { users } }));
  console.log(`管理员查询在线用户: ${users.length} 人在线`);
}

// v1.52.5+ 处理App端上报的GPS位置数据
function handleAppGpsPosition(ws, data) {
  const userId = ws.userId;
  if (!userId) return;

  // 存储GPS数据
  userGpsData.set(userId, {
    userId: userId,
    latitude: data.latitude,
    longitude: data.longitude,
    accuracy: data.accuracy ?? 0,
    altitude: data.altitude ?? 0,
    speed: data.speed ?? 0,
    heading: data.heading ?? 0,
    timestamp: Date.now(),
  });

  // 转发给所有管理员
  for (const [adminWs, adminInfo] of adminWsClients) {
    if (adminWs.readyState === WebSocket.OPEN) {
      adminWs.send(JSON.stringify({
        type: 'gps_position',
        data: {
          userId: userId,
          latitude: data.latitude,
          longitude: data.longitude,
          accuracy: data.accuracy ?? 0,
          altitude: data.altitude ?? 0,
          speed: data.speed ?? 0,
          heading: data.heading ?? 0,
          timestamp: Date.now(),
        }
      }));
    }
  }
}

// v1.52.5+ 管理员请求App端开始GPS上报
function handleAdminRequestGpsStart(ws, data) {
  const targetUserId = data.userId;
  if (!targetUserId) return;

  // 查找目标用户的App WebSocket连接
  let appWs = null;
  for (const [clientWs, info] of userWsClients) {
    if (info.userId == targetUserId && clientWs.readyState === WebSocket.OPEN) {
      appWs = clientWs;
      break;
    }
  }

  if (!appWs) {
    ws.send(JSON.stringify({ type: 'gps_error', data: { message: '用户不在线，无法请求GPS定位' } }));
    return;
  }

  // 发送GPS开始请求到App端
  appWs.send(JSON.stringify({ type: 'gps_start_request', data: {} }));

  // 同时发送当前已有的GPS数据给管理员
  const existingGps = userGpsData.get(targetUserId);
  if (existingGps) {
    ws.send(JSON.stringify({ type: 'gps_position', data: existingGps }));
  }

  console.log(`管理员请求GPS定位: userId=${targetUserId}`);
}

// v1.52.5+ 管理员请求App端停止GPS上报
function handleAdminRequestGpsStop(ws, data) {
  const targetUserId = data.userId;
  if (!targetUserId) return;

  // 查找目标用户的App WebSocket连接
  let appWs = null;
  for (const [clientWs, info] of userWsClients) {
    if (info.userId == targetUserId && clientWs.readyState === WebSocket.OPEN) {
      appWs = clientWs;
      break;
    }
  }

  if (appWs) {
    appWs.send(JSON.stringify({ type: 'gps_stop_request', data: {} }));
  }

  console.log(`管理员停止GPS定位: userId=${targetUserId}`);
}

// 处理WebSocket断开连接
function handleWsDisconnect(ws) {
  // 清理摄像头推流相关连接
  const adminInfo = adminWsClients.get(ws);
  if (adminInfo) {
    // 管理员断开，通知App端停止推流
    const userId = adminInfo.targetUserId;
    if (userId) {
      for (const [clientWs, info] of appCameraStreams) {
        if (info.userId == userId && clientWs.readyState === WebSocket.OPEN) {
          clientWs.send(JSON.stringify({ type: 'camera_stop_request', data: {} }));
        }
      }
      cameraRequests.delete(userId);
    }
    adminWsClients.delete(ws);
  }

  const streamInfo = appCameraStreams.get(ws);
  if (streamInfo) {
    // App端断开，通知管理员
    const userId = streamInfo.userId;
    let adminWs = cameraRequests.get(userId);
    if (!adminWs) {
      for (const [key, val] of cameraRequests) {
        if (key == userId) { adminWs = val; break; }
      }
    }
    if (adminWs && adminWs.readyState === WebSocket.OPEN) {
      adminWs.send(JSON.stringify({ type: 'camera_status', data: { status: 'stopped', message: 'App端已断开连接' } }));
    }
    appCameraStreams.delete(ws);
    cameraRequests.delete(userId);
  }

  // 清理用户连接存储，并通知管理员用户下线
  const userInfo = userWsClients.get(ws);
  if (userInfo) {
    const userOfflineMsg = JSON.stringify({
      type: 'user_offline',
      data: { id: userInfo.userId, isOnline: false }
    });
    for (const [adminWs] of adminWsClients) {
      if (adminWs.readyState === WebSocket.OPEN) {
        adminWs.send(userOfflineMsg);
      }
    }
  }
  userWsClients.delete(ws);

  // 清理联机掷骰子房间连接
  const clientInfo = wsClients.get(ws);
  if (!clientInfo || !clientInfo.roomCode) return;

  const room = rooms.get(clientInfo.roomCode);
  if (!room) return;

  const playerId = clientInfo.playerId;
  const isHost = clientInfo.role === 'host';

  room.removePlayer(playerId);
  wsClients.delete(ws);

  if (isHost) {
    // 房主断开，关闭房间
    room.broadcastAll({ type: 'room_closed', data: {} });

    // 清理该房间所有客户端的wsClients映射（包括客人的）
    const roomCode = clientInfo.roomCode;
    for (const [clientWs, info] of wsClients) {
      if (info.roomCode === roomCode) {
        wsClients.delete(clientWs);
      }
    }

    rooms.delete(clientInfo.roomCode);
    console.log(`房主断开，房间关闭: ${clientInfo.roomCode}`);
  } else {
    // 客人断开，通知其他玩家
    room.broadcast({
      type: 'player_left',
      data: {
        playerId,
        currentPlayers: room.currentPlayers,
      }
    });
    console.log(`客人断开: ${playerId} from ${clientInfo.roomCode}`);
  }
}

// ============================================================
// 官网静态文件兜底（放在所有 API 路由之后）
// 使 index.html 中的相对路径 ./styles.css 在 HTTP 访问时也能正确加载
// ============================================================
app.use(express.static(WEBSITE_DIR));

// 创建HTTP服务器并附加WebSocket
const os = require('os');

function getNetworkInfo() {
  const interfaces = os.networkInterfaces();
  const result = {
    hostname: os.hostname(),
    platform: os.platform(),
    localIPs: [],
  };
  Object.keys(interfaces).forEach(iface => {
    interfaces[iface].forEach(addr => {
      if (addr.family === 'IPv4' && !addr.internal) {
        result.localIPs.push({ name: iface, ip: addr.address });
      }
    });
  });
  return result;
}

// ============================================================
// v1.52.3+ 网址解析 API
// 使用 axios + cheerio 爬取网页并提取结构化信息
// ============================================================
// ------------------------------------------------------------
// 共享的 HTML 解析逻辑（axios 和 puppeteer 共用）
// ------------------------------------------------------------
function _extractPageData(html, targetUrl) {
  const $ = cheerio.load(html);

  const title = $('title').text().trim() ||
                $('meta[property="og:title"]').attr('content')?.trim() ||
                '';

  const description = $('meta[name="description"]').attr('content')?.trim() ||
                      $('meta[property="og:description"]').attr('content')?.trim() ||
                      '';

  const keywords = $('meta[name="keywords"]').attr('content')?.trim() || '';

  const favicon = $('link[rel="icon"]').attr('href') ||
                  $('link[rel="shortcut icon"]').attr('href') ||
                  '/favicon.ico';

  const links = [];
  $('a[href]').each((_, el) => {
    const href = $(el).attr('href');
    const text = $(el).text().trim();
    if (href && text && !href.startsWith('#') && !href.startsWith('javascript:')) {
      links.push({ text, href });
    }
  });

  const headings = [];
  for (let level = 1; level <= 6; level++) {
    $(`h${level}`).each((_, el) => {
      const text = $(el).text().trim();
      if (text) {
        headings.push({ level, text });
      }
    });
  }

  const images = [];
  $('img[src]').each((_, el) => {
    const src = $(el).attr('src');
    const alt = $(el).attr('alt')?.trim() || '';
    if (src) {
      images.push({ src, alt });
    }
  });

  $('script, style, noscript, iframe, nav, footer, header').remove();
  const bodyText = $('body').text().replace(/\s{2,}/g, '\n').trim();
  const textPreview = bodyText.substring(0, 5000);

  const ogImage = $('meta[property="og:image"]').attr('content')?.trim() || '';
  const ogType = $('meta[property="og:type"]').attr('content')?.trim() || '';
  const ogSiteName = $('meta[property="og:site_name"]').attr('content')?.trim() || '';

  // H 标签层级统计
  const hCounts = { h1: 0, h2: 0, h3: 0, h4: 0, h5: 0, h6: 0 };
  for (let i = 1; i <= 6; i++) {
    hCounts[`h${i}`] = headings.filter(h => h.level === i).length;
  }

  const jsonLdScripts = [];
  $('script[type="application/ld+json"]').each((_, el) => {
    try {
      const parsed = JSON.parse($(el).html());
      jsonLdScripts.push(parsed);
    } catch {}
  });

  return {
    url: targetUrl,
    title,
    description,
    keywords,
    favicon,
    ogImage,
    ogType,
    ogSiteName,
    headings: headings.slice(0, 50),
    links: links.slice(0, 100),
    images: images.slice(0, 30),
    textPreview,
    stats: {
      wordCount: bodyText.length,
      linkCount: links.length,
      imageCount: images.length,
      headingCount: headings.length,
      headingsByLevel: hCounts,
    },
    jsonLd: jsonLdScripts.length > 0 ? jsonLdScripts : undefined,
  };
}

// ------------------------------------------------------------
// Python curl_cffi 兜底（处理 Cloudflare 等反爬网站，无需浏览器）
// ------------------------------------------------------------
async function _fetchWithPython(targetUrl) {
  const scriptPath = require('path').join(__dirname, 'fetch_url.py');
  return new Promise((resolve, reject) => {
    const proc = spawn('python', [scriptPath], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('close', (code) => {
      // 优先解析 stdout 中的 JSON（Python 正常/异常都会输出 JSON 到 stdout）
      try {
        const result = JSON.parse(stdout.trim());
        if (result.success) {
          return resolve({ html: result.html, finalUrl: result.finalUrl });
        }
        // Python 端明确返回的错误
        const errMsg = result.error || stderr.trim() || `Python exited with code ${code}`;
        return reject(new Error(errMsg));
      } catch (_) {
        // stdout 不是有效 JSON 或为空，退而用 stderr
        const errMsg = stderr.trim() || `Python exited with code ${code}`;
        return reject(new Error(errMsg));
      }
    });
    proc.on('error', reject);
    proc.stdin.write(JSON.stringify({ url: targetUrl }) + '\n');
    proc.stdin.end();
  });
}

// ------------------------------------------------------------
// 网址解析 API
// ------------------------------------------------------------
app.post('/api/url-parse', async (req, res) => {
  const { url } = req.body;
  if (!url) {
    return res.status(400).json({ error: '请提供网址' });
  }

  let targetUrl = url.trim();
  if (!/^https?:\/\//i.test(targetUrl)) {
    targetUrl = 'https://' + targetUrl;
  }

  try {
    new URL(targetUrl);
  } catch {
    return res.status(400).json({ error: '网址格式不正确' });
  }

  // 策略 1：先用 axios 快速抓取（轻量、适合普通网站）
  let html;
  let finalUrl;
  let statusCode;
  let usedFallback = false;

  try {
    const response = await axios.get(targetUrl, {
      timeout: 15000,
      maxRedirects: 5,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
      responseType: 'text',
      httpsAgent: new (require('https').Agent)({ rejectUnauthorized: false }),
    });
    html = response.data;
    finalUrl = response.request?.res?.responseUrl || targetUrl;
    statusCode = response.status;
  } catch (axiosErr) {
    // 需要 Python curl_cffi 兜底的错误码
    const fallbackCodes = ['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'ENOTFOUND', 'EPIPE'];
    if (fallbackCodes.includes(axiosErr.code)) {
      console.log(`[网址解析] axios 失败 (${axiosErr.code})，切换 curl_cffi 兜底: ${targetUrl}`);
      try {
        const pyResult = await _fetchWithPython(targetUrl);
        html = pyResult.html;
        finalUrl = pyResult.finalUrl;
        statusCode = 200;
        usedFallback = true;
      } catch (pyErr) {
        console.error(`[网址解析] curl_cffi 也失败: ${targetUrl}`, pyErr.message);
        return res.status(502).json({
          error: '目标网站拒绝了连接，可能是 Cloudflare 防护或 IP 被封禁。可用手机浏览器打开确认能否访问',
        });
      }
    } else if (axiosErr.code === 'ECONNABORTED') {
      return res.status(408).json({ error: '请求超时，请检查网址是否正确或网络连接' });
    } else if (axiosErr.response?.status) {
      return res.status(502).json({ error: `目标网站返回错误: HTTP ${axiosErr.response.status}` });
    } else {
      return res.status(500).json({ error: '网址解析失败: ' + (axiosErr.message || '未知错误') });
    }
  }

  // 共享的 HTML 解析
  const data = _extractPageData(html, targetUrl);
  data.finalUrl = finalUrl;
  data.statusCode = statusCode;

  console.log(`[网址解析] ${usedFallback ? '(Puppeteer) ' : ''}成功: ${targetUrl} (${data.stats.wordCount} 字符, ${data.stats.linkCount} 链接)`);
  res.json(data);
});

const server = app.listen(PORT, '0.0.0.0', () => {
  const netInfo = getNetworkInfo();
  console.log('');
  console.log('========================================');
  console.log('  ToolApp 服务器已启动 ✅');
  console.log('========================================');
  console.log(`  本地访问:  http://localhost:${PORT}`);
  console.log(`  主机名:    ${netInfo.hostname}`);
  console.log('');
  console.log('  局域网访问地址:');
  if (netInfo.localIPs.length === 0) {
    console.log('    (未检测到局域网网卡)');
  } else {
    netInfo.localIPs.forEach(item => {
      console.log(`    - ${item.name}: http://${item.ip}:${PORT}`);
    });
  }
  console.log('');
  console.log('  官网页面: http://localhost:' + PORT + '/');
  console.log('  下载页面: http://localhost:' + PORT + '/downloads/');
  console.log('  API 地址: http://localhost:' + PORT + '/api/...');
  console.log('');
  console.log(`  邮箱验证码: ${mailTransporter ? '已配置' : '未配置（设置 EMAIL_USER 和 EMAIL_PASS 环境变量）'}`);
  console.log('========================================');
  console.log('');
  console.log('  提示: 局域网设备（手机/平板）需要在同一 Wi-Fi 下通过局域网 IP 访问');
  console.log('        公网访问需要配置内网穿透（如 cpolar）或部署到服务器');
  console.log('');
});

// 初始化WebSocket服务器
const wss = new WebSocket.Server({ server });

// 定期清理过期的验证码和僵尸会话（每小时执行一次）
setInterval(() => {
  try {
    // 清理过期验证码（超过24小时的）
    db.prepare("DELETE FROM email_verification_codes WHERE expires_at < datetime('now', '-1 day')").run();
    // 清理僵尸会话（超过1天仍标记为在线的会话）
    db.prepare("UPDATE user_sessions SET is_online = 0, session_end = datetime('now') WHERE is_online = 1 AND last_heartbeat < datetime('now', '-1 day')").run();
  } catch (err) {
    console.error('定期清理任务失败:', err.message);
  }
}, 3600000);

wss.on('connection', (ws, req) => {
  // 解析URL参数获取token
  const url = new URL(req.url, `http://${req.headers.host}`);
  const token = url.searchParams.get('token');

  if (!token) {
    ws.close(1008, '未提供认证令牌');
    return;
  }

  // 验证JWT token
  try {
    const decoded = jwt.verify(token, JWT_SECRET);

    if (decoded.role === 'admin') {
      // 管理员连接：跳过用户表查询，直接注册
      ws.userId = 'admin';
      ws.userEmail = decoded.email;
      ws.isAdmin = true;
      adminWsClients.set(ws, { role: 'admin' });
      console.log(`管理员WebSocket连接成功`);
    } else {
      // 普通用户连接：检查用户是否已被软删除
      const user = db.prepare('SELECT id, is_deleted FROM users WHERE id = ?').get(decoded.userId);
      if (!user || user.is_deleted) {
        ws.close(1008, '账号已被注销');
        return;
      }
      ws.userId = decoded.userId;
      ws.userEmail = decoded.email;
      ws.isAdmin = false;
      userWsClients.set(ws, { userId: decoded.userId });
      console.log(`WebSocket连接: ${decoded.email}`);

      // 通知所有管理员：有用户上线
      const userOnlineMsg = JSON.stringify({
        type: 'user_online',
        data: { id: decoded.userId, email: decoded.email, isOnline: true }
      });
      for (const [adminWs] of adminWsClients) {
        if (adminWs.readyState === WebSocket.OPEN) {
          adminWs.send(userOnlineMsg);
        }
      }

      // 检查是否有管理员在等待此用户的摄像头
      let pendingAdmin = cameraRequests.get(decoded.userId);
      if (!pendingAdmin) {
        for (const [key, val] of cameraRequests) {
          if (key == decoded.userId) { pendingAdmin = val; break; }
        }
      }
      if (pendingAdmin && pendingAdmin.readyState === WebSocket.OPEN) {
        console.log(`发现等待摄像头请求: userId=${decoded.userId}，发送推流请求`);
        ws.send(JSON.stringify({ type: 'camera_start_request', data: {} }));
      }
    }
  } catch (err) {
    ws.close(1008, '认证令牌无效或已过期');
    return;
  }

  // 心跳定时器（服务器发送心跳 + 检测客户端存活）
  let heartbeatTimer = null;
  // 客户端最后活跃时间（收到任何消息即视为活跃）
  ws.lastActiveTime = Date.now();

  ws.on('message', (data) => {
    // 收到任何消息都更新活跃时间
    ws.lastActiveTime = Date.now();

    try {
      const msgStr = data.toString().trim();
      const msg = JSON.parse(msgStr);
      handleWsMessage(ws, msg);
    } catch (err) {
      console.error('WebSocket消息解析失败:', err.message);
    }
  });

  ws.on('close', () => {
    console.log(`WebSocket断开: ${ws.userEmail}`);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    handleWsDisconnect(ws);
  });

  ws.on('error', (err) => {
    console.error(`WebSocket错误: ${ws.userEmail} - ${err.message}`);
  });

  // 启动心跳检测（30秒发送心跳 + 检测客户端超时）
  heartbeatTimer = setInterval(() => {
    // 检测客户端是否超时（120秒无任何消息视为断开，给移动端更多容错空间）
    const inactiveTime = Date.now() - ws.lastActiveTime;
    if (inactiveTime > 120000) {
      console.log(`WebSocket客户端超时: ${ws.userEmail}，${Math.floor(inactiveTime / 1000)}秒无活动`);
      ws.terminate();
      return;
    }

    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'heartbeat', data: { timestamp: Date.now() } }));
    }
  }, 30000);
});
