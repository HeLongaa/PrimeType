import Cocoa
import Darwin
import SwiftUI

private enum ClipboardFilterType: String, CaseIterable, Identifiable {
    case all = "所有类型"
    case text = "纯文本"
    case image = "图像"
    case link = "链接"
    case file = "文件"

    var id: String { rawValue }

    func matches(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: return true
        case .text: return entry.kind == .text
        case .image: return entry.kind == .image
        case .link: return entry.kind == .link
        case .file: return entry.kind == .file
        }
    }
}

private struct ClipboardActionPillGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
                        )
                )
                .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        }
    }
}

private struct RowClickCatcher: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickCatcherNSView {
        let view = ClickCatcherNSView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickCatcherNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickCatcherNSView: NSView {
        var onSingleClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick?()
            } else {
                onSingleClick?()
            }
        }
    }
}

private enum ClipboardAppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let maxCachedIcons = 24

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        // Downsample multi-resolution app icons (which include 512/1024px reps) to a lightweight 32x32 bitmap
        let rawIcon = NSWorkspace.shared.icon(forFile: url.path)
        let targetSize = NSSize(width: 32, height: 32)
        let small = NSImage(size: targetSize, flipped: false) { rect in
            rawIcon.draw(in: rect)
            return true
        }
        if cache.count >= maxCachedIcons {
            cache.removeAll(keepingCapacity: false)
        }
        cache[bundleID] = small
        return small
    }

    static func clear() {
        cache.removeAll(keepingCapacity: false)
    }
}

private final class ClipboardPanelState: ObservableObject {
    @Published var searchText: String = ""
    @Published var filterType: ClipboardFilterType = .all
    @Published var selectedEntryID: UUID?
    @Published var keyboardScrollTick: Int = 0
    @Published var targetAppName: String = "当前应用"

    func resetForOpen(targetAppName: String?, firstEntryID: UUID?) {
        self.searchText = ""
        self.filterType = .all
        self.selectedEntryID = firstEntryID
        self.keyboardScrollTick = 0
        self.targetAppName = targetAppName ?? "当前应用"
    }
}

private struct ClipboardPopupView: View {
    @ObservedObject var manager = ClipboardManager.shared
    @ObservedObject var state: ClipboardPanelState
    let onPaste: (ClipboardEntry) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    private var filteredEntries: [ClipboardEntry] {
        manager.entries.filter { entry in
            guard state.filterType.matches(entry) else { return false }
            let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            if entry.listTitle.localizedCaseInsensitiveContains(query) { return true }
            if let app = entry.sourceAppName, app.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    private var groupedSections: [(title: String, items: [ClipboardEntry])] {
        let order = ["今天", "昨天", "更早"]
        var dict: [String: [ClipboardEntry]] = [:]
        for item in filteredEntries {
            dict[item.dateSectionTitle, default: []].append(item)
        }
        return order.compactMap { key in
            guard let items = dict[key], !items.isEmpty else { return nil }
            return (title: key, items: items)
        }
    }

    private var selectedEntry: ClipboardEntry? {
        if let id = state.selectedEntryID, let match = filteredEntries.first(where: { $0.id == id }) {
            return match
        }
        return filteredEntries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.25)
            mainSplitContent
        }
        .frame(width: 780, height: 500)
        .onAppear {
            searchFocused = true
            if state.selectedEntryID == nil {
                state.selectedEntryID = filteredEntries.first?.id
            }
        }
        .onChange(of: filteredEntries) { _, newItems in
            if let current = state.selectedEntryID, newItems.contains(where: { $0.id == current }) {
                return
            }
            state.selectedEntryID = newItems.first?.id
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                if !state.searchText.isEmpty {
                    state.searchText = ""
                } else {
                    onDismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            TextField("输入以筛选条目...", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($searchFocused)
                .onSubmit {
                    if let entry = selectedEntry {
                        onPaste(entry)
                    }
                }

            Spacer()

            Menu {
                ForEach(ClipboardFilterType.allCases) { type in
                    Button {
                        state.filterType = type
                    } label: {
                        HStack {
                            Text(type.rawValue)
                            if state.filterType == type {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12))
                    Text(state.filterType.rawValue)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var mainSplitContent: some View {
        HStack(spacing: 0) {
            leftListColumn
                .frame(width: 285)
            Divider().opacity(0.25)
            rightDetailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftListColumn: some View {
        ZStack(alignment: .bottomLeading) {
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(InputSettings.shared.clipboardEnabled ? "暂无剪贴板条目" : "剪贴板记录未开启")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groupedSections, id: \.title) { section in
                                Text(section.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)

                                ForEach(section.items) { entry in
                                    entryRow(entry)
                                        .id(entry.id)
                                        .overlay {
                                            RowClickCatcher(
                                                onSingleClick: {
                                                    state.selectedEntryID = entry.id
                                                },
                                                onDoubleClick: {
                                                    state.selectedEntryID = entry.id
                                                    onPaste(entry)
                                                }
                                            )
                                        }
                                }
                            }
                        }
                        .padding(.bottom, 54)
                    }
                    .onChange(of: state.keyboardScrollTick) { _, _ in
                        if let newId = state.selectedEntryID {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                }
            }

            // Bottom-left quick filter / clear glass circle button (matching right action pill)
            Button {
                showFilterMenu()
            } label: {
                VStack(spacing: 3.5) {
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 13, height: 1.5)
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 13, height: 1.5)
                }
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.18), lineWidth: 0.75)
                        )
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.bottom, 14)
        }
    }

    private func entryRow(_ entry: ClipboardEntry) -> some View {
        let isSelected = (selectedEntry?.id == entry.id)
        return HStack(spacing: 10) {
            if entry.kind == .image, let img = manager.thumbnailImage(for: entry) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: entry.kind.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }

            Text(entry.listTitle)
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.13) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var rightDetailColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 0) {
                    previewArea(for: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                    metadataArea(for: entry)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 62)
                }

                bottomActionPill(for: entry)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            } else {
                Text("选择左侧条目查看详情")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func previewArea(for entry: ClipboardEntry) -> some View {
        if entry.kind == .image, let img = manager.previewImage(for: entry) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                Text(entry.text ?? "")
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    private func metadataArea(for entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if let appName = entry.sourceAppName {
                metadataRow(label: "来源") {
                    HStack(spacing: 6) {
                        if let bid = entry.sourceAppBundleID,
                           let icon = ClipboardAppIconCache.icon(forBundleID: bid) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 15, height: 15)
                        }
                        Text(appName)
                    }
                }
            }

            metadataRow(label: "种类") {
                Text(entry.kind.displayName)
            }

            if entry.kind == .image, let w = entry.imageWidth, let h = entry.imageHeight {
                metadataRow(label: "尺寸") {
                    Text("\(w)×\(h)")
                }
            } else if let text = entry.text {
                metadataRow(label: "字数") {
                    Text("\(text.count) 字符")
                }
            }

            metadataRow(label: "大小") {
                Text(entry.formattedSize)
            }

            metadataRow(label: "拷贝时间", showDivider: false) {
                Text(entry.formattedTimestamp)
            }
        }
    }

    private func metadataRow<Content: View>(label: String, showDivider: Bool = true, @ViewBuilder value: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                value()
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 6)

            if showDivider {
                Divider().opacity(0.18)
            }
        }
    }

    private func bottomActionPill(for entry: ClipboardEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                onPaste(entry)
            } label: {
                HStack(spacing: 6) {
                    Text("粘贴到 \(state.targetAppName)")
                        .font(.system(size: 13, weight: .medium))
                    Text("↵")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(0.28), lineWidth: 0.75)
                        )
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 16)
                .opacity(0.3)

            Button {
                showActionsMenu(for: entry)
            } label: {
                HStack(spacing: 5) {
                    Text("操作")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("⌘")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(0.24), lineWidth: 0.75)
                        )
                    Text("K")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(0.24), lineWidth: 0.75)
                        )
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .modifier(ClipboardActionPillGlassModifier())
    }

    private func showFilterMenu() {
        let menu = NSMenu()
        for type in ClipboardFilterType.allCases {
            let item = MenuActionItem(title: type.rawValue) {
                state.filterType = type
            }
            item.state = (state.filterType == type) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "清空全部剪贴板记录") {
            manager.clearAll()
        })
        popUpMenuInsidePanel(menu, alignRight: false)
    }

    private func showActionsMenu(for entry: ClipboardEntry) {
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: "粘贴到 \(state.targetAppName)") {
            onPaste(entry)
        })
        menu.addItem(MenuActionItem(title: "仅复制到剪贴板") {
            manager.copyToPasteboard(entry)
            onDismiss()
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "删除此条目") {
            manager.remove(id: entry.id)
        })
        menu.addItem(MenuActionItem(title: "清空全部记录") {
            manager.clearAll()
        })
        popUpMenuInsidePanel(menu, alignRight: true)
    }

    private func popUpMenuInsidePanel(_ menu: NSMenu, alignRight: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return
        }
        menu.update()
        let menuSize = menu.size
        let panelFrame = window.frame
        let x: CGFloat = alignRight
            ? max(panelFrame.minX + 14, panelFrame.maxX - menuSize.width - 16)
            : (panelFrame.minX + 14)
        // NSMenu expands downward from `at`, so place top edge at buttonTop + menuHeight
        // so the entire menu sits upward and strictly inside the clipboard panel.
        let topY = min(panelFrame.maxY - 14, panelFrame.minY + 56 + menuSize.height)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: topY), in: nil)
    }
}

private final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invokeHandler), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invokeHandler() {
        let action = handler
        DispatchQueue.main.async {
            action()
        }
    }
}

private final class AlignmentGuideLinesView: NSView {
    var leftLineX: CGFloat = 0
    var rightLineX: CGFloat = 0
    var visibleMinY: CGFloat = 0
    var visibleMaxY: CGFloat = 0
    var isSnapped: Bool = false

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard visibleMaxY > visibleMinY else { return }

        let lineWidth: CGFloat = isSnapped ? 1.5 : 1.0
        let accentColor = NSColor.controlAccentColor.withAlphaComponent(isSnapped ? 0.95 : 0.58)
        let backingColor = NSColor.black.withAlphaComponent(isSnapped ? 0.22 : 0.16)
        let dashPattern: [CGFloat] = [6, 4]

        // Place lines right along the outer left/right edges of the horizontally centered panel slot
        let xs = [round(leftLineX) - 0.5, round(rightLineX) + 0.5]

        for x in xs {
            // Subtle dark contrast backing so guide lines remain legible over bright backgrounds
            let backingPath = NSBezierPath()
            backingPath.lineWidth = lineWidth + 1.5
            if !isSnapped {
                backingPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            }
            backingPath.move(to: NSPoint(x: x, y: visibleMinY))
            backingPath.line(to: NSPoint(x: x, y: visibleMaxY))
            backingColor.setStroke()
            backingPath.stroke()

            NSGraphicsContext.saveGraphicsState()
            if isSnapped {
                let glow = NSShadow()
                glow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.55)
                glow.shadowBlurRadius = 5
                glow.shadowOffset = .zero
                glow.set()
            }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            if !isSnapped {
                path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            }
            path.move(to: NSPoint(x: x, y: visibleMinY))
            path.line(to: NSPoint(x: x, y: visibleMaxY))
            accentColor.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

private final class ClipboardGuideOverlayWindow: NSWindow {
    private let guideView = AlignmentGuideLinesView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = guideView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showGuides(
        on screen: NSScreen,
        centeredLeftX: CGFloat,
        centeredRightX: CGFloat,
        isSnapped: Bool,
        below panel: NSWindow
    ) {
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
        }
        level = panel.level
        guideView.frame = NSRect(origin: .zero, size: screen.frame.size)
        guideView.leftLineX = centeredLeftX - screen.frame.minX
        guideView.rightLineX = centeredRightX - screen.frame.minX
        guideView.visibleMinY = screen.visibleFrame.minY - screen.frame.minY
        guideView.visibleMaxY = screen.visibleFrame.maxY - screen.frame.minY
        guideView.isSnapped = isSnapped
        guideView.needsDisplay = true

        if !isVisible {
            order(.below, relativeTo: panel.windowNumber)
        }
    }

    func hideGuides() {
        if isVisible {
            orderOut(nil)
        }
    }
}

private final class FloatingClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCommandDragUpdate: ((NSScreen, CGFloat, CGFloat, Bool) -> Void)?
    var onCommandDragEnd: ((NSScreen, Bool) -> Void)?
    var onCommandDragCancel: (() -> Void)?

    private var isCommandDragging = false
    private var hasDragged = false
    private var dragStartMouseScreen: NSPoint = .zero
    private var dragStartPanelOrigin: NSPoint = .zero
    private var wasSnappedX = false
    private var didPushDragCursor = false
    private var lastDragScreen: NSScreen?

    private let horizontalSnapThreshold: CGFloat = 14.0

    func cancelCommandDragIfNeeded() {
        guard isCommandDragging else { return }
        isCommandDragging = false
        hasDragged = false
        lastDragScreen = nil
        if didPushDragCursor {
            NSCursor.pop()
            didPushDragCursor = false
        }
        onCommandDragCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if event.modifierFlags.contains(.command) {
                isCommandDragging = true
                hasDragged = false
                dragStartMouseScreen = NSEvent.mouseLocation
                dragStartPanelOrigin = frame.origin
                let screen = activeScreen(forPanelOrigin: frame.origin, mouse: dragStartMouseScreen)
                lastDragScreen = screen
                if let screen {
                    let centeredLeftX = round(screen.visibleFrame.midX - frame.width / 2)
                    wasSnappedX = abs(frame.origin.x - centeredLeftX) <= 1.0
                } else {
                    wasSnappedX = false
                }
                if !didPushDragCursor {
                    NSCursor.closedHand.push()
                    didPushDragCursor = true
                }
                return
            }

        case .leftMouseDragged:
            if isCommandDragging {
                handleCommandDrag()
                return
            }

        case .leftMouseUp:
            if isCommandDragging {
                let moved = hasDragged
                let snapped = wasSnappedX
                let screen = lastDragScreen ?? activeScreen(forPanelOrigin: frame.origin, mouse: NSEvent.mouseLocation)
                isCommandDragging = false
                hasDragged = false
                lastDragScreen = nil
                if didPushDragCursor {
                    NSCursor.pop()
                    didPushDragCursor = false
                }
                if moved, let screen {
                    onCommandDragEnd?(screen, snapped)
                } else {
                    onCommandDragCancel?()
                }
                return
            }

        default:
            break
        }

        super.sendEvent(event)
    }

    private func handleCommandDrag() {
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - dragStartMouseScreen.x
        let dy = currentMouse.y - dragStartMouseScreen.y
        if !hasDragged && abs(dx) < 1 && abs(dy) < 1 {
            return
        }
        hasDragged = true

        let rawX = dragStartPanelOrigin.x + dx
        let rawY = dragStartPanelOrigin.y + dy
        guard let screen = activeScreen(forPanelOrigin: NSPoint(x: rawX, y: rawY), mouse: currentMouse) else {
            setFrameOrigin(NSPoint(x: round(rawX), y: round(rawY)))
            return
        }
        lastDragScreen = screen

        let visibleFrame = screen.visibleFrame
        let centeredLeftX = round(visibleFrame.midX - frame.width / 2)
        let centeredRightX = centeredLeftX + frame.width

        let snappedX: Bool
        let finalX: CGFloat
        if abs(rawX - centeredLeftX) <= horizontalSnapThreshold {
            finalX = centeredLeftX
            snappedX = true
        } else {
            finalX = round(rawX)
            snappedX = false
        }

        let finalY = round(rawY)

        if snappedX && !wasSnappedX {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        wasSnappedX = snappedX

        setFrameOrigin(NSPoint(x: finalX, y: finalY))
        onCommandDragUpdate?(screen, centeredLeftX, centeredRightX, snappedX)
    }

    private func activeScreen(forPanelOrigin origin: NSPoint, mouse: NSPoint) -> NSScreen? {
        let center = NSPoint(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? self.screen
            ?? NSScreen.main
    }
}

final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private static let offsetXKey = "clipboardPanelOffsetX"
    private static let offsetYKey = "clipboardPanelOffsetY"
    private static let defaultOffsetY: CGFloat = 30

    private let panel: FloatingClipboardPanel
    private let guideOverlay = ClipboardGuideOverlayWindow()
    private let state = ClipboardPanelState()
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    private override init() {
        let p = FloatingClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // Keep below NSMenu (popUpMenuWindow = 101) so native popup menus always render on top
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Dragging is exclusively via Command + Drag so clicks/text-selection never accidentally move the panel
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        self.panel = p
        super.init()

        p.onCommandDragUpdate = { [weak self] screen, leftX, rightX, isSnapped in
            guard let self else { return }
            self.guideOverlay.showGuides(
                on: screen,
                centeredLeftX: leftX,
                centeredRightX: rightX,
                isSnapped: isSnapped,
                below: self.panel
            )
        }
        p.onCommandDragEnd = { [weak self] screen, isSnappedX in
            guard let self else { return }
            self.guideOverlay.hideGuides()
            self.savePanelPosition(on: screen, snappedToCenterX: isSnappedX)
        }
        p.onCommandDragCancel = { [weak self] in
            self?.guideOverlay.hideGuides()
        }
        p.delegate = self
    }

    private func attachContentViewIfNeeded() {
        guard panel.contentView == nil else { return }
        let rootView = ClipboardPopupView(
            state: state,
            onPaste: { [weak self] entry in
                self?.pasteAndDismiss(entry)
            },
            onDismiss: { [weak self] in
                self?.hide(restoreFocus: true)
            }
        )
        let host = NSHostingView(rootView: rootView)
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
            panel.contentView = glass
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
            panel.contentView = effect
        }
    }

    func toggle() {
        if panel.isVisible {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        } else if previousApp == nil, let bid = InputTypeController.latestActiveBundleID {
            previousApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }
        }

        state.resetForOpen(
            targetAppName: previousApp?.localizedName,
            firstEntryID: ClipboardManager.shared.entries.first?.id
        )

        attachContentViewIfNeeded()
        positionOnActiveScreen()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        installKeyMonitor()

        DispatchQueue.main.async {
            ClipboardManager.shared.pruneExpiredEntries()
        }
    }

    func hide(restoreFocus: Bool = false) {
        panel.cancelCommandDragIfNeeded()
        guideOverlay.hideGuides()
        removeKeyMonitor()
        panel.orderOut(nil)
        if restoreFocus, let target = previousApp {
            NSApp.yieldActivation(to: target)
            target.activate()
        }
        // Tear down SwiftUI view tree and image caches once hidden so clipboard UI & thumbnails
        // do not stay resident in the background IME process.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.panel.contentView = nil
            ClipboardAppIconCache.clear()
            ClipboardManager.shared.clearImageCache()
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide(restoreFocus: false)
    }

    private func pasteAndDismiss(_ entry: ClipboardEntry) {
        let target = previousApp
        hide(restoreFocus: false)
        ClipboardManager.shared.pasteEntry(entry, into: target)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 780, height: 500)

        let defaults = UserDefaults.standard
        let offsetX: CGFloat = defaults.object(forKey: Self.offsetXKey) != nil
            ? CGFloat(defaults.double(forKey: Self.offsetXKey))
            : 0
        let offsetY: CGFloat = defaults.object(forKey: Self.offsetYKey) != nil
            ? CGFloat(defaults.double(forKey: Self.offsetYKey))
            : Self.defaultOffsetY

        var originX = round(visibleFrame.midX + offsetX - size.width / 2)
        var originY = round(visibleFrame.midY + offsetY - size.height / 2)

        // Clamp within visible screen bounds so the panel is always reachable
        if visibleFrame.width >= size.width {
            originX = min(max(originX, visibleFrame.minX), visibleFrame.maxX - size.width)
        } else {
            originX = round(visibleFrame.midX - size.width / 2)
        }
        if visibleFrame.height >= size.height {
            originY = min(max(originY, visibleFrame.minY), visibleFrame.maxY - size.height)
        } else {
            originY = round(visibleFrame.midY - size.height / 2)
        }

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
    }

    private func savePanelPosition(on screen: NSScreen, snappedToCenterX: Bool) {
        let visibleFrame = screen.visibleFrame
        let offsetX: Double = snappedToCenterX ? 0 : Double(panel.frame.midX - visibleFrame.midX)
        let offsetY: Double = Double(panel.frame.midY - visibleFrame.midY)
        let defaults = UserDefaults.standard
        defaults.set(offsetX, forKey: Self.offsetXKey)
        defaults.set(offsetY, forKey: Self.offsetYKey)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == [.command] && event.keyCode == 0x28 { // Cmd + K -> open actions menu
                if let entry = self.currentSelectedEntry() {
                    self.showActionsMenuForKeyboard(entry: entry)
                }
                return nil
            }
            switch event.keyCode {
            case 0x35: // Escape
                self.hide(restoreFocus: true)
                return nil
            case 0x7d: // Down Arrow
                self.moveSelection(delta: 1)
                return nil
            case 0x7e: // Up Arrow
                self.moveSelection(delta: -1)
                return nil
            case 0x24, 0x4c: // Return / Enter
                if let entry = self.currentSelectedEntry() {
                    self.pasteAndDismiss(entry)
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func showActionsMenuForKeyboard(entry: ClipboardEntry) {
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: "粘贴到 \(state.targetAppName)") { [weak self] in
            self?.pasteAndDismiss(entry)
        })
        menu.addItem(MenuActionItem(title: "仅复制到剪贴板") { [weak self] in
            ClipboardManager.shared.copyToPasteboard(entry)
            self?.hide(restoreFocus: true)
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "删除此条目") {
            ClipboardManager.shared.remove(id: entry.id)
        })
        menu.addItem(MenuActionItem(title: "清空全部记录") {
            ClipboardManager.shared.clearAll()
        })
        menu.update()
        let menuSize = menu.size
        let x = max(panel.frame.minX + 14, panel.frame.maxX - menuSize.width - 16)
        let topY = min(panel.frame.maxY - 14, panel.frame.minY + 56 + menuSize.height)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: topY), in: nil)
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func currentFilteredEntries() -> [ClipboardEntry] {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardManager.shared.entries.filter { entry in
            guard state.filterType.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            return entry.listTitle.localizedCaseInsensitiveContains(query)
                || (entry.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func currentSelectedEntry() -> ClipboardEntry? {
        let items = currentFilteredEntries()
        if let id = state.selectedEntryID, let match = items.first(where: { $0.id == id }) {
            return match
        }
        return items.first
    }

    private func moveSelection(delta: Int) {
        let items = currentFilteredEntries()
        guard !items.isEmpty else { return }
        if let id = state.selectedEntryID, let idx = items.firstIndex(where: { $0.id == id }) {
            let next = max(0, min(items.count - 1, idx + delta))
            state.selectedEntryID = items[next].id
        } else {
            state.selectedEntryID = items.first?.id
        }
        state.keyboardScrollTick &+= 1
    }
}
