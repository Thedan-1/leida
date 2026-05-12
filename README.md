# BoilerPatrol Pro (Leida)

**BoilerPatrol Pro** 是一款专为工业巡检与现场数字化设计的 iOS 增强现实 (AR) 应用程序。它利用 Apple 设备先进的 LiDAR 传感器和摄影测量技术，提供从空间扫描、语义分析到高精度物体建模的一站式解决方案。

---

## 🌟 核心功能 (Features)

### 1. 空间 LiDAR 扫描 (Spatial LiDAR Scanning)
- **实时网格化**：利用 LiDAR 深度传感器实时生成环境的三维网格 (Mesh)。
- **定位质量实时反馈**：交通灯式UI指示器（绿/黄/红），实时显示ARKit定位状态与地图就绪程度。
- **手电筒支持**：内置闪光灯开关，解决黑暗环境（锅炉内部）定位失效问题。
- **场景语义分析**：基于机器视觉自动分类识别场景元素并以不同颜色可视化。
- **大场景优化**：支持 20m×20m 级别场景扫描，内置防息屏、自动保存、内存监控等稳定性保障。
- **多格式导出**：
  - **.OBJ**：通用 3D 格式，适用于大多数建模软件（白模）。
  - **.PLY**：支持顶点颜色的格式，保留 AI 分类色彩信息（`Scan_*.ply`）。

### 2. QR 码辅助定位 (QR-Assisted Localization) 🆕
- **特征点标记**：在场地张贴二维码作为人工特征点，辅助 ARKit 重定位。
- **位置平均算法**：同一二维码多次扫描后自动计算平均位置，提高精度。
- **测试工具**：提供 `generate_qr_randomized.py` 脚本，生成高区分度（带随机盐）的测试二维码。

### 3. 物体摄影测量（手动拍照建模）(Photogrammetry)
- **高精度纹理**：针对单个物体（如设备零件、阀门等）进行 360° 环绕拍摄。
- **手动相机拍摄**：使用 AVFoundation 拍摄一组照片（推荐 20–50 张）。
- **设备端重建**：无需上传云端，直接在 iOS 设备上利用 `PhotogrammetrySession` 合成带有照片级纹理的 `.USDZ` 模型。

### 3. AR 地图持久化 (World Persistence)
- **保存与加载**：支持保存当前的 AR 世界地图（WorldMap），包含特征点和锚点信息。
- **重定位 (Relocalization)**：在同一地点重新打开 App，可快速恢复之前的坐标系，实现持续的巡检记录。

### 4. 文件管理与预览 (File Management)
- **内置文件库**：管理所有扫描生成的 .obj, .ply, .usdz 和 .worldmap 文件。
- **3D 预览器**：集成 SceneKit 查看器，支持在 App 内直接预览模型，支持旋转、缩放操作。
- **保存位置**：导出的文件保存在 App 的 Documents 目录，可在“文件库”中查看与分享。

### 5. 账号与巡检报告 (Auth & Reports)
- **登录/注册（本地离线）**：支持手机号注册与登录；注册时选择身份（部署人员/使用人员/管理员）并填写个人信息。
- **巡检报告**：在“使用巡检”模式下可填写巡检字段（温度/压力/水位/阀位/异常状态/备注），支持**拍照附件**与**手写签名确认**，并生成 `Report_*.json`（附件图片文件名会写入 JSON），在文件库内查看与分享。

### 6. 物联网可视化大屏 (IoT Dashboard)
#### 数据大屏服务
- **专业监控界面**：参考工业监控系统设计，深蓝科技风格，九宫格响应式布局。
- **3D可视化**：Three.js实时渲染锅炉模型，支持旋转动画，红点标记告警位置。
- **多维度图表**：ECharts集成温度趋势、压力分布、隐患分类饼图、设备运行雷达图。
- **数据加载**：点击"加载JSON"按钮选择App导出的Report_*.json文件，点击3D场景中的球体查看详情。

#### 主控看板
- **左侧导航栏**：5大功能模块切换
  - 📊 **数据大屏**：嵌入dashboard.html的3D可视化视图
  - 📋 **巡检报告**：表格形式展示所有报告记录
  - 👥 **员工管理**：卡片展示各员工巡检统计（次数/告警数）
  - 📈 **统计分析**：时间分布柱状图、问题类型饼图
  - ⚙️ **系统设置**：上传JSON数据文件
- **数据格式兼容**：自动识别单报告或多报告合集格式
- **使用流程**：
  1. 在App中生成巡检报告（自动保存为兼容格式）
  2. 通过AirDrop将Report_*.json传到电脑
  3. 浏览器打开dashboard_system.html
  4. 进入"系统设置"上传JSON文件
  5. 切换各模块查看不同维度的数据
---

## 🧭 角色与使用流程 (Workflows)

### A. 部署人员（初次建图/基线采集）
目标：为锅炉房/机房建立可复用的 `WorldMap`，并（可选）导出一次基线 3D 网格用于归档。

推荐流程：
- 进入“空间扫描”，先选择「部署建图」，再点击「进入摄像头」。
- 按提示缓慢走动覆盖关键区域（锅炉本体、通道、阀门区、控制柜），避免快速摇晃。
- 观察 HUD 的“定位”状态，尽量达到“扩展中/已定位”。
- 点击「保存地图」生成 `Map_*.worldmap`。
- （可选）点击「保存模型」导出 `Scan_*.obj` 或 `Scan_*.ply` 作为基线资料。

### B. 使用人员（巡检/佩戴使用）
目标：加载现成地图并快速重定位，让坐标系稳定，便于后续巡检交互。

推荐流程：
- 进入“空间扫描”，先选择「使用巡检」，再点击「进入摄像头」。
- 点击底部「更多」→「加载最新地图」一键加载最近一次 `Map_*.worldmap`；或点「选地图（文件库）」手动选择。
- 按提示缓慢移动设备，让系统完成重定位（HUD 显示“已定位 (Mapped)”后更稳定）。
- 需要留档时，点「更多」→「保存模型」导出当前扫描到的网格。
- 需要交付记录时，点击「填写报告」填写巡检表单并生成 `Report_*.json`。

---

## 🧠 重定位 (Relocalization) 是怎么实现的？

### 1) 原理（iPhone 自带的 ARKit 能力）
iPhone/iPad 的 AR 追踪本质是 **视觉惯性里程计 (VIO)**：
- **IMU（陀螺仪/加速度计）** + **相机画面** → 实时估计设备姿态与位移。
- 这个坐标系一开始是“临时的局部坐标系”，App 关掉/Session 重置后会丢失。

所谓“重定位”，就是把“当前相机看到的环境”与“之前保存的环境地图”做匹配，从而恢复到同一个坐标系。

ARKit 的 `ARWorldMap` 可以理解为：
- 一份**稀疏的环境特征地图**（不是网格、也不是点云的完整几何）
- 以及你放进场景里的锚点/对象信息（如果有）

当你重新进入现场并加载这份 `ARWorldMap`：
- ARKit 会尝试把当前相机画面中的特征点，与 WorldMap 里的特征点进行匹配
- 一旦匹配成功，就能解出一个变换，把当前会话坐标系对齐到过去的坐标系
- 对齐成功后，你看到的“坐标、网格、锚点”才会稳定地回到原位置

### 2) 在本 App 里具体怎么做的
- **保存地图**：通过 `ARSession.getCurrentWorldMap` 拿到 `ARWorldMap`，用 `NSKeyedArchiver` 写入 `Map_*.worldmap`。
- **加载地图**：读取 `Map_*.worldmap`，反序列化 `ARWorldMap`，设置到 `ARWorldTrackingConfiguration.initialWorldMap`，再 `session.run(..., options: [.resetTracking, .removeExistingAnchors])` 触发重定位。
- **显示状态**：每帧读取 `ARFrame.worldMappingStatus`（`mapped/extending/limited/notAvailable`）与 `ARCamera.TrackingState`（`limited(.relocalizing)`）来更新 HUD。

### 3) LiDAR 和重定位的关系
- **LiDAR** 在这里主要用于 `sceneReconstruction`（生成 Mesh），便于导出 `.obj/.ply`。
- **重定位更依赖“视觉特征”**（纹理、角点、对比度），所以：
  - 墙面太白/光照太暗/大面积反光 → 重定位会更难
  - 场景改动太大（设备挪动、遮挡变化）→ 也会更难

---

## ✅ 现场让“更容易重定位成功”的操作要点
- **建图时**：尽量覆盖“结构稳定且有纹理”的区域（门框、管道、标识牌、柜体边角），少对着纯白墙。
- **建图质量**：看到 `worldMappingStatus` 至少到“扩展中/已定位”再保存。
- **复用入口**：巡检时尽量从“建图时起点附近”进入，并缓慢移动 5–15 秒。
- **光照稳定**：避免强逆光/频闪/过暗；必要时打开辅助照明。
- **分区建图**：锅炉房很大时建议按区域保存多份地图（例如 A 区/B 区），不要强求一张覆盖全部。

---

## 📚 官方参考文档（Apple）
- ARWorldMap: https://developer.apple.com/documentation/arkit/arworldmap
- ARSession.getCurrentWorldMap: https://developer.apple.com/documentation/arkit/arsession/2923551-getcurrentworldmap
- ARWorldTrackingConfiguration.initialWorldMap: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/2972807-initialworldmap
- ARFrame.worldMappingStatus: https://developer.apple.com/documentation/arkit/arframe/2865793-worldmappingstatus
- ARCamera.TrackingState: https://developer.apple.com/documentation/arkit/arcamera/trackingstate


## 🛠 技术栈 (Tech Stack)

本项目完全基于 Apple 原生技术栈构建，确保最佳的性能与系统兼容性：

- **语言**：Swift 5.9
- **UI 框架**：SwiftUI (MVVM 架构)
- **AR 核心**：ARKit 6
  - `ARWorldTrackingConfiguration` (场景追踪)
  - `SceneReconstruction` (场景重建)
  - `ARMeshClassification` (语义分类)
- **渲染与模型**：
  - RealityKit (用于 AR 展示)
  - SceneKit (用于文件预览)
  - Metal (底层图形处理)
  - ModelIO (3D 数据处理与导出)
- **并发处理**：Swift Concurrency (async/await, Task, Actor)

---

## 📱 环境要求 (Requirements)

- **硬件**：
  - 配备 LiDAR 扫描仪的设备 (iPhone 12 Pro/Max 及更新机型, iPad Pro 2020 及更新机型)。
  - 对于物体扫描功能，建议使用 A14 仿生芯片或更新的设备以获得最佳重建速度。
- **系统**：
  - **iOS 17.0+**（用于设备端 `PhotogrammetrySession` 重建）。
  - Xcode 15.0+ (用于编译)。

---

## 📄 协议与致谢 (License & Credits)

### 开源协议
本项目代码采用 **MIT License** 授权。您可以自由使用、修改和分发，但请保留原作者版权声明。

### 致谢 (Credits)
本项目使用了以下 Apple 技术与 API：
- **ARKit & RealityKit**: Apple Inc. 提供底层的 AR 追踪与渲染技术。
- **PhotogrammetrySession**: Apple Inc. 提供的设备端摄影测量重建能力。
- **SwiftUI**: 现代化的声明式 UI 框架。

---

**开发者**: TheDan  
**最后更新**: 2026-01-08

### 8. 手机反向控制电脑雷达（预留接口）
在电脑端 (`windows_udp_controller.py`) 中为您预留了 `wait_for_phone_start()` 函数。
其它开发者可以通过该函数，监听来自手机的 `START_RADAR` TCP 信号。当手机端点击开始按钮时，不仅会开始 iOS 端的录制，同时能通过局域网“唤醒”电脑端的毫米波雷达捕获。这样可以实现一键完美的双端同步启动。

### 8. 手机反向控制电脑雷达（预留接口）
在电脑端 (`windows_udp_controller.py`) 中为您预留了 `wait_for_phone_start()` 函数。
其它开发者可以通过该函数，监听来自手机的 `START_RADAR` TCP 信号。当手机端点击开始按钮时，不仅会开始 iOS 端的录制，同时能通过局域网“唤醒”电脑端的毫米波雷达捕获。这样可以实现一键完美的双端同步启动。
