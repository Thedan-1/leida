import SwiftUI
import ARKit
import RealityKit

// MARK: - 导轨安装模式（手机底部 2.5cm 插槽，UI 集中在顶部）
struct RadarMountedView: View {

    @StateObject private var vm: PrecisionTestViewModel
    @ObservedObject var appModel: AppModel

    // 弹窗状态
    @State private var showResetConfirm = false

    // 底部插槽遮挡高度估算（2.5cm ≈ 95pt，保守取 100pt）
    // 用 safeAreaInsets.bottom 之外再加上物理插槽高度
    private let slotExtraPt: CGFloat = 100

    init(session: ARSession, appModel: AppModel) {
        _vm = StateObject(
            wrappedValue: PrecisionTestViewModel(mode: .dynamicHand, session: session)
        )
        self.appModel = appModel
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {

                // ── 全屏背景：摄像头预览 or 省电纯黑 ──
                if vm.isPreviewVisible {
                    PrecisionARViewContainer(session: vm.arSession)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                // ── 顶部 HUD（所有控件） ──
                VStack(spacing: 0) {
                    topHUD
                        .padding(.top, geo.safeAreaInsets.top > 0 ? 4 : 16)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea(edges: .bottom) // 底部插槽区域 SwiftUI 不做布局
        .onAppear {
            vm.startAR()
            UIApplication.shared.isIdleTimerDisabled = true  // 常亮
        }
        .onDisappear {
            vm.stopAR()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 重置地图确认弹窗
        .alert("重置 AR 地图", isPresented: $showResetConfirm) {
            Button("确认重置", role: .destructive) {
                vm.resetWorldMap()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空当前 AR 地图并重新追踪。\n已录制的 CSV 数据不受影响。")
        }
    }

    // MARK: - 顶部 HUD
    private var topHUD: some View {
        VStack(spacing: 6) {

            // ── 第一行：TCP 状态 | 录制状态 | 预览开关 ──
            HStack(spacing: 8) {
                // TCP 指示
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.tcpEnabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(vm.tcpEnabled ? "TCP" : "TCP 关")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                // 录制状态
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.isRecording ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(vm.isRecording ? "录制中 \(vm.recordCount) 行" : "待机")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vm.isRecording ? .red : .white.opacity(0.7))
                }

                Spacer()

                // 预览开关（省 CPU）
                Button(action: { vm.togglePreview() }) {
                    HStack(spacing: 3) {
                        Image(systemName: vm.isPreviewVisible ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 13))
                        Text(vm.isPreviewVisible ? "预览" : "省电")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(vm.isPreviewVisible ? .blue : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 14)

            // ── 状态消息 ──
            Text(vm.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 14)

            Divider().background(Color.white.opacity(0.25))

            // ── 坐标显示 ──
            HStack(spacing: 0) {
                coordCell(label: "X (m)", value: String(format: "%.3f", vm.posX), color: .white)
                coordCell(label: "Y (m)", value: String(format: "%.3f", vm.posY), color: .white)
                coordCell(label: "Z (m)", value: String(format: "%.3f", vm.posZ), color: .white)
            }

            // ── 姿态显示 ──
            HStack(spacing: 0) {
                coordCell(label: "Roll °", value: String(format: "%.1f", vm.roll),   color: .cyan)
                coordCell(label: "Pitch °", value: String(format: "%.1f", vm.pitch), color: .cyan)
                coordCell(label: "Yaw °",  value: String(format: "%.1f", vm.yaw),   color: .cyan)
            }

            Divider().background(Color.white.opacity(0.25))

            // ── 操作按钮 ──
            HStack(spacing: 10) {
                // 开始录制
                Button(action: { vm.startRecording() }) {
                    VStack(spacing: 3) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 22))
                        Text("开始")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(vm.isRecording
                        ? Color.gray.opacity(0.35)
                        : Color.green.opacity(0.85))
                    .cornerRadius(12)
                }
                .disabled(vm.isRecording)

                // 停止录制
                Button(action: { vm.stopRecording() }) {
                    VStack(spacing: 3) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                        Text("停止")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(vm.isRecording
                        ? Color.red.opacity(0.85)
                        : Color.gray.opacity(0.35))
                    .cornerRadius(12)
                }
                .disabled(!vm.isRecording)

                // 重置地图（带确认）
                Button(action: { showResetConfirm = true }) {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.system(size: 22))
                        Text("重置地图")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color.orange.opacity(0.8))
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            // ── 最后保存的文件名 ──
            if !vm.lastSavedFile.isEmpty {
                Text("💾 \(vm.lastSavedFile)")
                    .font(.system(size: 10))
                    .foregroundColor(.green.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(18)
        .padding(.horizontal, 10)
    }

    // MARK: - Helper
    private func coordCell(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
