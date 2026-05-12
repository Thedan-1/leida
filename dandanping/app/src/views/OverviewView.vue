<script setup lang="ts">
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const realtimeOption = computed(() => {
  const points = store.realtimeSeries.slice(-24)
  return {
    backgroundColor: 'transparent',
    textStyle: { color: '#8fb8ff', fontFamily: 'Consolas' },
    tooltip: { trigger: 'axis', backgroundColor: 'rgba(10,14,26,0.95)', borderColor: '#3b82f6' },
    legend: { top: 4, textStyle: { color: '#7aa8ff' } },
    grid: { left: '8%', right: '4%', bottom: '12%', top: '18%' },
    xAxis: {
      type: 'category',
      data: points.map((item) => item.time),
      axisLine: { lineStyle: { color: 'rgba(59,130,246,0.35)' } },
      axisLabel: { color: '#7aa8ff', fontSize: 11 },
    },
    yAxis: [
      {
        type: 'value',
        name: '温度 °C',
        min: 55,
        max: 120,
        axisLine: { lineStyle: { color: '#fb923c' } },
        splitLine: { lineStyle: { color: 'rgba(59,130,246,0.14)', type: 'dashed' } },
      },
      {
        type: 'value',
        name: '压力 MPa',
        min: 0.9,
        max: 2.0,
        axisLine: { lineStyle: { color: '#38bdf8' } },
        splitLine: { show: false },
      },
    ],
    series: [
      {
        name: '炉膛温度',
        type: 'line',
        smooth: true,
        yAxisIndex: 0,
        data: points.map((item) => item.temperature),
        itemStyle: { color: '#fb923c' },
        areaStyle: { color: 'rgba(251,146,60,0.18)' },
      },
      {
        name: '管网压力',
        type: 'line',
        smooth: true,
        yAxisIndex: 1,
        data: points.map((item) => item.pressure),
        itemStyle: { color: '#38bdf8' },
        areaStyle: { color: 'rgba(56,189,248,0.15)' },
      },
    ],
  }
})

const healthOption = computed(() => ({
  backgroundColor: 'transparent',
  tooltip: { trigger: 'item', backgroundColor: 'rgba(10,14,26,0.95)', borderColor: '#3b82f6' },
  series: [
    {
      type: 'pie',
      radius: ['54%', '78%'],
      avoidLabelOverlap: false,
      label: { color: '#8fb8ff' },
      labelLine: { lineStyle: { color: '#8fb8ff' } },
      data: [
        { value: store.reports.filter((item) => item.status === 'normal').length, name: '正常', itemStyle: { color: '#22c55e' } },
        { value: store.warningCount, name: '预警', itemStyle: { color: '#f59e0b' } },
        { value: store.criticalCount, name: '严重', itemStyle: { color: '#ef4444' } },
      ],
    },
  ],
}))

const loadRate = computed(() => `${Math.round((store.latestRealtimePoint.powerLoad / 95) * 100)}%`)
</script>

<template>
  <div class="legacy-screen">
    <div class="screen-head">
      <div class="title">锅炉巡检管理系统</div>
      <div class="meta">MODE: VUE-SCADA | SIMULATION: ONLINE | TIME: {{ store.latestRealtimePoint.time }}</div>
    </div>

    <div class="dashboard-grid">
      <section class="panel">
        <header class="panel-title">核心指标</header>
        <div class="kpi-list">
          <div class="kpi-row">
            <span>巡检总数</span>
            <strong>{{ store.totalReports }}</strong>
          </div>
          <div class="kpi-row warn">
            <span>预警数量</span>
            <strong>{{ store.warningCount }}</strong>
          </div>
          <div class="kpi-row danger">
            <span>严重告警</span>
            <strong>{{ store.criticalCount }}</strong>
          </div>
          <div class="kpi-row ok">
            <span>健康率</span>
            <strong>{{ store.normalRate }}%</strong>
          </div>
          <div class="kpi-row">
            <span>负荷率</span>
            <strong>{{ loadRate }}</strong>
          </div>
        </div>
      </section>

      <section class="panel center top-center">
        <header class="panel-title">主机工况实时曲线</header>
        <VChart :option="realtimeOption" autoresize style="height: 100%;" />
      </section>

      <section class="panel">
        <header class="panel-title">设备健康分布</header>
        <VChart :option="healthOption" autoresize style="height: calc(100% - 6px);" />
      </section>

      <section class="panel">
        <header class="panel-title">告警闭环队列</header>
        <el-table :data="store.alarms.slice(0, 6)" size="small" height="100%" class="dark-table">
          <el-table-column prop="level" label="级别" width="68" />
          <el-table-column prop="title" label="内容" min-width="120" />
          <el-table-column prop="source" label="来源" min-width="100" />
          <el-table-column label="状态" width="72">
            <template #default="scope">
              <el-tag size="small" :type="scope.row.acknowledged ? 'success' : 'danger'">{{ scope.row.acknowledged ? '已确认' : '待确认' }}</el-tag>
            </template>
          </el-table-column>
        </el-table>
      </section>

      <section class="panel center middle-center">
        <header class="panel-title">联锁控制状态</header>
        <div class="link-grid">
          <div class="link-box">
            <span>急停</span>
            <b :class="store.controlState.emergencyStop ? 'danger' : 'ok'">{{ store.controlState.emergencyStop ? '已触发' : '正常' }}</b>
          </div>
          <div class="link-box">
            <span>冷却泵</span>
            <b :class="store.controlState.coolingPump ? 'ok' : 'danger'">{{ store.controlState.coolingPump ? '运行' : '停机' }}</b>
          </div>
          <div class="link-box">
            <span>泄压阀</span>
            <b :class="store.controlState.ventValve ? 'warn' : 'ok'">{{ store.controlState.ventValve ? '开启' : '关闭' }}</b>
          </div>
          <div class="link-box">
            <span>目标温度</span>
            <b>{{ store.controlState.targetTemperature }}°C</b>
          </div>
          <div class="link-box">
            <span>目标压力</span>
            <b>{{ store.controlState.targetPressure }} MPa</b>
          </div>
          <div class="link-box">
            <span>数据流</span>
            <b :class="store.simulationRunning ? 'ok' : 'danger'">{{ store.simulationRunning ? '在线' : '离线' }}</b>
          </div>
        </div>
      </section>

      <section class="panel">
        <header class="panel-title">资产健康排行</header>
        <el-table :data="store.assets" size="small" height="100%" class="dark-table">
          <el-table-column prop="name" label="设备" min-width="120" />
          <el-table-column prop="area" label="区域" width="70" />
          <el-table-column label="健康分" width="120">
            <template #default="scope">
              <el-progress
                :percentage="scope.row.healthScore"
                :stroke-width="8"
                :color="scope.row.healthScore < 70 ? '#ef4444' : scope.row.healthScore < 85 ? '#f59e0b' : '#22c55e'"
              />
            </template>
          </el-table-column>
        </el-table>
      </section>

      <section class="panel">
        <header class="panel-title">工单执行看板</header>
        <el-table :data="store.workOrders" size="small" height="100%" class="dark-table">
          <el-table-column prop="id" label="工单" width="88" />
          <el-table-column prop="title" label="任务" min-width="150" />
          <el-table-column prop="assignee" label="负责人" width="82" />
          <el-table-column label="进度" width="120">
            <template #default="scope">
              <el-progress :percentage="scope.row.progress" :stroke-width="8" />
            </template>
          </el-table-column>
        </el-table>
      </section>

      <section class="panel center">
        <header class="panel-title">应急演练与事件流</header>
        <div class="timeline-wrap">
          <div class="line-title">演练完成度</div>
          <div v-for="drill in store.drillScenarios" :key="drill.id" class="drill-row">
            <span>{{ drill.title }}</span>
            <el-progress :percentage="drill.completionRate" :stroke-width="8" style="width: 160px" />
          </div>
          <div class="line-title">实时事件</div>
          <el-timeline>
            <el-timeline-item
              v-for="log in store.eventLogs.slice(0, 4)"
              :key="log.id"
              :timestamp="log.time"
              :color="log.level === 'critical' ? '#ef4444' : log.level === 'warning' ? '#f59e0b' : '#3b82f6'"
            >
              {{ log.message }}
            </el-timeline-item>
          </el-timeline>
        </div>
      </section>

      <section class="panel">
        <header class="panel-title">工业应用功能清单</header>
        <ul class="feature-list">
          <li>联锁控制策略推演与目标参数下发</li>
          <li>异常告警分级与确认闭环追踪</li>
          <li>工单派发、执行进度与到期提醒</li>
          <li>设备健康评分与维护周期建议</li>
          <li>应急演练覆盖率与响应效率评估</li>
        </ul>
      </section>
    </div>
  </div>
</template>

<style scoped>
.legacy-screen {
  height: calc(100vh - 104px);
  min-height: 760px;
  color: #7aa8ff;
  font-family: 'Consolas', 'Courier New', 'Microsoft YaHei', monospace;
  position: relative;
}

.legacy-screen::before {
  content: '';
  position: absolute;
  inset: 0;
  background: repeating-linear-gradient(
    0deg,
    transparent,
    transparent 2px,
    rgba(59, 130, 246, 0.04) 2px,
    rgba(59, 130, 246, 0.04) 4px
  );
  pointer-events: none;
  z-index: 3;
}

.screen-head {
  height: 52px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 16px;
  margin-bottom: 8px;
  background: #0d1117;
  border: 2px solid #3b82f6;
}

.title {
  color: #3b82f6;
  font-size: 18px;
  font-weight: 700;
  letter-spacing: 1px;
}

.meta {
  color: #58a6ff;
  font-size: 12px;
}

.dashboard-grid {
  display: grid;
  grid-template-columns: 320px 1fr 320px;
  grid-template-rows: repeat(3, minmax(180px, 1fr));
  gap: 10px;
  height: calc(100% - 60px);
  position: relative;
  z-index: 1;
}

.panel {
  background: #0d1117;
  border: 2px solid #3b82f6;
  padding: 10px;
  box-shadow: inset 0 0 16px rgba(59, 130, 246, 0.14);
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.center {
  border-color: #2563eb;
}

.top-center {
  grid-row: span 2;
}

.middle-center {
  grid-row: span 1;
}

.panel-title {
  font-size: 13px;
  font-weight: 700;
  color: #3b82f6;
  border-bottom: 1px solid rgba(59, 130, 246, 0.3);
  padding-bottom: 6px;
  margin-bottom: 8px;
  text-transform: uppercase;
}

.kpi-list {
  display: grid;
  gap: 8px;
}

.kpi-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 7px 8px;
  border: 1px solid rgba(59, 130, 246, 0.24);
  background: rgba(13, 17, 23, 0.8);
  font-size: 12px;
}

.kpi-row strong {
  color: #bfdbfe;
}

.kpi-row.warn strong {
  color: #f59e0b;
}

.kpi-row.danger strong {
  color: #ef4444;
}

.kpi-row.ok strong {
  color: #22c55e;
}

.link-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
}

.link-box {
  border: 1px solid rgba(59, 130, 246, 0.24);
  padding: 8px;
  font-size: 12px;
  display: flex;
  justify-content: space-between;
}

.link-box b {
  color: #bfdbfe;
}

.link-box .ok {
  color: #22c55e;
}

.link-box .warn {
  color: #f59e0b;
}

.link-box .danger {
  color: #ef4444;
}

.timeline-wrap {
  overflow: auto;
  padding-right: 4px;
}

.line-title {
  color: #60a5fa;
  font-size: 12px;
  margin-bottom: 8px;
}

.drill-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 8px;
  font-size: 12px;
}

.feature-list {
  margin: 0;
  padding-left: 18px;
  color: #93c5fd;
  display: grid;
  gap: 8px;
  font-size: 12px;
}

:deep(.el-table),
:deep(.el-table__inner-wrapper),
:deep(.el-table th.el-table__cell),
:deep(.el-table tr),
:deep(.el-table td.el-table__cell),
:deep(.el-table::before) {
  background: transparent !important;
  color: #c7dcff;
  border-color: rgba(59, 130, 246, 0.22) !important;
}

:deep(.el-progress__text) {
  color: #c7dcff;
}

:deep(.el-timeline-item__timestamp),
:deep(.el-timeline-item__content) {
  color: #9ec3ff;
}

@media (max-width: 1460px) {
  .dashboard-grid {
    grid-template-columns: 1fr;
    grid-template-rows: auto;
    height: auto;
  }

  .panel,
  .top-center,
  .middle-center {
    grid-row: auto;
    min-height: 260px;
  }

  .legacy-screen {
    height: auto;
    min-height: 0;
  }
}
</style>
