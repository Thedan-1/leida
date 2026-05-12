<script setup lang="ts">
import { reactive } from 'vue'
import { ElMessage } from 'element-plus'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const form = reactive({
  title: '',
  assignee: '',
  priority: 'medium' as 'high' | 'medium' | 'low',
})

const submit = () => {
  if (!form.title || !form.assignee) {
    ElMessage.warning('请补全工单标题和责任人')
    return
  }
  store.addWorkOrder(form.title, form.assignee, form.priority)
  form.title = ''
  form.assignee = ''
  form.priority = 'medium'
  ElMessage.success('工单已创建')
}
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 4;">
      <div class="panel-head"><div class="panel-title">创建工单</div></div>
      <div class="panel-body">
        <el-form label-position="top">
          <el-form-item label="工单标题"><el-input v-model="form.title" placeholder="例如：更换阀组密封圈" /></el-form-item>
          <el-form-item label="责任人"><el-input v-model="form.assignee" placeholder="例如：张工" /></el-form-item>
          <el-form-item label="优先级">
            <el-segmented v-model="form.priority" :options="[{ label: '高', value: 'high' }, { label: '中', value: 'medium' }, { label: '低', value: 'low' }]" />
          </el-form-item>
          <el-button type="primary" style="width: 100%;" @click="submit">创建工单</el-button>
        </el-form>
      </div>
    </div>

    <div class="panel" style="grid-column: span 8;">
      <div class="panel-head"><div class="panel-title">工单执行看板</div></div>
      <div class="panel-body">
        <el-table :data="store.workOrders" border>
          <el-table-column prop="id" label="工单号" width="110" />
          <el-table-column prop="title" label="任务" />
          <el-table-column prop="assignee" label="责任人" width="90" />
          <el-table-column label="优先级" width="90">
            <template #default="scope">
              <el-tag :type="scope.row.priority === 'high' ? 'danger' : scope.row.priority === 'medium' ? 'warning' : 'info'">{{ scope.row.priority }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="进度" width="210">
            <template #default="scope">
              <div style="display: flex; align-items: center; gap: 10px;">
                <el-slider :model-value="scope.row.progress" :min="0" :max="100" style="width: 130px;" @change="(val:number) => store.updateWorkOrderProgress(scope.row.id, val)" />
                <span>{{ scope.row.progress }}%</span>
              </div>
            </template>
          </el-table-column>
          <el-table-column prop="dueDate" label="截止日期" width="110" />
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
