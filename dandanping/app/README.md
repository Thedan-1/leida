# Dandanping Industrial Dashboard

这是基于 Vue3 + Vite + Element Plus + ECharts 重构的工业智慧大屏。

## 已完成内容

- 旧版大屏归档：`../legacy` 下保留原始文件，可随时回退。
- 新版多页面架构：态势总览、告警中心、工单中心、巡检报告、设备资产、统计分析、系统设置。
- 组件化与状态管理：使用 Pinia 管理报告、告警、工单、资产数据。
- 兼容旧数据：系统设置页面支持上传旧 `Report_*.json` 并自动映射。

## 本地运行

```bash
npm install
npm run dev
```

默认启动后访问控制台输出中的本地地址。

## 生产构建

```bash
npm run build
```

构建输出目录：`dist/`

## 目录说明

- `src/router/`：路由与页面入口
- `src/stores/`：Pinia 数据状态
- `src/views/`：各业务页面
- `src/components/`：通用组件
- `src/utils/reportParser.ts`：旧 JSON 数据解析与映射

## 下一步可迭代方向

- 接入后端 API（替换本地 mock）
- 引入 WebSocket 实时推送
- 对接权限系统（管理员/巡检员/只读）
- 增加设备详情页与时序数据回放
