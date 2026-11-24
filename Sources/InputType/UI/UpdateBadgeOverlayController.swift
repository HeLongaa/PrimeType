import Cocoa
import QuartzCore

/// Pure AppKit floating update pill shown below the IMKCandidates window when a newer version is available.
final class UpdateBadgeOverlayController {
    static let shared = UpdateBadgeOverlayController()

    private var panel: NSPanel?
    private var lastVersionText: String = ""

    private init() {}

    func showIfAvailable(below candidateWindow: NSWindow?) {
        let updater = AppUpdateManager.shared
        guard updater.hasUpdate, let rawVersion = updater.latestVersion, !rawVersion.isEmpty,
              let candidateWindow, candidateWindow.isVisible else {
            hide()
            return
        }

        let normalized = rawVersion.hasPrefix("v") || rawVersion.hasPrefix("V")
            ? "V" + rawVersion.dropFirst()
            : "V" + rawVersion
        let badgeText = "\(normalized) NEW"

        let panel = ensurePanel(badgeText: badgeText)
        let candidateFrame = candidateWindow.frame
        let badgeSize = panel.frame.size
        let origin = NSPoint(
            x: candidateFrame.minX + 6,
            y: candidateFrame.minY - badgeSize.height - 4
        )
        panel.setFrameOrigin(origin)
        panel.level = NSWindow.Level(rawValue: candidateWindow.level.rawValue + 1)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel(badgeText: String) -> NSPanel {
        if let existing = panel, lastVersionText == badgeText {
            return existing
        }
        lastVersionText = badgeText

        let pill = UpdateBadgePillNSView(text: badgeText) { [weak self] in
            self?.hide()
            SettingsHelperLauncher.shared.showSettings()
        }
        let size = pill.intrinsicContentSize
        pill.frame = NSRect(origin: .zero, size: size)

        let p: NSPanel = panel ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = pill
        p.setContentSize(size)
        self.panel = p
        return p
    }
}

private final class UpdateBadgePillNSView: NSView {
    private let label: NSTextField
    private let gradientLayer = CAGradientLayer()
    private let onTap: () -> Void

    init(text: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        wantsLayer = true
        let baseFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let roundedFont: NSFont
        if let desc = baseFont.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: desc, size: 10.5) {
            roundedFont = f
        } else {
            roundedFont = baseFont
        }
        label.font = roundedFont
        label.textColor = NSColor(calibratedRed: 0.25, green: 0.16, blue: 0.0, alpha: 1.0)
        label.alignment = .center
        label.sizeToFit()

        gradientLayer.colors = [
            NSColor(calibratedRed: 0.99, green: 0.86, blue: 0.42, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.22, alpha: 1.0).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.borderColor = NSColor(calibratedRed: 0.78, green: 0.56, blue: 0.10, alpha: 0.6).cgColor
        gradientLayer.borderWidth = 0.75
        layer?.addSublayer(gradientLayer)

        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: max(ceil(s.width) + 16, 72), height: max(ceil(s.height) + 6, 20))
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = bounds.height * 0.5
        let s = label.fittingSize
        label.frame = NSRect(
            x: round((bounds.width - s.width) * 0.5),
            y: round((bounds.height - s.height) * 0.5),
            width: ceil(s.width),
            height: ceil(s.height)
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }
}
