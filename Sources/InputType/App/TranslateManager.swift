import Cocoa
import Carbon
import NaturalLanguage

enum TranslateLanguage: String, CaseIterable, Identifiable, Codable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"
    case es = "es"
    case ru = "ru"
    case it = "it"
    case pt = "pt"
    case ar = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .en: return "英语"
        case .ja: return "日语"
        case .ko: return "韩语"
        case .fr: return "法语"
        case .de: return "德语"
        case .es: return "西班牙语"
        case .ru: return "俄语"
        case .it: return "意大利语"
        case .pt: return "葡萄牙语"
        case .ar: return "阿拉伯语"
        }
    }

    var promptName: String {
        switch self {
        case .zhHans: return "Simplified Chinese (简体中文)"
        case .zhHant: return "Traditional Chinese (繁體中文)"
        case .en: return "English"
        case .ja: return "Japanese (日本語)"
        case .ko: return "Korean (한국어)"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .ru: return "Russian"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .ar: return "Arabic"
        }
    }

    static func from(nlLanguage: NLLanguage) -> TranslateLanguage? {
        switch nlLanguage {
        case .simplifiedChinese: return .zhHans
        case .traditionalChinese: return .zhHant
        case .english: return .en
        case .japanese: return .ja
        case .korean: return .ko
        case .french: return .fr
        case .german: return .de
        case .spanish: return .es
        case .russian: return .ru
        case .italian: return .it
        case .portuguese: return .pt
        case .arabic: return .ar
        default: return nil
        }
    }
}

enum QuickActionKind {
    case translate
    case rewrite

    var title: String {
        switch self {
        case .translate: return "翻译"
        case .rewrite: return "改写"
        }
    }

    var systemImage: String {
        switch self {
        case .translate: return "bubble.left.and.text.bubble.right"
        case .rewrite: return "wand.and.stars"
        }
    }
}

enum QuickActionDiffEngine {
    enum Chunk: Equatable {
        case equal(String)
        case inserted(String)
        case deleted(String)
    }

    static let maxTokens = 4_000

    static func diff(original: String, modified: String) -> [Chunk] {
        if original == modified { return original.isEmpty ? [] : [.equal(original)] }
        if original.isEmpty { return [.inserted(modified)] }
        if modified.isEmpty { return [.deleted(original)] }

        let old = tokenize(original)
        let new = tokenize(modified)
        guard old.count <= maxTokens, new.count <= maxTokens else {
            return [.deleted(original), .inserted(modified)]
        }

        let traceback = Traceback(old, new)
        var reversed: [Chunk] = []
        var i = old.count
        var j = new.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                reversed.append(.equal(old[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || traceback.inserts(row: i - 1, column: j - 1) {
                reversed.append(.inserted(new[j - 1]))
                j -= 1
            } else {
                reversed.append(.deleted(old[i - 1]))
                i -= 1
            }
        }
        return coalesce(reversed.reversed())
    }

    private static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWord = false
        for character in string {
            let isWordCharacter = character.isLetter || character.isNumber
            if isWordCharacter == inWord, !current.isEmpty {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                inWord = isWordCharacter
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private struct Traceback {
        let columns: Int
        let insertions: [UInt8]

        init(_ old: [String], _ new: [String]) {
            columns = new.count
            var scores = [UInt16](repeating: 0, count: new.count + 1)
            var bits = [UInt8](repeating: 0, count: (old.count * new.count + 7) / 8)
            for i in old.indices {
                var diagonal: UInt16 = 0
                for j in new.indices {
                    let above = scores[j + 1]
                    if old[i] == new[j] {
                        scores[j + 1] = diagonal + 1
                    } else if scores[j] >= above {
                        scores[j + 1] = scores[j]
                        let index = i * new.count + j
                        bits[index >> 3] |= UInt8(1) << (index & 7)
                    }
                    diagonal = above
                }
            }
            insertions = bits
        }

        func inserts(row: Int, column: Int) -> Bool {
            let index = row * columns + column
            return insertions[index >> 3] & (UInt8(1) << (index & 7)) != 0
        }
    }

    private static func coalesce(_ chunks: [Chunk]) -> [Chunk] {
        chunks.reduce(into: []) { result, chunk in
            switch (result.last, chunk) {
            case (.equal(let a), .equal(let b)): result[result.count - 1] = .equal(a + b)
            case (.inserted(let a), .inserted(let b)): result[result.count - 1] = .inserted(a + b)
            case (.deleted(let a), .deleted(let b)): result[result.count - 1] = .deleted(a + b)
            default: result.append(chunk)
            }
        }
    }
}

enum TranslateCaptureMode {
    case selection
    case wholeInputField
}

enum TranslateShortcutHelper {
    static let doubleTapPrefix = "双击 "

    static func doubleTapModifierKeyCode(for spec: String) -> UInt16? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(doubleTapPrefix) else { return nil }
        let rest = String(trimmed.dropFirst(doubleTapPrefix.count))
        return VoiceShortcutFormatter.singleModifierKeyCode(for: rest)
    }

    static func isDoubleTapSpec(_ spec: String) -> Bool {
        doubleTapModifierKeyCode(for: spec) != nil
    }

    static func isModifierPressed(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 63: return flags.contains(.function)
        case 61, 58: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 62, 59: return flags.contains(.control)
        case 60, 56: return flags.contains(.shift)
        default: return false
        }
    }
}

final class TranslateManager: ObservableObject {
    static let shared = TranslateManager()
    static var isRecordingShortcut = false

    @Published private(set) var activeAction: QuickActionKind = .translate
    @Published private(set) var isProcessing = false
    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var diffChunks: [QuickActionDiffEngine.Chunk] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var detectedLanguageLabel: String = ""
    @Published private(set) var targetLanguageLabel: String = ""
    @Published private(set) var selectedSourceLanguage: TranslateLanguage? = nil
    @Published private(set) var selectedTargetLanguage: TranslateLanguage = .en

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    // Double-tap modifier state machine
    private var downModifierCode: UInt16?
    private var downModifierCancelled = false
    private var downModifierAt = Date.distantPast
    private var lastTapModifierCode: UInt16?
    private var lastTapModifierAt = Date.distantPast
    private var lastFlagsStamp: (code: UInt16, rawFlags: UInt, timeMs: Int) = (0, 0, -1000)
    private var lastKeyDownStamp: (code: UInt16, timeMs: Int) = (0, -1000)

    // Active translation session context
    private var currentTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    private var focusedAXElement: AXUIElement?
    private var captureMode: TranslateCaptureMode = .selection

    private init() {}

    func startMonitors() {
        guard globalFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChangedEvent(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChangedEvent(event)
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyDownEvent(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDownEvent(event) == true {
                return nil
            }
            return event
        }
    }

    // MARK: - Shortcut Monitoring

    private func activeDoubleTapTargets() -> [(code: UInt16, action: QuickActionKind)] {
        let settings = InputSettings.shared
        var targets: [(UInt16, QuickActionKind)] = []
        if settings.translateEnabled,
           let code = TranslateShortcutHelper.doubleTapModifierKeyCode(for: settings.translateShortcutKey) {
            targets.append((code, .translate))
        }
        if settings.rewriteEnabled,
           let code = TranslateShortcutHelper.doubleTapModifierKeyCode(for: settings.rewriteShortcutKey) {
            targets.append((code, .rewrite))
        }
        return targets
    }

    func handleFlagsChangedEvent(_ event: NSEvent) {
        guard !Self.isRecordingShortcut, !VoiceInputManager.isRecordingShortcut else { return }

        let targets = activeDoubleTapTargets()
        guard !targets.isEmpty else { return }

        let nowMs = Int(event.timestamp * 1000)
        let rawFlags = event.modifierFlags.intersection([.function, .command, .option, .control, .shift]).rawValue
        if event.keyCode == lastFlagsStamp.code && rawFlags == lastFlagsStamp.rawFlags && abs(nowMs - lastFlagsStamp.timeMs) < 20 {
            return
        }
        lastFlagsStamp = (event.keyCode, rawFlags, nowMs)

        let code = event.keyCode
        guard let matched = targets.first(where: { $0.code == code }) else {
            if downModifierCode != nil {
                downModifierCancelled = true
            }
            lastTapModifierCode = nil
            return
        }

        let isPressed = TranslateShortcutHelper.isModifierPressed(code: code, flags: event.modifierFlags)
        let now = Date()
        if isPressed {
            if downModifierCode == nil {
                downModifierCode = code
                downModifierCancelled = false
                downModifierAt = now
            }
        } else if downModifierCode == code {
            let pressDuration = now.timeIntervalSince(downModifierAt)
            let wasCancelled = downModifierCancelled
            downModifierCode = nil
            downModifierCancelled = false

            guard !wasCancelled, pressDuration < 0.35 else {
                lastTapModifierCode = nil
                return
            }

            if lastTapModifierCode == code && now.timeIntervalSince(lastTapModifierAt) < 0.42 {
                lastTapModifierCode = nil
                lastTapModifierAt = .distantPast
                triggerAction(matched.action)
            } else {
                lastTapModifierCode = code
                lastTapModifierAt = now
            }
        }
    }

    @discardableResult
    func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        guard !Self.isRecordingShortcut, !VoiceInputManager.isRecordingShortcut else { return false }

        // Any regular keyDown cancels pending modifier double-tap
        if downModifierCode != nil {
            downModifierCancelled = true
        }
        lastTapModifierCode = nil

        let nowMs = Int(event.timestamp * 1000)
        if event.keyCode == lastKeyDownStamp.code && abs(nowMs - lastKeyDownStamp.timeMs) < 20 {
            return false
        }
        lastKeyDownStamp = (event.keyCode, nowMs)

        // Escape closes popup if visible
        if event.keyCode == 0x35 && TranslatePopupController.shared.isVisible {
            close()
            return true
        }

        let settings = InputSettings.shared
        if settings.translateEnabled {
            let spec = settings.translateShortcutKey
            if !TranslateShortcutHelper.isDoubleTapSpec(spec),
               VoiceShortcutFormatter.matches(keyDown: event, spec: spec) {
                triggerAction(.translate)
                return true
            }
        }
        if settings.rewriteEnabled {
            let spec = settings.rewriteShortcutKey
            if !TranslateShortcutHelper.isDoubleTapSpec(spec),
               VoiceShortcutFormatter.matches(keyDown: event, spec: spec) {
                triggerAction(.rewrite)
                return true
            }
        }
        return false
    }

    // MARK: - Trigger & Capture Text

    func triggerTranslate() {
        triggerAction(.translate)
    }

    func triggerRewrite() {
        triggerAction(.rewrite)
    }

    func triggerAction(_ action: QuickActionKind) {
        currentTask?.cancel()
        currentTask = nil

        let frontApp = NSWorkspace.shared.frontmostApplication
        let externalApp = (frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier) ? frontApp : nil
        targetApp = externalApp
        focusedAXElement = nil

        // 0ms instant feedback: show popup immediately below the active selection/cursor
        // (or near the mouse pointer otherwise). Keep key focus on the target app briefly
        // in case clipboard fallback needs to send Cmd+C.
        let cursorAnchor = InputTypeController.activeSelectionRect(forBundleID: externalApp?.bundleIdentifier)
        activeAction = action
        sourceText = ""
        translatedText = ""
        diffChunks = []
        errorMessage = nil
        detectedLanguageLabel = ""
        targetLanguageLabel = ""
        selectedSourceLanguage = nil
        selectedTargetLanguage = InputSettings.shared.translatePrimaryLanguage
        isProcessing = true
        TranslatePopupController.shared.show(near: cursorAnchor, makeKey: false)

        // Dispatch text capture on next runloop tick so the popup renders immediately on screen
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isProcessing else { return }
            self.captureAndRun(action: action, in: externalApp, initialAnchor: cursorAnchor)
        }
    }

    private func captureAndRun(action: QuickActionKind, in app: NSRunningApplication?, initialAnchor: NSRect?) {
        let axElement = captureFocusedElement(in: app)
        focusedAXElement = axElement

        // 1. Try direct AX selected text (including WebKit/Chromium AXSelectedTextMarkerRange)
        if let axElement, let selected = readAXSelection(in: axElement),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureMode = .selection
            let refinedAnchor = resolveSelectionAnchor(
                axElement: axElement,
                mode: .selection,
                selectedText: selected,
                fallback: initialAnchor
            )
            startAction(action: action, text: selected, anchorRect: refinedAnchor, alreadyShown: true)
            return
        }

        // 2. Try AX editable input field value (user typed in an input box then pressed shortcut)
        if let axElement, isEditableInputElement(axElement),
           let value = copyStringAttribute(axElement, kAXValueAttribute as CFString),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureMode = .wholeInputField
            let refinedAnchor = resolveSelectionAnchor(
                axElement: axElement,
                mode: .wholeInputField,
                selectedText: value,
                fallback: initialAnchor
            )
            startAction(action: action, text: value, anchorRect: refinedAnchor, alreadyShown: true)
            return
        }

        // 3. Fallback for apps that don't expose AX selection/value:
        //    Temporarily simulate Cmd+C (restoring pasteboard); if unchanged and in an input field, Cmd+A + Cmd+C.
        captureTextViaClipboardFallback(isLikelyInput: (axElement.map(isEditableInputElement) ?? false) || InputTypeController.isServerCurrentlyActive) { [weak self] text, mode in
            guard let self, self.isProcessing else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showErrorPopup("未获取到可\(action.title)的文本，请先选中文本或在输入框中输入内容。", anchorRect: initialAnchor)
                return
            }
            self.captureMode = mode
            let refinedAnchor = self.resolveSelectionAnchor(
                axElement: axElement,
                mode: mode,
                selectedText: text,
                fallback: initialAnchor
            )
            self.startAction(action: action, text: text, anchorRect: refinedAnchor, alreadyShown: true)
        }
    }

    private func showErrorPopup(_ message: String, anchorRect: NSRect?) {
        isProcessing = false
        sourceText = ""
        translatedText = ""
        detectedLanguageLabel = ""
        targetLanguageLabel = ""
        errorMessage = message
        if TranslatePopupController.shared.isVisible {
            TranslatePopupController.shared.updateLayout()
            TranslatePopupController.shared.focusPanel()
        } else {
            TranslatePopupController.shared.show(near: anchorRect, makeKey: true)
        }
    }

    func setSourceLanguage(_ language: TranslateLanguage?) {
        guard activeAction == .translate else { return }
        let previousSource = selectedSourceLanguage
        if let language, language == selectedTargetLanguage {
            let settings = InputSettings.shared
            if let previousSource, previousSource != language {
                selectedTargetLanguage = previousSource
            } else {
                selectedTargetLanguage = (language == settings.translatePrimaryLanguage)
                    ? settings.translateSecondaryLanguage
                    : settings.translatePrimaryLanguage
            }
        }
        selectedSourceLanguage = language
        detectedLanguageLabel = language?.displayName ?? "自动"
        targetLanguageLabel = selectedTargetLanguage.displayName
        retranslateCurrentText()
    }

    func setTargetLanguage(_ language: TranslateLanguage) {
        guard activeAction == .translate else { return }
        let previousTarget = selectedTargetLanguage
        if selectedSourceLanguage == language {
            selectedSourceLanguage = (previousTarget != language) ? previousTarget : nil
        }
        selectedTargetLanguage = language
        detectedLanguageLabel = selectedSourceLanguage?.displayName ?? "自动"
        targetLanguageLabel = selectedTargetLanguage.displayName
        retranslateCurrentText()
    }

    func swapLanguages() {
        guard activeAction == .translate else { return }
        guard let currentSource = selectedSourceLanguage, currentSource != selectedTargetLanguage else { return }
        let oldTarget = selectedTargetLanguage
        selectedSourceLanguage = oldTarget
        selectedTargetLanguage = currentSource
        detectedLanguageLabel = oldTarget.displayName
        targetLanguageLabel = currentSource.displayName
        retranslateCurrentText()
    }

    private func retranslateCurrentText() {
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentTask?.cancel()
        currentTask = nil
        startAction(
            action: .translate,
            text: text,
            anchorRect: nil,
            alreadyShown: true,
            useManualLanguages: true
        )
    }

    private func startAction(
        action: QuickActionKind,
        text: String,
        anchorRect: NSRect?,
        alreadyShown: Bool = false,
        useManualLanguages: Bool = false
    ) {
        let settings = InputSettings.shared
        let resolved: (AIProviderConfig, String)?
        let systemPrompt: String
        let temperature: Double

        switch action {
        case .translate:
            resolved = settings.resolvedTranslateProviderAndModel()
            let sourceLang: TranslateLanguage?
            let targetLang: TranslateLanguage
            if useManualLanguages {
                sourceLang = selectedSourceLanguage
                targetLang = selectedTargetLanguage
            } else {
                let detected = Self.detectDominantLanguage(of: text)
                sourceLang = detected
                targetLang = Self.resolveTargetLanguage(
                    detected: detected,
                    primary: settings.translatePrimaryLanguage,
                    secondary: settings.translateSecondaryLanguage
                )
                selectedSourceLanguage = sourceLang
                selectedTargetLanguage = targetLang
            }
            detectedLanguageLabel = sourceLang?.displayName ?? "自动"
            targetLanguageLabel = targetLang.displayName
            let directionPhrase: String
            if let sourceLang {
                directionPhrase = "from \(sourceLang.promptName) into \(targetLang.promptName)"
            } else {
                directionPhrase = "into \(targetLang.promptName)"
            }
            systemPrompt = """
            You are a professional translator. Translate the user's text \(directionPhrase) accurately, naturally, and idiomatically.
            Rules:
            1. Output ONLY the translated text without any explanations, notes, surrounding quotes, or prefixes.
            2. Preserve original formatting, line breaks, markdown syntax, code snippets, and placeholders.
            3. Keep the tone and intent faithful to the original text.
            """
            temperature = 0.2

        case .rewrite:
            resolved = settings.resolvedRewriteProviderAndModel()
            detectedLanguageLabel = ""
            targetLanguageLabel = ""
            let trimmedPrompt = settings.rewriteSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            systemPrompt = trimmedPrompt.isEmpty ? InputSettings.defaultRewriteSystemPrompt : trimmedPrompt
            temperature = 0.3
        }

        guard let (provider, modelID) = resolved else {
            showErrorPopup("尚未配置\(action.title)模型，请先在「设置 → 快速操作 → 提供商 / \(action.title)」中配置。", anchorRect: anchorRect)
            return
        }

        activeAction = action
        sourceText = text
        translatedText = ""
        diffChunks = []
        errorMessage = nil
        isProcessing = true
        if alreadyShown && TranslatePopupController.shared.isVisible {
            TranslatePopupController.shared.updateLayout()
            TranslatePopupController.shared.focusPanel()
        } else {
            TranslatePopupController.shared.show(near: anchorRect, makeKey: true)
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.streamOpenAIResponse(
                    text: text,
                    systemPrompt: systemPrompt,
                    temperature: temperature,
                    provider: provider,
                    modelID: modelID,
                    actionTitle: action.title
                )
                await MainActor.run {
                    self.isProcessing = false
                    let trimmed = self.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.errorMessage = "模型未返回\(action.title)内容"
                    } else if action == .rewrite {
                        self.diffChunks = QuickActionDiffEngine.diff(
                            original: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            modified: trimmed
                        )
                    }
                    TranslatePopupController.shared.updateLayout()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    TranslatePopupController.shared.updateLayout()
                }
            }
        }
    }

    // MARK: - Language Proportion Detection & Target Selection

    static func detectDominantLanguage(of text: String) -> TranslateLanguage? {
        var hanCount = 0
        var kanaCount = 0
        var hangulCount = 0
        var cyrillicCount = 0
        var arabicCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v) {
                hanCount += 1
            } else if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                kanaCount += 1
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) {
                hangulCount += 1
            } else if (0x0400...0x04FF).contains(v) {
                cyrillicCount += 1
            } else if (0x0600...0x06FF).contains(v) {
                arabicCount += 1
            } else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) || (0x00C0...0x024F).contains(v) {
                latinCount += 1
            }
        }

        let total = hanCount + kanaCount + hangulCount + cyrillicCount + arabicCount + latinCount
        guard total > 0 else { return nil }

        // Japanese: Kana present alongside optional Kanji
        if kanaCount > 0 && Double(kanaCount + hanCount) / Double(total) >= 0.35 && Double(kanaCount) / Double(max(1, kanaCount + hanCount)) >= 0.12 {
            return .ja
        }
        // Korean: Hangul proportion dominates
        if Double(hangulCount) / Double(total) >= 0.35 {
            return .ko
        }
        // Russian / Cyrillic
        if Double(cyrillicCount) / Double(total) >= 0.35 {
            return .ru
        }
        // Arabic
        if Double(arabicCount) / Double(total) >= 0.35 {
            return .ar
        }
        // Chinese: Han proportion dominates
        if Double(hanCount) / Double(total) >= 0.35 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if recognizer.dominantLanguage == .traditionalChinese {
                return .zhHant
            }
            return .zhHans
        }

        // Latin or mixed text: use NLLanguageRecognizer to distinguish English/French/German/Spanish/etc.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dom = recognizer.dominantLanguage, let mapped = TranslateLanguage.from(nlLanguage: dom) {
            return mapped
        }
        if latinCount > 0 {
            return .en
        }
        return nil
    }

    static func resolveTargetLanguage(
        detected: TranslateLanguage?,
        primary: TranslateLanguage,
        secondary: TranslateLanguage
    ) -> TranslateLanguage {
        guard let detected else { return primary }
        if detected == primary {
            return secondary
        }
        if detected == secondary {
            return primary
        }
        return primary
    }

    // MARK: - OpenAI-Compatible Streaming Response

    private func streamOpenAIResponse(
        text: String,
        systemPrompt: String,
        temperature: Double,
        provider: AIProviderConfig,
        modelID: String,
        actionTitle: String
    ) async throws {
        let rawBase = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        let endpointString = normalizedBase.hasSuffix("/chat/completions")
            ? normalizedBase
            : "\(normalizedBase)/chat/completions"

        guard let url = URL(string: endpointString) else {
            throw NSError(domain: "TranslateManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "基础 URL 格式无效：\(endpointString)"
            ])
        }

        let body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for header in provider.headers {
            let hKey = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hKey.isEmpty else { continue }
            request.setValue(header.value, forHTTPHeaderField: hKey)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TranslateManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无效的网络响应"
            ])
        }

        if !(200...299).contains(http.statusCode) {
            var errData = Data()
            for try await b in bytes {
                errData.append(b)
                if errData.count >= 1024 { break }
            }
            let preview = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(180) ?? ""
            throw NSError(domain: "TranslateManager", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(actionTitle)请求失败 (HTTP \(http.statusCode))\(preview.isEmpty ? "" : "：\(preview)")"
            ])
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") {
            var fullData = Data()
            for try await b in bytes {
                fullData.append(b)
            }
            if let content = Self.extractNonStreamingContent(from: fullData) {
                await MainActor.run {
                    self.translatedText = content
                    TranslatePopupController.shared.updateLayout()
                }
            }
            return
        }

        var accumulated = ""
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let delta = Self.extractSSEDelta(from: data), !delta.isEmpty else {
                continue
            }
            accumulated += delta
            let snapshot = accumulated
            await MainActor.run {
                self.translatedText = snapshot
                TranslatePopupController.shared.updateLayout()
            }
        }
    }

    private static func extractSSEDelta(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
            return content
        }
        if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
            return content
        }
        return nil
    }

    private static func extractNonStreamingContent(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions (Close / Copy / Replace)

    func close() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        TranslatePopupController.shared.hide()
    }

    func copyResult() {
        let text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        close()
    }

    func replaceResult() {
        let text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let mode = captureMode
        let element = focusedAXElement
        let app = targetApp

        close()

        // Try direct AX replacement first for whole input field
        if mode == .wholeInputField, let element {
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                return
            }
        }

        // Activate target app and replace selection or whole field via clipboard + Cmd+V (preserving original clipboard)
        if let app, !app.isActive {
            app.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.pasteReplacing(text: text, selectAllFirst: mode == .wholeInputField)
        }
    }

    // MARK: - Accessibility & Clipboard Helpers

    private static let axTimeout: Float = 0.4

    private func captureFocusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        let root: AXUIElement
        if let app {
            root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, Self.axTimeout)
            // Chromium / Electron only builds its AX tree once AXManualAccessibility is enabled
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        } else {
            root = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(root, Self.axTimeout)
        }

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let obj = focusedRef,
              CFGetTypeID(obj) == AXUIElementGetTypeID() else {
            return nil
        }
        let el = obj as! AXUIElement
        AXUIElementSetMessagingTimeout(el, Self.axTimeout)
        return el
    }

    private func readAXSelection(in element: AXUIElement) -> String? {
        if let text = copyStringAttribute(element, kAXSelectedTextAttribute as CFString), !text.isEmpty {
            return text
        }
        // Browsers & Electron expose web selection via AXSelectedTextMarkerRange
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success, let markerRange else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    /// Resolves the best full bounding rect (in AppKit screen coordinates) for the selected text
    /// or input field so the popup always appears cleanly below (or above) all selected lines.
    private func resolveSelectionAnchor(
        axElement: AXUIElement?,
        mode: TranslateCaptureMode,
        selectedText: String,
        fallback: NSRect?
    ) -> NSRect? {
        if let axElement {
            if mode == .selection, let axBounds = readAXSelectionBounds(in: axElement) {
                return axBounds
            }
            if mode == .wholeInputField {
                if let axTextBounds = readAXFullTextBounds(in: axElement) {
                    return axTextBounds
                }
                if let axFrame = readAXElementFrame(axElement) {
                    return axFrame
                }
            }
        }

        // Fallback heuristic: if IMK only reported the first line of a multi-line selection
        // and the mouse cursor is positioned below that first line (typical mouse drag selection),
        // extend the anchor downward to include the mouse vertical position so lines 2..N aren't covered.
        if let base = fallback {
            let lineCount = selectedText.components(separatedBy: .newlines).count
            let looksMultiLine = lineCount > 1 || selectedText.count > 45
            if looksMultiLine && base.height < 42 {
                let mouse = NSEvent.mouseLocation
                let dyBelow = base.minY - mouse.y
                let dxNear = abs(mouse.x - base.minX)
                if dyBelow > 8 && dyBelow < 420 && dxNear < 900 {
                    let expandedMinY = mouse.y - 12
                    return NSRect(
                        x: base.minX,
                        y: expandedMinY,
                        width: max(base.width, 1),
                        height: base.maxY - expandedMinY
                    )
                }
            }
            return base
        }

        return nil
    }

    private func readAXSelectionBounds(in element: AXUIElement) -> NSRect? {
        // 1. Standard AX text controls: AXSelectedTextRange -> AXBoundsForRange
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeVal = rangeRef,
           CFGetTypeID(rangeVal) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(rangeVal as! AXValue, .cfRange, &cfRange), cfRange.length > 0 {
                if let rect = axBoundsForCFRange(element: element, range: cfRange) {
                    return rect
                }
            }
        }

        // 2. WebKit / Chromium / Electron: AXSelectedTextMarkerRange -> AXBoundsForTextMarkerRange
        var markerRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
           let markerRange {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXBoundsForTextMarkerRange" as CFString,
                markerRange,
                &boundsRef
            ) == .success,
               let boundsVal = boundsRef,
               CFGetTypeID(boundsVal) == AXValueGetTypeID() {
                var cgRect = CGRect.zero
                if AXValueGetValue(boundsVal as! AXValue, .cgRect, &cgRect),
                   let converted = convertAXRectToCocoa(cgRect) {
                    return converted
                }
            }
        }

        return nil
    }

    private func readAXFullTextBounds(in element: AXUIElement) -> NSRect? {
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let countNum = countRef as? NSNumber,
              countNum.intValue > 0 else {
            return nil
        }
        return axBoundsForCFRange(element: element, range: CFRange(location: 0, length: countNum.intValue))
    }

    private func axBoundsForCFRange(element: AXUIElement, range: CFRange) -> NSRect? {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        ) == .success,
              let boundsVal = boundsRef,
              CFGetTypeID(boundsVal) == AXValueGetTypeID() else {
            return nil
        }
        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsVal as! AXValue, .cgRect, &cgRect) else { return nil }
        return convertAXRectToCocoa(cgRect)
    }

    private func readAXElementFrame(_ element: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz) else {
            return nil
        }
        // Avoid anchoring to a huge container frame (e.g. an entire editor pane)
        guard sz.height > 0 && sz.height < 420 else { return nil }
        return convertAXRectToCocoa(CGRect(origin: pt, size: sz))
    }

    /// Converts a Quartz/AX top-left screen CGRect to AppKit bottom-left screen NSRect.
    private func convertAXRectToCocoa(_ axRect: CGRect) -> NSRect? {
        guard axRect.origin.x.isFinite && axRect.origin.y.isFinite &&
              axRect.size.width.isFinite && axRect.size.height.isFinite else {
            return nil
        }
        guard axRect.size.width > 0 || axRect.size.height > 0 else { return nil }
        guard axRect.origin.x != 0 || axRect.origin.y != 0 else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        let cocoa = NSRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.origin.y - axRect.size.height,
            width: max(axRect.size.width, 1),
            height: max(axRect.size.height, 18)
        )
        guard NSScreen.screens.contains(where: { $0.frame.intersects(cocoa) }) else {
            return nil
        }
        return cocoa
    }

    private func copyStringAttribute(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func isEditableInputElement(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if let role = copyStringAttribute(el, kAXRoleAttribute as CFString) {
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        }
        return false
    }

    private func captureTextViaClipboardFallback(
        isLikelyInput: Bool,
        completion: @escaping (String?, TranslateCaptureMode) -> Void
    ) {
        guard ClipboardManager.shared.isAccessibilityTrusted else {
            completion(nil, .selection)
            return
        }

        let pb = NSPasteboard.general
        let savedItems = Self.snapshotPasteboard(pb)
        let beforeCount = pb.changeCount

        Self.postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_C))
        Self.waitForPasteboardChange(pb, initialCount: beforeCount, timeout: 0.08) { changed in
            if changed, let str = pb.string(forType: .string), !str.isEmpty {
                Self.restorePasteboard(pb, items: savedItems)
                completion(str, .selection)
                return
            }

            guard isLikelyInput else {
                Self.restorePasteboard(pb, items: savedItems)
                completion(nil, .selection)
                return
            }

            // Nothing selected in an editable field: select all + copy
            let beforeSelectAllCount = pb.changeCount
            Self.postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_A))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                Self.postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_C))
                Self.waitForPasteboardChange(pb, initialCount: beforeSelectAllCount, timeout: 0.08) { changedAll in
                    let captured = changedAll ? pb.string(forType: .string) : nil
                    Self.restorePasteboard(pb, items: savedItems)
                    completion(captured, .wholeInputField)
                }
            }
        }
    }

    private static func waitForPasteboardChange(
        _ pb: NSPasteboard,
        initialCount: Int,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if pb.changeCount != initialCount {
                ClipboardManager.shared.syncCurrentChangeCount()
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                poll()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            poll()
        }
    }

    private static func pasteReplacing(text: String, selectAllFirst: Bool) {
        let pb = NSPasteboard.general
        let savedItems = snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let expectedCount = pb.changeCount
        ClipboardManager.shared.syncCurrentChangeCount()

        if selectAllFirst {
            postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_A))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_V))
            }
        } else {
            postCommandKey(virtualKey: CGKeyCode(kVK_ANSI_V))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard pb.changeCount == expectedCount, !savedItems.isEmpty else { return }
            restorePasteboard(pb, items: savedItems)
        }
    }

    private static func postCommandKey(virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type), data.count <= 2 * 1024 * 1024 {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(items)
        ClipboardManager.shared.syncCurrentChangeCount()
    }
}
