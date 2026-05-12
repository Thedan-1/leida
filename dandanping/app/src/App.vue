<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Box, Connection, DataAnalysis, DataBoard, Document, Monitor, Operation, Setting, Warning } from '@element-plus/icons-vue'

const route = useRoute()
const router = useRouter()
const mobileMenuVisible = ref(false)

const menuItems = [
  { index: '/legacy', label: '原版大屏', icon: Monitor },
  { index: '/overview', label: '工业总览', icon: DataBoard },
  { index: '/realtime', label: '实时监测', icon: DataBoard },
  { index: '/alarms', label: '告警中心', icon: Warning },
  { index: '/workorders', label: '工单中心', icon: Operation },
  { index: '/command', label: '控制中心', icon: Connection },
  { index: '/drills', label: '演练预案', icon: Box },
  { index: '/reports', label: '巡检报表', icon: Document },
  { index: '/assets', label: '资产台账', icon: Box },
  { index: '/analytics', label: '趋势分析', icon: DataAnalysis },
  { index: '/settings', label: '系统设置', icon: Setting },
]

const activePath = computed(() => route.path)

const onSelect = (path: string) => {
  router.push(path)
  mobileMenuVisible.value = false
}
</script>

<template>
  <el-container class="app-shell sci-fi-theme">
    <!-- Vue UI 层：导航栏和主体部分 -->
    <aside class="app-aside desktop-only sci-fi-aside">
      <div class="brand-block sci-fi-brand">
        <h1 class="glow-text">锅炉巡检管理系统</h1>
        <p>BOILER INSPECTION SCADA</p>
      </div>
      <el-menu :default-active="activePath" class="app-menu sci-fi-menu" @select="onSelect">
        <el-menu-item v-for="item in menuItems" :key="item.index" :index="item.index">
          <el-icon><component :is="item.icon" /></el-icon>
          <span>{{ item.label }}</span>
        </el-menu-item>
      </el-menu>
      <div class="user-info">
        <div class="user-avatar">OP</div>
        <div>
          <div class="user-name">值班工程师</div>
          <div class="user-role">ROLE: OPERATOR</div>
        </div>
      </div>
    </aside>

    <el-container>
      <!-- Header -->
      <el-header class="top-bar sci-fi-header">
        <div class="left-actions">
          <el-button class="mobile-only" type="primary" plain @click="mobileMenuVisible = true">菜单</el-button>
          <h2 class="header-title">{{ route.meta.title || '原版大屏' }}</h2>
        </div>
        <div class="right-meta">
          <span class="status-indicator"></span>
          <span class="status-text">系统运行中</span>
          <el-tag effect="dark" type="primary" class="sci-fi-tag">VUE + PINIA + ECHARTS</el-tag>
        </div>
      </el-header>

      <!-- Vue 容器层 -->
      <el-main class="main-view sci-fi-main">
        <router-view />
      </el-main>
    </el-container>
  </el-container>
</template>

<style>
/* 全局强力的工业科技感样式 */
.sci-fi-theme {
  height: 100vh;
  overflow: hidden;
  background: #0a0e1a;
  color: #e2e8f0;
  font-family: 'Consolas', 'Courier New', monospace;
}

/* 侧边栏 */
.sci-fi-aside {
  background: #0d1117 !important;
  border-right: 2px solid #3b82f6;
}

.sci-fi-brand {
  padding: 20px;
  border-bottom: 2px solid #3b82f6;
  text-align: center;
}

.glow-text {
  color: #38bdf8;
  text-shadow: 0 0 10px rgba(59, 130, 246, 0.6);
  font-size: 18px;
  font-weight: bold;
  letter-spacing: 1px;
}

/* 菜单 */
.sci-fi-menu {
  background: transparent !important;
  border-right: none !important;
}

.sci-fi-menu .el-menu-item {
  color: #8b949e !important;
  transition: all 0.2s ease;
}

.sci-fi-menu .el-menu-item:hover {
  background: rgba(59, 130, 246, 0.08) !important;
  color: #3b82f6 !important;
}

.sci-fi-menu .el-menu-item.is-active {
  background: rgba(59, 130, 246, 0.15) !important;
  color: #3b82f6 !important;
  border-left: 4px solid #3b82f6;
  text-shadow: 0 0 8px rgba(59, 130, 246, 0.45);
}

/* Header */
.sci-fi-header {
  background: #0d1117;
  border-bottom: 2px solid #3b82f6;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 20px;
}

.header-title {
  color: #60a5fa;
  font-size: 18px;
  font-weight: bold;
  letter-spacing: 1px;
}

.status-indicator {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #10b981;
  box-shadow: 0 0 8px #10b981;
  margin-right: 8px;
  animation: blink 2s infinite;
}

@keyframes blink {
  0% { opacity: 1; }
  50% { opacity: 0.4; }
  100% { opacity: 1; }
}

.status-text {
  color: #67e8f9;
  font-size: 12px;
  margin-right: 16px;
}

.sci-fi-tag {
  background: rgba(59, 130, 246, 0.2);
  border: 1px solid #3b82f6;
  color: #93c5fd;
}

/* Main */
.sci-fi-main {
  padding: 12px;
  overflow-y: auto;
  position: relative;
  background: #0a0e1a;
}

.user-info {
  padding: 12px;
  border-top: 2px solid #3b82f6;
  display: flex;
  align-items: center;
  gap: 10px;
  background: #161b22;
}

.user-avatar {
  width: 34px;
  height: 34px;
  background: #3b82f6;
  color: #0d1117;
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
}

.user-name {
  color: #93c5fd;
  font-size: 12px;
}

.user-role {
  color: #60a5fa;
  font-size: 11px;
}

/* Custom Scrollbar for Sci-Fi theme */
::-webkit-scrollbar {
  width: 6px;
  height: 6px;
}
::-webkit-scrollbar-track {
  background: rgba(15, 23, 42, 0.5);
}
::-webkit-scrollbar-thumb {
  background: rgba(56, 189, 248, 0.3);
  border-radius: 3px;
}
::-webkit-scrollbar-thumb:hover {
  background: rgba(56, 189, 248, 0.6);
}
</style>
