import type { HealthStatus, InspectionReport } from '../types'

const toStatus = (raw: unknown): HealthStatus => {
  const value = String(raw ?? '').toLowerCase()
  if (value.includes('告警') || value.includes('alert') || value.includes('critical')) {
    return 'critical'
  }
  if (value.includes('警告') || value.includes('warning')) {
    return 'warning'
  }
  return 'normal'
}

const normalizeOne = (item: Record<string, unknown>, fallbackId: string): InspectionReport => {
  const source = (item.record as Record<string, unknown>) ?? item
  return {
    id: String(source.id ?? fallbackId),
    time: String(source.time ?? new Date().toISOString()),
    inspector: String(source.inspector ?? '未命名人员'),
    location: String(source.location ?? '未指定区域'),
    temperature: Number(source.temperature ?? 0),
    pressure: Number(source.pressure ?? 0),
    status: toStatus(source.status),
    issue: String(source.issue ?? '无'),
    description: String(source.description ?? ''),
  }
}

export const parseLegacyReportJson = (payload: unknown): InspectionReport[] => {
  if (!payload) return []
  if (Array.isArray(payload)) {
    return payload
      .filter((item) => typeof item === 'object' && item !== null)
      .map((item, index) => normalizeOne(item as Record<string, unknown>, `R-${index + 1}`))
  }

  if (typeof payload !== 'object') return []

  const obj = payload as Record<string, unknown>
  const records = obj.records

  if (Array.isArray(records)) {
    return records
      .filter((item) => typeof item === 'object' && item !== null)
      .map((item, index) => normalizeOne(item as Record<string, unknown>, `R-${index + 1}`))
  }

  return [normalizeOne(obj, 'R-1')]
}
