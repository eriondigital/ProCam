import SwiftUI

struct CameraScreen: View {
    @StateObject private var cam = CameraController()
    @StateObject private var level = LevelMeter()
    @Environment(\.scenePhase) private var scenePhase

    @State private var selected: ManualControl?
    @State private var showLooks = false
    @State private var showGrid = true
    @State private var focusPoint: CGPoint?
    @State private var focusToken = UUID()
    @State private var blink = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cam.permissionDenied {
                PermissionView()
            } else {
                VStack(spacing: 0) {
                    topBar
                    viewfinder
                    controlStrip.padding(.top, 8)
                    modeRow.padding(.top, 4)
                    Spacer(minLength: 4)
                    bottomBar.padding(.bottom, 8)
                }
            }

            if let toast = cam.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .onAppear {
            cam.start()
            level.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: cam.resume(); level.start()
            case .background: cam.pause(); level.stop()
            default: break
            }
        }
        .onChange(of: cam.shutterTick) { _, _ in
            blink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) { blink = false }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            ForEach(CaptureFormat.allCases) { f in
                let supported = f == .heif
                    || (f == .proRAW && cam.supportsProRAW)
                    || (f == .raw && cam.supportsBayerRAW)
                let enabled = supported && (cam.mode == .photo || f == .heif)
                Button {
                    Haptics.tap()
                    cam.setFormat(f)
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(cam.format == f ? Color.accentCam : Color.white.opacity(0.1)))
                        .foregroundStyle(cam.format == f ? Color.black : Color.white.opacity(enabled ? 0.9 : 0.3))
                }
                .disabled(!enabled)
            }
            Spacer()
            if cam.timerSeconds > 0 {
                Label("\(cam.timerSeconds)s", systemImage: "timer")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentCam)
            }
            settingsMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var settingsMenu: some View {
        Menu {
            Section("Overlays") {
                Toggle(isOn: $cam.showHistogram) { Label("Histogram", systemImage: "chart.bar.xaxis") }
                Toggle(isOn: $cam.showPeaking) { Label("Focus peaking", systemImage: "scope") }
                Toggle(isOn: $cam.showZebras) { Label("Zebras", systemImage: "line.diagonal") }
                Toggle(isOn: $showGrid) { Label("Grid & level", systemImage: "grid") }
            }
            Section("Shooting") {
                Toggle(isOn: $cam.steadyEnabled) { Label("SteadyZoom", systemImage: "gyroscope") }
                Toggle(isOn: $cam.smartShutter) { Label("Smart shutter", systemImage: "hand.raised") }
                Picker(selection: $cam.timerSeconds) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("10 s").tag(10)
                } label: {
                    Label("Timer", systemImage: "timer")
                }
                .pickerStyle(.menu)
            }
            Button {
                cam.resetAll()
            } label: {
                Label("Reset manual controls", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 32)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(
                    session: cam.session,
                    renderer: cam.renderer,
                    showProcessed: cam.metalActive,
                    onTap: { devicePoint, viewPoint, normalized in
                        Haptics.tap()
                        cam.handleTap(devicePoint: devicePoint, viewNormalized: normalized)
                        showReticle(at: viewPoint)
                    },
                    onLongPress: { devicePoint, viewPoint, normalized in
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        cam.handleLongPress(devicePoint: devicePoint, viewNormalized: normalized)
                        if !cam.steadyActive { showReticle(at: viewPoint) }
                    },
                    onPinch: { scale, began in cam.pinch(scale: scale, began: began) },
                    onHardwareShutter: { cam.shutterPressed() }
                )

                if cam.peakingActive || cam.showZebras, let img = cam.overlayImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                if showGrid {
                    GridOverlay().allowsHitTesting(false)
                    if !level.isFlat {
                        LevelIndicator(roll: level.roll).allowsHitTesting(false)
                    }
                }

                if let box = cam.lockBox {
                    LockBracket()
                        .stroke(Color.accentCam, lineWidth: 2)
                        .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                        .position(x: box.midX * geo.size.width, y: box.midY * geo.size.height)
                        .allowsHitTesting(false)
                }

                if let p = focusPoint {
                    FocusReticle()
                        .id(focusToken)
                        .position(p)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                statusOverlay.allowsHitTesting(false)
                viewfinderOverlays

                Color.black.opacity(blink ? 1 : 0).allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func showReticle(at point: CGPoint) {
        let token = UUID()
        focusToken = token
        focusPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if focusToken == token { withAnimation { focusPoint = nil } }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let n = cam.countdown {
            Text("\(n)")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 8)
        } else if let done = cam.nightProgress {
            StatusCard(title: "NIGHT \(done)/\(CameraController.nightFrameCount)",
                       subtitle: "Hold still",
                       progress: Double(done) / Double(CameraController.nightFrameCount))
        } else if cam.isMerging {
            StatusCard(title: "MERGING", subtitle: "Aligning frames", progress: nil)
        } else if cam.holdingSteady {
            StatusCard(title: "HOLD STEADY", subtitle: "Waiting for a still moment", progress: nil)
        }
    }

    private var viewfinderOverlays: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                if cam.showHistogram {
                    HistogramView(channels: cam.histogram).frame(width: 112, height: 52)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if cam.zoom > 1.01 {
                        Badge(text: String(format: "%.1f×", cam.effectiveZoom))
                    }
                    if cam.steadyActive {
                        Badge(text: "STEADY", icon: "gyroscope")
                    }
                    if cam.lockBox != nil {
                        Badge(text: "LOCKED", icon: "scope")
                    }
                    if cam.aeafLocked {
                        Badge(text: "AE/AF LOCK", icon: "lock.fill")
                    }
                    if cam.look != .natural {
                        Badge(text: cam.look.rawValue.uppercased())
                    }
                }
            }
            Spacer()
            if showLooks {
                looksStrip.transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let sel = selected {
                dialPanel(sel).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !cam.isFront && cam.lenses.count > 1 {
                lensPicker
            }
        }
        .padding(10)
    }

    private var looksStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Look.allCases) { l in
                    Button {
                        Haptics.tap()
                        cam.look = l
                    } label: {
                        Text(l.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(cam.look == l ? Color.accentCam : Color.black.opacity(0.55)))
                            .foregroundStyle(cam.look == l ? Color.black : Color.white)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func dialPanel(_ c: ManualControl) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                cam.setAuto(c)
            } label: {
                Text("AUTO")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Capsule().strokeBorder(cam.isManual(c) ? Color.white.opacity(0.5) : Color.accentCam, lineWidth: 1))
                    .foregroundStyle(cam.isManual(c) ? Color.white : Color.accentCam)
            }

            if c == .ev && cam.exposureIsManual {
                Text("Manual exposure: EV shows the meter")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else if c == .focus && !cam.manualFocusSupported {
                Text("Manual focus isn't supported on this lens")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                RulerDial(progress: Binding(
                    get: { cam.progress(for: c) },
                    set: { cam.setProgress($0, for: c) }
                ))
                .frame(height: 40)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.55)))
    }

    private var lensPicker: some View {
        HStack(spacing: 6) {
            ForEach(cam.lenses) { lens in
                let active = lens.id == cam.currentDeviceID
                Button {
                    Haptics.tap()
                    cam.select(lens)
                } label: {
                    Text(lens.label)
                        .font(.system(size: active ? 13 : 11, weight: .bold, design: .rounded))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .foregroundStyle(active ? Color.accentCam : Color.white)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }

    // MARK: Manual control strip

    private var controlStrip: some View {
        HStack(spacing: 0) {
            ForEach(ManualControl.allCases) { c in
                Button {
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.2)) {
                        showLooks = false
                        selected = selected == c ? nil : c
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(cam.label(for: c))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(cam.displayValue(for: c))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(cam.isManual(c) ? Color.accentCam : Color.white)
                        Capsule()
                            .fill(selected == c ? Color.accentCam : Color.clear)
                            .frame(width: 16, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Mode row

    private var modeRow: some View {
        HStack {
            Button {
                Haptics.tap()
                withAnimation(.snappy(duration: 0.2)) {
                    selected = nil
                    showLooks.toggle()
                }
            } label: {
                Image(systemName: "camera.filters")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 30)
                    .foregroundStyle(showLooks || cam.look != .natural ? Color.accentCam : Color.white.opacity(0.75))
            }

            Spacer()

            HStack(spacing: 22) {
                ForEach(ShootMode.allCases) { m in
                    Button {
                        Haptics.tap()
                        cam.setMode(m)
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(cam.mode == m ? Color.accentCam : Color.white.opacity(0.55))
                    }
                }
            }

            Spacer()

            Color.clear.frame(width: 44, height: 30)
        }
        .padding(.horizontal, 14)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                Group {
                    if let t = cam.lastThumbnail {
                        Image(uiImage: t).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2)))
            }

            Spacer()

            ShutterButton(icon: cam.mode == .night ? "moon.fill" : nil) {
                Haptics.shutter()
                cam.shutterPressed()
            }
            .opacity(cam.isBusy ? 0.5 : 1)

            Spacer()

            Button {
                Haptics.tap()
                cam.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 28)
    }
}
