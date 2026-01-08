# BoilerPatrol Pro (Leida)

**BoilerPatrol Pro** 是一款专为工业巡检与现场数字化设计的 iOS 增强现实 (AR) 应用程序。它利用 Apple 设备先进的 LiDAR 传感器和摄影测量技术，提供从空间扫描、语义分析到高精度物体建模的一站式解决方案。

---

## 🌟 核心功能 (Features)

### 1. 空间 LiDAR 扫描 (Spatial LiDAR Scanning)
- **实时网格化**：利用 LiDAR 深度传感器实时生成环境的三维网格 (Mesh)。
- **AI 语义着色**：基于机器学习自动识别场景元素（墙壁、地板、天花板、桌椅等），并以不同颜色进行可视化区分。
- **多格式导出**：
  - **.OBJ**：通用 3D 格式，适用于大多数建模软件（白模）。
  - **.PLY**：支持顶点颜色的格式，保留 AI 分类色彩信息（`Scan_*.ply`）。

### 2. 物体摄影测量（手动拍照建模）(Photogrammetry)
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

### 6. 报告 AI 审核（可选，离线）
- App 生成的 `Report_*.json` 可以在电脑上用脚本喂给你指定的大模型做“风险研判/审核建议”。
- 脚本位置：`tools/ai_report_review.py`（不会写死密钥，使用环境变量）。

示例：
```bash
cd tools
pip install -r requirements.txt

export AI_API_KEY='你的密钥'
export AI_BASE_URL='https://aistudio.baidu.com/llm/lmapi/v3'
python ai_report_review.py --report /path/to/Report_123.json --model ernie-x1.1-preview
```

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

## 🧩 你现在这套软件，真实使用还缺什么（建议清单）

### 1) 人类正常使用（工人端）
- **“一键正常/快速异常”**：报告默认“全部正常”，只需勾选异常项+备注，减少输入。
- **二维码/二维码贴纸**：扫描设备二维码自动填“锅炉编号/区域”。
- **语音输入**：备注支持语音转文字（戴手套更友好）。
- **报告预览页**：生成前预览（含照片/签名），防止漏填。
- **今日巡检列表**：按日期显示今天做了哪些点位、哪些异常。

### 2) 管理效率（离线单机也能做）
- **报告汇总与导出**：App 内按日期/锅炉编号筛选，导出 CSV/PDF（交付/留档更方便）。
- **异常自动分级**：根据异常组合与关键词给出 LOW/MEDIUM/HIGH，减少人工判断成本。
- **设备台账/点位清单**：把锅炉/阀门/柜体作为资产列表，巡检按清单打卡。
- **数据备份/迁移**：一键导出/导入（Documents 打包），换机不丢。

### 3) 安全与合规（现场落地常见要求）
- **账号锁定/密码重置策略**（离线也要可管理）。
- **数据留存周期与清理**：照片/模型很占空间，建议提供“存储占用”和“清理策略”。

---

## 📚 官方参考文档（Apple）
- ARWorldMap: https://developer.apple.com/documentation/arkit/arworldmap
- ARSession.getCurrentWorldMap: https://developer.apple.com/documentation/arkit/arsession/2923551-getcurrentworldmap
- ARWorldTrackingConfiguration.initialWorldMap: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/2972807-initialworldmap
- ARFrame.worldMappingStatus: https://developer.apple.com/documentation/arkit/arframe/2865793-worldmappingstatus
- ARCamera.TrackingState: https://developer.apple.com/documentation/arkit/arcamera/trackingstate

---

## 🔍 关于“是否真的用了 LiDAR”
- 在支持 LiDAR 的设备上：App 会开启 ARKit 的 `sceneReconstruction`（mesh/meshWithClassification），并可导出网格文件。
- 在不支持 LiDAR 的设备上：无法开启网格重建；仍可进行 AR 追踪/平面检测，但不会产生可导出的 LiDAR 网格。

---

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
