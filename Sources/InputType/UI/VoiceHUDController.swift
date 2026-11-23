import Cocoa
import SwiftUI

// MARK: - Channel Icon

struct VoiceChannelIconView: View {
    let channel: VoiceCloudChannel?
    var isError: Bool = false
    var size: CGFloat = 22
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if isError {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.88, green: 0.27, blue: 0.32))
                    Image(systemName: "exclamationmark")
                        .font(.system(size: round(size * 0.52), weight: .bold))
                        .foregroundStyle(.white)
                }
            } else if let channel, let nsImage = NSImage(named: channel.iconAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor)
                    Image(systemName: "mic.fill")
                        .font(.system(size: round(size * 0.50), weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Audio Level Spectrum Visualizer

private struct VoiceWaveView: View {
    @Environment(\.colorScheme) private var colorScheme
    var level: CGFloat
    var paused: Bool = false
    var width: CGFloat = 120
    var height: CGFloat = 30

    private static let barCount = 13
    private static let barWeights: [CGFloat] = [
        0.34, 0.48, 0.64, 0.78, 0.90, 0.98, 1.00, 0.98, 0.90, 0.78, 0.64, 0.48, 0.34
    ]
    private static let barPhases: [CGFloat] = [
        0.0, 0.7, 1.4, 2.1, 2.8, 3.5, 4.2, 4.9, 5.6, 6.3, 7.0, 7.7, 8.4
    ]

    // Luminous Apple-Intelligence-inspired iridescent stops (wraps smoothly)
    private static let darkPalette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.22, 0.74, 0.98), // Sky Cyan
        (0.38, 0.65, 1.00), // Electric Blue
        (0.65, 0.55, 0.98), // Soft Violet
        (0.96, 0.45, 0.71), // Vivid Pink
        (0.99, 0.50, 0.44), // Warm Coral
        (0.98, 0.75, 0.24)  // Luminous Amber
    ]

    private static let lightPalette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.01, 0.52, 0.78), // Deep Sky
        (0.15, 0.39, 0.92), // Cobalt Blue
        (0.49, 0.23, 0.93), // Rich Violet
        (0.86, 0.15, 0.47), // Vivid Magenta
        (0.88, 0.16, 0.28), // Rose Coral
        (0.85, 0.47, 0.02)  // Rich Amber
    ]

    private static func sampledColor(at position: CGFloat, isDark: Bool, opacity: CGFloat) -> Color {
        let palette = isDark ? darkPalette : lightPalette
        let n = palette.count
        var wrapped = position.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        let scaled = wrapped * CGFloat(n)
        let idx0 = Int(floor(scaled)) % n
        let idx1 = (idx0 + 1) % n
        let frac = scaled - floor(scaled)
        let c0 = palette[idx0]
        let c1 = palette[idx1]
        return Color(
            red: c0.0 + (c1.0 - c0.0) * frac,
            green: c0.1 + (c1.1 - c0.1) * frac,
            blue: c0.2 + (c1.2 - c0.2) * frac
        ).opacity(opacity)
    }

    var body: some View {
        let isDark = (colorScheme == .dark)
        TimelineView(.animation(paused: paused)) { context in
            let t = CGFloat(context.date.timeIntervalSinceReferenceDate)
            Canvas { ctx, size in
                let count = Self.barCount
                let spacing: CGFloat = 4.5
                let totalSpacing = spacing * CGFloat(count - 1)
                let barWidth = max(2.5, min(3.2, (size.width - totalSpacing) / CGFloat(count)))
                let contentWidth = CGFloat(count) * barWidth + totalSpacing
                let startX = (size.width - contentWidth) * 0.5
                let minBarHeight: CGFloat = 4.5
                let maxBarHeight = max(minBarHeight, size.height - 4.0)
                let clampedLevel = max(0, min(1, level))
                let colorShift = t * 0.22

                for i in 0..<count {
                    let weight = Self.barWeights[i]
                    let phase = Self.barPhases[i]

                    let rippleA = 0.5 + 0.5 * sin(t * 6.8 + phase)
                    let rippleB = 0.5 + 0.5 * cos(t * 4.1 - phase * 0.7)
                    let organic = 0.55 + 0.45 * (rippleA * 0.6 + rippleB * 0.4)
                    let energy = pow(clampedLevel, 0.82)
                    let active = (0.10 + energy * 0.90) * organic * weight
                    let normalizedHeight = max(0.06, min(1.0, active))

                    let barHeight = minBarHeight + (maxBarHeight - minBarHeight) * normalizedHeight
                    let x = startX + CGFloat(i) * (barWidth + spacing)
                    let y = (size.height - barHeight) * 0.5
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let pill = Path(roundedRect: rect, cornerRadius: barWidth * 0.5)

                    let u = CGFloat(i) / CGFloat(max(1, count - 1))
                    let barOpacity = 0.82 + 0.18 * normalizedHeight
                    let topColor = Self.sampledColor(at: u * 0.85 + colorShift, isDark: isDark, opacity: barOpacity)
                    let bottomColor = Self.sampledColor(at: u * 0.85 + colorShift + 0.10, isDark: isDark, opacity: barOpacity * 0.92)
                    ctx.fill(
                        pill,
                        with: .linearGradient(
                            Gradient(colors: [topColor, bottomColor]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                }
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Activity Indicator

private struct VoiceWaitSpinnerView: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.0
    var paused: Bool = false

    var body: some View {
        let isDark = (colorScheme == .dark)
        TimelineView(.animation(paused: paused)) { context in
            let angle = Angle.degrees(
                context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85) / 0.85 * 360.0
            )
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(isDark ? 0.20 : 0.14), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.34)
                    .stroke(
                        LinearGradient(
                            colors: isDark
                                ? [Color(red: 0.22, green: 0.74, blue: 0.98), Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.96, green: 0.45, blue: 0.71)]
                                : [Color(red: 0.01, green: 0.52, blue: 0.78), Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.86, green: 0.15, blue: 0.47)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(angle)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - HUD Visibility State

private final class VoiceHUDVisibilityState: ObservableObject {
    @Published var isVisible: Bool = false
}

// MARK: - HUD Root Content View

private struct VoiceHUDContentView: View {
    @ObservedObject var manager = VoiceInputManager.shared
    @ObservedObject var visibilityState: VoiceHUDVisibilityState
    @State private var smoothedLevel: CGFloat = 0

    var body: some View {
        singleChannelCapsule
            .onChange(of: manager.audioLevel) { _, raw in
                let v = CGFloat(raw)
                smoothedLevel = v > smoothedLevel
                    ? (smoothedLevel * 0.3 + v * 0.7)
                    : (smoothedLevel * 0.85 + v * 0.15)
            }
    }

    // Compact floating voice status capsule (hosted inside single native NSGlassEffectView)
    private var singleChannelCapsule: some View {
        let paused = !visibilityState.isVisible
        return HStack(spacing: 11) {
            VoiceChannelIconView(
                channel: manager.activeChannel,
                isError: manager.isErrorState,
                size: 22,
                cornerRadius: 6
            )

            if manager.isRecording {
                if manager.isMicReady {
                    VoiceWaveView(
                        level: smoothedLevel,
                        paused: paused,
                        width: 112,
                        height: 26
                    )
                } else {
                    HStack(spacing: 6) {
                        VoiceWaitSpinnerView(size: 12, lineWidth: 1.8, paused: paused)
                        Text("启动麦克风…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.86))
                    }
                    .frame(width: 112, height: 26)
                }
            }

            if manager.isErrorState && !manager.statusText.isEmpty {
                Text(manager.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 420, alignment: .leading)
            } else if manager.isRecognizing {
                Text("识别中…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                VoiceWaitSpinnerView(size: 14, lineWidth: 2.0, paused: paused)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 16)
        .frame(height: 44)
        .fixedSize()
    }
}

final class VoiceHUDController {
    static let shared = VoiceHUDController()

    private let panel: NSPanel
    private let visibilityState = VoiceHUDVisibilityState()
    private let hostingView: NSHostingView<VoiceHUDContentView>
    private var glassContainerView: NSView?
    private var fallbackEffectView: NSVisualEffectView?
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 172, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let host = NSHostingView(rootView: VoiceHUDContentView(visibilityState: visibilityState))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerCurve = .continuous
        host.layer?.cornerRadius = 22
        host.layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 22
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 22
            glass.layer?.masksToBounds = true
            glass.contentView = host
            p.contentView = glass
            self.glassContainerView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = 22
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
            self.fallbackEffectView = effect
        }

        self.panel = p
        self.hostingView = host
    }

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        visibilityState.isVisible = true
        updateLayout()
        panel.orderFrontRegardless()
    }

    func updateLayout() {
        panel.ignoresMouseEvents = true

        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0 && size.height > 0 else { return }

        let cornerRadius: CGFloat = round(size.height / 2)
        hostingView.layer?.cornerRadius = cornerRadius
        if #available(macOS 26.0, *), let glass = glassContainerView as? NSGlassEffectView {
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = cornerRadius
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.masksToBounds = true
        } else if let effect = fallbackEffectView {
            effect.layer?.cornerRadius = cornerRadius
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backingScale = max(1.0, screen?.backingScaleFactor ?? 2.0)
        let desiredGapAboveDockPx: CGFloat = 15.0
        let desiredGapPt = desiredGapAboveDockPx / backingScale

        let origin = NSPoint(
            x: round(visibleFrame.midX - size.width / 2),
            y: round(visibleFrame.minY + desiredGapPt)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()
        if delay <= 0 {
            visibilityState.isVisible = false
            panel.orderOut(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.visibilityState.isVisible = false
            self?.panel.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
