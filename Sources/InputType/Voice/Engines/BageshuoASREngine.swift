import Foundation
import os

final class BageshuoASREngine: VoiceASREngine {
    let channel: VoiceCloudChannel = .bageshuo

    private static let ticketEndpoint = "https://dict-typeless.youdao.com/api/v1/realtime/tickets"
    private static let appVersion = "1.0.30"
    private static let userAgent = "bageshuo/1.0.30"
    private static let keyID = "typeless_mac_main"
    private static let secretKey = "1TNWxQEtUtTg1XkhvJvQJl84TmtLXmCe"
    private static let deviceModel = "Mac14,2"

    func start(sampleRate: UInt32, onEvent: @escaping (VoiceASREvent) -> Void) -> (any VoiceASRSession)? {
        StreamingVoiceASRSession(onEvent: onEvent) { audioStream, onPartial in
            try await Self.runSession(audioStream: audioStream, onPartial: onPartial)
        }
    }

    // MARK: - Device ID, Hash & Signature

    private struct DeviceRecord: Codable {
        let device: String
    }

    private static var deviceFileURL: URL {
        VoiceDataStore.shared.fileURL(named: "bageshuo_device.json")
    }

    private static func loadOrCreateDeviceID() -> String {
        if let data = try? Data(contentsOf: deviceFileURL),
           let rec = try? JSONDecoder().decode(DeviceRecord.self, from: data),
           !rec.device.isEmpty {
            return rec.device
        }
        let id = UUID().uuidString.lowercased()
        if let encoded = try? JSONEncoder().encode(DeviceRecord(device: id)) {
            try? encoded.write(to: deviceFileURL, options: .atomic)
        }
        return id
    }

    static func computeABTest(device: String) -> UInt32 {
        var h: UInt32 = 0
        for byte in device.utf8 {
            h = h &* 31 &+ UInt32(byte)
        }
        return h % 10
    }

    static func buildSignedQueryItems(device: String, timestampMs: UInt64) -> [URLQueryItem] {
        var signedPairs: [(String, String)] = [
            ("product", "typeless"),
            ("appVersion", appVersion),
            ("client", "mac"),
            ("mid", device),
            ("vendor", "direct"),
            ("screen", "1920x1080"),
            ("model", deviceModel),
            ("imei", device),
            ("network", "wifi"),
            ("keyfrom", "typeless.\(appVersion).mac"),
            ("abtest", String(computeABTest(device: device))),
            ("yduuid", device),
            ("keyid", keyID),
            ("mysticTime", String(timestampMs))
        ]
        signedPairs.sort { $0.0 < $1.0 }

        let plainQuery = signedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let sign = VoiceCrypto.md5Hex(Data("\(plainQuery)&key=\(secretKey)".utf8), uppercase: false)
        let pointParam = signedPairs.map { $0.0 }.joined(separator: ",")

        var items = signedPairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        items.append(contentsOf: [
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "pointParam", value: pointParam),
            URLQueryItem(name: "generationStreaming", value: "true"),
            URLQueryItem(name: "osName", value: "macOS"),
            URLQueryItem(name: "osVersion", value: "14.0"),
            URLQueryItem(name: "architecture", value: "arm64"),
            URLQueryItem(name: "chip", value: ""),
            URLQueryItem(name: "deviceModel", value: deviceModel)
        ])
        return items
    }

    static func validateOfficialYoudaoWSS(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "wss",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              host == "youdao.com" || host.hasSuffix(".youdao.com") else {
            return nil
        }
        return url
    }

    // MARK: - Ticket Request & WebSocket Session

    private static func requestWebSocketURL(cookie: String) async throws -> URL {
        guard var comps = URLComponents(string: ticketEndpoint) else {
            throw VoiceProtocolError.invalidURL("八哥说 Ticket 地址无效")
        }
        comps.queryItems = buildSignedQueryItems(device: loadOrCreateDeviceID(), timestampMs: VoiceCrypto.nowMilliseconds())
        guard let url = comps.url else {
            throw VoiceProtocolError.invalidURL("八哥说 Ticket URL 拼接失败")
        }

        let bodyObj: [String: Any] = [
            "protocolVersion": 1,
            "capabilities": ["generationStreaming": true]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceProtocolError.networkFailed("八哥说 Ticket 响应异常")
        }
        if http.statusCode == 401 {
            throw VoiceProtocolError.handshakeFailed("八哥说登录已失效，请在设置中重新配置 Cookie")
        }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let container = (json["data"] as? [String: Any]) ?? json
        guard (200...299).contains(http.statusCode),
              let wsRaw = container["websocketUrl"] as? String,
              !wsRaw.isEmpty else {
            let msg = (json["message"] as? String) ?? (json["msg"] as? String) ?? "未知错误"
            throw VoiceProtocolError.handshakeFailed("八哥说获取会话失败：\(msg) (\(http.statusCode))")
        }
        guard let validated = validateOfficialYoudaoWSS(wsRaw) else {
            throw VoiceProtocolError.handshakeFailed("八哥说返回的识别地址不是有道官方域名")
        }
        return validated
    }

    private static func waitForEvent(ws: VoiceWebSocket, type expectedType: String, timeout: TimeInterval = 10) async throws {
        try await withAsyncTimeout(seconds: timeout, message: "八哥说等待 \(expectedType) 超时") {
            while true {
                let raw = try await ws.receiveData(timeout: timeout)
                guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let msgType = obj["type"] as? String else {
                    continue
                }
                if msgType == expectedType {
                    return
                }
                if msgType == "error" {
                    throw VoiceProtocolError.serverError(formatServerError(obj))
                }
            }
        }
    }

    private static func formatServerError(_ json: [String: Any]) -> String {
        let payload = json["payload"] as? [String: Any]
        let message = (payload?["message"] as? String) ?? "识别失败"
        let code = (payload?["code"] as? String) ?? "-"
        return "八哥说 \(message) (\(code))"
    }

    private static func runSession(
        audioStream: AsyncStream<[Int16]>,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let cookie = VoiceDataStore.shared.cookie(for: .bageshuo),
              VoiceDataStore.shared.hasCookie(for: .bageshuo) else {
            throw VoiceProtocolError.handshakeFailed("八哥说未配置有道登录 Cookie，请在设置 → 语音输入中配置")
        }

        let wsURL = try await requestWebSocketURL(cookie: cookie)
        let ws = try await VoiceWebSocket.connect(
            url: wsURL,
            headers: [
                ("Cookie", cookie),
                ("User-Agent", userAgent)
            ],
            timeout: 10
        )
        defer { ws.close() }

        try await waitForEvent(ws: ws, type: "connection.ready", timeout: 10)

        let utteranceID = UUID().uuidString.lowercased()
        let startObj: [String: Any] = [
            "v": 1,
            "type": "utterance.start",
            "utteranceId": utteranceID,
            "payload": [
                "operation": "POLISH",
                "asrLang": "zh-CHS",
                "preRollPcmBase64": ""
            ]
        ]
        let startText = String(decoding: try JSONSerialization.data(withJSONObject: startObj), as: UTF8.self)
        try await ws.sendText(startText)
        try await waitForEvent(ws: ws, type: "utterance.ready", timeout: 10)

        let shared = OSAllocatedUnfairLock(initialState: (text: "", sentAudio: false, lastActivity: Date()))

        let pingTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                try? await ws.sendPing()
            }
        }
        defer { pingTask.cancel() }

        let senderTask = Task<Void, Error> {
            for await frame in audioStream {
                try Task.checkCancellation()
                let pcm = VoiceCrypto.pcm16LittleEndianData(frame)
                shared.withLock {
                    $0.sentAudio = true
                    $0.lastActivity = Date()
                }
                try await ws.sendBinary(pcm)
            }
            let endObj: [String: Any] = [
                "v": 1,
                "type": "utterance.end",
                "utteranceId": utteranceID
            ]
            let endText = String(decoding: try JSONSerialization.data(withJSONObject: endObj), as: UTF8.self)
            shared.withLock { $0.lastActivity = Date() }
            try await ws.sendText(endText)
        }
        defer { senderTask.cancel() }

        var receiveError: Error?
        while !Task.isCancelled {
            let lastAct = shared.withLock { $0.lastActivity }
            let remaining = max(0.5, 30.0 - Date().timeIntervalSince(lastAct))
            do {
                let raw = try await ws.receiveData(timeout: remaining)
                shared.withLock { $0.lastActivity = Date() }
                guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let msgType = obj["type"] as? String else {
                    continue
                }
                let payload = obj["payload"] as? [String: Any]
                switch msgType {
                case "transcript.partial":
                    if let full = payload?["fullText"] as? String, !full.isEmpty {
                        let changed = shared.withLock { s -> Bool in
                            guard s.text != full else { return false }
                            s.text = full
                            return true
                        }
                        if changed {
                            onPartial(full)
                        }
                    }
                case "transcript.final":
                    if let full = payload?["fullText"] as? String, !full.isEmpty {
                        shared.withLock { $0.text = full }
                    }
                    senderTask.cancel()
                    pingTask.cancel()
                    return shared.withLock { $0.text }
                case "error":
                    receiveError = VoiceProtocolError.serverError(formatServerError(obj))
                default:
                    continue
                }
                if receiveError != nil {
                    break
                }
            } catch {
                // Re-check sliding idle timeout in case sender recently pushed audio
                if case VoiceProtocolError.timeout = error {
                    let elapsed = Date().timeIntervalSince(shared.withLock { $0.lastActivity })
                    if elapsed < 29.5 {
                        continue
                    }
                }
                receiveError = error
                break
            }
        }

        senderTask.cancel()
        pingTask.cancel()

        let snap = shared.withLock { $0 }
        if let receiveError {
            if !snap.text.isEmpty {
                return snap.text
            }
            throw receiveError
        }
        if snap.text.isEmpty && !snap.sentAudio {
            throw VoiceProtocolError.serverError("没有采集到音频")
        }
        return snap.text
    }
}
