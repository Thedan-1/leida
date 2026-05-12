<script setup lang="ts">
import { ElMessage } from 'element-plus'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const ack = (id: string) => {
  store.acknowledgeAlarm(id)
  ElMessage.success('告警已确认')
}
</script>

<template>
  <div class="panel">
    <div class="panel-head">
      <div class="panel-title">告警闭环管理</div>
      <el-tag type="danger">P1: {{ store.alarms.filter((item) => item.level === 'P1').length }}</el-tag>
    </div>
    <div class="panel-body">
      <el-table :data="store.alarms" border>
        <el-table-column prop="id" label="ID" width="120" />
        <el-table-column prop="title" label="告警内容" />
        <el-table-column prop="source" label="来源设备" width="180" />
        <el-table-column label="等级" width="90">
          <template #default="scope">
            <el-tag :type="scope.row.level === 'P1' ? 'danger' : scope.row.level === 'P2' ? 'warning' : 'info'">{{ scope.row.level }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="createdAt" label="发生时间" width="180" />
        <el-table-column label="状态" width="90">
          <template #default="scope">
            <el-tag :type="scope.row.acknowledged ? 'success' : 'danger'">{{ scope.row.acknowledged ? '已确认' : '未确认' }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="120">
          <template #default="scope">
            <el-button size="small" :disabled="scope.row.acknowledged" @click="ack(scope.row.id)">确认</el-button>
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>
