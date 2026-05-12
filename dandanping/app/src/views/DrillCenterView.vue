<script setup lang="ts">
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 8;">
      <div class="panel-head"><div class="panel-title">应急演练任务库（模拟）</div></div>
      <div class="panel-body">
        <el-table :data="store.drillScenarios" border>
          <el-table-column prop="id" label="编号" width="100" />
          <el-table-column prop="title" label="演练主题" />
          <el-table-column prop="category" label="类别" width="100" />
          <el-table-column prop="level" label="等级" width="80" />
          <el-table-column prop="durationMinutes" label="时长(分钟)" width="110" />
          <el-table-column label="完成率" width="190">
            <template #default="scope">
              <el-slider
                :model-value="scope.row.completionRate"
                :min="0"
                :max="100"
                @change="(val:number) => store.updateDrillProgress(scope.row.id, val)"
              />
            </template>
          </el-table-column>
        </el-table>
      </div>
    </div>

    <div class="panel" style="grid-column: span 4;">
      <div class="panel-head"><div class="panel-title">演练完成看板</div></div>
      <div class="panel-body" style="display: flex; flex-direction: column; gap: 12px;">
        <div v-for="item in store.drillScenarios" :key="item.id" style="padding: 12px; border: 1px solid #e6eef9; border-radius: 10px; background: #fff;">
          <div style="display: flex; justify-content: space-between; margin-bottom: 6px;">
            <strong>{{ item.title }}</strong>
            <el-tag size="small">{{ item.level }}</el-tag>
          </div>
          <el-progress :percentage="item.completionRate" :status="item.completionRate >= 85 ? 'success' : undefined" />
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
