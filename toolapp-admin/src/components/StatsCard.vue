<template>
  <el-card class="stats-card" shadow="hover" @click="$emit('click')">
    <div class="stats-card-content">
      <div class="stats-card-info">
        <div class="stats-card-label">{{ label }}</div>
        <div class="stats-card-value">{{ value }}</div>
      </div>
      <div class="stats-card-icon" :style="{ backgroundColor: iconBg }">
        <el-icon :size="28" :color="iconColor">
          <component :is="icon" />
        </el-icon>
      </div>
    </div>
  </el-card>
</template>

<script setup>
defineProps({
  label: { type: String, required: true },
  value: { type: [Number, String], required: true },
  icon: { type: String, required: true },
  iconBg: { type: String, default: '#ecf5ff' },
  iconColor: { type: String, default: '#409EFF' },
})
defineEmits(['click'])
</script>

<style scoped>
.stats-card {
  cursor: pointer;
  transition: transform 0.2s;
}
.stats-card:hover {
  transform: translateY(-2px);
}
.stats-card-content {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.stats-card-label {
  font-size: 14px;
  color: #909399;
  margin-bottom: 8px;
}
.stats-card-value {
  font-size: 28px;
  font-weight: bold;
  color: #303133;
}
.stats-card-icon {
  width: 56px;
  height: 56px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}
</style>
