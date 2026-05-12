# 锅炉房 LiDAR 智能巡检系统 (BoilerPatrol Pro)

**项目完成时间**: 2026年1月24日  
**状态**: ✅ 核心功能完整交付（iOS App + Web Dashboard）

---

## 📖 项目概述
本项目开发了一套基于 **LiDAR 深度感知** 与 **AR 增强现实** 技术的工业巡检系统。通过 iPhone 12 Pro+ 系列设备的激光雷达传感器，实现锅炉房环境的实时三维重建、精确空间定位、设备状态监测及数据可视化大屏联动。

---

## 🛠 核心功能清单

### 1. iOS 移动端 (Swift + ARKit + RealityKit)
- [x] **空间扫描与建图 (LiDAR)**
  - **实时网格重建**: 利用 `meshWithClassification` 生成带语义的 3D 网格。
  - **真实环境识别**: 自动区分墙面、地面、窗户、物体等（支持 AI 语义上色导出）。
  - **精度增强**: 集成 `smoothedSceneDepth` 获取高密度深度图，逼近“纯 LiDAR”效果。
  - **环境地图持久化**: 支持保存和加载 `.worldmap`，实现多人共享与重定位。
  
- [x] **智能巡检业务**
  - **AR 空间定位**: 实时记录巡检员在车间内的 XYZ 三维坐标。
  - **多维数据采集**: 录入温度、压力、水位、阀位等 6 项核心指标。
  - **异常监测**: 勾选异响、泄漏等 6 类常见故障。
  - **多媒体证据**: 支持拍照取证（AR 坐标关联）与手写电子签名。

- [x] **数据导出与管理**
  - **标准格式**: 导出 JSON 巡检报告，无缝对接 Web 大屏。
  - **3D 模型导出**: 支持 `.obj` (白模) 和 `.ply` (AI 语义色彩) 格式。
  - **用户系统**: 角色权限管理（管理员/巡检员），SHA256 加密登录。

### 2. Web 可视化大屏 (HTML5 + Three.js + ECharts)
- [x] **3D 数字孪生车间**
  - 使用 Three.js 构建 20x20m 完整锅炉房场景（4 台锅炉）。
  - 支持 **内外视角切换**（鸟瞰/第一人称）与 **鼠标自由交互**。
  - **空间映射算法**: 将 AR 坐标 (Meters) 自动映射到虚拟车间坐标系。
  
- [x] **数据可视化**
  - **实时告警**: 红色/绿色发光球体在 3D 场景中实时标记设备状态。
  - **图表分析**: 12小时温压趋势图、故障类型饼图、运行状态雷达图。
  - **员工管理**: 班组排班与巡检记录统计。

---

## 📊 关于 LiDAR 精度与实现机制

用户的“纯 LiDAR”需求受限于硬件架构（ARKit 需要 VIO 融合），但本项目采用了**最大化 LiDAR 权重**的优化方案：

### 1. 深度优化策略
为了响应导师对“纯 LiDAR”的期望，我们在底层配置中加入了：
```swift
// 启用平滑场景深度 (Smoothed Scene Depth)
config.frameSemantics.insert(.smoothedSceneDepth)
```
此配置利用 LiDAR 传感器的时间累积数据，生成比普通相机更稳定、更密集的深度图，大幅提升了建图精度和抗干扰能力。

### 2. 六大精度优化指标
详见 `LIDAR_ACCURACY.md`，我们在代码中实现了：
1. **Mesh Classification**: 语义级网格生成。
2. **Auto Focus & Environment Texturing**: 增强视觉特征捕捉。
3. **Gravity Alignment**: 减少空间漂移。
4. **Plane Detection**: 同时检测水平面和垂直面，锁定几何特征。
5. **Smoothed Scene Depth**: 高级 LiDAR 深度平滑。
6. **Relocalization**: 基于 WorldMap 的重定位纠偏。

---

## 💾 文件结构与交付物

### 📱 iOS 源码
- `ContentView.swift`: 主程序入口，包含 AR 会话管理、表单逻辑、文件库。
- `AppModel`: 全局状态管理、数据持久化。
- `leida.xcodeproj`: Xcode 项目文件。

### 💻 Web 大屏源码 (`/dashboard`)
- `frontend/dashboard.html`: 核心 3D 可视化界面。
- `dashboard_system.html`: 后台管理系统框架。
- `assets/`: 包含图片、字体及 Three.js 依赖库。

---

## 📝 更新日志 (Jan 22-24)

### 2026-01-24 (Final Polish)
- ✅ **修复编译器错误**: 解决 Swift 6 类型检查超时问题，提取 Form Section。
- ✅ **增强 LiDAR 配置**: 开启 `smoothedSceneDepth` 语义，提升建图密度。
- ✅ **界面优化**: 将扫描设置移至 AR 视图右上角，改善操作流程。
- ✅ **文档整合**: 归档零散 MD 文件，统一项目说明。

### 2026-01-23
- ✅ **功能增强**: 3D 车间升级为完整场景，添加鼠标控制。
- ✅ **数据联调**: 实现 App 真实坐标 (XYZ) 到大屏的自动映射。

---

> 此文档汇总了项目的所有核心信息，可直接用于答辩演示或技术报告。
> 之前的 `PROJECT_COMPLETION.md` 和 `LIDAR_ACCURACY.md` 内容已整合入此文件。
