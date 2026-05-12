<script setup lang="ts">
import { reactive } from 'vue'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const localState = reactive({
  targetTemperature: store.controlState.targetTemperature,
  targetPressure: store.controlState.targetPressure,
})

const applyTarget = () => {
  store.updateControlState({
    targetTemperature: localState.targetTemperature,
    targetPressure: localState.targetPressure,
  })
}
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 5;">
      <div class="panel-head"><div class="panel-title">执行控制（模拟）</div></div>
      <div class="panel-body" style="display: flex; flex-direction: column; gap: 12px;">
        <el-switch
          :model-value="store.controlState.coolingPump"
          inline-prompt
          active-text="冷却泵开"
          inactive-text="冷却泵关"
          @change="(val:boolean) => store.updateControlState({ coolingPump: val })"
        />
        <el-switch
          :model-value="store.controlState.ventValve"
          inline-prompt
          active-text="泄压阀开"
          inactive-text="泄压阀关"
          @change="(val:boolean) => store.updateControlState({ ventValve: val })"
        />
        <el-switch
          :model-value="store.controlState.emergencyStop"
          inline-prompt
          active-text="急停启用"
          inactive-text="急停关闭"
          @change="(val:boolean) => store.updateControlState({ emergencyStop: val })"
        />

        <el-divider />

        <div>
          <div style="font-size: 13px; color: #6b7a92; margin-bottom: 6px;">目标温度</div>
          <el-slider v-model="localState.targetTemperature" :min="65" :max="110" :step="1" show-input />
        </div>
        <div>
          <div style="font-size: 13px; color: #6b7a92; margin-bottom: 6px;">目标压力</div>
          <el-slider v-model="localState.targetPressure" :min="1.0" :max="1.9" :step="0.01" show-input />
        </div>

        <el-space>
          <el-button type="primary" @click="applyTarget">应用目标值</el-button>
          <el-button type="danger" @click="store.runEmergencyProtocol">一键应急处置</el-button>
        </el-space>
      </div>
    </div>

    <div class="panel" style="grid-column: span 7;">
      <div class="panel-head"><div class="panel-title">控制指令日志</div></div>
      <div class="panel-body">
        <el-table :data="store.commandHistory.slice(0, 20)" border>
          <el-table-column prop="time" label="时间" width="180" />
          <el-table-column label="级别" width="100">
            <template #default="scope">
              <el-tag :type="scope.row.level === 'critical' ? 'danger' : scope.row.level === 'warning' ? 'warning' : 'info'">{{ scope.row.level }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="message" label="日志内容" />
        </el-table>
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
