import SwiftUI

/// Feature tour shown on first launch (and from Settings → Feature tour).
struct OnboardingView: View {
    var onFinish: () -> Void

    private struct Page: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let text: String
        let tint: Color
    }

    private let pages: [Page] = [
        Page(icon: "camera.aperture", title: "Welcome to ProCam",
             text: "A pro camera that stays out of your way. Here's a quick look at what it can do.",
             tint: .accentCam),
        Page(icon: "gyroscope", title: "SteadyZoom",
             text: "Zoom in and ProCam stabilises the frame itself, on top of the lens. Long-press a subject while zoomed to lock on and keep it centred.",
             tint: .orange),
        Page(icon: "moon.stars.fill", title: "Night Mode",
             text: "Shoots a burst of longer exposures, aligns them and merges them into one clean, bright photo. Hold still while the ring fills. A tripod makes it even better.",
             tint: .indigo),
        Page(icon: "wand.and.stars", title: "ProCam Detail",
             text: "ProCam's own processing adds local contrast and edge-aware sharpening for crisper, deeper photos. RAW shots get developed by ProCam too. Pick Apple, Natural or Strong in settings.",
             tint: .teal),
        Page(icon: "dial.medium", title: "Full Manual Control",
             text: "ISO, shutter, focus, white balance and EV on a precise dial. Shoot HEIF, ProRAW or RAW.",
             tint: .yellow),
        Page(icon: "chart.bar.xaxis", title: "Pro Tools & Looks",
             text: "Live histogram, focus peaking, zebras, grid and level. Looks give you live colour styles, from Warm Film to Noir.",
             tint: .pink),
        Page(icon: "hand.tap.fill", title: "Shortcuts",
             text: "Tap to focus. Long-press to lock focus and exposure. Pinch to zoom. The volume buttons take the photo. Find the self-timer in settings.",
             tint: .green)
    ]

    @State private var index = 0
    @State private var glow = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if index < pages.count - 1 {
                        Button("Skip") { onFinish() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .glassCapsule()
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 20)

                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        pageView(page).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots.padding(.bottom, 22)

                Button {
                    Haptics.tap()
                    if index < pages.count - 1 {
                        withAnimation(.snappy) { index += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(index < pages.count - 1 ? "Continue" : "Start shooting")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .prominentGlassButton()
                .tint(.accentCam)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { glow = true }
        }
    }

    private var background: some View {
        let tint = pages[index].tint
        return ZStack {
            Color.black
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: glow ? 90 : -90, y: glow ? -220 : -120)
            Circle()
                .fill(Color.accentCam.opacity(0.35))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: glow ? -110 : 100, y: glow ? 260 : 180)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: index)
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 128, height: 128)
                .glass(Circle(), tint: page.tint.opacity(0.5))
            VStack(spacing: 12) {
                Text(page.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(page.text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .glass(RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 24)
            Spacer()
            Spacer()
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.3))
                    .frame(width: i == index ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: index)
    }
}
