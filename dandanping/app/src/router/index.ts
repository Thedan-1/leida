import { createRouter, createWebHistory } from 'vue-router'

const routes = [
  { path: '/', redirect: '/legacy' },
  { path: '/legacy', name: 'legacy', component: () => import('../views/LegacyDashboardView.vue'), meta: { title: '原版大屏' } },
  { path: '/overview', name: 'overview', component: () => import('../views/OverviewView.vue'), meta: { title: '工业总览' } },
  { path: '/alarms', name: 'alarms', component: () => import('../views/AlarmCenterView.vue'), meta: { title: '告警中心' } },
  { path: '/workorders', name: 'workorders', component: () => import('../views/WorkOrderView.vue'), meta: { title: '工单中心' } },
  { path: '/realtime', name: 'realtime', component: () => import('../views/RealtimeView.vue'), meta: { title: '实时监测' } },
  { path: '/command', name: 'command', component: () => import('../views/CommandCenterView.vue'), meta: { title: '控制中心' } },
  { path: '/drills', name: 'drills', component: () => import('../views/DrillCenterView.vue'), meta: { title: '演练中心' } },
  { path: '/reports', name: 'reports', component: () => import('../views/ReportsView.vue'), meta: { title: '巡检报表' } },
  { path: '/assets', name: 'assets', component: () => import('../views/AssetsView.vue'), meta: { title: '资产台账' } },
  { path: '/analytics', name: 'analytics', component: () => import('../views/AnalyticsView.vue'), meta: { title: '趋势分析' } },
  { path: '/settings', name: 'settings', component: () => import('../views/SettingsView.vue'), meta: { title: '系统设置' } }
]

export default createRouter({
  history: createWebHistory(),
  routes
})
