import Cocoa
import InputMethodKit

@objc(InputTypeController)
final class InputTypeController: IMKInputController {
    static weak var latestActiveController: InputTypeController?
    static weak var latestActiveClient: (any IMKTextInput)?
    static var isServerCurrentlyActive: Bool = false
    static var latestActiveBundleID: String?
    private static var lastAppliedAppearanceName: String?
    private static var cachedAppearanceByBundleID: [String: (appearance: NSAppearance, timestamp: TimeInterval)] = [:]
    private static var cachedEditorStorageTheme: [String: (mtime: Date, appearance: NSAppearance?)] = [:]
    private static var lastKnownCursorRect: NSRect?
    private static var lastKnownCursorBundleID: String?

    /// Trims bounded UI appearance caches during idle memory pressure relief.
    static func trimCachesIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if cachedAppearanceByBundleID.count > 24 {
            cachedAppearanceByBundleID = cachedAppearanceByBundleID.filter { (now - $0.value.timestamp) < 60.0 }
            if cachedAppearanceByBundleID.count > 24 {
                cachedAppearanceByBundleID.removeAll(keepingCapacity: false)
            }
        }
        if cachedEditorStorageTheme.count > 12 {
            cachedEditorStorageTheme.removeAll(keepingCapacity: false)
        }
    }

    private var sessionId: RimeSessionId = 0
    private var engineGeneration: UInt64 = 0
    private weak var currentClient: (any IMKTextInput)?
    private var pendingCommandKeyCode: UInt16?
    private var currentPreedit: String = ""
    private var currentPreeditSelStart: Int = 0
    private var currentCandidates: [RimeCandidateItem] = []
    private var currentRimeCandidates: [RimeCandidateItem] = []
    private var currentPresentedCandidates: [PresentedCandidate] = []
    private var currentDirectCommitTexts: Set<String> = []
    private var asciiComposingBuffer: String? = nil
    private var isVModeActive = false
    private var isPreeditAllSelected = false
    private var isNavigatingCandidates = false
    private let queryCoordinator = QueryCoordinator(debounceMs: 45, timeoutMs: 200)
    private let candidatePresenter = CandidatePresenter(lockFirstWindowSeconds: 0.15, top1LeadThreshold: 0.15)

    // Context trackers for smart spacing, symbol conversion, and auto-numbering
    private var lastCommittedChar: Character?
    private var currentLineBuffer: String = ""

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        ensureValidSession()
        let client = inputClient as? (any IMKTextInput)
        registerActiveClient(client)
    }

    private func registerActiveClient(_ client: (any IMKTextInput)?) {
        guard let client else { return }
        currentClient = client
        let bundleId = client.bundleIdentifier()
        if bundleId != Bundle.main.bundleIdentifier {
            Self.latestActiveController = self
            Self.latestActiveClient = client
            Self.isServerCurrentlyActive = true
            if let bundleId {
                Self.latestActiveBundleID = bundleId
            }
        }
    }

    deinit {
        // Shared Rime session is owned by RimeEngine; do not destroy it when a background controller deallocates.
    }

    private func ensureValidSession() {
        let gen = RimeEngine.shared.generation
        if sessionId == 0 || engineGeneration != gen {
            queryCoordinator.cancelAll()
            candidatePresenter.reset()
            sessionId = RimeEngine.shared.sharedSession()
            engineGeneration = gen
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            asciiComposingBuffer = nil
            isPreeditAllSelected = false
            isNavigatingCandidates = false
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        let switchingController = Self.latestActiveController !== self
        ensureValidSession()
        if switchingController {
            queryCoordinator.cancelAll()
            candidatePresenter.reset()
            if sessionId != 0 {
                RimeEngine.shared.clearComposition(sessionId: sessionId)
            }
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            asciiComposingBuffer = nil
            isPreeditAllSelected = false
            isNavigatingCandidates = false
        }
        let client = sender as? (any IMKTextInput)
        registerActiveClient(client)
        resetInputContextTracking()

        let bundleId = client?.bundleIdentifier()
        // Pure Pinyin input method: always keep Rime ascii_mode disabled
        RimeEngine.shared.setAsciiMode(sessionId: sessionId, enabled: false)

        if let candidatesWin = AppDelegate.sharedCandidates {
            syncCandidateAppearance(candidatesWin: candidatesWin, client: client)
        }

        if let client,
           let pendingText = ClipboardManager.shared.consumePendingIMKTextPaste(forBundleID: bundleId) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                client.insertText(pendingText, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                self?.updateTracking(appending: pendingText)
            }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        queryCoordinator.cancelAll()
        candidatePresenter.reset()
        let wasActiveController = Self.latestActiveController === self
        if wasActiveController {
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontBundle != Bundle.main.bundleIdentifier {
                Self.isServerCurrentlyActive = false
            }
        }
        if isVModeActive {
            exitVMode(client: sender as? (any IMKTextInput) ?? currentClient, clearMarked: true)
        }
        if wasActiveController || !currentPreedit.isEmpty || asciiComposingBuffer != nil {
            commitComposition(sender)
        }
        resetInputContextTracking()
        if wasActiveController {
            hideCandidatesImmediately()
        }
        MemoryPressureManager.shared.noteInputDeactivated()
        super.deactivateServer(sender)
    }

    @discardableResult
    func insertClipboardTextDirectly(_ text: String) -> Bool {
        guard !text.isEmpty, let client = currentClient ?? Self.latestActiveClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        updateTracking(appending: text)
        return true
    }

    static func activeCursorRect(
        forBundleID expectedBundleID: String?,
        client explicitClient: (any IMKTextInput)? = nil,
        allowAXFallback: Bool = true
    ) -> NSRect? {
        guard let client = explicitClient ?? (isServerCurrentlyActive ? latestActiveClient : nil) else {
            return nil
        }
        let clientBundleID = client.bundleIdentifier()
        if let expectedBundleID,
           let clientBundleID,
           clientBundleID != expectedBundleID {
            return nil
        }

        func isValidCursorRect(_ rect: NSRect) -> Bool {
            guard rect.origin.x != 0 || rect.origin.y != 0 else { return false }
            guard rect.origin.x.isFinite && rect.origin.y.isFinite else { return false }
            let probe = NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: max(rect.width, 1),
                height: max(rect.height, 18)
            )
            return NSScreen.screens.contains { $0.frame.intersects(probe) || $0.frame.contains(rect.origin) }
        }

        func normalizedCursorRect(_ rect: NSRect) -> NSRect {
            NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: max(rect.width, 1),
                height: max(rect.height, 18)
            )
        }

        // 1. Try querying IMKTextInput across candidate indices:
        //    Index 0 is the marked-text origin used by IMKCandidates (critical for Electron/Chromium);
        //    selRange.location and selRange.location - 1 cover non-composing carets in native views.
        let selRange = client.selectedRange()
        var candidateIndices: [Int] = [0]
        if selRange.location != NSNotFound && selRange.location >= 0 {
            if !candidateIndices.contains(selRange.location) {
                candidateIndices.append(selRange.location)
            }
            if selRange.location > 0 && !candidateIndices.contains(selRange.location - 1) {
                candidateIndices.append(selRange.location - 1)
            }
        }

        for idx in candidateIndices {
            var lineRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: idx, lineHeightRectangle: &lineRect)
            if isValidCursorRect(lineRect) {
                let norm = normalizedCursorRect(lineRect)
                lastKnownCursorRect = norm
                lastKnownCursorBundleID = clientBundleID ?? expectedBundleID
                return norm
            }

            var actual = NSRange(location: NSNotFound, length: 0)
            let first = client.firstRect(
                forCharacterRange: NSRange(location: idx, length: 0),
                actualRange: &actual
            )
            if isValidCursorRect(first) {
                let norm = normalizedCursorRect(first)
                lastKnownCursorRect = norm
                lastKnownCursorBundleID = clientBundleID ?? expectedBundleID
                return norm
            }
        }

        // 2. Fallback to the live or most recent IMKCandidates window position if available
        if let candidatesWin = AppDelegate.sharedCandidates,
           let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController,
           let win = ctrl.window,
           win.frame.origin.x != 0 || win.frame.origin.y != 0 {
            let inferred = NSRect(x: win.frame.minX, y: win.frame.maxY + 4, width: 1, height: 20)
            if isValidCursorRect(inferred) && (lastKnownCursorBundleID == nil || lastKnownCursorBundleID == (clientBundleID ?? expectedBundleID)) {
                lastKnownCursorRect = inferred
                lastKnownCursorBundleID = clientBundleID ?? expectedBundleID
                return inferred
            }
        }

        // 3. Fallback to cached cursor rect from the same app during recent typing
        let targetBundle = clientBundleID ?? expectedBundleID
        if let cached = lastKnownCursorRect,
           targetBundle == nil || lastKnownCursorBundleID == targetBundle {
            return cached
        }

        // 4. Fallback to Accessibility focused UI element caret / bounds (only on-demand, never per-keystroke)
        if allowAXFallback,
           let axRect = queryAXFocusedCaretOrElementRect(forBundleID: targetBundle), isValidCursorRect(axRect) {
            let norm = normalizedCursorRect(axRect)
            lastKnownCursorRect = norm
            lastKnownCursorBundleID = targetBundle
            return norm
        }

        return nil
    }

    /// Returns the union screen rect (AppKit coordinates) covering the entire active text selection
    /// across multiple lines, falling back to `activeCursorRect` when there is no selection range.
    static func activeSelectionRect(
        forBundleID expectedBundleID: String?,
        client explicitClient: (any IMKTextInput)? = nil
    ) -> NSRect? {
        guard let client = explicitClient ?? (isServerCurrentlyActive ? latestActiveClient : nil) else {
            return nil
        }
        let clientBundleID = client.bundleIdentifier()
        if let expectedBundleID,
           let clientBundleID,
           clientBundleID != expectedBundleID {
            return nil
        }

        func isValidRect(_ rect: NSRect) -> Bool {
            guard rect.origin.x != 0 || rect.origin.y != 0 else { return false }
            guard rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite else { return false }
            let probe = NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: max(rect.width, 1),
                height: max(rect.height, 14)
            )
            return NSScreen.screens.contains { $0.frame.intersects(probe) || $0.frame.contains(rect.origin) }
        }

        func normalized(_ rect: NSRect) -> NSRect {
            NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: max(rect.width, 1),
                height: max(rect.height, 18)
            )
        }

        let selRange = client.selectedRange()
        guard selRange.location != NSNotFound, selRange.location >= 0, selRange.length > 0 else {
            return activeCursorRect(forBundleID: expectedBundleID, client: client)
        }

        var unionRect: NSRect?
        func include(_ rect: NSRect) {
            guard isValidRect(rect) else { return }
            let norm = normalized(rect)
            unionRect = unionRect.map { $0.union(norm) } ?? norm
        }

        // 1. Walk line-by-line across the selected range using firstRect(forCharacterRange:actualRange:)
        let selEnd = selRange.location + selRange.length
        var cursor = selRange.location
        var steps = 0
        while cursor < selEnd && steps < 32 {
            steps += 1
            var actual = NSRange(location: NSNotFound, length: 0)
            let rect = client.firstRect(
                forCharacterRange: NSRange(location: cursor, length: selEnd - cursor),
                actualRange: &actual
            )
            include(rect)
            if actual.location != NSNotFound && actual.length > 0 {
                let next = actual.location + actual.length
                if next <= cursor { break }
                cursor = next
            } else {
                break
            }
        }

        // 2. Explicitly probe the start and end indices so clients that ignore length > 0 still report the last line
        let endProbeIndices = [selRange.location, max(selRange.location, selEnd - 1), selEnd]
        for idx in endProbeIndices {
            var lineRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: idx, lineHeightRectangle: &lineRect)
            include(lineRect)

            var actual = NSRange(location: NSNotFound, length: 0)
            let first = client.firstRect(
                forCharacterRange: NSRange(location: idx, length: 0),
                actualRange: &actual
            )
            include(first)
        }

        return unionRect ?? activeCursorRect(forBundleID: expectedBundleID, client: client)
    }

    private static func queryAXFocusedCaretOrElementRect(forBundleID bundleID: String?) -> NSRect? {
        let app: NSRunningApplication?
        if let bundleID {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedObj = focusedRef,
              CFGetTypeID(focusedObj) == AXUIElementGetTypeID() else {
            return nil
        }
        let el = focusedObj as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.12)

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900

        // Try exact selected text range bounds first
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeVal = rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeVal,
                &boundsRef
            ) == .success,
               let boundsVal = boundsRef,
               CFGetTypeID(boundsVal) == AXValueGetTypeID() {
                var cgRect = CGRect.zero
                if AXValueGetValue(boundsVal as! AXValue, .cgRect, &cgRect),
                   (cgRect.origin.x != 0 || cgRect.origin.y != 0) {
                    let h = max(cgRect.height, 18)
                    let appKitY = primaryScreenHeight - cgRect.origin.y - h
                    return NSRect(x: cgRect.origin.x, y: appKitY, width: max(cgRect.width, 1), height: h)
                }
            }
        }

        // Fallback to the focused input element's own top-left area
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let posVal = posRef, let sizeVal = sizeRef,
           CFGetTypeID(posVal) == AXValueGetTypeID(),
           CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            var sz = CGSize.zero
            if AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
               AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
               (pt.x != 0 || pt.y != 0), sz.height > 0, sz.height < 260 {
                let appKitY = primaryScreenHeight - pt.y - min(sz.height, 28)
                return NSRect(x: pt.x + 12, y: appKitY, width: 1, height: min(sz.height, 24))
            }
        }
        return nil
    }

    @discardableResult
    func updateVoiceMarkedText(_ text: String) -> Bool {
        guard let client = currentClient ?? Self.latestActiveClient else { return false }
        let attrStr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)
        if range.length > 0,
           let attrs = mark(forStyle: Int(kTSMHiliteConvertedText), at: range) as? [NSAttributedString.Key: Any] {
            attrStr.setAttributes(attrs, range: range)
        }
        client.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        return true
    }

    func clearVoiceMarkedText() {
        guard let client = currentClient ?? Self.latestActiveClient else { return }
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func cancelComposition() {
        queryCoordinator.cancelAll()
        candidatePresenter.reset()
        let targetClient = currentClient
        if isVModeActive {
            exitVMode(client: targetClient, clearMarked: true)
        }
        let hadMarked = !currentPreedit.isEmpty || asciiComposingBuffer != nil
        asciiComposingBuffer = nil
        if sessionId != 0 && (hadMarked || Self.latestActiveController === self) {
            RimeEngine.shared.clearComposition(sessionId: sessionId)
        }
        currentPreedit = ""
        currentCandidates = []
        currentRimeCandidates = []
        currentPresentedCandidates = []
        currentDirectCommitTexts = []
        if hadMarked {
            clearMarkedText(client: targetClient)
        }
        hideCandidatesImmediately()
        super.cancelComposition()
    }

    override func commitComposition(_ sender: Any!) {
        queryCoordinator.cancelAll()
        candidatePresenter.reset()
        let targetClient = sender as? (any IMKTextInput) ?? currentClient
        if isVModeActive {
            exitVMode(client: targetClient, clearMarked: true)
        }
        if let asciiBuffer = asciiComposingBuffer {
            asciiComposingBuffer = nil
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            hideCandidatesImmediately()
            if !asciiBuffer.isEmpty {
                insertProcessedText(asciiBuffer, client: targetClient, allowAutoPair: false)
            } else {
                clearMarkedText(client: targetClient)
            }
            return
        }
        guard sessionId != 0 else { return }
        let hadPreedit = !currentPreedit.isEmpty
        guard hadPreedit || Self.latestActiveController === self else {
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            return
        }
        var didCommit = false
        if RimeEngine.shared.commitComposition(sessionId: sessionId) {
            if let commitText = RimeEngine.shared.getCommitText(sessionId: sessionId), !commitText.isEmpty {
                insertProcessedText(commitText, client: targetClient, allowAutoPair: false)
                didCommit = true
            }
        }
        RimeEngine.shared.clearComposition(sessionId: sessionId)
        currentPreedit = ""
        currentCandidates = []
        currentRimeCandidates = []
        currentPresentedCandidates = []
        currentDirectCommitTexts = []
        // Per Apple IMKTextInput contract, insertText already replaces marked text and unmarks it.
        // Only send setMarkedText("") when clearing an uncommitted composition.
        if hadPreedit && !didCommit {
            clearMarkedText(client: targetClient)
        }
        hideCandidatesImmediately()
    }

    private func resetInputContextTracking() {
        lastCommittedChar = nil
        currentLineBuffer = ""
    }

    // MARK: - Native IMKCandidates DataSource & Callbacks

    override func candidates(_ sender: Any!) -> [Any]! {
        return currentCandidates.map { $0.text }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string, !text.isEmpty else { return }
        commitCandidate(withText: text, client: currentClient)
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        // Highlight state is managed natively by IMKCandidates
    }

    // MARK: - Key Event Handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let client = (sender as? (any IMKTextInput)) ?? currentClient
        registerActiveClient(client)

        ensureValidSession()

        if event.type == .flagsChanged {
            VoiceInputManager.shared.handleFlagsChangedEvent(event)
            TranslateManager.shared.handleFlagsChangedEvent(event)
            return handleFlagsChanged(event, client: client)
        }

        guard event.type == .keyDown else { return false }
        let keystrokeStartAt = CFAbsoluteTimeGetCurrent()
        MemoryPressureManager.shared.noteTypingActivity()
        candidatePresenter.noteKeystroke(now: keystrokeStartAt)
        queryCoordinator.cancelAll()
        pendingCommandKeyCode = nil

        if VoiceInputManager.shared.handleKeyDownEvent(event) {
            return true
        }
        if TranslateManager.shared.handleKeyDownEvent(event) {
            return true
        }

        // Global state toggle shortcuts (Option + Shift + F / H / .)
        if handleStateToggleShortcuts(event, client: client) {
            return true
        }

        // Cmd + A while composing selects the entire composing pinyin so Backspace/Delete removes only the preedit
        let allMods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if allMods == [.command] && event.keyCode == 0x00 && !currentPreedit.isEmpty && !isVModeActive && asciiComposingBuffer == nil {
            isPreeditAllSelected = true
            isNavigatingCandidates = false
            selectAllMarkedPreedit(client: client)
            return true
        }

        // Pass through Command shortcuts directly to the app and reset context tracking
        if event.modifierFlags.contains(.command) {
            isPreeditAllSelected = false
            isNavigatingCandidates = false
            if isVModeActive {
                exitVMode(client: client, clearMarked: true)
            }
            if asciiComposingBuffer != nil {
                exitASCIIComposingMode(client: client, clearMarked: true)
            }
            resetInputContextTracking()
            return false
        }

        // When the composing pinyin was selected via Cmd + A:
        // - Backspace / Delete / Escape clears only the composing pinyin
        // - Typing a new printable character replaces the old composing pinyin
        if isPreeditAllSelected {
            isPreeditAllSelected = false
            if event.keyCode == 0x33 || event.keyCode == 0x75 || event.keyCode == 0x35 {
                clearActiveRimeComposition(client: client)
                return true
            }
            let nonShift = event.modifierFlags.intersection([.control, .option, .command])
            if nonShift.isEmpty,
               let chars = event.characters,
               let scalar = chars.unicodeScalars.first,
               scalar.value >= 0x21 && scalar.value <= 0x7e {
                RimeEngine.shared.clearComposition(sessionId: sessionId)
                currentPreedit = ""
                currentCandidates = []
                currentRimeCandidates = []
                currentPresentedCandidates = []
                currentDirectCommitTexts = []
                isNavigatingCandidates = false
            }
        }

        // V-Mode quick action menu / calculator / phrases / symbols / datetime
        if isVModeActive {
            return handleVModeKey(event, client: client)
        }

        // Email (@) and URL/Domain (.) smart completion composing mode
        if asciiComposingBuffer != nil {
            return handleASCIIComposingKey(event, client: client)
        }

        // Enter Email (@) or URL/Domain (.) smart completion from active Rime composition
        if !currentPreedit.isEmpty, shouldEnterASCIIComposingMode(for: event, client: client) {
            return true
        }

        // When composing, handle selection, paging, navigation, and grid expand/collapse directly
        if !currentPreedit.isEmpty, let candidatesWin = AppDelegate.sharedCandidates {
            if let handled = handleComposingCandidateKey(event, candidatesWin: candidatesWin, client: client) {
                return handled
            }
        }

        // Non-composing smart input features
        if currentPreedit.isEmpty {
            if let handled = handleNonComposingFeatures(event, client: client) {
                return handled
            }
        }

        guard let keyCode = KeyCodeMapper.rimeKeyCode(from: event) else {
            return false
        }
        let modifiers = KeyCodeMapper.rimeModifiers(from: event.modifierFlags)

        let wasComposingBeforeKey = !currentPreedit.isEmpty
        isNavigatingCandidates = false
        let rimeStart = CFAbsoluteTimeGetCurrent()
        let handled = RimeEngine.shared.processKey(sessionId: sessionId, keyCode: keyCode, mask: modifiers)
        let rimeProcessMs = (CFAbsoluteTimeGetCurrent() - rimeStart) * 1000.0
        syncRimeState(client: client, keystrokeStartAt: keystrokeStartAt, rimeProcessMs: rimeProcessMs)

        // macOS IMKInputController never delivers keyUp events. When Backspace clears the last
        // composing character, emit a synthetic BackSpace release so Lua processors (e.g. wanxiang
        // super_processor's backspace limiter) reset their hold sequence cleanly.
        if wasComposingBeforeKey && currentPreedit.isEmpty && event.keyCode == 0x33 {
            _ = RimeEngine.shared.processKey(
                sessionId: sessionId,
                keyCode: KeyCodeMapper.XK_BackSpace,
                mask: modifiers | KeyCodeMapper.kReleaseMask
            )
        }

        if !handled && currentPreedit.isEmpty {
            return trackOrTransformUnhandledKey(event, client: client)
        }
        return handled
    }

    // MARK: - Non-Composing Smart Features

    private func handleNonComposingFeatures(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool? {
        let settings = InputSettings.shared
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])

        // Backspace / Forward Delete when NOT composing must ALWAYS pass straight through to the host app.
        // Never route them into Rime, otherwise Lua processors expecting keyUp events (like wanxiang's
        // enable_backspace_limit) can swallow Backspace and make deletion stop working (e.g. in Spotlight).
        if event.keyCode == 0x33 || event.keyCode == 0x75 {
            if event.keyCode == 0x33 && mods.isEmpty {
                if !currentLineBuffer.isEmpty {
                    currentLineBuffer.removeLast()
                    lastCommittedChar = currentLineBuffer.last
                } else {
                    lastCommittedChar = nil
                }
            } else {
                resetInputContextTracking()
            }
            return false
        }

        // Navigation, Escape, and Tab keys when NOT composing pass straight through to the host app
        if [0x7b, 0x7c, 0x7d, 0x7e, 0x73, 0x77, 0x74, 0x79, 0x35, 0x30].contains(event.keyCode) {
            resetInputContextTracking()
            return false
        }

        // Auto-numbering on Return; otherwise pass Return straight through to the host app
        if event.keyCode == 0x24 || event.keyCode == 0x4c {
            if mods.isEmpty, settings.autoNumbering, let nextPrefix = nextAutoNumberPrefix(for: currentLineBuffer) {
                insertRawText("\n" + nextPrefix, client: client)
                currentLineBuffer = nextPrefix
                lastCommittedChar = nextPrefix.last
                return true
            }
            resetInputContextTracking()
            return false
        }

        guard mods.subtracting([.shift]).isEmpty else { return nil }

        // V Mode: pressing lowercase 'v' in Chinese mode opens the quick function menu at cursor
        if settings.shortcutVMode && mods.isEmpty && event.characters == "v" {
            enterVMode(client: client)
            return true
        }

        // Symbol auto-conversion after digits (e.g. 12:00, 3.14, 1,000)
        if settings.autoConvertSymbols,
           let prev = lastCommittedChar, prev.isASCII && prev.isNumber,
           let chars = event.characters, chars.count == 1,
           [":", ".", ",", "-", "/"].contains(chars) {
            insertRawText(chars, client: client)
            updateTracking(appending: chars)
            return true
        }

        // Replace '/?' key (unshifted '/') with '、' in Chinese mode
        if settings.slashToEnumerationComma && event.keyCode == 0x2c && !mods.contains(.shift) {
            insertProcessedText("、", client: client, allowAutoPair: false)
            return true
        }

        return nil
    }

    private func trackOrTransformUnhandledKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        let nonShiftMods = event.modifierFlags.intersection([.control, .option, .command])
        guard nonShiftMods.isEmpty, let chars = event.characters, !chars.isEmpty else {
            return false
        }
        return handleDirectPassthroughCharacter(chars, client: client)
    }

    private func handleDirectPassthroughCharacter(_ chars: String, client: (any IMKTextInput)?) -> Bool {
        guard chars.count == 1, let ch = chars.first, !ch.isNewline else {
            return false
        }
        if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
           scalar.value < 0x20 || scalar.value == 0x7f {
            return false
        }
        let needsSpace = shouldInsertAutoSpace(previous: lastCommittedChar, next: ch)
        if needsSpace {
            insertRawText(" " + chars, client: client)
            updateTracking(appending: " " + chars)
            return true
        }
        updateTracking(appending: chars)
        return false
    }

    private func nextAutoNumberPrefix(for line: String) -> String? {
        // Pattern 1: "1. text" / "1、text" / "1) text"
        let pattern1 = #"^(\s*)(\d+)(\.\s*|、|\)\s*)(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern1),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let indentRange = Range(match.range(at: 1), in: line),
           let numRange = Range(match.range(at: 2), in: line),
           let sepRange = Range(match.range(at: 3), in: line),
           let bodyRange = Range(match.range(at: 4), in: line) {
            let body = line[bodyRange].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, let num = Int(line[numRange]) else { return nil }
            return "\(line[indentRange])\(num + 1)\(line[sepRange])"
        }

        // Pattern 2: "(1) text" / "（1）text"
        let pattern2 = #"^(\s*)([\(（])(\d+)([\)）]\s*)(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern2),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let indentRange = Range(match.range(at: 1), in: line),
           let openRange = Range(match.range(at: 2), in: line),
           let numRange = Range(match.range(at: 3), in: line),
           let closeRange = Range(match.range(at: 4), in: line),
           let bodyRange = Range(match.range(at: 5), in: line) {
            let body = line[bodyRange].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, let num = Int(line[numRange]) else { return nil }
            return "\(line[indentRange])\(line[openRange])\(num + 1)\(line[closeRange])"
        }

        return nil
    }

    // MARK: - Auto-Spacing & Auto-Pair Helpers

    private func isHanCharacter(_ ch: Character) -> Bool {
        return ch.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value)
        }
    }

    private func isASCIILetter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private func isASCIIDigit(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x30...0x39).contains(scalar.value)
    }

    private func isChinesePunctuation(_ ch: Character) -> Bool {
        let puncts: Set<Character> = [
            "，", "。", "、", "；", "：", "！", "？",
            "（", "）", "【", "】", "《", "》",
            "“", "”", "‘", "’", "「", "」", "『", "』", "…", "—"
        ]
        return puncts.contains(ch)
    }

    private func shouldInsertAutoSpace(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        let settings = InputSettings.shared
        if settings.autoSpaceChineseEnglish {
            if (isHanCharacter(previous) && isASCIILetter(next)) ||
               (isASCIILetter(previous) && isHanCharacter(next)) {
                return true
            }
        }
        if settings.autoSpaceChineseNumber {
            if (isHanCharacter(previous) && isASCIIDigit(next)) ||
               (isASCIIDigit(previous) && (isHanCharacter(next) || isChinesePunctuation(next))) {
                return true
            }
        }
        return false
    }

    private func insertProcessedText(_ text: String, client: (any IMKTextInput)?, allowAutoPair: Bool) {
        guard !text.isEmpty else { return }
        var output = text
        if shouldInsertAutoSpace(previous: lastCommittedChar, next: output.first) {
            output = " " + output
        }

        if allowAutoPair, let closing = InputSettings.shared.closingPair(for: text) {
            insertRawText(output + closing, client: client)
            updateTracking(appending: output)
            if InputSettings.shared.personalRankingEnabled {
                EmitHistory.shared.recordCommit(output, bundleID: client?.bundleIdentifier())
            }
            moveCaretLeftOnce()
            return
        }

        insertRawText(output, client: client)
        updateTracking(appending: output)
        if InputSettings.shared.personalRankingEnabled {
            EmitHistory.shared.recordCommit(output, bundleID: client?.bundleIdentifier())
        }
    }

    private func insertRawText(_ text: String, client: (any IMKTextInput)?) {
        client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func updateTracking(appending text: String) {
        for ch in text {
            if ch.isNewline {
                currentLineBuffer = ""
                lastCommittedChar = nil
            } else {
                currentLineBuffer.append(ch)
                if currentLineBuffer.count > 200 {
                    currentLineBuffer = String(currentLineBuffer.suffix(200))
                }
                lastCommittedChar = ch
            }
        }
    }

    private func moveCaretLeftOnce() {
        // Wait briefly so insertText finishes committing in the client app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            // Strategy 1: Move caret directly via Accessibility kAXSelectedTextRangeAttribute.
            // This works reliably even while the user is still physically holding Shift
            // (e.g. after typing (, （, 《, “, etc.) without any modifier contamination.
            if Self.moveFocusedCaretLeftViaAX() {
                return
            }

            // Strategy 2: Post a clean Left Arrow via private event source to cgSessionEventTap
            // (unlike cghidEventTap, cgSessionEventTap does not re-inject physically held Shift).
            guard let source = CGEventSource(stateID: .privateState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x7b, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x7b, keyDown: false) else {
                return
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }

    private static func moveFocusedCaretLeftViaAX() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedObj = focusedRef else {
            return false
        }
        let element = focusedObj as! AXUIElement

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeObj = rangeRef else {
            return false
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeObj as! AXValue, .cfRange, &range), range.location > 0 else {
            return false
        }

        var newRange = CFRange(location: range.location - 1, length: 0)
        guard let newValue = AXValueCreate(.cfRange, &newRange) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newValue) == .success
    }

    // MARK: - V Mode (Quick Function Bar)

    private func enterVMode(client: (any IMKTextInput)?) {
        hideCandidatesImmediately()
        isVModeActive = true
        let controller = VModePanelController.shared
        controller.state.reset()
        setVModeMarkedText("v", client: client)

        controller.onSelectMenuItem = { [weak self] item in
            guard let self else { return }
            self.executeVModeMenuItem(item, client: self.currentClient)
        }
        controller.onCommitText = { [weak self] text in
            guard let self else { return }
            self.commitVModeText(text, client: self.currentClient)
        }
        controller.onBackToMenu = { [weak self] in
            guard let self else { return }
            self.returnVModeToMenu(client: self.currentClient)
        }
        controller.onDismiss = { [weak self] in
            guard let self else { return }
            self.exitVMode(client: self.currentClient, clearMarked: true)
        }

        let detectedApp = Self.detectClientAppearance(for: client)
        let isDark: Bool
        if let detectedApp {
            isDark = (detectedApp.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        } else {
            isDark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }

        let anchor = Self.activeCursorRect(forBundleID: client?.bundleIdentifier(), client: client)
        controller.show(near: anchor, isDark: isDark)

        // Electron / Chromium updates marked-text composition bounds asynchronously after setMarkedText("v").
        // Re-query on the next tick so the V-mode popup snaps to the exact 'v' caret even in a fresh input field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, self.isVModeActive, VModePanelController.shared.isVisible else { return }
            let targetClient = client ?? self.currentClient
            if let refreshed = Self.activeCursorRect(forBundleID: targetClient?.bundleIdentifier(), client: targetClient) {
                VModePanelController.shared.updateAnchor(refreshed)
            }
        }
    }

    private func exitVMode(client: (any IMKTextInput)?, clearMarked: Bool) {
        guard isVModeActive else { return }
        isVModeActive = false
        VModePanelController.shared.hide()
        VModePanelController.shared.state.reset()
        if clearMarked {
            clearMarkedText(client: client ?? currentClient)
        }
    }

    private func setVModeMarkedText(_ text: String, client: (any IMKTextInput)?) {
        guard let target = client ?? currentClient else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        target.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: 0, length: text.utf16.count),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func returnVModeToMenu(client: (any IMKTextInput)?) {
        let controller = VModePanelController.shared
        controller.state.page = .menu
        controller.state.hasNavigatedMenu = false
        controller.state.calcExpression = ""
        controller.state.selectedListIndex = 0
        setVModeMarkedText("v", client: client)
        controller.updateLayout()
    }

    private func commitVModeText(_ text: String, client: (any IMKTextInput)?) {
        let target = client ?? currentClient
        exitVMode(client: target, clearMarked: text.isEmpty)
        guard !text.isEmpty else { return }
        insertProcessedText(text, client: target, allowAutoPair: false)
    }

    private func executeVModeMenuItem(_ item: VModeMenuItem, client: (any IMKTextInput)?) {
        let controller = VModePanelController.shared
        switch item {
        case .calculator:
            controller.state.page = .calculator
            controller.state.calcExpression = ""
            controller.state.selectedListIndex = 0
            setVModeMarkedText("v", client: client)
            controller.updateLayout()

        case .phrases:
            controller.state.page = .phrases
            controller.state.selectedListIndex = 0
            setVModeMarkedText("v常用语", client: client)
            controller.updateLayout()

        case .symbols:
            controller.state.page = .symbols
            controller.state.selectedListIndex = 0
            setVModeMarkedText("v符号", client: client)
            controller.updateLayout()

        case .dateTime:
            controller.state.page = .dateTime
            controller.state.selectedListIndex = 0
            setVModeMarkedText("v日期", client: client)
            controller.updateLayout()

        case .clipboard:
            exitVMode(client: client, clearMarked: true)
            DispatchQueue.main.async {
                ClipboardPanelController.shared.show()
            }

        case .voice:
            exitVMode(client: client, clearMarked: true)
            DispatchQueue.main.async {
                VoiceInputManager.shared.toggleTapRecording()
            }

        case .translate:
            exitVMode(client: client, clearMarked: true)
            DispatchQueue.main.async {
                TranslateManager.shared.triggerTranslate()
            }

        case .rewrite:
            exitVMode(client: client, clearMarked: true)
            DispatchQueue.main.async {
                TranslateManager.shared.triggerRewrite()
            }

        case .settings:
            exitVMode(client: client, clearMarked: true)
            DispatchQueue.main.async {
                SettingsHelperLauncher.shared.showSettings()
            }
        }
    }

    private func handleVModeKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        let controller = VModePanelController.shared
        let state = controller.state
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])

        // Escape always exits V Mode
        if event.keyCode == 0x35 {
            exitVMode(client: client, clearMarked: true)
            return true
        }

        switch state.page {
        case .menu:
            if event.keyCode == 0x33 { // Backspace
                exitVMode(client: client, clearMarked: true)
                return true
            }
            let total = VModeMenuItem.allCases.count
            switch event.keyCode {
            case 0x7b: // Left
                state.hasNavigatedMenu = true
                if state.selectedMenuIndex % 2 == 1 {
                    state.selectedMenuIndex -= 1
                }
                return true
            case 0x7c: // Right
                state.hasNavigatedMenu = true
                if state.selectedMenuIndex % 2 == 0, state.selectedMenuIndex + 1 < total {
                    state.selectedMenuIndex += 1
                }
                return true
            case 0x7d: // Down
                state.hasNavigatedMenu = true
                if state.selectedMenuIndex + 2 < total {
                    state.selectedMenuIndex += 2
                } else {
                    state.selectedMenuIndex = state.selectedMenuIndex % 2
                }
                return true
            case 0x7e: // Up
                state.hasNavigatedMenu = true
                if state.selectedMenuIndex - 2 >= 0 {
                    state.selectedMenuIndex -= 2
                } else {
                    let col = state.selectedMenuIndex % 2
                    let lastInCol = (0..<total).last(where: { $0 % 2 == col }) ?? 0
                    state.selectedMenuIndex = lastInCol
                }
                return true
            case 0x30: // Tab
                state.hasNavigatedMenu = true
                state.selectedMenuIndex = (state.selectedMenuIndex + 1) % total
                return true
            case 0x24, 0x4c: // Return / Enter -> commit raw 'v' unless user explicitly navigated menu with arrows/Tab
                if state.hasNavigatedMenu {
                    let items = VModeMenuItem.allCases
                    if state.selectedMenuIndex < items.count {
                        executeVModeMenuItem(items[state.selectedMenuIndex], client: client)
                    }
                } else {
                    commitVModeText("v", client: client)
                }
                return true
            case 0x31: // Space -> execute highlighted menu item
                let items = VModeMenuItem.allCases
                if state.selectedMenuIndex < items.count {
                    executeVModeMenuItem(items[state.selectedMenuIndex], client: client)
                }
                return true
            default:
                break
            }

            if let chars = event.characters, chars.count == 1, mods.subtracting([.shift]).isEmpty {
                // Quick letter trigger commands: vj, vc, vy, ve, vf, vr, vd, vs (and '1' for calculator)
                if let triggeredItem = VModeMenuItem.fromTriggerCharacter(chars) {
                    executeVModeMenuItem(triggeredItem, client: client)
                    return true
                }
                let calcStarters = CharacterSet(charactersIn: "0123456789+-*/(.")
                if let scalar = chars.unicodeScalars.first, calcStarters.contains(scalar) {
                    state.page = .calculator
                    state.calcExpression = chars
                    state.selectedListIndex = 0
                    setVModeMarkedText("v\(chars)", client: client)
                    controller.updateLayout()
                    return true
                }
                if let scalar = chars.unicodeScalars.first,
                   CharacterSet.letters.contains(scalar) {
                    // User is typing a word starting with 'v' (e.g. "vivo", "vue")
                    exitVMode(client: client, clearMarked: true)
                    insertProcessedText("v" + chars, client: client, allowAutoPair: false)
                    return true
                }
            }
            return true

        case .calculator:
            if event.keyCode == 0x33 { // Backspace
                if !state.calcExpression.isEmpty {
                    state.calcExpression.removeLast()
                    state.selectedListIndex = 0
                    setVModeMarkedText("v\(state.calcExpression)", client: client)
                    controller.updateLayout()
                } else {
                    returnVModeToMenu(client: client)
                }
                return true
            }
            let results = state.calcResults
            switch event.keyCode {
            case 0x7d: // Down
                if !results.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex + 1) % results.count
                }
                return true
            case 0x7e: // Up
                if !results.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex - 1 + results.count) % results.count
                }
                return true
            case 0x24, 0x4c, 0x31: // Return / Enter / Space
                if !results.isEmpty {
                    let idx = min(state.selectedListIndex, results.count - 1)
                    commitVModeText(results[idx].value, client: client)
                } else if !state.calcExpression.isEmpty {
                    commitVModeText(state.calcExpression, client: client)
                } else {
                    exitVMode(client: client, clearMarked: true)
                }
                return true
            default:
                break
            }

            if let chars = event.characters, chars.count == 1, mods.subtracting([.shift]).isEmpty {
                if chars == "=" {
                    if !results.isEmpty {
                        let idx = min(state.selectedListIndex, results.count - 1)
                        commitVModeText(results[idx].value, client: client)
                    }
                    return true
                }
                let allowed = CharacterSet(charactersIn: "0123456789+-*/().%^")
                if let scalar = chars.unicodeScalars.first, allowed.contains(scalar) {
                    state.calcExpression.append(chars)
                    state.selectedListIndex = 0
                    setVModeMarkedText("v\(state.calcExpression)", client: client)
                    controller.updateLayout()
                    return true
                }
            }
            return true

        case .phrases, .dateTime:
            if event.keyCode == 0x33 { // Backspace
                returnVModeToMenu(client: client)
                return true
            }
            let items = (state.page == .phrases) ? state.phraseItems : state.dateTimeItems
            switch event.keyCode {
            case 0x7d: // Down
                if !items.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex + 1) % items.count
                }
                return true
            case 0x7e: // Up
                if !items.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex - 1 + items.count) % items.count
                }
                return true
            case 0x24, 0x4c, 0x31: // Return / Enter / Space
                if !items.isEmpty {
                    let idx = min(state.selectedListIndex, items.count - 1)
                    commitVModeText(items[idx].value, client: client)
                } else {
                    exitVMode(client: client, clearMarked: true)
                }
                return true
            default:
                break
            }
            if mods.isEmpty, let chars = event.characters, chars.count == 1,
               let digit = Int(chars), (1...9).contains(digit), digit - 1 < items.count {
                commitVModeText(items[digit - 1].value, client: client)
                return true
            }
            return true

        case .symbols:
            if event.keyCode == 0x33 { // Backspace
                returnVModeToMenu(client: client)
                return true
            }
            let symbols = state.symbolCategory.symbols
            let cats = VModeSymbolCategory.allCases
            let columns = 6
            switch event.keyCode {
            case 0x30: // Tab / Shift+Tab -> switch category
                let step = mods.contains(.shift) ? -1 : 1
                let idx = (state.symbolCategory.rawValue + step + cats.count) % cats.count
                state.symbolCategory = cats[idx]
                state.selectedListIndex = 0
                return true
            case 0x7b: // Left -> previous symbol
                if !symbols.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex - 1 + symbols.count) % symbols.count
                }
                return true
            case 0x7c: // Right -> next symbol
                if !symbols.isEmpty {
                    state.selectedListIndex = (state.selectedListIndex + 1) % symbols.count
                }
                return true
            case 0x7d: // Down -> next row
                if !symbols.isEmpty {
                    let next = state.selectedListIndex + columns
                    if next < symbols.count {
                        state.selectedListIndex = next
                    } else {
                        state.selectedListIndex = state.selectedListIndex % columns
                    }
                }
                return true
            case 0x7e: // Up -> previous row
                if !symbols.isEmpty {
                    let prev = state.selectedListIndex - columns
                    if prev >= 0 {
                        state.selectedListIndex = prev
                    } else {
                        let col = state.selectedListIndex % columns
                        let lastRowStart = ((symbols.count - 1) / columns) * columns
                        let target = lastRowStart + col
                        state.selectedListIndex = target < symbols.count ? target : max(0, target - columns)
                    }
                }
                return true
            case 0x24, 0x4c, 0x31: // Return / Enter / Space
                if !symbols.isEmpty {
                    let idx = min(state.selectedListIndex, symbols.count - 1)
                    commitVModeText(symbols[idx], client: client)
                }
                return true
            default:
                break
            }
            if mods.isEmpty, let chars = event.characters, chars.count == 1,
               let digit = Int(chars), (1...9).contains(digit), digit - 1 < symbols.count {
                commitVModeText(symbols[digit - 1], client: client)
                return true
            }
            return true
        }
    }

    // MARK: - Candidate Appearance Adaptation (Follow Client App / Window Light-Dark Mode)

    static func resolvedActiveAppearance(for client: (any IMKTextInput)? = nil) -> NSAppearance {
        let effectiveClient = client ?? latestActiveClient
        if let detected = detectClientAppearance(for: effectiveClient) {
            return detected
        }
        let isDark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        return NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
    }

    static func detectClientAppearance(for client: (any IMKTextInput)?) -> NSAppearance? {
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let bundleId: String?
        if let frontBundle, frontBundle != Bundle.main.bundleIdentifier {
            bundleId = frontBundle
        } else {
            bundleId = client?.bundleIdentifier() ?? latestActiveBundleID
        }

        // 1. Inspect concrete RGB text/background color via IMKTextInput (check marked/caret/prev/0)
        //    Only trust the client if it belongs to the currently active app.
        if let client,
           (bundleId == nil || client.bundleIdentifier() == bundleId),
           let imkApp = detectAppearanceFromIMKTextInput(client) {
            cacheDetectedAppearance(imkApp, forBundleID: bundleId)
            return imkApp
        }

        // 2. Native InputMethodKit client view/window effective appearance (when supported)
        if let clientObj = client as? NSObject,
           (bundleId == nil || client?.bundleIdentifier() == bundleId) {
            for selName in ["viewEffectiveAppearance", "windowEffectiveAppearance"] {
                let sel = NSSelectorFromString(selName)
                if clientObj.responds(to: sel),
                   let raw = clientObj.perform(sel)?.takeUnretainedValue(),
                   let resolved = normalizedAppearance(from: raw) {
                    cacheDetectedAppearance(resolved, forBundleID: bundleId)
                    return resolved
                }
            }
        }

        // 3. Live theme file for Electron/VS Code-based editors whose <canvas>/Monaco editor
        //    doesn't expose background/foreground colors through IMKTextInput or AX.
        if let bundleId, let editorApp = detectAppearanceFromEditorStorage(bundleID: bundleId) {
            cacheDetectedAppearance(editorApp, forBundleID: bundleId)
            return editorApp
        }

        // 4. Per-app macOS appearance preferences (AppleInterfaceStyle / NSRequiresAquaSystemAppearance)
        //    (Avoid synchronous AX tree walks on the main typing thread, which block in NSSavePanel / Electron)
        if let bundleId, let prefApp = detectAppearanceFromAppPreferences(bundleID: bundleId) {
            cacheDetectedAppearance(prefApp, forBundleID: bundleId)
            return prefApp
        }

        // 6. Short-lived cache for empty input fields inside an app whose theme was just detected
        if let bundleId,
           let cached = Self.cachedAppearanceByBundleID[bundleId],
           Date.timeIntervalSinceReferenceDate - cached.timestamp < 10.0 {
            return cached.appearance
        }

        return nil
    }

    private static func cacheDetectedAppearance(_ appearance: NSAppearance, forBundleID bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        Self.cachedAppearanceByBundleID[bundleID] = (appearance, Date.timeIntervalSinceReferenceDate)
    }

    private static let vsCodeFamilyStorageFolders: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
        "com.trae.app": "Trae",
        "com.trae.cn": "Trae",
        "com.google.antigravity": "Antigravity"
    ]

    private static func detectAppearanceFromEditorStorage(bundleID: String) -> NSAppearance? {
        guard let appFolder = vsCodeFamilyStorageFolders[bundleID] else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storagePath = "\(home)/Library/Application Support/\(appFolder)/User/globalStorage/storage.json"

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: storagePath),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }

        if let cached = cachedEditorStorageTheme[storagePath], cached.mtime == mtime {
            return cached.appearance
        }

        var resolved: NSAppearance?
        if let data = FileManager.default.contents(atPath: storagePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Prefer exact resolved hex background color (e.g. "#24273a")
            var hexBg = json["themeBackground"] as? String
            if hexBg == nil,
               let splash = json["windowSplash"] as? [String: Any],
               let colorInfo = splash["colorInfo"] as? [String: Any] {
                hexBg = (colorInfo["editorBackground"] as? String) ?? (colorInfo["background"] as? String)
            }
            if let hexBg, let lum = perceivedLuminance(fromHex: hexBg) {
                if lum < 0.45 {
                    resolved = NSAppearance(named: .darkAqua)
                } else if lum >= 0.55 {
                    resolved = NSAppearance(named: .aqua)
                }
            }
            // Fallback to VS Code baseTheme ("vs-dark" / "hc-black" vs "vs" / "hc-light")
            if resolved == nil {
                let baseTheme = (json["theme"] as? String)
                    ?? ((json["windowSplash"] as? [String: Any])?["baseTheme"] as? String)
                if let baseTheme {
                    let lower = baseTheme.lowercased()
                    if lower.contains("dark") || lower.contains("black") {
                        resolved = NSAppearance(named: .darkAqua)
                    } else if lower == "vs" || lower.contains("light") {
                        resolved = NSAppearance(named: .aqua)
                    }
                }
            }
        }

        cachedEditorStorageTheme[storagePath] = (mtime, resolved)
        return resolved
    }

    private static func perceivedLuminance(fromHex hex: String) -> CGFloat? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned.prefix(6), radix: 16) else {
            return nil
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func detectAppearanceFromIMKTextInput(_ client: any IMKTextInput) -> NSAppearance? {
        var candidateIndices: [Int] = []
        let marked = client.markedRange()
        if marked.location != NSNotFound && marked.location >= 0 {
            candidateIndices.append(marked.location)
        }
        let sel = client.selectedRange()
        if sel.location != NSNotFound && sel.location >= 0 {
            candidateIndices.append(sel.location)
            if sel.location > 0 {
                candidateIndices.append(sel.location - 1)
            }
        }
        candidateIndices.append(0)

        var seen = Set<Int>()
        var fallbackForegroundAppearance: NSAppearance?

        for idx in candidateIndices where seen.insert(idx).inserted {
            var lineRect = NSRect.zero
            let attrs = client.attributes(forCharacterIndex: idx, lineHeightRectangle: &lineRect) as? [NSAttributedString.Key: Any]
            if let resolved = classifyAttributes(attrs, fallbackForeground: &fallbackForegroundAppearance) {
                return resolved
            }
            if let sub = client.attributedSubstring(from: NSRange(location: idx, length: 1)),
               sub.length > 0 {
                let subAttrs = sub.attributes(at: 0, effectiveRange: nil)
                if let resolved = classifyAttributes(subAttrs, fallbackForeground: &fallbackForegroundAppearance) {
                    return resolved
                }
            }
        }

        return fallbackForegroundAppearance
    }

    private static func classifyAttributes(
        _ attrs: [NSAttributedString.Key: Any]?,
        fallbackForeground: inout NSAppearance?
    ) -> NSAppearance? {
        guard let attrs else { return nil }

        // Only trust concrete component-based colors (catalog system colors resolve against
        // PrimeType's own system appearance instead of the client app's overridden theme).
        if let bgColor = attrs[.backgroundColor] as? NSColor,
           bgColor.type == .componentBased,
           let bgLum = perceivedLuminance(of: bgColor, minimumAlpha: 0.4) {
            if bgLum < 0.45 {
                return NSAppearance(named: .darkAqua)
            } else if bgLum >= 0.55 {
                return NSAppearance(named: .aqua)
            }
        }

        if fallbackForeground == nil,
           let fgColor = attrs[.foregroundColor] as? NSColor,
           fgColor.type == .componentBased,
           isNearNeutralColor(fgColor),
           let fgLum = perceivedLuminance(of: fgColor, minimumAlpha: 0.4) {
            if fgLum >= 0.62 {
                fallbackForeground = NSAppearance(named: .darkAqua)
            } else if fgLum <= 0.35 {
                fallbackForeground = NSAppearance(named: .aqua)
            }
        }

        return nil
    }

    private static func detectAppearanceFromAppPreferences(bundleID: String) -> NSAppearance? {
        if let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, bundleID as CFString) as? String {
            if style.caseInsensitiveCompare("Dark") == .orderedSame {
                return NSAppearance(named: .darkAqua)
            }
            if style.caseInsensitiveCompare("Light") == .orderedSame {
                return NSAppearance(named: .aqua)
            }
        }
        if let requiresAqua = CFPreferencesCopyAppValue("NSRequiresAquaSystemAppearance" as CFString, bundleID as CFString) as? Bool,
           requiresAqua {
            return NSAppearance(named: .aqua)
        }
        return nil
    }

    private static func isNearNeutralColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let maxC = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let minC = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        return (maxC - minC) < 0.24
    }

    private static func normalizedAppearance(from raw: Any) -> NSAppearance? {
        let appearance: NSAppearance?
        if let app = raw as? NSAppearance {
            appearance = app
        } else if let name = raw as? String, !name.isEmpty {
            appearance = NSAppearance(named: NSAppearance.Name(name))
        } else {
            appearance = nil
        }
        guard let appearance else { return nil }
        let matched = appearance.bestMatch(from: [.darkAqua, .aqua])
        if matched == .darkAqua {
            return NSAppearance(named: .darkAqua)
        }
        return NSAppearance(named: .aqua)
    }

    private static func perceivedLuminance(of color: NSColor, minimumAlpha: CGFloat) -> CGFloat? {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent >= minimumAlpha else {
            return nil
        }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    private func syncCandidateAppearance(candidatesWin: IMKCandidates, client: (any IMKTextInput)?) {
        let targetAppearance = Self.detectClientAppearance(for: client)
        let targetName = targetAppearance?.name.rawValue ?? "__system__"
        let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController
        let windowMatches = (ctrl?.window?.appearance?.name.rawValue ?? "__system__") == targetName

        guard Self.lastAppliedAppearanceName != targetName || !windowMatches else {
            return
        }
        Self.lastAppliedAppearanceName = targetName

        let setAppSel = NSSelectorFromString("setAppearance:")
        if candidatesWin.responds(to: setAppSel) {
            candidatesWin.perform(setAppSel, with: targetAppearance)
        }
        if let ctrl {
            if ctrl.responds(to: setAppSel) {
                ctrl.perform(setAppSel, with: targetAppearance)
            }
            ctrl.window?.appearance = targetAppearance
            ctrl.window?.contentView?.appearance = targetAppearance
            let updateViewSel = NSSelectorFromString("updateAppearanceView")
            if ctrl.responds(to: updateViewSel) {
                ctrl.perform(updateViewSel)
            }
        }
    }

    // MARK: - Candidate Navigation

    private func isCandidatesExpanded(_ candidatesWin: IMKCandidates) -> Bool {
        return (candidatesWin.value(forKey: "isExpanded") as? Bool) ?? false
    }

    private func elevateCandidateWindow(_ candidatesWin: IMKCandidates) {
        let topLevel = Int(CGWindowLevelForKey(.screenSaverWindow)) + 1
        candidatesWin.setValue(NSNumber(value: topLevel), forKey: "windowLevel")
        let setAllowAnimSel = NSSelectorFromString("setAllowImplicitAnimations:")
        if candidatesWin.responds(to: setAllowAnimSel) {
            candidatesWin.setValue(false, forKey: "allowImplicitAnimations")
        }
        if let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController {
            if ctrl.responds(to: setAllowAnimSel) {
                ctrl.setValue(false, forKey: "allowImplicitAnimations")
            }
            if let win = ctrl.window {
                win.animationBehavior = .none
                win.level = NSWindow.Level(rawValue: topLevel)
                win.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
                win.orderFrontRegardless()
            }
        }
    }

    private func hideCandidatesImmediately() {
        UpdateBadgeOverlayController.shared.hide()
        guard let candidatesWin = AppDelegate.sharedCandidates else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        if let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController,
           let win = ctrl.window {
            win.animationBehavior = .none
            win.orderOut(nil)
        }
        candidatesWin.hide()
        NSAnimationContext.endGrouping()
    }

    private func expandCandidates(_ candidatesWin: IMKCandidates) {
        if asciiComposingBuffer == nil && !currentPreedit.isEmpty {
            let sylCount = CandidatePipeline.syllableCount(from: currentPreedit)
            let expandedLimit = CandidatePipeline.adaptiveFetchLimit(syllableCount: sylCount, isExpanded: true)
            if currentRimeCandidates.count < expandedLimit {
                let expanded = RimeEngine.shared.getAllCandidates(sessionId: sessionId, limit: expandedLimit)
                if expanded.count > currentRimeCandidates.count {
                    currentRimeCandidates = expanded
                    let prefixItems = currentPresentedCandidates
                        .filter(\.isDirectCommit)
                        .map { RimeCandidateItem(text: $0.text, comment: $0.comment) }
                    let built = CandidatePipeline.buildCandidates(
                        rimeCandidates: expanded,
                        directPrefixItems: prefixItems,
                        syllableCount: sylCount
                    )
                    currentPresentedCandidates = built
                    currentCandidates = built.map { RimeCandidateItem(text: $0.text, comment: $0.comment) }
                    candidatePresenter.presentSync(preedit: currentPreedit, candidates: built)
                    candidatesWin.update()
                }
            }
        }
        let sel = Selector(("expand"))
        if candidatesWin.responds(to: sel) {
            candidatesWin.perform(sel)
            elevateCandidateWindow(candidatesWin)
        }
    }

    private func collapseCandidates(_ candidatesWin: IMKCandidates) {
        if let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSObject {
            let sel = Selector(("collapse"))
            if ctrl.responds(to: sel) {
                ctrl.perform(sel)
            }
        }
    }

    private func currentlyHighlightedCandidateText(_ candidatesWin: IMKCandidates) -> String? {
        if let direct = candidatesWin.selectedCandidateString()?.string, !direct.isEmpty {
            return direct
        }
        if let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSObject,
           let selectedObj = ctrl.value(forKey: "selectedCandidate") as? NSObject,
           let text = selectedObj.value(forKey: "text") as? String,
           !text.isEmpty {
            return text
        }
        if let focusedObj = candidatesWin.value(forKey: "focusedCandidate") as? NSObject,
           let text = focusedObj.value(forKey: "text") as? String,
           !text.isEmpty {
            return text
        }
        return visibleFirstLineCandidates(candidatesWin).first ?? currentCandidates.first?.text
    }

    private func visibleFirstLineCandidates(_ candidatesWin: IMKCandidates) -> [String] {
        if let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSObject {
            if isCandidatesExpanded(candidatesWin),
               let listView = ctrl.value(forKey: "listView") as? NSObject,
               let map = listView.value(forKey: "selectionKeyToCandidateMapping") as? NSDictionary,
               map.count > 0 {
                var rowItems: [String] = []
                for idx in 1...9 {
                    if let candObj = map["\(idx)"] as? NSObject,
                       let text = candObj.value(forKey: "text") as? String,
                       !text.isEmpty {
                        rowItems.append(text)
                    }
                }
                if !rowItems.isEmpty {
                    return rowItems
                }
            }

            let sel = Selector(("stringIdentifiersForVisibleItemsInFirstLine"))
            if ctrl.responds(to: sel),
               let items = ctrl.perform(sel)?.takeUnretainedValue() as? [String],
               !items.isEmpty {
                return items
            }
        }
        return currentCandidates.map { $0.text }
    }

    private func handleStateToggleShortcuts(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard mods == [.option, .shift] else { return false }
        let settings = InputSettings.shared

        switch event.keyCode {
        case 0x03 where settings.shortcutTraditional: // Option + Shift + F -> 简繁体切换
            RimeEngine.shared.toggleOption(
                sessionId: sessionId,
                name: RimeEngine.shared.currentPreset.traditionalOptionName
            )
            return true
        case 0x04 where settings.shortcutFullShape: // Option + Shift + H -> 全半角切换
            RimeEngine.shared.toggleOption(sessionId: sessionId, name: "full_shape")
            return true
        case 0x2f where settings.shortcutAsciiPunct: // Option + Shift + . -> 中英标点切换
            RimeEngine.shared.toggleOption(sessionId: sessionId, name: "ascii_punct")
            return true
        default:
            return false
        }
    }

    private func handleComposingCandidateKey(
        _ event: NSEvent,
        candidatesWin: IMKCandidates,
        client: (any IMKTextInput)?
    ) -> Bool? {
        let settings = InputSettings.shared
        let nonShiftMods = event.modifierFlags.intersection([.control, .option, .command])
        guard nonShiftMods.isEmpty else { return nil }
        let hasShift = event.modifierFlags.contains(.shift)

        // Shift + Tab -> page up / move up when Tab paging is enabled
        if event.keyCode == 0x30 && hasShift && settings.pageTab {
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveUp(self)
            } else {
                candidatesWin.pageUp(self)
            }
            return true
        }

        // '+' (Shift + '=' or Numpad '+'): expand when collapsed; move down one row when already expanded
        if (event.keyCode == 0x18 && hasShift) || event.keyCode == 0x45 {
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveDown(self)
            } else {
                expandCandidates(candidatesWin)
            }
            return true
        }

        // Shift + Backspace / Shift + Forward Delete -> remove highlighted mis-learned candidate from userdb & blacklist
        if hasShift && (event.keyCode == 0x33 || event.keyCode == 0x75) {
            if let highlightedText = currentlyHighlightedCandidateText(candidatesWin) {
                deleteHighlightedCandidate(withText: highlightedText, client: client)
                return true
            }
        }

        guard !hasShift else { return nil }

        // Digits 1-9: select the exact visible item on the top line
        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x31 && scalar.value <= 0x39 {
            let slotIndex = Int(scalar.value - 0x31)
            let firstLine = visibleFirstLineCandidates(candidatesWin)
            if slotIndex < firstLine.count {
                commitCandidate(withText: firstLine[slotIndex], client: client)
            }
            return true
        }

        // ';' / '\'' -> select 2nd / 3rd candidate when enabled
        if settings.selectWithSemicolonQuote {
            if event.keyCode == 0x29 { // ';' -> 2nd candidate
                let firstLine = visibleFirstLineCandidates(candidatesWin)
                if firstLine.count > 1 {
                    commitCandidate(withText: firstLine[1], client: client)
                }
                return true
            }
            if event.keyCode == 0x27 { // '\'' -> 3rd candidate
                let firstLine = visibleFirstLineCandidates(candidatesWin)
                if firstLine.count > 2 {
                    commitCandidate(withText: firstLine[2], client: client)
                }
                return true
            }
        }

        switch event.keyCode {
        case 0x31: // Space -> commit currently highlighted candidate
            if let selectedText = currentlyHighlightedCandidateText(candidatesWin) {
                commitCandidate(withText: selectedText, client: client)
                return true
            }
            return nil

        case 0x7b: // Left Arrow -> jump left by syllable boundary in preedit (or move left in candidates if navigating them)
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveLeft(self)
                return true
            }
            if isNavigatingCandidates {
                let firstItem = visibleFirstLineCandidates(candidatesWin).first
                let currentItem = currentlyHighlightedCandidateText(candidatesWin)
                if let firstItem, let currentItem, currentItem != firstItem {
                    candidatesWin.moveLeft(self)
                    return true
                }
                isNavigatingCandidates = false
            }
            movePreeditCaretLeftBySyllable(client: client)
            return true

        case 0x7c: // Right Arrow -> move right by 1 letter in preedit; once at end, move right into candidate selection
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveRight(self)
                return true
            }
            if movePreeditCaretRightByCharIfPossible(client: client) {
                isNavigatingCandidates = false
                return true
            }
            isNavigatingCandidates = true
            candidatesWin.moveRight(self)
            return true

        case 0x7d: // Down Arrow -> expand if collapsed, else move down a row
            if !isCandidatesExpanded(candidatesWin) {
                expandCandidates(candidatesWin)
            } else {
                candidatesWin.moveDown(self)
            }
            return true

        case 0x7e: // Up Arrow -> collapse if on first line while expanded, else move up
            if isCandidatesExpanded(candidatesWin),
               let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSObject,
               let lineIdx = ctrl.value(forKey: "lineIndexForSelectedCandidate") as? Int,
               lineIdx <= 0 {
                collapseCandidates(candidatesWin)
            } else {
                candidatesWin.moveUp(self)
            }
            return true

        case 0x18 where settings.pageMinusEqual: // '=' -> move down one row in expanded grid, or next page when collapsed
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveDown(self)
            } else {
                candidatesWin.pageDown(self)
            }
            return true

        case 0x1b where settings.pageMinusEqual, 0x4e where settings.pageMinusEqual: // '-'
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveUp(self)
            } else {
                candidatesWin.pageUp(self)
            }
            return true

        case 0x1e where settings.pageBrackets: // ']' -> next page / down one row
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveDown(self)
            } else {
                candidatesWin.pageDown(self)
            }
            return true

        case 0x21 where settings.pageBrackets: // '[' -> previous page / up one row
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveUp(self)
            } else {
                candidatesWin.pageUp(self)
            }
            return true

        case 0x2f where settings.pageCommaPeriod: // '.' -> next page / down one row
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveDown(self)
            } else {
                candidatesWin.pageDown(self)
            }
            return true

        case 0x2b where settings.pageCommaPeriod: // ',' -> previous page / up one row
            if isCandidatesExpanded(candidatesWin) {
                candidatesWin.moveUp(self)
            } else {
                candidatesWin.pageUp(self)
            }
            return true

        case 0x79: // Page Down
            candidatesWin.pageDown(self)
            return true

        case 0x74: // Page Up
            candidatesWin.pageUp(self)
            return true

        case 0x30: // Tab -> page down if pageTab enabled, otherwise toggle scrolling grid expand/collapse
            if settings.pageTab {
                if isCandidatesExpanded(candidatesWin) {
                    candidatesWin.moveDown(self)
                } else {
                    candidatesWin.pageDown(self)
                }
            } else if isCandidatesExpanded(candidatesWin) {
                collapseCandidates(candidatesWin)
            } else {
                expandCandidates(candidatesWin)
            }
            return true

        default:
            return nil
        }
    }

    private func deleteHighlightedCandidate(withText text: String, client: (any IMKTextInput)?) {
        guard !text.isEmpty else { return }
        if let presented = currentPresentedCandidates.first(where: { $0.text == text }),
           let rimeIdx = presented.originalRimeIndex {
            _ = RimeEngine.shared.deleteCandidate(sessionId: sessionId, index: rimeIdx)
        } else if let fallbackIdx = currentRimeCandidates.firstIndex(where: { $0.text == text }) {
            _ = RimeEngine.shared.deleteCandidate(sessionId: sessionId, index: fallbackIdx)
        }
        syncRimeState(client: client)
    }

    private func commitCandidate(withText text: String, client: (any IMKTextInput)?) {
        queryCoordinator.cancelAll()
        if asciiComposingBuffer != nil || currentDirectCommitTexts.contains(text) {
            asciiComposingBuffer = nil
            RimeEngine.shared.clearComposition(sessionId: sessionId)
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            candidatePresenter.reset()
            hideCandidatesImmediately()
            if !text.isEmpty {
                insertProcessedText(text, client: client, allowAutoPair: false)
            } else {
                clearMarkedText(client: client)
            }
            return
        }

        // Always map displayed candidate back to its exact original Rime index so userdb & segmented commits stay intact
        let index: Int
        if let presented = currentPresentedCandidates.first(where: { $0.text == text }),
           let originalIdx = presented.originalRimeIndex {
            index = originalIdx
        } else {
            index = currentRimeCandidates.firstIndex(where: { $0.text == text }) ?? 0
        }

        if RimeEngine.shared.selectCandidate(sessionId: sessionId, index: index) {
            syncRimeState(client: client)
        }
    }

    // MARK: - Email (@) & URL/Domain (.) Smart Completion Mode

    private static let commonEmailDomains: [String] = [
        "qq.com",
        "163.com",
        "gmail.com",
        "126.com",
        "outlook.com",
        "icloud.com",
        "foxmail.com",
        "sina.com",
        "hotmail.com",
        "yeah.net",
        "aliyun.com",
        "139.com",
        "me.com"
    ]

    private static let commonURLSuffixes: [String] = [
        "com",
        "cn",
        "net",
        "org",
        "com.cn",
        "io",
        "top",
        "cc",
        "me",
        "tv",
        "gov.cn",
        "edu.cn"
    ]

    private static let commonWWWSites: [String] = [
        "www.baidu.com",
        "www.qq.com",
        "www.google.com",
        "www.github.com",
        "www.bilibili.com",
        "www.zhihu.com",
        "www.taobao.com"
    ]

    private static let urlSchemePrefixes: Set<String> = [
        "http", "https", "ftp", "mailto", "file"
    ]

    private static let allowedASCIIComposingScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-+/:?&=~#%"
    )

    private func rawRimeComposingASCII() -> String {
        if let raw = RimeEngine.shared.getRawInput(sessionId: sessionId), !raw.isEmpty {
            return raw
        }
        return currentPreedit
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private func isValidASCIIComposingPrefix(_ text: String) -> Bool {
        guard !text.isEmpty,
              let first = text.unicodeScalars.first,
              (0x30...0x39).contains(first.value) || (0x41...0x5A).contains(first.value) || (0x61...0x7A).contains(first.value) else {
            return false
        }
        return text.unicodeScalars.allSatisfy { Self.allowedASCIIComposingScalars.contains($0) }
    }

    private func shouldEnterASCIIComposingMode(for event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        guard InputSettings.shared.smartEmailURLCompletion else { return false }
        guard let chars = event.characters,
              chars.count == 1,
              (chars == "@" || chars == "." || chars == ":") else {
            return false
        }
        let nonShiftMods = event.modifierFlags.intersection([.control, .option, .command])
        guard nonShiftMods.isEmpty else {
            return false
        }

        let rawPrefix = rawRimeComposingASCII()
        guard isValidASCIIComposingPrefix(rawPrefix) else { return false }

        if chars == "@" {
            enterASCIIComposingMode(with: rawPrefix + "@", client: client)
            return true
        }

        if chars == "." && !event.modifierFlags.contains(.shift) && rawPrefix.count >= 2 {
            enterASCIIComposingMode(with: rawPrefix + ".", client: client)
            return true
        }

        if chars == ":" && Self.urlSchemePrefixes.contains(rawPrefix.lowercased()) {
            enterASCIIComposingMode(with: rawPrefix + ":", client: client)
            return true
        }

        return false
    }

    private func enterASCIIComposingMode(with initialBuffer: String, client: (any IMKTextInput)?) {
        RimeEngine.shared.clearComposition(sessionId: sessionId)
        asciiComposingBuffer = initialBuffer
        updateASCIIComposingUI(client: client, wasAlreadyComposing: !currentPreedit.isEmpty)
    }

    private func exitASCIIComposingMode(client: (any IMKTextInput)?, clearMarked: Bool) {
        asciiComposingBuffer = nil
        currentPreedit = ""
        currentCandidates = []
        currentRimeCandidates = []
        currentDirectCommitTexts = []
        if clearMarked {
            clearMarkedText(client: client)
        }
        hideCandidatesImmediately()
    }

    private func handleASCIIComposingKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        guard var buffer = asciiComposingBuffer else { return false }
        let nonShiftMods = event.modifierFlags.intersection([.control, .option, .command])
        guard nonShiftMods.isEmpty else { return false }
        let hasShift = event.modifierFlags.contains(.shift)
        let settings = InputSettings.shared
        let candidatesWin = AppDelegate.sharedCandidates

        switch event.keyCode {
        case 0x35: // Escape -> cancel composition
            exitASCIIComposingMode(client: client, clearMarked: true)
            return true

        case 0x33: // Backspace
            guard !buffer.isEmpty else {
                exitASCIIComposingMode(client: client, clearMarked: true)
                return true
            }
            buffer.removeLast()
            if buffer.isEmpty {
                exitASCIIComposingMode(client: client, clearMarked: true)
                return true
            }
            // If all '@', '.', ':' triggers were deleted, seamlessly restore normal Pinyin composition in Rime
            if !buffer.contains("@") && !buffer.contains(".") && !buffer.contains(":") {
                asciiComposingBuffer = nil
                RimeEngine.shared.clearComposition(sessionId: sessionId)
                if !RimeEngine.shared.setRawInput(sessionId: sessionId, input: buffer) {
                    for scalar in buffer.unicodeScalars {
                        _ = RimeEngine.shared.processKey(sessionId: sessionId, keyCode: Int32(scalar.value), mask: 0)
                    }
                }
                syncRimeState(client: client)
                return true
            }
            asciiComposingBuffer = buffer
            updateASCIIComposingUI(client: client, wasAlreadyComposing: true)
            return true

        case 0x31, 0x24, 0x4c: // Space, Return, Numpad Enter -> commit currently highlighted completion candidate
            let selectedText = (candidatesWin.flatMap { currentlyHighlightedCandidateText($0) })
                ?? currentCandidates.first?.text
                ?? buffer
            commitCandidate(withText: selectedText, client: client)
            return true

        case 0x7b: // Left Arrow
            candidatesWin?.moveLeft(self)
            return true

        case 0x7c: // Right Arrow
            candidatesWin?.moveRight(self)
            return true

        case 0x7d: // Down Arrow
            if let candidatesWin {
                if !isCandidatesExpanded(candidatesWin) {
                    expandCandidates(candidatesWin)
                } else {
                    candidatesWin.moveDown(self)
                }
            }
            return true

        case 0x7e: // Up Arrow
            if let candidatesWin {
                if isCandidatesExpanded(candidatesWin),
                   let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSObject,
                   let lineIdx = ctrl.value(forKey: "lineIndexForSelectedCandidate") as? Int,
                   lineIdx <= 0 {
                    collapseCandidates(candidatesWin)
                } else {
                    candidatesWin.moveUp(self)
                }
            }
            return true

        case 0x79: // Page Down
            candidatesWin?.pageDown(self)
            return true

        case 0x74: // Page Up
            candidatesWin?.pageUp(self)
            return true

        case 0x30: // Tab
            if let candidatesWin {
                if hasShift && settings.pageTab {
                    if isCandidatesExpanded(candidatesWin) {
                        candidatesWin.moveUp(self)
                    } else {
                        candidatesWin.pageUp(self)
                    }
                } else if settings.pageTab {
                    if isCandidatesExpanded(candidatesWin) {
                        candidatesWin.moveDown(self)
                    } else {
                        candidatesWin.pageDown(self)
                    }
                } else if isCandidatesExpanded(candidatesWin) {
                    collapseCandidates(candidatesWin)
                } else {
                    expandCandidates(candidatesWin)
                }
            }
            return true

        default:
            break
        }

        // ';' / '\'' quick 2nd / 3rd candidate selection
        if !hasShift && settings.selectWithSemicolonQuote, let candidatesWin {
            if event.keyCode == 0x29 {
                let firstLine = visibleFirstLineCandidates(candidatesWin)
                if firstLine.count > 1 {
                    commitCandidate(withText: firstLine[1], client: client)
                }
                return true
            }
            if event.keyCode == 0x27 {
                let firstLine = visibleFirstLineCandidates(candidatesWin)
                if firstLine.count > 2 {
                    commitCandidate(withText: firstLine[2], client: client)
                }
                return true
            }
        }

        // '[' / ']' paging when enabled
        if !hasShift && settings.pageBrackets, let candidatesWin {
            if event.keyCode == 0x1e {
                if isCandidatesExpanded(candidatesWin) {
                    candidatesWin.moveDown(self)
                } else {
                    candidatesWin.pageDown(self)
                }
                return true
            }
            if event.keyCode == 0x21 {
                if isCandidatesExpanded(candidatesWin) {
                    candidatesWin.moveUp(self)
                } else {
                    candidatesWin.pageUp(self)
                }
                return true
            }
        }

        // Append valid email / URL characters directly into asciiComposingBuffer
        if let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first {
            // Digits 1-9: if the user is not typing a numeric domain (like 163.com / 126.com / 139.com / port / query),
            // allow 1-9 to select visible candidates on the first line when the digit would not match any email domain prefix.
            if !hasShift, scalar.value >= 0x31 && scalar.value <= 0x39, let candidatesWin {
                let digitChar = String(scalar)
                let shouldAppendAsDomainOrURL = shouldTreatDigitAsTextInASCIIMode(digitChar, currentBuffer: buffer)
                if !shouldAppendAsDomainOrURL {
                    let slotIndex = Int(scalar.value - 0x31)
                    let firstLine = visibleFirstLineCandidates(candidatesWin)
                    if slotIndex < firstLine.count {
                        commitCandidate(withText: firstLine[slotIndex], client: client)
                        return true
                    }
                }
            }

            if Self.allowedASCIIComposingScalars.contains(scalar) {
                buffer.append(chars)
                asciiComposingBuffer = buffer
                updateASCIIComposingUI(client: client, wasAlreadyComposing: true)
                return true
            }
        }

        // Any other character (e.g. Chinese punctuation or unsupported symbol): commit current buffer and pass through
        commitCandidate(withText: buffer, client: client)
        return false
    }

    private func shouldTreatDigitAsTextInASCIIMode(_ digit: String, currentBuffer: String) -> Bool {
        // If typing a URL path/query/port after ':' or '/' or '?' or '=', digits are part of the URL
        if currentBuffer.contains(":") || currentBuffer.contains("/") || currentBuffer.contains("?") || currentBuffer.contains("=") {
            return true
        }
        // If in email mode after '@', check whether appending this digit matches a known numeric email domain (e.g. 163.com, 126.com, 139.com)
        // or if the user has already started typing digits in the domain part
        if let atIndex = currentBuffer.firstIndex(of: "@") {
            let domainPart = String(currentBuffer[currentBuffer.index(after: atIndex)...])
            if !domainPart.isEmpty && domainPart.allSatisfy({ $0.isNumber }) {
                return true
            }
        }
        return false
    }

    private func generateASCIIComposingCandidates(for buffer: String) -> [RimeCandidateItem] {
        var results: [String] = []
        var seen = Set<String>()

        func appendUnique(_ text: String) {
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            results.append(text)
        }

        let lowerBuffer = buffer.lowercased()

        // 1. Email completion mode (contains '@')
        if let atIndex = buffer.firstIndex(of: "@") {
            let localPart = String(buffer[..<atIndex])
            let domainPrefix = String(buffer[buffer.index(after: atIndex)...])
            let lowerDomainPrefix = domainPrefix.lowercased()

            // Include any user custom phrase whose content is an email matching the typed prefix
            for phrase in InputSettings.shared.customPhrases {
                let content = phrase.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.contains("@") && content.lowercased().hasPrefix(lowerBuffer) {
                    appendUnique(content)
                }
            }

            // Match common email domains by prefix
            for domain in Self.commonEmailDomains {
                if lowerDomainPrefix.isEmpty || domain.lowercased().hasPrefix(lowerDomainPrefix) {
                    appendUnique("\(localPart)@\(domain)")
                }
            }

            // Fallback candidates when user has typed characters after '@'
            // Matches Screenshot 2 (`lumocored@g` -> `1 lumocored@gmail.com`, `2 lumocored@g.com`)
            // and Screenshot 3 (`lumocored@gmail.com` -> `1 lumocored@gmail.com`)
            if !domainPrefix.isEmpty {
                if !domainPrefix.contains(".") {
                    appendUnique("\(localPart)@\(domainPrefix).com")
                    appendUnique(buffer)
                } else {
                    appendUnique(buffer)
                    if let lastDot = domainPrefix.lastIndex(of: ".") {
                        let hostPart = String(domainPrefix[..<lastDot])
                        let tldPrefix = String(domainPrefix[domainPrefix.index(after: lastDot)...]).lowercased()
                        if !hostPart.isEmpty {
                            for tld in Self.commonURLSuffixes where tld.hasPrefix(tldPrefix) {
                                appendUnique("\(localPart)@\(hostPart).\(tld)")
                            }
                        }
                    }
                }
            } else {
                appendUnique(buffer)
            }

            return results.map { RimeCandidateItem(text: $0, comment: nil) }
        }

        // 2. URL / Domain completion mode (contains '.' or ':')
        // Matches Screenshot 4 (`baidu.` -> `1 baidu.`, `2 baidu.com`, `3 baidu.cn`, ...)
        appendUnique(buffer)

        // Include any user custom phrase matching the URL prefix
        for phrase in InputSettings.shared.customPhrases {
            let content = phrase.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if (content.contains(".") || content.contains("://")) && content.lowercased().hasPrefix(lowerBuffer) {
                appendUnique(content)
            }
        }

        if lowerBuffer == "http:" || lowerBuffer == "https:" {
            appendUnique("\(buffer)//")
            appendUnique("\(buffer)//www.")
        } else if lowerBuffer == "www." || lowerBuffer == "http://www." || lowerBuffer == "https://www." {
            let schemePrefix = lowerBuffer.hasPrefix("http") ? String(buffer.dropLast(4)) : ""
            for site in Self.commonWWWSites {
                appendUnique(schemePrefix + site)
            }
        } else if let lastDot = buffer.lastIndex(of: ".") {
            let afterDot = String(buffer[buffer.index(after: lastDot)...])
            if !afterDot.contains("/") && !afterDot.contains("?") && !afterDot.contains(":") {
                let hostPrefix = String(buffer[..<lastDot])
                let lowerTLDPrefix = afterDot.lowercased()
                let isWWWOnly = hostPrefix.lowercased() == "www" || hostPrefix.lowercased().hasSuffix("://www")
                if isWWWOnly && !afterDot.isEmpty {
                    for site in Self.commonWWWSites where site.lowercased().hasPrefix(lowerBuffer) {
                        appendUnique(site)
                    }
                }
                for tld in Self.commonURLSuffixes {
                    if lowerTLDPrefix.isEmpty || tld.lowercased().hasPrefix(lowerTLDPrefix) {
                        appendUnique("\(hostPrefix).\(tld)")
                    }
                }
            }
        }

        return results.map { RimeCandidateItem(text: $0, comment: nil) }
    }

    private func updateASCIIComposingUI(client: (any IMKTextInput)?, wasAlreadyComposing: Bool) {
        guard let buffer = asciiComposingBuffer else { return }
        currentPreedit = buffer

        // Render contiguous underlined preedit (no syllable spaces)
        let attrStr = NSMutableAttributedString(string: buffer)
        let rawRange = NSRange(location: 0, length: buffer.utf16.count)
        if rawRange.length > 0,
           let attrs = mark(forStyle: Int(kTSMHiliteSelectedRawText), at: rawRange) as? [NSAttributedString.Key: Any] {
            attrStr.setAttributes(attrs, range: rawRange)
        }
        client?.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: buffer.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        let items = generateASCIIComposingCandidates(for: buffer)
        currentCandidates = items
        currentRimeCandidates = []
        currentDirectCommitTexts = Set(items.map { $0.text })

        if let candidatesWin = AppDelegate.sharedCandidates {
            if currentCandidates.isEmpty {
                hideCandidatesImmediately()
            } else {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                NSAnimationContext.current.allowsImplicitAnimation = false
                if !wasAlreadyComposing {
                    syncCandidateAppearance(candidatesWin: candidatesWin, client: client)
                }
                let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController
                ctrl?.window?.animationBehavior = .none
                let isWinVisible = ctrl?.window?.isVisible ?? false
                candidatesWin.update()
                if !wasAlreadyComposing || !isWinVisible {
                    candidatesWin.show(kIMKLocateCandidatesBelowHint)
                    syncCandidateAppearance(candidatesWin: candidatesWin, client: client)
                }
                elevateCandidateWindow(candidatesWin)
                if let win = ctrl?.window, win.isVisible,
                   win.frame.origin.x != 0 || win.frame.origin.y != 0 {
                    Self.lastKnownCursorRect = NSRect(x: win.frame.minX, y: win.frame.maxY + 4, width: 1, height: 20)
                    Self.lastKnownCursorBundleID = client?.bundleIdentifier()
                }
                NSAnimationContext.endGrouping()
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        let settings = InputSettings.shared

        // Left / Right Command solo tap -> select 2nd / 3rd candidate while composing when enabled
        let isLeftCmd = (event.keyCode == 55)
        let isRightCmd = (event.keyCode == 54)
        if isLeftCmd || isRightCmd {
            guard settings.selectWithLeftRightCommand,
                  !currentPreedit.isEmpty,
                  let candidatesWin = AppDelegate.sharedCandidates else {
                pendingCommandKeyCode = nil
                return false
            }
            if event.modifierFlags.contains(.command) {
                pendingCommandKeyCode = event.keyCode
            } else if let pending = pendingCommandKeyCode, pending == event.keyCode {
                pendingCommandKeyCode = nil
                let slotIndex = isLeftCmd ? 1 : 2
                let firstLine = visibleFirstLineCandidates(candidatesWin)
                if slotIndex < firstLine.count {
                    commitCandidate(withText: firstLine[slotIndex], client: client)
                    return true
                }
            }
            return false
        }

        pendingCommandKeyCode = nil
        return false
    }

    private func clearActiveRimeComposition(client: (any IMKTextInput)?) {
        queryCoordinator.cancelAll()
        candidatePresenter.reset()
        RimeEngine.shared.clearComposition(sessionId: sessionId)
        currentPreedit = ""
        currentCandidates = []
        currentRimeCandidates = []
        currentPresentedCandidates = []
        currentDirectCommitTexts = []
        isPreeditAllSelected = false
        isNavigatingCandidates = false
        clearMarkedText(client: client)
        hideCandidatesImmediately()
    }

    private func selectAllMarkedPreedit(client: (any IMKTextInput)?) {
        guard !currentPreedit.isEmpty else { return }
        let displayPreedit = Self.formatDisplayPreedit(currentPreedit, selStartUTF8: currentPreeditSelStart)
        let totalUTF16 = displayPreedit.utf16.count
        let attrStr = NSMutableAttributedString(string: displayPreedit)
        let fullRange = NSRange(location: 0, length: totalUTF16)
        if let attrs = mark(forStyle: Int(kTSMHiliteSelectedRawText), at: fullRange) as? [NSAttributedString.Key: Any] {
            attrStr.setAttributes(attrs, range: fullRange)
        }
        client?.setMarkedText(
            attrStr,
            selectionRange: fullRange,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func movePreeditCaretLeftBySyllable(client: (any IMKTextInput)?) {
        guard let rawInput = RimeEngine.shared.getRawInput(sessionId: sessionId), !rawInput.isEmpty else { return }
        let rawCaret = RimeEngine.shared.getCaretPos(sessionId: sessionId)
        guard rawCaret > 0 else { return }

        let targetPos = Self.previousSyllableBoundary(
            rawInput: rawInput,
            preedit: currentPreedit,
            currentCaret: rawCaret
        )
        if targetPos != rawCaret {
            RimeEngine.shared.setCaretPos(sessionId: sessionId, pos: targetPos)
            syncRimeState(client: client)
        }
    }

    private func movePreeditCaretRightByCharIfPossible(client: (any IMKTextInput)?) -> Bool {
        guard let rawInput = RimeEngine.shared.getRawInput(sessionId: sessionId), !rawInput.isEmpty else {
            return false
        }
        let rawLen = rawInput.utf8.count
        let rawCaret = RimeEngine.shared.getCaretPos(sessionId: sessionId)
        guard rawCaret < rawLen else {
            return false
        }
        RimeEngine.shared.setCaretPos(sessionId: sessionId, pos: rawCaret + 1)
        syncRimeState(client: client)
        return true
    }

    /// Computes the nearest syllable/segment boundary strictly before `currentCaret` in Rime's raw input buffer.
    static func previousSyllableBoundary(rawInput: String, preedit: String, currentCaret: Int) -> Int {
        guard currentCaret > 0 else { return 0 }
        let rawLen = rawInput.utf8.count
        let clampedCaret = min(currentCaret, rawLen)

        let asciiTailStart = preedit.lastIndex(where: { !$0.isASCII })
            .map { preedit.index(after: $0) } ?? preedit.startIndex
        let asciiTail = String(preedit[asciiTailStart...])
        let segments = asciiTail.split { $0 == " " || $0 == "'" || $0 == "·" }
        let tailRawLen = segments.reduce(0) { $0 + $1.utf8.count }
        let baseOffset = max(0, rawLen - tailRawLen)

        var boundaries: [Int] = [0]
        if baseOffset > 0 {
            boundaries.append(baseOffset)
        }
        var cursor = baseOffset
        for seg in segments {
            cursor += seg.utf8.count
            if cursor <= rawLen {
                boundaries.append(cursor)
            }
        }

        if let prev = boundaries.last(where: { $0 < clampedCaret }) {
            return prev
        }
        return max(0, clampedCaret - 1)
    }

    private func syncRimeState(
        client: (any IMKTextInput)?,
        keystrokeStartAt: CFAbsoluteTime? = nil,
        rimeProcessMs: Double = 0
    ) {
        // Pure Pinyin input method: ensure ascii_mode never gets enabled by any Rime keybinding
        if RimeEngine.shared.isAsciiMode(sessionId: sessionId) {
            RimeEngine.shared.setAsciiMode(sessionId: sessionId, enabled: false)
        }
        asciiComposingBuffer = nil

        var didCommit = false
        if let commitText = RimeEngine.shared.getCommitText(sessionId: sessionId), !commitText.isEmpty {
            insertProcessedText(commitText, client: client, allowAutoPair: true)
            didCommit = true
        }

        guard let context = RimeEngine.shared.getContext(sessionId: sessionId) else {
            let hadPreedit = !currentPreedit.isEmpty
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            isPreeditAllSelected = false
            isNavigatingCandidates = false
            candidatePresenter.reset()
            queryCoordinator.cancelAll()
            // insertText already replaces marked text and exits composition mode;
            // calling setMarkedText("") afterward violates IMKTextInput and breaks Backspace
            // in strict NSTextView / Spotlight / WKWebView clients (e.g. Gemini Mac app).
            if hadPreedit && !didCommit {
                clearMarkedText(client: client)
            }
            hideCandidatesImmediately()
            return
        }

        if context.preedit.isEmpty {
            let hadPreedit = !currentPreedit.isEmpty
            currentPreedit = ""
            currentCandidates = []
            currentRimeCandidates = []
            currentPresentedCandidates = []
            currentDirectCommitTexts = []
            isPreeditAllSelected = false
            isNavigatingCandidates = false
            candidatePresenter.reset()
            queryCoordinator.cancelAll()
            if hadPreedit && !didCommit {
                clearMarkedText(client: client)
            }
            hideCandidatesImmediately()
        } else {
            let wasComposing = !currentPreedit.isEmpty
            currentPreedit = context.preedit
            updateMarkedText(context, client: client)

            // Tier 0: Adaptive Rime lazy-fetch budget based on real syllable count
            let syllableCount = CandidatePipeline.syllableCount(from: context.preedit)
            let isExpanded = AppDelegate.sharedCandidates.map { isCandidatesExpanded($0) } ?? false
            let fetchLimit = CandidatePipeline.adaptiveFetchLimit(syllableCount: syllableCount, isExpanded: isExpanded)

            let fetchStart = CFAbsoluteTimeGetCurrent()
            let rimeCandidates = RimeEngine.shared.getAllCandidates(sessionId: sessionId, limit: fetchLimit)
            let fetchMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000.0
            currentRimeCandidates = rimeCandidates

            // Tier 1: Direct custom phrases + semantic deduplication + personal feedback & cross-message entity boost
            let tier1Start = CFAbsoluteTimeGetCurrent()
            let normalizedQuery = UserRankingEngine.normalizeCode(context.preedit)

            var extraItems: [RimeCandidateItem] = []
            var directTexts: Set<String> = []

            for phrase in InputSettings.shared.matchingPhrases(forNormalizedPreedit: normalizedQuery) {
                if !directTexts.contains(phrase.content) {
                    extraItems.append(RimeCandidateItem(text: phrase.content, comment: nil))
                    directTexts.insert(phrase.content)
                }
            }

            if InputSettings.shared.shortcutVMode {
                if normalizedQuery == "vj" && InputSettings.shared.clipboardEnabled {
                    for entry in ClipboardManager.shared.entries.prefix(15) {
                        if let text = entry.text, !text.isEmpty, !directTexts.contains(text) {
                            extraItems.append(RimeCandidateItem(text: text, comment: nil))
                            directTexts.insert(text)
                        }
                    }
                } else if normalizedQuery == "vc" {
                    for phrase in InputSettings.shared.customPhrases.prefix(20) {
                        if !directTexts.contains(phrase.content) {
                            extraItems.append(RimeCandidateItem(text: phrase.content, comment: nil))
                            directTexts.insert(phrase.content)
                        }
                    }
                }
            }

            currentDirectCommitTexts = directTexts

            let presented = CandidatePipeline.buildCandidates(
                rimeCandidates: rimeCandidates,
                directPrefixItems: extraItems,
                syllableCount: syllableCount
            )
            let tier1Ms = (CFAbsoluteTimeGetCurrent() - tier1Start) * 1000.0

            currentPresentedCandidates = presented
            currentCandidates = presented.map { RimeCandidateItem(text: $0.text, comment: $0.comment) }
            candidatePresenter.presentSync(preedit: context.preedit, candidates: presented)

            if let candidatesWin = AppDelegate.sharedCandidates {
                if currentCandidates.isEmpty {
                    hideCandidatesImmediately()
                } else {
                    NSAnimationContext.beginGrouping()
                    NSAnimationContext.current.duration = 0
                    NSAnimationContext.current.allowsImplicitAnimation = false
                    let ctrl = candidatesWin.value(forKey: "expandableWindowController") as? NSWindowController
                    ctrl?.window?.animationBehavior = .none
                    let isWinVisible = ctrl?.window?.isVisible ?? false
                    candidatesWin.update()
                    if !wasComposing || !isWinVisible {
                        candidatesWin.show(kIMKLocateCandidatesBelowHint)
                        elevateCandidateWindow(candidatesWin)
                    }
                    if AppUpdateManager.shared.hasUpdate {
                        UpdateBadgeOverlayController.shared.showIfAvailable(below: ctrl?.window)
                    }
                    if let win = ctrl?.window, win.isVisible,
                       win.frame.origin.x != 0 || win.frame.origin.y != 0 {
                        Self.lastKnownCursorRect = NSRect(x: win.frame.minX, y: win.frame.maxY + 4, width: 1, height: 20)
                        Self.lastKnownCursorBundleID = client?.bundleIdentifier()
                    }
                    NSAnimationContext.endGrouping()
                }
            }

            if let t0 = keystrokeStartAt {
                let totalSyncMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                LatencyProbe.shared.recordSync(
                    totalMs: totalSyncMs,
                    rimeMs: rimeProcessMs + fetchMs,
                    tier1Ms: tier1Ms
                )
            }

            // Optional Tier-2 local neural reranker (only runs when explicitly installed & enabled in Settings)
            if LocalNeuralReranker.shared.isInstalled && InputSettings.shared.localRerankerEnabled {
                let bundleID = client?.bundleIdentifier()
                let contextPrefix = EmitHistory.shared.recentContext(forBundleID: bundleID, maxChars: 80)
                let rawInputForExpand = (context.selStart == 0) ? (RimeEngine.shared.getRawInput(sessionId: sessionId) ?? "") : ""
                let rawCaretForExpand = (context.selStart == 0 && !rawInputForExpand.isEmpty)
                    ? RimeEngine.shared.getCaretPos(sessionId: sessionId)
                    : 0
                let wholeSentenceCount = presented.prefix(8).filter(\.isWholeSentence).count
                let canExpandNBest = (context.selStart == 0)
                    && !rawInputForExpand.isEmpty
                    && rawCaretForExpand == rawInputForExpand.utf8.count
                    && syllableCount >= 3
                    && wholeSentenceCount < 4
                let neuralPotentiallyEligible = (syllableCount >= 6 || (syllableCount >= 2 && !contextPrefix.isEmpty))

                if canExpandNBest || LocalNeuralReranker.shared.shouldTrigger(
                    syllableCount: syllableCount,
                    candidates: presented,
                    contextPrefix: contextPrefix
                ) {
                    let snapshotPreedit = context.preedit
                    let snapshotCandidates = presented
                    let snapshotCode = normalizedQuery
                    let snapshotRawInput = rawInputForExpand
                    let snapshotCaret = rawCaretForExpand
                    let shouldExpand = canExpandNBest && neuralPotentiallyEligible

                    if shouldExpand || neuralPotentiallyEligible {
                        queryCoordinator.schedule(
                            work: { [weak self] () async -> NeuralRerankResult? in
                                var workingCandidates = snapshotCandidates
                                var newlyExpandedTexts: [String] = []

                                if shouldExpand {
                                let expanded: [String] = await MainActor.run {
                                    guard let self,
                                          self.currentPreedit == snapshotPreedit,
                                          self.currentPreeditSelStart == 0 else {
                                        return []
                                    }
                                    let topWholeLen = snapshotCandidates.first(where: \.isWholeSentence)?.text.count ?? syllableCount
                                    let minWholeChars = max(syllableCount - 1, topWholeLen - 1)
                                    let prefixIndices: [Int] = snapshotCandidates
                                        .prefix(10)
                                        .compactMap { cand -> Int? in
                                            guard !cand.isDirectCommit,
                                                  !cand.isWholeSentence,
                                                  let rimeIdx = cand.originalRimeIndex,
                                                  cand.text.count < topWholeLen else {
                                                return nil
                                            }
                                            return rimeIdx
                                        }
                                        .prefix(3)
                                        .map { $0 }
                                    guard !prefixIndices.isEmpty else { return [] }
                                    return RimeEngine.shared.expandAlternateWholeSentences(
                                        sessionId: self.sessionId,
                                        rawInputToRestore: snapshotRawInput,
                                        caretToRestore: snapshotCaret,
                                        prefixIndices: prefixIndices,
                                        existingTexts: Set(snapshotCandidates.map(\.text)),
                                        minCharCount: minWholeChars,
                                        maxSentences: 3
                                    )
                                }
                                newlyExpandedTexts = expanded
                                if !expanded.isEmpty {
                                    var insertAt = workingCandidates.firstIndex(where: { !$0.isWholeSentence && !$0.isDirectCommit })
                                        ?? min(1, workingCandidates.count)
                                    if insertAt == 0 && !workingCandidates.isEmpty {
                                        insertAt = 1
                                    }
                                    let extraWhole = expanded.enumerated().map { offset, sentence in
                                        PresentedCandidate(
                                            text: sentence,
                                            comment: nil,
                                            originalRimeIndex: nil,
                                            isDirectCommit: true,
                                            isWholeSentence: true,
                                            baseRank: insertAt + offset
                                        )
                                    }
                                    workingCandidates.insert(contentsOf: extraWhole, at: min(insertAt, workingCandidates.count))
                                }
                            }

                            if LocalNeuralReranker.shared.shouldTrigger(
                                syllableCount: syllableCount,
                                candidates: workingCandidates,
                                contextPrefix: contextPrefix
                            ) {
                                return await LocalNeuralReranker.shared.rerank(
                                    preedit: snapshotPreedit,
                                    candidates: workingCandidates,
                                    contextPrefix: contextPrefix,
                                    normalizedCode: snapshotCode
                                )
                            }

                            guard !newlyExpandedTexts.isEmpty else { return nil }
                            // Surface alternate full sentences at slots 1..3 without touching Top-1
                            return NeuralRerankResult(
                                preedit: snapshotPreedit,
                                candidates: workingCandidates,
                                leadMargin: 0.0
                            )
                        },
                        onResult: { [weak self] result, asyncMs in
                            guard let self, self.currentPreedit == result.preedit else { return }
                            for cand in result.candidates where cand.isDirectCommit {
                                self.currentDirectCommitTexts.insert(cand.text)
                            }
                            let outcome = self.candidatePresenter.presentAsync(
                                preedit: result.preedit,
                                reranked: result.candidates,
                                leadMargin: result.leadMargin
                            )
                            LatencyProbe.shared.recordAsyncApplied(ms: asyncMs, flippedTop1: outcome.flippedTop1)
                            if outcome.didChange {
                                self.currentPresentedCandidates = self.candidatePresenter.currentCandidates
                                self.currentCandidates = self.currentPresentedCandidates.map {
                                    RimeCandidateItem(text: $0.text, comment: $0.comment)
                                }
                                AppDelegate.sharedCandidates?.update()
                            }
                        }
                    )
                    }
                }
            }
        }
    }

    private func clearMarkedText(client: (any IMKTextInput)?) {
        client?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func utf16Offset(fromUTF8Offset offset: Int, in string: String) -> Int {
        let clamped = max(0, min(offset, string.utf8.count))
        let utf8Index = string.utf8.index(string.utf8.startIndex, offsetBy: clamped)
        let strIndex = String.Index(utf8Index, within: string) ?? string.endIndex
        return strIndex.utf16Offset(in: string)
    }

    private static func isPinyinSyllableCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
            return true
        }
        // Pinyin ü and tone-marked Latin vowels (e.g. ā á ǎ à ō ó ǒ ò ē é ě è ī í ǐ ì ū ú ǔ ù ǖ ǘ ǚ ǜ)
        return (0x00C0...0x024F).contains(v)
    }

    /// Formats Rime's space-delimited unconverted pinyin syllables with visible `'` separators
    /// (e.g. `xian zai shi shi` -> `xian'zai'shi'shi`), while keeping converted text untouched
    /// and preserving 1:1 UTF-8 and UTF-16 byte lengths for exact cursor/selection mapping.
    static func formatDisplayPreedit(_ preedit: String, selStartUTF8: Int) -> String {
        guard preedit.contains(" ") else { return preedit }
        let clampedUTF8 = max(0, min(selStartUTF8, preedit.utf8.count))
        let utf8Idx = preedit.utf8.index(preedit.utf8.startIndex, offsetBy: clampedUTF8)
        let rawStart = String.Index(utf8Idx, within: preedit) ?? preedit.startIndex

        let convertedPrefix = preedit[..<rawStart]
        let rawChars = Array(preedit[rawStart...])
        guard !rawChars.isEmpty else { return preedit }

        var formatted = String(convertedPrefix)
        formatted.reserveCapacity(preedit.count)
        for i in 0..<rawChars.count {
            let ch = rawChars[i]
            if ch == " ",
               i > 0, i + 1 < rawChars.count,
               isPinyinSyllableCharacter(rawChars[i - 1]),
               isPinyinSyllableCharacter(rawChars[i + 1]) {
                formatted.append("'")
            } else {
                formatted.append(ch)
            }
        }
        return formatted
    }

    private func updateMarkedText(_ context: RimeContextSnapshot, client: (any IMKTextInput)?) {
        currentPreeditSelStart = context.selStart
        let preedit = Self.formatDisplayPreedit(context.preedit, selStartUTF8: context.selStart)
        let totalUTF16 = preedit.utf16.count
        let selStartUTF16 = utf16Offset(fromUTF8Offset: context.selStart, in: preedit)
        let cursorUTF16 = utf16Offset(fromUTF8Offset: context.cursorPos, in: preedit)

        let attrStr = NSMutableAttributedString(string: preedit)
        if selStartUTF16 > 0 {
            let convertedRange = NSRange(location: 0, length: selStartUTF16)
            if let attrs = mark(forStyle: Int(kTSMHiliteConvertedText), at: convertedRange) as? [NSAttributedString.Key: Any] {
                attrStr.setAttributes(attrs, range: convertedRange)
            }
        }
        if selStartUTF16 < totalUTF16 {
            let rawRange = NSRange(location: selStartUTF16, length: totalUTF16 - selStartUTF16)
            if let attrs = mark(forStyle: Int(kTSMHiliteSelectedRawText), at: rawRange) as? [NSAttributedString.Key: Any] {
                attrStr.setAttributes(attrs, range: rawRange)
            }
        }

        client?.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: cursorUTF16, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    // MARK: - Menu & Preferences

    override func showPreferences(_ sender: Any!) {
        DispatchQueue.main.async {
            SettingsHelperLauncher.shared.showSettings()
        }
    }

    override func menu() -> NSMenu! {
        ensureValidSession()
        let settings = InputSettings.shared
        let menu = NSMenu(title: "Prime 输入法")

        let settingsItem = NSMenuItem(title: "Prime 输入法设置…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 快捷功能
        let voiceShortcutSuffix: String
        if settings.shortcutVoiceStart && !settings.shortcutVoiceStartKey.isEmpty {
            let cleanKey = settings.shortcutVoiceStartKey.replacingOccurrences(of: " ", with: "+")
            voiceShortcutSuffix = " (\(cleanKey))"
        } else {
            voiceShortcutSuffix = ""
        }
        let voiceItem = NSMenuItem(title: "语音输入\(voiceShortcutSuffix)", action: #selector(menuTriggerVoice(_:)), keyEquivalent: "")
        voiceItem.target = self
        menu.addItem(voiceItem)

        let clipboardItem = NSMenuItem(title: "剪贴板", action: #selector(menuOpenClipboard(_:)), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        let phrasesItem = NSMenuItem(title: "常用语", action: #selector(menuOpenPhrases(_:)), keyEquivalent: "")
        phrasesItem.target = self
        menu.addItem(phrasesItem)

        let symbolsItem = NSMenuItem(title: "符号", action: #selector(menuOpenSymbols(_:)), keyEquivalent: "")
        symbolsItem.target = self
        menu.addItem(symbolsItem)

        menu.addItem(NSMenuItem.separator())

        // 输入状态切换
        let tradOption = RimeEngine.shared.currentPreset.traditionalOptionName
        let isTraditional = RimeEngine.shared.getOption(sessionId: sessionId, name: tradOption)
        let tradItem = NSMenuItem(
            title: isTraditional ? "切换至简体输入" : "切换至繁体输入",
            action: #selector(menuToggleTraditional(_:)),
            keyEquivalent: settings.shortcutTraditional ? "f" : ""
        )
        if settings.shortcutTraditional {
            tradItem.keyEquivalentModifierMask = [.option, .shift]
        }
        tradItem.target = self
        menu.addItem(tradItem)

        let isAsciiPunct = RimeEngine.shared.getOption(sessionId: sessionId, name: "ascii_punct")
        let punctItem = NSMenuItem(
            title: "使用英文标点符号",
            action: #selector(menuToggleAsciiPunct(_:)),
            keyEquivalent: settings.shortcutAsciiPunct ? "." : ""
        )
        if settings.shortcutAsciiPunct {
            punctItem.keyEquivalentModifierMask = [.option, .shift]
        }
        punctItem.state = isAsciiPunct ? .on : .off
        punctItem.target = self
        menu.addItem(punctItem)

        let isFullShape = RimeEngine.shared.getOption(sessionId: sessionId, name: "full_shape")
        let fullShapeItem = NSMenuItem(
            title: "使用全角输入",
            action: #selector(menuToggleFullShape(_:)),
            keyEquivalent: settings.shortcutFullShape ? "h" : ""
        )
        if settings.shortcutFullShape {
            fullShapeItem.keyEquivalentModifierMask = [.option, .shift]
        }
        fullShapeItem.state = isFullShape ? .on : .off
        fullShapeItem.target = self
        menu.addItem(fullShapeItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于 Prime 输入法", action: #selector(menuOpenAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        return menu
    }

    @objc private func menuTriggerVoice(_ sender: Any?) {
        DispatchQueue.main.async {
            VoiceInputManager.shared.toggleTapRecording()
        }
    }

    @objc private func menuOpenClipboard(_ sender: Any?) {
        DispatchQueue.main.async {
            ClipboardPanelController.shared.show()
        }
    }

    @objc private func menuOpenPhrases(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enterVMode(client: self.currentClient)
            self.executeVModeMenuItem(.phrases, client: self.currentClient)
        }
    }

    @objc private func menuOpenSymbols(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enterVMode(client: self.currentClient)
            self.executeVModeMenuItem(.symbols, client: self.currentClient)
        }
    }

    @objc private func menuToggleTraditional(_ sender: Any?) {
        ensureValidSession()
        RimeEngine.shared.toggleOption(
            sessionId: sessionId,
            name: RimeEngine.shared.currentPreset.traditionalOptionName
        )
    }

    @objc private func menuToggleAsciiPunct(_ sender: Any?) {
        ensureValidSession()
        RimeEngine.shared.toggleOption(sessionId: sessionId, name: "ascii_punct")
    }

    @objc private func menuToggleFullShape(_ sender: Any?) {
        ensureValidSession()
        RimeEngine.shared.toggleOption(sessionId: sessionId, name: "full_shape")
    }

    @objc private func menuOpenAbout(_ sender: Any?) {
        DispatchQueue.main.async {
            SettingsHelperLauncher.shared.showAbout()
        }
    }
}
