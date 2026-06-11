<template>
  <AppLayout>
    <div class="dashboard">
      <h2 class="page-title">仪表盘</h2>

      <!-- 统计卡片 -->
      <el-row :gutter="20" class="stats-row">
        <el-col :span="4">
          <StatsCard label="用户数" :value="stats.users" icon="User" iconBg="#ecf5ff" iconColor="#409EFF" @click="$router.push('/users')" />
        </el-col>
        <el-col :span="4">
          <StatsCard label="心率记录" :value="stats.heartRate" icon="Monitor" iconBg="#f0f9eb" iconColor="#67C23A" @click="$router.push('/heart-rate')" />
        </el-col>
        <el-col :span="4">
          <StatsCard label="网速记录" :value="stats.networkSpeed" icon="Connection" iconBg="#fdf6ec" iconColor="#E6A23C" @click="$router.push('/network-speed')" />
        </el-col>
        <el-col :span="4">
          <StatsCard label="转换记录" :value="stats.convert" icon="VideoCamera" iconBg="#fef0f0" iconColor="#F56C6C" @click="$router.push('/convert-history')" />
        </el-col>
        <el-col :span="4">
          <StatsCard label="骰子记录" :value="stats.dice" icon="Coin" iconBg="#f4f4f5" iconColor="#909399" @click="$router.push('/dice-records')" />
        </el-col>
        <el-col :span="4">
          <StatsCard label="经期记录" :value="stats.period" icon="Calendar" iconBg="#fdf2f8" iconColor="#EC4899" @click="$router.push('/period-records')" />
        </el-col>
      </el-row>

      <!-- 图表区域 -->
      <el-row :gutter="20" class="charts-row">
        <el-col :span="16">
          <el-card shadow="hover">
            <template #header>数据分布</template>
            <div ref="barChartRef" style="height: 320px;"></div>
          </el-card>
        </el-col>
        <el-col :span="8">
          <el-card shadow="hover">
            <template #header>模块数据占比</template>
            <div ref="pieChartRef" style="height: 320px;"></div>
          </el-card>
        </el-col>
      </el-row>

      <!-- 最近注册用户 -->
      <el-card shadow="hover" class="recent-card">
        <template #header>最近注册用户</template>
        <el-table :data="recentUsers" stripe style="width: 100%">
          <el-table-column prop="id" label="ID" width="80" />
          <el-table-column prop="email" label="邮箱" />
          <el-table-column prop="created_at" label="注册时间" />
        </el-table>
      </el-card>
    </div>
  </AppLayout>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount, nextTick } from 'vue'
import * as echarts from 'echarts'
import AppLayout from '@/components/AppLayout.vue'
import StatsCard from '@/components/StatsCard.vue'
import { api } from '@/utils/api'

const stats = ref({
  users: 0,
  heartRate: 0,
  networkSpeed: 0,
  convert: 0,
  dice: 0,
  period: 0,
})
const recentUsers = ref([])
const barChartRef = ref(null)
const pieChartRef = ref(null)

// 保存echarts实例，用于resize和销毁
let barChartInstance = null
let pieChartInstance = null

onMounted(async () => {
  await loadStats()
  await nextTick()
  renderCharts()
  // 监听窗口resize，自动调整图表大小
  window.addEventListener('resize', handleResize)
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', handleResize)
  // 销毁echarts实例，防止内存泄漏
  if (barChartInstance) {
    barChartInstance.dispose()
    barChartInstance = null
  }
  if (pieChartInstance) {
    pieChartInstance.dispose()
    pieChartInstance = null
  }
})

function handleResize() {
  barChartInstance?.resize()
  pieChartInstance?.resize()
}

async function loadStats() {
  try {
    stats.value = await api.getStats()
  } catch (err) {
    console.error('加载统计失败:', err)
  }

  try {
    const result = await api.getUsers({ page: 1, pageSize: 5 })
    recentUsers.value = result.rows || []
  } catch (err) {
    console.error('加载用户失败:', err)
  }
}

function renderCharts() {
  // 柱状图 - 数据分布
  if (barChartRef.value) {
    barChartInstance = echarts.init(barChartRef.value)
    barChartInstance.setOption({
      tooltip: { trigger: 'axis' },
      xAxis: {
        type: 'category',
        data: ['心率', '网速', '转换', '骰子', '经期'],
      },
      yAxis: { type: 'value' },
      series: [{
        type: 'bar',
        data: [
          stats.value.heartRate,
          stats.value.networkSpeed,
          stats.value.convert,
          stats.value.dice,
          stats.value.period,
        ],
        itemStyle: {
          color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
            { offset: 0, color: '#409EFF' },
            { offset: 1, color: '#79bbff' },
          ]),
        },
      }],
    })
  }

  // 饼图 - 模块数据占比
  if (pieChartRef.value) {
    pieChartInstance = echarts.init(pieChartRef.value)
    pieChartInstance.setOption({
      tooltip: { trigger: 'item' },
      series: [{
        type: 'pie',
        radius: ['40%', '70%'],
        data: [
          { value: stats.value.heartRate, name: '心率' },
          { value: stats.value.networkSpeed, name: '网速' },
          { value: stats.value.convert, name: '转换' },
          { value: stats.value.dice, name: '骰子' },
          { value: stats.value.period, name: '经期' },
        ],
      }],
    })
  }
}
</script>

<style scoped>
.page-title {
  margin-bottom: 20px;
  color: #303133;
}
.stats-row {
  margin-bottom: 20px;
}
.charts-row {
  margin-bottom: 20px;
}
.recent-card {
  margin-bottom: 20px;
}
</style>
