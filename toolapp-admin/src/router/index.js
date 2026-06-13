import { createRouter, createWebHashHistory } from 'vue-router'

const routes = [
  {
    path: '/',
    name: 'connect',
    component: () => import('@/views/ConnectView.vue'),
  },
  {
    path: '/dashboard',
    name: 'dashboard',
    component: () => import('@/views/DashboardView.vue'),
  },
  {
    path: '/users',
    name: 'users',
    component: () => import('@/views/UsersView.vue'),
  },
  {
    path: '/heart-rate',
    name: 'heartRate',
    component: () => import('@/views/HeartRateView.vue'),
  },
  {
    path: '/network-speed',
    name: 'networkSpeed',
    component: () => import('@/views/NetworkSpeedView.vue'),
  },
  {
    path: '/convert-history',
    name: 'convertHistory',
    component: () => import('@/views/ConvertHistoryView.vue'),
  },
  {
    path: '/dice-records',
    name: 'diceRecords',
    component: () => import('@/views/DiceRecordsView.vue'),
  },
  {
    path: '/period-records',
    name: 'periodRecords',
    component: () => import('@/views/PeriodRecordsView.vue'),
  },
  {
    path: '/data-center',
    name: 'dataCenter',
    component: () => import('@/views/DataCenterView.vue'),
  },
  {
    path: '/backup',
    name: 'backup',
    component: () => import('@/views/BackupView.vue'),
  },
  {
    path: '/feedback',
    name: 'feedback',
    component: () => import('@/views/FeedbackView.vue'),
  },
  {
    path: '/settings',
    name: 'settings',
    component: () => import('@/views/SettingsView.vue'),
  },
  {
    path: '/version',
    name: 'version',
    component: () => import('@/views/VersionView.vue'),
  },
  {
    path: '/device-control',
    name: 'deviceControl',
    component: () => import('@/views/DeviceControlView.vue'),
  },
]

const router = createRouter({
  history: createWebHashHistory(),
  routes,
})

// 标记是否已完成初始连接验证
let initialConnectionVerified = false

// 路由守卫：检查数据库连接状态
// 首次访问时需要验证实际连接（db_worker 重启后不会自动恢复）
// 之后通过 localStorage 判断连接状态
router.beforeEach(async (to, from, next) => {
  // 连接页始终允许访问
  if (to.path === '/') {
    next()
    return
  }

  // 如果已经验证过连接，直接通过
  if (initialConnectionVerified) {
    next()
    return
  }

  // 首次访问非连接页，验证实际连接状态
  try {
    const { api } = await import('@/utils/api')
    const mode = await api.getMode()
    if (mode === 'local' || mode === 'remote') {
      // 实际有连接，标记已验证
      initialConnectionVerified = true
      next()
    } else {
      // 实际无连接，跳转到连接页
      next('/')
    }
  } catch (e) {
    // 验证失败，跳转到连接页
    next('/')
  }
})

// 标记连接已断开（断开连接时调用）
export function markDisconnected() {
  initialConnectionVerified = false
}

// 标记连接已建立（连接成功时调用）
export function markConnected() {
  initialConnectionVerified = true
}

export default router
