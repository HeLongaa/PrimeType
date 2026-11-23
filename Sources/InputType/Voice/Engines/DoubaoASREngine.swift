import Foundation
import os

final class DoubaoASREngine: VoiceASREngine {
    let channel: VoiceCloudChannel = .doubao

    private static let registerURL = "https://log-klink.zijieapi.com/service/2/device_register/"
    private static let wsBaseURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    private static let okStatus: Int32 = 20_000_000
    private static let appToken = "OrnqKvSSrs"
    private static let frameFlagFirst: UInt64 = 1
    private static let frameFlagMiddle: UInt64 = 3
    private static let frameFlagLast: UInt64 = 9

    private static let fixedAppParams: [(String, String)] = [
        ("aid", "401734"),
        ("app_name", "oime"),
        ("channel", "official"),
        ("version_code", "100406010"),
        ("version_name", "1.4.6"),
        ("manifest_version_code", "100406010"),
        ("update_version_code", "100406010"),
        ("package", "com.bytedance.android.doubaoime")
    ]

    private struct DeviceProfile: Codable, Sendable {
        let brand: String
        let model: String
        let os: String
        let api: String
        let build: String
        let resolution: String
        let dpi: String

        static let presets: [DeviceProfile] = [
            DeviceProfile(brand: "google", model: "Pixel 7 Pro", os: "16", api: "36", build: "BP2A.250605.031.A2", resolution: "1080*2340", dpi: "420"),
            DeviceProfile(brand: "google", model: "Pixel 8", os: "15", api: "35", build: "AP4A.250205.002", resolution: "1080*2400", dpi: "420"),
            DeviceProfile(brand: "samsung", model: "SM-S9210", os: "14", api: "34", build: "UP1A.231005.007", resolution: "1080*2340", dpi: "480"),
            DeviceProfile(brand: "Xiaomi", model: "23127PN0CC", os: "14", api: "34", build: "UKQ1.230804.001", resolution: "1200*2670", dpi: "440")
        ]

        var userAgent: String {
            "com.bytedance.android.doubaoime/100406010 (Linux; U; Android \(os); en_US; \(model); Build/\(build); Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
        }

        func baseParams() -> [(String, String)] {
            DoubaoASREngine.fixedAppParams + [
                ("device_platform", "android"),
                ("os", "android"),
                ("os_api", api),
                ("os_version", os),
                ("device_type", model),
                ("device_brand", brand),
                ("device_model", model),
                ("resolution", resolution),
                ("dpi", dpi),
                ("language", "zh"),
                ("timezone", "8"),
                ("access", "wifi"),
                ("rom", build),
                ("rom_version", build)
            ]
        }
    }

    private struct DeviceCredential: Codable, Sendable {
        let did: String
        let profile: DeviceProfile
    }

    private enum SessionFailure: Error {
        case deviceRejected(String)
        case fatal(Error)
    }

    private final class TranscriptAccumulator: @unchecked Sendable {
        private struct State {
            var finalized: [Int: String] = [:]
            var current: String = ""
            var nextIndex: Int = 0
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        func update(resultJSON: String) -> String? {
            guard let data = resultJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                return nil
            }

            return lock.withLock { s in
                let hasIndex = results.contains { $0["index"] != nil }
                if !hasIndex {
                    guard let first = results.first,
                          let text = first["text"] as? String,
                          !text.isEmpty else {
                        return nil
                    }
                    s.finalized.removeAll()
                    s.current = text
                    return text
                }

                for item in results {
                    guard let text = item["text"] as? String, !text.isEmpty else { continue }
                    let extra = item["extra"] as? [String: Any]
                    let nonstream = (extra?["nonstream_result"] as? Bool) ?? false
                    let isInterim = item["is_interim"] as? Bool
                    let isVadFinished = item["is_vad_finished"] as? Bool
                    let isSentenceFinal = nonstream || (isInterim == false && isVadFinished == true)

                    if isSentenceFinal {
                        let idx = (item["index"] as? Int) ?? s.nextIndex
                        s.finalized[idx] = text
                        s.nextIndex = max(s.nextIndex, idx + 1)
                        s.current = ""
                    } else {
                        s.current = text
                    }
                }
                return Self.buildText(state: s)
            }
        }

        func currentText() -> String {
            lock.withLock { Self.buildText(state: $0) }
        }

        private static func buildText(state: State) -> String {
            var parts = state.finalized.keys.sorted().compactMap { state.finalized[$0] }
            if !state.current.isEmpty {
                parts.append(state.current)
            }
            return VoiceCrypto.joinSentenceFragments(parts)
        }
    }

    func start(sampleRate: UInt32, onEvent: @escaping (VoiceASREvent) -> Void) -> (any VoiceASRSession)? {
        StreamingVoiceASRSession(onEvent: onEvent) { audioStream, onPartial in
            try await Self.runWithRetry(audioStream: audioStream, onPartial: onPartial)
        }
    }

    func prewarm() {
        Task.detached(priority: .utility) {
            _ = try? await Self.loadOrRegisterDevice()
        }
    }

    // MARK: - Device Registration

    private static var deviceFileURL: URL {
        VoiceDataStore.shared.fileURL(named: "doubao_device.json")
    }

    private static func resetDevice() {
        try? FileManager.default.removeItem(at: deviceFileURL)
    }

    private static func loadOrRegisterDevice() async throws -> DeviceCredential {
        if let data = try? Data(contentsOf: deviceFileURL),
           let cached = try? JSONDecoder().decode(DeviceCredential.self, from: data),
           !cached.did.isEmpty, cached.did != "0" {
            return cached
        }
        let fresh = try await registerNewDevice()
        if let encoded = try? JSONEncoder().encode(fresh) {
            try? encoded.write(to: deviceFileURL, options: .atomic)
        }
        return fresh
    }

    private static func registerNewDevice() async throws -> DeviceCredential {
        let profile = DeviceProfile.presets.randomElement() ?? DeviceProfile.presets[0]
        let cdid = UUID().uuidString.lowercased()
        let nowMs = VoiceCrypto.nowMilliseconds()
        let nowStr = String(nowMs)

        let baseParams = profile.baseParams()
        var queryItems = baseParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "_rticket", value: nowStr),
            URLQueryItem(name: "cdid", value: cdid),
            URLQueryItem(name: "ac", value: "wifi")
        ])

        guard var comps = URLComponents(string: registerURL) else {
            throw VoiceProtocolError.invalidURL("豆包设备注册地址无效")
        }
        comps.queryItems = queryItems
        guard let url = comps.url else {
            throw VoiceProtocolError.invalidURL("豆包设备注册 URL 拼接失败")
        }

        var headerDict: [String: Any] = [:]
        for (k, v) in baseParams {
            headerDict[k] = v
        }
        headerDict["device_id"] = 0
        headerDict["install_id"] = 0
        headerDict["cdid"] = cdid
        headerDict["openudid"] = VoiceCrypto.randomHex(byteCount: 8, uppercase: false)
        headerDict["clientudid"] = UUID().uuidString.lowercased()
        headerDict["region"] = "CN"
        headerDict["tz_name"] = "Asia/Shanghai"
        headerDict["tz_offset"] = 28800
        headerDict["sim_region"] = "cn"
        headerDict["carrier_region"] = "cn"
        headerDict["cpu_abi"] = "arm64-v8a"
        headerDict["build_serial"] = "unknown"
        headerDict["not_request_sender"] = 0
        headerDict["sig_hash"] = ""
        headerDict["google_aid"] = ""
        headerDict["mc"] = ""
        headerDict["serial_number"] = ""

        let bodyObj: [String: Any] = [
            "magic_tag": "ss_app_log",
            "header": headerDict,
            "_gen_time": nowMs
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VoiceProtocolError.handshakeFailed("豆包设备注册 HTTP 失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceProtocolError.handshakeFailed("豆包设备注册响应格式异常")
        }

        let did: String
        if let str = json["device_id_str"] as? String, !str.isEmpty, str != "0" {
            did = str
        } else if let num = json["device_id"] as? NSNumber, num.uint64Value > 0 {
            did = String(num.uint64Value)
        } else {
            throw VoiceProtocolError.handshakeFailed("豆包设备注册被拒绝")
        }
        return DeviceCredential(did: did, profile: profile)
    }

    // MARK: - Streaming Session with Automatic Device-Rejection Replay

    private static func runWithRetry(
        audioStream: AsyncStream<[Int16]>,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let recorded = OSAllocatedUnfairLock(initialState: [[Int16]]())

        let teeStream = AsyncStream<[Int16]> { continuation in
            let task = Task {
                for await frame in audioStream {
                    recorded.withLock { $0.append(frame) }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        do {
            return try await runSingleSession(audioStream: teeStream, intervalMs: 20, onPartial: onPartial)
        } catch SessionFailure.deviceRejected(let reason) {
            resetDevice()
            let replayFrames = recorded.withLock { frames -> [[Int16]] in
                let copy = frames
                frames.removeAll()
                return copy
            }
            guard !replayFrames.isEmpty else {
                throw VoiceProtocolError.serverError(reason)
            }
            let replayStream = AsyncStream<[Int16]> { continuation in
                for f in replayFrames {
                    continuation.yield(f)
                }
                continuation.finish()
            }
            do {
                return try await runSingleSession(audioStream: replayStream, intervalMs: 5, onPartial: onPartial)
            } catch SessionFailure.deviceRejected(let retryReason) {
                resetDevice()
                throw VoiceProtocolError.serverError("\(reason)；换设备重试失败：\(retryReason)")
            } catch SessionFailure.fatal(let retryErr) {
                resetDevice()
                throw VoiceProtocolError.serverError("\(reason)；换设备重试失败：\(retryErr.localizedDescription)")
            }
        } catch SessionFailure.fatal(let err) {
            throw err
        }
    }

    private static func runSingleSession(
        audioStream: AsyncStream<[Int16]>,
        intervalMs: UInt64,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let device: DeviceCredential
        do {
            device = try await loadOrRegisterDevice()
        } catch {
            throw SessionFailure.fatal(error)
        }

        let rid = UUID().uuidString.lowercased()
        guard let url = URL(string: "\(wsBaseURL)?aid=401734&device_id=\(device.did)") else {
            throw SessionFailure.fatal(VoiceProtocolError.invalidURL("豆包 WebSocket 地址无效"))
        }

        let ws: VoiceWebSocket
        do {
            ws = try await VoiceWebSocket.connect(
                url: url,
                headers: [
                    ("User-Agent", device.profile.userAgent),
                    ("proto-version", "v2"),
                    ("x-custom-keepalive", "true")
                ],
                timeout: 10
            )
        } catch {
            throw SessionFailure.fatal(error)
        }
        defer { ws.close() }

        // Handshake: StartTask -> TaskStarted -> StartSession -> SessionStarted
        do {
            let startTask = encodeRequest(token: appToken, method: "StartTask", payload: nil, audio: nil, rid: rid, frameFlag: 0)
            try await ws.sendBinary(startTask)
            try await expectEvent(ws: ws, expected: "TaskStarted", timeout: 10)

            let sessionPayloadObj: [String: Any] = [
                "audio_info": [
                    "channel": 1,
                    "format": "speech_opus",
                    "sample_rate": 16000
                ],
                "enable_punctuation": true,
                "enable_speech_rejection": true,
                "extra": [
                    "app_name": "oime",
                    "cell_compress_rate": 8,
                    "did": device.did,
                    "enable_asr_threepass": false,
                    "enable_asr_twopass": true,
                    "input_mode": "stream"
                ]
            ]
            let sessionPayloadData = try JSONSerialization.data(withJSONObject: sessionPayloadObj)
            let sessionPayload = String(decoding: sessionPayloadData, as: UTF8.self)
            let startSession = encodeRequest(token: appToken, method: "StartSession", payload: sessionPayload, audio: nil, rid: rid, frameFlag: 0)
            try await ws.sendBinary(startSession)
            try await expectEvent(ws: ws, expected: "SessionStarted", timeout: 10)
        } catch {
            resetDevice()
            throw SessionFailure.fatal(error)
        }

        let transcript = TranscriptAccumulator()
        let receiverTask = Task<Void, Error> {
            while !Task.isCancelled {
                let raw = try await ws.receiveData(timeout: 600)
                let resp = try decodeResponse(raw)
                if !resp.result.isEmpty, let updated = transcript.update(resultJSON: resp.result) {
                    onPartial(updated)
                }
                if resp.event.hasSuffix("Failed") {
                    throw VoiceProtocolError.serverError("豆包 \(resp.event) \(resp.status): \(resp.message)")
                }
                if resp.event == "SessionFinished" {
                    return
                }
            }
        }
        defer { receiverTask.cancel() }

        let encoder: OpusEncoder
        do {
            encoder = try OpusEncoder(sampleRate: 16000, channels: 1, application: .voip, bitrate: 16000, complexity: 5)
        } catch {
            throw SessionFailure.fatal(error)
        }

        let paced = VoiceAudioPacer.pacedStream(from: audioStream, leadingSilenceFrames: 0, frameSamples: 320, intervalMs: intervalMs)
        let ts0 = VoiceCrypto.nowMilliseconds()
        var frameIndex: UInt64 = 0

        do {
            for await frame in paced {
                try Task.checkCancellation()
                let opusPacket = try encoder.encode(pcm16: frame)
                let meta = "{\"extra\":{},\"timestamp_ms\":\(ts0 + frameIndex * 20)}"
                let flag = (frameIndex == 0) ? frameFlagFirst : frameFlagMiddle
                let req = encodeRequest(token: nil, method: "TaskRequest", payload: meta, audio: opusPacket, rid: rid, frameFlag: flag)
                try await ws.sendBinary(req)
                frameIndex += 1
            }

            let endMeta = "{\"extra\":{},\"timestamp_ms\":\(ts0 + frameIndex * 20)}"
            let endAudioReq = encodeRequest(token: nil, method: "TaskRequest", payload: endMeta, audio: nil, rid: rid, frameFlag: frameFlagLast)
            try await ws.sendBinary(endAudioReq)

            let finishReq = encodeRequest(token: appToken, method: "FinishSession", payload: nil, audio: nil, rid: rid, frameFlag: 0)
            try await ws.sendBinary(finishReq)
        } catch is CancellationError {
            throw SessionFailure.fatal(CancellationError())
        } catch {
            let text = transcript.currentText()
            if !text.isEmpty {
                return text
            }
            throw SessionFailure.fatal(error)
        }

        let finishTimeout = 10.0 + Double(frameIndex) / 200.0
        do {
            try await withAsyncTimeout(seconds: finishTimeout, message: "豆包定稿超时") {
                try await receiverTask.value
            }
            return transcript.currentText()
        } catch {
            let text = transcript.currentText()
            if !text.isEmpty {
                return text
            }
            let desc = error.localizedDescription
            if desc.contains("Failed") {
                throw SessionFailure.deviceRejected(desc)
            }
            throw SessionFailure.fatal(error)
        }
    }

    // MARK: - Protobuf Framing

    private struct ServerResponse {
        let event: String
        let status: Int32
        let message: String
        let result: String
    }

    private static func encodeRequest(
        token: String?,
        method: String,
        payload: String?,
        audio: Data?,
        rid: String,
        frameFlag: UInt64
    ) -> Data {
        var writer = ProtoWriter()
        if let token, !token.isEmpty {
            writer.writeString(field: 2, value: token)
        }
        writer.writeString(field: 3, value: "ASR")
        writer.writeString(field: 5, value: method)
        if let payload, !payload.isEmpty {
            writer.writeString(field: 6, value: payload)
        }
        if let audio, !audio.isEmpty {
            writer.writeBytes(field: 7, value: audio)
        }
        writer.writeString(field: 8, value: rid)
        if frameFlag != 0 {
            writer.writeVarint(field: 9, value: frameFlag)
        }
        return writer.data
    }

    private static func decodeResponse(_ data: Data) throws -> ServerResponse {
        let msg = try ProtoMessage.decode(data)
        let event = msg.string(for: 4) ?? ""
        let statusRaw = msg.varint(for: 5) ?? 0
        let status = Int32(truncatingIfNeeded: statusRaw)
        let message = msg.string(for: 6) ?? ""
        let result = msg.string(for: 7) ?? ""
        return ServerResponse(event: event, status: status, message: message, result: result)
    }

    private static func expectEvent(ws: VoiceWebSocket, expected: String, timeout: TimeInterval) async throws {
        try await withAsyncTimeout(seconds: timeout, message: "豆包握手等待 \(expected) 超时") {
            while true {
                let raw = try await ws.receiveData(timeout: timeout)
                let resp = try decodeResponse(raw)
                if resp.event.hasSuffix("Failed") || (resp.event == expected && resp.status != okStatus) {
                    throw VoiceProtocolError.serverError("豆包 \(resp.event) \(resp.status): \(resp.message)")
                }
                if resp.event == expected {
                    return
                }
            }
        }
    }
}
