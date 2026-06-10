# ToolApp Admin - PC 桌面端数据库管理软件设计文档

## 概述

ToolApp Admin 是一款 PC 桌面端数据库管理软件，用于联动 ToolApp 移动端应用，提供用户数据查看、管理、统计和备份功能。

## 技术栈

- **框架**：Electron + Vue 3
- **UI 库**：Element Plus
- **图表**：ECharts
- **状态管理**：Pinia
- **构建工具**：Vite
- **数据库驱动**：better-sqlite3（本地模式）
- **HTTP 客户端**：axios（远程模式）

## 整体架构

```
┌─────────────────────────────────────────────┐
│           ToolApp Admin (Electron)           │
├──────────────┬──────────────────────────────┤
│  主进程(Main) │  渲染进程(Renderer - Vue 3)   │
│              │                              │
│ - SQLite读取  │ - Element Plus UI            │
│ - HTTP API   │ - ECharts 图表               │
│ - IPC桥接    │ - Vue Router 路由            │
│ - 文件导出    │ - Pinia 状态管理             │
└──────────────┴──────────────────────────────┘
         │                    │
         ▼                    ▼
   ┌──────────┐      ┌──────────────┐
   │ SQLite   │      │ ToolApp      │
   │ 数据库文件 │      │ Server API   │
   └──────────┘      └──────────────┘
```

### 数据连接双模式

1. **本地模式**：主进程通过 better-sqlite3 直接读取 `toolapp-server/data/toolapp.db`
2. **远程模式**：主进程通过 HTTP 请求连接运行中的 ToolApp Server API

## 项目结构

```
ToolApp/toolapp-admin/
├── electron/                # Electron 主进程
│   ├── main.js              # 主入口：窗口创建、IPC 注册
│   ├── preload.js           # IPC 桥接：暴露安全 API 给渲染进程
│   └── db.js                # 数据库连接管理（本地 SQLite + 远程 HTTP）
├── src/                     # Vue 3 渲染进程
│   ├── views/               # 页面组件
│   │   ├── ConnectView.vue  # 连接配置页
│   │   ├── DashboardView.vue # 仪表盘
│   │   ├── UsersView.vue    # 用户管理
│   │   ├── HeartRateView.vue # 心率数据
│   │   ├── NetworkSpeedView.vue # 网速数据
│   │   ├── ConvertHistoryView.vue # 转换历史
│   │   ├── DiceRecordsView.vue # 骰子记录
│   │   ├── PeriodRecordsView.vue # 经期记录
│   │   └── BackupView.vue   # 数据备份
│   ├── components/          # 通用组件
│   │   ├── AppLayout.vue    # 主布局（侧边栏+内容区）
│   │   ├── StatsCard.vue    # 统计卡片
│   │   └── DataFilter.vue   # 数据筛选器
│   ├── stores/              # Pinia 状态
│   │   ├── connection.js    # 连接状态
│   │   └── data.js          # 数据缓存
│   ├── router/              # 路由配置
│   │   └── index.js
│   └── utils/               # 工具函数
│       └── api.js           # IPC 调用封装
├── package.json
└── vite.config.js
```

## 页面与功能模块

### 页面列表

| 页面 | 路由 | 功能 |
|------|------|------|
| 连接配置 | `/` | 选择本地/远程模式，配置数据库路径或服务器地址，测试连接 |
| 仪表盘 | `/dashboard` | 总览统计：用户数、各模块数据量、最近活动、趋势图表 |
| 用户管理 | `/users` | 用户列表、搜索、查看详情、删除用户 |
| 心率数据 | `/heart-rate` | 心率记录表格、按用户筛选、查看采样数据详情 |
| 网速数据 | `/network-speed` | 网速测试记录、延迟/抖动/丢包率数据 |
| 转换历史 | `/convert-history` | 视频转换记录、状态/格式筛选 |
| 骰子记录 | `/dice-records` | 骰子投掷记录、按类型筛选 |
| 经期记录 | `/period-records` | 经期记录、症状/流量筛选 |
| 数据备份 | `/backup` | 数据库备份/恢复、CSV/Excel 导出 |

### 侧边栏导航

```
📊 仪表盘
👥 用户管理
--------- 数据管理 ---------
❤️ 心率数据
🌐 网速数据
🎬 转换历史
🎲 骰子记录
🌸 经期记录
--------- 系统工具 ---------
💾 数据备份
⚙️ 连接配置
```

## 数据模型

### 现有数据库表（与 toolapp-server 共享）

- **users**：id, email, password_hash, created_at
- **heart_rate_sessions**：id, user_id, start_time, end_time, max_hr, min_hr, avg_hr, samples, connection_mode
- **network_speed_records**：id, user_id, test_time, server_url, min_latency, avg_latency, max_latency, jitter, loss_rate
- **convert_history**：id, user_id, input_file, output_file, output_size, format, quality, status, timestamp_ms
- **dice_records**：id, user_id, dice_type, result, timestamp_ms
- **period_records**：id, user_id, start_date, end_date, record_mode, flow_level, symptoms, notes, local_id

### 远程模式新增管理端 API

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/admin/stats` | GET | 全局统计（用户数、各表数据量） |
| `/api/admin/users` | GET | 用户列表（分页、搜索） |
| `/api/admin/users/:id` | DELETE | 删除用户及其所有数据 |
| `/api/admin/:table` | GET | 查询指定表数据（分页、筛选） |
| `/api/admin/:table/:id` | PUT/DELETE | 编辑/删除单条记录 |
| `/api/admin/backup` | GET | 下载数据库备份 |
| `/api/admin/export/:table` | GET | 导出指定表为 CSV |

管理端使用独立的管理员密码认证，不依赖用户 JWT。

## IPC 通信接口

渲染进程通过 preload.js 暴露的 API 与主进程通信：

```js
window.api = {
  // 连接管理
  connectLocal(dbPath),              // 连接本地数据库
  connectRemote(serverUrl, password), // 连接远程服务器
  testConnection(),                  // 测试连接
  disconnect(),                      // 断开连接

  // 数据查询
  getStats(),                        // 获取全局统计
  getUsers(params),                  // 获取用户列表（分页、搜索）
  getTableData(table, params),       // 获取表数据（分页、筛选）
  updateRecord(table, id, data),     // 更新记录
  deleteRecord(table, id),           // 删除记录
  deleteUser(userId),                // 删除用户及其所有数据

  // 导出备份
  exportTable(table, format),        // 导出表数据（csv/json）
  backupDatabase(),                  // 备份数据库文件
  restoreDatabase(filePath),         // 从文件恢复数据库
}
```

## UI 设计

### 整体风格

- 配色：深色侧边栏 + 浅色内容区，主色调蓝色系（#409EFF）
- 布局：左侧固定侧边栏（可折叠）+ 顶部标题栏 + 右侧内容区
- 字体：系统默认字体，中文优先

### 仪表盘

- 顶部：4 个统计卡片（用户数、心率记录数、网速记录数、转换记录数）
- 中部左：数据增长趋势折线图（近 7/30 天）
- 中部右：模块数据占比饼图
- 底部：最近活动列表

### 数据表格页

- 顶部：标题 + 搜索框 + 筛选下拉
- 中部：Element Plus el-table，支持分页、排序
- 操作列：编辑按钮、删除按钮
- 批量操作：多选后可批量删除或导出

## 核心交互流程

1. 启动应用 → 连接配置页 → 选择本地/远程模式 → 测试连接 → 连接成功进入仪表盘
2. 仪表盘 → 查看全局统计 → 点击卡片跳转对应数据页
3. 用户管理 → 搜索/筛选 → 查看用户详情 → 删除用户
4. 数据页 → 按用户筛选 → 查看/编辑/删除记录 → 导出数据
5. 数据备份 → 备份数据库/导出表 → 恢复数据库

## 错误处理

- 连接失败：显示错误提示，引导用户检查配置
- 数据库文件不存在：提示选择正确的数据库路径
- 远程服务器不可达：提示检查服务器地址和网络
- 操作确认：删除操作需二次确认
