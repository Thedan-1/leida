import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import dayjs from 'dayjs'
import type { AlarmItem, AssetItem, ControlState, DrillScenario, EventLog, InspectionReport, RealtimePoint, WorkOrder } from '../types'
import { parseLegacyReportJson } from '../utils/reportParser'

let simulationTimer: ReturnType<typeof setInterval> | null = null

const defaultReports = (): InspectionReport[] => {
  const inspectors = ['张工', '李工', '王工', '陈工']
  const locations = ['A炉膛', 'B换热区', 'C泵房', 'D阀组']
  return Array.from({ length: 24 }).map((_, idx) => {
    const temp = 68 + ((idx * 7) % 38)
    const pressure = Number((1.2 + (idx % 7) * 0.09).toFixed(2))
    return {
      id: `R-${1000 + idx}`,
      time: dayjs().subtract(idx * 3, 'hour').format('YYYY-MM-DD HH:mm:ss'),
      inspector: inspectors[idx % inspectors.length],
      location: locations[idx % locations.length],
      temperature: temp,
      pressure,
      status: temp >= 95 || pressure >= 1.7 ? 'critical' : temp >= 85 ? 'warning' : 'normal',
      issue: temp >= 95 ? '温度峰值偏高' : pressure >= 1.7 ? '压力异常波动' : '巡检正常',
      description: '系统自动生成巡检样本数据',
    }
  })
}

const defaultAssets = (): AssetItem[] => [
  { id: 'AST-01', name: '主锅炉-1', area: 'A区', type: '锅炉本体', healthScore: 92, runtimeHours: 12340, status: 'normal', lastMaintenance: '2026-03-28' },
  { id: 'AST-02', name: '高压循环泵', area: 'B区', type: '泵机', healthScore: 78, runtimeHours: 17300, status: 'warning', lastMaintenance: '2026-03-06' },
  { id: 'AST-03', name: '蒸汽分配阀组', area: 'C区', type: '阀门组件', healthScore: 64, runtimeHours: 20122, status: 'critical', lastMaintenance: '2026-01-15' },
  { id: 'AST-04', name: '热交换模块', area: 'D区', type: '换热器', healthScore: 88, runtimeHours: 14030, status: 'normal', lastMaintenance: '2026-02-26' },
]

const defaultWorkOrders = (): WorkOrder[] => [
  { id: 'WO-501', title: '排查主锅炉温度波动', assignee: '张工', priority: 'high', progress: 46, dueDate: '2026-04-10', status: 'in_progress' },
  { id: 'WO-502', title: '更换循环泵密封件', assignee: '李工', priority: 'medium', progress: 20, dueDate: '2026-04-11', status: 'pending' },
  { id: 'WO-503', title: '阀组联动测试', assignee: '王工', priority: 'low', progress: 100, dueDate: '2026-04-07', status: 'done' },
]

const defaultRealtimeSeries = (): RealtimePoint[] => {
  return Array.from({ length: 40 }).map((_, idx) => {
    const minuteOffset = 39 - idx
    const temperature = 76 + Math.sin(idx / 3.2) * 8 + (idx % 5)
    const pressure = 1.25 + Math.cos(idx / 4.3) * 0.14
    const flowRate = 68 + Math.sin(idx / 5.1) * 12
    const powerLoad = 56 + Math.cos(idx / 7.2) * 10
    return {
      time: dayjs().subtract(minuteOffset, 'minute').format('HH:mm:ss'),
      temperature: Number(temperature.toFixed(1)),
      pressure: Number(pressure.toFixed(2)),
      flowRate: Number(flowRate.toFixed(1)),
      powerLoad: Number(powerLoad.toFixed(1)),
    }
  })
}

const defaultEventLogs = (): EventLog[] => [
  { id: 'EV-1', level: 'warning', message: 'B区换热效率下降至阈值边缘', time: dayjs().subtract(3, 'minute').format('YYYY-MM-DD HH:mm:ss') },
  { id: 'EV-2', level: 'info', message: '巡检任务 WO-501 已进入执行阶段', time: dayjs().subtract(9, 'minute').format('YYYY-MM-DD HH:mm:ss') },
  { id: 'EV-3', level: 'critical', message: 'C区阀组压差持续异常超过 120s', time: dayjs().subtract(14, 'minute').format('YYYY-MM-DD HH:mm:ss') },
]

const defaultControlState = (): ControlState => ({
  emergencyStop: false,
  coolingPump: true,
  ventValve: false,
  targetTemperature: 82,
  targetPressure: 1.48,
})

const defaultDrills = (): DrillScenario[] => [
  { id: 'DR-101', title: '蒸汽泄漏应急处置', category: '安全事故', level: 'L3', durationMinutes: 25, completionRate: 78 },
  { id: 'DR-102', title: '高温连锁降载流程', category: '设备防护', level: 'L2', durationMinutes: 18, completionRate: 91 },
  { id: 'DR-103', title: '夜班巡检通讯中断恢复', category: '运维协同', level: 'L1', durationMinutes: 12, completionRate: 66 },
]

export const useDashboardStore = defineStore('dashboard', () => {
  const reports = ref<InspectionReport[]>(defaultReports())
  const assets = ref<AssetItem[]>(defaultAssets())
  const workOrders = ref<WorkOrder[]>(defaultWorkOrders())
  const realtimeSeries = ref<RealtimePoint[]>(defaultRealtimeSeries())
  const eventLogs = ref<EventLog[]>(defaultEventLogs())
  const commandHistory = ref<EventLog[]>([])
  const controlState = ref<ControlState>(defaultControlState())
  const drillScenarios = ref<DrillScenario[]>(defaultDrills())
  const simulationRunning = ref(false)

  const alarms = ref<AlarmItem[]>([
    { id: 'AL-1', title: 'A区温度越限', source: '主锅炉-1', level: 'P1', createdAt: dayjs().subtract(25, 'minute').format('YYYY-MM-DD HH:mm:ss'), acknowledged: false, reportId: 'R-1002' },
    { id: 'AL-2', title: '阀组压差异常', source: '蒸汽分配阀组', level: 'P2', createdAt: dayjs().subtract(70, 'minute').format('YYYY-MM-DD HH:mm:ss'), acknowledged: false, reportId: 'R-1008' },
    { id: 'AL-3', title: '巡检中断恢复', source: '高压循环泵', level: 'P3', createdAt: dayjs().subtract(150, 'minute').format('YYYY-MM-DD HH:mm:ss'), acknowledged: true },
  ])

  const totalReports = computed(() => reports.value.length)
  const criticalCount = computed(() => reports.value.filter((r) => r.status === 'critical').length)
  const warningCount = computed(() => reports.value.filter((r) => r.status === 'warning').length)
  const latestRealtimePoint = computed(() => realtimeSeries.value[realtimeSeries.value.length - 1] ?? {
    time: dayjs().format('HH:mm:ss'),
    temperature: 0,
    pressure: 0,
    flowRate: 0,
    powerLoad: 0,
  })
  const normalRate = computed(() => {
    if (!reports.value.length) return 0
    const normal = reports.value.filter((r) => r.status === 'normal').length
    return Number(((normal / reports.value.length) * 100).toFixed(1))
  })

  const appendEvent = (level: EventLog['level'], message: string) => {
    const event: EventLog = {
      id: `EV-${Date.now()}`,
      level,
      message,
      time: dayjs().format('YYYY-MM-DD HH:mm:ss'),
    }
    eventLogs.value.unshift(event)
    if (eventLogs.value.length > 60) {
      eventLogs.value = eventLogs.value.slice(0, 60)
    }
  }

  const pushRealtimeTick = () => {
    const previous = latestRealtimePoint.value
    const drift = (Math.random() - 0.5) * 2
    const nextTemperature = Number(Math.max(62, Math.min(112, previous.temperature + drift * 1.4)).toFixed(1))
    const nextPressure = Number(Math.max(1.02, Math.min(1.92, previous.pressure + drift * 0.02)).toFixed(2))
    const nextFlowRate = Number(Math.max(40, Math.min(98, previous.flowRate + drift * 1.8)).toFixed(1))
    const nextPowerLoad = Number(Math.max(30, Math.min(95, previous.powerLoad + drift * 2.3)).toFixed(1))

    realtimeSeries.value.push({
      time: dayjs().format('HH:mm:ss'),
      temperature: nextTemperature,
      pressure: nextPressure,
      flowRate: nextFlowRate,
      powerLoad: nextPowerLoad,
    })

    if (realtimeSeries.value.length > 90) {
      realtimeSeries.value = realtimeSeries.value.slice(-90)
    }

    if (nextTemperature > 98) {
      appendEvent('critical', '实时仿真触发: 温度超过 98°C，建议执行降载流程')
    } else if (nextPressure > 1.74) {
      appendEvent('warning', '实时仿真触发: 压力逼近上限，请检查阀组')
    }
  }

  const startSimulation = () => {
    if (simulationTimer) return
    simulationRunning.value = true
    simulationTimer = setInterval(() => {
      pushRealtimeTick()
    }, 2500)
    appendEvent('info', '模拟数据流已启动')
  }

  const stopSimulation = () => {
    if (!simulationTimer) return
    clearInterval(simulationTimer)
    simulationTimer = null
    simulationRunning.value = false
    appendEvent('info', '模拟数据流已停止')
  }

  const runEmergencyProtocol = () => {
    controlState.value.emergencyStop = true
    controlState.value.coolingPump = true
    controlState.value.ventValve = true
    appendEvent('critical', '执行一键应急处置：急停启用、冷却泵强制开启、泄压阀开启')
    commandHistory.value.unshift({
      id: `CMD-${Date.now()}`,
      level: 'critical',
      message: '一键应急处置执行',
      time: dayjs().format('YYYY-MM-DD HH:mm:ss'),
    })
  }

  const updateControlState = (patch: Partial<ControlState>) => {
    controlState.value = { ...controlState.value, ...patch }
    commandHistory.value.unshift({
      id: `CMD-${Date.now()}`,
      level: 'info',
      message: `控制参数更新: ${Object.keys(patch).join(', ')}`,
      time: dayjs().format('YYYY-MM-DD HH:mm:ss'),
    })
    if (commandHistory.value.length > 80) {
      commandHistory.value = commandHistory.value.slice(0, 80)
    }
  }

  const updateDrillProgress = (id: string, progress: number) => {
    const scenario = drillScenarios.value.find((item) => item.id === id)
    if (!scenario) return
    scenario.completionRate = progress
  }

  const loadFromLegacyJson = (payload: unknown) => {
    const list = parseLegacyReportJson(payload)
    if (list.length) {
      reports.value = list
      alarms.value = list
        .filter((r) => r.status !== 'normal')
        .map((r, idx) => ({
          id: `AL-UP-${idx + 1}`,
          title: r.issue || '巡检发现异常',
          source: r.location,
          level: r.status === 'critical' ? 'P1' : 'P2',
          createdAt: r.time,
          acknowledged: false,
          reportId: r.id,
        }))
    }
  }

  const acknowledgeAlarm = (id: string) => {
    const alarm = alarms.value.find((item) => item.id === id)
    if (alarm) alarm.acknowledged = true
  }

  const addWorkOrder = (title: string, assignee: string, priority: WorkOrder['priority']) => {
    const id = `WO-${Math.floor(Math.random() * 900 + 100)}`
    workOrders.value.unshift({
      id,
      title,
      assignee,
      priority,
      progress: 0,
      dueDate: dayjs().add(priority === 'high' ? 1 : 3, 'day').format('YYYY-MM-DD'),
      status: 'pending',
    })
  }

  const updateWorkOrderProgress = (id: string, progress: number) => {
    const item = workOrders.value.find((order) => order.id === id)
    if (!item) return
    item.progress = progress
    item.status = progress >= 100 ? 'done' : progress > 0 ? 'in_progress' : 'pending'
  }

  startSimulation()

  return {
    reports,
    assets,
    alarms,
    workOrders,
    realtimeSeries,
    eventLogs,
    commandHistory,
    controlState,
    drillScenarios,
    simulationRunning,
    totalReports,
    criticalCount,
    warningCount,
    latestRealtimePoint,
    normalRate,
    loadFromLegacyJson,
    acknowledgeAlarm,
    addWorkOrder,
    updateWorkOrderProgress,
    startSimulation,
    stopSimulation,
    runEmergencyProtocol,
    updateControlState,
    updateDrillProgress,
  }
})
