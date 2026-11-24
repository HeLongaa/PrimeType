import Cocoa
import Carbon.HIToolbox
import Combine

// MARK: - Pure AppKit Pill Action Button

private final class TranslatePillButtonNSView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let onClick: () -> Void
    private var isAccent: Bool
    private var isEnabledState: Bool = true
    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, shortcut: String, isAccent: Bool, onClick: @escaping () -> Void) {
        self.isAccent = isAccent
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerCurve = .continuous

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerCurve = .continuous
        badgeContainer.layer?.cornerRadius = 4

        let baseFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        if let desc = baseFont.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: desc, size: 10.5) {
            badgeLabel.font = f
        } else {
            badgeLabel.font = baseFont
        }
        badgeLabel.stringValue = shortcut
        badgeLabel.alignment = .center

        addSubview(titleLabel)
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabledState != enabled else { return }
        isEnabledState = enabled
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hoverBoost: CGFloat = (isHovered && isEnabledState) ? 0.05 : 0.0
        if isAccent {
            let accent = NSColor.controlAccentColor
            titleLabel.textColor = accent.withAlphaComponent(isEnabledState ? 1.0 : 0.40)
            badgeLabel.textColor = accent.withAlphaComponent(isEnabledState ? 0.88 : 0.30)
            badgeContainer.layer?.backgroundColor = accent.withAlphaComponent(isEnabledState ? 0.16 : 0.07).cgColor
            layer?.backgroundColor = accent.withAlphaComponent(isEnabledState ? ((isDark ? 0.24 : 0.14) + hoverBoost) : 0.08).cgColor
        } else {
            titleLabel.textColor = NSColor.labelColor.withAlphaComponent(isEnabledState ? 0.86 : 0.32)
            badgeLabel.textColor = isEnabledState ? .secondaryLabelColor : NSColor.labelColor.withAlphaComponent(0.24)
            badgeContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isEnabledState ? 0.08 : 0.04).cgColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isEnabledState ? ((isDark ? 0.11 : 0.08) + hoverBoost) : 0.04).cgColor
        }
    }

    override var intrinsicContentSize: NSSize {
        let t = titleLabel.fittingSize
        let b = badgeLabel.fittingSize
        let badgeW = ceil(b.width) + 10
        let height = max(ceil(t.height), ceil(b.height) + 3) + 12
        return NSSize(width: 12 + ceil(t.width) + 6 + badgeW + 9, height: height)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height * 0.5
        let t = titleLabel.fittingSize
        let b = badgeLabel.fittingSize
        let badgeW = ceil(b.width) + 10
        let badgeH = ceil(b.height) + 3
        titleLabel.frame = NSRect(x: 12, y: round((bounds.height - t.height) * 0.5), width: ceil(t.width), height: ceil(t.height))
        let bx = 12 + ceil(t.width) + 6
        badgeContainer.frame = NSRect(x: bx, y: round((bounds.height - badgeH) * 0.5), width: badgeW, height: badgeH)
        badgeLabel.frame = NSRect(x: 5, y: round((badgeH - b.height) * 0.5), width: ceil(b.width), height: ceil(b.height))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabledState else { return }
        onClick()
    }
}

// MARK: - Pure AppKit Language Selector Pill

private final class TranslateLangPillNSView: NSView {
    private let sourceBtn = NSButton()
    private let swapBtn = NSButton()
    private let targetBtn = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        for btn in [sourceBtn, swapBtn, targetBtn] {
            btn.isBordered = false
            btn.bezelStyle = .inline
            btn.focusRingType = .none
            addSubview(btn)
        }

        sourceBtn.font = .systemFont(ofSize: 11, weight: .medium)
        sourceBtn.target = self
        sourceBtn.action = #selector(onSource)
        sourceBtn.toolTip = "选择源语言"

        let arrowCfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
        swapBtn.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(arrowCfg)
        swapBtn.contentTintColor = NSColor.labelColor.withAlphaComponent(0.55)
        swapBtn.target = self
        swapBtn.action = #selector(onSwap)
        swapBtn.toolTip = "互换源语言与目标语言"

        targetBtn.font = .systemFont(ofSize: 11, weight: .medium)
        targetBtn.target = self
        targetBtn.action = #selector(onTarget)
        targetBtn.toolTip = "选择目标语言"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(from manager: TranslateManager) {
        let srcText = (manager.detectedLanguageLabel.isEmpty ? "自动" : manager.detectedLanguageLabel) + " ▾"
        let dstText = manager.targetLanguageLabel + " ▾"
        let attrsSrc: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.76)
        ]
        sourceBtn.attributedTitle = NSAttributedString(string: srcText, attributes: attrsSrc)
        targetBtn.attributedTitle = NSAttributedString(string: dstText, attributes: attrsSrc)
        swapBtn.isEnabled = (manager.selectedSourceLanguage != nil)
        swapBtn.alphaValue = swapBtn.isEnabled ? 1.0 : 0.40
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let sW = ceil(sourceBtn.fittingSize.width) + 8
        let tW = ceil(targetBtn.fittingSize.width) + 8
        return NSSize(width: 4 + sW + 2 + 18 + 2 + tW + 4, height: 22)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height * 0.5
        let sW = ceil(sourceBtn.fittingSize.width) + 8
        let tW = ceil(targetBtn.fittingSize.width) + 8
        var x: CGFloat = 4
        sourceBtn.frame = NSRect(x: x, y: 1, width: sW, height: bounds.height - 2)
        x += sW + 2
        swapBtn.frame = NSRect(x: x, y: round((bounds.height - 18) * 0.5), width: 18, height: 18)
        x += 20
        targetBtn.frame = NSRect(x: x, y: 1, width: tW, height: bounds.height - 2)
    }

    @objc private func onSource() { TranslatePopupController.shared.presentSourceLanguageMenu() }
    @objc private func onSwap() { TranslateManager.shared.swapLanguages() }
    @objc private func onTarget() { TranslatePopupController.shared.presentTargetLanguageMenu() }
}

// MARK: - Pure AppKit Translate Popup Content View

private final class TranslatePopupContentNSView: NSView {
    private static let fixedWidth: CGFloat = 440

    private let headerIcon = NSImageView()
    private let headerTitle = NSTextField(labelWithString: "")
    private let langPill = TranslateLangPillNSView()

    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在处理...")

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var measuredTextHeight: CGFloat = 22

    private let footerSpinner = NSProgressIndicator()
    private let closeBtn: TranslatePillButtonNSView
    private let copyBtn: TranslatePillButtonNSView
    private let replaceBtn: TranslatePillButtonNSView

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        self.closeBtn = TranslatePillButtonNSView(title: "关闭", shortcut: "Esc", isAccent: false) {
            TranslateManager.shared.close()
        }
        self.copyBtn = TranslatePillButtonNSView(title: "拷贝", shortcut: "⌘C", isAccent: false) {
            TranslateManager.shared.copyResult()
        }
        self.replaceBtn = TranslatePillButtonNSView(title: "替换", shortcut: "↵", isAccent: true) {
            TranslateManager.shared.replaceResult()
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        headerIcon.imageScaling = .scaleProportionallyDown
        headerIcon.contentTintColor = .secondaryLabelColor

        headerTitle.font = .systemFont(ofSize: 14.5, weight: .semibold)
        headerTitle.textColor = .labelColor

        errorLabel.font = .systemFont(ofSize: 13.5)
        errorLabel.maximumNumberOfLines = 0

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false

        loadingLabel.font = .systemFont(ofSize: 13.5)
        loadingLabel.textColor = .secondaryLabelColor

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        footerSpinner.style = .spinning
        footerSpinner.controlSize = .mini
        footerSpinner.isDisplayedWhenStopped = false

        addSubview(headerIcon)
        addSubview(headerTitle)
        addSubview(langPill)
        addSubview(errorLabel)
        addSubview(loadingSpinner)
        addSubview(loadingLabel)
        addSubview(scrollView)
        addSubview(footerSpinner)
        addSubview(closeBtn)
        addSubview(copyBtn)
        addSubview(replaceBtn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(from: TranslateManager.shared)
    }

    func refresh(from manager: TranslateManager) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        headerIcon.image = NSImage(systemSymbolName: manager.activeAction.systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        headerTitle.stringValue = manager.activeAction.title

        let showLang = (manager.activeAction == .translate && !manager.targetLanguageLabel.isEmpty)
        langPill.isHidden = !showLang
        if showLang {
            langPill.refresh(from: manager)
        }

        let hasResult = !manager.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyBtn.setEnabled(hasResult)
        replaceBtn.setEnabled(hasResult)
        closeBtn.updateAppearance()

        if let error = manager.errorMessage {
            errorLabel.isHidden = false
            errorLabel.stringValue = error
            errorLabel.textColor = isDark
                ? NSColor(srgbRed: 1.0, green: 0.45, blue: 0.48, alpha: 1.0)
                : NSColor(srgbRed: 0.82, green: 0.16, blue: 0.22, alpha: 1.0)
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
            loadingLabel.isHidden = true
            scrollView.isHidden = true
        } else if manager.isProcessing && manager.translatedText.isEmpty {
            errorLabel.isHidden = true
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
            loadingLabel.isHidden = false
            scrollView.isHidden = true
            measuredTextHeight = 22
        } else {
            errorLabel.isHidden = true
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
            loadingLabel.isHidden = true
            scrollView.isHidden = false

            let attr = buildResultAttributedString(manager: manager, isDark: isDark)
            textView.textStorage?.setAttributedString(attr)
            let contentWidth = Self.fixedWidth - 32
            textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 10)
            textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                lm.ensureLayout(for: tc)
                let used = lm.usedRect(for: tc).height + 4
                measuredTextHeight = min(max(ceil(used), 22), 220)
            }
        }

        let showFooterSpin = manager.isProcessing && !manager.translatedText.isEmpty
        footerSpinner.isHidden = !showFooterSpin
        if showFooterSpin {
            footerSpinner.startAnimation(nil)
        } else {
            footerSpinner.stopAnimation(nil)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func buildResultAttributedString(manager: TranslateManager, isDark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let font = NSFont.systemFont(ofSize: 14)

        if manager.activeAction == .rewrite && !manager.diffChunks.isEmpty {
            let result = NSMutableAttributedString()
            for chunk in manager.diffChunks {
                switch chunk {
                case .equal(let text):
                    result.append(NSAttributedString(string: text, attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraph
                    ]))
                case .inserted(let text):
                    let color = isDark
                        ? NSColor(srgbRed: 0.42, green: 0.88, blue: 0.50, alpha: 1.0)
                        : NSColor(srgbRed: 0.09, green: 0.58, blue: 0.24, alpha: 1.0)
                    result.append(NSAttributedString(string: text, attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: paragraph
                    ]))
                case .deleted(let text):
                    let color = isDark
                        ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
                        : NSColor(srgbRed: 0.82, green: 0.16, blue: 0.22, alpha: 1.0)
                    result.append(NSAttributedString(string: text, attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .paragraphStyle: paragraph
                    ]))
                }
            }
            return result
        }

        return NSAttributedString(string: manager.translatedText, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }

    func preferredSize() -> NSSize {
        let contentW = Self.fixedWidth - 32
        let headerH: CGFloat = 22
        let bodyH: CGFloat
        if !errorLabel.isHidden {
            errorLabel.preferredMaxLayoutWidth = contentW
            bodyH = max(22, ceil(errorLabel.fittingSize.height))
        } else if !loadingLabel.isHidden {
            bodyH = 24
        } else {
            bodyH = measuredTextHeight
        }
        let footerH = max(closeBtn.intrinsicContentSize.height, 28)
        let totalH = 14 + headerH + 12 + bodyH + 14 + footerH + 14
        return NSSize(width: Self.fixedWidth, height: ceil(totalH))
    }

    override func layout() {
        super.layout()
        let contentW = bounds.width - 32
        var y: CGFloat = 14

        // Header
        let headerH: CGFloat = 22
        headerIcon.frame = NSRect(x: 16, y: y + 3, width: 16, height: 16)
        let titleSize = headerTitle.fittingSize
        headerTitle.frame = NSRect(x: 40, y: y + round((headerH - titleSize.height) * 0.5), width: min(220, ceil(titleSize.width)), height: ceil(titleSize.height))
        if !langPill.isHidden {
            let pillSize = langPill.intrinsicContentSize
            langPill.frame = NSRect(x: bounds.width - 16 - pillSize.width, y: y, width: pillSize.width, height: pillSize.height)
        }
        y += headerH + 12

        // Body
        if !errorLabel.isHidden {
            errorLabel.preferredMaxLayoutWidth = contentW
            let h = max(22, ceil(errorLabel.fittingSize.height))
            errorLabel.frame = NSRect(x: 16, y: y, width: contentW, height: h)
            y += h
        } else if !loadingLabel.isHidden {
            loadingSpinner.frame = NSRect(x: 16, y: y + 4, width: 16, height: 16)
            let ls = loadingLabel.fittingSize
            loadingLabel.frame = NSRect(x: 40, y: y + round((24 - ls.height) * 0.5), width: ceil(ls.width), height: ceil(ls.height))
            y += 24
        } else {
            scrollView.frame = NSRect(x: 16, y: y, width: contentW, height: measuredTextHeight)
            y += measuredTextHeight
        }

        y += 14

        // Footer
        let rSize = replaceBtn.intrinsicContentSize
        let cSize = copyBtn.intrinsicContentSize
        let xSize = closeBtn.intrinsicContentSize
        let footerH = max(rSize.height, 28)

        if !footerSpinner.isHidden {
            footerSpinner.frame = NSRect(x: 16, y: y + round((footerH - 12) * 0.5), width: 12, height: 12)
        }

        var rx = bounds.width - 16 - rSize.width
        replaceBtn.frame = NSRect(x: rx, y: y, width: rSize.width, height: rSize.height)
        rx -= (8 + cSize.width)
        copyBtn.frame = NSRect(x: rx, y: y, width: cSize.width, height: cSize.height)
        rx -= (8 + xSize.width)
        closeBtn.frame = NSRect(x: rx, y: y, width: xSize.width, height: xSize.height)
    }
}

// MARK: - TranslatePanel & TranslatePopupController

private final class TranslatePanel: NSPanel {
    enum KeyAction {
        case close
        case copy
        case replace
    }

    var onKeyAction: ((KeyAction) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKeyAction {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == [.command] && Int(event.keyCode) == kVK_ANSI_C {
                onKeyAction(.copy)
                return
            }
            if mods.isEmpty {
                switch Int(event.keyCode) {
                case kVK_Escape:
                    onKeyAction(.close)
                    return
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    onKeyAction(.replace)
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}

final class TranslatePopupController: NSObject, NSWindowDelegate {
    static let shared = TranslatePopupController()

    private struct PopupPlacement {
        let lockedX: CGFloat
        let anchorTopY: CGFloat
        let anchorBottomY: CGFloat
        let isAbove: Bool
        let visibleFrame: NSRect
    }

    private let panel: TranslatePanel
    private let contentNSView: TranslatePopupContentNSView
    private var activePlacement: PopupPlacement?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isHiding = false
    private var isPresentingMenu = false
    private var menuActionTargets: [MenuActionTrampoline] = []
    private var cancellables: Set<AnyCancellable> = []

    private final class MenuActionTrampoline: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func invoke(_ sender: Any?) { handler() }
    }

    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    private override init() {
        let p = TranslatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
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
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let view = TranslatePopupContentNSView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = 20
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 20
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 20
            glass.layer?.masksToBounds = true
            glass.contentView = view
            p.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = 20
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                view.topAnchor.constraint(equalTo: effect.topAnchor),
                view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
        }

        self.panel = p
        self.contentNSView = view
        super.init()

        p.delegate = self
        p.onKeyAction = { action in
            switch action {
            case .close: TranslateManager.shared.close()
            case .copy: TranslateManager.shared.copyResult()
            case .replace: TranslateManager.shared.replaceResult()
            }
        }
        bindManager()
    }

    private func bindManager() {
        let mgr = TranslateManager.shared
        mgr.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.contentNSView.refresh(from: TranslateManager.shared)
                if self.panel.isVisible {
                    self.applyActivePlacement()
                }
            }
            .store(in: &cancellables)
    }

    func show(near anchorRect: NSRect?, makeKey: Bool = true) {
        isHiding = false
        contentNSView.refresh(from: TranslateManager.shared)
        activePlacement = computeInitialPlacement(anchorRect: anchorRect)
        applyActivePlacement()
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
    }

    func focusPanel() {
        guard panel.isVisible, !isHiding else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func updateLayout() {
        guard panel.isVisible else { return }
        contentNSView.refresh(from: TranslateManager.shared)
        applyActivePlacement()
    }

    func hide() {
        guard !isHiding else { return }
        isHiding = true
        removeOutsideClickMonitors()
        panel.orderOut(nil)
        activePlacement = nil
        isHiding = false
    }

    // MARK: - Language Dropdown Menus

    func presentSourceLanguageMenu() {
        let manager = TranslateManager.shared
        let menu = NSMenu(title: "源语言")
        var trampolines: [MenuActionTrampoline] = []

        let autoTrampoline = MenuActionTrampoline { manager.setSourceLanguage(nil) }
        trampolines.append(autoTrampoline)
        let autoItem = NSMenuItem(title: "自动检测", action: #selector(MenuActionTrampoline.invoke(_:)), keyEquivalent: "")
        autoItem.target = autoTrampoline
        autoItem.state = (manager.selectedSourceLanguage == nil) ? .on : .off
        menu.addItem(autoItem)
        menu.addItem(.separator())

        for lang in TranslateLanguage.allCases {
            let trampoline = MenuActionTrampoline { manager.setSourceLanguage(lang) }
            trampolines.append(trampoline)
            let item = NSMenuItem(title: lang.displayName, action: #selector(MenuActionTrampoline.invoke(_:)), keyEquivalent: "")
            item.target = trampoline
            item.state = (manager.selectedSourceLanguage == lang) ? .on : .off
            menu.addItem(item)
        }

        presentMenuAnchoredToMouse(menu, trampolines: trampolines)
    }

    func presentTargetLanguageMenu() {
        let manager = TranslateManager.shared
        let menu = NSMenu(title: "目标语言")
        var trampolines: [MenuActionTrampoline] = []

        for lang in TranslateLanguage.allCases {
            let trampoline = MenuActionTrampoline { manager.setTargetLanguage(lang) }
            trampolines.append(trampoline)
            let item = NSMenuItem(title: lang.displayName, action: #selector(MenuActionTrampoline.invoke(_:)), keyEquivalent: "")
            item.target = trampoline
            item.state = (manager.selectedTargetLanguage == lang) ? .on : .off
            menu.addItem(item)
        }

        presentMenuAnchoredToMouse(menu, trampolines: trampolines)
    }

    private func presentMenuAnchoredToMouse(_ menu: NSMenu, trampolines: [MenuActionTrampoline]) {
        guard panel.isVisible, let contentView = panel.contentView else { return }
        menuActionTargets = trampolines
        isPresentingMenu = true

        let mouseInWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = contentView.convert(mouseInWindow, from: nil)
        let popPoint = NSPoint(x: max(8, localPoint.x - 16), y: max(8, localPoint.y - 12))
        menu.popUp(positioning: nil, at: popPoint, in: contentView)

        isPresentingMenu = false
        menuActionTargets = []
        if panel.isVisible && !isHiding {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isHiding, !isPresentingMenu, panel.isVisible else { return }
        TranslateManager.shared.close()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.isHiding, !self.isPresentingMenu else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                TranslateManager.shared.close()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible, !self.isHiding, !self.isPresentingMenu else { return event }
            if event.window !== self.panel && !self.panel.frame.contains(NSEvent.mouseLocation) {
                TranslateManager.shared.close()
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func computeInitialPlacement(anchorRect: NSRect?) -> PopupPlacement {
        let size = contentNSView.preferredSize()
        let panelWidth = size.width > 0 ? size.width : 440
        let panelHeight = size.height > 0 ? size.height : 120

        let mouse = NSEvent.mouseLocation
        let screen = (anchorRect.flatMap { rect in NSScreen.screens.first { $0.frame.contains(rect.origin) } })
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let spacing: CGFloat = 8
        let reservedHeight = max(panelHeight, 260)

        let rawX: CGFloat
        let anchorTopY: CGFloat
        let anchorBottomY: CGFloat

        if let anchor = anchorRect {
            rawX = anchor.minX
            anchorTopY = anchor.maxY + spacing
            anchorBottomY = anchor.minY - spacing
        } else {
            rawX = mouse.x + 12
            anchorTopY = mouse.y + 12
            anchorBottomY = mouse.y - 12
        }

        let lockedX = round(min(max(rawX, visible.minX + 8), visible.maxX - panelWidth - 8))
        let spaceBelow = anchorBottomY - (visible.minY + 8)
        let spaceAbove = (visible.maxY - 8) - anchorTopY
        let isAbove = (spaceBelow < reservedHeight && spaceAbove > spaceBelow)

        return PopupPlacement(
            lockedX: lockedX,
            anchorTopY: anchorTopY,
            anchorBottomY: anchorBottomY,
            isAbove: isAbove,
            visibleFrame: visible
        )
    }

    private func applyActivePlacement() {
        let size = contentNSView.preferredSize()
        guard size.width > 0 && size.height > 0 else { return }

        let placement = activePlacement ?? computeInitialPlacement(anchorRect: nil)
        activePlacement = placement

        let visible = placement.visibleFrame
        let rawY = placement.isAbove
            ? placement.anchorTopY
            : (placement.anchorBottomY - size.height)
        let clampedY = round(min(max(rawY, visible.minY + 8), visible.maxY - size.height - 8))

        panel.setFrame(NSRect(origin: NSPoint(x: placement.lockedX, y: clampedY), size: size), display: true)
        panel.invalidateShadow()
    }
}
