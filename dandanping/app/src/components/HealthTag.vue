<script setup lang="ts">
import type { HealthStatus } from '../types'

defineProps<{ status: HealthStatus }>()
</script>

<template>
  <el-tag v-if="status === 'normal'" type="success">正常</el-tag>
  <el-tag v-else-if="status === 'warning'" type="warning">警告</el-tag>
  <el-tag v-else type="danger">告警</el-tag>
</template>
