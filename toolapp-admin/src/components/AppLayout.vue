<template>
  <el-container class="app-layout">
    <!-- 侧边栏 -->
    <el-aside :width="isCollapsed ? '64px' : '220px'" class="sidebar">
      <div class="sidebar-header">
        <span v-if="!isCollapsed" class="sidebar-title">ToolApp Admin</span>
        <span v-else class="sidebar-title-short">TA</span>
      </div>
      <el-menu
        :default-active="activeMenu"
        :collapse="isCollapsed"
        background-color="#304156"
        text-color="#bfcbd9"
        active-text-color="#409EFF"
        router
      >
        <el-menu-item index="/dashboard">
          <el-icon><DataAnalysis /></el-icon>
          <template #title>仪表盘</template>
        </el-menu-item>
        <el-menu-item index="/users">
          <el-icon><User /></el-icon>
          <template #title>用户管理</template>
        </el-menu-item>
        <el-menu-item index="/data-center">
          <el-icon><Coin /></el-icon>
          <template #title>数据中心</template>
        </el-menu-item>
        <el-menu-item index="/online-monitor">
          <el-icon><Monitor /></el-icon>
          <template #title>在线监控</template>
        </el-menu-item>
        <el-divider v-if="!isCollapsed" content-position="left">系统工具</el-divider>
        <el-menu-item index="/backup">
          <el-icon><FolderOpened /></el-icon>
          <template #title>数据备份</template>
        </el-menu-item>
        <el-menu-item index="/settings">
          <el-icon><Setting /></el-icon>
          <template #title>系统设置</template>
        </el-menu-item>
      </el-menu>
    </el-aside>

    <!-- 主内容区 -->
    <el-container>
      <el-header class="app-header">
        <el-icon class="collapse-btn" @click="isCollapsed = !isCollapsed">
          <Fold v-if="!isCollapsed" />
          <Expand v-else />
        </el-icon>
        <div class="header-right">
          <el-tag :type="connectionStore.mode === 'local' ? 'success' : 'warning'" size="small">
            {{ connectionStore.mode === 'local' ? '本地模式' : '远程模式' }}
          </el-tag>
          <el-button text @click="handleDisconnect">
            <el-icon><SwitchButton /></el-icon>
            断开
          </el-button>
        </div>
      </el-header>
      <el-main class="app-main">
        <slot />
      </el-main>
    </el-container>
  </el-container>
</template>

<script setup>
import { ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useConnectionStore } from '@/stores/connection'
import { markDisconnected } from '@/router'

const route = useRoute()
const router = useRouter()
const connectionStore = useConnectionStore()
const isCollapsed = ref(false)

const activeMenu = computed(() => route.path)

async function handleDisconnect() {
  await connectionStore.disconnect()
  markDisconnected()
  router.push('/')
}
</script>

<style scoped>
.app-layout {
  height: 100vh;
}
.sidebar {
  background-color: #304156;
  transition: width 0.3s;
  overflow: hidden;
}
.sidebar-header {
  height: 60px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-size: 18px;
  font-weight: bold;
  border-bottom: 1px solid #3a4a5b;
}
.sidebar-title {
  white-space: nowrap;
}
.sidebar-title-short {
  font-size: 20px;
}
.app-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid #e6e6e6;
  background: #fff;
  padding: 0 20px;
}
.collapse-btn {
  font-size: 20px;
  cursor: pointer;
  color: #606266;
}
.collapse-btn:hover {
  color: #409EFF;
}
.header-right {
  display: flex;
  align-items: center;
  gap: 12px;
}
.app-main {
  background: #f5f7fa;
  padding: 20px;
  overflow-y: auto;
}
.el-divider {
  margin: 8px 16px;
  border-color: #3a4a5b;
}
:deep(.el-divider__text) {
  color: #7a8a9b;
  font-size: 12px;
  background-color: #304156;
}
</style>
