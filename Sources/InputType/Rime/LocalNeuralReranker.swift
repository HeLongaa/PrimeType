import Combine
import Darwin
import Foundation

struct NeuralRerankResult: Sendable {
    let preedit: String
    let candidates: [PresentedCandidate]
    let leadMargin: Double
}

/// Optional out-of-process Tier-2 local neural reranker using `llama-server` (Apple Silicon Metal)
/// + `Qwen2.5-0.5B-Instruct (Q4_K_M)` (~398 MB, downloaded on demand into `~/Library/InputType/models/llm/`).
///
/// Key engineering properties:
/// - Runs in an isolated subprocess on `127.0.0.1` so Metal/OOM faults can never crash the IME process.
/// - Lazy-launched on the first eligible long-sentence query and automatically unloaded after 5 minutes idle.
/// - Scores Top-6~8 whole-sentence candidates via Teacher-Forcing prompt log-prob (`n_predict: 0, cache_prompt: true`)
///   reusing the shared KV cache of preceding context `C`, then fuses via RRF with Rime rank & personal score.
final class LocalNeuralReranker: NSObject, ObservableObject {
    static let shared = LocalNeuralReranker()

    enum RuntimeState: String {
        case notInstalled = "未下载"
        case idleUnloaded = "已就绪（空闲休眠，0 MB 显存）"
        case starting = "正在按需加载模型…"
        case running = "运行中（Metal 加速）"
    }

    @Published private(set) var runtimeState: RuntimeState = .notInstalled
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var statusMessage: String = ""

    static let modelFilename = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    static let modelDownloadURL = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
    static let llamaReleaseAPI = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=8"
    static let idleUnloadSeconds: TimeInterval = 300 // 5 minutes

    let llmDirURL: URL
    var modelFileURL: URL { llmDirURL.appendingPathComponent(Self.modelFilename) }
    var serverBinaryURL: URL { llmDirURL.appendingPathComponent("bin/llama-server") }

    private let stateLock = NSLock()
    private var serverProcess: Process?
    private var serverPort: Int = 0
    private var lastActivityAt: TimeInterval = 0
    private var idleTimer: DispatchSourceTimer?
    private var downloadTask: Task<Void, Never>?
    private var activeURLSession: URLSession?

    private override init() {
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/InputType", isDirectory: true)
        self.llmDirURL = userDir.appendingPathComponent("models/llm", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: llmDirURL, withIntermediateDirectories: true)
        refreshInstallState()
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: serverBinaryURL.path),
              let attrs = try? fm.attributesOfItem(atPath: modelFileURL.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 100_000_000
    }

    func refreshInstallState() {
        let installed = isInstalled
        stateLock.lock()
        let running = serverProcess?.isRunning == true
        stateLock.unlock()

        DispatchQueue.main.async {
            if !installed {
                self.runtimeState = .notInstalled
            } else if running {
                self.runtimeState = .running
            } else {
                self.runtimeState = .idleUnloaded
            }
        }
    }

    // MARK: - Download & Lifecycle

    func downloadRuntimeAndModel() {
        guard !isDownloading else { return }
        try? FileManager.default.createDirectory(at: llmDirURL, withIntermediateDirectories: true)

        DispatchQueue.main.async {
            self.isDownloading = true
            self.downloadProgress = 0.02
            self.statusMessage = "正在查询最新版 llama.cpp (Apple Silicon)…"
        }

        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Step 1: Download prebuilt llama-server for macOS arm64 if not present
                if !FileManager.default.isExecutableFile(atPath: self.serverBinaryURL.path) {
                    let archiveURL = try await self.resolveLlamaMacArm64AssetURL()
                    try Task.checkCancellation()
                    let tarTmp = try await self.downloadWithProgress(
                        url: archiveURL,
                        progressBase: 0.02,
                        progressSpan: 0.18,
                        label: "正在下载推理引擎 (llama-server)"
                    )
                    try Task.checkCancellation()
                    try self.extractLlamaServer(fromTarGz: tarTmp)
                    try? FileManager.default.removeItem(at: tarTmp)
                }

                // Step 2: Download Qwen2.5-0.5B-Instruct Q4_K_M GGUF (~398 MB)
                if !self.isInstalled {
                    guard let modelURL = URL(string: Self.modelDownloadURL) else {
                        throw NSError(domain: "LocalNeuralReranker", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型下载地址无效"])
                    }
                    let modelTmp = try await self.downloadWithProgress(
                        url: modelURL,
                        progressBase: 0.20,
                        progressSpan: 0.78,
                        label: "正在下载 Qwen2.5-0.5B (4-bit)"
                    )
                    try Task.checkCancellation()
                    let fm = FileManager.default
                    if fm.fileExists(atPath: self.modelFileURL.path) {
                        try fm.removeItem(at: self.modelFileURL)
                    }
                    try fm.moveItem(at: modelTmp, to: self.modelFileURL)
                }

                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.statusMessage = "端侧语境模型安装完成（按需懒加载，空闲 5 分钟自动卸载）"
                    InputSettings.shared.localRerankerEnabled = true
                }
                self.refreshInstallState()
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 0
                    self.statusMessage = "已取消下载"
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 0
                    self.statusMessage = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeURLSession?.invalidateAndCancel()
        activeURLSession = nil
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadProgress = 0
            self.statusMessage = "已取消下载"
        }
    }

    func unloadNow() {
        stateLock.lock()
        idleTimer?.cancel()
        idleTimer = nil
        let proc = serverProcess
        serverProcess = nil
        serverPort = 0
        stateLock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
        }
        malloc_zone_pressure_relief(nil, 0)
        refreshInstallState()
    }

    func deleteModelAndRuntime() {
        unloadNow()
        try? FileManager.default.removeItem(at: llmDirURL)
        try? FileManager.default.createDirectory(at: llmDirURL, withIntermediateDirectories: true)
        DispatchQueue.main.async {
            InputSettings.shared.localRerankerEnabled = false
            self.statusMessage = "已删除本地语境模型与推理引擎"
        }
        refreshInstallState()
    }

    // MARK: - Teacher-Forcing Rerank Query

    /// Determines whether a query should dispatch Tier-2 neural reranking.
    func shouldTrigger(
        syllableCount: Int,
        candidates: [PresentedCandidate],
        contextPrefix: String
    ) -> Bool {
        guard InputSettings.shared.localRerankerEnabled, isInstalled else { return false }
        let wholeCount = candidates.prefix(8).filter { !$0.isDirectCommit && $0.isWholeSentence }.count
        guard wholeCount >= 2 else { return false }
        if syllableCount >= 6 { return true }
        if syllableCount >= 2 && !contextPrefix.isEmpty { return true }
        return false
    }

    /// Runs batch Teacher-Forcing conditional log-prob scoring against the local loopback `llama-server`
    /// and fuses scores via Reciprocal Rank Fusion (RRF) + UserRankingEngine score.
    func rerank(
        preedit: String,
        candidates: [PresentedCandidate],
        contextPrefix: String,
        normalizedCode: String
    ) async -> NeuralRerankResult? {
        guard isInstalled else { return nil }
        guard let port = await ensureServerReady() else { return nil }

        stateLock.withLock {
            lastActivityAt = Date().timeIntervalSince1970
        }

        var prefixDirect: [PresentedCandidate] = []
        var rimePool: [PresentedCandidate] = []
        for c in candidates {
            if c.isDirectCommit { prefixDirect.append(c) }
            else { rimePool.append(c) }
        }

        let topWhole = rimePool.prefix(8).filter(\.isWholeSentence)
        guard topWhole.count >= 2 else { return nil }

        let targetSlice = Array(topWhole.prefix(6))
        var llmScores: [Double] = []
        llmScores.reserveCapacity(targetSlice.count)

        let prefixText = contextPrefix.isEmpty ? "" : contextPrefix
        for cand in targetSlice {
            if Task.isCancelled { return nil }
            guard let avgLogProb = await scoreCandidateLogProb(
                port: port,
                contextPrefix: prefixText,
                candidateText: cand.text
            ) else {
                return nil
            }
            llmScores.append(avgLogProb)
        }

        // Min-Max normalize LLM log-probs into [0, 1]
        let minLLM = llmScores.min() ?? 0
        let maxLLM = llmScores.max() ?? 0
        let llmSpan = max(maxLLM - minLLM, 1e-6)

        // RRF prior + normalized LLM semantic score + normalized user feedback
        let rrfK = 6.0
        var fused: [(cand: PresentedCandidate, score: Double, origPos: Int)] = []
        fused.reserveCapacity(targetSlice.count)

        for (idx, cand) in targetSlice.enumerated() {
            let rrfScore = 1.0 / (rrfK + Double(idx))
            let rrfMax = 1.0 / rrfK
            let normRime = rrfScore / rrfMax
            let normLLM = (llmScores[idx] - minLLM) / llmSpan
            let (rawUser, _) = UserRankingEngine.shared.effectiveScore(code: normalizedCode, word: cand.text)
            let normUser = max(-1.0, min(1.0, rawUser / 8.0))

            let finalScore = 0.45 * normRime + 0.45 * normLLM + 0.10 * normUser
            fused.append((cand, finalScore, idx))
        }

        let sorted = fused.sorted { a, b in
            if abs(a.score - b.score) > 1e-6 { return a.score > b.score }
            return a.origPos < b.origPos
        }

        let oldTopScore = fused.first?.score ?? 0
        let newTopScore = sorted.first?.score ?? 0
        let leadMargin = newTopScore - oldTopScore

        let scoredSet = Set(targetSlice.map(\.text))
        let remainingRime = rimePool.filter { !scoredSet.contains($0.text) }
        let merged = prefixDirect + sorted.map(\.cand) + remainingRime

        return NeuralRerankResult(preedit: preedit, candidates: merged, leadMargin: leadMargin)
    }

    // MARK: - Loopback llama-server Helpers

    private func ensureServerReady() async -> Int? {
        if let activePort: Int = stateLock.withLock({
            if let proc = serverProcess, proc.isRunning, serverPort > 0 {
                lastActivityAt = Date().timeIntervalSince1970
                return serverPort
            }
            return nil
        }) {
            return activePort
        }

        let port = Int.random(in: 38400...48900)
        let proc = Process()
        proc.executableURL = serverBinaryURL
        proc.arguments = [
            "--model", modelFileURL.path,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--ctx-size", "512",
            "--n-gpu-layers", "99",
            "--parallel", "1",
            "--no-webui"
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        DispatchQueue.main.async {
            self.runtimeState = .starting
        }

        do {
            try proc.run()
        } catch {
            refreshInstallState()
            return nil
        }

        stateLock.withLock {
            serverProcess = proc
            serverPort = port
            lastActivityAt = Date().timeIntervalSince1970
            startIdleWatchdogLocked()
        }

        // Poll /health briefly (up to 3s on first lazy launch)
        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        for _ in 0..<30 {
            if Task.isCancelled { return nil }
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 0.2
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               http.statusCode == 200 {
                refreshInstallState()
                return port
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func startIdleWatchdogLocked() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let idle = Date().timeIntervalSince1970 - self.lastActivityAt
            let isRunning = self.serverProcess?.isRunning == true
            self.stateLock.unlock()
            if isRunning && idle >= Self.idleUnloadSeconds {
                self.unloadNow()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    /// Calls `llama-server` `/completion` with `n_predict: 0`, `cache_prompt: true`, `n_probs: 1`, `post_sampling_probs: false`
    /// to obtain teacher-forcing conditional log-probabilities for the candidate suffix tokens only.
    private func scoreCandidateLogProb(port: Int, contextPrefix: String, candidateText: String) async -> Double? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return nil }
        let fullPrompt = contextPrefix + candidateText

        let body: [String: Any] = [
            "prompt": fullPrompt,
            "n_predict": 0,
            "cache_prompt": true,
            "n_probs": 1,
            "return_tokens": true,
            "eval_prompt_probs": true
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 0.18
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Parse prompt_probabilities / completion_probabilities depending on llama-server version
        let probsArray = (json["completion_probabilities"] as? [[String: Any]])
            ?? (json["prompt_probabilities"] as? [[String: Any]])
            ?? []
        guard !probsArray.isEmpty else { return nil }

        // Only sum log-probs over the trailing tokens belonging to `candidateText`
        let approxCandTokens = max(1, min(probsArray.count, candidateText.count))
        let suffixSlice = probsArray.suffix(approxCandTokens)
        var sumLogProb = 0.0
        var count = 0
        for item in suffixSlice {
            if let logprob = item["logprob"] as? Double {
                sumLogProb += logprob
                count += 1
            } else if let probs = item["probs"] as? [[String: Any]],
                      let first = probs.first,
                      let p = first["prob"] as? Double, p > 0 {
                sumLogProb += log(p)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return sumLogProb / Double(count)
    }

    // MARK: - Asset Download Helpers

    private func resolveLlamaMacArm64AssetURL() async throws -> URL {
        guard let apiURL = URL(string: Self.llamaReleaseAPI) else {
            throw NSError(domain: "LocalNeuralReranker", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 地址无效"])
        }
        var req = URLRequest(url: apiURL)
        req.setValue("PrimeType", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "LocalNeuralReranker", code: 3, userInfo: [NSLocalizedDescriptionKey: "解析 llama.cpp 版本列表失败"])
        }
        for rel in releases {
            let assets = rel["assets"] as? [[String: Any]] ?? []
            if let match = assets.first(where: { asset in
                let name = (asset["name"] as? String ?? "").lowercased()
                return name.contains("macos-arm64") && (name.hasSuffix(".tar.gz") || name.hasSuffix(".zip"))
            }), let urlStr = match["browser_download_url"] as? String, let url = URL(string: urlStr) {
                return url
            }
        }
        throw NSError(domain: "LocalNeuralReranker", code: 4, userInfo: [NSLocalizedDescriptionKey: "未找到 macOS arm64 预编译引擎"])
    }

    private func extractLlamaServer(fromTarGz archiveURL: URL) throws {
        let fm = FileManager.default
        let binDir = llmDirURL.appendingPathComponent("bin", isDirectory: true)
        try? fm.removeItem(at: binDir)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let tmpExtract = fm.temporaryDirectory.appendingPathComponent("llama-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpExtract) }

        let proc = Process()
        if archiveURL.path.hasSuffix(".zip") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-xk", archiveURL.path, tmpExtract.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xzf", archiveURL.path, "-C", tmpExtract.path]
        }
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "LocalNeuralReranker", code: 5, userInfo: [NSLocalizedDescriptionKey: "解压 llama-server 失败"])
        }

        // Copy llama-server and companion dylibs / metallib into bin/
        guard let enumerator = fm.enumerator(at: tmpExtract, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "LocalNeuralReranker", code: 6, userInfo: [NSLocalizedDescriptionKey: "扫描解压目录失败"])
        }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name == "llama-server" || name.hasSuffix(".dylib") || name.hasSuffix(".metallib") {
                let dest = binDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try fm.copyItem(at: fileURL, to: dest)
            }
        }
        guard fm.isExecutableFile(atPath: serverBinaryURL.path) else {
            throw NSError(domain: "LocalNeuralReranker", code: 7, userInfo: [NSLocalizedDescriptionKey: "未在压缩包中找到 llama-server"])
        }
    }

    private func downloadWithProgress(
        url: URL,
        progressBase: Double,
        progressSpan: Double,
        label: String
    ) async throws -> URL {
        final class Delegate: NSObject, URLSessionDownloadDelegate {
            let onProgress: (Int64, Int64) -> Void
            let onFinish: (Result<URL, Error>) -> Void
            private var completed = false

            init(onProgress: @escaping (Int64, Int64) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
                self.onProgress = onProgress
                self.onFinish = onFinish
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                onProgress(totalBytesWritten, totalBytesExpectedToWrite)
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                guard !completed else { return }
                let copyURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PrimeTypeLLM-\(UUID().uuidString)-\(urlFilename(downloadTask))")
                do {
                    try FileManager.default.moveItem(at: location, to: copyURL)
                    completed = true
                    onFinish(.success(copyURL))
                } catch {
                    completed = true
                    onFinish(.failure(error))
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                guard let error, !completed else { return }
                completed = true
                onFinish(.failure(error))
            }

            private func urlFilename(_ task: URLSessionDownloadTask) -> String {
                task.originalRequest?.url?.lastPathComponent ?? "download.bin"
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = Delegate(
                onProgress: { written, total in
                    let ratio = total > 0 ? min(max(Double(written) / Double(total), 0), 1) : 0
                    let mbW = Double(written) / (1024.0 * 1024.0)
                    let mbT = Double(total) / (1024.0 * 1024.0)
                    DispatchQueue.main.async {
                        self.downloadProgress = progressBase + ratio * progressSpan
                        if total > 0 {
                            self.statusMessage = String(format: "%@… %.1f MB / %.1f MB (%.0f%%)", label, mbW, mbT, ratio * 100)
                        } else {
                            self.statusMessage = String(format: "%@… %.1f MB", label, mbW)
                        }
                    }
                },
                onFinish: { result in
                    continuation.resume(with: result)
                }
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.activeURLSession = session
            var req = URLRequest(url: url)
            req.setValue("PrimeType", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }
}
