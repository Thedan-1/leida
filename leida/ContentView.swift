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
    @Published var shouldSaveMap: Bool = false
    @Published var mapToLoad: URL?
    @Published var shouldResetSession: Bool = false
    @Published var isLiDAREnabled: Bool = true // 控制 LiDAR 开关
    @Published var isMeshColoringEnabled: Bool = true // 控制网格分类显示
    @Published var isRelocalizing: Bool = false // 是否正在重定位中
    @Published var isSessionStarted: Bool = false // 是否已启动 AR 会话
    @Published var currentPosition: SIMD3<Float> = .zero // 当前 XYZ 坐标

    // 使用模式
    @Published var workMode: WorkMode = .deployment

    // 设备能力/运行状态
    @Published var lidarMeshStatus: String = ""
    
    // 设置与着色
    @Published var showSettings: Bool = false
    @Published var coloringMode: ColoringMode = .ai
    
    enum ColoringMode: String, CaseIterable, Identifiable {
        case none = "无颜色 (白模)"
        case ai = "AI 语义 (分类色)"
        // case reality = "真实色彩 (开发中)" // 暂时隐藏，需要复杂的纹理烘焙算法
        
        var id: String { self.rawValue }
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
                    $0.pathExtension == "json"
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

        // Swift 6: 避免在 detached 里使用 MainActor 隔离的 Encodable conformance
        let dataToWrite: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            dataToWrite = try encoder.encode(report)
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
    
    // 导出 Mesh (支持 OBJ 和 PLY)
    func exportMesh(anchors: [ARMeshAnchor]) {
        guard !anchors.isEmpty else {
            alertMessage = "当前没有扫描到任何网格数据。"
            showAlert = true
            return
        }
        
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
                // classification.buffer 包含每个面的分类索引 (UInt8)
                let count = classification.count // 面数
                classData = Data(bytes: classification.buffer.contents(), count: count)
            }
            
            return (transform, vertexData, faceData, classData, vertexCount, faceCount, vertexStride, faceBytesPerIndex)
        }
        
        let mode = self.coloringMode
        
        // 2. 后台处理
        Task.detached(priority: .userInitiated) {
            do {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                
                if mode == .none {
                    // 导出 OBJ (白模)
                    let fileName = "Scan_\(Int(Date().timeIntervalSince1970)).obj"
                    let fileURL = docDir.appendingPathComponent(fileName)
                    let content = self.generateOBJFromRawData(data: rawData)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                } else {
                    // 导出 PLY (带颜色)
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
                    
                    self.alertMessage = "地图保存成功！下次可加载此地图进行重定位。"
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
        alertMessage = "正在加载地图，请移动设备以进行重定位..."
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
        var plyHeader = """
        ply
        format ascii 1.0
        comment BoilerPatrol Scan Export (PLY)
        """
        
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
            item.vertexData.withUnsafeBytes { vBuffer in
                guard let vBase = vBuffer.baseAddress else { return }
                
                item.faceData.withUnsafeBytes { fBuffer in
                    guard let fBase = fBuffer.baseAddress else { return }
                    
                    // 分类数据指针
                    var cBase: UnsafeRawPointer? = nil
                    if let cData = item.classData {
                        cData.withUnsafeBytes { cBuffer in
                            cBase = cBuffer.baseAddress
                        }
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
                        if mode == .ai, let cPtr = cBase {
                            // ARMeshClassification 是基于面的，每个面一个 UInt8
                            let classIndex = cPtr.load(fromByteOffset: i, as: UInt8.self)
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
                    
                    FileLibraryView(appModel: appModel)
                        .tabItem {
                            Label("文件库", systemImage: "folder.fill")
                        }
                        .tag(1)
                }
                .onChange(of: appModel.selectedTab) { oldTab, newTab in
                    // 切换到物体扫描时，强制停止 ARSession 释放相机
                    if newTab == 2 {
                        print("📢 切换到物体扫描 Tab，发送停止 ARSession 通知...")
                        NotificationCenter.default.post(name: NSNotification.Name("forceStopARSession"), object: nil)
                        // 同时重置 session 状态，确保 ARView 被卸载
                        appModel.isSessionStarted = false
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
        .sheet(isPresented: $appModel.showSettings) {
            SettingsView(appModel: appModel)
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
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                if let user = appModel.currentUser {
                    Section(header: Text("账号")) {
                        HStack {
                            Text("姓名")
                            Spacer()
                            Text(user.displayName)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("手机号")
                            Spacer()
                            Text(user.phone)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("身份")
                            Spacer()
                            Text(user.role.rawValue)
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            appModel.logout()
                            dismiss()
                        } label: {
                            Text("退出登录")
                        }
                    }
                }

                Section(header: Text("扫描配置")) {
                    Toggle("启用 LiDAR 网格", isOn: $appModel.isLiDAREnabled)
                        .tint(.yellow)
                    
                    Toggle("启用 AI 语义分类", isOn: $appModel.isMeshColoringEnabled)
                        .tint(.yellow)
                }
                
                Section(header: Text("导出与显示")) {
                    Picker("上色模式", selection: $appModel.coloringMode) {
                        ForEach(AppModel.ColoringMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    
                    if appModel.coloringMode == .ai {
                        Text("ℹ️ 将导出为 .ply 格式以支持颜色显示。")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                
                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0 (Build 20260105)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("系统设置")
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

// MARK: - 3. Scan View (AR + Controls)
struct ScanView: View {
    @ObservedObject var appModel: AppModel
    @State private var showReportComposer: Bool = false
    @State private var hasEnteredCamera: Bool = false
    
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
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BoilerPatrol Pro")
                                .font(.headline)
                                .foregroundStyle(.yellow)

                            HStack(spacing: 10) {
                                Text(appModel.workMode.rawValue)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.55))
                                    .cornerRadius(10)

                                Button {
                                    // 返回模式选择页，同时卸载 ARView 释放相机
                                    hasEnteredCamera = false
                                    NotificationCenter.default.post(name: .forceStopARSession, object: nil)
                                } label: {
                                    Text("切换模式")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.black.opacity(0.55))
                                        .cornerRadius(10)
                                }
                            }

                            HStack {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(appModel.trackingState)
                                    .font(.caption)
                            }

                            if !appModel.lidarMeshStatus.isEmpty {
                                Text("LiDAR 网格: \(appModel.lidarMeshStatus)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(String(format: "X: %.2f  Y: %.2f  Z: %.2f",
                                        appModel.currentPosition.x,
                                        appModel.currentPosition.y,
                                        appModel.currentPosition.z))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.55))
                                .cornerRadius(6)

                            if !appModel.relocalizationStatus.isEmpty {
                                Text("定位: \(appModel.relocalizationStatus)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            if appModel.workMode == .deployment {
                                if appModel.relocalizationStatus != "已定位 (Mapped)" {
                                    Text("提示: 走动扩展环境，稳定后保存地图")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                if appModel.relocalizationStatus != "已定位 (Mapped)" {
                                    Text("提示: 先加载地图，再缓慢移动完成重定位")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()

                        Button(action: {
                            appModel.showSettings = true
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal)
                    .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))

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
                        HStack(spacing: 12) {
                            if appModel.workMode == .deployment {
                                SecondaryCompactButton(title: "保存地图", systemImage: "map.fill") {
                                    NotificationCenter.default.post(name: .requestSaveMap, object: nil)
                                }

                                PrimaryPillButton(title: "保存模型", systemImage: "cube.transparent") {
                                    NotificationCenter.default.post(name: .requestSaveMesh, object: nil)
                                }
                            } else {
                                Menu {
                                    Button {
                                        appModel.loadLatestWorldMap()
                                    } label: {
                                        Label("加载最新地图", systemImage: "location.fill")
                                    }

                                    Button {
                                        appModel.selectedTab = 1
                                    } label: {
                                        Label("选地图（文件库）", systemImage: "folder.fill")
                                    }

                                    Button {
                                        NotificationCenter.default.post(name: .requestSaveMesh, object: nil)
                                    } label: {
                                        Label("保存模型", systemImage: "cube.transparent")
                                    }
                                } label: {
                                    SecondaryCompactButton(title: "更多", systemImage: "ellipsis.circle.fill") { }
                                }

                                PrimaryPillButton(title: "填写报告", systemImage: "doc.text.fill") {
                                    showReportComposer = true
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 26)
                    }
                }
            }
        }
        .sheet(isPresented: $showReportComposer) {
            InspectionReportComposerView(appModel: appModel)
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
}

private struct ScanModeEntryView: View {
    @ObservedObject var appModel: AppModel
    let onEnter: () -> Void

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
                        feature1: "保存 WorldMap",
                        feature2: "建立基线环境"
                    ) {
                        appModel.workMode = .deployment
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

                Spacer()

                Button {
                    onEnter()
                } label: {
                    Text("进入摄像头")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.yellow)
                        .cornerRadius(14)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("基础信息")) {
                    TextField("锅炉编号/设备号", text: $boilerId)
                    TextField("区域/位置（如：一层东侧）", text: $area)
                }

                Section(header: Text("读数（可选）")) {
                    TextField("温度 (°C)", text: $temperatureC)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("压力 (MPa)", text: $pressureMPa)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("水位/液位", text: $waterLevel)
                    TextField("阀位/开度", text: $valvePosition)
                }

                Section(header: Text("异常状态")) {
                    Toggle("异响", isOn: $abnormalNoise)
                    Toggle("泄漏", isOn: $leakage)
                    Toggle("振动", isOn: $vibration)
                    Toggle("冒烟/蒸汽异常", isOn: $smokeOrSteam)
                    Toggle("温压异常", isOn: $overTempOrPressure)
                    Toggle("报警触发", isOn: $alarmTriggered)
                }

                Section(header: Text("备注")) {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                }

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
                    Button("生成") {
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

                        Task.detached(priority: .userInitiated) {
                            do {
                                var photoNames: [String] = []
                                for (index, image) in photosToSave.enumerated() {
                                    let name = "\(baseName)_photo_\(String(format: "%02d", index + 1)).jpg"
                                    let url = docDir.appendingPathComponent(name)
                                    try writeJPEG(image, to: url)
                                    photoNames.append(name)
                                }

                                let signatureName = "\(baseName)_signature.png"
                                let signatureURL = docDir.appendingPathComponent(signatureName)
                                try writePNG(signatureToSave, to: signatureURL)

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
                                        photoFileNames: photoNames,
                                        signatureFileName: signatureName,
                                        signerName: signerSnapshot,
                                        confirmationChecked: confirmationSnapshot
                                    )

                                    isSavingAttachments = false
                                    appModel.saveInspectionReport(report)
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run {
                                    isSavingAttachments = false
                                    attachmentError = "附件保存失败：\(error.localizedDescription)"
                                }
                            }
                        }
                    }
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
}

private struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onComplete: (UIImage?) -> Void

        init(onComplete: @escaping (UIImage?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.originalImage] as? UIImage)
            onComplete(image)
        }
    }
}

private func writeJPEG(_ image: UIImage, to url: URL, compressionQuality: CGFloat = 0.85) throws {
    guard let data = image.jpegData(compressionQuality: compressionQuality) else {
        throw NSError(domain: "Leida", code: 1001, userInfo: [NSLocalizedDescriptionKey: "无法生成 JPEG 数据"])
    }
    try data.write(to: url, options: [.atomic])
}

private func writePNG(_ image: UIImage, to url: URL) throws {
    guard let data = image.pngData() else {
        throw NSError(domain: "Leida", code: 1002, userInfo: [NSLocalizedDescriptionKey: "无法生成 PNG 数据"])
    }
    try data.write(to: url, options: [.atomic])
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
    
    var body: some View {
        NavigationView {
            List {
                LibrarySection(
                    title: "巡检报告",
                    subtitle: ".json",
                    icon: "doc.text.fill",
                    files: reportFiles,
                    emptyHint: "暂无巡检报告"
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
                    emptyHint: "暂无空间扫描导出文件"
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
                    emptyHint: "暂无拍照建模生成的模型"
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
                    emptyHint: "暂无保存的环境地图"
                ) { url in
                    appModel.loadWorldMap(url: url)
                } onDelete: { urls in
                    delete(urls: urls)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("文件库")
            .onAppear { appModel.loadSavedFiles() }
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
                url.pathExtension == "worldmap" && url.lastPathComponent.hasPrefix("Map_")
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
                    Button {
                        onTap(url)
                    } label: {
                        FileCardRow(url: url)
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
                text = try String(contentsOf: url, encoding: .utf8)
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

// MARK: - 6. AR Logic (Core)
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var appModel: AppModel
    
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        print("🛑 ARViewContainer dismantleUIView - 正在释放相机...")
        uiView.session.pause()
        // 彻底清理 session
        uiView.session.delegate = nil
        coordinator.arView = nil
        print("✅ ARSession 已暂停并释放")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // 初始配置
        let config = ARWorldTrackingConfiguration()
        // 关键修改：优先使用 .meshWithClassification 以支持 AI 语义导出
        if appModel.isLiDAREnabled {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                config.sceneReconstruction = .meshWithClassification
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
        }
        
        config.planeDetection = [.horizontal, .vertical]

        arView.session.run(config)

        Task { @MainActor in
            if !appModel.isLiDAREnabled {
                appModel.lidarMeshStatus = "已关闭"
            } else if config.sceneReconstruction == [] {
                appModel.lidarMeshStatus = "设备不支持"
            } else {
                appModel.lidarMeshStatus = "已开启"
            }
        }
        
        arView.debugOptions = [.showSceneUnderstanding, .showFeaturePoints]
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
        // 如果当前没有配置（比如刚从暂停恢复），或者配置需要更新
        let currentConfig = uiView.session.configuration as? ARWorldTrackingConfiguration
        let config = currentConfig ?? ARWorldTrackingConfiguration()
        var shouldRun = currentConfig == nil // 如果是 nil，肯定要 run
        
        if appModel.isLiDAREnabled {
            // 开启 LiDAR 时，优先尝试开启带分类的 Mesh
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                if config.sceneReconstruction != .meshWithClassification {
                    config.sceneReconstruction = .meshWithClassification
                    shouldRun = true
                }
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                if config.sceneReconstruction != .mesh {
                    config.sceneReconstruction = .mesh
                    shouldRun = true
                }
            }
        } else {
            // 关闭 LiDAR
            if config.sceneReconstruction != [] {
                config.sceneReconstruction = []
                shouldRun = true
            }
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
        if config.planeDetection != [.horizontal, .vertical] {
            config.planeDetection = [.horizontal, .vertical]
            shouldRun = true
        }

        
        
        // 如果需要更新配置，或者 Session 之前被暂停了（通过检查 configuration 是否为 nil 并不完全准确，
        // 但如果 selectedTab == 0，我们希望它运行）。
        // 更稳健的做法是：只要在 Tab 0，就确保它在运行。
        if appModel.selectedTab == 0 {
             // 如果配置变了，或者之前暂停了（这里简化处理，只要配置变了就 run）
             if shouldRun {
                 uiView.session.run(config)
             } else {
                 // 如果配置没变，但可能处于暂停状态？
                 // ARSession 没有直接的 isPaused 属性，但重复调用 run(config) 开销很小且能恢复运行
                 // 为了防止频繁调用，我们可以加个状态检查，或者简单地依赖 SwiftUI 的 updateUIView 调用频率（通常不高）
                 // 这里为了修复切换回来的黑屏问题，我们强制 run 一次如果它没在跑
                 // 但为了避免每帧都 run，我们假设 shouldRun 逻辑覆盖了大部分情况。
                 // 补充：当从 Tab 2 切回 Tab 0，updateUIView 会被调用。
                 // 此时 session 可能被暂停了。我们需要恢复。
                 // 强制恢复：
                 uiView.session.run(config)
             }
        }
        
        // 动态响应网格分类显示 (AI 识别效果)
        // 只有在 AI 模式下才开启 SceneUnderstanding
        // 强制刷新 debugOptions，防止切换后丢失
        if appModel.isMeshColoringEnabled && appModel.coloringMode == .ai {
            if !uiView.debugOptions.contains(.showSceneUnderstanding) {
                uiView.debugOptions.insert(.showSceneUnderstanding)
            }
        } else {
            if uiView.debugOptions.contains(.showSceneUnderstanding) {
                uiView.debugOptions.remove(.showSceneUnderstanding)
            }
        }
        
        // 确保物理网格显示 (如果需要)
        // 如果用户觉得“格子没了”，可能是 .showSceneUnderstanding 没生效，或者需要 .showPhysics
        // 通常 .showSceneUnderstanding 会显示彩色网格。
        // 如果是在非 AI 模式，我们可能想显示白色网格？
        // 之前的代码只在 AI 模式下显示 SceneUnderstanding。
        // 如果是白模模式，我们应该显示 .showSceneUnderstanding 吗？
        // ARKit 的 .showSceneUnderstanding 会覆盖颜色。
        // 如果是白模，我们可能只需要 .showPhysics 或者 .showWorldOrigin (作为参考)
        // 但用户说“格子”，通常指 Mesh。
        // 如果 sceneReconstruction = .mesh，ARView 默认会自动渲染 Mesh 吗？
        // RealityKit 的 ARView 会自动渲染 MeshAnchor 对应的 Entity 吗？
        // 不，ARView 需要 debugOptions 才能看到 Mesh，除非我们自己添加了 Entity。
        // 我们的代码没有手动添加 MeshEntity，所以完全依赖 debugOptions。
        // 所以，如果不在 AI 模式，也应该显示 Mesh 线框。
        
        if appModel.coloringMode == .none {
             // 白模模式下，显示物理网格线框
             if !uiView.debugOptions.contains(.showPhysics) {
                 uiView.debugOptions.insert(.showPhysics)
             }
        } else {
             if uiView.debugOptions.contains(.showPhysics) {
                 uiView.debugOptions.remove(.showPhysics)
             }
        }
        
        // 响应地图加载 (重定位)
        if appModel.shouldResetSession, let mapURL = appModel.mapToLoad {
            loadAndReset(arView: uiView, mapURL: mapURL)
            
            // Reset flags immediately on MainActor to avoid loop
            DispatchQueue.main.async {
                appModel.shouldResetSession = false
                appModel.mapToLoad = nil
                appModel.isRelocalizing = true // 标记开始重定位
            }
        }
    }
    
    private func loadAndReset(arView: ARView, mapURL: URL) {
        do {
            let data = try Data(contentsOf: mapURL)
            if let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                let config = ARWorldTrackingConfiguration()
                config.initialWorldMap = worldMap
                
                // 同样在重定位时优先开启分类
                if appModel.isLiDAREnabled {
                    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                        config.sceneReconstruction = .meshWithClassification
                    } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                        config.sceneReconstruction = .mesh
                    }
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

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // 节流更新 UI
            if frame.timestamp.remainder(dividingBy: 0.5) < 0.05 {
                Task { @MainActor in
                    appModel.trackingState = describeState(frame.camera.trackingState)
                    
                    // 更新 XYZ 坐标
                    let transform = frame.camera.transform
                    appModel.currentPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    
                    // 检查重定位状态
                    if let map = session.currentFrame?.worldMappingStatus {
                        switch map {
                        case .mapped:
                            appModel.relocalizationStatus = "已定位 (Mapped)"
                            // 如果之前在重定位中，现在成功了，给个提示
                            if appModel.isRelocalizing {
                                appModel.isRelocalizing = false
                                appModel.alertMessage = "✅ 重定位成功！\n当前环境已与地图匹配。"
                                appModel.showAlert = true
                            }
                        case .extending: appModel.relocalizationStatus = "扩展中 (Extending)"
                        case .limited: appModel.relocalizationStatus = "定位受限 (Limited)"
                        case .notAvailable: appModel.relocalizationStatus = "不可用"
                        @unknown default: break
                        }
                    }
                }
            }

            
        }
        
        @objc func handleSaveMesh() {
            guard let arView = arView, let frame = arView.session.currentFrame else { return }
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            Task { @MainActor in
                appModel.exportMesh(anchors: meshAnchors)
            }
        }
        
        @objc func handleSaveMap() {
            guard let arView = arView else { return }
            Task { @MainActor in
                appModel.saveWorldMap(session: arView.session)
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


// MARK: - 7. Object Capture (手动拍照建模)
@available(iOS 17.0, *)
struct ObjectCaptureContainer: View {
    @ObservedObject var appModel: AppModel
    @State private var capturedImages: [URL] = []
    @State private var imagesDirectory: URL?
    @State private var showCamera = false
    @State private var totalPhotos = 0
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // 标题区域
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                    
                    Text("手动拍照建模")
                        .font(.title2)
                        .bold()
                    
                    Text("围绕物体拍摄 20-50 张照片\n系统将自动生成 3D 模型")
                        .multilineTextAlignment(.center)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                
                // 进度指示
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "photo.stack")
                        Text("已拍摄: \(totalPhotos) 张")
                            .font(.headline)
                    }
                    
                    // 进度条
                    ProgressView(value: min(Double(totalPhotos) / 30.0, 1.0))
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 40)
                    
                    if totalPhotos < 20 {
                        Text("建议至少拍摄 20 张")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("✅ 照片数量充足，可以开始建模")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding(.horizontal)
                
                Spacer()
                
                // 操作按钮
                VStack(spacing: 16) {
                    // 拍照按钮
                    Button(action: {
                        prepareAndShowCamera()
                    }) {
                        HStack {
                            Image(systemName: "camera.fill")
                            Text(totalPhotos == 0 ? "开始拍照" : "继续拍照")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.blue)
                        .cornerRadius(25)
                    }
                    .padding(.horizontal, 40)
                    
                    // 生成模型按钮
                    if totalPhotos >= 10 {
                        Button(action: {
                            startReconstruction()
                        }) {
                            HStack {
                                Image(systemName: "cube.fill")
                                Text("生成 3D 模型")
                            }
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.yellow)
                            .cornerRadius(25)
                        }
                        .padding(.horizontal, 40)
                    }
                    
                    // 重置按钮
                    if totalPhotos > 0 {
                        Button(action: {
                            resetCapture()
                        }) {
                            Text("清空重拍")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(.bottom, 50)
            }
            .navigationTitle("物体扫描")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showCamera) {
                ManualCaptureView(
                    imagesDirectory: $imagesDirectory,
                    totalPhotos: $totalPhotos,
                    onDismiss: { showCamera = false }
                )
            }
        }
    }
    
    func prepareAndShowCamera() {
        // 创建图片目录
        if imagesDirectory == nil {
            let id = UUID().uuidString
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docDir.appendingPathComponent("ManualCapture/\(id)/")
            
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                imagesDirectory = dir
            } catch {
                appModel.alertMessage = "创建目录失败: \(error.localizedDescription)"
                appModel.showAlert = true
                return
            }
        }
        
        showCamera = true
    }
    
    func resetCapture() {
        if let dir = imagesDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        capturedImages = []
        totalPhotos = 0
        imagesDirectory = nil
    }
    
    func startReconstruction() {
        guard let imagesDir = imagesDirectory, totalPhotos >= 10 else {
            appModel.alertMessage = "请至少拍摄 10 张照片"
            appModel.showAlert = true
            return
        }
        
        appModel.isProcessing = true
        appModel.processMessage = "正在进行 3D 重建...\n这可能需要几分钟"
        
        Task {
            do {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = "Model_\(Int(Date().timeIntervalSince1970)).usdz"
                let outputURL = docDir.appendingPathComponent(fileName)
                
                let session = try PhotogrammetrySession(input: imagesDir)
                try session.process(requests: [
                    .modelFile(url: outputURL, detail: .reduced)
                ])
                
                for try await output in session.outputs {
                    switch output {
                    case .processingComplete:
                        await MainActor.run {
                            appModel.isProcessing = false
                            appModel.alertMessage = "✅ 模型生成成功！\n已保存为: \(fileName)"
                            appModel.showAlert = true
                            appModel.loadSavedFiles()
                            resetCapture()
                        }
                    case .requestError(_, let error):
                        await MainActor.run {
                            appModel.isProcessing = false
                            appModel.alertMessage = "重建失败: \(error.localizedDescription)"
                            appModel.showAlert = true
                        }
                    case .requestProgress(_, let fraction):
                        await MainActor.run {
                            appModel.processMessage = "正在重建: \(Int(fraction * 100))%"
                        }
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    appModel.isProcessing = false
                    appModel.alertMessage = "初始化重建失败: \(error.localizedDescription)"
                    appModel.showAlert = true
                }
            }
        }
    }
}

// MARK: - 手动拍照界面 (使用 AVFoundation)
import AVFoundation

@available(iOS 17.0, *)
struct ManualCaptureView: View {
    @Binding var imagesDirectory: URL?
    @Binding var totalPhotos: Int
    let onDismiss: () -> Void
    
    @StateObject private var cameraModel = CameraModel()
    @State private var flashOn = false
    
    var body: some View {
        ZStack {
            // 相机预览
            CameraPreview(session: cameraModel.session)
                .ignoresSafeArea()
            
            // 控制层
            VStack {
                // 顶部栏
                HStack {
                    Button("完成") {
                        onDismiss()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    
                    Spacer()
                    
                    // 深度状态 + 拍照计数
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cameraModel.hasDepth ? .green : .orange)
                                .frame(width: 8, height: 8)
                            Text(cameraModel.hasDepth ? "LiDAR" : "无深度")
                                .font(.caption2)
                        }
                        Text("已拍 \(totalPhotos) 张")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5))
                    .cornerRadius(20)
                    
                    Spacer()
                    
                    Button(action: {
                        flashOn.toggle()
                        cameraModel.toggleFlash(flashOn)
                    }) {
                        Image(systemName: flashOn ? "bolt.fill" : "bolt.slash")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                
                Spacer()
                
                // 提示文字
                Text("围绕物体移动，每转 15° 拍一张")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.6))
                    .cornerRadius(8)
                
                // 底部拍照按钮
                HStack {
                    Spacer()
                    
                    Button(action: {
                        capturePhoto()
                    }) {
                        ZStack {
                            Circle()
                                .strokeBorder(.white, lineWidth: 4)
                                .frame(width: 70, height: 70)
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            cameraModel.checkPermissionsAndStart()
        }
        .onDisappear {
            cameraModel.stop()
        }
    }
    
    func capturePhoto() {
        guard let dir = imagesDirectory else { return }
        
        // 使用 HEIC 格式保存（保留深度数据）
        let fileName = "photo_\(totalPhotos + 1)_\(Int(Date().timeIntervalSince1970)).heic"
        let fileURL = dir.appendingPathComponent(fileName)
        
        cameraModel.capturePhoto(to: fileURL) { success in
            if success {
                totalPhotos += 1
            }
        }
    }
}

// MARK: - Camera Model (支持 LiDAR 深度)
@available(iOS 17.0, *)
class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var saveURL: URL?
    private var photoCompletion: ((Bool) -> Void)?
    @Published var hasDepth: Bool = false
    @Published var statusMessage: String = ""
    
    func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.main.async {
                        self.setupAndStart()
                    }
                }
            }
        default:
            break
        }
    }
    
    func setupAndStart() {
        session.beginConfiguration()
        
        // 🔑 关键：使用 LiDAR 深度相机（如果可用）
        var selectedDevice: AVCaptureDevice?
        
        // 优先尝试 LiDAR 深度相机
        if let lidarCamera = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            selectedDevice = lidarCamera
            print("✅ 使用 LiDAR 深度相机")
            DispatchQueue.main.async {
                self.hasDepth = true
                self.statusMessage = "LiDAR 深度相机已启用"
            }
        } else if let dualCamera = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            // 备选：双摄广角（支持立体深度）
            selectedDevice = dualCamera
            print("⚠️ 使用双摄广角相机（立体深度）")
            DispatchQueue.main.async {
                self.hasDepth = true
                self.statusMessage = "双摄深度已启用"
            }
        } else if let wideCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            // 最后备选：普通广角
            selectedDevice = wideCamera
            print("⚠️ 仅使用普通广角相机（无深度）")
            DispatchQueue.main.async {
                self.hasDepth = false
                self.statusMessage = "⚠️ 无深度数据"
            }
        }
        
        guard let camera = selectedDevice,
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("❌ 无法创建相机输入")
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            // 🔑 启用深度数据输出
            if photoOutput.isDepthDataDeliverySupported {
                photoOutput.isDepthDataDeliveryEnabled = true
                print("✅ 深度数据输出已启用")
            } else {
                print("⚠️ 当前配置不支持深度数据输出")
                DispatchQueue.main.async {
                    self.hasDepth = false
                    self.statusMessage = "⚠️ 深度输出不可用"
                }
            }
        }
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
    
    func stop() {
        session.stopRunning()
    }
    
    func toggleFlash(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }
    
    /// 拍照并保存带深度的 HEIC 文件
    func capturePhoto(to url: URL, completion: @escaping (Bool) -> Void) {
        saveURL = url
        photoCompletion = completion
        
        // 使用 HEVC 格式以保留深度数据（HEIF/HEIC 容器）
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        
        // 🔑 请求深度数据
        if photoOutput.isDepthDataDeliverySupported && photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            print("📸 拍照：请求深度数据")
        }
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let url = saveURL else { return }
        
        // 检查是否有深度数据
        if let _ = photo.depthData {
            print("✅ 照片包含深度数据")
        } else {
            print("⚠️ 照片无深度数据")
        }
        
        // 保存完整文件（包含深度元数据）
        if let data = photo.fileDataRepresentation() {
            do {
                try data.write(to: url)
                print("✅ 照片已保存: \(url.lastPathComponent)")
                DispatchQueue.main.async {
                    self.photoCompletion?(true)
                }
            } catch {
                print("❌ 保存失败: \(error)")
                DispatchQueue.main.async {
                    self.photoCompletion?(false)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.photoCompletion?(false)
            }
        }
    }
}

// MARK: - Camera Preview
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        DispatchQueue.main.async {
            previewLayer.frame = view.bounds
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = uiView.bounds
        }
    }
}
