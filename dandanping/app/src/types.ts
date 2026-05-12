export type HealthStatus = 'normal' | 'warning' | 'critical'

export interface InspectionReport {
  id: string
  time: string
  inspector: string
  location: string
  temperature: number
  pressure: number
  status: HealthStatus
  issue: string
  description: string
}

export interface AlarmItem {
  id: string
  title: string
  source: string
  level: 'P1' | 'P2' | 'P3'
  createdAt: string
  acknowledged: boolean
  reportId?: string
}

export interface AssetItem {
  id: string
  name: string
  area: string
  type: string
  healthScore: number
  runtimeHours: number
  status: HealthStatus
  lastMaintenance: string
}

export interface WorkOrder {
  id: string
  title: string
  assignee: string
  priority: 'high' | 'medium' | 'low'
  progress: number
  dueDate: string
  status: 'pending' | 'in_progress' | 'done'
}

export interface RealtimePoint {
  time: string
  temperature: number
  pressure: number
  flowRate: number
  powerLoad: number
}

export interface EventLog {
  id: string
  level: 'info' | 'warning' | 'critical'
  message: string
  time: string
}

export interface ControlState {
  emergencyStop: boolean
  coolingPump: boolean
  ventValve: boolean
  targetTemperature: number
  targetPressure: number
}

export interface DrillScenario {
  id: string
  title: string
  category: string
  level: 'L1' | 'L2' | 'L3'
  durationMinutes: number
  completionRate: number
}
