import SwiftUI
import ARKit
import RealityKit
import Combine
import simd
import Darwin

// MARK: - 精度测试数据行
struct PositionRecord {
    let source: String
    let event: String
    let timestampUnix: Double
    let tRel: Double
    let x: Double
    let y: Double
    let z: Double
    let qx: Double
    let qy: Double
    let qz: Double
    let qw: Double
    let roll: Double
    let pitch: Double
    let yaw: Double

    // frame: 行号（由 saveCSV 传入），与 quat.csv 对齐
    func csvRow(frame: Int) -> String {
        // 前9列与 quat.csv 完全一致：frame,time_abs,x,y,z,qx,qy,qz,qw
        // 后6列为手机特有字段，放在末尾
        return "\(frame),\(String(format: "%.6f", tRel)),\(String(format: "%.6f", x)),\(String(format: "%.6f", y)),\(String(format: "%.6f", z)),\(String(format: "%.6f", qx)),\(String(format: "%.6f", qy)),\(String(format: "%.6f", qz)),\(String(format: "%.6f", qw)),\(source),\(event),\(String(format: "%.6f", timestampUnix)),\(String(format: "%.4f", roll)),\(String(format: "%.4f", pitch)),\(String(format: "%.4f", yaw))"
    }
}

// MARK: - 精度测试模式
enum PrecisionMode {
    case staticRail   // 慢速静态：1920×1440@30fps，30Hz，有摄像头预览
    case staticBlind  // 慢速静态：1920×1440@30fps，30Hz，无摄像头预览（省热）
    case dynamicHand  // 精确模式：1920×1080@60fps，30Hz，可切换预览，支持地图保存

    var displayTitle: String {
        switch self {
        case .staticRail:  return "慢速静态 · 30fps@30Hz · 预览开"
        case .staticBlind: return "慢速静态 · 30fps@30Hz · 无预览"
        case .dynamicHand: return "精确模式 · 60fps@30Hz"
        }
    }
    var csvPrefix: String {
        switch self {
        case .staticRail:  return "Position_Static"
        case .staticBlind: return "Position_Static"
        case .dynamicHand: return "Position_Dynamic"
        }
    }
    var targetFPS: Int {
        switch self {
        case .staticRail:  return 30
        case .staticBlind: return 30
        case .dynamicHand: return 60
        }
    }
    var frameInterval: Double {
        switch self {
        case .staticRail:  return 1.0 / 30.0
        case .staticBlind: return 1.0 / 30.0
        case .dynamicHand: return 1.0 / 30.0  // 60fps 摄像头，每2帧采样=30Hz
        }
    }
    /// 默认是否显示摄像头预览
    var defaultShowPreview: Bool {
        switch self {
        case .staticRail:  return true
        case .staticBlind: return false
        case .dynamicHand: return true
        }
    }
    /// 是否支持地图功能（重置/保存 AR WorldMap）
    var supportsMapFeatures: Bool { true }  // 所有模式都支持地图保存/载入/重置
}

// MARK: - 精度测试 ViewModel
@MainActor
class PrecisionTestViewModel: NSObject, ObservableObject {
    let mode: PrecisionMode

    // --- 显示 ---
    @Published var posX: Float = 0
    @Published var posY: Float = 0
    @Published var posZ: Float = 0
    @Published var roll: Float = 0
    @Published var pitch: Float = 0
    @Published var yaw: Float = 0
    @Published var isRecording: Bool = false
    @Published var recordCount: Int = 0
    @Published var statusMessage: String = "等待 GO 指令..."
    @Published var lastSavedFile: String = ""
    @Published var tcpEnabled: Bool = true
    @Published var isPreviewVisible: Bool = true
    @Published var worldMapStatus: String = ""
    @Published var showMapPicker: Bool = false

    // --- 录制状态 ---
    private var records: [PositionRecord] = []
    private var t0Unix: Double = 0          // wall clock at GO
    private var t0Frame: Double = 0         // ARKit frame.timestamp at first record
    private var originPosition: SIMD3<Float>? = nil
    private var pendingOriginReset: Bool = false  // 重置地图后等追踪恢复再设原点

    // --- ARKit ---
    var arSession: ARSession
    private var lastFrameTimestamp: Double = 0
    // frameInterval 由 mode 决定，与视频帧率保持整除关系，不节流不漂移
    private var frameInterval: Double { mode.frameInterval }

    // --- TCP 服务端 (POSIX socket) ---
    private var tcpListenSock: Int32 = -1
    private var tcpQueue = DispatchQueue(label: "tcp.server", qos: .utility)
    private var tcpSendQueue = DispatchQueue(label: "tcp.send", qos: .userInitiated)
    private var tcpRunning = false
    private let tcpPortNum: UInt16 = 9999
    private let pcUploadPort: UInt16 = 10001

    init(mode: PrecisionMode = .staticRail, session: ARSession) {
        self.mode = mode
        self.arSession = session
        super.init()
        isPreviewVisible = mode.defaultShowPreview
    }

    // MARK: - ARKit 启动
    private func makeARConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        config.isAutoFocusEnabled = true
        config.worldAlignment = .gravity
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let targetFPS = mode.targetFPS
        let chosen = formats
            .filter { Int($0.framesPerSecond) == targetFPS }
            .max(by: { a, b in
                a.imageResolution.width * a.imageResolution.height <
                b.imageResolution.width * b.imageResolution.height
            })
            ?? formats.max(by: { a, b in
                a.imageResolution.width * a.imageResolution.height <
                b.imageResolution.width * b.imageResolution.height
            })
        if let fmt = chosen { config.videoFormat = fmt }
        return config
    }

    func startAR() {
        // 先设当前模式为 delegate，再 run（对同一 session 重新配置不会重置地图）
        arSession.delegate = self
        arSession.run(makeARConfig(), options: [])
        startTCPServer()
    }

    func stopAR() {
        arSession.pause()
        stopTCPServer()
    }

    // MARK: - 预览切换
    func togglePreview() {
        isPreviewVisible.toggle()
    }

    // MARK: - 重置 AR 地图
    func resetWorldMap() {
        pendingOriginReset = true   // 等 ARKit 追踪恢复后再设原点
        originPosition = nil
        posX = 0; posY = 0; posZ = 0
        arSession.run(makeARConfig(), options: [.resetTracking, .removeExistingAnchors])
        worldMapStatus = ""
        statusMessage = "🔄 AR地图已重置，等待重新定位..."
    }

    // MARK: - 保存 AR WorldMap
    func saveWorldMap() {
        worldMapStatus = "保存中..."
        arSession.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self = self else { return }
            if let error = error {
                Task { @MainActor in
                    self.worldMapStatus = "保存失败: \(error.localizedDescription)"
                }
                return
            }
            guard let map = worldMap else {
                Task { @MainActor in self.worldMapStatus = "地图数据为空" }
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let filename = "WorldMap_\(formatter.string(from: Date())).worldmap"
                let url = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                Task { @MainActor in
                    self.worldMapStatus = "✅ 已保存"
                    self.statusMessage = "💾 地图已保存: \(filename)"
                }
            } catch {
                Task { @MainActor in
                    self.worldMapStatus = "保存失败: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 载入 AR WorldMap
    func loadWorldMap(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            worldMapStatus = "无权限访问文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                worldMapStatus = "格式错误"
                return
            }
            let config = makeARConfig()
            config.initialWorldMap = worldMap
            // 不 resetTracking，让 ARKit 在当前画面中重定位到已有地图
            arSession.run(config, options: [])
            originPosition = nil
            worldMapStatus = "🗺️ 载入中"
            statusMessage = "🗺️ 地图已载入，正在重定位..."
        } catch {
            worldMapStatus = "载入失败"
            statusMessage = "地图载入失败: \(error.localizedDescription)"
        }
    }

    // MARK: - TCP 开关
    func toggleTCP() {
        if tcpEnabled {
            stopTCPServer()
            tcpEnabled = false
            statusMessage = "TCP 已关闭"
        } else {
            tcpEnabled = true
            startTCPServer()
        }
    }

    // MARK: - 重置原点
    func resetOrigin() {
        originPosition = nil
        posX = 0; posY = 0; posZ = 0
        statusMessage = "📍 原点已重置"
    }

    // MARK: - TCP 服务端 (POSIX)
    private func startTCPServer() {
        tcpListenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard tcpListenSock >= 0 else {
            statusMessage = "TCP socket 创建失败"
            return
        }
        var on: Int32 = 1
        setsockopt(tcpListenSock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // accept() 超时，方便退出时检查 tcpRunning
        var tv = timeval()
        tv.tv_sec = 1
        tv.tv_usec = 0
        setsockopt(tcpListenSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = tcpPortNum.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(tcpListenSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            statusMessage = "TCP bind 失败 (端口 \(tcpPortNum) 被占用?)"
            close(tcpListenSock); tcpListenSock = -1
            return
        }
        guard listen(tcpListenSock, 1) == 0 else {
            statusMessage = "TCP listen 失败"
            close(tcpListenSock); tcpListenSock = -1
            return
        }
        tcpRunning = true
        let sock = tcpListenSock
        tcpQueue.async { [weak self] in
            self?.tcpAcceptLoop(listenSock: sock)
        }
        statusMessage = "TCP 监听中 (端口 \(tcpPortNum))..."
    }

    private func tcpAcceptLoop(listenSock: Int32) {
        while tcpRunning {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenSock, $0, &clientLen)
                }
            }
            guard clientSock >= 0 else { continue }  // EAGAIN = timeout, loop

            // recv 超时，防止 tcpHandleConn 永久阻塞
            var tv = timeval()
            tv.tv_sec = 1
            tv.tv_usec = 0
            setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // 提取 PC IP 用于文件上传
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = clientAddr.sin_addr
            inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let pcIP = String(cString: ipBuf)

            Task { @MainActor [weak self] in
                self?.statusMessage = "TCP 已连接: \(pcIP)"
            }
            tcpHandleConn(sock: clientSock, pcIP: pcIP)
            close(clientSock)
            Task { @MainActor [weak self] in
                guard let self = self, self.tcpRunning else { return }
                self.statusMessage = "TCP 监听中 (端口 \(self.tcpPortNum))..."
            }
        }
    }

    private func tcpHandleConn(sock: Int32, pcIP: String) {
        while tcpRunning {
            guard let line = tcpRecvLine(sock: sock) else { break }
            let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { continue }
            let ip = pcIP
            Task { @MainActor [weak self] in
                self?.handleTCPCommand(cmd, connSock: sock, pcIP: ip)
            }
        }
    }

    private func tcpRecvLine(sock: Int32) -> String? {
        var buf = ""
        while true {
            var ch: UInt8 = 0
            let n = recv(sock, &ch, 1, 0)
            if n <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if tcpRunning { continue }
                }
                return nil
            }
            if ch == UInt8(ascii: "\n") { return buf }
            buf.append(Character(Unicode.Scalar(ch)))
        }
    }

    private func stopTCPServer() {
        tcpRunning = false
        if tcpListenSock >= 0 { close(tcpListenSock); tcpListenSock = -1 }
    }

    private func tcpSend(_ text: String, to sock: Int32) {
        guard sock >= 0 else { return }
        let data = Array((text + "\n").utf8)
        _ = send(sock, data, data.count, 0)
    }

    // STOP 后把 CSV 上传到 PC（PC 端口 10001）
    /// 上传完成后在 doneConnSock（命令通道 9999）发送 "DONE\n"，让 PC 不必死等 30 秒
    private func uploadFileToPC(fileURL: URL, pcIP: String, doneConnSock: Int32 = -1) {
        guard let data = try? Data(contentsOf: fileURL) else {
            Task { @MainActor [weak self] in self?.statusMessage = "⚠️ 上传失败：读取文件失败" }
            return
        }
        let uploadSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard uploadSock >= 0 else { return }
        defer { close(uploadSock) }

        var serverAddr = sockaddr_in()
        serverAddr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port   = pcUploadPort.bigEndian
        var inAddr = in_addr()
        pcIP.withCString { inet_pton(AF_INET, $0, &inAddr) }
        serverAddr.sin_addr = inAddr

        let connectResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(uploadSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Task { @MainActor [weak self] in self?.statusMessage = "⚠️ 上传失败：无法连接 PC \(pcIP):10001" }
            return
        }

        // 协议：filename\n + size\n + payload
        let filename = fileURL.lastPathComponent
        let nameBytes = Array((filename + "\n").utf8)
        send(uploadSock, nameBytes, nameBytes.count, 0)
        let sizeBytes = Array(("\(data.count)\n").utf8)
        send(uploadSock, sizeBytes, sizeBytes.count, 0)

        var sent = 0
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < data.count {
                let n = send(uploadSock, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        let total = data.count
        let fname = filename
        Task { @MainActor [weak self] in
            if sent == total {
                self?.statusMessage = "✅ 已上传: \(fname) (\(sent) 字节)"
            } else {
                self?.statusMessage = "⚠️ 上传不完整: \(sent)/\(total)"
            }
        }
        // 通知 PC 上传完毕，使其无需死等
        if doneConnSock >= 0 {
            tcpSend("DONE", to: doneConnSock)
        }
    }

    private func handleTCPCommand(_ cmd: String, connSock: Int32, pcIP: String) {
        switch cmd {
        case "PING":
            let s = connSock
            tcpSendQueue.async { [weak self] in self?.tcpSend("PONG", to: s) }
        case "TIMESYNC":
            // NTP 式时钟同步：PC 记录 t1，发 TIMESYNC；iPhone 立即回复自己的 Unix 时间 t2
            // PC 收到后记录 t3，算 offset = t2 - (t1+t3)/2
            let t2 = Date().timeIntervalSince1970
            let s = connSock
            tcpSendQueue.async { [weak self] in
                self?.tcpSend(String(format: "TIMESYNC:%.6f", t2), to: s)
            }
        case "GO":
            startRecording(connSock: connSock)
        case "STOP":
            stopRecording(connSock: connSock, pcIP: pcIP)
        default:
            break
        }
    }

    // MARK: - GO / STOP
    func startRecording(connSock: Int32 = -1) {
        guard !isRecording else { return }
        records = []
        t0Unix = Date().timeIntervalSince1970
        t0Frame = 0
        originPosition = nil
        isRecording = true
        recordCount = 0
        statusMessage = "🔴 录制中..."
        UIApplication.shared.isIdleTimerDisabled = true  // 录制期间禁止熄屏

        let goRow = PositionRecord(
            source: "phone", event: "GO_START",
            timestampUnix: t0Unix, tRel: 0,
            x: Double(posX), y: Double(posY), z: Double(posZ),
            qx: 0, qy: 0, qz: 0, qw: 1,
            roll: Double(roll), pitch: Double(pitch), yaw: Double(yaw)
        )
        records.append(goRow)

        let reply = "RECORDING:\(String(format: "%.6f", t0Unix))"
        if connSock >= 0 {
            let s = connSock
            tcpSendQueue.async { [weak self] in self?.tcpSend(reply, to: s) }
        }
    }

    func stopRecording(connSock: Int32 = -1, pcIP: String = "") {
        guard isRecording else { return }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false  // 录制结束恢复自动熄屏

        let nowUnix = Date().timeIntervalSince1970
        let tRel = t0Frame > 0 ? nowUnix - t0Unix : 0
        let stopRow = PositionRecord(
            source: "phone", event: "STOP_RECV",
            timestampUnix: nowUnix, tRel: tRel,
            x: Double(posX), y: Double(posY), z: Double(posZ),
            qx: 0, qy: 0, qz: 0, qw: 1,
            roll: Double(roll), pitch: Double(pitch), yaw: Double(yaw)
        )
        records.append(stopRow)

        let count = records.count
        let reply = "STOPPED:\(count)"
        if connSock >= 0 {
            let s = connSock
            tcpSendQueue.async { [weak self] in self?.tcpSend(reply, to: s) }
        }

        let savedURL = saveCSV()
        // STOP 后自动上传 CSV 到 PC（端口 10001），完成后在命令 socket 发 DONE
        if let url = savedURL, !pcIP.isEmpty {
            let ip = pcIP
            let s = connSock
            tcpSendQueue.async { [weak self] in
                self?.uploadFileToPC(fileURL: url, pcIP: ip, doneConnSock: s)
            }
        }
        statusMessage = "✅ 已保存 \(count) 行，等待 GO..."
    }

    // MARK: - CSV 保存
    @discardableResult
    private func saveCSV() -> URL? {
        // UTF-8 BOM（EF BB BF）：Windows Excel 打开时能正确识别编码，第一行显示为表头
        let bom = "\u{FEFF}"
        // 前9列与 quat.csv 对齐，后6列为手机特有字段
        let header = "frame,time_abs,x_m,y_m,z_m,qx,qy,qz,qw,source,event,timestamp_unix_s,roll_deg,pitch_deg,yaw_deg\n"
        let rows = records.enumerated().map { idx, rec in rec.csvRow(frame: idx) }.joined(separator: "\n")
        let content = bom + header + rows + "\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "\(mode.csvPrefix)_\(formatter.string(from: Date())).csv"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedFile = fileName
            return fileURL
        } catch {
            statusMessage = "保存失败: \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - ARSessionDelegate
extension PrecisionTestViewModel: ARSessionDelegate {
    // 追踪状态变化：重置地图后等 normal 再设新原点
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard case .normal = camera.trackingState else { return }
        Task { @MainActor [weak self] in
            guard let self = self, self.pendingOriginReset else { return }
            self.pendingOriginReset = false
            self.originPosition = nil   // 让下一帧的真实位置成为新原点
            self.statusMessage = "✅ AR地图重置完成，原点已归零"
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let frameTS = frame.timestamp
        Task { @MainActor in
            // 帧率限制（非录制时也做节流，保持 lastFrameTimestamp 处于正常节奏）
            guard frameTS - lastFrameTimestamp >= frameInterval - 0.002 else { return }
            lastFrameTimestamp = frameTS

            // 位置和姿态
            let transform = frame.camera.transform
            let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let eulerAngles = frame.camera.eulerAngles

            let r = Double(eulerAngles.z * 180 / .pi)
            let p = Double(eulerAngles.x * 180 / .pi)
            let yw = Double(eulerAngles.y * 180 / .pi)

            // 始终维护 originPosition（非录制时也随 reset 归零）
            // pendingOriginReset 为 true 时：锁住原点不被帧更新，等追踪稳定后再设
            if !pendingOriginReset {
                if originPosition == nil { originPosition = pos }
            }
            let relPos = originPosition.map { pos - $0 } ?? SIMD3<Float>(0, 0, 0)

            // HUD 显示相对坐标
            posX = relPos.x
            posY = relPos.y
            posZ = relPos.z
            roll = Float(r)
            pitch = Float(p)
            yaw = Float(yw)

            // 记录数据
            guard isRecording else { return }

            // t0Frame 在第一个通过节流的录制帧时初始化，确保第一帧 tRel = 0
            if t0Frame == 0 {
                t0Frame = frameTS
            }

            let nowUnix = t0Unix + (frameTS - t0Frame)
            let tRel = frameTS - t0Frame

            // 四元数
            let q = simd_quaternion(transform)

            let rec = PositionRecord(
                source: "phone", event: "",
                timestampUnix: nowUnix, tRel: tRel,
                x: Double(relPos.x), y: Double(relPos.y), z: Double(relPos.z),
                qx: Double(q.vector.x), qy: Double(q.vector.y),
                qz: Double(q.vector.z), qw: Double(q.vector.w),
                roll: r, pitch: p, yaw: yw
            )
            records.append(rec)
            recordCount = records.count
        }
    }
}

// MARK: - 精度测试 View
struct PrecisionTestView: View {
    @StateObject private var vm: PrecisionTestViewModel
    @ObservedObject var appModel: AppModel

    init(mode: PrecisionMode = .staticRail, session: ARSession, appModel: AppModel) {
        _vm = StateObject(wrappedValue: PrecisionTestViewModel(mode: mode, session: session))
        self.appModel = appModel
    }

    var body: some View {
        ZStack {
            // ARKit 摄像头背景（预览关闭时用纯黑背景，降低 GPU 热负荷）
            if vm.isPreviewVisible {
                PrecisionARViewContainer(session: vm.arSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // 半透明 HUD 覆盖层
            VStack {
                // 坐标显示框
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.mode.displayTitle)
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
                    Text("📍 位置 (m)")
                        .font(.caption).foregroundColor(.yellow).bold()
                    HStack(spacing: 16) {
                        coordLabel(title: "X(左右)", value: vm.posX)
                        coordLabel(title: "Y(上下)", value: vm.posY)
                        coordLabel(title: "Z(前后)", value: vm.posZ)
                    }

                    Divider().background(Color.white.opacity(0.3))

                    Text("🦴 姿态 (°)")
                        .font(.caption).foregroundColor(.cyan).bold()
                    HStack(spacing: 16) {
                        angleLabel(title: "Roll", value: vm.roll)
                        angleLabel(title: "Pitch", value: vm.pitch)
                        angleLabel(title: "Yaw", value: vm.yaw)
                    }

                    Divider().background(Color.white.opacity(0.3))

                    HStack {
                        Circle()
                            .fill(vm.isRecording ? Color.red : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(vm.isRecording ? "录制中 \(vm.recordCount) 行" : "未录制")
                            .font(.caption).foregroundColor(.white)
                        Spacer()
                        // UDP 开关
                        Button(action: { vm.toggleTCP() }) {
                            Label(vm.tcpEnabled ? "TCP 开" : "TCP 关",
                                  systemImage: vm.tcpEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                .font(.caption2.bold())
                                .foregroundColor(vm.tcpEnabled ? .green : .gray)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text(vm.statusMessage)
                            .font(.caption2).foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer()
                    }

                    if !vm.lastSavedFile.isEmpty {
                        Text("💾 \(vm.lastSavedFile)")
                            .font(.caption2).foregroundColor(.green)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.65))
                .cornerRadius(14)
                .padding(.horizontal, 16)
                .padding(.top, 60)

                Spacer()

                // 底部控制栏
                HStack(spacing: 0) {
                    // 开始录制
                    Button(action: { vm.startRecording() }) {
                        VStack(spacing: 4) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 22))
                            Text("开始")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(vm.isRecording ? .gray : .white)
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(vm.isRecording ? Color.white.opacity(0.08) : Color.green.opacity(0.85))
                    }
                    .disabled(vm.isRecording)

                    Divider().background(Color.white.opacity(0.2)).frame(width: 1, height: 50)

                    // 结束录制
                    Button(action: { vm.stopRecording() }) {
                        VStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 22))
                            Text("结束")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(vm.isRecording ? .white : .gray)
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(vm.isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.08))
                    }
                    .disabled(!vm.isRecording)

                    Divider().background(Color.white.opacity(0.2)).frame(width: 1, height: 50)

                    // 重置原点
                    Button(action: { vm.resetOrigin() }) {
                        VStack(spacing: 4) {
                            Image(systemName: "scope")
                                .font(.system(size: 22))
                            Text("归零")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(Color.orange.opacity(0.75))
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.bottom, vm.mode.supportsMapFeatures ? 8 : 30)

                // 地图功能栏（仅精确模式显示）—— 2×2 网格
                if vm.mode.supportsMapFeatures {
                    VStack(spacing: 1) {
                        HStack(spacing: 0) {
                            // 预览开关
                            Button(action: { vm.togglePreview() }) {
                                mapButton(
                                    icon: vm.isPreviewVisible ? "eye.fill" : "eye.slash.fill",
                                    label: vm.isPreviewVisible ? "预览 开" : "预览 关",
                                    color: vm.isPreviewVisible ? Color.blue.opacity(0.7) : Color.white.opacity(0.1)
                                )
                            }
                            Divider().background(Color.white.opacity(0.2)).frame(width: 1, height: 40)
                            // 重置地图
                            Button(action: { vm.resetWorldMap() }) {
                                mapButton(icon: "arrow.counterclockwise.circle", label: "重置地图", color: Color.red.opacity(0.55))
                            }
                        }
                        Divider().background(Color.white.opacity(0.15)).frame(height: 1)
                        HStack(spacing: 0) {
                            // 载入地图
                            Button(action: { vm.showMapPicker = true }) {
                                mapButton(icon: "square.and.arrow.up.fill", label: "载入地图", color: Color.teal.opacity(0.65))
                            }
                            Divider().background(Color.white.opacity(0.2)).frame(width: 1, height: 40)
                            // 保存地图
                            Button(action: { vm.saveWorldMap() }) {
                                mapButton(
                                    icon: "square.and.arrow.down.fill",
                                    label: vm.worldMapStatus.isEmpty ? "保存地图" : vm.worldMapStatus,
                                    color: Color.purple.opacity(0.7)
                                )
                            }
                        }
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }

            }
        }
        .navigationTitle("精度测试")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.startAR() }
        .onDisappear { vm.stopAR() }
        .sheet(isPresented: $vm.showMapPicker) {
            MapPickerSheet(appModel: appModel) { url in
                vm.loadWorldMap(from: url)
                vm.showMapPicker = false
            }
        }
    }

    private func mapButton(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18))
            Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(color)
    }

    private func coordLabel(title: String, value: Float) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
            Text(String(format: "%.2f", value))
                .font(.system(size: 17, design: .monospaced)).foregroundColor(.white).bold()
        }
    }

    private func angleLabel(title: String, value: Float) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
            Text(String(format: "%.2f°", value))
                .font(.system(size: 17, design: .monospaced)).foregroundColor(.cyan).bold()
        }
    }
}

// MARK: - ARKit 摄像头背景 View
struct PrecisionARViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = session
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        // session 由 ViewModel 管理，此处不操作
    }
}

// MARK: - 地图选择 Sheet
struct MapPickerSheet: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSelect: (URL) -> Void

    private var mapFiles: [URL] {
        appModel.savedFiles.filter {
            $0.pathExtension == "worldmap" || $0.pathExtension == "arworldmap"
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if mapFiles.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "map").font(.system(size: 48)).foregroundColor(.gray)
                        Text("暂无保存的地图").foregroundColor(.gray)
                        Text("请先在精确模式或空间扫描中保存地图")
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(mapFiles, id: \.self) { url in
                        Button(action: { onSelect(url) }) {
                            HStack {
                                Image(systemName: "map.fill").foregroundColor(.teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.body).foregroundColor(.primary)
                                    if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                                        Text(date, style: .date)
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { appModel.loadSavedFiles() }
        }
    }
}
