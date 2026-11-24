import Combine
import Foundation

enum GrammarModelKind: String, CaseIterable, Codable, Identifiable {
    case lightweight = "zh-hans-t-essay-bgw"
    case wanxiangLTS = "wanxiang-lts-zh-hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lightweight: return "轻量语法模型（推荐 · 39 MB）"
        case .wanxiangLTS: return "万象完整语法模型（373 MB）"
        }
    }

    var shortName: String {
        switch self {
        case .lightweight: return "轻量语法模型"
        case .wanxiangLTS: return "万象 LTS 语法模型"
        }
    }

    var filename: String {
        "\(rawValue).gram"
    }

    var downloadURLString: String {
        switch self {
        case .lightweight:
            return "https://github.com/lotem/rime-octagram-data/raw/hans/zh-hans-t-essay-bgw.gram"
        case .wanxiangLTS:
            return "https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram"
        }
    }

    var approximateSizeLabel: String {
        switch self {
        case .lightweight: return "39 MB"
        case .wanxiangLTS: return "373 MB"
        }
    }
}

/// Manages downloadable `.gram` language models for the bundled `librime-octagram.dylib` plugin.
/// Stores a single copy in `~/Library/InputType/models/` and symlinks it into all 3 Rime profiles.
final class GrammarModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = GrammarModelManager()

    @Published private(set) var isDownloading = false
    @Published private(set) var downloadingKind: GrammarModelKind?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var installedModels: Set<GrammarModelKind> = []

    let modelsDirectoryURL: URL
    private var activeTask: URLSessionDownloadTask?
    private var activeSession: URLSession?
    private var activeDestinationURL: URL?

    private override init() {
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/InputType", isDirectory: true)
        self.modelsDirectoryURL = userDir.appendingPathComponent("models", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        refreshInstalledModels()
    }

    func modelFileURL(for kind: GrammarModelKind) -> URL {
        modelsDirectoryURL.appendingPathComponent(kind.filename)
    }

    func isInstalled(_ kind: GrammarModelKind) -> Bool {
        let path = modelFileURL(for: kind).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 1_000_000
    }

    /// Returns the active installed grammar model to mount in Rime `custom.yaml`, if enabled and present.
    func activeGrammarLanguage(preferred: GrammarModelKind, enabled: Bool) -> String? {
        guard enabled else { return nil }
        if isInstalled(preferred) {
            return preferred.rawValue
        }
        // Fallback to any installed grammar model
        for kind in GrammarModelKind.allCases where isInstalled(kind) {
            return kind.rawValue
        }
        return nil
    }

    func refreshInstalledModels() {
        var found = Set<GrammarModelKind>()
        for kind in GrammarModelKind.allCases where isInstalled(kind) {
            found.insert(kind)
        }
        DispatchQueue.main.async {
            self.installedModels = found
        }
    }

    /// Symlinks all installed `.gram` files into the given Rime profile directory so `librime-octagram`
    /// loads them via `mmap` with zero duplication on disk.
    func ensureSymlinks(in profileDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
        for kind in GrammarModelKind.allCases where isInstalled(kind) {
            let source = modelFileURL(for: kind).path
            let linkPath = (profileDir as NSString).appendingPathComponent(kind.filename)
            if let attrs = try? fm.attributesOfItem(atPath: linkPath) {
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                   let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath),
                   dest == source {
                    continue
                }
                try? fm.removeItem(atPath: linkPath)
            }
            try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: source)
        }
    }

    func syncAllProfileSymlinks() {
        for preset in DictionaryPreset.allCases {
            ensureSymlinks(in: RimeEngine.shared.userDataDir(for: preset))
        }
    }

    func download(_ kind: GrammarModelKind) {
        guard !isDownloading, let url = URL(string: kind.downloadURLString) else { return }
        try? FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        DispatchQueue.main.async {
            self.isDownloading = true
            self.downloadingKind = kind
            self.progress = 0.01
            self.statusMessage = "正在连接下载 \(kind.shortName)…"
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("PrimeType", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: req)
        self.activeSession = session
        self.activeTask = task
        self.activeDestinationURL = modelFileURL(for: kind)
        task.resume()
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeSession?.invalidateAndCancel()
        activeTask = nil
        activeSession = nil
        activeDestinationURL = nil
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadingKind = nil
            self.progress = 0
            self.statusMessage = "已取消下载"
        }
    }

    func deleteModel(_ kind: GrammarModelKind) {
        let fm = FileManager.default
        try? fm.removeItem(at: modelFileURL(for: kind))
        for preset in DictionaryPreset.allCases {
            let linkPath = (RimeEngine.shared.userDataDir(for: preset) as NSString)
                .appendingPathComponent(kind.filename)
            try? fm.removeItem(atPath: linkPath)
        }
        refreshInstalledModels()
        DispatchQueue.main.async {
            self.statusMessage = "已删除 \(kind.shortName)"
        }
        InputSettings.shared.redeployCurrentPreset()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let writtenMB = Double(totalBytesWritten) / (1024.0 * 1024.0)
        let totalMB = Double(totalBytesExpectedToWrite) / (1024.0 * 1024.0)
        let ratio = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : 0
        DispatchQueue.main.async {
            self.progress = ratio
            if totalBytesExpectedToWrite > 0 {
                self.statusMessage = String(format: "正在下载… %.1f MB / %.1f MB (%.0f%%)", writtenMB, totalMB, ratio * 100)
            } else {
                self.statusMessage = String(format: "正在下载… %.1f MB", writtenMB)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let dest = activeDestinationURL, let kind = downloadingKind else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: location, to: dest)
            syncAllProfileSymlinks()
            refreshInstalledModels()
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadingKind = nil
                self.progress = 1.0
                self.statusMessage = "\(kind.shortName) 安装完成，正在重新部署 Rime…"
                InputSettings.shared.selectedGrammarModel = kind
                InputSettings.shared.grammarModelEnabled = true
                InputSettings.shared.redeployCurrentPreset()
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadingKind = nil
                self.progress = 0
                self.statusMessage = "保存失败：\(error.localizedDescription)"
            }
        }
        activeSession?.finishTasksAndInvalidate()
        activeSession = nil
        activeTask = nil
        activeDestinationURL = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadingKind = nil
            self.progress = 0
            self.statusMessage = "下载失败：\(error.localizedDescription)"
        }
        activeSession?.finishTasksAndInvalidate()
        activeSession = nil
        activeTask = nil
        activeDestinationURL = nil
    }
}
