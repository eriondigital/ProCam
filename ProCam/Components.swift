import SwiftUI
import UIKit

extension Color {
    static let accentCam = Color(red: 1.0, green: 0.48, blue: 0.1)
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func shutter() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

// MARK: - Shutter

struct ShutterButton: View {
    var icon: String? = nil
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
            Circle().fill(.white).frame(width: 64, height: 64).scaleEffect(pressed ? 0.86 : 1)
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .scaleEffect(pressed ? 0.86 : 1)
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.25)) { pressed = false }
                    action()
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Take photo")
    }
}

// MARK: - Ruler dial

/// Horizontal scrolling ruler. Drag left/right to change `progress` (0…1).
struct RulerDial: View {
    @Binding var progress: Double
    @State private var dragStart: Double?
    @State private var lastTick = -1
    private let ticks = 60
    private let feedback = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let span: CGFloat = geo.size.width * 2.2
            Canvas { ctx, size in
                let mid = size.width / 2
                let offset = CGFloat(progress) * span
                for i in 0...ticks {
                    let x = mid + CGFloat(i) / CGFloat(ticks) * span - offset
                    if x < -2 || x > size.width + 2 { continue }
                    let major = i % 5 == 0
                    let h: CGFloat = major ? 16 : 8
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height / 2 - h / 2))
                    p.addLine(to: CGPoint(x: x, y: size.height / 2 + h / 2))
                    let fade = 1 - min(abs(x - mid) / mid, 1) * 0.8
                    ctx.stroke(p,
                               with: .color(.white.opacity(Double((major ? 0.9 : 0.5) * fade))),
                               lineWidth: major ? 1.5 : 1)
                }
                var needle = Path()
                needle.move(to: CGPoint(x: mid, y: 2))
                needle.addLine(to: CGPoint(x: mid, y: size.height - 2))
                ctx.stroke(needle, with: .color(.accentCam), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let start = dragStart ?? progress
                        if dragStart == nil {
                            dragStart = start
                            feedback.prepare()
                        }
                        let p = min(max(start - Double(g.translation.width / span), 0), 1)
                        progress = p
                        let tick = Int((p * Double(ticks)).rounded())
                        if tick != lastTick {
                            lastTick = tick
                            feedback.selectionChanged()
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }
}

// MARK: - Overlays

struct HistogramView: View {
    let channels: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            let colors: [Color] = [.red, .green, .blue]
            ctx.blendMode = .screen
            for (i, ch) in channels.enumerated() where i < 3 && ch.count > 1 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (j, v) in ch.enumerated() {
                    let x = size.width * CGFloat(j) / CGFloat(ch.count - 1)
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[i].opacity(0.75)))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
        .allowsHitTesting(false)
    }
}

struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
        }
    }
}

struct LevelIndicator: View {
    let roll: Double

    var body: some View {
        let snapped = (roll / 90).rounded() * 90
        let isLevel = abs(roll - snapped) < 0.8
        ZStack {
            // fixed reference ticks
            HStack(spacing: 100) {
                Rectangle().frame(width: 10, height: 1)
                Rectangle().frame(width: 10, height: 1)
            }
            .foregroundStyle(.white.opacity(0.5))
            // live horizon
            Rectangle()
                .fill(isLevel ? Color.accentCam : Color.white.opacity(0.85))
                .frame(width: 90, height: isLevel ? 2 : 1)
                .rotationEffect(.degrees(-roll))
        }
        .animation(.easeOut(duration: 0.1), value: isLevel)
    }
}

struct FocusReticle: View {
    @State private var scale: CGFloat = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentCam, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { scale = 1 }
            }
    }
}

struct Badge: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.accentCam)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Corner brackets drawn around a locked-on subject.
struct LockBracket: Shape {
    func path(in r: CGRect) -> Path {
        let l = min(r.width, r.height) * 0.25
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

/// Centre status card (countdown, smart shutter, night progress).
struct StatusCard: View {
    let title: String
    var subtitle: String? = nil
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let progress {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 4)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentCam, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
                .frame(width: 54, height: 54)
            }
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color.accentCam)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.6)))
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40))
            Text("Camera access is off").font(.title3.bold())
            Text("Turn it on in Settings to start shooting.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentCam)
        }
        .foregroundStyle(.white)
        .padding()
    }
}
