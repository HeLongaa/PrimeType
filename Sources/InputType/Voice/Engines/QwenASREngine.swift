import Foundation
import os

final class QwenASREngine: VoiceASREngine {
    let channel: VoiceCloudChannel = .qwen

    private static let version = "1.2.35.46"
    private static let origin = "https://www.qianwen.com"
    private static let hmacKey = Data("2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48".utf8)
    private static let aesKey = Data("a0a6237b2b735a54".utf8)
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice"
    private static let chunkByteSize = 3840

    private struct DeviceInfo: Codable {
        let utdid: String
    }

    private struct AuthParams {
        let utRawBase64: String
        let chid: String
        let reqt: String
        let sign: String

        var encodedUT: String {
            VoiceCrypto.rfc3986Encode(utRawBase64)
        }

        var queryString: String {
            "chid=\(chid)&biz_id=ai_qwen_input&from=kkframenew_quark_asr&uc_param_str=vepffrprsvchut&ut=\(encodedUT)&ve=\(QwenASREngine.version)&pf=8002&pr=qwen&fr=mac&sv=release&ch=qianwen-ime"
        }

        var headers: [(String, String)] {
            [
                ("Cache-Control", "no-cache"),
                ("User-Agent", QwenASREngine.userAgent),
                ("Origin", QwenASREngine.origin),
                ("clt-acs-ut", encodedUT),
                ("clt-acs-ve", QwenASREngine.version),
                ("clt-acs-kp", ""),
                ("clt-acs-reqt", reqt),
                ("clt-acs-wsgnver", "1"),
                ("clt-acs-request-params", "chid"),
                ("clt-acs-sign", sign),
                ("clt-acs-caer", "tlbe"),
                ("x-wpk-reqid", chid)
            ]
        }

        static func create() throws -> AuthParams {
            let utdid = QwenASREngine.loadOrCreateUTDID()
            let encrypted = try VoiceCrypto.aesCBCEncrypt(
                key: QwenASREngine.aesKey,
                iv: QwenASREngine.aesKey,
                plaintext: Data(utdid.utf8)
            )
            var packed = Data([0x4E, 0xA4])
            packed.append(encrypted)
            let ut = packed.base64EncodedString()
            let chid = "\(UUID().uuidString.lowercased())_1"
            let reqt = String(VoiceCrypto.nowMilliseconds())
            let signPayload = "\(ut)\(QwenASREngine.version)\(chid)\(reqt)"
            let macHex = VoiceCrypto.hmacSHA1Hex(key: QwenASREngine.hmacKey, message: Data(signPayload.utf8))
            let sign = "4ea4\(macHex)"
            return AuthParams(utRawBase64: ut, chid: chid, reqt: reqt, sign: sign)
        }
    }

    private final class Connection {
        let auth: AuthParams
        let ws: VoiceWebSocket
        var isDead = false
        var sessionID: String = ""
        var roundID: String = ""
        var isAttached = false

        private init(auth: AuthParams, ws: VoiceWebSocket) {
            self.auth = auth
            self.ws = ws
        }

        static func open() async throws -> Connection {
            let auth = try AuthParams.create()
            guard let url = URL(string: "wss://voice-input.qianwen.com/ws/v1/voice?\(auth.queryString)") else {
                throw VoiceProtocolError.invalidURL("千问 WebSocket 地址无效")
            }
            let ws = try await VoiceWebSocket.connect(url: url, headers: auth.headers, timeout: 10)
            return Connection(auth: auth, ws: ws)
        }

        func close() {
            isDead = true
            ws.close()
        }

        func resetRoundState() {
            isAttached = false
            sessionID = ""
            roundID = ""
        }

        func ensureAttached() async throws {
            if isAttached && !sessionID.isEmpty {
                return
            }
            do {
                try await performAttach()
            } catch {
                isDead = true
                throw error
            }
        }

        private func performAttach() async throws {
            let packet = try buildAttachPacket()
            try await ws.sendBinary(packet)

            let deadline = Date().addingTimeInterval(8.0)
            while Date() < deadline && sessionID.isEmpty {
                let remaining = max(0.2, min(2.0, deadline.timeIntervalSinceNow))
                do {
                    let raw = try await ws.receiveData(timeout: remaining)
                    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          let dataObj = obj["data"] as? [String: Any],
                          let sid = dataObj["sessionId"] as? String,
                          !sid.isEmpty else {
                        continue
                    }
                    let rid = dataObj["roundId"] as? String
                    recordSession(id: sid, round: rid)
                } catch VoiceProtocolError.timeout {
                    continue
                }
            }

            if sessionID.isEmpty {
                throw VoiceProtocolError.handshakeFailed("千问会话绑定未返回 sessionId")
            }
        }

        func recordSession(id: String, round: String?) {
            sessionID = id
            if let round, !round.isEmpty {
                roundID = round
            } else {
                roundID = "ro_\(id)_0"
            }
            isAttached = true
        }

        private func buildAttachPacket() throws -> Data {
            let reqt = String(VoiceCrypto.nowMilliseconds())
            let asrConfig: [String: Any] = [
                "body": [
                    "bitDepth": "16",
                    "channel": "mono",
                    "format": "pcm",
                    "maxEndSilence": "180000",
                    "maxStartSilence": "180000",
                    "sampleRate": "16000",
                    "type": "manualStreamStop"
                ],
                "chid": auth.chid,
                "header": [
                    "clt-acs-reqt": reqt,
                    "ai_polish_mode": "off"
                ],
                "param": [String: Any](),
                "route": "/app/live/init"
            ]
            let pipelineCtx: [String: Any] = [
                "biz_data": [String: Any](),
                "biz_id": "ai_command",
                "chat_client": "native",
                "client_tm": reqt,
                "endpoint_config": [String: Any](),
                "from": "kkframenew_quark_asr",
                "scene": "voice_input_assistant",
                "ai_polish_mode": "off"
            ]
            let asrStr = String(decoding: try JSONSerialization.data(withJSONObject: asrConfig), as: UTF8.self)
            let pipeStr = String(decoding: try JSONSerialization.data(withJSONObject: pipelineCtx), as: UTF8.self)

            var writer = ProtoWriter()
            writer.writeString(field: 1, value: "/voice_assistant/channel/attach")
            writer.writeString(field: 2, value: auth.chid)
            writer.writeKeyValue(field: 3, key: "clt-acs-reqt", value: reqt)
            writer.writeKeyValue(field: 5, key: "asrConfig", value: asrStr)
            writer.writeKeyValue(field: 5, key: "pipelineContext", value: pipeStr)
            writer.writeKeyValue(field: 5, key: "trigger", value: "local_device")
            return writer.data
        }

        private func baseFrame(route: String) -> ProtoWriter {
            var writer = ProtoWriter()
            writer.writeString(field: 1, value: route)
            writer.writeString(field: 2, value: auth.chid)
            writer.writeKeyValue(field: 3, key: "clt-acs-reqt", value: String(VoiceCrypto.nowMilliseconds()))
            writer.writeKeyValue(field: 4, key: "roundId", value: roundID)
            writer.writeKeyValue(field: 4, key: "sessionId", value: sessionID)
            return writer
        }

        func buildAudioFrame(pcmChunk: Data) -> Data {
            var audioSub = ProtoWriter()
            audioSub.writeString(field: 1, value: "audio")
            audioSub.writeString(field: 2, value: "pcm")
            audioSub.writeBytes(field: 3, value: pcmChunk)

            var frame = baseFrame(route: "/voice_assistant/channel/asr/send")
            frame.writeKeyValue(field: 5, key: "streamInputState", value: "process")
            frame.writeMessage(field: 6, value: audioSub)
            return frame.data
        }

        func buildCompleteFrame() -> Data {
            baseFrame(route: "/voice_assistant/channel/asr/complete").data
        }
    }

    private actor ConnectionPool {
        private var idle: Connection?

        func take(forceFresh: Bool = false) async throws -> (conn: Connection, reused: Bool) {
            if !forceFresh, let existing = idle, !existing.isDead, !existing.ws.isClosed {
                idle = nil
                return (existing, true)
            }
            idle?.close()
            idle = nil
            do {
                let fresh = try await Connection.open()
                return (fresh, false)
            } catch {
                QwenASREngine.resetUTDID()
                throw error
            }
        }

        func put(_ conn: Connection) {
            if conn.isDead || conn.ws.isClosed {
                conn.close()
                return
            }
            conn.resetRoundState()
            idle?.close()
            idle = conn
        }

        func prewarm() async {
            if let existing = idle, !existing.isDead, !existing.ws.isClosed {
                return
            }
            if let fresh = try? await Connection.open() {
                idle?.close()
                idle = fresh
            }
        }
    }

    private let pool = ConnectionPool()

    func start(sampleRate: UInt32, onEvent: @escaping (VoiceASREvent) -> Void) -> (any VoiceASRSession)? {
        let pool = self.pool
        return StreamingVoiceASRSession(onEvent: onEvent) { audioStream, onPartial in
            try await Self.runSession(pool: pool, audioStream: audioStream, onPartial: onPartial)
        }
    }

    func prewarm() {
        let pool = self.pool
        Task.detached(priority: .utility) {
            await pool.prewarm()
        }
    }

    // MARK: - Device Identity

    private static var deviceFileURL: URL {
        VoiceDataStore.shared.fileURL(named: "qwen_device.json")
    }

    private static func loadOrCreateUTDID() -> String {
        if let data = try? Data(contentsOf: deviceFileURL),
           let info = try? JSONDecoder().decode(DeviceInfo.self, from: data),
           !info.utdid.isEmpty {
            return info.utdid
        }
        let generated = "PT" + VoiceCrypto.randomHex(byteCount: 10, uppercase: true)
        if let encoded = try? JSONEncoder().encode(DeviceInfo(utdid: generated)) {
            try? encoded.write(to: deviceFileURL, options: .atomic)
        }
        return generated
    }

    private static func resetUTDID() {
        try? FileManager.default.removeItem(at: deviceFileURL)
    }

    // MARK: - Streaming Session

    private static func runSession(
        pool: ConnectionPool,
        audioStream: AsyncStream<[Int16]>,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var (conn, reused) = try await pool.take(forceFresh: false)
        var returnToPool = false
        defer {
            if !returnToPool {
                conn.close()
            }
        }

        do {
            try await conn.ensureAttached()
        } catch {
            guard reused else { throw error }
            conn.close()
            (conn, _) = try await pool.take(forceFresh: true)
            try await conn.ensureAttached()
        }

        let transcriptState = OSAllocatedUnfairLock(initialState: (text: "", isDone: false, nextRoundID: Optional<String>.none))

        let receiverTask = Task<Void, Error> {
            while !Task.isCancelled {
                let raw = try await conn.ws.receiveData(timeout: 600)
                guard let obj = try? JSONSerialization.jsonObject(with: raw) else { continue }
                if let dict = obj as? [String: Any],
                   let dataObj = dict["data"] as? [String: Any],
                   let sid = dataObj["sessionId"] as? String, !sid.isEmpty {
                    if let newRound = dataObj["newRoundId"] as? String, !newRound.isEmpty {
                        transcriptState.withLock {
                            $0.nextRoundID = newRound
                            $0.isDone = true
                        }
                    }
                }
                var extractedTexts: [String] = []
                collectContentTexts(from: obj, into: &extractedTexts)
                for text in extractedTexts where !text.isEmpty {
                    let changed = transcriptState.withLock { s -> Bool in
                        guard s.text != text else { return false }
                        s.text = text
                        return true
                    }
                    if changed {
                        onPartial(text)
                    }
                }
                if transcriptState.withLock({ $0.isDone }) {
                    return
                }
            }
        }
        defer { receiverTask.cancel() }

        let paced = VoiceAudioPacer.pacedStream(from: audioStream, leadingSilenceFrames: 0, frameSamples: 320, intervalMs: 20)
        var pcmBuffer = Data()
        pcmBuffer.reserveCapacity(chunkByteSize * 2)

        do {
            for await frame in paced {
                try Task.checkCancellation()
                pcmBuffer.append(VoiceCrypto.pcm16LittleEndianData(frame))
                while pcmBuffer.count >= chunkByteSize {
                    let chunk = Data(pcmBuffer.prefix(chunkByteSize))
                    pcmBuffer.removeFirst(chunkByteSize)
                    try await conn.ws.sendBinary(conn.buildAudioFrame(pcmChunk: chunk))
                }
            }

            if !pcmBuffer.isEmpty {
                let padLen = chunkByteSize - pcmBuffer.count
                if padLen > 0 {
                    pcmBuffer.append(Data(repeating: 0, count: padLen))
                }
                try await conn.ws.sendBinary(conn.buildAudioFrame(pcmChunk: pcmBuffer))
                pcmBuffer.removeAll()
            }

            try await conn.ws.sendBinary(conn.buildCompleteFrame())

            // Wait up to 2000ms for server newRoundId final marker
            var completedCleanly = false
            do {
                try await withAsyncTimeout(seconds: 2.0, message: "千问定稿等待超时") {
                    try await receiverTask.value
                }
                completedCleanly = true
            } catch VoiceProtocolError.timeout {
                receiverTask.cancel()
            }
            if completedCleanly {
                if let nextRound = transcriptState.withLock({ $0.nextRoundID }) {
                    conn.roundID = nextRound
                }
                returnToPool = true
                await pool.put(conn)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let kept = transcriptState.withLock { $0.text }
            if !kept.isEmpty {
                return kept
            }
            conn.isDead = true
            throw error
        }

        receiverTask.cancel()

        let finalText = transcriptState.withLock { $0.text }
        guard !finalText.isEmpty else {
            throw VoiceProtocolError.serverError("千问没有识别文本")
        }
        return finalText
    }

    private static func collectContentTexts(from value: Any, into results: inout [String]) {
        if let dict = value as? [String: Any] {
            if let content = dict["content"] as? [String: Any],
               let text = content["text"] as? String,
               !text.isEmpty {
                results.append(text)
            }
            for (_, v) in dict {
                collectContentTexts(from: v, into: &results)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectContentTexts(from: item, into: &results)
            }
        }
    }
}
