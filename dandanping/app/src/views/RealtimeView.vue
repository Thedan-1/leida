<script setup lang="ts">
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const realtimeOption = computed(() => ({
  tooltip: { trigger: 'axis' },
  legend: { data: ['温度', '压力', '流量'] },
  xAxis: { type: 'category', data: store.realtimeSeries.map((item) => item.time) },
  yAxis: [{ type: 'value', name: '温度/流量' }, { type: 'value', name: '压力', min: 1, max: 2 }],
  series: [
    { name: '温度', type: 'line', smooth: true, data: store.realtimeSeries.map((item) => item.temperature), itemStyle: { color: '#f97316' } },
    { name: '压力', type: 'line', yAxisIndex: 1, smooth: true, data: store.realtimeSeries.map((item) => item.pressure), itemStyle: { color: '#1d5dff' } },
    { name: '流量', type: 'line', smooth: true, data: store.realtimeSeries.map((item) => item.flowRate), itemStyle: { color: '#0ea5a6' } },
  ],
}))
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 12;">
      <div class="panel-body" style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px;">
        <div style="padding: 14px; border: 1px solid #dbe6f6; border-radius: 10px; background: #fff;">
          <div style="font-size: 12px; color: #6b7a92;">当前温度</div>
          <div style="font-size: 26px; font-weight: 700; color: #f97316;">{{ store.latestRealtimePoint.temperature }}°C</div>
        </div>
        <div style="padding: 14px; border: 1px solid #dbe6f6; border-radius: 10px; background: #fff;">
          <div style="font-size: 12px; color: #6b7a92;">当前压力</div>
          <div style="font-size: 26px; font-weight: 700; color: #1d5dff;">{{ store.latestRealtimePoint.pressure }} MPa</div>
        </div>
        <div style="padding: 14px; border: 1px solid #dbe6f6; border-radius: 10px; background: #fff;">
          <div style="font-size: 12px; color: #6b7a92;">循环流量</div>
          <div style="font-size: 26px; font-weight: 700; color: #0ea5a6;">{{ store.latestRealtimePoint.flowRate }} t/h</div>
        </div>
        <div style="padding: 14px; border: 1px solid #dbe6f6; border-radius: 10px; background: #fff;">
          <div style="font-size: 12px; color: #6b7a92;">电力负载</div>
          <div style="font-size: 26px; font-weight: 700; color: #7c3aed;">{{ store.latestRealtimePoint.powerLoad }}%</div>
        </div>
        <div style="padding: 14px; border: 1px solid #dbe6f6; border-radius: 10px; background: #fff; display: flex; flex-direction: column; gap: 8px;">
          <div style="font-size: 12px; color: #6b7a92;">模拟引擎</div>
          <el-space>
            <el-button size="small" type="primary" @click="store.startSimulation">启动</el-button>
            <el-button size="small" @click="store.stopSimulation">停止</el-button>
          </el-space>
          <el-tag :type="store.simulationRunning ? 'success' : 'info'">{{ store.simulationRunning ? '运行中' : '已停止' }}</el-tag>
        </div>
      </div>
    </div>

    <div class="panel" style="grid-column: span 8; min-height: 380px;">
      <div class="panel-head"><div class="panel-title">实时工况曲线（模拟）</div></div>
      <div class="panel-body"><VChart :option="realtimeOption" autoresize style="height: 310px;" /></div>
    </div>

    <div class="panel" style="grid-column: span 4; min-height: 380px;">
      <div class="panel-head"><div class="panel-title">实时事件流</div></div>
      <div class="panel-body" style="max-height: 320px; overflow: auto; display: flex; flex-direction: column; gap: 8px;">
        <div v-for="event in store.eventLogs.slice(0, 14)" :key="event.id" style="padding: 10px; border: 1px solid #e5edf9; border-radius: 8px; background: #fff;">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
            <el-tag size="small" :type="event.level === 'critical' ? 'danger' : event.level === 'warning' ? 'warning' : 'info'">{{ event.level }}</el-tag>
            <span style="font-size: 11px; color: #6b7a92;">{{ event.time }}</span>
          </div>
          <div style="font-size: 13px; color: #22314a;">{{ event.message }}</div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
@media (max-width: 980px) {
  .panel {
    grid-column: span 12 !important;
  }
}
</style>
