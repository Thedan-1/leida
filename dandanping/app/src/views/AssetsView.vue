<script setup lang="ts">
import VChart from 'vue-echarts'
import { ref, computed } from 'vue'
import HealthTag from '../components/HealthTag.vue'
import { useDashboardStore } from '../stores/dashboard'
import type { Asset } from '../types'
import * as echarts from 'echarts/core'

const store = useDashboardStore()

const detailDrawer = ref(false)
const selectedAsset = ref<Asset | null>(null)

const handleRowClick = (row: Asset) => {
  selectedAsset.value = row
  detailDrawer.value = true
}

const historyOption = computed(() => {
  if (!selectedAsset.value) return {}
  return {
    tooltip: { trigger: 'axis' },
    legend: { textStyle: { color: '#8892b0' } },
    xAxis: {
      type: 'category',
      data: Array.from({ length: 10 }, (_, i) => `T-${10 - i}h`),
      axisLabel: { color: '#8892b0' }
    },
    yAxis: [
      { type: 'value', name: '温度(°C)', splitLine: { lineStyle: { color: 'rgba(255,255,255,0.05)' } } },
      { type: 'value', name: '压力(MPa)', position: 'right', splitLine: { show: false } }
    ],
    series: [
      {
        name: '温度',
        type: 'line',
        itemStyle: { color: '#f39c12' },
        smooth: true,
        data: Array.from({ length: 10 }, () => 40 + Math.random() * 20),
      },
      {
        name: '压力',
        type: 'line',
        yAxisIndex: 1,
        itemStyle: { color: '#0ea5a6' },
        smooth: true,
        data: Array.from({ length: 10 }, () => 0.5 + Math.random() * 0.5),
      }
    ]
  }
})

const healthOption = computed(() => ({
  xAxis: { type: 'category', data: store.assets.map((item) => item.name) },
  yAxis: { type: 'value', max: 100 },
  tooltip: { trigger: 'axis' },
  series: [{ type: 'bar', data: store.assets.map((item) => item.healthScore), itemStyle: { color: '#0ea5a6' } }],
}))
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 7;">
      <div class="panel-head"><div class="panel-title">设备资产清单</div></div>
      <div class="panel-body">
        <el-table :data="store.assets" border @row-click="handleRowClick" highlight-current-row style="cursor: pointer;">
          <el-table-column prop="id" label="资产ID" width="100" />
          <el-table-column prop="name" label="设备名称" width="180" />
          <el-table-column prop="area" label="区域" width="70" />
          <el-table-column prop="type" label="类型" width="100" />
          <el-table-column prop="runtimeHours" label="累计工时" width="100" />
          <el-table-column prop="lastMaintenance" label="上次维护" width="120" />
          <el-table-column label="状态" width="90">
            <template #default="scope"><HealthTag :status="scope.row.status" /></template>
          </el-table-column>
        </el-table>
      </div>
    </div>

    <div class="panel" style="grid-column: span 5;">
      <div class="panel-head"><div class="panel-title">设备健康评分</div></div>
      <div class="panel-body">
        <VChart :option="healthOption" autoresize style="height: 320px;" />
      </div>
    </div>
  </div>

  <el-drawer v-model="detailDrawer" :title="`${selectedAsset?.name || ''} - 设备数字档案`" size="45%" direction="rtl" destroy-on-close class="custom-drawer">
    <div v-if="selectedAsset" class="drawer-content">
      <el-descriptions border :column="2" class="mb-4">
        <el-descriptions-item label="设备类型">{{ selectedAsset.type }}</el-descriptions-item>
        <el-descriptions-item label="安装区域">{{ selectedAsset.area }}</el-descriptions-item>
        <el-descriptions-item label="工时统计">{{ selectedAsset.runtimeHours }} 小时</el-descriptions-item>
        <el-descriptions-item label="上次维保">{{ selectedAsset.lastMaintenance }}</el-descriptions-item>
        <el-descriptions-item label="供应商">西门子(示例)</el-descriptions-item>
        <el-descriptions-item label="健康得分"><span style="color:#0ea5a6; font-weight:bold;">{{ selectedAsset.healthScore }} 分</span></el-descriptions-item>
      </el-descriptions>

      <div class="panel" style="margin-top: 20px;">
        <div class="panel-head"><div class="panel-title">近10小时工况曲线</div></div>
        <div class="panel-body">
          <VChart :option="historyOption" autoresize style="height: 250px;" />
        </div>
      </div>
      
      <div class="panel" style="margin-top: 20px;">
        <div class="panel-head"><div class="panel-title">维保记录</div></div>
        <div class="panel-body">
          <el-timeline>
            <el-timeline-item
              v-for="(activity, index) in 3"
              :key="index"
              :timestamp="`2026-03-0${9 - index}`"
              placement="top"
              type="primary">
              <el-card>
                <h4>{{ ['季度大修', '更换滤网', '常规润滑'][index] }}</h4>
                <p>负责人：操作员{{ index + 1 }} - 处理情况：正常完成</p>
              </el-card>
            </el-timeline-item>
          </el-timeline>
        </div>
      </div>
    </div>
  </el-drawer>
</template>

<style scoped>
@media (max-width: 980px) {
  .panel {
    grid-column: span 12 !important;
  }
}
.drawer-content {
  padding: 0 10px;
}
.custom-drawer .el-drawer__header {
  color: #ccd6f6 !important;
  border-bottom: 1px solid rgba(255,255,255,0.05);
}
.custom-drawer .el-descriptions__label {
  background-color: #0b1a29;
  color: #ccd6f6;
}
.custom-drawer .el-descriptions__content {
  background-color: #112240;
  color: #8892b0;
}
.custom-drawer .el-card {
  background-color: #112240;
  color: #ccd6f6;
  border: 1px solid rgba(14, 165, 166, 0.2);
}
</style>
