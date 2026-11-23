import Cocoa
import Foundation

// MARK: - App Update Manager

final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: String = "https://github.com/HeLongaa/PrimeType/releases"
    @Published private(set) var releaseNotes: String?
    @Published private(set) var assetDownloadURL: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasUpdate = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private init() {}

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking && !isUpdating else { return }
        isChecking = true
        if !silent {
            statusMessage = "正在检查软件更新…"
        }

        Task {
            do {
                guard let url = URL(string: "https://api.github.com/repos/HeLongaa/PrimeType/releases/latest") else { return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("PrimeType/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    await MainActor.run {
                        self.isChecking = false
                        self.latestVersion = "v\(self.currentVersion)"
                        self.hasUpdate = false
                        if !silent {
                            self.statusMessage = "当前已是最新版本"
                        }
                    }
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "AppUpdateManager", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "检查失败 (HTTP \(http.statusCode))"
                    ])
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let tag = (json?["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let htmlURL = (json?["html_url"] as? String) ?? "https://github.com/HeLongaa/PrimeType/releases"
                let body = (json?["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let assets = json?["assets"] as? [[String: Any]] ?? []
                let zipAssetURL = assets.first(where: { asset in
                    let name = (asset["name"] as? String ?? "").lowercased()
                    return name.hasSuffix(".zip") && name.contains("primetype") && !name.contains("installer")
                })?["browser_download_url"] as? String
                ?? assets.first(where: { asset in
                    (asset["name"] as? String ?? "").lowercased().hasSuffix(".zip")
                })?["browser_download_url"] as? String

                let newer = Self.isRemoteVersion(tag, newerThan: currentVersion)

                await MainActor.run {
                    self.isChecking = false
                    self.latestVersion = tag.isEmpty ? nil : tag
                    self.releaseURL = htmlURL
                    self.releaseNotes = body
                    self.assetDownloadURL = zipAssetURL
                    self.hasUpdate = newer
                    if newer {
                        self.statusMessage = "发现新版本 \(tag)"
                    } else if !silent {
                        self.statusMessage = "当前已是最新版本"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isChecking = false
                    if !silent {
                        self.statusMessage = "检查更新失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func downloadAndInstallUpdate() {
        guard !isUpdating, let urlStr = assetDownloadURL, let url = URL(string: urlStr) else {
            if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        isUpdating = true
        downloadProgress = 0.05
        statusMessage = "正在下载更新包…"

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("PrimeTypeUpdate-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let zipURL = tmpDir.appendingPathComponent("PrimeType.zip")

                var req = URLRequest(url: url)
                req.timeoutInterval = 180
                req.setValue("PrimeType/\(self.currentVersion)", forHTTPHeaderField: "User-Agent")

                let (downloadedTmp, response) = try await URLSession.shared.download(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "AppUpdateManager", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "下载失败 (HTTP \(http.statusCode))"
                    ])
                }
                if fm.fileExists(atPath: zipURL.path) {
                    try fm.removeItem(at: zipURL)
                }
                try fm.moveItem(at: downloadedTmp, to: zipURL)

                await MainActor.run {
                    self.downloadProgress = 0.65
                    self.statusMessage = "正在解压更新包…"
                }

                let extractDir = tmpDir.appendingPathComponent("extracted", isDirectory: true)
                try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", zipURL.path, extractDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw NSError(domain: "AppUpdateManager", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "解压更新包失败"
                    ])
                }

                guard let newAppURL = Self.findAppBundle(in: extractDir) else {
                    throw NSError(domain: "AppUpdateManager", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "更新包中未找到 PrimeType.app"
                    ])
                }

                await MainActor.run {
                    self.downloadProgress = 0.85
                    self.statusMessage = "正在安装并重启输入法…"
                }

                let installTarget = "/Library/Input Methods/PrimeType.app"
                let parentDir = "/Library/Input Methods"
                let installScript = """
                set -e
                rm -rf "\(installTarget).old"
                if [ -d "\(installTarget)" ]; then
                  mv "\(installTarget)" "\(installTarget).old"
                fi
                ditto "\(newAppURL.path)" "\(installTarget)"
                rm -rf "\(installTarget).old"
                xattr -dr com.apple.quarantine "\(installTarget)" 2>/dev/null || true
                """

                if fm.isWritableFile(atPath: parentDir) && (!fm.fileExists(atPath: installTarget) || fm.isWritableFile(atPath: installTarget)) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                    proc.arguments = ["-c", installScript]
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw NSError(domain: "AppUpdateManager", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: "安装更新失败"
                        ])
                    }
                } else {
                    let escaped = installScript
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    proc.arguments = ["-e", appleScript]
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw NSError(domain: "AppUpdateManager", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "已取消安装或权限不足"
                        ])
                    }
                }

                try? fm.removeItem(at: tmpDir)

                await MainActor.run {
                    self.downloadProgress = 1.0
                    self.isUpdating = false
                    self.hasUpdate = false
                    self.statusMessage = "更新安装完成，正在重启输入法…"
                }

                // Exit cleanly so macOS InputMethodKit immediately relaunches the updated PrimeType.app
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            } catch {
                try? fm.removeItem(at: tmpDir)
                await MainActor.run {
                    self.isUpdating = false
                    self.downloadProgress = 0
                    self.statusMessage = "更新失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static func findAppBundle(in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("PrimeType.app")
        if fm.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "PrimeType.app" {
                return url
            }
        }
        return nil
    }

    static func isRemoteVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let l = local.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard !r.isEmpty else { return false }
        return r.compare(l, options: .numeric) == .orderedDescending
    }
}

// MARK: - Dictionary Update Manager

struct DictionaryOverlayManifest: Codable {
    let version: String
    let updatedAt: Date
    let sourceURL: String
}

struct DictionaryUpdateState: Equatable {
    var localVersion: String
    var latestVersion: String?
    var downloadURL: String?
    var isChecking: Bool = false
    var isUpdating: Bool = false
    var statusText: String?

    var hasUpdate: Bool {
        guard let latest = latestVersion, !latest.isEmpty else { return false }
        return latest != localVersion
    }
}

final class DictionaryUpdateManager: ObservableObject {
    static let shared = DictionaryUpdateManager()

    @Published private(set) var states: [DictionaryPreset: DictionaryUpdateState] = [:]
    @Published private(set) var isCheckingAll = false

    private let baseOverlayDir: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseOverlayDir = home.appendingPathComponent("Library/InputType/dictionaries", isDirectory: true)
        refreshLocalStates()
    }

    func overlayDir(for preset: DictionaryPreset) -> URL {
        baseOverlayDir.appendingPathComponent(preset.profileDirectoryName, isDirectory: true)
    }

    func manifestURL(for preset: DictionaryPreset) -> URL {
        overlayDir(for: preset).appendingPathComponent("manifest.json")
    }

    func bundledVersionLabel(for preset: DictionaryPreset) -> String {
        switch preset {
        case .wanxiang: return "内置 v18.2.0"
        case .rimeIce: return "内置主干"
        case .ohMyRime: return "内置发行版"
        }
    }

    func refreshLocalStates() {
        for preset in DictionaryPreset.allCases {
            let existing = states[preset]
            let manifest = readManifest(for: preset)
            let hasValidOverlay = FileManager.default.fileExists(
                atPath: overlayDir(for: preset).appendingPathComponent("\(preset.schemaID).schema.yaml").path
            )
            let localVer = (hasValidOverlay ? manifest?.version : nil) ?? bundledVersionLabel(for: preset)
            states[preset] = DictionaryUpdateState(
                localVersion: localVer,
                latestVersion: existing?.latestVersion,
                downloadURL: existing?.downloadURL,
                isChecking: existing?.isChecking ?? false,
                isUpdating: existing?.isUpdating ?? false,
                statusText: existing?.statusText
            )
        }
    }

    func state(for preset: DictionaryPreset) -> DictionaryUpdateState {
        states[preset] ?? DictionaryUpdateState(
            localVersion: bundledVersionLabel(for: preset)
        )
    }

    private func readManifest(for preset: DictionaryPreset) -> DictionaryOverlayManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: preset)) else { return nil }
        return try? JSONDecoder().decode(DictionaryOverlayManifest.self, from: data)
    }

    // MARK: - Check Upstream Versions

    func checkAllUpdates(autoApplyIfEnabled: Bool = false) {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        refreshLocalStates()

        Task {
            await withTaskGroup(of: Void.self) { group in
                for preset in DictionaryPreset.allCases {
                    group.addTask {
                        await self.checkUpdate(for: preset, autoApply: autoApplyIfEnabled)
                    }
                }
            }
            await MainActor.run {
                self.isCheckingAll = false
            }
        }
    }

    func checkUpdate(for preset: DictionaryPreset, autoApply: Bool = false) async {
        await MainActor.run {
            var st = self.state(for: preset)
            st.isChecking = true
            st.statusText = "正在检查…"
            self.states[preset] = st
        }

        do {
            let (version, downloadURL) = try await fetchLatestInfo(for: preset)
            await MainActor.run {
                var st = self.state(for: preset)
                st.isChecking = false
                st.latestVersion = version
                st.downloadURL = downloadURL
                st.statusText = st.hasUpdate ? "有新版本可用" : "已是最新"
                self.states[preset] = st
            }

            if autoApply && InputSettings.shared.autoUpdateDictionaries {
                let shouldUpdate = await MainActor.run { self.state(for: preset).hasUpdate }
                if shouldUpdate && InputSettings.shared.selectedDictionary == preset {
                    await updateDictionary(preset)
                }
            }
        } catch {
            await MainActor.run {
                var st = self.state(for: preset)
                st.isChecking = false
                st.statusText = "检查失败：\(error.localizedDescription)"
                self.states[preset] = st
            }
        }
    }

    private func fetchLatestInfo(for preset: DictionaryPreset) async throws -> (version: String, downloadURL: String) {
        let apiURLString: String
        switch preset {
        case .wanxiang:
            apiURLString = "https://api.github.com/repos/amzxyz/rime_wanxiang/releases/latest"
        case .rimeIce:
            apiURLString = "https://api.github.com/repos/iDvel/rime-ice/commits/main"
        case .ohMyRime:
            apiURLString = "https://api.github.com/repos/Mintimate/oh-my-rime/commits/main"
        }

        guard let url = URL(string: apiURLString) else {
            throw NSError(domain: "DictionaryUpdateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的更新地址"])
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PrimeType/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "DictionaryUpdateManager", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DictionaryUpdateManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "响应解析失败"])
        }

        switch preset {
        case .rimeIce:
            let sha = (json["sha"] as? String) ?? ""
            let shortSha = String(sha.prefix(7))
            let version = shortSha.isEmpty ? "main" : "main-\(shortSha)"
            return (version, "https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip")

        case .wanxiang:
            let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "latest"
            let assets = json["assets"] as? [[String: Any]] ?? []
            let preferredAsset = assets.first { asset in
                let name = (asset["name"] as? String)?.lowercased() ?? ""
                return name.hasSuffix(".zip") && name.contains("base") && !name.contains("pro")
            } ?? assets.first { asset in
                ((asset["name"] as? String)?.lowercased() ?? "").hasSuffix(".zip")
            }
            let dl = (preferredAsset?["browser_download_url"] as? String)
                ?? (json["zipball_url"] as? String)
                ?? "https://github.com/amzxyz/rime_wanxiang/archive/refs/tags/\(tag).zip"
            return (tag, dl)

        case .ohMyRime:
            let sha = (json["sha"] as? String) ?? ""
            let shortSha = String(sha.prefix(7))
            let version = shortSha.isEmpty ? "main" : "main-\(shortSha)"
            return (version, "https://github.com/Mintimate/oh-my-rime/archive/refs/heads/main.zip")
        }
    }

    // MARK: - Download & Atomic Overlay Install

    func updateDictionary(_ preset: DictionaryPreset) async {
        let alreadyUpdating = await MainActor.run { self.state(for: preset).isUpdating }
        guard !alreadyUpdating else { return }

        await MainActor.run {
            var st = self.state(for: preset)
            st.isUpdating = true
            st.statusText = "正在获取最新包…"
            self.states[preset] = st
        }

        do {
            var dlURLString = await MainActor.run { self.state(for: preset).downloadURL }
            var targetVersion = await MainActor.run { self.state(for: preset).latestVersion }
            if dlURLString == nil || targetVersion == nil {
                let info = try await fetchLatestInfo(for: preset)
                targetVersion = info.version
                dlURLString = info.downloadURL
            }
            guard let dlStr = dlURLString, let dlURL = URL(string: dlStr), let version = targetVersion else {
                throw NSError(domain: "DictionaryUpdateManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "未找到可用下载链接"])
            }

            await MainActor.run {
                var st = self.state(for: preset)
                st.statusText = "正在下载 \(version)…"
                self.states[preset] = st
            }

            var req = URLRequest(url: dlURL)
            req.timeoutInterval = 120
            req.setValue("PrimeType/0.1.0", forHTTPHeaderField: "User-Agent")
            let (tempZipURL, response) = try await URLSession.shared.download(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "DictionaryUpdateManager", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "下载失败 (HTTP \(http.statusCode))"
                ])
            }

            await MainActor.run {
                var st = self.state(for: preset)
                st.statusText = "正在解压校验…"
                self.states[preset] = st
            }

            let fm = FileManager.default
            let stagingRoot = baseOverlayDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingRoot) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-xk", tempZipURL.path, stagingRoot.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "DictionaryUpdateManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }

            guard let schemaDir = findSchemaDirectory(for: preset.schemaID, under: stagingRoot) else {
                throw NSError(domain: "DictionaryUpdateManager", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "未在压缩包内找到 \(preset.schemaID).schema.yaml"
                ])
            }

            let targetDir = overlayDir(for: preset)
            let backupDir = baseOverlayDir.appendingPathComponent(".backup-\(preset.profileDirectoryName)-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: baseOverlayDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: targetDir.path) {
                try fm.moveItem(at: targetDir, to: backupDir)
            }

            do {
                try fm.moveItem(at: schemaDir, to: targetDir)
                let manifest = DictionaryOverlayManifest(version: version, updatedAt: Date(), sourceURL: dlStr)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let mData = try? encoder.encode(manifest) {
                    try? mData.write(to: manifestURL(for: preset), options: .atomic)
                }
                try? fm.removeItem(at: backupDir)
            } catch {
                if fm.fileExists(atPath: backupDir.path) {
                    try? fm.removeItem(at: targetDir)
                    try? fm.moveItem(at: backupDir, to: targetDir)
                }
                throw error
            }

            if InputSettings.shared.selectedDictionary == preset {
                await MainActor.run {
                    var st = self.state(for: preset)
                    st.statusText = "正在重新部署词库…"
                    self.states[preset] = st
                }
                RimeEngine.shared.switchPreset(preset, waitForMaintenance: true)
            }

            await MainActor.run {
                self.refreshLocalStates()
                var st = self.state(for: preset)
                st.isUpdating = false
                st.latestVersion = version
                st.downloadURL = dlStr
                st.statusText = "已更新至 \(version)"
                self.states[preset] = st
            }
        } catch {
            await MainActor.run {
                var st = self.state(for: preset)
                st.isUpdating = false
                st.statusText = "更新失败：\(error.localizedDescription)"
                self.states[preset] = st
            }
        }
    }

    private func findSchemaDirectory(for schemaID: String, under root: URL) -> URL? {
        let fm = FileManager.default
        let targetFile = "\(schemaID).schema.yaml"
        if fm.fileExists(atPath: root.appendingPathComponent(targetFile).path) {
            return root
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == targetFile {
                return fileURL.deletingLastPathComponent()
            }
        }
        return nil
    }
}
