import Cocoa
import Carbon
import Combine
import Darwin
import ImageIO
import ApplicationServices

enum ClipboardItemKind: String, Codable, CaseIterable, Identifiable {
    case text
    case image
    case link
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "纯文本"
        case .image: return "图像"
        case .link: return "链接"
        case .file: return "文件"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .link: return "link"
        case .file: return "doc"
        }
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipboardItemKind
    let text: String?
    let imageFilename: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let byteSize: Int
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        kind: ClipboardItemKind,
        text: String? = nil,
        imageFilename: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        byteSize: Int,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFilename = imageFilename
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteSize = byteSize
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = timestamp
    }

    var listTitle: String {
        switch kind {
        case .image:
            return "图像"
        case .text, .link, .file:
            let raw = text ?? ""
            let singleLine = raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return singleLine.isEmpty ? kind.displayName : singleLine
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    private static let fullDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return fmt
    }()

    var formattedTimestamp: String {
        let cal = Calendar.current
        let timePart = Self.timeFormatter.string(from: timestamp)
        if cal.isDateInToday(timestamp) {
            return "今天 \(timePart)"
        } else if cal.isDateInYesterday(timestamp) {
            return "昨天 \(timePart)"
        } else {
            return Self.fullDateFormatter.string(from: timestamp)
        }
    }

    var dateSectionTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(timestamp) { return "今天" }
        if cal.isDateInYesterday(timestamp) { return "昨天" }
        return "更早"
    }
}

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var entries: [ClipboardEntry] = []

    private struct PendingIMKTextPaste {
        let id: UUID
        let text: String
        let targetBundleID: String?
        let expiresAt: Date
    }

    private let historyURL: URL
    private let imagesDirURL: URL
    private let maxEntries = 50
    private var timer: Timer?
    private var lastChangeCount: Int
    private var cancellable: AnyCancellable?
    private var retentionCancellable: AnyCancellable?
    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 2 * 1024 * 1024 // 2 MB cap for 64px list icons
        return cache
    }()
    private let previewCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 6 * 1024 * 1024 // 6 MB cap for 720px detail previews
        return cache
    }()
    private var pendingIMKTextPaste: PendingIMKTextPaste?
    private var hasPromptedAccessibilityThisSession = false

    private init() {
        let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/InputType")
        self.imagesDirURL = userDir.appendingPathComponent("clipboard_images")
        try? FileManager.default.createDirectory(at: imagesDirURL, withIntermediateDirectories: true)
        self.historyURL = userDir.appendingPathComponent("clipboard_history.json")
        self.lastChangeCount = NSPasteboard.general.changeCount
        loadFromDisk()

        cancellable = InputSettings.shared.$clipboardEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.updateMonitoring(enabled: enabled)
            }

        retentionCancellable = InputSettings.shared.$clipboardRetentionDays
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pruneExpiredEntries()
            }
    }

    func syncWithSettings() {
        DispatchQueue.main.async { [weak self] in
            self?.updateMonitoring(enabled: InputSettings.shared.clipboardEnabled)
        }
    }

    private func updateMonitoring(enabled: Bool) {
        if enabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Standard macOS pasteboard types emitted by password managers (1Password, Keychain, Bitwarden)
    /// and transient/concealed clipboard operations that must never be stored in history.
    static let sensitivePasteboardTypeNames: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "PasswordPboardType"
    ]

    static func containsSensitiveType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        for t in types where sensitivePasteboardTypeNames.contains(t.rawValue) {
            return true
        }
        return false
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let types = pb.types ?? []
        if Self.containsSensitiveType(types) {
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName
        let appBundleId = frontApp?.bundleIdentifier

        // Check image first when pasteboard carries image data (and not a file/text copy with icon)
        let hasImageType = types.contains(.png) || types.contains(.tiff)
        let hasTextType = types.contains(.string)
        let hasFileType = types.contains(.fileURL)

        if hasFileType, let urlString = pb.string(forType: .fileURL), let fileURL = URL(string: urlString) {
            recordTextEntry(
                kind: .file,
                text: fileURL.path,
                sourceAppName: appName,
                sourceAppBundleID: appBundleId
            )
            return
        }

        if hasImageType && !hasTextType {
            if capturePasteboardImage(from: pb, sourceAppName: appName, sourceAppBundleID: appBundleId) {
                return
            }
        }

        if let raw = pb.string(forType: .string) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let kind: ClipboardItemKind = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? .link : .text
                recordTextEntry(
                    kind: kind,
                    text: raw,
                    sourceAppName: appName,
                    sourceAppBundleID: appBundleId
                )
                return
            }
        }

        if hasImageType {
            _ = capturePasteboardImage(from: pb, sourceAppName: appName, sourceAppBundleID: appBundleId)
        }
    }

    @discardableResult
    private func capturePasteboardImage(
        from pb: NSPasteboard,
        sourceAppName: String?,
        sourceAppBundleID: String?
    ) -> Bool {
        var recordedEntry: ClipboardEntry?
        autoreleasepool {
            guard let pngData = extractPNGData(from: pb), !pngData.isEmpty else { return }
            let id = UUID()
            let filename = "\(id.uuidString).png"
            let fileURL = imagesDirURL.appendingPathComponent(filename)
            do {
                try pngData.write(to: fileURL, options: .atomic)
            } catch {
                return
            }
            // Read pixel dimensions from header metadata without decoding full RGBA pixel buffer
            let dims = Self.imagePixelSize(from: pngData)
            recordedEntry = ClipboardEntry(
                id: id,
                kind: .image,
                imageFilename: filename,
                imageWidth: dims?.width,
                imageHeight: dims?.height,
                byteSize: pngData.count,
                sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID
            )
        }
        guard let entry = recordedEntry else { return false }
        insertEntry(entry)
        // Return transient TIFF/PNG conversion pages promptly to macOS so peak spikes don't linger
        malloc_zone_pressure_relief(nil, 0)
        return true
    }

    private func extractPNGData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) {
            return png
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private static func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOpts) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else {
            return nil
        }
        return (w, h)
    }

    private static func loadDownsampledImage(at url: URL, maxPixelSize: Int) -> (image: NSImage, cost: Int)? {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let cost = max(1, cgImage.width * cgImage.height * 4)
        return (img, cost)
    }

    private func recordTextEntry(
        kind: ClipboardItemKind,
        text: String,
        sourceAppName: String?,
        sourceAppBundleID: String?
    ) {
        entries.removeAll { $0.kind == kind && $0.text == text }
        let entry = ClipboardEntry(
            kind: kind,
            text: text,
            byteSize: text.utf8.count,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        insertEntry(entry)
    }

    private func insertEntry(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            let evicted = entries.suffix(from: maxEntries)
            for old in evicted {
                deleteImageFile(for: old)
            }
            entries = Array(entries.prefix(maxEntries))
        }
        saveToDisk()
    }

    /// Lightweight 64px thumbnail for the 24x24 list row icon (~16 KB decoded instead of ~20 MB full-res).
    func thumbnailImage(for entry: ClipboardEntry) -> NSImage? {
        guard entry.kind == .image, let filename = entry.imageFilename else { return nil }
        let key = entry.id as NSUUID
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let url = imagesDirURL.appendingPathComponent(filename)
        guard let loaded = Self.loadDownsampledImage(at: url, maxPixelSize: 64) else { return nil }
        thumbnailCache.setObject(loaded.image, forKey: key, cost: loaded.cost)
        return loaded.image
    }

    /// Downsampled 720px preview for the detail pane (~0.8-1.3 MB decoded; full PNG on disk is still used when pasting).
    func previewImage(for entry: ClipboardEntry) -> NSImage? {
        guard entry.kind == .image, let filename = entry.imageFilename else { return nil }
        let key = entry.id as NSUUID
        if let cached = previewCache.object(forKey: key) {
            return cached
        }
        let url = imagesDirURL.appendingPathComponent(filename)
        guard let loaded = Self.loadDownsampledImage(at: url, maxPixelSize: 720) else { return nil }
        previewCache.setObject(loaded.image, forKey: key, cost: loaded.cost)
        return loaded.image
    }

    func image(for entry: ClipboardEntry) -> NSImage? {
        previewImage(for: entry)
    }

    func clearImageCache() {
        thumbnailCache.removeAllObjects()
        previewCache.removeAllObjects()
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Marks the current `NSPasteboard.general.changeCount` as already processed so internal
    /// clipboard operations (e.g. Translate/Rewrite temporary copy or restore) do not pollute history.
    func syncCurrentChangeCount() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    func requestAccessibilityPermission(openSystemSettings: Bool = false) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        if openSystemSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func copyToPasteboard(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .image:
            autoreleasepool {
                if let filename = entry.imageFilename,
                   let data = try? Data(contentsOf: imagesDirURL.appendingPathComponent(filename)) {
                    var types: [NSPasteboard.PasteboardType] = [.png]
                    let tiffData = NSImage(data: data)?.tiffRepresentation
                    if tiffData != nil {
                        types.append(.tiff)
                    }
                    pb.declareTypes(types, owner: nil)
                    pb.setData(data, forType: .png)
                    if let tiffData {
                        pb.setData(tiffData, forType: .tiff)
                    }
                } else if let img = previewImage(for: entry) {
                    pb.writeObjects([img])
                }
            }
            malloc_zone_pressure_relief(nil, 0)
        case .text, .link:
            if let text = entry.text {
                pb.setString(text, forType: .string)
            }
        case .file:
            if let path = entry.text {
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                pb.setString(path, forType: .string)
            }
        }
        lastChangeCount = pb.changeCount
    }

    func consumePendingIMKTextPaste(forBundleID clientBundleID: String?) -> String? {
        guard let pending = pendingIMKTextPaste else { return nil }
        if Date() > pending.expiresAt {
            pendingIMKTextPaste = nil
            return nil
        }
        if let expected = pending.targetBundleID {
            let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard clientBundleID == expected || frontBundleID == expected else {
                return nil
            }
        }
        pendingIMKTextPaste = nil
        return pending.text
    }

    func pasteEntry(_ entry: ClipboardEntry, into targetApp: NSRunningApplication?) {
        copyToPasteboard(entry)

        let textForIMK: String?
        switch entry.kind {
        case .text, .link:
            textForIMK = (entry.text?.isEmpty == false) ? entry.text : nil
        case .file:
            // When Accessibility is granted, Cmd+V pastes the actual file object into Finder/chat apps.
            // Without Accessibility, fall back to inserting the file path via IMK if active.
            textForIMK = (!isAccessibilityTrusted && entry.text?.isEmpty == false) ? entry.text : nil
        case .image:
            textForIMK = nil
        }

        let pendingID: UUID?
        if let textForIMK {
            let id = UUID()
            pendingID = id
            pendingIMKTextPaste = PendingIMKTextPaste(
                id: id,
                text: textForIMK,
                targetBundleID: targetApp?.bundleIdentifier,
                expiresAt: Date().addingTimeInterval(0.8)
            )
        } else {
            pendingID = nil
            pendingIMKTextPaste = nil
        }

        if let targetApp {
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
        } else {
            NSApp.deactivate()
        }

        if let pendingID {
            // If the target app never called deactivateServer, deliver directly via the active IMK client.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self,
                      let pending = self.pendingIMKTextPaste,
                      pending.id == pendingID else { return }
                if InputTypeController.isServerCurrentlyActive,
                   (targetApp == nil || targetApp?.isActive == true),
                   let controller = InputTypeController.latestActiveController,
                   let text = self.consumePendingIMKTextPaste(forBundleID: InputTypeController.latestActiveBundleID) {
                    _ = controller.insertClipboardTextDirectly(text)
                }
            }

            // If IMK did not activate (e.g. user is on ABC/English layout or a non-IMK target), fall back to Cmd+V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self,
                      let pending = self.pendingIMKTextPaste,
                      pending.id == pendingID else { return }
                self.pendingIMKTextPaste = nil
                self.postCommandVWhenActive(targetApp: targetApp, attemptsRemaining: 8)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.postCommandVWhenActive(targetApp: targetApp, attemptsRemaining: 12)
            }
        }
    }

    private func postCommandVWhenActive(targetApp: NSRunningApplication?, attemptsRemaining: Int) {
        if let targetApp, !targetApp.isActive, attemptsRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.postCommandVWhenActive(targetApp: targetApp, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        guard isAccessibilityTrusted else {
            if !hasPromptedAccessibilityThisSession {
                hasPromptedAccessibilityThisSession = true
                requestAccessibilityPermission()
            }
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func remove(id: UUID) {
        if let entry = entries.first(where: { $0.id == id }) {
            deleteImageFile(for: entry)
        }
        entries.removeAll { $0.id == id }
        saveToDisk()
    }

    func clearAll() {
        for entry in entries {
            deleteImageFile(for: entry)
        }
        entries.removeAll()
        clearImageCache()
        saveToDisk()
        #if PRIMETYPE_SETTINGS_HELPER
        PrimeTypeIPC.post(PrimeTypeIPC.clearClipboard)
        #endif
    }

    private func deleteImageFile(for entry: ClipboardEntry) {
        let key = entry.id as NSUUID
        thumbnailCache.removeObject(forKey: key)
        previewCache.removeObject(forKey: key)
        if let filename = entry.imageFilename {
            try? FileManager.default.removeItem(at: imagesDirURL.appendingPathComponent(filename))
        }
    }

    func pruneExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-InputSettings.shared.clipboardRetentionDays.timeInterval)
        var expired: [ClipboardEntry] = []
        var kept: [ClipboardEntry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            if entry.timestamp < cutoff {
                expired.append(entry)
            } else {
                kept.append(entry)
            }
        }
        guard !expired.isEmpty else { return }
        for old in expired {
            deleteImageFile(for: old)
        }
        entries = kept
        saveToDisk()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        entries = decoded
        pruneExpiredEntries()
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}
