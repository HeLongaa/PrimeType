import Cocoa
import Combine
import Darwin

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

private enum ClipboardAppIconCache {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static let maxCachedIcons = 24
    private static let fetchQueue = DispatchQueue(label: "com.lumocore.inputtype.clipboard.icons", qos: .userInitiated)

    static func cachedIcon(forBundleID bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleID]
    }

    static func loadIconAsync(forBundleID bundleID: String, completion: @escaping (NSImage?) -> Void) {
        if let hit = cachedIcon(forBundleID: bundleID) {
            completion(hit)
            return
        }
        fetchQueue.async {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let rawIcon = NSWorkspace.shared.icon(forFile: url.path)
            let targetSize = NSSize(width: 32, height: 32)
            let small = NSImage(size: targetSize, flipped: false) { rect in
                rawIcon.draw(in: rect)
                return true
            }
            lock.lock()
            if cache.count >= maxCachedIcons {
                cache.removeAll(keepingCapacity: false)
            }
            cache[bundleID] = small
            lock.unlock()
            DispatchQueue.main.async {
                completion(small)
            }
        }
    }

    static func clear() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
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

// MARK: - Pure AppKit Clipboard Content View (Zero SwiftUI, < 6ms Popup)

private enum ClipboardListRowModel {
    case section(String)
    case entry(ClipboardEntry)
}

private final class ClipboardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClipboardActionControlView: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class ClipboardContentNSView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let state: ClipboardPanelState
    private let onPaste: (ClipboardEntry) -> Void
    private let onDismiss: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    private var rows: [ClipboardListRowModel] = []
    private var filteredEntries: [ClipboardEntry] = []

    // Top bar
    private let backBtn = NSButton()
    private let searchField = NSTextField()
    private let filterBtn = NSButton()
    private let topDivider = NSView()

    // Left list
    private let listScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyListLabel = NSTextField(labelWithString: "")
    private var bottomLeftFilterGlass: NSView!
    private let bottomLeftFilterBtn = ClipboardActionControlView()
    private let splitDivider = NSView()

    // Right detail
    private let rightContainer = ClipboardFlippedView()
    private let previewImageView = NSImageView()
    private let previewTextScroll = NSScrollView()
    private let previewTextView = NSTextView()
    private let metadataStack = ClipboardFlippedView()
    private let emptyDetailLabel = NSTextField(labelWithString: "选择左侧条目查看详情")
    private var actionPillGlass: NSView!
    private let actionPillHost = ClipboardFlippedView()
    private let pasteActionBtn = ClipboardActionControlView()
    private let pasteTitleLabel = NSTextField(labelWithString: "")
    private let actionsMenuBtn = ClipboardActionControlView()
    private var activeDetailEntryID: UUID?

    override var isFlipped: Bool { true }

    init(
        state: ClipboardPanelState,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.state = state
        self.onPaste = onPaste
        self.onDismiss = onDismiss
        super.init(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupSubviews()
        bindState()
        reloadData(scrollToSelection: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func prepareForDisplay() {
        if searchField.stringValue != state.searchText {
            searchField.stringValue = state.searchText
        }
        reloadData(scrollToSelection: true)
    }

    func clearTransientPreview() {
        previewImageView.image = nil
    }

    private func setupSubviews() {
        // Top bar (height 54)
        backBtn.isBordered = false
        let chevCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        backBtn.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?.withSymbolConfiguration(chevCfg)
        backBtn.contentTintColor = .secondaryLabelColor
        backBtn.target = self
        backBtn.action = #selector(onBackTapped)
        addSubview(backBtn)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 19, weight: .regular)
        searchField.placeholderString = "输入以筛选条目..."
        searchField.delegate = self
        addSubview(searchField)

        filterBtn.isBordered = false
        filterBtn.bezelStyle = .inline
        filterBtn.target = self
        filterBtn.action = #selector(onTopFilterTapped)
        addSubview(filterBtn)

        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        addSubview(topDivider)

        // Left list (explicit `.plain` style prevents macOS 14+/26+ `.inset` from adding extra horizontal padding that clips rows)
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        col.width = 285
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(onTableSingleClick)
        tableView.doubleAction = #selector(onTableDoubleClick)

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder
        listScrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 54, right: 0)
        addSubview(listScrollView)

        emptyListLabel.font = .systemFont(ofSize: 13)
        emptyListLabel.textColor = .secondaryLabelColor
        emptyListLabel.alignment = .center
        emptyListLabel.isHidden = true
        addSubview(emptyListLabel)

        // Bottom-left floating native Liquid Glass circle button
        bottomLeftFilterBtn.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        bottomLeftFilterBtn.autoresizingMask = [.width, .height]
        bottomLeftFilterBtn.onClick = { [weak self] in self?.showFilterMenu() }
        let line1 = NSView(frame: NSRect(x: 10.5, y: 13.5, width: 13, height: 1.5))
        line1.wantsLayer = true
        line1.layer?.cornerRadius = 0.75
        line1.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        let line2 = NSView(frame: NSRect(x: 10.5, y: 19, width: 13, height: 1.5))
        line2.wantsLayer = true
        line2.layer?.cornerRadius = 0.75
        line2.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        bottomLeftFilterBtn.addSubview(line1)
        bottomLeftFilterBtn.addSubview(line2)
        bottomLeftFilterGlass = Self.wrapInLiquidGlass(bottomLeftFilterBtn, cornerRadius: 17)
        addSubview(bottomLeftFilterGlass)

        splitDivider.wantsLayer = true
        splitDivider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        addSubview(splitDivider)

        // Right detail container
        addSubview(rightContainer)

        previewImageView.imageScaling = .scaleProportionallyDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerCurve = .continuous
        previewImageView.layer?.cornerRadius = 10
        previewImageView.layer?.masksToBounds = true
        rightContainer.addSubview(previewImageView)

        previewTextScroll.hasVerticalScroller = true
        previewTextScroll.autohidesScrollers = true
        previewTextScroll.drawsBackground = false
        previewTextScroll.borderType = .noBorder
        previewTextScroll.wantsLayer = true
        previewTextScroll.layer?.cornerCurve = .continuous
        previewTextScroll.layer?.cornerRadius = 10
        previewTextScroll.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.font = .systemFont(ofSize: 14)
        previewTextView.textColor = .labelColor
        previewTextView.textContainerInset = NSSize(width: 14, height: 14)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.textContainer?.widthTracksTextView = true
        previewTextScroll.documentView = previewTextView
        rightContainer.addSubview(previewTextScroll)

        rightContainer.addSubview(metadataStack)

        emptyDetailLabel.font = .systemFont(ofSize: 13)
        emptyDetailLabel.textColor = .tertiaryLabelColor
        emptyDetailLabel.alignment = .center
        rightContainer.addSubview(emptyDetailLabel)

        // Floating bottom-right native Liquid Glass action pill
        actionPillHost.autoresizingMask = [.width, .height]

        pasteActionBtn.onClick = { [weak self] in
            if let entry = self?.selectedEntry() {
                self?.onPaste(entry)
            }
        }
        pasteTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pasteTitleLabel.textColor = .labelColor
        pasteActionBtn.addSubview(pasteTitleLabel)
        actionPillHost.addSubview(pasteActionBtn)

        actionsMenuBtn.onClick = { [weak self] in
            if let entry = self?.selectedEntry() {
                self?.showActionsMenu(for: entry)
            }
        }
        actionPillHost.addSubview(actionsMenuBtn)
        actionPillGlass = Self.wrapInLiquidGlass(actionPillHost, cornerRadius: 17)
        rightContainer.addSubview(actionPillGlass)
    }

    private static func wrapInLiquidGlass(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = cornerRadius
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.masksToBounds = true
            glass.contentView = content
            return glass
        } else {
            let effect = NSVisualEffectView(frame: content.frame)
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
            effect.layer?.borderWidth = 0.75
            content.frame = effect.bounds
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            return effect
        }
    }

    private func bindState() {
        ClipboardManager.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadData(scrollToSelection: false) }
            .store(in: &cancellables)

        state.$filterType
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadData(scrollToSelection: false) }
            .store(in: &cancellables)

        state.$searchText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                if self.searchField.stringValue != text {
                    self.searchField.stringValue = text
                }
                self.reloadData(scrollToSelection: false)
            }
            .store(in: &cancellables)

        state.$selectedEntryID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
                self?.refreshDetail()
            }
            .store(in: &cancellables)

        state.$keyboardScrollTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scrollToSelectedEntry() }
            .store(in: &cancellables)

        state.$targetAppName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshActionPill() }
            .store(in: &cancellables)
    }

    private func selectedEntry() -> ClipboardEntry? {
        if let id = state.selectedEntryID, let match = filteredEntries.first(where: { $0.id == id }) {
            return match
        }
        return filteredEntries.first
    }

    private func reloadData(scrollToSelection: Bool) {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredEntries = ClipboardManager.shared.entries.filter { entry in
            guard state.filterType.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            if entry.listTitle.localizedCaseInsensitiveContains(query) { return true }
            if let app = entry.sourceAppName, app.localizedCaseInsensitiveContains(query) { return true }
            return false
        }

        if let cur = state.selectedEntryID, !filteredEntries.contains(where: { $0.id == cur }) {
            state.selectedEntryID = filteredEntries.first?.id
        } else if state.selectedEntryID == nil {
            state.selectedEntryID = filteredEntries.first?.id
        }

        let order = ["今天", "昨天", "更早"]
        var dict: [String: [ClipboardEntry]] = [:]
        for item in filteredEntries {
            dict[item.dateSectionTitle, default: []].append(item)
        }
        var built: [ClipboardListRowModel] = []
        for title in order {
            if let items = dict[title], !items.isEmpty {
                built.append(.section(title))
                for item in items {
                    built.append(.entry(item))
                }
            }
        }
        rows = built

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        filterBtn.attributedTitle = NSAttributedString(string: "≡ \(state.filterType.rawValue) ▾", attributes: attrs)

        let isEmpty = filteredEntries.isEmpty
        listScrollView.isHidden = isEmpty
        emptyListLabel.isHidden = !isEmpty
        emptyListLabel.stringValue = InputSettings.shared.clipboardEnabled ? "暂无剪贴板条目" : "剪贴板记录未开启"

        tableView.reloadData()
        if scrollToSelection { scrollToSelectedEntry() }
        refreshDetail()
        needsLayout = true
    }

    private func scrollToSelectedEntry() {
        guard let targetID = state.selectedEntryID else { return }
        if let rowIdx = rows.firstIndex(where: {
            if case .entry(let e) = $0 { return e.id == targetID }
            return false
        }) {
            tableView.scrollRowToVisible(rowIdx)
        }
    }

    private func refreshDetail() {
        guard let entry = selectedEntry() else {
            activeDetailEntryID = nil
            previewImageView.isHidden = true
            previewImageView.image = nil
            previewTextScroll.isHidden = true
            metadataStack.isHidden = true
            actionPillGlass.isHidden = true
            emptyDetailLabel.isHidden = false
            return
        }

        activeDetailEntryID = entry.id
        emptyDetailLabel.isHidden = true
        metadataStack.isHidden = false
        actionPillGlass.isHidden = false

        if entry.kind == .image {
            previewTextScroll.isHidden = true
            previewImageView.isHidden = false
            if let cached = ClipboardManager.shared.cachedPreviewImage(for: entry) {
                previewImageView.image = cached
            } else {
                // Show tiny cached thumbnail immediately if available, then swap in 720px async
                previewImageView.image = ClipboardManager.shared.cachedThumbnailImage(for: entry)
                let targetID = entry.id
                ClipboardManager.shared.loadPreviewImageAsync(for: entry) { [weak self] img in
                    guard let self, self.activeDetailEntryID == targetID else { return }
                    self.previewImageView.image = img
                }
            }
        } else {
            previewImageView.isHidden = true
            previewImageView.image = nil
            previewTextScroll.isHidden = false
            previewTextView.string = entry.text ?? ""
            previewTextView.scrollToBeginningOfDocument(nil)
        }

        rebuildMetadata(for: entry)
        refreshActionPill()
        needsLayout = true
    }

    private func rebuildMetadata(for entry: ClipboardEntry) {
        for sub in metadataStack.subviews { sub.removeFromSuperview() }
        let rightW = rightContainer.bounds.width > 0 ? rightContainer.bounds.width : (780 - 286)
        let w = max(200, rightW - 36)
        var y: CGFloat = 0

        let header = NSTextField(labelWithString: "信息")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 0, y: y, width: w, height: 15)
        metadataStack.addSubview(header)
        y += 20

        var specs: [(label: String, value: String, bundleID: String?)] = []
        if let appName = entry.sourceAppName {
            specs.append(("来源", appName, entry.sourceAppBundleID))
        }
        specs.append(("种类", entry.kind.displayName, nil))
        if entry.kind == .image, let iw = entry.imageWidth, let ih = entry.imageHeight {
            specs.append(("尺寸", "\(iw)×\(ih)", nil))
        } else if let text = entry.text {
            specs.append(("字数", "\(text.count) 字符", nil))
        }
        specs.append(("大小", entry.formattedSize, nil))
        specs.append(("拷贝时间", entry.formattedTimestamp, nil))

        for (idx, row) in specs.enumerated() {
            let rowH: CGFloat = 26
            let keyLbl = NSTextField(labelWithString: row.label)
            keyLbl.font = .systemFont(ofSize: 12.5)
            keyLbl.textColor = .secondaryLabelColor
            keyLbl.frame = NSRect(x: 0, y: y + 5, width: 70, height: 16)
            metadataStack.addSubview(keyLbl)

            let valLbl = NSTextField(labelWithString: row.value)
            valLbl.font = .systemFont(ofSize: 12.5, weight: .medium)
            valLbl.textColor = .labelColor
            valLbl.alignment = .right
            valLbl.lineBreakMode = .byTruncatingTail
            let vw = min(w - 96, ceil(valLbl.fittingSize.width) + 2)
            valLbl.frame = NSRect(x: w - vw, y: y + 5, width: vw, height: 16)
            metadataStack.addSubview(valLbl)

            if let bundleID = row.bundleID {
                let iv = NSImageView(frame: NSRect(x: w - vw - 21, y: y + 5.5, width: 15, height: 15))
                iv.imageScaling = .scaleProportionallyUpOrDown
                metadataStack.addSubview(iv)
                if let cached = ClipboardAppIconCache.cachedIcon(forBundleID: bundleID) {
                    iv.image = cached
                } else {
                    let targetID = entry.id
                    ClipboardAppIconCache.loadIconAsync(forBundleID: bundleID) { [weak self, weak iv] icon in
                        guard let self, self.activeDetailEntryID == targetID, let iv else { return }
                        iv.image = icon
                    }
                }
            }

            y += rowH
            if idx < specs.count - 1 {
                let div = NSView(frame: NSRect(x: 0, y: y, width: w, height: 1))
                div.wantsLayer = true
                div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
                metadataStack.addSubview(div)
                y += 1
            }
        }
    }

    private func refreshActionPill() {
        for sub in pasteActionBtn.subviews where sub !== pasteTitleLabel { sub.removeFromSuperview() }
        for sub in actionsMenuBtn.subviews { sub.removeFromSuperview() }
        for sub in actionPillHost.subviews where sub !== pasteActionBtn && sub !== actionsMenuBtn { sub.removeFromSuperview() }

        pasteTitleLabel.stringValue = "粘贴到 \(state.targetAppName)"
        pasteTitleLabel.sizeToFit()
        let pW = ceil(pasteTitleLabel.fittingSize.width)

        let retBadge = makeKeyBadge("↵", tint: .labelColor)
        let leftW = pW + 6 + retBadge.frame.width
        pasteActionBtn.frame = NSRect(x: 14, y: 0, width: leftW, height: 34)
        pasteTitleLabel.frame = NSRect(x: 0, y: 9, width: pW, height: 16)
        retBadge.frame.origin = NSPoint(x: pW + 6, y: round((34 - retBadge.frame.height) * 0.5))
        pasteActionBtn.addSubview(retBadge)

        let divX = 14 + leftW + 12
        let div = NSView(frame: NSRect(x: divX, y: 9, width: 1, height: 16))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        actionPillHost.addSubview(div)

        let opsLbl = NSTextField(labelWithString: "操作")
        opsLbl.font = .systemFont(ofSize: 13)
        opsLbl.textColor = .secondaryLabelColor
        opsLbl.sizeToFit()
        let oW = ceil(opsLbl.fittingSize.width)
        let cmdBadge = makeKeyBadge("⌘", tint: .secondaryLabelColor)
        let kBadge = makeKeyBadge("K", tint: .secondaryLabelColor)
        let rightW = oW + 5 + cmdBadge.frame.width + 4 + kBadge.frame.width

        actionsMenuBtn.frame = NSRect(x: divX + 13, y: 0, width: rightW, height: 34)
        opsLbl.frame = NSRect(x: 0, y: 9, width: oW, height: 16)
        cmdBadge.frame.origin = NSPoint(x: oW + 5, y: round((34 - cmdBadge.frame.height) * 0.5))
        kBadge.frame.origin = NSPoint(x: cmdBadge.frame.maxX + 4, y: round((34 - kBadge.frame.height) * 0.5))
        actionsMenuBtn.addSubview(opsLbl)
        actionsMenuBtn.addSubview(cmdBadge)
        actionsMenuBtn.addSubview(kBadge)

        let totalW = divX + 13 + rightW + 14
        let rightWContainer = rightContainer.bounds.width > 0 ? rightContainer.bounds.width : (780 - 286)
        let rightHContainer = rightContainer.bounds.height > 0 ? rightContainer.bounds.height : (500 - 55)
        actionPillGlass.frame = NSRect(x: rightWContainer - 16 - totalW, y: rightHContainer - 14 - 34, width: totalW, height: 34)
        actionPillHost.frame = actionPillGlass.bounds
    }

    private func makeKeyBadge(_ key: String, tint: NSColor) -> NSView {
        let lbl = NSTextField(labelWithString: key)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = tint
        lbl.alignment = .center
        lbl.sizeToFit()
        let w = ceil(lbl.fittingSize.width) + 10
        let h = ceil(lbl.fittingSize.height) + 4
        let box = ClipboardFlippedView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.cornerRadius = 4
        box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.26).cgColor
        box.layer?.borderWidth = 0.75
        lbl.frame = NSRect(x: 5, y: 2, width: ceil(lbl.fittingSize.width), height: ceil(lbl.fittingSize.height))
        box.addSubview(lbl)
        return box
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let topH: CGFloat = 54
        let leftW: CGFloat = 285

        // Top bar
        backBtn.frame = NSRect(x: 18, y: 15, width: 24, height: 24)
        let fSize = filterBtn.fittingSize
        let fw = ceil(fSize.width) + 10
        filterBtn.frame = NSRect(x: w - 18 - fw, y: 16, width: fw, height: 22)
        searchField.frame = NSRect(x: 52, y: 14, width: max(100, filterBtn.frame.minX - 64), height: 26)
        topDivider.frame = NSRect(x: 0, y: topH, width: w, height: 1)

        // Split content
        let bodyY = topH + 1
        let bodyH = h - bodyY
        listScrollView.frame = NSRect(x: 0, y: bodyY, width: leftW, height: bodyH)
        tableView.tableColumns.first?.width = leftW
        emptyListLabel.frame = NSRect(x: 16, y: bodyY + round((bodyH - 22) * 0.5), width: leftW - 32, height: 22)
        bottomLeftFilterGlass.frame = NSRect(x: 14, y: h - 14 - 34, width: 34, height: 34)
        bottomLeftFilterBtn.frame = bottomLeftFilterGlass.bounds
        splitDivider.frame = NSRect(x: leftW, y: bodyY, width: 1, height: bodyH)

        // Right detail
        let rx = leftW + 1
        let rw = w - rx
        rightContainer.frame = NSRect(x: rx, y: bodyY, width: rw, height: bodyH)
        emptyDetailLabel.frame = NSRect(x: 20, y: round((bodyH - 22) * 0.5), width: rw - 40, height: 22)

        let metaH: CGFloat = 158
        let previewH = max(120, bodyH - 16 - 10 - metaH - 62)
        let previewRect = NSRect(x: 18, y: 16, width: rw - 36, height: previewH)
        previewImageView.frame = previewRect
        previewTextScroll.frame = previewRect
        previewTextView.frame = NSRect(x: 0, y: 0, width: previewRect.width, height: max(previewRect.height, previewTextView.frame.height))
        metadataStack.frame = NSRect(x: 18, y: previewRect.maxY + 10, width: rw - 36, height: metaH)
        if let entry = selectedEntry() {
            rebuildMetadata(for: entry)
        }
        refreshActionPill()
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section: return 26
        case .entry: return 40
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(let title):
            let rowW = max(120, tableView.bounds.width)
            let cell = NSView(frame: NSRect(x: 0, y: 0, width: rowW, height: 26))
            cell.autoresizingMask = [.width]
            let lbl = NSTextField(labelWithString: title)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = .secondaryLabelColor
            lbl.frame = NSRect(x: 16, y: 4, width: rowW - 32, height: 16)
            lbl.autoresizingMask = [.width]
            cell.addSubview(lbl)
            return cell

        case .entry(let entry):
            let isSelected = (selectedEntry()?.id == entry.id)
            let rowW = max(120, tableView.bounds.width)
            let cell = NSView(frame: NSRect(x: 0, y: 0, width: rowW, height: 40))
            cell.autoresizingMask = [.width]

            let bg = NSView(frame: NSRect(x: 8, y: 1, width: rowW - 16, height: 38))
            bg.autoresizingMask = [.width]
            bg.wantsLayer = true
            bg.layer?.cornerCurve = .continuous
            bg.layer?.cornerRadius = 10
            bg.layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor
            cell.addSubview(bg)

            let iconBox = NSView(frame: NSRect(x: 10, y: 7, width: 24, height: 24))
            iconBox.wantsLayer = true
            iconBox.layer?.cornerCurve = .continuous
            iconBox.layer?.cornerRadius = 6
            iconBox.layer?.masksToBounds = true

            if entry.kind == .image {
                let thumbLayerHost = NSView(frame: iconBox.bounds)
                thumbLayerHost.wantsLayer = true
                thumbLayerHost.layer?.contentsGravity = .resizeAspectFill
                thumbLayerHost.layer?.masksToBounds = true
                iconBox.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                iconBox.layer?.borderWidth = 0.5
                iconBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
                iconBox.addSubview(thumbLayerHost)
                if let thumb = ClipboardManager.shared.cachedThumbnailImage(for: entry) {
                    thumbLayerHost.layer?.contents = thumb
                } else {
                    ClipboardManager.shared.loadThumbnailImageAsync(for: entry) { [weak thumbLayerHost] loaded in
                        thumbLayerHost?.layer?.contents = loaded
                    }
                }
            } else {
                iconBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                let iv = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                iv.image = NSImage(systemSymbolName: entry.kind.systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
                iv.contentTintColor = .secondaryLabelColor
                iv.imageScaling = .scaleProportionallyDown
                iconBox.addSubview(iv)
            }
            bg.addSubview(iconBox)

            let lbl = NSTextField(labelWithString: entry.listTitle)
            lbl.font = .systemFont(ofSize: 13.5)
            lbl.textColor = .labelColor
            lbl.lineBreakMode = .byTruncatingTail
            lbl.frame = NSRect(x: 44, y: 11, width: max(40, bg.bounds.width - 54), height: 17)
            lbl.autoresizingMask = [.width]
            bg.addSubview(lbl)

            return cell
        }
    }

    @objc private func onTableSingleClick() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count else { return }
        if case .entry(let entry) = rows[row] {
            state.selectedEntryID = entry.id
        }
    }

    @objc private func onTableDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count else { return }
        if case .entry(let entry) = rows[row] {
            state.selectedEntryID = entry.id
            onPaste(entry)
        }
    }

    // MARK: - Search & Menus

    func controlTextDidChange(_ obj: Notification) {
        state.searchText = searchField.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let entry = selectedEntry() {
                onPaste(entry)
            }
            return true
        }
        return false
    }

    @objc private func onBackTapped() {
        if !state.searchText.isEmpty {
            state.searchText = ""
            searchField.stringValue = ""
        } else {
            onDismiss()
        }
    }

    @objc private func onTopFilterTapped() {
        let menu = NSMenu()
        for type in ClipboardFilterType.allCases {
            let item = MenuActionItem(title: type.rawValue) { [weak self] in
                self?.state.filterType = type
            }
            item.state = (state.filterType == type) ? .on : .off
            menu.addItem(item)
        }
        let pt = NSPoint(x: 0, y: filterBtn.bounds.height + 4)
        menu.popUp(positioning: nil, at: pt, in: filterBtn)
    }

    private func showFilterMenu() {
        let menu = NSMenu()
        for type in ClipboardFilterType.allCases {
            let item = MenuActionItem(title: type.rawValue) { [weak self] in
                self?.state.filterType = type
            }
            item.state = (state.filterType == type) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "清空全部剪贴板记录") {
            ClipboardManager.shared.clearAll()
        })
        popUpMenuInsidePanel(menu, alignRight: false)
    }

    private func showActionsMenu(for entry: ClipboardEntry) {
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: "粘贴到 \(state.targetAppName)") { [weak self] in
            self?.onPaste(entry)
        })
        menu.addItem(MenuActionItem(title: "仅复制到剪贴板") { [weak self] in
            ClipboardManager.shared.copyToPasteboard(entry)
            self?.onDismiss()
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "删除此条目") {
            ClipboardManager.shared.remove(id: entry.id)
        })
        menu.addItem(MenuActionItem(title: "清空全部记录") {
            ClipboardManager.shared.clearAll()
        })
        popUpMenuInsidePanel(menu, alignRight: true)
    }

    private func popUpMenuInsidePanel(_ menu: NSMenu, alignRight: Bool) {
        guard let window = self.window else { return }
        menu.update()
        let menuSize = menu.size
        let panelFrame = window.frame
        let x: CGFloat = alignRight
            ? max(panelFrame.minX + 14, panelFrame.maxX - menuSize.width - 16)
            : (panelFrame.minX + 14)
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
    private var activeContentNSView: ClipboardContentNSView?
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
        guard activeContentNSView == nil else { return }
        let contentView = ClipboardContentNSView(
            state: state,
            onPaste: { [weak self] entry in
                self?.pasteAndDismiss(entry)
            },
            onDismiss: { [weak self] in
                self?.hide(restoreFocus: true)
            }
        )
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.cornerRadius = 20
        contentView.layer?.masksToBounds = true
        contentView.autoresizingMask = [.width, .height]
        self.activeContentNSView = contentView

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 20
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 20
            glass.layer?.masksToBounds = true
            glass.contentView = contentView
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = 20
            contentView.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: effect.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            panel.contentView = effect
        }
    }

    /// Pre-warms the pure-AppKit panel, Liquid Glass backdrop, recent thumbnails, and app icons off-screen
    /// so even the very first hotkey press opens in < 5ms.
    func warmUp() {
        attachContentViewIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        ClipboardManager.shared.prewarmRecentThumbnails(limit: 12)
        let bundleIDs = Set(ClipboardManager.shared.entries.prefix(8).compactMap(\.sourceAppBundleID))
        for bid in bundleIDs {
            ClipboardAppIconCache.loadIconAsync(forBundleID: bid) { _ in }
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
        activeContentNSView?.prepareForDisplay()
        positionOnActiveScreen()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        activeContentNSView?.focusSearchField()
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
        // Keep the lightweight pure-AppKit view tree & 64px thumbnails warm for instant < 5ms reopen;
        // only release large 720px detail preview buffers and return freed pages to macOS.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.activeContentNSView?.clearTransientPreview()
            ClipboardManager.shared.clearPreviewImageCache()
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
