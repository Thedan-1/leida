<script setup lang="ts">
import { computed, ref } from 'vue'
import dayjs from 'dayjs'
import HealthTag from '../components/HealthTag.vue'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()
const keyword = ref('')
const status = ref<'all' | 'normal' | 'warning' | 'critical'>('all')
const page = ref(1)
const pageSize = ref(8)

const filtered = computed(() =>
  store.reports.filter((item) => {
    const hitKeyword = [item.location, item.inspector, item.issue].join(' ').includes(keyword.value)
    const hitStatus = status.value === 'all' ? true : item.status === status.value
    return hitKeyword && hitStatus
  }),
)

const paged = computed(() => {
  const start = (page.value - 1) * pageSize.value
  return filtered.value.slice(start, start + pageSize.value)
})
</script>

<template>
  <div class="panel">
    <div class="panel-head">
      <div class="panel-title">巡检报告中心</div>
      <el-space>
        <el-input v-model="keyword" placeholder="搜索位置/人员/问题" clearable style="width: 260px;" />
        <el-select v-model="status" style="width: 130px;">
          <el-option label="全部" value="all" />
          <el-option label="正常" value="normal" />
          <el-option label="警告" value="warning" />
          <el-option label="告警" value="critical" />
        </el-select>
      </el-space>
    </div>

    <div class="panel-body">
      <el-table :data="paged" border>
        <el-table-column prop="id" label="记录号" width="120" />
        <el-table-column label="时间" width="180">
          <template #default="scope">{{ dayjs(scope.row.time).format('YYYY-MM-DD HH:mm') }}</template>
        </el-table-column>
        <el-table-column prop="inspector" label="检查员" width="100" />
        <el-table-column prop="location" label="位置" width="120" />
        <el-table-column prop="temperature" label="温度" width="90" />
        <el-table-column prop="pressure" label="压力" width="90" />
        <el-table-column label="状态" width="90">
          <template #default="scope"><HealthTag :status="scope.row.status" /></template>
        </el-table-column>
        <el-table-column prop="issue" label="问题描述" />
      </el-table>

      <div style="display: flex; justify-content: end; margin-top: 14px;">
        <el-pagination
          v-model:current-page="page"
          v-model:page-size="pageSize"
          layout="total, sizes, prev, pager, next"
          :total="filtered.length"
          :page-sizes="[8, 15, 30]"
        />
      </div>
    </div>
  </div>
</template>
