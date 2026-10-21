import SwiftUI

struct CameraScreen: View {
    @StateObject private var cam = CameraController()
    @StateObject private var level = LevelMeter()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("procam.onboarded") private var onboarded = false

    @State private var showTour = false
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
                    controlStrip.padding(.top, 10)
                    modeRow.padding(.top, 8)
                    Spacer(minLength: 4)
                    bottomBar.padding(.bottom, 8)
                }
            }

            if let toast = cam.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: cam.toast)
        .onAppear {
            if onboarded {
                cam.start()
            } else {
                showTour = true
            }
            level.start()
        }
        .fullScreenCover(isPresented: $showTour) {
            OnboardingView {
                onboarded = true
                showTour = false
                cam.start()
            }
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
        HStack(spacing: 8) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(CaptureFormat.allCases) { f in
                        let supported = f == .heif
                            || (f == .proRAW && cam.supportsProRAW)
                            || (f == .raw && cam.supportsBayerRAW)
                        let enabled = supported && (cam.mode == .photo || f == .heif)
                        let active = cam.format == f
                        Button {
                            Haptics.tap()
                            cam.setFormat(f)
                        } label: {
                            Text(f.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(active ? Color.black : Color.white.opacity(enabled ? 0.9 : 0.3))
                                .background(Capsule().fill(active ? Color.accentCam : Color.clear))
                        }
                        .disabled(!enabled)
                    }
                }
                .padding(3)
                .glassCapsule()
            }
            Spacer()
            if cam.timerSeconds > 0 {
                Label("\(cam.timerSeconds)s", systemImage: "timer")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentCam)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassCapsule()
            }
            settingsMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var settingsMenu: some View {
        Menu {
            Section("Processing") {
                Picker(selection: $cam.processing) {
                    ForEach(ProcessingStyle.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label("Processing", systemImage: "wand.and.stars")
                }
                .pickerStyle(.menu)
            }
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
            Section {
                Button {
                    cam.resetAll()
                } label: {
                    Label("Reset manual controls", systemImage: "arrow.counterclockwise")
                }
                Button {
                    showTour = true
                } label: {
                    Label("Feature tour", systemImage: "sparkles")
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 36)
                .glassCircle()
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
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                .font(.system(size: 88, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 150, height: 150)
                .glass(Circle())
        } else if let done = cam.nightProgress {
            StatusCard(title: "NIGHT \(done)/\(cam.nightTotal)",
                       subtitle: cam.nightPlan.map { "Hold still · \($0)" } ?? "Hold still",
                       progress: Double(done) / Double(max(cam.nightTotal, 1)))
        } else if cam.isMerging {
            StatusCard(title: "DEVELOPING", subtitle: "Aligning and merging frames", progress: nil)
        } else if cam.holdingSteady {
            StatusCard(title: "HOLD STEADY", subtitle: "Waiting for a still moment", progress: nil)
        }
    }

    private var viewfinderOverlays: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                if cam.showHistogram {
                    HistogramView(channels: cam.histogram).frame(width: 118, height: 58)
                }
                Spacer()
                GlassGroup(spacing: 6) {
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
                        if cam.processing != .apple {
                            Badge(text: cam.processing == .strong ? "DETAIL+" : "DETAIL", icon: "wand.and.stars")
                        }
                        if cam.look != .natural {
                            Badge(text: cam.look.rawValue.uppercased())
                        }
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
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Look.allCases) { l in
                        let active = cam.look == l
                        Button {
                            Haptics.tap()
                            cam.look = l
                        } label: {
                            Text(l.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(active ? Color.black : Color.white)
                                .glassCapsule(tint: active ? .accentCam : nil)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
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
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .foregroundStyle(cam.isManual(c) ? Color.white : Color.black)
                    .glassCapsule(tint: cam.isManual(c) ? nil : .accentCam)
            }

            if c == .ev && cam.exposureIsManual {
                Text("Manual exposure: EV shows the meter")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else if c == .focus && !cam.manualFocusSupported {
                Text("Manual focus isn't supported on this lens")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                RulerDial(progress: Binding(
                    get: { cam.progress(for: c) },
                    set: { cam.setProgress($0, for: c) }
                ))
                .frame(height: 40)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .glass(RoundedRectangle(cornerRadius: 20))
    }

    private var lensPicker: some View {
        GlassGroup(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(cam.lenses) { lens in
                    let active = lens.id == cam.currentDeviceID
                    Button {
                        Haptics.tap()
                        cam.select(lens)
                    } label: {
                        Text(lens.label)
                            .font(.system(size: active ? 13 : 11, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? Color.accentCam : Color.white)
                            .frame(width: active ? 42 : 36, height: active ? 42 : 36)
                            .glassCircle()
                    }
                }
            }
            .padding(4)
        }
        .animation(.snappy, value: cam.currentDeviceID)
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
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(selected == c ? Color.white.opacity(0.14) : Color.clear)
                    )
                }
            }
        }
        .padding(4)
        .glass(Capsule())
        .padding(.horizontal, 12)
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(showLooks || cam.look != .natural ? Color.accentCam : Color.white)
                    .frame(width: 40, height: 36)
                    .glassCircle()
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(ShootMode.allCases) { m in
                    let active = cam.mode == m
                    Button {
                        Haptics.tap()
                        cam.setMode(m)
                    } label: {
                        Label(m.rawValue, systemImage: m == .night ? "moon.fill" : "camera.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(active ? Color.black : Color.white.opacity(0.75))
                            .background(Capsule().fill(active ? Color.accentCam : Color.clear))
                    }
                }
            }
            .padding(3)
            .glassCapsule()

            Spacer()

            Color.clear.frame(width: 40, height: 36)
        }
        .padding(.horizontal, 14)
        .animation(.snappy, value: cam.mode)
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
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(4)
                .glass(RoundedRectangle(cornerRadius: 14), interactive: true)
            }

            Spacer()

            ShutterButton(icon: cam.mode == .night ? "moon.fill" : nil) {
                Haptics.shutter()
                cam.shutterPressed()
            }
            .padding(5)
            .glassCircle()
            .opacity(cam.isBusy ? 0.5 : 1)

            Spacer()

            Button {
                Haptics.tap()
                cam.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .glassCircle()
            }
        }
        .padding(.horizontal, 26)
    }
}
