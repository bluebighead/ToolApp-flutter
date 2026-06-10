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
    path: '/data-center',
    name: 'dataCenter',
    component: () => import('@/views/DataCenterView.vue'),
  },
  {
    path: '/online-monitor',
    name: 'onlineMonitor',
    component: () => import('@/views/OnlineMonitorView.vue'),
  },
  {
    path: '/backup',
    name: 'backup',
    component: () => import('@/views/BackupView.vue'),
  },
  {
    path: '/settings',
    name: 'settings',
    component: () => import('@/views/SettingsView.vue'),
  },
]

const router = createRouter({
  history: createWebHashHistory(),
  routes,
})

export default router
