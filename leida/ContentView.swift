import SwiftUI
import RealityKit
import ARKit
import Combine
import ModelIO
import MetalKit
import SceneKit
import QuickLookThumbnailing
import CryptoKit
import Security
import PhotosUI
import UIKit
import Vision  // QR 码检测

// MARK: - MeshResource Extension for ARMeshAnchor
extension MeshResource {
    /// 从 ARMeshAnchor 创建 MeshResource，用于可视化网格
    static func generate(from meshAnchor: ARMeshAnchor) throws -> MeshResource {
        let geometry = meshAnchor.geometry
        
        // 提取顶点
        let vertices = geometry.vertices
        let vertexCount = vertices.count
        let vertexStride = vertices.stride
        
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)
        
        let vertexBuffer = vertices.buffer.contents()
        for i in 0..<vertexCount {
            let offset = i * vertexStride
            let x = vertexBuffer.load(fromByteOffset: offset, as: Float.self)
            let y = vertexBuffer.load(fromByteOffset: offset + 4, as: Float.self)
            let z = vertexBuffer.load(fromByteOffset: offset + 8, as: Float.self)
            positions.append(SIMD3<Float>(x, y, z))
        }
        
        // 提取面索引
        let faces = geometry.faces
        let faceCount = faces.count
        let indexCountPerPrimitive = faces.indexCountPerPrimitive // 应为 3
        let bytesPerIndex = faces.bytesPerIndex
        
        var indices: [UInt32] = []
        indices.reserveCapacity(faceCount * indexCountPerPrimitive)
        
        let faceBuffer = faces.buffer.contents()
        for i in 0..<(faceCount * indexCountPerPrimitive) {
            let index: UInt32
            if bytesPerIndex == 2 {
                index = UInt32(faceBuffer.load(fromByteOffset: i * 2, as: UInt16.self))
            } else {
                index = faceBuffer.load(fromByteOffset: i * 4, as: UInt32.self)
            }
            indices.append(index)
        }
        
        // 创建 MeshDescriptor
        var descriptor = MeshDescriptor(name: "ARMesh")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        
        return try MeshResource.generate(from: [descriptor])
    }
}

// MARK: - 1. App State & Logic
@MainActor
final class AppModel: ObservableObject {
    enum WorkMode: String, CaseIterable, Identifiable {
        case deployment = "部署建图"
        case operation = "使用巡检"

        var id: String { rawValue }
    }

    enum UserRole: String, CaseIterable, Identifiable, Codable {
        case deployment = "部署人员"
        case worker = "使用人员"
        case manager = "管理员"

        var id: String { rawValue }
    }

    struct UserAccount: Identifiable, Codable, Equatable {
        var id: UUID
        var phone: String
        var displayName: String
        var company: String
        var role: UserRole
        var passwordSaltBase64: String
        var passwordHashBase64: String
        var createdAt: Date
    }

    struct InspectionReport: Identifiable, Codable {
        var id: UUID
        var createdAt: Date
        var signedAt: Date?
        var inspectorId: UUID
        var inspectorName: String
        var inspectorRole: UserRole
        var boilerId: String
        var area: String
        
        // AR位置坐标（相对于地图原点）
        var positionX: Double?
        var positionY: Double?
        var positionZ: Double?

        var temperatureC: String
        var pressureMPa: String
        var waterLevel: String
        var valvePosition: String

        var abnormalNoise: Bool
        var leakage: Bool
        var vibration: Bool
        var smokeOrSteam: Bool
        var overTempOrPressure: Bool
        var alarmTriggered: Bool

        var notes: String

        // 附件（离线存储在 Documents，JSON 里仅记录文件名）
        var photoFileNames: [String]
        var signatureFileName: String?
        var signerName: String
        var confirmationChecked: Bool
    }

    // 导航状态
    @Published var selectedTab: Int = 0

    // 账号状态
    @Published var currentUser: UserAccount?
    
    // 扫描状态
    @Published var isScanning: Bool = true
    @Published var meshCount: Int = 0
    @Published var trackingState: String = "初始化..."
    @Published var relocalizationStatus: String = "等待地图..."
    
    // 导出状态
    @Published var isProcessing: Bool = false
    @Published var processMessage: String = ""
    @Published var showAlert: Bool = false
    @Published var alertMessage: String = ""
    
    // 文件管理
    @Published var savedFiles: [URL] = []
    @Published var selectedFile: URL?
    @Published var showFileViewer: Bool = false
    
    // AR 控制
    weak var arView: ARView? // 弱引用持有 ARView
    @Published var shouldSaveMap: Bool = false
    @Published var mapToLoad: URL?
    @Published var shouldResetSession: Bool = false
    @Published var isLiDAREnabled: Bool = true // 控制 LiDAR 开关
    @Published var isMeshColoringEnabled: Bool = true // 控制网格分类显示
    @Published var isTorchEnabled: Bool = false // 手电筒开关
    @Published var isRelocalizing: Bool = false // 是否正在重定位中
    @Published var isSessionStarted: Bool = false // 是否已启动 AR 会话
    @Published var currentPosition: SIMD3<Float> = .zero // 当前 XYZ 坐标

    /// 精确测试专用共享 ARSession（三个精确Tab共用，避免多实例竞争相机）
    let precisionARSession: ARSession = ARSession()
    
    // 扫描状态控制
    enum ScanState: String {
        case idle = "准备中"
        case scanning = "扫描中"
        case paused = "已暂停"
        case completed = "已完成"
    }
    @Published var scanState: ScanState = .idle
    @Published var selectedMapForPatrol: URL? = nil  // 巡检模式选择的地图
    
    // 定位质量状态
    enum LocalizationQuality {
        case lost           // 迷失/初始化
        case relocalizing   // 重定位中
        case good           // 良好 (Normal + Mapped)
        case limited(String) // 受限 (带原因)
    }
    @Published var locQuality: LocalizationQuality = .lost
    @Published var locQualityMessage: String = "初始化中..."

    // 使用模式
    @Published var workMode: WorkMode = .deployment

    // 设备能力/运行状态
    @Published var lidarMeshStatus: String = ""
    
    // 设置与着色
    @Published var coloringMode: ColoringMode = .ai
    @Published var showExportOptions: Bool = false  // 显示导出选项弹窗
    @Published var pendingMeshAnchors: [ARMeshAnchor] = []  // 待导出的网格
    
    // 纹理采集开关（默认关闭，节省电量）
    @Published var isTextureCaptureEnabled: Bool = false
    
    enum ColoringMode: String, CaseIterable, Identifiable {
        case none = "无颜色 (白模)"
        case ai = "AI 语义 (分类色)"
        case texture = "真实纹理 (相机色)"
        
        var id: String { self.rawValue }
    }
    
    // MARK: - QR 码辅助重定位
    // QR 锚点：存储扫描过程中检测到的 QR 码位置
    struct QRAnchor: Codable {
        let content: String           // QR 码内容
        var worldPosition: SIMD3<Float>  // 世界坐标位置
        var observations: Int = 1     // 观测次数（用于平均）
        var lastSeen: TimeInterval = 0
    }
    
    // 当前会话的 QR 锚点（内容 -> 锚点）
    var qrAnchors: [String: QRAnchor] = [:]
    var lastQRScanTime: TimeInterval = 0
    let qrScanInterval: Double = 1.0  // QR 检测间隔（秒）— 从0.3提高到1.0，大幅降低性能消耗
    
    // 重定位校正偏移量
    var relocalizationOffset: SIMD3<Float> = .zero
    var isQRCorrectionEnabled: Bool = true
    @Published var isAutoQRRelocalizationEnabled: Bool = false
    
    // QR 码物理尺寸（用于精确位置计算）
    var qrCodePhysicalSize: Float = 0.10  // 默认 10cm，可在设置中修改
    
    // QR 码检测可视化反馈
    @Published var lastDetectedQR: String? = nil  // 最近检测到的 QR 码
    @Published var lastDetectedQRTime: Date? = nil  // 检测时间（用于显示动画）
    @Published var lastDetectedQRPosition: SIMD3<Float>? = nil  // 检测到的3D位置
    @Published var lastDetectedQRDistance: Float? = nil  // 估算的距离
    @Published var driftWarning: String? = nil  // 漂移警告信息
    @Published var showQRActionSheet: Bool = false  // 显示QR码操作菜单
    
    // 清空 QR 锚点
    func clearQRAnchors() {
        qrAnchors.removeAll()
        relocalizationOffset = .zero
    }
    
    // MARK: - 相机帧捕获（用于真实纹理映射）
    struct CapturedCameraFrame: @unchecked Sendable {
        let rgbaData: Data            // RGBA 像素数据
        let width: Int
        let height: Int
        let transform: simd_float4x4  // 相机世界变换矩阵
        let intrinsics: simd_float3x3 // 相机内参矩阵
        let timestamp: TimeInterval
        
        func sampleColor(atX x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let offset = (y * width + x) * 4
            guard offset + 2 < rgbaData.count else { return nil }
            return rgbaData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return (128, 128, 128) }
                let r = base.load(fromByteOffset: offset, as: UInt8.self)
                let g = base.load(fromByteOffset: offset + 1, as: UInt8.self)
                let b = base.load(fromByteOffset: offset + 2, as: UInt8.self)
                return (r, g, b)
            }
        }
    }
    
    var capturedCameraFrames: [CapturedCameraFrame] = []
    @Published var capturedFrameCount: Int = 0   // 单独的 @Published 计数器，确保 UI 及时刷新
    var lastFrameCaptureTime: TimeInterval = 0
    let frameCaptureInterval: Double = 0.8   // 每0.8秒采集一帧（平衡清晰度与CPU负载）
    let maxCapturedFrames: Int = 150         // 帧上限（960px下约525MB，按需调整）
    
    func addCapturedFrame(_ frame: CapturedCameraFrame) {
        guard capturedCameraFrames.count < maxCapturedFrames else { return }
        capturedCameraFrames.append(frame)
        capturedFrameCount = capturedCameraFrames.count
        print("📸 帧#\(capturedFrameCount) 已捕获 (\(frame.width)×\(frame.height), 数据大小=\(frame.rgbaData.count)B)")
    }
    
    func clearCameraFrameCache() {
        capturedCameraFrames.removeAll()
        capturedFrameCount = 0
        lastFrameCaptureTime = 0
        print("🗑️ 相机帧缓存已清空")
    }
    
    // 更新 QR 锚点
    // 策略：部署模式下始终记录，使用加权平均保持位置稳定
    func updateQRAnchor(content: String, position: SIMD3<Float>, timestamp: TimeInterval, forceRecord: Bool = false) {
        // 如果不是强制记录，且不在扫描状态，只更新 lastSeen
        if !forceRecord && scanState != .scanning {
            if var existing = qrAnchors[content] {
                existing.lastSeen = timestamp
                qrAnchors[content] = existing
            }
            return
        }
        
        if var existing = qrAnchors[content] {
            // 已有锚点：使用指数移动平均，新值权重 0.1（保持位置稳定）
            // 只有当观测次数 < 10 时才更新位置，之后就锁定
            if existing.observations < 10 {
                let alpha: Float = 0.2  // 新值权重
                existing.worldPosition = existing.worldPosition * (1 - alpha) + position * alpha
                existing.observations += 1
            }
            existing.lastSeen = timestamp
            qrAnchors[content] = existing
            print("📍 QR 锚点更新: \(content), 观测次数: \(existing.observations), 位置: (\(String(format: "%.3f, %.3f, %.3f", existing.worldPosition.x, existing.worldPosition.y, existing.worldPosition.z)))")
        } else {
            // 新锚点：直接记录
            qrAnchors[content] = QRAnchor(content: content, worldPosition: position, observations: 1, lastSeen: timestamp)
            print("📍 新 QR 锚点: \(content), 位置: (\(String(format: "%.3f, %.3f, %.3f", position.x, position.y, position.z)))")
        }
    }
    
    // 保存 QR 锚点到文件
    func saveQRAnchors(forMapURL mapURL: URL) {
        let qrURL = mapURL.deletingPathExtension().appendingPathExtension("qranchors")
        print("💾 准备保存 \(qrAnchors.count) 个 QR 锚点到: \(qrURL.path)")
        
        guard !qrAnchors.isEmpty else {
            print("⚠️ 没有 QR 锚点需要保存")
            return
        }
        
        do {
            let data = try JSONEncoder().encode(Array(qrAnchors.values))
            try data.write(to: qrURL)
            
            // 验证文件确实被保存了
            if FileManager.default.fileExists(atPath: qrURL.path) {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: qrURL.path)[.size] as? Int) ?? 0
                print("✅ QR 锚点已保存: \(qrURL.lastPathComponent), 大小: \(fileSize) bytes")
                print("📍 保存的 QR 码内容: \(qrAnchors.keys)")
            } else {
                print("❌ 文件保存后不存在！")
            }
        } catch {
            print("❌ QR 锚点保存失败: \(error)")
        }
    }
    
    // 加载 QR 锚点
    func loadQRAnchors(forMapURL mapURL: URL) {
        let qrURL = mapURL.deletingPathExtension().appendingPathExtension("qranchors")
        print("🔍 尝试加载 QR 锚点文件: \(qrURL.path)")
        
        // 列出目录中的所有 qranchors 文件
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
            let qrFiles = files.filter { $0.pathExtension == "qranchors" }
            print("📁 目录中的 .qranchors 文件: \(qrFiles.map { $0.lastPathComponent })")
        }
        
        guard FileManager.default.fileExists(atPath: qrURL.path) else {
            print("ℹ️ 没有找到 QR 锚点文件: \(qrURL.lastPathComponent)")
            return
        }
        do {
            let data = try Data(contentsOf: qrURL)
            let anchors = try JSONDecoder().decode([QRAnchor].self, from: data)
            qrAnchors = Dictionary(uniqueKeysWithValues: anchors.map { ($0.content, $0) })
            print("✅ 已加载 \(qrAnchors.count) 个 QR 锚点，内容: \(qrAnchors.keys)")
        } catch {
            print("❌ QR 锚点加载失败: \(error)")
        }
    }
    
    init() {
        Task {
            loadSavedFiles()
            loadAccountsAndRestoreSession()
        }
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var accountsFileURL: URL {
        documentsDirectory.appendingPathComponent("accounts.json")
    }

    private let currentUserIdKey = "currentUserId"

    private var accounts: [UserAccount] = []
    
    func loadSavedFiles() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Task.detached(priority: .background) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: [.creationDateKey])
                let sortedFiles = files.filter {
                    $0.pathExtension == "obj" ||
                    $0.pathExtension == "worldmap" ||
                    $0.pathExtension == "ply" ||
                    $0.pathExtension == "usdz" ||
                    $0.pathExtension == "json" ||
                    $0.pathExtension == "csv"
                }
                    .sorted {
                        let date1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                        let date2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                        return date1 > date2
                    }
                
                await MainActor.run {
                    self.savedFiles = sortedFiles
                }
            } catch {
                print("加载文件失败: \(error)")
            }
        }
    }

    private func loadAccountsAndRestoreSession() {
        let fileURL = accountsFileURL
        let storedIdString = UserDefaults.standard.string(forKey: currentUserIdKey)
        Task.detached(priority: .background) {
            let loadedAccounts: [UserAccount]
            do {
                let data = try Data(contentsOf: fileURL)
                loadedAccounts = try JSONDecoder().decode([UserAccount].self, from: data)
            } catch {
                loadedAccounts = []
            }

            let storedId = storedIdString.flatMap { UUID(uuidString: $0) }
            let restored = storedId.flatMap { id in loadedAccounts.first(where: { $0.id == id }) }

            await MainActor.run {
                self.accounts = loadedAccounts
                self.currentUser = restored
            }
        }
    }

    private func persistAccounts() {
        let fileURL = accountsFileURL
        let snapshot = accounts
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                print("保存账号失败: \(error)")
            }
        }
    }

    private func randomSalt(bytes: Int = 16) -> Data {
        var buffer = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        if status == errSecSuccess {
            return Data(buffer)
        }
        // fallback
        return Data(UUID().uuidString.utf8)
    }

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func hashPassword(_ password: String, salt: Data) -> Data {
        var data = Data()
        data.append(salt)
        data.append(Data(password.utf8))
        return sha256(data)
    }

    func registerAccount(phone: String, displayName: String, company: String, role: UserRole, password: String) {
        let cleanedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = company.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedPhone.isEmpty, !name.isEmpty else {
            alertMessage = "请输入手机号与姓名。"
            showAlert = true
            return
        }
        guard password.count >= 6 else {
            alertMessage = "密码至少 6 位。"
            showAlert = true
            return
        }
        guard !accounts.contains(where: { $0.phone == cleanedPhone }) else {
            alertMessage = "该手机号已注册。"
            showAlert = true
            return
        }

        let salt = randomSalt()
        let hash = hashPassword(password, salt: salt)
        let account = UserAccount(
            id: UUID(),
            phone: cleanedPhone,
            displayName: name,
            company: org,
            role: role,
            passwordSaltBase64: salt.base64EncodedString(),
            passwordHashBase64: hash.base64EncodedString(),
            createdAt: Date()
        )

        accounts.insert(account, at: 0)
        persistAccounts()
        currentUser = account
        UserDefaults.standard.set(account.id.uuidString, forKey: currentUserIdKey)
    }

    func login(phone: String, password: String) {
        let cleanedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = accounts.first(where: { $0.phone == cleanedPhone }) else {
            alertMessage = "账号不存在，请先注册。"
            showAlert = true
            return
        }
        guard let salt = Data(base64Encoded: account.passwordSaltBase64),
              let storedHash = Data(base64Encoded: account.passwordHashBase64) else {
            alertMessage = "账号数据损坏，请重新注册。"
            showAlert = true
            return
        }

        let inputHash = hashPassword(password, salt: salt)
        guard inputHash == storedHash else {
            alertMessage = "密码错误。"
            showAlert = true
            return
        }

        currentUser = account
        UserDefaults.standard.set(account.id.uuidString, forKey: currentUserIdKey)
    }

    func logout() {
        currentUser = nil
        isSessionStarted = false
        UserDefaults.standard.removeObject(forKey: currentUserIdKey)
    }

    func saveInspectionReport(_ report: InspectionReport) {
        isProcessing = true
        processMessage = "正在生成报告..."

        let docDir = documentsDirectory
        let fileName = "Report_\(Int(report.createdAt.timeIntervalSince1970)).json"
        let fileURL = docDir.appendingPathComponent(fileName)

        // 转换为大屏兼容格式
        let dataToWrite: Data
        do {
            var dashboardRecord: [String: Any] = [
                "id": report.id.uuidString,
                "inspector": report.inspectorName,
                "time": ISO8601DateFormatter().string(from: report.createdAt),
                "location": report.area.isEmpty ? report.boilerId : "\(report.boilerId) - \(report.area)"
            ]
            
            // 使用真实的AR位置坐标（如果有）
            if let x = report.positionX, let y = report.positionY, let z = report.positionZ {
                dashboardRecord["position"] = [
                    "x": x,
                    "y": y,
                    "z": z
                ]
            } else {
                // 如果没有坐标，使用默认值
                dashboardRecord["position"] = [
                    "x": 0.0,
                    "y": 0.0,
                    "z": 0.0
                ]
            }
            
            // 温度和压力
            if let temp = Double(report.temperatureC), !report.temperatureC.isEmpty {
                dashboardRecord["temperature"] = temp
            }
            if let pressure = Double(report.pressureMPa), !report.pressureMPa.isEmpty {
                dashboardRecord["pressure"] = pressure
            }
            
            // 判断状态
            let hasAlarm = report.abnormalNoise || report.leakage || report.vibration || 
                           report.smokeOrSteam || report.overTempOrPressure || report.alarmTriggered
            dashboardRecord["status"] = hasAlarm ? "告警" : "正常"
            
            // 异常描述
            var issues: [String] = []
            if report.abnormalNoise { issues.append("异响") }
            if report.leakage { issues.append("泄漏") }
            if report.vibration { issues.append("振动") }
            if report.smokeOrSteam { issues.append("冒烟/蒸汽") }
            if report.overTempOrPressure { issues.append("温压异常") }
            if report.alarmTriggered { issues.append("报警触发") }
            
            if !issues.isEmpty {
                dashboardRecord["issue"] = issues.joined(separator: "、")
            }
            
            // 照片（嵌入Base64以便导出到电脑查看）
            if let firstPhotoName = report.photoFileNames.first {
                // 1. 尝试读取文件内容
                let photoURL = docDir.appendingPathComponent(firstPhotoName)
                if let photoData = try? Data(contentsOf: photoURL) {
                     // 简单判断文件扩展名以确定MIME type (默认jpg)
                     let mimeType = firstPhotoName.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
                     let base64String = photoData.base64EncodedString()
                     dashboardRecord["photo"] = "data:\(mimeType);base64,\(base64String)"
                } else {
                     // 只有文件名
                     dashboardRecord["photo"] = firstPhotoName
                }
            }
            
            // 描述
            if !report.notes.isEmpty {
                dashboardRecord["description"] = report.notes
            } else {
                dashboardRecord["description"] = hasAlarm ? "发现异常情况，需要处理" : "设备运行正常"
            }
            
            // 组装完整数据结构（保留原有字段供App内部使用）
            let fullData: [String: Any] = [
                "project": "锅炉房安全巡检",
                "exportTime": ISO8601DateFormatter().string(from: Date()),
                "record": dashboardRecord,
                // 原始数据用于App内部读取
                "_appData": [
                    "inspectorId": report.inspectorId.uuidString,
                    "inspectorRole": report.inspectorRole.rawValue,
                    "boilerId": report.boilerId,
                    "area": report.area,
                    "waterLevel": report.waterLevel,
                    "valvePosition": report.valvePosition,
                    "photoFileNames": report.photoFileNames,
                    "signatureFileName": report.signatureFileName ?? "",
                    "signerName": report.signerName,
                    "confirmationChecked": report.confirmationChecked
                ]
            ]
            
            dataToWrite = try JSONSerialization.data(withJSONObject: fullData, options: .prettyPrinted)
        } catch {
            isProcessing = false
            alertMessage = "报告生成失败: \(error.localizedDescription)"
            showAlert = true
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                try dataToWrite.write(to: fileURL, options: [.atomic])

                await MainActor.run {
                    self.isProcessing = false
                    self.alertMessage = "✅ 报告已生成：\(fileName)"
                    self.showAlert = true
                    self.loadSavedFiles()
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.alertMessage = "报告生成失败: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    func loadLatestWorldMap() {
        // savedFiles 已按创建时间倒序
        if let latest = savedFiles.first(where: { $0.pathExtension == "worldmap" && $0.lastPathComponent.hasPrefix("Map_") }) {
            loadWorldMap(url: latest)
        } else {
            alertMessage = "未找到可加载的地图文件（Map_*.worldmap）。请先在部署建图模式下保存地图。"
            showAlert = true
        }
    }
    
    func deleteFile(at offsets: IndexSet) {
        offsets.forEach { index in
            let url = savedFiles[index]
            try? FileManager.default.removeItem(at: url)
        }
        loadSavedFiles()
    }
    func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            isTorchEnabled = on
        } catch {
            print("手电筒控制失败: \(error)")
        }
    }
    
    // 导出 Mesh (支持 OBJ 和 PLY)
    func exportMesh(anchors: [ARMeshAnchor]) {
        guard !anchors.isEmpty else {
            alertMessage = "当前没有扫描到任何网格数据。"
            showAlert = true
            return
        }
        
        // ⚠️ 导出诊断（关键日志）
        print("\n=============================")
        print("📦 开始导出 | 模式: \(self.coloringMode) | 网格块数: \(anchors.count)")
        print("📦 纹理帧缓存: \(self.capturedCameraFrames.count) 帧")
        if self.coloringMode == .texture && self.capturedCameraFrames.isEmpty {
            print("❌❌❌ 严重问题: 选择了真实纹理模式但没有相机帧！请先开启纹理采集按钮再扫描！")
        }
        print("=============================\n")
        
        isProcessing = true
        processMessage = "正在处理 \(anchors.count) 个网格块..."
        
        // 1. 提取数据 (主线程)
        let rawData = anchors.map { anchor -> (transform: simd_float4x4, vertexData: Data, faceData: Data, classData: Data?, vertexCount: Int, faceCount: Int, vertexStride: Int, faceBytesPerIndex: Int) in
            let transform = anchor.transform
            let geometry = anchor.geometry
            
            // 顶点
            let vertices = geometry.vertices
            var vertexData = Data()
            var vertexCount = 0
            let vertexStride = vertices.stride
            if vertices.format == .float3 {
                vertexCount = vertices.count
                vertexData = Data(bytes: vertices.buffer.contents(), count: vertexStride * vertexCount)
            }
            
            // 面
            let faces = geometry.faces
            let faceCount = faces.count * faces.indexCountPerPrimitive
            let faceBytesPerIndex = faces.bytesPerIndex
            let faceData = Data(bytes: faces.buffer.contents(), count: faceBytesPerIndex * faceCount)
            
            // 分类数据 (仅在需要时提取)
            var classData: Data? = nil
            if self.coloringMode == .ai, let classification = geometry.classification {
                // classification.buffer 包含每个面的分类索引
                // 必须用 stride * count 计算总字节数，不能直接用 count
                let byteCount = classification.stride * classification.count
                classData = Data(bytes: classification.buffer.contents().advanced(by: classification.offset), count: byteCount)
                print("📦 分类数据: count=\(classification.count), stride=\(classification.stride), offset=\(classification.offset), format=\(classification.format.rawValue), bytes=\(byteCount)")
            }
            
            return (transform, vertexData, faceData, classData, vertexCount, faceCount, vertexStride, faceBytesPerIndex)
        }
        
        let mode = self.coloringMode
        let framesSnapshot = mode == .texture ? self.capturedCameraFrames : []
        
        // ℹ️ 计算总顶点数用于日志
        let totalVerts = rawData.reduce(0) { $0 + $1.vertexCount }
        print("📦 rawData: \(rawData.count) 个网格块, 总顶点数=\(totalVerts), framesSnapshot=\(framesSnapshot.count)")
        print("📦 当前导出模式: \(mode) | 帧缓存中有: \(self.capturedCameraFrames.count) 帧")
        
        // ❗️ 真实纹理模式但没有帧 —— 给用户明确提示
        if mode == .texture && framesSnapshot.isEmpty {
            isProcessing = false
            alertMessage = "❌ 没有纹理帧数据！\n\n请先点击相机图标开启纹理采集，扫描时自动捕获相机画面，然后再导出。"
            showAlert = true
            return
        }
        
        // 3. 后台处理
        Task.detached(priority: .userInitiated) {
            do {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                
                if mode == .none {
                    // 导出 OBJ (白模)
                    print("🔄 进入白模 (OBJ) 导出分支")
                    let fileName = "Scan_\(Int(Date().timeIntervalSince1970)).obj"
                    let fileURL = docDir.appendingPathComponent(fileName)
                    let content = self.generateOBJFromRawData(data: rawData)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                } else if mode == .texture {
                    // 导出 PLY (真实纹理)
                    print("🔄 进入真实纹理 (PLY) 导出分支")
                    await MainActor.run {
                        self.processMessage = "正在映射真实纹理（\(framesSnapshot.count) 帧, \(totalVerts) 个顶点）...\n顶点较多时可能需要 1-3 分钟"
                    }
                    let fileName = "Scan_\(Int(Date().timeIntervalSince1970))_textured.ply"
                    let fileURL = docDir.appendingPathComponent(fileName)
                    let content = self.generateTexturedPLYFromRawData(data: rawData, frames: framesSnapshot)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                } else {
                    // 导出 PLY (AI 分类色)
                    print("🔄 进入 AI 语义色 (PLY) 导出分支")
                    let fileName = "Scan_\(Int(Date().timeIntervalSince1970)).ply"
                    let fileURL = docDir.appendingPathComponent(fileName)
                    let content = self.generatePLYFromRawData(data: rawData, mode: mode)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                }
                
                await MainActor.run {
                    self.isProcessing = false
                    self.alertMessage = "模型已保存！"
                    self.showAlert = true
                    self.loadSavedFiles()
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.alertMessage = "导出失败: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
    
    // 保存 ARWorldMap
    func saveWorldMap(session: ARSession) {
        // 1. 预检查：如果地图构建程度不够，直接提示用户，不要尝试保存
        if let status = session.currentFrame?.worldMappingStatus {
            if status == .notAvailable || status == .limited {
                alertMessage = "⚠️ 地图数据不足，无法保存。\n\n请继续移动设备扫描周围环境，直到左上角状态变为“扩展中”或“已定位”。"
                showAlert = true
                return
            }
        }
        
        isProcessing = true
        processMessage = "正在保存环境地图..."
        
        session.getCurrentWorldMap { worldMap, error in
            Task { @MainActor in
                defer { self.isProcessing = false }
                
                if let error = error {
                    self.alertMessage = "地图保存失败: \(error.localizedDescription)"
                    self.showAlert = true
                    return
                }
                
                guard let map = worldMap else { return }
                
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    let fileName = "Map_\(Int(Date().timeIntervalSince1970)).worldmap"
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let fileURL = docDir.appendingPathComponent(fileName)
                    try data.write(to: fileURL)
                    
                    // 同时保存 QR 锚点
                    let qrCount = self.qrAnchors.count
                    self.saveQRAnchors(forMapURL: fileURL)
                    
                    let qrMsg = qrCount > 0 ? "\n已关联 \(qrCount) 个 QR 码锚点。" : ""
                    self.alertMessage = "地图保存成功！下次可加载此地图进行重定位。\(qrMsg)"
                    self.showAlert = true
                    self.loadSavedFiles()
                } catch {
                    self.alertMessage = "地图写入失败: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }
    
    // 加载 ARWorldMap
    func loadWorldMap(url: URL) {
        mapToLoad = url
        shouldResetSession = true
        selectedTab = 0 // 自动跳回扫描页
        
        // 加载关联的 QR 锚点
        loadQRAnchors(forMapURL: url)
        let qrMsg = qrAnchors.count > 0 ? "\n已加载 \(qrAnchors.count) 个 QR 码锚点，扫描到 QR 码时将自动校正位置。" : ""
        
        alertMessage = "正在加载地图，请移动设备以进行重定位...\(qrMsg)"
        showAlert = true
    }

    // 纯逻辑函数，处理纯数据 (OBJ)
    nonisolated private func generateOBJFromRawData(data: [(transform: simd_float4x4, vertexData: Data, faceData: Data, classData: Data?, vertexCount: Int, faceCount: Int, vertexStride: Int, faceBytesPerIndex: Int)]) -> String {
        var objText = "# BoilerPatrol Scan Export (OBJ)\n"
        var vertexOffset: Int32 = 1
        
        for item in data {
            let transform = item.transform
            let vertexCount = item.vertexCount
            let faceCount = item.faceCount
            let stride = item.vertexStride
            let bytesPerIndex = item.faceBytesPerIndex
            
            // 顶点处理
            item.vertexData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let baseAddress = buffer.baseAddress else { return }
                for i in 0..<vertexCount {
                    let offset = i * stride
                    let x = baseAddress.load(fromByteOffset: offset, as: Float.self)
                    let y = baseAddress.load(fromByteOffset: offset + 4, as: Float.self)
                    let z = baseAddress.load(fromByteOffset: offset + 8, as: Float.self)
                    
                    let vertex4 = simd_float4(x, y, z, 1)
                    let worldVertex = transform * vertex4
                    objText += String(format: "v %.4f %.4f %.4f\n", worldVertex.x, worldVertex.y, worldVertex.z)
                }
            }
            
            // 面处理
            item.faceData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let baseAddress = buffer.baseAddress else { return }
                let triangleCount = faceCount / 3
                for i in 0..<triangleCount {
                    let base = i * 3
                    var i0: Int32 = 0
                    var i1: Int32 = 0
                    var i2: Int32 = 0
                    
                    if bytesPerIndex == 2 {
                        let offset0 = base * 2
                        let offset1 = (base + 1) * 2
                        let offset2 = (base + 2) * 2
                        i0 = Int32(baseAddress.load(fromByteOffset: offset0, as: Int16.self))
                        i1 = Int32(baseAddress.load(fromByteOffset: offset1, as: Int16.self))
                        i2 = Int32(baseAddress.load(fromByteOffset: offset2, as: Int16.self))
                    } else {
                        let offset0 = base * 4
                        let offset1 = (base + 1) * 4
                        let offset2 = (base + 2) * 4
                        i0 = baseAddress.load(fromByteOffset: offset0, as: Int32.self)
                        i1 = baseAddress.load(fromByteOffset: offset1, as: Int32.self)
                        i2 = baseAddress.load(fromByteOffset: offset2, as: Int32.self)
                    }
                    
                    objText += "f \(i0 + vertexOffset) \(i1 + vertexOffset) \(i2 + vertexOffset)\n"
                }
            }
            
            vertexOffset += Int32(vertexCount)
        }
        return objText
    }
    
    // 纯逻辑函数，处理纯数据 (PLY 带颜色)
    nonisolated private func generatePLYFromRawData(data: [(transform: simd_float4x4, vertexData: Data, faceData: Data, classData: Data?, vertexCount: Int, faceCount: Int, vertexStride: Int, faceBytesPerIndex: Int)], mode: ColoringMode) -> String {
        var plyHeader = "ply\nformat ascii 1.0\ncomment BoilerPatrol Scan Export (PLY)\n"
        
        // 1. 计算总顶点数和总面数
        // 注意：为了给每个面赋予不同的颜色（分类是基于面的），我们需要将网格“解压”为三角形列表（Triangle Soup）。
        // 这意味着每个三角形都有自己独立的 3 个顶点，不共享。虽然文件变大，但能保证颜色边界清晰。
        var totalFaces = 0
        for item in data {
            totalFaces += item.faceCount / 3
        }
        let totalVertices = totalFaces * 3
        
        plyHeader += "\nelement vertex \(totalVertices)"
        plyHeader += "\nproperty float x\nproperty float y\nproperty float z"
        plyHeader += "\nproperty uchar red\nproperty uchar green\nproperty uchar blue"
        plyHeader += "\nelement face \(totalFaces)"
        plyHeader += "\nproperty list uchar int vertex_index"
        plyHeader += "\nend_header\n"
        
        var plyBody = ""
        
        for item in data {
            let transform = item.transform
            let stride = item.vertexStride
            let bytesPerIndex = item.faceBytesPerIndex
            let triangleCount = item.faceCount / 3
            
            // 准备数据指针
            // ⚠️ 关键：所有 withUnsafeBytes 必须嵌套，指针只在闭包内有效！
            item.vertexData.withUnsafeBytes { vBuffer in
                guard let vBase = vBuffer.baseAddress else { return }
                
                item.faceData.withUnsafeBytes { fBuffer in
                    guard let fBase = fBuffer.baseAddress else { return }
                    
                    // 分类数据必须在同一个嵌套作用域内访问
                    // 不能把指针赋值给外部变量后在闭包外使用（悬空指针！）
                    let classBytes: [UInt8]
                    if mode == .ai, let cData = item.classData {
                        classBytes = [UInt8](cData)
                    } else {
                        classBytes = []
                    }
                    
                    for i in 0..<triangleCount {
                        // 1. 获取当前三角形的 3 个顶点索引
                        var idx0: Int = 0
                        var idx1: Int = 0
                        var idx2: Int = 0
                        
                        let base = i * 3
                        if bytesPerIndex == 2 {
                            idx0 = Int(fBase.load(fromByteOffset: base * 2, as: Int16.self))
                            idx1 = Int(fBase.load(fromByteOffset: (base + 1) * 2, as: Int16.self))
                            idx2 = Int(fBase.load(fromByteOffset: (base + 2) * 2, as: Int16.self))
                        } else {
                            idx0 = Int(fBase.load(fromByteOffset: base * 4, as: Int32.self))
                            idx1 = Int(fBase.load(fromByteOffset: (base + 1) * 4, as: Int32.self))
                            idx2 = Int(fBase.load(fromByteOffset: (base + 2) * 4, as: Int32.self))
                        }
                        
                        // 2. 获取颜色
                        var color: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
                        if mode == .ai && i < classBytes.count {
                            let classIndex = classBytes[i]
                            color = getColorForClassification(classIndex)
                        }
                        
                        // 3. 写入 3 个顶点 (解压)
                        let indices = [idx0, idx1, idx2]
                        for idx in indices {
                            let offset = idx * stride
                            let x = vBase.load(fromByteOffset: offset, as: Float.self)
                            let y = vBase.load(fromByteOffset: offset + 4, as: Float.self)
                            let z = vBase.load(fromByteOffset: offset + 8, as: Float.self)
                            
                            let v4 = simd_float4(x, y, z, 1)
                            let wv = transform * v4
                            
                            plyBody += String(format: "%.4f %.4f %.4f %d %d %d\n", wv.x, wv.y, wv.z, color.r, color.g, color.b)
                        }
                    }
                }
            }
        }
        
        // 4. 写入面索引 (因为我们解压了，所以索引是连续的: 0 1 2, 3 4 5...)
        for i in 0..<totalFaces {
            let base = i * 3
            plyBody += "3 \(base) \(base+1) \(base+2)\n"
        }
        
        return plyHeader + plyBody
    }
    
    nonisolated private func getColorForClassification(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        // ARMeshClassification 枚举值映射
        // 0: none, 1: wall, 2: floor, 3: ceiling, 4: table, 5: seat, 6: window, 7: door
        switch index {
        case 1: return (255, 0, 0)     // Wall: Red
        case 2: return (0, 255, 0)     // Floor: Green
        case 3: return (0, 0, 255)     // Ceiling: Blue
        case 4: return (255, 255, 0)   // Table: Yellow
        case 5: return (0, 255, 255)   // Seat: Cyan
        case 6: return (255, 0, 255)   // Window: Magenta
        case 7: return (128, 64, 0)    // Door: Brown
        default: return (200, 200, 200) // Other: Gray
        }
    }
    
    // MARK: - 真实纹理 PLY 导出（相机颜色投影到网格顶点）
    nonisolated private func generateTexturedPLYFromRawData(
        data: [(transform: simd_float4x4, vertexData: Data, faceData: Data, classData: Data?, vertexCount: Int, faceCount: Int, vertexStride: Int, faceBytesPerIndex: Int)],
        frames: [CapturedCameraFrame]
    ) -> String {
        
        // Step 1: 提取所有世界空间顶点和面
        var allVertices: [(x: Float, y: Float, z: Float)] = []
        var allFaces: [(Int, Int, Int)] = []
        var vertexOffset = 0
        
        for item in data {
            let transform = item.transform
            let stride = item.vertexStride
            let bytesPerIndex = item.faceBytesPerIndex
            let triangleCount = item.faceCount / 3
            
            // 提取世界空间顶点
            item.vertexData.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                for i in 0..<item.vertexCount {
                    let offset = i * stride
                    let x = base.load(fromByteOffset: offset, as: Float.self)
                    let y = base.load(fromByteOffset: offset + 4, as: Float.self)
                    let z = base.load(fromByteOffset: offset + 8, as: Float.self)
                    let v4 = simd_float4(x, y, z, 1)
                    let wv = transform * v4
                    allVertices.append((wv.x, wv.y, wv.z))
                }
            }
            
            // 提取面索引
            item.faceData.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                for i in 0..<triangleCount {
                    let b = i * 3
                    var i0, i1, i2: Int
                    if bytesPerIndex == 2 {
                        i0 = Int(base.load(fromByteOffset: b * 2, as: UInt16.self))
                        i1 = Int(base.load(fromByteOffset: (b + 1) * 2, as: UInt16.self))
                        i2 = Int(base.load(fromByteOffset: (b + 2) * 2, as: UInt16.self))
                    } else {
                        i0 = Int(base.load(fromByteOffset: b * 4, as: UInt32.self))
                        i1 = Int(base.load(fromByteOffset: (b + 1) * 4, as: UInt32.self))
                        i2 = Int(base.load(fromByteOffset: (b + 2) * 4, as: UInt32.self))
                    }
                    allFaces.append((i0 + vertexOffset, i1 + vertexOffset, i2 + vertexOffset))
                }
            }
            
            vertexOffset += item.vertexCount
        }
        
        print("🎨 纹理映射: \(allVertices.count) 个顶点, \(allFaces.count) 个面, \(frames.count) 帧相机数据")
        
        // 打印顶点坐标范围（诊断用）
        if !allVertices.isEmpty {
            let xs = allVertices.map { $0.x }
            let ys = allVertices.map { $0.y }
            let zs = allVertices.map { $0.z }
            print("📊 顶点范围: X[\(String(format:"%.2f",xs.min()!))~\(String(format:"%.2f",xs.max()!))] Y[\(String(format:"%.2f",ys.min()!))~\(String(format:"%.2f",ys.max()!))] Z[\(String(format:"%.2f",zs.min()!))~\(String(format:"%.2f",zs.max()!))]")
        }
        
        if frames.isEmpty {
            print("❌ 纹理映射失败: 没有相机帧数据！请确保扫描时开启了纹理采集按钮。")
            // 返回默认灰色模型而不是继续处理
        } else {
            let f = frames[0]
            print("📐 首帧信息: \(f.width)×\(f.height), fx=\(f.intrinsics[0][0]), fy=\(f.intrinsics[1][1]), cx=\(f.intrinsics[2][0]), cy=\(f.intrinsics[2][1])")
            // 打印首帧相机位置
            let camPos = f.transform.columns.3
            print("📍 首帧相机位置: (\(String(format:"%.2f",camPos.x)), \(String(format:"%.2f",camPos.y)), \(String(format:"%.2f",camPos.z)))")
            // 验证首帧 RGBA 数据不为全零
            let expectedSize = f.width * f.height * 4
            let actualSize = f.rgbaData.count
            print("📐 首帧 RGBA: expected=\(expectedSize) bytes, actual=\(actualSize) bytes")
            if actualSize > 0 {
                // 采样几个像素检查颜色值
                let midOffset = (f.height / 2 * f.width + f.width / 2) * 4
                if midOffset + 3 < actualSize {
                    let r = f.rgbaData[midOffset], g = f.rgbaData[midOffset+1], b = f.rgbaData[midOffset+2]
                    print("📐 首帧中心像素颜色: R=\(r) G=\(g) B=\(b)")
                }
            }
            
            // ==== 关键诊断：检查第一个顶点能否投影到第一帧 ====
            if !allVertices.isEmpty {
                let testVertex = allVertices[0]
                let worldPos = simd_float4(testVertex.x, testVertex.y, testVertex.z, 1)
                let viewMatrix = simd_inverse(f.transform)
                let camPos = viewMatrix * worldPos
                print("🔬 测试投影: 顶点世界坐标=(\(String(format:"%.2f",testVertex.x)), \(String(format:"%.2f",testVertex.y)), \(String(format:"%.2f",testVertex.z)))")
                print("🔬 相机空间坐标: x=\(String(format:"%.2f",camPos.x)), y=\(String(format:"%.2f",camPos.y)), z=\(String(format:"%.2f",camPos.z))")
                
                let depth = -camPos.z
                print("🔬 深度 = \(String(format:"%.2f",depth))m (z>0.1表示在背后, depth应>0.05)")
                
                if depth > 0.05 {
                    let u = f.intrinsics[0][0] * (camPos.x / depth) + f.intrinsics[2][0]
                    let v = f.intrinsics[1][1] * (-camPos.y / depth) + f.intrinsics[2][1]
                    print("🔬 投影像素: u=\(String(format:"%.1f",u)), v=\(String(format:"%.1f",v)) | 图像尺寸: \(f.width)×\(f.height)")
                    print("🔬 像素合法范围: [0,\(f.width)) x [0,\(f.height))")
                }
            }
        }
        
        // Step 2: 预计算所有帧的 view matrix（逆变换矩阵）
        let viewMatrices = frames.map { simd_inverse($0.transform) }
        
        // Step 3: 为每个顶点找到最佳相机帧并采样颜色
        var vertexColors: [(UInt8, UInt8, UInt8)] = Array(repeating: (180, 180, 180), count: allVertices.count)
        
        let totalVertices = allVertices.count
        var coloredCount = 0
        
        // 🔍 诊断：为前 3 个顶点打印完整投影过程
        let diagVertexCount = min(3, totalVertices)
        
        for (vi, vertex) in allVertices.enumerated() {
            let worldPos = simd_float4(vertex.x, vertex.y, vertex.z, 1)
            let isDiagVertex = vi < diagVertexCount
            
            var bestScore: Float = -1
            var bestColor: (UInt8, UInt8, UInt8) = (180, 180, 180)
            
            for (fi, frame) in frames.enumerated() {
                // 变换到相机局部坐标系 (ARKit: -Z Forward)
                let camPos = viewMatrices[fi] * worldPos
                
                // 宽松检查：如果完全在相机后面才跳过 (z > 0.1)
                // 正常 ARKit 可视范围 z 应为负值
                // 如果 z 为正数 (0.1以上)，说明点在相机背后
                if camPos.z > 0.1 {
                     if isDiagVertex && fi == 0 { print("   ❌ 在相机背后 (z=\(String(format:"%.2f",camPos.z)))") }
                     continue
                }
                
                let depth = -camPos.z
                
                // 距离过近或过远过滤
                guard depth > 0.05 && depth < 8.0 else {
                    if isDiagVertex && fi == 0 { print("   ❌ 深度无效 depth=\(String(format:"%.2f",depth))m") }
                    continue
                }
                
                // 投影到图像像素坐标
                // ARKit 相机坐标系: -Z 向前, +Y 向上
                // 图像坐标系: +v 向下, 原点左上角
                // depth = -camPos.z (正值)
                // u = fx * (X / depth) + cx
                // v = cy - fy * (Y / depth) = fy * (-Y / depth) + cy
                let u = frame.intrinsics[0][0] * (camPos.x / depth) + frame.intrinsics[2][0]
                let v = frame.intrinsics[1][1] * (-camPos.y / depth) + frame.intrinsics[2][1]
                
                let px = Int(u)
                let py = Int(v)
                
                // 检查是否在图像范围内（留边距避免边缘畸变）
                let margin = 15
                if isDiagVertex && fi == 0 {
                    print("   → 投影像素 u=\(String(format:"%.1f",u)) v=\(String(format:"%.1f",v)) | 图像\(frame.width)×\(frame.height) | depth=\(String(format:"%.2f",depth))m")
                    print("   → 合法范围: [\(margin), \(frame.width-margin)] × [\(margin), \(frame.height-margin)]")
                }
                guard px >= margin, px < frame.width - margin,
                      py >= margin, py < frame.height - margin else {
                    if isDiagVertex && fi == 0 { print("   ❌ 投影超出图像范围") }
                    continue
                }
                
                // 评分: 距离越近越好 + 越靠近图像中心越好
                let centerX = Float(frame.width) / 2
                let centerY = Float(frame.height) / 2
                let centerDist = sqrt(pow(u - centerX, 2) + pow(v - centerY, 2))
                let maxCenterDist = sqrt(pow(centerX, 2) + pow(centerY, 2))
                let centerScore = 1.0 - (centerDist / maxCenterDist)
                
                let distanceScore = 1.0 / (1.0 + depth)
                
                let score = centerScore * 0.4 + distanceScore * 0.6
                
                if score > bestScore {
                    if let color = frame.sampleColor(atX: px, y: py) {
                        bestScore = score
                        bestColor = color
                    }
                }
            }
            
            vertexColors[vi] = bestColor
            if bestScore > 0 { coloredCount += 1 }
            
            // 前几个着色成功的顶点 debug 输出
            if bestScore > 0 && coloredCount <= 3 {
                print("🎯 顶点#\(vi) 有色: R=\(bestColor.0) G=\(bestColor.1) B=\(bestColor.2), score=\(String(format: "%.3f", bestScore))")
            }
            
            // 进度日志
            if vi > 0 && vi % 50000 == 0 {
                print("🎨 纹理映射进度: \(vi)/\(totalVertices) (\(Int(Float(vi) / Float(totalVertices) * 100))%), 已着色: \(coloredCount)")
            }
        }
        
        print("✅ 纹理映射完成: \(coloredCount)/\(totalVertices) 个顶点有颜色 (\(Int(Float(coloredCount) / max(Float(totalVertices), 1) * 100))%)")
        
        // 诊断：统计最终颜色分布
        var grayCount = 0  // 默认灰色 (180, 180, 180)
        var colorfulCount = 0
        var colorSamples: [(UInt8, UInt8, UInt8)] = []
        for color in vertexColors {
            if color.0 == 180 && color.1 == 180 && color.2 == 180 {
                grayCount += 1
            } else {
                colorfulCount += 1
                if colorSamples.count < 5 {
                    colorSamples.append(color)
                }
            }
        }
        print("📊 颜色统计: 灰色(默认)=\(grayCount), 有色=\(colorfulCount)")
        if !colorSamples.isEmpty {
            print("🎨 颜色样本: \(colorSamples.map { "(\($0.0),\($0.1),\($0.2))" }.joined(separator: ", "))")
        }
        
        // Step 4: 写入 PLY 文件（按顶点着色，文件更小）
        var ply = "ply\n"
        ply += "format ascii 1.0\n"
        ply += "comment BoilerPatrol Textured Scan Export\n"
        ply += "comment Colored by camera projection (\(frames.count) frames)\n"
        ply += "element vertex \(allVertices.count)\n"
        ply += "property float x\n"
        ply += "property float y\n"
        ply += "property float z\n"
        ply += "property uchar red\n"
        ply += "property uchar green\n"
        ply += "property uchar blue\n"
        ply += "element face \(allFaces.count)\n"
        ply += "property list uchar int vertex_index\n"
        ply += "end_header\n"
        
        for (i, v) in allVertices.enumerated() {
            let c = vertexColors[i]
            ply += String(format: "%.4f %.4f %.4f %d %d %d\n", v.x, v.y, v.z, c.0, c.1, c.2)
        }
        
        for f in allFaces {
            ply += "3 \(f.0) \(f.1) \(f.2)\n"
        }
        
        return ply
    }
}

// MARK: - 2. Main View Structure
struct ContentView: View {
    @StateObject private var appModel = AppModel()
    
    var body: some View {
        Group {
            if appModel.currentUser == nil {
                AuthView(appModel: appModel)
            } else {
                TabView(selection: $appModel.selectedTab) {
                    ScanView(appModel: appModel)
                        .tabItem {
                            Label("空间扫描", systemImage: "arkit")
                        }
                        .tag(0)
                    
                    FileLibraryView(appModel: appModel)
                        .tabItem {
                            Label("文件库", systemImage: "folder.fill")
                        }
                        .tag(1)
                    
                    if #available(iOS 17.0, *) {
                        ObjectCaptureContainer(appModel: appModel)
                            .tabItem {
                                Label("物体扫描", systemImage: "cube.fill")
                            }
                            .tag(2)
                    } else {
                        Text("物体扫描功能需要 iOS 17 或更高版本")
                            .tabItem {
                                Label("物体扫描", systemImage: "cube.fill")
                            }
                            .tag(2)
                    }
                    
                    PrecisionTestView(mode: .staticRail, session: appModel.precisionARSession, appModel: appModel)
                        .tabItem {
                            Label("静态测试", systemImage: "ruler.fill")
                        }
                        .tag(3)

                    PrecisionTestView(mode: .staticBlind, session: appModel.precisionARSession, appModel: appModel)
                        .tabItem {
                            Label("静态(省热)", systemImage: "thermometer.low")
                        }
                        .tag(4)

                    PrecisionTestView(mode: .dynamicHand, session: appModel.precisionARSession, appModel: appModel)
                        .tabItem {
                            Label("精确模式", systemImage: "camera.aperture")
                        }
                        .tag(5)

                    RadarMountedView(session: appModel.precisionARSession, appModel: appModel)
                        .tabItem {
                            Label("导轨安装", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tag(7)

                    SettingsView(appModel: appModel)
                        .tabItem {
                            Label("设置", systemImage: "gearshape.fill")
                        }
                        .tag(6)
                }
                .onChange(of: appModel.selectedTab) { oldTab, newTab in
                    // 切换到物体扫描时，强制停止 ARSession 释放相机
                    if newTab == 2 {
                        print("📢 切换到物体扫描 Tab，发送停止 ARSession 通知...")
                        NotificationCenter.default.post(name: NSNotification.Name("forceStopARSession"), object: nil)
                        appModel.isSessionStarted = false
                        // 离开精确测试 Tab 时暂停共享 session
                        appModel.precisionARSession.pause()
                    }
                    // 切换离开精确测试 Tab 时暂停共享 session
                    if [3, 4, 5, 7].contains(oldTab) && ![3, 4, 5, 7].contains(newTab) {
                        appModel.precisionARSession.pause()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("系统提示", isPresented: $appModel.showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(appModel.alertMessage)
        }
        .sheet(isPresented: $appModel.showFileViewer) {
            if let url = appModel.selectedFile {
                FileViewer(url: url, appModel: appModel)
            }
        }
    }
}

// MARK: - Auth
private struct AuthView: View {
    @ObservedObject var appModel: AppModel

    @State private var isLogin: Bool = true

    @State private var phone: String = ""
    @State private var password: String = ""

    @State private var displayName: String = ""
    @State private var company: String = ""
    @State private var role: AppModel.UserRole = .worker
    @State private var confirmPassword: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("操作", selection: $isLogin) {
                        Text("登录").tag(true)
                        Text("注册").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("账号")) {
                    TextField("手机号", text: $phone)
                        .keyboardType(.phonePad)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                }

                if !isLogin {
                    Section(header: Text("个人信息")) {
                        TextField("姓名", text: $displayName)
                        TextField("单位/班组（可选）", text: $company)

                        Picker("身份", selection: $role) {
                            ForEach(AppModel.UserRole.allCases) { r in
                                Text(r.rawValue).tag(r)
                            }
                        }
                    }

                    Section(header: Text("确认")) {
                        SecureField("再次输入密码", text: $confirmPassword)
                    }
                }

                Section {
                    Button(isLogin ? "登录" : "注册") {
                        if isLogin {
                            appModel.login(phone: phone, password: password)
                        } else {
                            guard password == confirmPassword else {
                                appModel.alertMessage = "两次密码不一致。"
                                appModel.showAlert = true
                                return
                            }
                            appModel.registerAccount(
                                phone: phone,
                                displayName: displayName,
                                company: company,
                                role: role,
                                password: password
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.black)
                    .listRowBackground(Color.yellow)
                }
            }
            .navigationTitle("账号")
            .tint(.yellow)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }
}

// MARK: - 2.5 Settings View
struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var showImagePicker: Bool = false
    @State private var selectedImage: UIImage?
    
    var body: some View {
        NavigationView {
            Form {
                if let user = appModel.currentUser {
                    // 个人信息区域
                    Section(header: Text("个人信息")) {
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                // 头像
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 100, height: 100)
                                    
                                    if let image = selectedImage {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 100)
                                            .clipShape(Circle())
                                    } else {
                                        Text(user.displayName.prefix(1))
                                            .font(.system(size: 40, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    
                                    // 编辑按钮
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                        .offset(x: 35, y: 35)
                                }
                                .onTapGesture {
                                    showImagePicker = true
                                }
                                
                                Text(user.displayName)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                
                                Text(user.role.rawValue)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        
                        LabeledContent("手机号", value: user.phone)
                        LabeledContent("单位/班组", value: user.company.isEmpty ? "未填写" : user.company)
                        LabeledContent("注册时间", value: user.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    
                    // 工具与测试
                    Section(header: Text("开发者工具")) {
                        NavigationLink(destination: PowerTestView()) {
                            Label {
                                Text("最大功率耗电测试")
                                    .foregroundColor(.primary)
                            } icon: {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
                    // 巡检统计
                    Section(header: Text("巡检统计")) {
                        let reportCount = appModel.savedFiles.filter { 
                            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("Report_")
                        }.count
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(reportCount)")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)
                                Text("巡检报告")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("\(appModel.savedFiles.filter { $0.pathExtension == "worldmap" }.count)")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.green)
                                Text("环境地图")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("\(appModel.savedFiles.filter { $0.pathExtension == "ply" || $0.pathExtension == "obj" }.count)")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.orange)
                                Text("3D模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // 账号管理
                    Section(header: Text("账号管理")) {
                        Button(role: .destructive) {
                            appModel.logout()
                        } label: {
                            Label("退出登录", systemImage: "arrow.right.square")
                        }
                    }
                }
                
                Section(header: Text("关于")) {
                    LabeledContent("版本", value: "2.0.0")
                    LabeledContent("编译版本", value: "Build 20260123")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $selectedImage)
        }
    }
}

// 扫描设置页（从主设置中分离）
struct ScanSettingsSheet: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("扫描配置")) {
                    Toggle("启用 LiDAR 网格", isOn: $appModel.isLiDAREnabled)
                        .tint(.yellow)
                    
                    Toggle("启用 AI 语义上色", isOn: $appModel.isMeshColoringEnabled)
                        .tint(.yellow)
                        .disabled(!appModel.isLiDAREnabled) // LiDAR关了就没意义了
                        
                    Toggle("手电筒补光", isOn: $appModel.isTorchEnabled)
                        .tint(.yellow)
                        .onChange(of: appModel.isTorchEnabled) { _, newValue in
                            appModel.toggleTorch(on: newValue)
                        }
                }
                
                Section(header: Text("QR 码重定位")) {
                    HStack {
                        Text("QR 码物理尺寸")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { Int(appModel.qrCodePhysicalSize * 100) },
                            set: { appModel.qrCodePhysicalSize = Float($0) / 100.0 }
                        )) {
                            Text("5cm").tag(5)
                            Text("8cm").tag(8)
                            Text("10cm").tag(10)
                            Text("15cm").tag(15)
                            Text("20cm").tag(20)
                        }
                        .pickerStyle(.menu)
                    }
                    
                    HStack {
                        Text("已识别 QR 锚点")
                        Spacer()
                        Text("\(appModel.qrAnchors.count) 个")
                            .foregroundStyle(.secondary)
                    }

                    Toggle("巡检时自动重定位", isOn: $appModel.isAutoQRRelocalizationEnabled)
                        .tint(.blue)
                    
                    if appModel.relocalizationOffset != .zero {
                        HStack {
                            Text("当前校正偏移")
                            Spacer()
                            Text(String(format: "%.0fcm", simd_length(appModel.relocalizationOffset) * 100))
                                .foregroundStyle(.green)
                        }
                        
                        Button(role: .destructive) {
                            appModel.relocalizationOffset = .zero
                        } label: {
                            Label("清除校正偏移", systemImage: "xmark.circle")
                        }
                    }
                    
                    if !appModel.qrAnchors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(appModel.qrAnchors.keys.sorted().prefix(5)), id: \.self) { key in
                                if let anchor = appModel.qrAnchors[key] {
                                    let pos = anchor.worldPosition
                                    Text("📍 \(key.replacingOccurrences(of: "LEIDA_POS_", with: "#").replacingOccurrences(of: "LEIDA_", with: "")): (\(String(format: "%.2f, %.2f, %.2f", pos.x, pos.y, pos.z)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if appModel.qrAnchors.count > 5 {
                                Text("... 还有 \(appModel.qrAnchors.count - 5) 个")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 提示:")
                            .fontWeight(.medium)
                        Text("1. QR 码尺寸要与实际打印尺寸一致")
                        Text("2. 部署时扫描 QR 码会自动记录位置")
                        Text("3. 巡检时检测到 QR 码可自动或手动重定位")
                        Text("4. 重定位可消除 ARKit 累积漂移")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Section(header: Text("真实纹理采集")) {
                    Toggle(isOn: $appModel.isTextureCaptureEnabled) {
                        Label("开启纹理采集", systemImage: "camera.fill")
                    }
                    .tint(.cyan)
                    .onChange(of: appModel.isTextureCaptureEnabled) { _, newValue in
                        if newValue {
                            // 开启时清空旧帧，重新开始
                            appModel.clearCameraFrameCache()
                        }
                    }
                    
                    if appModel.isTextureCaptureEnabled {
                        HStack {
                            Text("已采集帧数")
                            Spacer()
                            Text("\(appModel.capturedFrameCount) / \(appModel.maxCapturedFrames)")
                                .foregroundStyle(.cyan)
                                .fontWeight(.medium)
                        }
                        
                        if appModel.capturedFrameCount > 0 {
                            Button(role: .destructive) {
                                appModel.clearCameraFrameCache()
                            } label: {
                                Label("清空已采集帧", systemImage: "trash")
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 说明:")
                            .fontWeight(.medium)
                        Text("1. 开启后扫描时自动捕获相机画面")
                        Text("2. 导出时选择「真实纹理」即可看到真实颜色")
                        Text("3. 不需要时请关闭，节省电量")
                        Text("4. 建议采集 30-100 帧效果最佳")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Section(header: Text("操作")) {
                    Button {
                        NotificationCenter.default.post(name: .requestSaveMap, object: nil)
                        dismiss()
                    } label: {
                        Label("保存环境地图 (.worldmap)", systemImage: "map")
                    }
                    
                    Button {
                        NotificationCenter.default.post(name: .requestSaveMesh, object: nil)
                        dismiss()
                    } label: {
                        Label("导出扫描模型 (.obj/.ply)", systemImage: "arkit")
                    }
                    
                    Button(role: .destructive) {
                        appModel.shouldResetSession = true
                        dismiss()
                    } label: {
                        Label("重置扫描会话", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("空间扫描设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// 简单的图片选择器
struct ImagePicker: UIViewControllerRepresentable {
    var image: Binding<UIImage?>?
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    var completion: ((UIImage?) -> Void)?
    @Environment(\.dismiss) var dismiss
    
    // 支持两种初始化方式
    init(image: Binding<UIImage?>) {
        self.image = image
        self.sourceType = .photoLibrary
        self.completion = nil
    }
    
    init(sourceType: UIImagePickerController.SourceType, completion: @escaping (UIImage?) -> Void) {
        self.image = nil
        self.sourceType = sourceType
        self.completion = completion
    }
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let selectedImage = info[.originalImage] as? UIImage
            
            if let binding = parent.image {
                binding.wrappedValue = selectedImage
            }
            
            if let completion = parent.completion {
                completion(selectedImage)
            }
            
            parent.dismiss()
        }
    }
}

// MARK: - 3. Scan View (AR + Controls)
struct ScanView: View {
    @ObservedObject var appModel: AppModel
    @State private var showReportComposer: Bool = false
    @State private var hasEnteredCamera: Bool = false
    @State private var showSettings: Bool = false
    @State private var isHUDExpanded: Bool = false
    
    var body: some View {
        ZStack {
            // 关键修改：只有在当前 Tab 且 Session 启动时才加载 ARView
            // 这样切换 Tab 时会自动销毁 ARView，彻底释放摄像头资源
            if appModel.isSessionStarted && appModel.selectedTab == 0 && hasEnteredCamera {
                ARViewContainer(appModel: appModel)
                    .ignoresSafeArea()
                    .id("arview-tab0") // 强制在 Tab 切换时重建
            }

            if !appModel.isSessionStarted {
                // 启动页 (Welcome Screen)
                VStack(spacing: 30) {
                    Image(systemName: "arkit")
                        .font(.system(size: 80))
                        .foregroundStyle(.yellow)
                    
                    VStack(spacing: 10) {
                        Text("BoilerPatrol Pro")
                            .font(.largeTitle)
                            .bold()
                        Text("工业级 AR 巡检终端")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button(action: {
                        appModel.isSessionStarted = true
                    }) {
                        Text("启动扫描系统")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(width: 200, height: 50)
                            .background(Color.yellow)
                            .cornerRadius(25)
                    .tint(.yellow)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                    }
                }
            } else if !hasEnteredCamera {
                ScanModeEntryView(
                    appModel: appModel,
                    onEnter: {
                        hasEnteredCamera = true
                    }
                )
            } else {
                // HUD + Controls (进入摄像头后)
                VStack {
                    // ═══ 顶部 HUD（分层设计）═══
                    VStack(alignment: .leading, spacing: 0) {
                        // ── 第一层：始终显示的核心信息 ──
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                // 标题行 + 模式标签
                                HStack(spacing: 8) {
                                    Text("BoilerPatrol")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.yellow)
                                    
                                    Text(appModel.workMode.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(appModel.workMode == .deployment ? Color.green.opacity(0.3) : Color.blue.opacity(0.3))
                                        .cornerRadius(6)
                                    
                                    Button {
                                        hasEnteredCamera = false
                                        NotificationCenter.default.post(name: .forceStopARSession, object: nil)
                                    } label: {
                                        Image(systemName: "arrow.uturn.left")
                                            .font(.caption2)
                                            .foregroundStyle(.yellow)
                                            .padding(4)
                                    }
                                }
                                
                                // 坐标 + 追踪状态（核心指标，始终显示）
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(statusColor)
                                        .frame(width: 7, height: 7)
                                    
                                    Image(systemName: getIcon(for: appModel.locQuality))
                                        .font(.caption2)
                                        .foregroundStyle(getColor(for: appModel.locQuality))
                                    
                                    Text(String(format: "X:%.2f Y:%.2f Z:%.2f",
                                                appModel.currentPosition.x,
                                                appModel.currentPosition.y,
                                                appModel.currentPosition.z))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(isQualityGood(appModel.locQuality) ? .white : .gray.opacity(0.6))
                                        .fontWeight(isQualityGood(appModel.locQuality) ? .semibold : .regular)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.65))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(getColor(for: appModel.locQuality).opacity(0.4), lineWidth: 1)
                                )
                                
                                // 快速状态行（图标式，一行显示多个状态）
                                HStack(spacing: 8) {
                                    // QR 状态（图标化）
                                    HStack(spacing: 3) {
                                        Image(systemName: "qrcode")
                                            .font(.caption2)
                                            .foregroundStyle(appModel.qrAnchors.isEmpty ? .gray : (appModel.workMode == .deployment ? .green : .blue))
                                        Text("\(appModel.qrAnchors.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // 校正状态
                                    if appModel.relocalizationOffset != .zero {
                                        HStack(spacing: 2) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                            Text(String(format: "%.0fcm", simd_length(appModel.relocalizationOffset) * 100))
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    
                                    // 纹理采集状态
                                    if appModel.isTextureCaptureEnabled {
                                        HStack(spacing: 2) {
                                            Image(systemName: "camera.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.cyan)
                                            Text("\(appModel.capturedFrameCount)")
                                                .font(.caption2)
                                                .foregroundStyle(.cyan)
                                        }
                                    }
                                    
                                    // 最近检测到的 QR
                                    if let lastQR = appModel.lastDetectedQR,
                                       let lastTime = appModel.lastDetectedQRTime,
                                       Date().timeIntervalSince(lastTime) < 2.0 {
                                        let shortName = lastQR
                                            .replacingOccurrences(of: "LEIDA_POS_", with: "#")
                                            .replacingOccurrences(of: "LEIDA_", with: "")
                                        Text("[\(shortName) ✓]")
                                            .font(.caption2)
                                            .foregroundStyle(.yellow)
                                            .fontWeight(.bold)
                                    }
                                    
                                    Spacer()
                                    
                                    // 展开/收起按钮
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            isHUDExpanded.toggle()
                                        }
                                    } label: {
                                        Image(systemName: isHUDExpanded ? "chevron.up" : "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.6))
                                            .padding(4)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            // 右侧快捷按钮组
                            VStack(spacing: 8) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "gearshape.fill")
                                        .font(.body)
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                
                                if appModel.workMode == .deployment {
                                    Button {
                                        appModel.isTextureCaptureEnabled.toggle()
                                        if appModel.isTextureCaptureEnabled {
                                            appModel.clearCameraFrameCache()
                                        }
                                    } label: {
                                        Image(systemName: appModel.isTextureCaptureEnabled ? "camera.fill" : "camera")
                                            .font(.body)
                                            .foregroundStyle(appModel.isTextureCaptureEnabled ? .cyan : .white.opacity(0.6))
                                            .padding(8)
                                            .background(appModel.isTextureCaptureEnabled ? Color.cyan.opacity(0.25) : Color.clear)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle()
                                                    .stroke(appModel.isTextureCaptureEnabled ? Color.cyan.opacity(0.8) : Color.clear, lineWidth: 1.5)
                                            )
                                    }
                                }
                            }
                        }
                        
                        // ── 第二层：展开后显示的详细信息 ──
                        if isHUDExpanded {
                            VStack(alignment: .leading, spacing: 6) {
                                Divider().background(.white.opacity(0.2))
                                
                                // 追踪详情
                                HStack(spacing: 4) {
                                    Circle().fill(statusColor).frame(width: 6, height: 6)
                                    Text(appModel.trackingState)
                                        .font(.caption2)
                                    if !appModel.lidarMeshStatus.isEmpty {
                                        Text("·")
                                            .foregroundStyle(.secondary)
                                        Text("网格: \(appModel.lidarMeshStatus)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                // 定位质量
                                HStack(spacing: 4) {
                                    Image(systemName: getIcon(for: appModel.locQuality))
                                        .foregroundStyle(getColor(for: appModel.locQuality))
                                    Text(appModel.locQualityMessage)
                                        .foregroundStyle(getColor(for: appModel.locQuality))
                                }
                                .font(.caption2)
                                
                                // 纹理采集详情
                                if appModel.isTextureCaptureEnabled {
                                    HStack(spacing: 4) {
                                        Image(systemName: "camera.fill")
                                            .foregroundStyle(.cyan)
                                        if appModel.scanState == .scanning {
                                            Text("纹理采集中: \(appModel.capturedFrameCount)/\(appModel.maxCapturedFrames)")
                                                .foregroundStyle(.cyan)
                                        } else {
                                            Text("纹理帧: \(appModel.capturedFrameCount)/\(appModel.maxCapturedFrames) 已就绪")
                                                .foregroundStyle(.cyan.opacity(0.7))
                                        }
                                    }
                                    .font(.caption2)
                                }
                                
                                // QR 锚点详情
                                if !appModel.qrAnchors.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "qrcode")
                                            .foregroundStyle(appModel.workMode == .deployment ? .green : .blue)
                                        Text("QR 锚点: \(appModel.qrAnchors.count) 个")
                                            .foregroundStyle(appModel.workMode == .deployment ? .green : .blue)
                                        if appModel.relocalizationOffset != .zero {
                                            Text("· 已校正 \(String(format: "%.0fcm", simd_length(appModel.relocalizationOffset) * 100))")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .font(.caption2)
                                }
                                
                                // 漂移警告
                                if let warning = appModel.driftWarning {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text(warning)
                                            .foregroundStyle(.orange)
                                            .fontWeight(.medium)
                                    }
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.orange.opacity(0.15))
                                    .cornerRadius(4)
                                }
                                
                                // 模式提示
                                if appModel.workMode == .deployment {
                                    if appModel.relocalizationStatus != "已定位 (Mapped)" {
                                        Text("💡 走动扩展环境，稳定后保存地图")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    if appModel.relocalizationStatus != "已定位 (Mapped)" {
                                        Text("💡 对准 QR 码可快速重定位")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .background(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(isHUDExpanded ? 0.7 : 0.3), .clear], startPoint: .top, endPoint: .bottom))

                    Spacer()

                    if appModel.isProcessing {
                        HStack {
                            ProgressView().tint(.white)
                            Text(appModel.processMessage).font(.caption)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding(.bottom, 26)
                    } else {
                        VStack(spacing: 12) {
                            // 扫描状态指示器（部署模式）
                            if appModel.workMode == .deployment {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(scanStateColor)
                                        .frame(width: 10, height: 10)
                                    Text(appModel.scanState.rawValue)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    
                                    // 扫描控制按钮组
                                    HStack(spacing: 8) {
                                        if appModel.scanState == .idle || appModel.scanState == .paused {
                                            Button {
                                                appModel.scanState = .scanning
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: appModel.scanState == .idle ? "play.fill" : "play.fill")
                                                    Text(appModel.scanState == .idle ? "开始扫描" : "继续")
                                                }
                                                .font(.caption)
                                                .foregroundStyle(.black)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.green)
                                                .cornerRadius(8)
                                            }
                                        }
                                        
                                        if appModel.scanState == .scanning {
                                            Button {
                                                appModel.scanState = .paused
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "pause.fill")
                                                    Text("暂停")
                                                }
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.orange)
                                                .cornerRadius(8)
                                            }
                                        }
                                        
                                        if appModel.scanState == .scanning || appModel.scanState == .paused {
                                            Button {
                                                appModel.scanState = .completed
                                                // 自动停止纹理采集
                                                appModel.isTextureCaptureEnabled = false
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "checkmark")
                                                    Text("完成")
                                                }
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.blue)
                                                .cornerRadius(8)
                                            }
                                        }
                                        
                                        if appModel.scanState == .completed || appModel.scanState == .paused {
                                            Button {
                                                appModel.scanState = .idle
                                                // 重置时也停止纹理采集并清空缓存
                                                appModel.isTextureCaptureEnabled = false
                                                appModel.clearCameraFrameCache()
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.counterclockwise")
                                                    Text("重置")
                                                }
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.gray)
                                                .cornerRadius(8)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                            }
                            
                            // 底部操作按钮
                            HStack(spacing: 12) {
                                if appModel.workMode == .deployment {
                                    SecondaryCompactButton(title: "保存地图", systemImage: "map.fill") {
                                        NotificationCenter.default.post(name: .requestSaveMap, object: nil)
                                    }

                                    PrimaryPillButton(title: "保存模型", systemImage: "cube.transparent") {
                                        NotificationCenter.default.post(name: .requestSaveMesh, object: nil)
                                    }
                                } else {
                                    // AI 导航按钮
                                    SecondaryCompactButton(title: "AI导航", systemImage: "location.viewfinder") {
                                        // TODO: 实现 AI 导航功能
                                        appModel.alertMessage = "AI 导航功能开发中..."
                                        appModel.showAlert = true
                                    }

                                    PrimaryPillButton(title: "填写报告", systemImage: "doc.text.fill") {
                                        showReportComposer = true
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.bottom, 26)
                    }
                }
                
                // QR 码检测浮动卡片（两种模式都支持手动重定位）
                if let qrContent = appModel.lastDetectedQR,
                   let qrTime = appModel.lastDetectedQRTime,
                   Date().timeIntervalSince(qrTime) < 3.0 {
                    
                    // 巡检模式：需要有保存的锚点才能重定位
                    // 部署模式：显示检测到的 QR 信息
                    if appModel.workMode == .operation && appModel.qrAnchors[qrContent] != nil {
                        QRRelocalizationCard(appModel: appModel)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: qrContent)
                    } else if appModel.workMode == .deployment {
                        // 部署模式：显示 QR 码检测提示
                        QRDetectionBadge(appModel: appModel)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: qrContent)
                    }
                }
            }
        }
        .sheet(isPresented: $showReportComposer) {
            InspectionReportComposerView(appModel: appModel)
        }
        .sheet(isPresented: $showSettings) {
            ScanSettingsSheet(appModel: appModel)
        }
        .confirmationDialog("选择导出格式", isPresented: $appModel.showExportOptions, titleVisibility: .visible) {
            Button("白模 (OBJ)") {
                appModel.coloringMode = .none
                appModel.exportMesh(anchors: appModel.pendingMeshAnchors)
            }
            Button("AI语义色 (PLY)") {
                appModel.coloringMode = .ai
                appModel.exportMesh(anchors: appModel.pendingMeshAnchors)
            }
            Button("📸 真实纹理 (PLY)") {
                appModel.coloringMode = .texture
                appModel.exportMesh(anchors: appModel.pendingMeshAnchors)
            }
            Button("取消", role: .cancel) { }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
    
    var statusColor: Color {
        switch appModel.trackingState {
        case "追踪正常": return .green
        case "不可用": return .red
        default: return .yellow
        }
    }
    
    var scanStateColor: Color {
        switch appModel.scanState {
        case .idle: return .gray
        case .scanning: return .green
        case .paused: return .orange
        case .completed: return .blue
        }
    }

    private func getIcon(for quality: AppModel.LocalizationQuality) -> String {
        switch quality {
        case .good: return "checkmark.circle.fill"
        case .relocalizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .lost: return "xmark.circle.fill"
        }
    }

    private func getColor(for quality: AppModel.LocalizationQuality) -> Color {
        switch quality {
        case .good: return .green
        case .relocalizing: return .yellow
        case .limited: return .orange
        case .lost: return .red
        }
    }

    private func isQualityGood(_ quality: AppModel.LocalizationQuality) -> Bool {
        if case .good = quality { return true }
        return false
    }
}

private struct ScanModeEntryView: View {
    @ObservedObject var appModel: AppModel
    let onEnter: () -> Void
    @State private var showMapPicker: Bool = false

    private var worldMapFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                url.pathExtension == "worldmap" && url.lastPathComponent.hasPrefix("Map_")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // 最新的在前
    }
    
    private var canEnterCamera: Bool {
        // 部署模式：随时可以进入
        // 巡检模式：必须选择地图
        if appModel.workMode == .deployment {
            return true
        } else {
            return appModel.selectedMapForPatrol != nil
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                VStack(spacing: 8) {
                    Text("请选择模式")
                        .font(.title2)
                        .bold()
                        .foregroundStyle(.white)
                    Text("先选择部署/巡检，再进入摄像头")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    ModeChoiceCard(
                        isSelected: appModel.workMode == .deployment,
                        illustration: .deployment,
                        title: "部署建图",
                        feature1: "扫描环境建立模型",
                        feature2: "保存 WorldMap"
                    ) {
                        appModel.workMode = .deployment
                        appModel.selectedMapForPatrol = nil
                    }

                    ModeChoiceCard(
                        isSelected: appModel.workMode == .operation,
                        illustration: .operation,
                        title: "使用巡检",
                        feature1: "加载地图重定位",
                        feature2: "填写巡检报告"
                    ) {
                        appModel.workMode = .operation
                    }
                }
                .padding(.horizontal)
                
                // 巡检模式下显示地图选择区域
                if appModel.workMode == .operation {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "map.fill")
                                .foregroundStyle(.yellow)
                            Text("请选择要加载的地图")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        if worldMapFiles.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title)
                                    .foregroundStyle(.orange)
                                Text("暂无可用地图")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                Text("请先使用「部署建图」模式创建并保存地图")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                            .padding(.horizontal)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(worldMapFiles, id: \.self) { file in
                                        MapSelectionCard(
                                            file: file,
                                            isSelected: appModel.selectedMapForPatrol == file,
                                            onTap: {
                                                appModel.selectedMapForPatrol = file
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        
                        // 显示已选地图
                        if let selectedMap = appModel.selectedMapForPatrol {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("已选: \(selectedMap.deletingPathExtension().lastPathComponent)")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Spacer()

                Button {
                    if canEnterCamera {
                        // 如果是巡检模式，自动设置要加载的地图并加载 QR 锚点
                        if appModel.workMode == .operation, let map = appModel.selectedMapForPatrol {
                            appModel.mapToLoad = map
                            appModel.loadQRAnchors(forMapURL: map)  // 加载 QR 锚点
                            print("📍 已加载 \(appModel.qrAnchors.count) 个 QR 锚点")
                        }
                        onEnter()
                    }
                } label: {
                    HStack {
                        if !canEnterCamera {
                            Image(systemName: "lock.fill")
                        }
                        Text(canEnterCamera ? "进入摄像头" : "请先选择地图")
                    }
                    .font(.headline)
                    .foregroundStyle(canEnterCamera ? .black : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canEnterCamera ? Color.yellow : Color.gray.opacity(0.3))
                    .cornerRadius(14)
                }
                .disabled(!canEnterCamera)
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            appModel.loadSavedFiles()
        }
    }

    private func getIcon(for quality: AppModel.LocalizationQuality) -> String {
        switch quality {
        case .good: return "checkmark.circle.fill"
        case .relocalizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .lost: return "xmark.circle.fill"
        }
    }

    private func getColor(for quality: AppModel.LocalizationQuality) -> Color {
        switch quality {
        case .good: return .green
        case .relocalizing: return .yellow
        case .limited: return .orange
        case .lost: return .red
        }
    }

    private func isQualityGood(_ quality: AppModel.LocalizationQuality) -> Bool {
        if case .good = quality { return true }
        return false
    }
}

private enum ModeIllustrationKind {
    case deployment
    case operation
}

private struct ModeChoiceCard: View {
    let isSelected: Bool
    let illustration: ModeIllustrationKind
    let title: String
    let feature1: String
    let feature2: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                ModeIllustration(kind: illustration)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    VStack(spacing: 4) {
                        Text(feature1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(feature2)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .yellow : .white.opacity(0.45))
                    .font(.title3)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.yellow.opacity(0.9) : Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

private struct ModeIllustration: View {
    let kind: ModeIllustrationKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            ZStack {
                switch kind {
                case .deployment:
                    ZStack {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.yellow)

                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 26, y: 18)
                    }
                case .operation:
                    ZStack {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.yellow)

                        Image(systemName: "location.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 26, y: 18)
                    }
                }
            }
        }
        .frame(height: 110)
        .padding(.horizontal, 12)
    }
}

// 部署模式 QR 码检测徽章
private struct QRDetectionBadge: View {
    @ObservedObject var appModel: AppModel
    
    private var qrContent: String {
        appModel.lastDetectedQR ?? ""
    }
    
    private var shortName: String {
        qrContent
            .replacingOccurrences(of: "LEIDA_POS_", with: "点位 ")
            .replacingOccurrences(of: "LEIDA_", with: "")
    }
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title3)
                    .foregroundStyle(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("QR 码已记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(shortName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
                
                Spacer()
                
                if let anchor = appModel.qrAnchors[qrContent] {
                    Text("观测 \(anchor.observations) 次")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.green.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }
}

// QR 码重定位浮动卡片
private struct QRRelocalizationCard: View {
    @ObservedObject var appModel: AppModel
    @State private var isExpanded: Bool = false
    
    private var qrContent: String {
        appModel.lastDetectedQR ?? ""
    }
    
    private var shortName: String {
        qrContent
            .replacingOccurrences(of: "LEIDA_POS_", with: "点位 ")
            .replacingOccurrences(of: "LEIDA_", with: "")
    }
    
    private var savedAnchor: AppModel.QRAnchor? {
        appModel.qrAnchors[qrContent]
    }
    
    private var offset: SIMD3<Float> {
        guard let saved = savedAnchor,
              let current = appModel.lastDetectedQRPosition else {
            return .zero
        }
        return saved.worldPosition - current
    }
    
    private var offsetDistance: Float {
        simd_length(offset)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 12) {
                // 收起状态：小卡片
                HStack(spacing: 12) {
                    // QR 图标带动画
                    ZStack {
                        Circle()
                            .fill(.yellow.opacity(0.2))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("检测到 QR 码")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(shortName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        
                        if let dist = appModel.lastDetectedQRDistance {
                            Text("距离 \(String(format: "%.1f", dist))m · 偏移 \(String(format: "%.0f", offsetDistance * 100))cm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // 展开/收起按钮
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // 展开状态：显示详情和按钮
                if isExpanded {
                    Divider()
                        .background(.white.opacity(0.2))
                    
                    VStack(spacing: 12) {
                        // 位置信息
                        if let saved = savedAnchor,
                           let current = appModel.lastDetectedQRPosition {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("保存位置")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "(%.2f, %.2f, %.2f)", saved.worldPosition.x, saved.worldPosition.y, saved.worldPosition.z))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.blue)
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("当前检测")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "(%.2f, %.2f, %.2f)", current.x, current.y, current.z))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.orange)
                                }
                            }
                            
                            // 偏移量
                            HStack {
                                Text("偏移修正:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "X: %.0fcm  Y: %.0fcm  Z: %.0fcm", offset.x * 100, offset.y * 100, offset.z * 100))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                        }
                        
                        // 操作按钮
                        HStack(spacing: 12) {
                            Button {
                                withAnimation {
                                    isExpanded = false
                                }
                            } label: {
                                Text("取消")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(.white.opacity(0.15))
                                    .cornerRadius(10)
                            }
                            
                            Button {
                                // 应用重定位
                                appModel.relocalizationOffset = offset
                                appModel.isRelocalizing = false
                                
                                // 清除检测状态
                                appModel.lastDetectedQR = nil
                                
                                withAnimation {
                                    isExpanded = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "location.fill")
                                    Text("重定位")
                                }
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(.yellow)
                                .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.yellow.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 20)
            .padding(.bottom, 120) // 留出底部按钮空间
        }
    }
}

// 地图选择卡片
private struct MapSelectionCard: View {
    let file: URL
    let isSelected: Bool
    let onTap: () -> Void
    
    private var displayName: String {
        let name = file.deletingPathExtension().lastPathComponent
        // Map_1234567890 -> 格式化日期
        if name.hasPrefix("Map_"), let timestamp = Int(name.replacingOccurrences(of: "Map_", with: "")) {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            return formatter.string(from: date)
        }
        return name
    }
    
    private var fileSize: String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }
        return ""
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1))
                    Image(systemName: "map.fill")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .yellow : .white.opacity(0.7))
                }
                .frame(width: 60, height: 50)
                
                VStack(spacing: 2) {
                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(isSelected ? .yellow : .white)
                    Text(fileSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .yellow : .white.opacity(0.3))
                    .font(.caption)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

private struct PrimaryPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.headline)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.yellow)
            .cornerRadius(28)
        }
    }
}

private struct SecondaryCompactButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(width: 120, height: 56)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }
}

private struct InspectionReportComposerView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var boilerId: String = ""
    @State private var area: String = ""

    @State private var temperatureC: String = ""
    @State private var pressureMPa: String = ""
    @State private var waterLevel: String = ""
    @State private var valvePosition: String = ""

    @State private var abnormalNoise: Bool = false
    @State private var leakage: Bool = false
    @State private var vibration: Bool = false
    @State private var smokeOrSteam: Bool = false
    @State private var overTempOrPressure: Bool = false
    @State private var alarmTriggered: Bool = false

    @State private var notes: String = ""

    @State private var capturedPhotos: [UIImage] = []
    @State private var showCameraPicker: Bool = false
    @State private var showSignaturePad: Bool = false
    @State private var signatureDrawing = SignatureDrawing()
    @State private var signatureImage: UIImage?
    @State private var signerName: String = ""
    @State private var confirmationChecked: Bool = false

    @State private var isSavingAttachments: Bool = false
    @State private var attachmentError: String?

    private var canGenerate: Bool {
        signatureImage != nil && confirmationChecked && !isSavingAttachments
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func makeAttachmentBaseName(createdAt: Date) -> String {
        "Report_\(Int(createdAt.timeIntervalSince1970))"
    }
    
    private func generateReport() {
        attachmentError = nil
        guard let user = appModel.currentUser else {
            appModel.alertMessage = "未登录，无法生成报告。"
            appModel.showAlert = true
            return
        }
        guard confirmationChecked else {
            attachmentError = "请勾选确认。"
            return
        }
        guard let sig = signatureImage else {
            attachmentError = "请完成签名后再生成报告。"
            return
        }

        // Swift 6: detached 任务里不能读写 @State / MainActor 数据，先做快照
        isSavingAttachments = true
        let createdAt = Date()
        let baseName = makeAttachmentBaseName(createdAt: createdAt)
        let docDir = documentsDirectory()
        let photosToSave = capturedPhotos
        let signatureToSave = sig

        let boilerIdSnapshot = boilerId.trimmingCharacters(in: .whitespacesAndNewlines)
        let areaSnapshot = area.trimmingCharacters(in: .whitespacesAndNewlines)
        let temperatureSnapshot = temperatureC.trimmingCharacters(in: .whitespacesAndNewlines)
        let pressureSnapshot = pressureMPa.trimmingCharacters(in: .whitespacesAndNewlines)
        let waterLevelSnapshot = waterLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        let valveSnapshot = valvePosition.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSnapshot = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let signerSnapshot = signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmationSnapshot = confirmationChecked
        let abnormalNoiseSnapshot = abnormalNoise
        let leakageSnapshot = leakage
        let vibrationSnapshot = vibration
        let smokeSnapshot = smokeOrSteam
        let overSnapshot = overTempOrPressure
        let alarmSnapshot = alarmTriggered

        // 获取当前AR相机位置（必须在MainActor上）
        let cameraTransform = appModel.arView?.session.currentFrame?.camera.transform
        let posX = cameraTransform.map { Double($0.columns.3.x) }
        let posY = cameraTransform.map { Double($0.columns.3.y) }
        let posZ = cameraTransform.map { Double($0.columns.3.z) }

        Task.detached(priority: .userInitiated) {
            do {
                var photoNames: [String] = []
                for (index, image) in photosToSave.enumerated() {
                    let name = "\(baseName)_photo_\(String(format: "%02d", index + 1)).jpg"
                    let url = docDir.appendingPathComponent(name)
                    try ImageSaver.writeJPEG(image, to: url)
                    photoNames.append(name)
                }

                let signatureName = "\(baseName)_signature.png"
                let signatureURL = docDir.appendingPathComponent(signatureName)
                try ImageSaver.writePNG(signatureToSave, to: signatureURL)
                
                // Create immutable copies for capture
                let finalPhotoNames = photoNames
                let finalSignatureName = signatureName

                await MainActor.run {
                    let report = AppModel.InspectionReport(
                        id: UUID(),
                        createdAt: createdAt,
                        signedAt: createdAt,
                        inspectorId: user.id,
                        inspectorName: user.displayName,
                        inspectorRole: user.role,
                        boilerId: boilerIdSnapshot,
                        area: areaSnapshot,
                        positionX: posX,
                        positionY: posY,
                        positionZ: posZ,
                        temperatureC: temperatureSnapshot,
                        pressureMPa: pressureSnapshot,
                        waterLevel: waterLevelSnapshot,
                        valvePosition: valveSnapshot,
                        abnormalNoise: abnormalNoiseSnapshot,
                        leakage: leakageSnapshot,
                        vibration: vibrationSnapshot,
                        smokeOrSteam: smokeSnapshot,
                        overTempOrPressure: overSnapshot,
                        alarmTriggered: alarmSnapshot,
                        notes: notesSnapshot,
                        photoFileNames: finalPhotoNames,
                        signatureFileName: finalSignatureName,
                        signerName: signerSnapshot,
                        confirmationChecked: confirmationSnapshot
                    )

                    appModel.saveInspectionReport(report)
                    appModel.alertMessage = "巡检报告已生成！（已导出到 Documents 文件夹）"
                    appModel.showAlert = true
                    isSavingAttachments = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    attachmentError = "保存附件失败：\(error.localizedDescription)"
                    isSavingAttachments = false
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                basicInfoSection
                readingsSection
                abnormalStatusSection
                notesSection
                photoSection
                signatureSection
            }
            .navigationTitle("巡检报告")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.yellow)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("生成", action: generateReport)
                        .disabled(!canGenerate)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCameraPicker) {
            ImagePicker(sourceType: .camera) { image in
                if let img = image {
                    capturedPhotos.insert(img, at: 0)
                }
                showCameraPicker = false
            }
        }
        .sheet(isPresented: $showSignaturePad) {
            SignaturePadSheet(drawing: $signatureDrawing) { rendered in
                signatureImage = rendered
                showSignaturePad = false
            } onCancel: {
                showSignaturePad = false
            }
        }
    }
    
    // MARK: - Section Views
    
    private var basicInfoSection: some View {
        Section(header: Text("基础信息")) {
            TextField("锅炉编号/设备号", text: $boilerId)
            TextField("区域/位置（如：一层东侧）", text: $area)
        }
    }
    
    private var readingsSection: some View {
        Section(header: Text("读数（可选）")) {
            TextField("温度 (°C)", text: $temperatureC)
                .keyboardType(.numbersAndPunctuation)
            TextField("压力 (MPa)", text: $pressureMPa)
                .keyboardType(.numbersAndPunctuation)
            TextField("水位/液位", text: $waterLevel)
            TextField("阀位/开度", text: $valvePosition)
        }
    }
    
    private var abnormalStatusSection: some View {
        Section(header: Text("异常状态")) {
            Toggle("异响", isOn: $abnormalNoise)
            Toggle("泄漏", isOn: $leakage)
            Toggle("振动", isOn: $vibration)
            Toggle("冒烟/蒸汽异常", isOn: $smokeOrSteam)
            Toggle("温压异常", isOn: $overTempOrPressure)
            Toggle("报警触发", isOn: $alarmTriggered)
        }
    }
    
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        private var notesSection: some View {
        Section(header: Text("备注")) {
            TextEditor(text: $notes)
                .frame(minHeight: 120)
        }
    }
    
    private var photoSection: some View {
        Section(header: Text("拍照附件")) {
            Button {
                showCameraPicker = true
            } label: {
                HStack {
                    Image(systemName: "camera")
                    Text("拍照添加")
                    Spacer()
                    if !capturedPhotos.isEmpty {
                        Text("\(capturedPhotos.count) 张")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !capturedPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(capturedPhotos.enumerated()), id: \.offset) { idx, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 110, height: 80)
                                    .clipped()
                                    .cornerRadius(10)

                                Button {
                                    capturedPhotos.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                }
                                .padding(6)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("提示：照片会离线保存到 Documents，并写入报告 JSON 的附件字段。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    
    private var signatureSection: some View {
        Section(header: Text("签名确认")) {
            TextField("签名人姓名（可选）", text: $signerName)

            HStack {
                Button {
                    showSignaturePad = true
                } label: {
                    HStack {
                        Image(systemName: "pencil.and.outline")
                        Text(signatureImage == nil ? "去签名" : "重新签名")
                    }
                }

                Spacer()

                if signatureImage != nil {
                    Label("已签名", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            Toggle("我确认以上信息真实有效", isOn: $confirmationChecked)

            if let err = attachmentError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private enum ImageSaver {
    nonisolated static func writeJPEG(_ image: UIImage, to url: URL, compressionQuality: CGFloat = 0.85) throws {
        guard let data = image.jpegData(compressionQuality: compressionQuality) else {
            throw NSError(domain: "Leida", code: 1001, userInfo: [NSLocalizedDescriptionKey: "无法生成 JPEG 数据"])
        }
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func writePNG(_ image: UIImage, to url: URL) throws {
        guard let data = image.pngData() else {
            throw NSError(domain: "Leida", code: 1002, userInfo: [NSLocalizedDescriptionKey: "无法生成 PNG 数据"])
        }
        try data.write(to: url, options: [.atomic])
    }
}

private struct SignatureDrawing: Equatable {
    var strokes: [[CGPoint]] = []

    mutating func startStroke(at point: CGPoint) {
        strokes.append([point])
    }

    mutating func addPoint(_ point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(point)
    }

    mutating func clear() {
        strokes.removeAll()
    }

    func renderImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.cgContext.setLineWidth(3)
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            UIColor.white.setStroke()

            for stroke in strokes {
                guard let first = stroke.first else { continue }
                ctx.cgContext.beginPath()
                ctx.cgContext.move(to: first)
                for p in stroke.dropFirst() {
                    ctx.cgContext.addLine(to: p)
                }
                ctx.cgContext.strokePath()
            }
        }
    }
}

private struct SignaturePadSheet: View {
    @Binding var drawing: SignatureDrawing
    let onDone: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var canvasSize: CGSize = .init(width: 320, height: 180)
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("请在下方签名")
                    .font(.headline)

                SignaturePad(drawing: $drawing)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { canvasSize = geo.size }
                                .onChange(of: geo.size) { _, newValue in canvasSize = newValue }
                        }
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("清空") { drawing.clear() }
                        .buttonStyle(.bordered)

                    Spacer()

                    Button("完成") {
                        let image = drawing.renderImage(size: canvasSize, scale: displayScale)
                        onDone(image)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(drawing.strokes.isEmpty)
                }
                .padding(.horizontal)

                Text("提示：签名会以 PNG 形式离线保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .navigationTitle("签名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SignaturePad: View {
    @Binding var drawing: SignatureDrawing

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for stroke in drawing.strokes {
                guard let first = stroke.first else { continue }
                path.move(to: first)
                for p in stroke.dropFirst() {
                    path.addLine(to: p)
                }
            }
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .background(Color.black)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero {
                        drawing.startStroke(at: value.location)
                    } else {
                        drawing.addPoint(value.location)
                    }
                }
        )
    }
}

// MARK: - 4. File Library View
struct FileLibraryView: View {
    @ObservedObject var appModel: AppModel
    @State private var isEditing = false
    @State private var selectedURLs: Set<URL> = []
    
    var body: some View {
        NavigationView {
            List(selection: isEditing ? $selectedURLs : nil) {
                LibrarySection(
                    title: "精度测试轨迹",
                    subtitle: ".csv",
                    icon: "ruler.fill",
                    files: precisionCSVFiles,
                    emptyHint: "暂无精度测试 CSV 文件",
                    isEditing: isEditing
                ) { url in
                    appModel.selectedFile = url
                    appModel.showFileViewer = true
                } onDelete: { urls in
                    delete(urls: urls)
                }

                LibrarySection(
                    title: "巡检报告",
                    subtitle: ".json",
                    icon: "doc.text.fill",
                    files: reportFiles,
                    emptyHint: "暂无巡检报告",
                    isEditing: isEditing
                ) { url in
                    appModel.selectedFile = url
                    appModel.showFileViewer = true
                } onDelete: { urls in
                    delete(urls: urls)
                }

                LibrarySection(
                    title: "空间扫描（LiDAR）",
                    subtitle: ".obj / .ply",
                    icon: "arkit",
                    files: lidarScanFiles,
                    emptyHint: "暂无空间扫描导出文件",
                    isEditing: isEditing
                ) { url in
                    appModel.selectedFile = url
                    appModel.showFileViewer = true
                } onDelete: { urls in
                    delete(urls: urls)
                }

                LibrarySection(
                    title: "拍照建模（Photogrammetry）",
                    subtitle: "手动 .usdz",
                    icon: "camera.viewfinder",
                    files: photogrammetryFiles,
                    emptyHint: "暂无拍照建模生成的模型",
                    isEditing: isEditing
                ) { url in
                    appModel.selectedFile = url
                    appModel.showFileViewer = true
                } onDelete: { urls in
                    delete(urls: urls)
                }

                LibrarySection(
                    title: "环境地图（WorldMap）",
                    subtitle: ".worldmap",
                    icon: "map",
                    files: worldMapFiles,
                    emptyHint: "暂无保存的环境地图",
                    isEditing: isEditing
                ) { url in
                    appModel.loadWorldMap(url: url)
                } onDelete: { urls in
                    delete(urls: urls)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("文件库")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing && !selectedURLs.isEmpty {
                        Button("删除 (\(selectedURLs.count))") {
                            deleteSelected()
                        }
                        .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "完成" : "编辑") {
                        withAnimation {
                            isEditing.toggle()
                            if !isEditing {
                                selectedURLs.removeAll()
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .onAppear { appModel.loadSavedFiles() }
        }
    }
    
    private func deleteSelected() {
        for url in selectedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        selectedURLs.removeAll()
        isEditing = false
        appModel.loadSavedFiles()
    }

    private var precisionCSVFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                url.pathExtension == "csv" &&
                (url.lastPathComponent.hasPrefix("Position_Static") ||
                 url.lastPathComponent.hasPrefix("Position_Dynamic"))
            }
    }

    private var lidarScanFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                (url.pathExtension == "obj" || url.pathExtension == "ply")
                    && url.lastPathComponent.hasPrefix("Scan_")
            }
    }

    private var reportFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                url.pathExtension == "json" && url.lastPathComponent.hasPrefix("Report_")
            }
    }

    private var photogrammetryFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                url.pathExtension == "usdz" && url.lastPathComponent.hasPrefix("Model_")
            }
    }

    private var worldMapFiles: [URL] {
        appModel.savedFiles
            .filter { url in
                url.pathExtension == "worldmap" &&
                (url.lastPathComponent.hasPrefix("Map_") ||
                 url.lastPathComponent.hasPrefix("WorldMap_"))
            }
    }

    private func delete(urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        appModel.loadSavedFiles()
    }
}

private struct LibrarySection: View {
    let title: String
    let subtitle: String
    let icon: String
    let files: [URL]
    let emptyHint: String
    let isEditing: Bool
    let onTap: (URL) -> Void
    let onDelete: ([URL]) -> Void

    var body: some View {
        Section {
            if files.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(emptyHint)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(files, id: \.self) { url in
                    if isEditing {
                        // 编辑模式：显示选择框
                        FileCardRow(url: url)
                            .tag(url)
                    } else {
                        // 正常模式：可点击 + 右滑直接分享（大文件无需打开）
                        Button {
                            onTap(url)
                        } label: {
                            FileCardRow(url: url)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            ShareLink(item: url) {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .onDelete { offsets in
                    let targets: [URL] = offsets.compactMap { index in
                        guard files.indices.contains(index) else { return nil }
                        return files[index]
                    }
                    onDelete(targets)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileCardRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnailView(url: url)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Text(fileKindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(fileDateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var fileKindLabel: String {
        switch url.pathExtension.lowercased() {
        case "obj": return "空间扫描 · OBJ"
        case "ply": return "空间扫描 · PLY"
        case "json":
            if url.lastPathComponent.hasPrefix("Report_") {
                return "巡检报告 · JSON"
            }
            return "数据 · JSON"
        case "usdz": return "拍照建模 · USDZ"
        case "worldmap": return "环境地图 · WorldMap"
        default: return url.pathExtension.uppercased()
        }
    }

    private var fileDateText: String {
        guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct FileThumbnailView: View {
    let url: URL
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private let size = CGSize(width: 56, height: 56)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: fallbackIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .task {
            await loadThumbnailIfNeeded()
        }
    }

    private var fallbackIcon: String {
        switch url.pathExtension.lowercased() {
        case "worldmap": return "map"
        case "usdz": return "cube.transparent"
        case "obj", "ply": return "cube"
        default: return "doc"
        }
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        if image != nil { return }

        // 仅对模型类尝试生成缩略图
        let ext = url.pathExtension.lowercased()
        guard ext == "usdz" || ext == "obj" || ext == "ply" else { return }

        if let cached = ThumbnailCache.shared.get(url: url) {
            image = cached
            return
        }

        do {
            let thumb = try await QuickLookThumbnailer.thumbnail(for: url, size: size, scale: displayScale)
            ThumbnailCache.shared.set(url: url, image: thumb)
            image = thumb
        } catch {
            // 缩略图失败就使用 fallback icon
        }
    }
}

private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func get(url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    func set(url: URL, image: UIImage) {
        cache.setObject(image, forKey: url.path as NSString)
    }
}

private enum QuickLookThumbnailer {
    static func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let image = representation?.uiImage {
                    continuation.resume(returning: image)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(domain: "QuickLookThumbnailer", code: -1))
                }
            }
        }
    }
}

// MARK: - 5. Built-in 3D Viewer (SceneKit)
struct FileViewer: View {
    let url: URL
    @ObservedObject var appModel: AppModel
    
    var body: some View {
        NavigationView {
            ZStack {
                if isTextPreview {
                    TextFileViewer(url: url)
                        .ignoresSafeArea()
                } else if isPLY {
                    PLYViewerContainer(url: url)
                        .ignoresSafeArea()
                } else {
                    SceneViewContainer(url: url)
                        .ignoresSafeArea()
                }
                
                VStack {
                    Spacer()
                    if !isTextPreview {
                        Text("单指旋转 • 双指缩放")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .padding(.bottom)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { appModel.showFileViewer = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var isTextPreview: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "json" || ext == "txt" || ext == "csv"
    }
    
    private var isPLY: Bool {
        url.pathExtension.lowercased() == "ply"
    }
}

private struct TextFileViewer: View {
    let url: URL
    @State private var text: String = ""
    @State private var isLoading: Bool = true

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    Text(text.isEmpty ? "(空文件)" : text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .background(Color.black)
        .task {
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let lines = raw.components(separatedBy: "\n")
                let limit = 200
                if lines.count > limit {
                    let preview = lines.prefix(limit).joined(separator: "\n")
                    text = preview + "\n\n⚠️ 文件共 \(lines.count) 行，仅预览前 \(limit) 行。\n请右滑文件 → 分享，用电脑查看完整数据。"
                } else {
                    text = raw
                }
            } catch {
                text = "无法读取文件：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

struct SceneViewContainer: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.backgroundColor = .black
        
        do {
            let scene = try SCNScene(url: url, options: nil)
            sceneView.scene = scene
        } catch {
            print("无法加载模型: \(error)")
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - PLY 3D Viewer（支持顶点色的 PLY 文件查看器）
struct PLYViewerContainer: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.backgroundColor = .black
        sceneView.scene = SCNScene()
        
        // 后台解析 PLY，完成后更新 scene
        Task.detached(priority: .userInitiated) {
            let result = PLYParser.parse(url: url)
            guard let geometry = result else {
                print("❌ PLY 解析失败")
                return
            }
            await MainActor.run {
                let node = SCNNode(geometry: geometry)
                sceneView.scene?.rootNode.addChildNode(node)
                
                // 自动居中和缩放
                let (center, radius) = boundingInfo(of: node)
                node.position = SCNVector3(-center.x, -center.y, -center.z)
                
                // 添加相机
                let cameraNode = SCNNode()
                cameraNode.camera = SCNCamera()
                cameraNode.camera?.automaticallyAdjustsZRange = true
                cameraNode.position = SCNVector3(0, 0, max(radius * 2.5, 1.0))
                sceneView.scene?.rootNode.addChildNode(cameraNode)
                sceneView.pointOfView = cameraNode
            }
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
    
    private func boundingInfo(of node: SCNNode) -> (center: SCNVector3, radius: Float) {
        let (minVec, maxVec) = node.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) / 2,
            (minVec.y + maxVec.y) / 2,
            (minVec.z + maxVec.z) / 2
        )
        let dx = maxVec.x - minVec.x
        let dy = maxVec.y - minVec.y
        let dz = maxVec.z - minVec.z
        let radius = sqrt(dx * dx + dy * dy + dz * dz) / 2
        return (center, radius)
    }
}

// MARK: - PLY 文件解析器
private enum PLYParser {
    
    struct PLYData {
        var vertices: [(Float, Float, Float)] = []
        var colors: [(UInt8, UInt8, UInt8)] = []
        var faces: [[Int]] = []
        var hasColors: Bool = false
    }
    
    static func parse(url: URL) -> SCNGeometry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("❌ 无法读取 PLY 文件")
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        var lineIndex = 0
        
        // 1. 解析 Header
        var vertexCount = 0
        var faceCount = 0
        var hasColors = false
        var properties: [String] = []  // 顶点属性顺序
        var inVertex = false
        
        while lineIndex < lines.count {
            let line = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            lineIndex += 1
            
            if line == "end_header" { break }
            
            if line.hasPrefix("element vertex") {
                vertexCount = Int(line.components(separatedBy: " ").last ?? "0") ?? 0
                inVertex = true
            } else if line.hasPrefix("element face") {
                faceCount = Int(line.components(separatedBy: " ").last ?? "0") ?? 0
                inVertex = false
            } else if line.hasPrefix("property") && inVertex {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3 {
                    let name = parts.last!
                    properties.append(name)
                    if name == "red" || name == "green" || name == "blue" {
                        hasColors = true
                    }
                }
            }
        }
        
        print("📄 PLY Header: \(vertexCount) vertices, \(faceCount) faces, colors: \(hasColors)")
        print("📄 Properties: \(properties)")
        
        // 确定属性索引
        let xIdx = properties.firstIndex(of: "x") ?? 0
        let yIdx = properties.firstIndex(of: "y") ?? 1
        let zIdx = properties.firstIndex(of: "z") ?? 2
        let rIdx = properties.firstIndex(of: "red")
        let gIdx = properties.firstIndex(of: "green")
        let bIdx = properties.firstIndex(of: "blue")
        
        // 2. 解析顶点数据
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(vertexCount)
        var colors: [SIMD4<UInt8>] = []
        if hasColors { colors.reserveCapacity(vertexCount) }
        
        for _ in 0..<vertexCount {
            guard lineIndex < lines.count else { break }
            let line = lines[lineIndex]
            lineIndex += 1
            
            let parts = line.split(separator: " ")
            guard parts.count >= properties.count else { continue }
            
            let x = Float(parts[xIdx]) ?? 0
            let y = Float(parts[yIdx]) ?? 0
            let z = Float(parts[zIdx]) ?? 0
            vertices.append(SCNVector3(x, y, z))
            
            if hasColors, let ri = rIdx, let gi = gIdx, let bi = bIdx {
                let r = UInt8(parts[ri]) ?? 180
                let g = UInt8(parts[gi]) ?? 180
                let b = UInt8(parts[bi]) ?? 180
                colors.append(SIMD4<UInt8>(r, g, b, 255))
            }
        }
        
        // 3. 解析面数据
        var indices: [Int32] = []
        indices.reserveCapacity(faceCount * 3)
        
        for _ in 0..<faceCount {
            guard lineIndex < lines.count else { break }
            let line = lines[lineIndex]
            lineIndex += 1
            
            let parts = line.split(separator: " ")
            guard parts.count >= 4 else { continue }
            // 第一个数字是顶点数（通常为3），后续为索引
            let count = Int(parts[0]) ?? 3
            for j in 1...count {
                if j < parts.count {
                    indices.append(Int32(parts[j]) ?? 0)
                }
            }
        }
        
        print("📄 PLY Parsed: \(vertices.count) vertices, \(colors.count) colors, \(indices.count / 3) triangles")
        
        // 诊断：打印前几个颜色值
        if hasColors && !colors.isEmpty {
            let samples = colors.prefix(5).map { "(\($0.x),\($0.y),\($0.z))" }
            print("📄 PLY 颜色样本: \(samples.joined(separator: ", "))")
        }
        
        // 4. 构建 SCNGeometry
        guard !vertices.isEmpty else { return nil }
        
        // ======= 修复方案：Triangle Soup（三角形汤）+ 逐顶点着色 =======
        // 每个三角形的 3 个顶点独立（不共享），每个顶点使用自己的颜色。
        // GPU 在三角形内部自动做平滑插值 → 真实纹理看起来细腻自然。
        // 对 AI 语义模式也兼容（同一三角形 3 个顶点颜色本来就相同，不会插值）。
        
        if hasColors && !colors.isEmpty && !indices.isEmpty {
            let triCount = indices.count / 3
            
            // --- Step 1: 构建 Triangle Soup 顶点 + 颜色 ---
            var soupVerts: [Float] = []     // x,y,z
            var soupColors: [Float] = []    // r,g,b,a  (0~1)
            soupVerts.reserveCapacity(triCount * 3 * 3)
            soupColors.reserveCapacity(triCount * 3 * 4)
            
            for t in 0..<triCount {
                let i0 = Int(indices[t * 3])
                let i1 = Int(indices[t * 3 + 1])
                let i2 = Int(indices[t * 3 + 2])
                
                // 每个顶点使用自己的颜色（逐顶点着色，GPU 自动平滑插值）
                let triIndices = [i0, i1, i2]
                for idx in triIndices {
                    let v = idx < vertices.count ? vertices[idx] : SCNVector3Zero
                    soupVerts.append(v.x)
                    soupVerts.append(v.y)
                    soupVerts.append(v.z)
                    
                    let c = idx < colors.count ? colors[idx] : SIMD4<UInt8>(180, 180, 180, 255)
                    soupColors.append(Float(c.x) / 255.0)
                    soupColors.append(Float(c.y) / 255.0)
                    soupColors.append(Float(c.z) / 255.0)
                    soupColors.append(1.0)
                }
            }
            
            let totalVerts = triCount * 3
            
            // --- Step 2: 构建 SCNGeometrySource ---
            let vertexData = Data(bytes: soupVerts, count: soupVerts.count * MemoryLayout<Float>.size)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: totalVerts,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            )
            
            let colorData = Data(bytes: soupColors, count: soupColors.count * MemoryLayout<Float>.size)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: totalVerts,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            
            // --- Step 3: 索引（连续递增） ---
            var soupIdx = [Int32](repeating: 0, count: totalVerts)
            for i in 0..<totalVerts { soupIdx[i] = Int32(i) }
            
            let idxData = Data(bytes: soupIdx, count: soupIdx.count * MemoryLayout<Int32>.size)
            let element = SCNGeometryElement(
                data: idxData,
                primitiveType: .triangles,
                primitiveCount: triCount,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            
            // --- Step 4: 组装 geometry ---
            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            
            let material = SCNMaterial()
            material.lightingModel = .constant   // 无光照 → 颜色直出
            material.diffuse.contents = UIColor.white
            material.isDoubleSided = true
            geometry.materials = [material]
            
            print("📄 PLY 渲染: Triangle Soup + Float 顶点色 (\(triCount) 三角形)")
            return geometry
            
        } else {
            // 无颜色或无面数据：灰色模式
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let elements: [SCNGeometryElement]
            if !indices.isEmpty {
                let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
                let element = SCNGeometryElement(
                    data: indexData,
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<Int32>.size
                )
                elements = [element]
            } else {
                let pointIndices = (0..<Int32(vertices.count)).map { $0 }
                let indexData = Data(bytes: pointIndices, count: pointIndices.count * MemoryLayout<Int32>.size)
                let element = SCNGeometryElement(
                    data: indexData,
                    primitiveType: .point,
                    primitiveCount: vertices.count,
                    bytesPerIndex: MemoryLayout<Int32>.size
                )
                element.pointSize = 3
                element.minimumPointScreenSpaceRadius = 2
                element.maximumPointScreenSpaceRadius = 5
                elements = [element]
            }
            
            let geometry = SCNGeometry(sources: [vertexSource], elements: elements)
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = UIColor.lightGray
            material.isDoubleSided = true
            geometry.materials = [material]
            return geometry
        }
    }
}

// MARK: - 6. AR Logic (Core)
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var appModel: AppModel
    
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        print("🛑 ARViewContainer dismantleUIView - 正在释放相机...")
        uiView.session.pause()
        uiView.session.delegate = nil
        coordinator.arView = nil
        
        // 延迟清理 appModel 属性，避免在 view update 中修改 Published 属性
        let appModel = coordinator.appModel
        Task { @MainActor in
            appModel.arView = nil
        }
        print("✅ ARSession 已暂停并释放")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // 关键修复：禁用自动会话配置，防止 ARView 覆盖我们的设置（这可能导致绿屏复发）
        arView.automaticallyConfigureSession = false
        
        context.coordinator.arView = arView  // 只修改 coordinator 的弱引用
        
        // 延迟设置 appModel.arView，避免在 view update 中修改 Published 属性
        let appModelRef = appModel
        Task { @MainActor in
            appModelRef.arView = arView
        }
        
        // 初始配置 - 优化精度
        let config = ARWorldTrackingConfiguration()
        
        // 关键：在 iOS 17 及更新版本中，不要禁用 CameraGrain 或开启其他后处理选项，
        // 否则会触发 RealityKit 底层的 `arInPlacePostProcessCombinedPermute` 找不到材质的报错，引起卡顿发热
        arView.renderOptions = [.disableMotionBlur]
        arView.debugOptions = []
        
        // 用于延迟更新的状态变量
        var shouldSetRelocalizing = false
        var shouldDisableLiDAR = false
        
        // 巡检模式如果已选择地图，在 makeUIView 时自动加载
        // 注意：如果是巡检模式且有选定的地图，则在这里加载地图
        if appModel.workMode == .operation, let mapURL = appModel.selectedMapForPatrol {
            // 巡检模式：自动加载地图，不开启 sceneReconstruction
            do {
                let data = try Data(contentsOf: mapURL)
                if let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                    config.sceneReconstruction = []  // 巡检模式不做新 Mesh
                    shouldSetRelocalizing = true
                    shouldDisableLiDAR = true
                    print("🔍 巡检模式启动：加载地图 \(mapURL.lastPathComponent)，不开启新 Mesh")
                    // 加载 QR 锚点（这个函数内部已经是同步的）
                    appModel.loadQRAnchors(forMapURL: mapURL)
                }
            } catch {
                print("地图加载失败: \(error)")
            }
        } else if appModel.workMode == .deployment && appModel.scanState == .scanning && appModel.isLiDAREnabled {
            // 部署模式 + 扫描状态 + LiDAR开启：才开启 sceneReconstruction
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                config.sceneReconstruction = .meshWithClassification
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
            
            // 优化：启用平滑场景深度（Smoothed Scene Depth）以获得更密集的深度数据
            // 注意：某些情况下开启 SceneDepth 可能导致 ARView 渲染调试颜色，暂时关闭以排查绿屏问题
            /*
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
            */
            print("📐 部署模式-扫描状态：开启 sceneReconstruction")
        } else {
            // 其他情况（部署模式但非扫描状态）：不开启 sceneReconstruction
            config.sceneReconstruction = []
            print("⏸️ 部署模式-准备状态：不开启 sceneReconstruction，等待用户点击开始扫描")
        }
        
        // 优化2：同时检测水平和垂直平面（提高特征点）
        config.planeDetection = [.horizontal, .vertical]
        
        // 优化3：开启自动对焦（提高纹理清晰度）
        config.isAutoFocusEnabled = true
        
        // 优化4：禁用环境纹理，因为 iOS 17 RealityKit 缺少 Builtin RenderGraph 而高概率触发底层 rematerial 崩溃与卡顿
        config.environmentTexturing = .none
        
        // 优化5：最大化追踪稳定性
        config.worldAlignment = .gravity // 重力对齐，减少漂移
        
        // 优化6：开启协作式会话数据（如果支持）
        if #available(iOS 13.0, *) {
            config.isCollaborationEnabled = false // 单设备场景，关闭以节省资源
        }

        arView.session.run(config)

        // 延迟更新所有 @Published 属性
        let isLiDAREnabled = appModel.isLiDAREnabled
        let sceneReconstructionEmpty = config.sceneReconstruction == []
        Task { @MainActor in
            // 更新巡检模式状态
            if shouldSetRelocalizing {
                appModelRef.isRelocalizing = true
            }
            if shouldDisableLiDAR {
                appModelRef.isLiDAREnabled = false
            }
            
            // 更新 LiDAR 状态显示
            if !isLiDAREnabled {
                appModelRef.lidarMeshStatus = "已关闭"
            } else if sceneReconstructionEmpty {
                appModelRef.lidarMeshStatus = "设备不支持"
            } else {
                appModelRef.lidarMeshStatus = "已开启"
            }
        }
        
        // 初始状态不显示 debug 信息，等 updateUIView 根据状态动态设置
        arView.debugOptions = []
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        context.coordinator.viewportSize = arView.bounds.size
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.viewportSize = uiView.bounds.size

        // 1. 检查 Tab 切换，暂停/恢复 Session
        // 如果当前不在 Tab 0 (空间扫描)，则暂停 ARSession 以释放相机给 ObjectCapture
        if appModel.selectedTab != 0 {
            // 强制暂停并移除代理，防止后台处理
            uiView.session.pause()
            return 
        }

        // 动态响应 LiDAR 开关
        // 关键修复：总是创建新的 config，因为 session.configuration 返回的是只读副本
        let config = ARWorldTrackingConfiguration()
        var shouldRun = false
        
        // 获取当前 session 的 sceneReconstruction 状态（用于比较）
        let currentSceneReconstruction = (uiView.session.configuration as? ARWorldTrackingConfiguration)?.sceneReconstruction ?? []
        
        // ⚠️ 绝对不能在 updateUIView 中访问 session.currentFrame!
        // updateUIView 在每次 SwiftUI @Published 属性变化时都会调用（每秒 30-60 次）
        // 每次访问 session.currentFrame 都会 retain 一帧
        // 这就是 "retaining 12 ARFrames" 的真正元凶!
        
        // 根据扫描状态和工作模式控制 sceneReconstruction
        let shouldEnableMesh = appModel.workMode == .deployment && 
                               appModel.isLiDAREnabled && 
                               appModel.scanState == .scanning  // 只有在扫描状态才开启 Mesh
        
        // 减少日志输出：只在状态变化时打印（移除 !currentMeshAnchors.isEmpty 条件）
        // 状态变化会在下方 scanStateChanged 处检测
        
        if appModel.workMode == .operation {
            // 巡检模式：强制关闭 sceneReconstruction
            config.sceneReconstruction = []
            if currentSceneReconstruction != [] {
                shouldRun = true
            }
        } else if shouldEnableMesh {
            // 部署模式 + LiDAR开启 + 扫描状态：开启带分类的 Mesh
            let supportsMeshWithClassification = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            
            if supportsMeshWithClassification {
                config.sceneReconstruction = .meshWithClassification
                // 只检查配置是否匹配，不检查 mesh 数量（避免频繁重启）
                if currentSceneReconstruction != .meshWithClassification {
                    shouldRun = true
                    print("✅ 将启用 sceneReconstruction = .meshWithClassification")
                }
            } else if supportsMesh {
                config.sceneReconstruction = .mesh
                if currentSceneReconstruction != .mesh {
                    shouldRun = true
                    print("✅ 将启用 sceneReconstruction = .mesh")
                }
            } else {
                config.sceneReconstruction = []
                // 只在状态变化时打印不支持信息
                if context.coordinator.lastScanState != appModel.scanState {
                    print("❌ 设备不支持 sceneReconstruction")
                }
            }
        } else {
            // 非扫描状态或关闭 LiDAR：关闭 sceneReconstruction
            config.sceneReconstruction = []
            if currentSceneReconstruction != [] {
                shouldRun = true
            }
        }
        
        // 根据扫描状态控制 debugOptions
        // 注意：rematerial 警告是 RealityKit 在 iOS 17 上使用 sceneReconstruction 时的已知行为
        // 它们是无害的日志输出，材质会自动 fallback 到 asset path 加载
        // 真正导致卡顿的是 updateUIView 中频繁访问 session.currentFrame（已修复）
        if appModel.scanState == .scanning && appModel.isLiDAREnabled {
            uiView.debugOptions = [.showSceneUnderstanding]
        } else {
            uiView.debugOptions = []
        }

        Task { @MainActor in
            if !appModel.isLiDAREnabled {
                appModel.lidarMeshStatus = "已关闭"
            } else if config.sceneReconstruction == [] {
                appModel.lidarMeshStatus = "设备不支持"
            } else {
                appModel.lidarMeshStatus = "已开启"
            }
        }
        
        // 确保 Plane Detection 始终开启
        config.planeDetection = [.horizontal, .vertical]
        
        // 确保其他重要配置项
        config.isAutoFocusEnabled = true
        // 避开会导致 `Could not resolve material name 'engine:BuiltinRenderGraphResources/AR/arInPlacePostProcess'` 的 Bug：
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        
        // 检查扫描状态是否从非 scanning 变为 scanning（强制重启）
        let scanStateChanged = context.coordinator.lastScanState != appModel.scanState
        if scanStateChanged {
            print("📢 扫描状态变化: \(context.coordinator.lastScanState) → \(appModel.scanState)")
            context.coordinator.lastScanState = appModel.scanState
            // 任何状态变化都强制重启 session
            shouldRun = true
            print("📢 状态变化，强制重启 session")
        }
        
        // 只在状态变化时打印完整日志
        if scanStateChanged || shouldRun {
            print("🔧 shouldRun=\(shouldRun), 目标sceneReconstruction=\(config.sceneReconstruction)")
        }
        
        // 如果需要更新配置 - 移除防抖，确保状态变化时立即响应
        if appModel.selectedTab == 0 && shouldRun {
            print("🚀 重新运行 ARSession, sceneReconstruction=\(config.sceneReconstruction)")
            uiView.session.run(config)
            context.coordinator.lastSessionRunTime = Date()
        }
        
        // ========== 网格可视化逻辑 ==========
        // 已在上方扫描状态块中统一处理 debugOptions
        if appModel.shouldResetSession, let mapURL = appModel.mapToLoad {
            loadAndReset(arView: uiView, mapURL: mapURL)
            
            // Reset flags immediately on MainActor to avoid loop
            DispatchQueue.main.async {
                appModel.shouldResetSession = false
                appModel.mapToLoad = nil
                appModel.isRelocalizing = true // 标记开始重定位
                appModel.clearCameraFrameCache() // 清空相机帧缓存
            }
        }
    }
    
    private func loadAndReset(arView: ARView, mapURL: URL) {
        do {
            let data = try Data(contentsOf: mapURL)
            if let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                let config = ARWorldTrackingConfiguration()
                config.initialWorldMap = worldMap
                
                // 关键改动：巡检模式不开启 sceneReconstruction，只做重定位
                // 部署模式才开启新的 Mesh 扫描
                if appModel.workMode == .deployment && appModel.isLiDAREnabled {
                    // 部署模式：开启 LiDAR 重建（继续建图）
                    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                        config.sceneReconstruction = .meshWithClassification
                    } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                        config.sceneReconstruction = .mesh
                    }
                    print("📐 部署模式：开启 sceneReconstruction 继续建图")
                } else if appModel.workMode == .operation {
                    // 巡检模式：不开启 sceneReconstruction，只做重定位
                    config.sceneReconstruction = []
                    print("🔍 巡检模式：不开启 sceneReconstruction，仅重定位")
                }
                
                config.planeDetection = [.horizontal, .vertical]
                
                arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                print("已加载地图，开始重定位...")
            }
        } catch {
            print("地图加载失败: \(error)")
        }
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        var appModel: AppModel
        weak var arView: ARView?
        var viewportSize: CGSize = .zero
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private var isQRDetectionInProgress: Bool = false
        
        /// 快速 CPU 拷贝像素缓冲区（~1-2ms），让 ARKit 立即回收原始帧
        /// 这是解决 "retaining xx ARFrames" 的关键：不在代理线程调用任何 GPU 操作
        private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let format = CVPixelBufferGetPixelFormatType(source)
            
            var copy: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &copy)
            guard status == kCVReturnSuccess, let dest = copy else { return nil }
            
            CVPixelBufferLockBaseAddress(source, .readOnly)
            CVPixelBufferLockBaseAddress(dest, [])
            defer {
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
                CVPixelBufferUnlockBaseAddress(dest, [])
            }
            
            let planeCount = CVPixelBufferGetPlaneCount(source)
            if planeCount > 0 {
                for plane in 0..<planeCount {
                    let srcAddr = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
                    let dstAddr = CVPixelBufferGetBaseAddressOfPlane(dest, plane)!
                    let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                    let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                    if srcBPR == dstBPR {
                        memcpy(dstAddr, srcAddr, srcBPR * rows)
                    } else {
                        for row in 0..<rows {
                            memcpy(dstAddr + row * dstBPR, srcAddr + row * srcBPR, min(srcBPR, dstBPR))
                        }
                    }
                }
            } else {
                let srcAddr = CVPixelBufferGetBaseAddress(source)!
                let dstAddr = CVPixelBufferGetBaseAddress(dest)!
                let srcBPR = CVPixelBufferGetBytesPerRow(source)
                let dstBPR = CVPixelBufferGetBytesPerRow(dest)
                if srcBPR == dstBPR {
                    memcpy(dstAddr, srcAddr, srcBPR * height)
                } else {
                    for row in 0..<height {
                        memcpy(dstAddr + row * dstBPR, srcAddr + row * srcBPR, min(srcBPR, dstBPR))
                    }
                }
            }
            
            return dest
        }
        private var lastAutoRelocalizationTime: TimeInterval = 0
        private let autoRelocalizationCooldown: TimeInterval = 3.0
        var lastSessionRunTime: Date = .distantPast  // 上次 session.run 的时间
        var lastScanState: AppModel.ScanState = .idle // 上次的扫描状态
        
        // 专用串行队列，优先级降为 background，防止与 ARKit sceneReconstruction 争抢 CPU
        // 这是解决"采集30帧后网格不再更新"的关键：让纹理处理让路给 ARKit
        private let frameProcessingQueue = DispatchQueue(label: "com.leida.frameProcessing", qos: .background)
        private var isFrameCaptureInProgress: Bool = false
        
        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleSaveMesh), name: .requestSaveMesh, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleSaveMap), name: .requestSaveMap, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleForceStop), name: .forceStopARSession, object: nil)
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc func handleForceStop() {
            print("🛑 收到强制停止 ARSession 通知")
            if let arView = arView {
                arView.session.pause()
                arView.session.delegate = nil
                print("✅ ARSession 已强制暂停")
            }
        }
        
        func session(_ session: ARSession, didFailWithError error: Error) {
            // 处理 ARSession 错误，尝试恢复
            if let arError = error as? ARError {
                print("ARSession Error: \(arError.code) - \(arError.localizedDescription)")
                switch arError.code {
                case .sensorFailed, .cameraUnauthorized:
                    // 严重错误，可能需要用户干预或重启 Session
                    Task { @MainActor in
                        appModel.trackingState = "摄像头错误: \(arError.localizedDescription)"
                        // 尝试重置
                        if appModel.selectedTab == 0 {
                            // 只有在当前页面才尝试重启
                            // 延迟一点重启
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            let config = session.configuration ?? ARWorldTrackingConfiguration()
                            session.run(config, options: [.resetTracking, .removeExistingAnchors])
                        }
                    }
                default:
                    break
                }
            }
        }
        
        // MARK: - 网格线框可视化 (系统原生)
        // 由 updateUIView 中的 debugOptions = [.showSceneUnderstanding] 控制
        // 无需手动构建 MeshEntities，系统原生渲染效率最高
        
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        }
        
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        }
        
        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        }
        
        private func addOrUpdateMeshVisualization(for meshAnchor: ARMeshAnchor) {
        }
        
        private func removeMeshVisualization(for identifier: UUID) {
        }
        
        func clearAllMeshVisualizations() {
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // 重要：不要保留对 frame 的引用，只提取需要的数据
            let currentTime = frame.timestamp
            let cameraTransform = frame.camera.transform
            let trackingState = frame.camera.trackingState
            
            // MARK: - QR 码检测（用于重定位校正）
            // 只有在巡检模式下，或者部署模式扫描中，才需要检测 QR 码
            // 如果不加这个判断，QR 检测会一直运行导致卡顿！
            if (appModel.workMode == .operation || (appModel.workMode == .deployment && appModel.scanState == .scanning)),
               currentTime - appModel.lastQRScanTime >= appModel.qrScanInterval {
                appModel.lastQRScanTime = currentTime
                detectQRCodes(in: frame)
            }
            
            // MARK: - 相机帧捕获（用于真实纹理映射，仅在用户手动开启时运行）
            if appModel.isTextureCaptureEnabled &&
               appModel.scanState == .scanning &&
               currentTime - appModel.lastFrameCaptureTime >= appModel.frameCaptureInterval {
                appModel.lastFrameCaptureTime = currentTime
                captureFrameForTexture(frame: frame)
            }
            
            // 节流更新 UI
            if currentTime.remainder(dividingBy: 0.5) < 0.05 {
                // 直接从当前 frame 提取数据，不要访问 session.currentFrame（会额外保留一帧）
                let mappingStatus = frame.worldMappingStatus
                let position = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
                
                Task { @MainActor in
                    appModel.trackingState = describeState(trackingState)
                    
                    // --- 核心逻辑修复：坐标更新与重定位状态强关联 ---
                    
                    // 1. 状态机推导
                    if case .limited(let reason) = trackingState {
                        if reason == .relocalizing {
                            appModel.locQuality = .relocalizing
                            appModel.locQualityMessage = "⚠️ 寻找特征点中... (请移动设备)"
                        } else {
                            appModel.locQuality = .limited(describeReason(reason))
                            appModel.locQualityMessage = "⚠️ 定位受限: \(describeReason(reason))"
                        }
                    } else if case .normal = trackingState {
                        // 即使 Tracking 正常，也要看地图有没有 Load 进去
                        if mappingStatus == .mapped || mappingStatus == .extending {
                            appModel.locQuality = .good
                            appModel.locQualityMessage = "✅ 定位成功 (误差范围±10cm)"
                            
                            // 只有在 Good 状态下，才认为刚才的重定位真正完成了
                            if appModel.isRelocalizing {
                                appModel.isRelocalizing = false
                                appModel.alertMessage = "✅ 重定位成功！\n坐标系统已对齐。"
                                appModel.showAlert = true
                            }
                        } else {
                            // Tracking 正常，但没有 World Map (比如刚开始扫)
                            appModel.locQuality = .good
                            appModel.locQualityMessage = "建图定位正常"
                        }
                    } else {
                        appModel.locQuality = .lost
                        appModel.locQualityMessage = "❌ 定位丢失"
                    }
                    
                    // 2. 更新显示的重定位状态文本 (用于 Debug)
                    switch mappingStatus {
                        case .mapped: appModel.relocalizationStatus = "已映射 (Mapped)"
                        case .extending: appModel.relocalizationStatus = "扩展中 (Extending)"
                        case .limited: appModel.relocalizationStatus = "地图受限 (Limited)"
                        case .notAvailable: appModel.relocalizationStatus = "不可用"
                        @unknown default: break
                    }
                    
                    // 3. 更新 XYZ 坐标（应用 QR 校正偏移）
                    appModel.currentPosition = position + appModel.relocalizationOffset
                }
            }
        }
        
        func describeReason(_ reason: ARCamera.TrackingState.Reason) -> String {
            switch reason {
            case .initializing: return "初始化中"
            case .relocalizing: return "重定位中"
            case .excessiveMotion: return "移动过快"
            case .insufficientFeatures: return "特征不足(请看纹理丰富处)"
            @unknown default: return "未知原因"
            }
        }
        
        @objc func handleSaveMesh() {
            guard let arView = arView, let frame = arView.session.currentFrame else { return }
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            Task { @MainActor in
                // 保存待导出的网格，显示选项弹窗
                appModel.pendingMeshAnchors = meshAnchors
                appModel.showExportOptions = true
            }
        }
        
        @objc func handleSaveMap() {
            guard let arView = arView else { return }
            Task { @MainActor in
                appModel.saveWorldMap(session: arView.session)
            }
        }
        
        // MARK: - 相机帧捕获（用于真实纹理映射）
        func captureFrameForTexture(frame: ARFrame) {
            guard !isFrameCaptureInProgress else { return }
            isFrameCaptureInProgress = true
            
            let transform = frame.camera.transform
            let intrinsics = frame.camera.intrinsics
            let timestamp = frame.timestamp
            
            // 关键：用快速 CPU memcpy 拷贝像素数据（~1-2ms），不调用任何 GPU 操作
            // 这样 ARFrame 在本函数返回后立即被 ARC 释放，不堵塞 ARKit 缓冲池
            guard let copiedBuffer = copyPixelBuffer(frame.capturedImage) else {
                isFrameCaptureInProgress = false
                return
            }
            
            // 所有 GPU 耗时操作都在后台队列执行，使用我们自己的像素副本
            frameProcessingQueue.async { [weak self] in
                guard let self = self else { 
                    return 
                }
                
                defer {
                    DispatchQueue.main.async {
                        self.isFrameCaptureInProgress = false
                    }
                }
                
                // 在后台线程用 CIContext 转换（使用拷贝的 buffer，不影响 ARKit）
                let ciImage = CIImage(cvPixelBuffer: copiedBuffer)
                guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
                
                let bufferWidth = cgImage.width
                let bufferHeight = cgImage.height
                let targetWidth = 960   // 从 480 提升到 960，纹理清晰度翻倍
                let scaleFactor = Float(targetWidth) / Float(bufferWidth)
                let targetHeight = Int(Float(bufferHeight) * scaleFactor)
                
                let totalBytes = targetWidth * targetHeight * 4
                var rgbaBytes = [UInt8](repeating: 0, count: totalBytes)
                
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                // 必须严格指定 ByteOrder32Big 和 premultipliedLast，确保内存排布强制为 R G B A
                let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(data: &rgbaBytes,
                                              width: targetWidth,
                                              height: targetHeight,
                                              bitsPerComponent: 8,
                                              bytesPerRow: targetWidth * 4,
                                              space: colorSpace,
                                              bitmapInfo: bitmapInfo) else { return }
                
                // 进行缩放绘制，使用中等插值保留细节
                context.interpolationQuality = .medium 
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
                
                let finalData = Data(rgbaBytes)
                
                // 3. 缩放相机内参矩阵
                var scaledIntrinsics = intrinsics
                scaledIntrinsics[0][0] *= scaleFactor  // fx
                scaledIntrinsics[1][1] *= scaleFactor  // fy
                scaledIntrinsics[2][0] *= scaleFactor  // cx
                scaledIntrinsics[2][1] *= scaleFactor  // cy
                
                let captured = AppModel.CapturedCameraFrame(
                    rgbaData: finalData,
                    width: targetWidth,
                    height: targetHeight,
                    transform: transform,
                    intrinsics: scaledIntrinsics,
                    timestamp: timestamp
                )
                
                Task { @MainActor in
                    self.appModel.addCapturedFrame(captured)
                }
            }
        }
        
        // MARK: - QR 码检测与位置计算
        
        // 用于传递 frame 数据的结构体，避免在闭包中保留 ARFrame
        struct FrameData {
            let intrinsics: simd_float3x3
            let cameraTransform: simd_float4x4
            let imageWidth: Int
            let imageHeight: Int
            let timestamp: TimeInterval
        }
        
        func detectQRCodes(in frame: ARFrame) {
            guard !isQRDetectionInProgress else { return }
            isQRDetectionInProgress = true

            let pixelBuffer = frame.capturedImage
            let timestamp = frame.timestamp
            
            // 在进入 async 之前提取所有需要的 frame 数据
            let frameData = FrameData(
                intrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform,
                imageWidth: CVPixelBufferGetWidth(pixelBuffer),
                imageHeight: CVPixelBufferGetHeight(pixelBuffer),
                timestamp: timestamp
            )
            let physicalSize = appModel.qrCodePhysicalSize
            
            // 快速 CPU 拷贝像素数据（~1-2ms），立即释放原始 ARFrame
            guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else {
                isQRDetectionInProgress = false
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // 创建 Vision 请求
                let request = VNDetectBarcodesRequest { [weak self] request, error in
                    guard let self = self,
                          error == nil,
                          let results = request.results as? [VNBarcodeObservation] else { return }

                    for barcode in results {
                        // 只处理 QR 码
                        guard barcode.symbology == .qr,
                              let content = barcode.payloadStringValue,
                              content.hasPrefix("LEIDA_") else { continue }

                        // 使用 QR 码角点 + 提取的 frame 数据计算位置
                        let qrInfo = self.calculateQRPositionFromData(
                            barcode: barcode,
                            frameData: frameData,
                            physicalSize: physicalSize
                        )

                        guard let worldPosition = qrInfo.position else { continue }

                        Task { @MainActor in
                            // 更新检测信息（用于 UI 显示）
                            self.appModel.lastDetectedQR = content
                            self.appModel.lastDetectedQRTime = Date()
                            self.appModel.lastDetectedQRPosition = worldPosition
                            self.appModel.lastDetectedQRDistance = qrInfo.estimatedDistance

                            if self.appModel.workMode == .deployment {
                                // 部署模式：只要定位成功就记录锚点（不限制扫描状态）
                                self.appModel.updateQRAnchor(
                                    content: content,
                                    position: worldPosition,
                                    timestamp: timestamp,
                                    forceRecord: true
                                )

                                // 检测漂移（距离越远容差越大）
                                if let existing = self.appModel.qrAnchors[content], existing.observations > 3 {
                                    let drift = simd_length(worldPosition - existing.worldPosition)
                                    let threshold = self.driftThresholdMeters(estimatedDistance: qrInfo.estimatedDistance)
                                    if drift > threshold {
                                        self.appModel.driftWarning = "漂移: \(String(format: "%.0f", drift * 100))cm"
                                    } else {
                                        self.appModel.driftWarning = nil
                                    }
                                }
                            } else if self.appModel.workMode == .operation,
                                      self.appModel.isAutoQRRelocalizationEnabled,
                                      self.appModel.isQRCorrectionEnabled,
                                      timestamp - self.lastAutoRelocalizationTime > self.autoRelocalizationCooldown {
                                self.lastAutoRelocalizationTime = timestamp
                                self.tryQRCorrection(content: content, detectedPosition: worldPosition)
                            }
                        }
                    }
                }

                request.symbologies = [.qr]
                // 使用拷贝的 pixelBuffer 而非原始的，确保 ARFrame 已经被释放
                let handler = VNImageRequestHandler(cvPixelBuffer: copiedBuffer, orientation: .right, options: [:])
                try? handler.perform([request])

                DispatchQueue.main.async {
                    self.isQRDetectionInProgress = false
                }
            }
        }
        
        // 基于 QR 码角点和物理尺寸计算 3D 位置
        struct QRPositionInfo {
            var position: SIMD3<Float>?
            var estimatedDistance: Float?
            var centerNormalized: CGPoint?
        }
        
        func calculateQRPosition(barcode: VNBarcodeObservation, frame: ARFrame, physicalSize: Float) -> QRPositionInfo {
            var info = QRPositionInfo()
            
            // 使用四角点计算中心（避免倾斜时 boundingBox 偏差）
            let center = qrCenterNormalized(from: barcode)
            info.centerNormalized = center
            
            // 图像的实际像素尺寸
            let imageWidth = CGFloat(CVPixelBufferGetWidth(frame.capturedImage))
            let imageHeight = CGFloat(CVPixelBufferGetHeight(frame.capturedImage))
            
            // 通过 QR 码在图像中的边长估算距离
            let qrSizeInImage = qrSizeNormalized(from: barcode)
            let qrPixelSize = qrSizeInImage * max(imageWidth, imageHeight)
            
            // 相机内参（使用 ARKit 提供的内参）
            let intrinsics = frame.camera.intrinsics
            let focalLength = (intrinsics[0][0] + intrinsics[1][1]) / 2
            let estimatedDistance = (physicalSize * focalLength) / Float(max(qrPixelSize, 1))
            info.estimatedDistance = estimatedDistance
            
            // 1) 优先使用 raycast 获取真实深度
            if let arView = arView, viewportSize.width > 0, viewportSize.height > 0 {
                let screenPoint = CGPoint(
                    x: center.x * viewportSize.width,
                    y: (1 - center.y) * viewportSize.height
                )
                let results = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
                if let hit = results.first {
                    let pos = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
                    info.position = pos
                    let camPos = frame.camera.transform.columns.3
                    info.estimatedDistance = simd_distance(pos, SIMD3<Float>(camPos.x, camPos.y, camPos.z))
                    return info
                }
            }
            
            // 2) 退化方案：内参反投影 + 估计深度
            let u = center.x * imageWidth
            let v = (1 - center.y) * imageHeight  // Vision 原点在左下，UIKit 在左上
            let fx = intrinsics[0][0]
            let fy = intrinsics[1][1]
            let cx = intrinsics[2][0]
            let cy = intrinsics[2][1]
            let z = max(estimatedDistance, 0.05)
            let x = (Float(u) - cx) / fx * z
            let y = (Float(v) - cy) / fy * z
            let camPoint = simd_float4(x, y, z, 1)
            let worldPoint = frame.camera.transform * camPoint
            info.position = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
            
            print("📐 QR位置估计: 像素尺寸=\(String(format: "%.1f", qrPixelSize))px, 估算距离=\(String(format: "%.2f", z))m")
            return info
        }
        
        // 使用 FrameData 而非 ARFrame 的版本（避免在闭包中保留 ARFrame）
        func calculateQRPositionFromData(barcode: VNBarcodeObservation, frameData: FrameData, physicalSize: Float) -> QRPositionInfo {
            var info = QRPositionInfo()
            
            // 使用四角点计算中心
            let center = qrCenterNormalized(from: barcode)
            info.centerNormalized = center
            
            let imageWidth = CGFloat(frameData.imageWidth)
            let imageHeight = CGFloat(frameData.imageHeight)
            
            // 通过 QR 码在图像中的边长估算距离
            let qrSizeInImage = qrSizeNormalized(from: barcode)
            let qrPixelSize = qrSizeInImage * max(imageWidth, imageHeight)
            
            let intrinsics = frameData.intrinsics
            let focalLength = (intrinsics[0][0] + intrinsics[1][1]) / 2
            let estimatedDistance = (physicalSize * focalLength) / Float(max(qrPixelSize, 1))
            info.estimatedDistance = estimatedDistance
            
            // 1) 优先使用 raycast（必须在主线程调用）
            // 注意：这里我们在 background thread，所以只能用退化方案
            // raycast 需要在主线程+有 ARView 时执行，在这个版本中跳过
            
            // 2) 退化方案：内参反投影 + 估计深度
            let u = center.x * imageWidth
            let v = (1 - center.y) * imageHeight
            let fx = intrinsics[0][0]
            let fy = intrinsics[1][1]
            let cx = intrinsics[2][0]
            let cy = intrinsics[2][1]
            let z = max(estimatedDistance, 0.05)
            let x = (Float(u) - cx) / fx * z
            let y = (Float(v) - cy) / fy * z
            let camPoint = simd_float4(x, y, z, 1)
            let worldPoint = frameData.cameraTransform * camPoint
            info.position = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
            
            return info
        }

        private func qrCenterNormalized(from barcode: VNBarcodeObservation) -> CGPoint {
            let points = [barcode.topLeft, barcode.topRight, barcode.bottomLeft, barcode.bottomRight]
            let valid = points.filter { $0 != .zero }
            if valid.count >= 2 {
                let sum = valid.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return CGPoint(x: sum.x / CGFloat(valid.count), y: sum.y / CGFloat(valid.count))
            }
            return CGPoint(x: barcode.boundingBox.midX, y: barcode.boundingBox.midY)
        }

        private func qrSizeNormalized(from barcode: VNBarcodeObservation) -> CGFloat {
            let tl = barcode.topLeft
            let tr = barcode.topRight
            let bl = barcode.bottomLeft
            if tl != .zero && tr != .zero && bl != .zero {
                let w = hypot(tr.x - tl.x, tr.y - tl.y)
                let h = hypot(bl.x - tl.x, bl.y - tl.y)
                return max(w, h)
            }
            return max(barcode.boundingBox.width, barcode.boundingBox.height)
        }

        private func driftThresholdMeters(estimatedDistance: Float?) -> Float {
            let d = max(estimatedDistance ?? 1.0, 0.3)
            return min(0.5, max(0.12, 0.05 + d * 0.08))
        }
        
        // 尝试使用 QR 码进行重定位校正
        func tryQRCorrection(content: String, detectedPosition: SIMD3<Float>) {
            guard appModel.isQRCorrectionEnabled else { return }
            guard let savedAnchor = appModel.qrAnchors[content] else {
                print("⚠️ 检测到 QR 码 \(content)，但没有保存的位置信息")
                // 巡检模式下，如果 QR 锚点来自地图文件但为空，给出提示
                if appModel.workMode == .operation {
                    Task { @MainActor in
                        appModel.alertMessage = "QR 码 \(content) 没有关联位置信息。\n请确保该地图包含 QR 锚点数据。"
                        appModel.showAlert = true
                    }
                }
                return
            }
            
            // 计算偏移量：savedPosition - currentlyDetectedPosition
            // 这个偏移量表示：要把当前坐标系修正到保存时的坐标系，需要加上多少
            let offset = savedAnchor.worldPosition - detectedPosition
            let distance = simd_length(offset)
            
            // 详细日志
            print("🔍 QR 校正分析: \(content)")
            print("   保存位置: (\(String(format: "%.3f, %.3f, %.3f", savedAnchor.worldPosition.x, savedAnchor.worldPosition.y, savedAnchor.worldPosition.z)))")
            print("   当前检测: (\(String(format: "%.3f, %.3f, %.3f", detectedPosition.x, detectedPosition.y, detectedPosition.z)))")
            print("   偏移量: (\(String(format: "%.3f, %.3f, %.3f", offset.x, offset.y, offset.z))), 距离: \(String(format: "%.3f", distance))m")
            
            // 如果偏差太小（<5cm），认为已经匹配
            if distance < 0.05 {
                print("✅ QR 码 \(content) 位置匹配良好，无需校正")
                Task { @MainActor in
                    appModel.isRelocalizing = false
                    appModel.relocalizationOffset = .zero
                    appModel.alertMessage = "✅ 重定位成功！位置精确匹配。"
                    appModel.showAlert = true
                }
                return
            }
            
            // 如果偏差太大（>3m），可能是误检测或地图不匹配
            if distance > 3.0 {
                print("⚠️ QR 码 \(content) 偏差过大 (\(String(format: "%.2f", distance))m)，可能地图不匹配")
                Task { @MainActor in
                    appModel.alertMessage = "⚠️ QR 码位置偏差过大（\(String(format: "%.1f", distance))m）\n可能加载了错误的地图，或 ARKit 重定位失败。"
                    appModel.showAlert = true
                }
                return
            }
            
            // 应用校正
            print("🔄 应用 QR 码校正: \(content)")
            
            Task { @MainActor in
                appModel.relocalizationOffset = offset
                appModel.isRelocalizing = false
                
                // 显示校正成功提示
                appModel.alertMessage = "✅ QR 码重定位校正成功！\n偏移修正: X=\(String(format: "%.0f", offset.x * 100))cm, Y=\(String(format: "%.0f", offset.y * 100))cm, Z=\(String(format: "%.0f", offset.z * 100))cm"
                appModel.showAlert = true
            }
        }
        
        func describeState(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .normal: return "追踪正常"
            case .notAvailable: return "不可用"
            case .limited(let reason):
                switch reason {
                case .relocalizing: return "正在重定位..."
                default: return "追踪受限"
                }
            }
        }
    }
}

extension Notification.Name {
    static let requestSaveMesh = Notification.Name("requestSaveMesh")
    static let requestSaveMap = Notification.Name("requestSaveMap")
    static let forceStopARSession = Notification.Name("forceStopARSession")
}

#Preview {
    ContentView()
}


// MARK: - 7. Object Capture (基于 iOS 17 ObjectCapture API 自动引导)
@available(iOS 17.0, *)
struct ObjectCaptureContainer: View {
    @ObservedObject var appModel: AppModel
    
    @State private var session: ObjectCaptureSession?
    @State private var isSessionReady = false
    
    @State private var isReconstructing = false
    @State private var reconstructionProgress: Float = 0.0
    @State private var buildMessage: String = "准备中..."
    
    // 用于保存扫描照片的本地目录
    let captureDir: URL = {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docDir.appendingPathComponent("AutoCaptureImages")
        return dir
    }()
    
    var body: some View {
        ZStack {
            // 苹果官方引导式捕获界面
            if let session = session, isSessionReady {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在初始化相机...")
                        .foregroundColor(.white)
                }
            }
            
            // 界面交互覆盖层
            if isReconstructing {
                // 模型合成状态页面
                VStack(spacing: 20) {
                    Image(systemName: "square.stack.3d.down.forward.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                    
                    Text("正在生成真实色彩模型...")
                        .font(.title3)
                        .bold()
                    
                    Text("这将会运用 Photogrammetry 处理高精度色彩\n该过程需消耗较大算力，请耐心等待")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 40)
                    
                    ProgressView(value: reconstructionProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                    
                    Text("\(Int(reconstructionProgress * 100))%")
                        .font(.headline)
                    
                    Text(buildMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            } else {
                VStack {
                    Spacer()
                    
                    // 状态提示及按钮
                    VStack(spacing: 16) {
                        if let session = session, case .initializing = session.state {
                            Text("正在初始化相机与 LiDAR...")
                                .foregroundColor(.white)
                                .padding()
                                .background(.black.opacity(0.6))
                                .cornerRadius(10)
                        } else if let session = session, case .ready = session.state {
                            Text("请将镜头对准您要扫描的物体")
                                .foregroundColor(.white)
                                .padding()
                                .background(.black.opacity(0.6))
                                .cornerRadius(10)
                                
                            Button(action: { session.startDetecting() }) {
                                Text("开始对准")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color.blue)
                                    .cornerRadius(25)
                            }
                            .padding(.horizontal, 40)
                            
                        } else if let session = session, case .detecting = session.state {
                            Text("您可以拖拉 3D 边框调整物体大小")
                                .foregroundColor(.white)
                                .padding()
                                .background(.black.opacity(0.6))
                                .cornerRadius(10)
                                
                            Button(action: { session.startCapturing() }) {
                                Text("确认边框并开始自动扫描")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color.yellow)
                                    .cornerRadius(25)
                            }
                            .padding(.horizontal, 40)
                            
                        } else if let session = session, case .capturing = session.state {
                            Text("请跟随屏幕光点引导移动，补全扫描视角")
                                .foregroundColor(.white)
                                .padding()
                                .background(.black.opacity(0.6))
                                .cornerRadius(10)
                                
                            Button(action: { session.finish() }) {
                                Text("提前结束并生成模型")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 20)
                                    .background(.white.opacity(0.9))
                                    .cornerRadius(20)
                            }
                        } else if let session = session, case .finishing = session.state {
                            Text("正在处理图片并等待会话完成...")
                                .foregroundColor(.white)
                                .padding()
                                .background(.black.opacity(0.6))
                                .cornerRadius(10)
                        }
                    }
                    .padding(.bottom, 40)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            // 延迟初始化，确保 ARSession 已完全释放相机
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                setupAndStart()
            }
        }
        .onChange(of: session?.state) { oldState, newState in
            if case .completed = newState {
                startReconstruction()
            }
        }
        .onDisappear {
            // 彻底清理 ObjectCaptureSession，释放相机资源
            // 这是防止连续切换崩溃的关键！
            if let session = session {
                if session.state == .capturing || session.state == .detecting || session.state == .initializing || session.state == .ready {
                    session.cancel()
                }
            }
            session = nil
            isSessionReady = false
        }
    }
    
    private func setupAndStart() {
        // 清理旧 session（如果有的话）
        if let oldSession = session {
            oldSession.cancel()
            session = nil
        }
        
        // 清理旧资源目录
        if FileManager.default.fileExists(atPath: captureDir.path) {
            try? FileManager.default.removeItem(at: captureDir)
        }
        try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        
        // 创建全新的 session
        let newSession = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        newSession.start(imagesDirectory: captureDir, configuration: config)
        session = newSession
        isSessionReady = true
    }
    
    private func startCapturing() {
        session?.startCapturing()
    }
    
    private func startReconstruction() {
        isReconstructing = true
        reconstructionProgress = 0.0
        buildMessage = "准备导入 Photogrammetry 引擎..."
        
        Task {
            do {
                // 检查文件夹中的照片数量，不足以建模会抛出异常
                let fileManager = FileManager.default
                let imageFiles = try? fileManager.contentsOfDirectory(at: captureDir, includingPropertiesForKeys: nil)
                let imageCount = imageFiles?.filter { $0.pathExtension.lowercased() == "heic" || $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }.count ?? 0
                
                guard imageCount >= 10 else {
                    await MainActor.run {
                        isReconstructing = false
                        appModel.alertMessage = "扫描失败：照片数量不足 (\(imageCount)张)。\n请确保在引导下围绕物体扫描更长时间，至少需要 10-20 张照片才能构成 3D 模型。"
                        appModel.showAlert = true
                    }
                    return
                }
                
                let pgSession = try PhotogrammetrySession(input: captureDir)
                
                // 输出最终的逼真带材质 usdz 模型
                let fileName = "RealColorModel_\(Int(Date().timeIntervalSince1970)).usdz"
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let outputURL = docDir.appendingPathComponent(fileName)
                
                // 创建请求，设定网格质量
                let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: .reduced)
                try pgSession.process(requests: [request])
                
                for try await output in pgSession.outputs {
                    switch output {
                    case .processingComplete:
                        await MainActor.run {
                            isReconstructing = false
                            appModel.alertMessage = "✅ 成功生成带真实色彩的 3D 模型！\n已保存至文件库: \(fileName)"
                            appModel.showAlert = true
                            appModel.loadSavedFiles()
                        }
                    case .requestError(_, let error):
                        await MainActor.run {
                            isReconstructing = false
                            appModel.alertMessage = "❌ 重建失败: \(error.localizedDescription)"
                            appModel.showAlert = true
                        }
                    case .requestProgress(_, let fraction):
                        await MainActor.run {
                            reconstructionProgress = Float(fraction)
                            buildMessage = "正在构建真实色彩点云与材质：\(Int(fraction * 100))%"
                        }
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    isReconstructing = false
                    appModel.alertMessage = "初始化 Photogrammetry 失败: \(error.localizedDescription)"
                    appModel.showAlert = true
                }
            }
        }
    }
}

