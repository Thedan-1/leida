<script setup lang="ts">
defineProps<{
  title?: string
}>()
</script>

<template>
  <div class="digital-twin panel">
    <div class="panel-head twin-head">
      <div class="panel-title">{{ title || '锅炉数字孪生视图' }}</div>
      <el-tag type="warning" effect="dark">Legacy 3D</el-tag>
    </div>
    <div class="twin-body">
      <iframe src="/legacy/dashboard/frontend/dashboard.html" title="锅炉数字孪生" class="twin-frame" />
      <div class="twin-overlay">
        <span class="dot" />
        原版锅炉图已融合到新总览
      </div>
    </div>
  </div>
</template>

<style scoped>
.digital-twin {
  overflow: hidden;
}

.twin-head {
  background: linear-gradient(90deg, #11306d 0%, #1d5dff 100%);
  color: #f2f7ff;
  border-bottom: none;
}

.twin-body {
  position: relative;
  height: 100%;
  min-height: 420px;
}

.twin-frame {
  width: 100%;
  height: 100%;
  min-height: 420px;
  border: none;
  background: #060b1c;
}

.twin-overlay {
  position: absolute;
  right: 12px;
  bottom: 12px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  border-radius: 999px;
  color: #deecff;
  background: #0f2049cc;
  border: 1px solid #5c87db;
  font-size: 12px;
}

.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #37d27d;
  box-shadow: 0 0 10px #37d27d;
}
</style>
