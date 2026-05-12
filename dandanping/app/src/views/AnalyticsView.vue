<script setup lang="ts">
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const byInspector = computed(() => {
  const map = new Map<string, number>()
  store.reports.forEach((item) => map.set(item.inspector, (map.get(item.inspector) ?? 0) + 1))
  return Array.from(map.entries())
})

const inspectorOption = computed(() => ({
  tooltip: { trigger: 'axis' },
  xAxis: { type: 'category', data: byInspector.value.map((item) => item[0]) },
  yAxis: { type: 'value' },
  series: [{ type: 'bar', data: byInspector.value.map((item) => item[1]), itemStyle: { color: '#1d5dff' } }],
}))

const riskRadarOption = computed(() => ({
  radar: {
    indicator: [
      { name: '温度风险', max: 100 },
      { name: '压力风险', max: 100 },
      { name: '巡检覆盖', max: 100 },
      { name: '告警闭环', max: 100 },
      { name: '维护及时性', max: 100 },
    ],
  },
  series: [{ type: 'radar', data: [{ value: [72, 65, 88, 61, 76], name: '当前状态' }] }],
}))
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 7;">
      <div class="panel-head"><div class="panel-title">人员巡检工作量分析</div></div>
      <div class="panel-body">
        <VChart :option="inspectorOption" autoresize style="height: 320px;" />
      </div>
    </div>

    <div class="panel" style="grid-column: span 5;">
      <div class="panel-head"><div class="panel-title">工业风险雷达</div></div>
      <div class="panel-body">
        <VChart :option="riskRadarOption" autoresize style="height: 320px;" />
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
