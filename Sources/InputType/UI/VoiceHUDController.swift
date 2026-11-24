import Cocoa
import Combine
import QuartzCore

// MARK: - Pure AppKit Channel Icon View

private final class VoiceChannelIconNSView: NSView {
    private let imageView = NSImageView()
    private let fallbackSymbolView = NSImageView()
    private var currentIsError = false
    private var currentChannel: VoiceCloudChannel?

    init(size: CGFloat = 22, cornerRadius: CGFloat = 6) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        fallbackSymbolView.imageScaling = .scaleProportionallyDown
        fallbackSymbolView.contentTintColor = .white
        let inset = round(size * 0.22)
        fallbackSymbolView.frame = bounds.insetBy(dx: inset, dy: inset)
        fallbackSymbolView.autoresizingMask = [.width, .height]
        addSubview(fallbackSymbolView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(channel: VoiceCloudChannel?, isError: Bool) {
        currentChannel = channel
        currentIsError = isError
        if isError {
            imageView.isHidden = true
            fallbackSymbolView.isHidden = false
            layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.27, blue: 0.32, alpha: 1.0).cgColor
            let cfg = NSImage.SymbolConfiguration(pointSize: round(bounds.height * 0.50), weight: .bold)
            fallbackSymbolView.image = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        } else if let channel, let nsImage = NSImage(named: channel.iconAssetName) {
            imageView.isHidden = false
            fallbackSymbolView.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
            imageView.image = nsImage
        } else {
            imageView.isHidden = true
            fallbackSymbolView.isHidden = false
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            let cfg = NSImage.SymbolConfiguration(pointSize: round(bounds.height * 0.48), weight: .semibold)
            fallbackSymbolView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
    }
}

// MARK: - Pure AppKit Spectrum Waveform View (Zero SwiftUI)

private final class VoiceWaveNSView: NSView {
    private static let barCount = 13
    private static let barWeights: [CGFloat] = [
        0.34, 0.48, 0.64, 0.78, 0.90, 0.98, 1.00, 0.98, 0.90, 0.78, 0.64, 0.48, 0.34
    ]
    private static let barPhases: [CGFloat] = [
        0.0, 0.7, 1.4, 2.1, 2.8, 3.5, 4.2, 4.9, 5.6, 6.3, 7.0, 7.7, 8.4
    ]
    private static let darkPalette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.22, 0.74, 0.98), (0.38, 0.65, 1.00), (0.65, 0.55, 0.98),
        (0.96, 0.45, 0.71), (0.99, 0.50, 0.44), (0.98, 0.75, 0.24)
    ]
    private static let lightPalette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.01, 0.52, 0.78), (0.15, 0.39, 0.92), (0.49, 0.23, 0.93),
        (0.86, 0.15, 0.47), (0.88, 0.16, 0.28), (0.85, 0.47, 0.02)
    ]

    var smoothedLevel: CGFloat = 0
    private var animTimer: Timer?

    override var isOpaque: Bool { false }

    func setAnimating(_ running: Bool) {
        if running {
            guard animTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            animTimer = timer
        } else {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    deinit {
        animTimer?.invalidate()
    }

    private static func sampledColor(at position: CGFloat, isDark: Bool, opacity: CGFloat) -> NSColor {
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
        return NSColor(
            srgbRed: c0.0 + (c1.0 - c0.0) * frac,
            green: c0.1 + (c1.1 - c0.1) * frac,
            blue: c0.2 + (c1.2 - c0.2) * frac,
            alpha: opacity
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let t = CGFloat(Date.timeIntervalSinceReferenceDate)
        let count = Self.barCount
        let spacing: CGFloat = 4.5
        let totalSpacing = spacing * CGFloat(count - 1)
        let barWidth = max(2.5, min(3.2, (bounds.width - totalSpacing) / CGFloat(count)))
        let contentWidth = CGFloat(count) * barWidth + totalSpacing
        let startX = (bounds.width - contentWidth) * 0.5
        let minBarHeight: CGFloat = 4.5
        let maxBarHeight = max(minBarHeight, bounds.height - 4.0)
        let clampedLevel = max(0, min(1, smoothedLevel))
        let colorShift = t * 0.22
        let cs = CGColorSpaceCreateDeviceRGB()

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
            let y = (bounds.height - barHeight) * 0.5
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth * 0.5, cornerHeight: barWidth * 0.5, transform: nil)

            let u = CGFloat(i) / CGFloat(max(1, count - 1))
            let barOpacity = 0.82 + 0.18 * normalizedHeight
            let topColor = Self.sampledColor(at: u * 0.85 + colorShift, isDark: isDark, opacity: barOpacity).cgColor
            let bottomColor = Self.sampledColor(at: u * 0.85 + colorShift + 0.10, isDark: isDark, opacity: barOpacity * 0.92).cgColor

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let grad = CGGradient(colorsSpace: cs, colors: [bottomColor, topColor] as CFArray, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(
                    grad,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: []
                )
            }
            ctx.restoreGState()
        }
    }
}

// MARK: - Pure AppKit Gradient Spinner View

private final class VoiceSpinnerNSView: NSView {
    var lineWidth: CGFloat = 1.9
    private var animTimer: Timer?

    override var isOpaque: Bool { false }

    func setAnimating(_ running: Bool) {
        if running {
            guard animTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            animTimer = timer
        } else {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    deinit {
        animTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let radius = (min(bounds.width, bounds.height) - lineWidth) * 0.5
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(isDark ? 0.20 : 0.14).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.85) / 0.85
        let startAngle = CGFloat(-phase * 2.0 * .pi)
        let endAngle = startAngle - CGFloat(0.36 * 2.0 * .pi)
        let accent = isDark
            ? NSColor(srgbRed: 0.45, green: 0.65, blue: 0.98, alpha: 1.0)
            : NSColor(srgbRed: 0.20, green: 0.45, blue: 0.92, alpha: 1.0)
        ctx.setStrokeColor(accent.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
    }
}

// MARK: - Pure AppKit HUD Content View

private final class VoiceHUDContentNSView: NSView {
    private let iconView = VoiceChannelIconNSView(size: 22, cornerRadius: 6)
    private let waveView = VoiceWaveNSView(frame: NSRect(x: 0, y: 0, width: 112, height: 26))
    private let waitSpinner = VoiceSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private let waitLabel = NSTextField(labelWithString: "启动麦克风…")
    private let statusLabel = NSTextField(labelWithString: "")
    private let recognizingSpinner = VoiceSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))

    private var smoothedLevel: CGFloat = 0
    private var isVisibleHUD = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        waitLabel.font = .systemFont(ofSize: 12, weight: .medium)
        waitLabel.textColor = NSColor.labelColor.withAlphaComponent(0.86)
        waitLabel.lineBreakMode = .byTruncatingTail
        waitSpinner.lineWidth = 1.8

        statusLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        recognizingSpinner.lineWidth = 2.0

        addSubview(iconView)
        addSubview(waveView)
        addSubview(waitSpinner)
        addSubview(waitLabel)
        addSubview(statusLabel)
        addSubview(recognizingSpinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHUDVisible(_ visible: Bool) {
        isVisibleHUD = visible
        refresh(from: VoiceInputManager.shared)
    }

    func updateAudioLevel(_ raw: Float) {
        let v = CGFloat(raw)
        smoothedLevel = v > smoothedLevel
            ? (smoothedLevel * 0.3 + v * 0.7)
            : (smoothedLevel * 0.85 + v * 0.15)
        waveView.smoothedLevel = smoothedLevel
    }

    func refresh(from manager: VoiceInputManager) {
        iconView.update(channel: manager.activeChannel, isError: manager.isErrorState)

        let showWave = manager.isRecording && manager.isMicReady
        let showMicWarmup = manager.isRecording && !manager.isMicReady
        let showError = manager.isErrorState && !manager.statusText.isEmpty
        let showRecognizing = !showError && manager.isRecognizing

        waveView.isHidden = !showWave
        waitSpinner.isHidden = !showMicWarmup
        waitLabel.isHidden = !showMicWarmup

        if showError {
            statusLabel.isHidden = false
            statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
            statusLabel.textColor = .labelColor
            statusLabel.stringValue = manager.statusText
            recognizingSpinner.isHidden = true
        } else if showRecognizing {
            statusLabel.isHidden = false
            statusLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            statusLabel.textColor = NSColor.labelColor.withAlphaComponent(0.88)
            statusLabel.stringValue = "识别中…"
            recognizingSpinner.isHidden = false
        } else {
            statusLabel.isHidden = true
            recognizingSpinner.isHidden = true
        }

        waveView.setAnimating(isVisibleHUD && showWave)
        waitSpinner.setAnimating(isVisibleHUD && showMicWarmup)
        recognizingSpinner.setAnimating(isVisibleHUD && showRecognizing)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func preferredSize() -> NSSize {
        let height: CGFloat = 44
        var x: CGFloat = 11 + 22 // leading + icon

        if !waveView.isHidden {
            x += 11 + 112
        } else if !waitLabel.isHidden {
            x += 11 + 112
        }

        if !statusLabel.isHidden {
            let textW = min(420, ceil(statusLabel.fittingSize.width))
            x += 11 + textW
            if !recognizingSpinner.isHidden {
                x += 11 + 14
            }
        }
        x += 16 // trailing
        return NSSize(width: max(x, 60), height: height)
    }

    override func layout() {
        super.layout()
        let midY = bounds.height * 0.5
        var x: CGFloat = 11

        iconView.frame = NSRect(x: x, y: round(midY - 11), width: 22, height: 22)
        x += 22

        if !waveView.isHidden {
            x += 11
            waveView.frame = NSRect(x: x, y: round(midY - 13), width: 112, height: 26)
            x += 112
        } else if !waitLabel.isHidden {
            x += 11
            let labelSize = waitLabel.fittingSize
            let groupWidth = 12 + 6 + ceil(labelSize.width)
            let groupStart = x + round(max(0, 112 - groupWidth) * 0.5)
            waitSpinner.frame = NSRect(x: groupStart, y: round(midY - 6), width: 12, height: 12)
            waitLabel.frame = NSRect(
                x: groupStart + 18,
                y: round(midY - labelSize.height * 0.5),
                width: ceil(labelSize.width),
                height: ceil(labelSize.height)
            )
            x += 112
        }

        if !statusLabel.isHidden {
            x += 11
            let s = statusLabel.fittingSize
            let textW = min(420, ceil(s.width))
            statusLabel.frame = NSRect(
                x: x,
                y: round(midY - s.height * 0.5),
                width: textW,
                height: ceil(s.height)
            )
            x += textW
            if !recognizingSpinner.isHidden {
                x += 11
                recognizingSpinner.frame = NSRect(x: x, y: round(midY - 7), width: 14, height: 14)
            }
        }
    }
}

// MARK: - VoiceHUDController

final class VoiceHUDController {
    static let shared = VoiceHUDController()

    private let panel: NSPanel
    private let contentNSView: VoiceHUDContentNSView
    private var glassContainerView: NSView?
    private var fallbackEffectView: NSVisualEffectView?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

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

        let view = VoiceHUDContentNSView(frame: NSRect(x: 0, y: 0, width: 172, height: 44))
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 22
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 22
            glass.layer?.masksToBounds = true
            glass.contentView = view
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
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                view.topAnchor.constraint(equalTo: effect.topAnchor),
                view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
            self.fallbackEffectView = effect
        }

        self.panel = p
        self.contentNSView = view
        bindManager()
    }

    private func bindManager() {
        let mgr = VoiceInputManager.shared
        mgr.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.contentNSView.updateAudioLevel(level)
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            mgr.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            mgr.$isMicReady.map { _ in () }.eraseToAnyPublisher(),
            mgr.$isRecognizing.map { _ in () }.eraseToAnyPublisher(),
            mgr.$isErrorState.map { _ in () }.eraseToAnyPublisher(),
            mgr.$statusText.map { _ in () }.eraseToAnyPublisher(),
            mgr.$activeChannel.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            self.contentNSView.refresh(from: VoiceInputManager.shared)
            if self.panel.isVisible {
                self.updateLayout()
            }
        }
        .store(in: &cancellables)
    }

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        contentNSView.setHUDVisible(true)
        updateLayout()
        panel.orderFrontRegardless()
    }

    func updateLayout() {
        panel.ignoresMouseEvents = true
        contentNSView.refresh(from: VoiceInputManager.shared)
        let size = contentNSView.preferredSize()
        guard size.width > 0 && size.height > 0 else { return }

        let cornerRadius: CGFloat = round(size.height / 2)
        contentNSView.layer?.cornerRadius = cornerRadius
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
        let desiredGapPt: CGFloat = 15.0 / backingScale

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
            contentNSView.setHUDVisible(false)
            panel.orderOut(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.contentNSView.setHUDVisible(false)
            self?.panel.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
