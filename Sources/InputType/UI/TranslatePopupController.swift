import Cocoa
import Carbon.HIToolbox
import SwiftUI

private struct TranslateShortcutBadge: View {
    let key: String
    let tint: Color
    let background: Color

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
            )
    }
}

private struct TranslatePopupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var manager = TranslateManager.shared
    @State private var textContentHeight: CGFloat = 22

    private var hasResult: Bool {
        !manager.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let isDark = (colorScheme == .dark)
        VStack(alignment: .leading, spacing: 12) {
            // Header row: icon + action title + subtle direction badge (for translate)
            HStack(spacing: 8) {
                Image(systemName: manager.activeAction.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(manager.activeAction.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if manager.activeAction == .translate && !manager.targetLanguageLabel.isEmpty {
                    TranslateLanguageSelectorPill(manager: manager)
                }
            }

            // Content area: spinner "正在处理..." / streaming translated text / error
            Group {
                if let error = manager.errorMessage {
                    Text(error)
                        .font(.system(size: 13.5))
                        .foregroundStyle(isDark ? Color(red: 1.0, green: 0.45, blue: 0.48) : Color(red: 0.82, green: 0.16, blue: 0.22))
                        .fixedSize(horizontal: false, vertical: true)
                } else if manager.isProcessing && manager.translatedText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在处理...")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    ScrollView {
                        resultTextView
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear {
                                            updateMeasuredTextHeight(geo.size.height)
                                        }
                                        .onChange(of: geo.size.height) { _, newHeight in
                                            updateMeasuredTextHeight(newHeight)
                                        }
                                }
                            )
                    }
                    .frame(height: min(max(textContentHeight, 22), 220))
                }
            }

            // Footer pill action buttons (bottom-right: 关闭 / 拷贝 / 替换)
            HStack(spacing: 8) {
                if manager.isProcessing && !manager.translatedText.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()

                Button {
                    manager.close()
                } label: {
                    HStack(spacing: 6) {
                        Text("关闭")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.86))
                        TranslateShortcutBadge(
                            key: "Esc",
                            tint: .secondary,
                            background: Color.primary.opacity(0.08)
                        )
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(isDark ? 0.11 : 0.08))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    manager.copyResult()
                } label: {
                    HStack(spacing: 6) {
                        Text("拷贝")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(hasResult ? Color.primary.opacity(0.86) : Color.primary.opacity(0.32))
                        TranslateShortcutBadge(
                            key: "⌘C",
                            tint: hasResult ? .secondary : Color.primary.opacity(0.24),
                            background: Color.primary.opacity(hasResult ? 0.08 : 0.04)
                        )
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(hasResult ? (isDark ? 0.11 : 0.08) : 0.04))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasResult)

                Button {
                    manager.replaceResult()
                } label: {
                    HStack(spacing: 6) {
                        Text("替换")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(hasResult ? Color.accentColor : Color.accentColor.opacity(0.4))
                        TranslateShortcutBadge(
                            key: "↵",
                            tint: hasResult ? Color.accentColor.opacity(0.88) : Color.accentColor.opacity(0.30),
                            background: Color.accentColor.opacity(hasResult ? 0.16 : 0.07)
                        )
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(hasResult ? (isDark ? 0.24 : 0.14) : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasResult)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: manager.translatedText) { _, newText in
            if newText.isEmpty {
                textContentHeight = 22
            }
        }
    }

    @ViewBuilder
    private var resultTextView: some View {
        if manager.activeAction == .rewrite && !manager.diffChunks.isEmpty {
            Text(attributedDiff(manager.diffChunks))
        } else {
            Text(manager.translatedText)
                .foregroundStyle(.primary)
        }
    }

    private func attributedDiff(_ chunks: [QuickActionDiffEngine.Chunk]) -> AttributedString {
        let isDark = (colorScheme == .dark)
        return chunks.reduce(into: AttributedString()) { result, chunk in
            switch chunk {
            case .equal(let text):
                var run = AttributedString(text)
                run.foregroundColor = Color.primary
                result.append(run)
            case .inserted(let text):
                var run = AttributedString(text)
                run.foregroundColor = isDark
                    ? Color(red: 0.42, green: 0.88, blue: 0.50)
                    : Color(red: 0.09, green: 0.58, blue: 0.24)
                result.append(run)
            case .deleted(let text):
                var run = AttributedString(text)
                run.foregroundColor = isDark
                    ? Color(red: 1.0, green: 0.42, blue: 0.42)
                    : Color(red: 0.82, green: 0.16, blue: 0.22)
                run.strikethroughStyle = .single
                result.append(run)
            }
        }
    }

    private func updateMeasuredTextHeight(_ height: CGFloat) {
        let clamped = max(22, ceil(height))
        guard abs(clamped - textContentHeight) > 0.5 else { return }
        textContentHeight = clamped
        DispatchQueue.main.async {
            TranslatePopupController.shared.updateLayout()
        }
    }
}

private struct TranslateLanguageSelectorPill: View {
    @ObservedObject var manager: TranslateManager
    @State private var hoverSource = false
    @State private var hoverTarget = false
    @State private var hoverSwap = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                TranslatePopupController.shared.presentSourceLanguageMenu()
            } label: {
                HStack(spacing: 3) {
                    Text(manager.detectedLanguageLabel.isEmpty ? "自动" : manager.detectedLanguageLabel)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.primary.opacity(hoverSource ? 0.92 : 0.70))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(hoverSource ? 0.11 : 0.0))
                )
            }
            .buttonStyle(.plain)
            .onHover { hoverSource = $0 }
            .help("选择源语言")

            Button {
                manager.swapLanguages()
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(hoverSwap ? 0.92 : 0.48))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(hoverSwap ? 0.11 : 0.0))
                    )
            }
            .buttonStyle(.plain)
            .disabled(manager.selectedSourceLanguage == nil)
            .onHover { hoverSwap = $0 }
            .help("互换源语言与目标语言")

            Button {
                TranslatePopupController.shared.presentTargetLanguageMenu()
            } label: {
                HStack(spacing: 3) {
                    Text(manager.targetLanguageLabel)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.primary.opacity(hoverTarget ? 0.92 : 0.74))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(hoverTarget ? 0.11 : 0.0))
                )
            }
            .buttonStyle(.plain)
            .onHover { hoverTarget = $0 }
            .help("选择目标语言")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1.5)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.08))
        )
    }
}

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
        let anchorTopY: CGFloat    // y above which the panel sits when placed above
        let anchorBottomY: CGFloat // y below which the panel sits when placed below
        let isAbove: Bool
        let visibleFrame: NSRect
    }

    private let panel: TranslatePanel
    private let hostingView: NSHostingView<TranslatePopupView>
    private var activePlacement: PopupPlacement?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isHiding = false
    private var isPresentingMenu = false
    private var menuActionTargets: [MenuActionTrampoline] = []

    private final class MenuActionTrampoline: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }
        @objc func invoke(_ sender: Any?) {
            handler()
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    private override init() {
        let p = TranslatePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 140),
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

        let host = NSHostingView(rootView: TranslatePopupView())
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerCurve = .continuous
        host.layer?.cornerRadius = 20
        host.layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 20
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 20
            glass.layer?.masksToBounds = true
            glass.contentView = host
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
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
        }

        self.panel = p
        self.hostingView = host
        super.init()

        p.delegate = self
        p.onKeyAction = { action in
            switch action {
            case .close:
                TranslateManager.shared.close()
            case .copy:
                TranslateManager.shared.copyResult()
            case .replace:
                TranslateManager.shared.replaceResult()
            }
        }
    }

    func show(near anchorRect: NSRect?, makeKey: Bool = true) {
        isHiding = false
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
        applyActivePlacement()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.applyActivePlacement()
        }
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

        let autoTrampoline = MenuActionTrampoline {
            manager.setSourceLanguage(nil)
        }
        trampolines.append(autoTrampoline)
        let autoItem = NSMenuItem(title: "自动检测", action: #selector(MenuActionTrampoline.invoke(_:)), keyEquivalent: "")
        autoItem.target = autoTrampoline
        autoItem.state = (manager.selectedSourceLanguage == nil) ? .on : .off
        menu.addItem(autoItem)
        menu.addItem(.separator())

        for lang in TranslateLanguage.allCases {
            let trampoline = MenuActionTrampoline {
                manager.setSourceLanguage(lang)
            }
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
            let trampoline = MenuActionTrampoline {
                manager.setTargetLanguage(lang)
            }
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

    // MARK: - Outside Click & Resign Key Dismissal

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
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
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
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
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
