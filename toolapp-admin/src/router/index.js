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
    path: '/backup',
    name: 'backup',
    component: () => import('@/views/BackupView.vue'),
  },
]

const router = createRouter({
  history: createWebHashHistory(),
  routes,
})

export default router
