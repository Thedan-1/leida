import SwiftUI
import AVFoundation
import Combine
import ARKit
import RealityKit

// 功率测试页面
struct PowerTestView: View {
    @State private var isTesting = false
    @State private var startTime: Date?
    @State private var elapsedTime: TimeInterval = 0
    @State private var checkSum: Int = 0 
    
    // Timer for UI updates
    let timerPublisher = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // 背景运行AR Session以消耗功率 (隐藏显示但实际在运行)
            if isTesting {
                ARPowerDrainView()
                    .opacity(0.01) // 几乎不可见，但必须在视图层级中才能运行
                    .allowsHitTesting(false)
            }
            
            VStack(spacing: 30) {
                Text("最大功率耗电测试")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top, 40)
                
                VStack {
                    Text(timeString(from: elapsedTime))
                        .font(.system(size: 64, design: .monospaced))
                        .foregroundColor(isTesting ? .red : .primary)
                    
                    Text("运行时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                
                VStack(spacing: 20) {
                    PowerStatusRow(icon: "flashlight.on.fill", title: "闪光灯常亮", isActive: isTesting, activeText: "ON", inactiveText: "OFF")
                    PowerStatusRow(icon: "arkit", title: "LiDAR 空间扫描", isActive: isTesting, activeText: "ACTIVE", inactiveText: "OFF")
                    PowerStatusRow(icon: "cpu.fill", title: "CPU 高负载运算", isActive: isTesting, activeText: "ACTIVE", inactiveText: "IDLE")
                    PowerStatusRow(icon: "sun.max.fill", title: "屏幕常亮无休眠", isActive: isTesting, activeText: "ON", inactiveText: "AUTO")
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)
                
                if isTesting {
                    Text("⚠️ 注意：此模式会迅速消耗电量并产生热量")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top)
                }
                
                Spacer()
                
                Button(action: toggleTest) {
                    HStack {
                        Image(systemName: isTesting ? "stop.fill" : "play.fill")
                        Text(isTesting ? "停止测试" : "开始测试")
                    }
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isTesting ? Color.red : Color.green)
                    .cornerRadius(16)
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .onDisappear {
            stopTest()
        }
        .onReceive(timerPublisher) { _ in
            if isTesting, let start = startTime {
                elapsedTime = Date().timeIntervalSince(start)
                burnCPU()
            }
        }
    }
    
    func toggleTest() {
        if isTesting {
            stopTest()
        } else {
            startTest()
        }
    }
    
    func startTest() {
        isTesting = true // 这会触发 ARPowerDrainView 加载
        startTime = Date()
        elapsedTime = 0
        UIApplication.shared.isIdleTimerDisabled = true
        toggleTorch(on: true)
    }
    
    func stopTest() {
        isTesting = false // 这会移除 ARPowerDrainView
        UIApplication.shared.isIdleTimerDisabled = false
        toggleTorch(on: false)
    }
    
    func burnCPU() {
        // High frequency calculation loop
        // 增加负载：多线程并行运算
        for _ in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async {
                var val = 0
                for i in 0..<100000 {
                    val = val &+ (i * i) 
                }
            }
        }
    }
    
    func toggleTorch(on: Bool) {
        let device = AVCaptureDevice.default(for: .video)
        if let device = device, device.hasTorch {
            do {
                try device.lockForConfiguration()
                if on {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                print("Torch error: \(error)")
            }
        }
    }
    
    func timeString(from interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        let tenths = Int((interval * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// 专门用于耗电的AR视图
struct ARPowerDrainView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // 配置最高性能消耗的会话
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh // 开启LiDAR网格生成 (高功耗)
        }
        config.frameSemantics = .sceneDepth // 开启深度图 (高功耗)
        
        arView.session.run(config)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

struct PowerStatusRow: View {
    let icon: String
    let title: String
    let isActive: Bool
    let activeText: String
    let inactiveText: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
            Text(title)
            Spacer()
            if isActive {
                Text(activeText).bold().foregroundColor(.red)
            } else {
                Text(inactiveText).foregroundColor(.secondary)
            }
        }
    }
}
