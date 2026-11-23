import Foundation

final class WeTypeASREngine: VoiceASREngine {
    let channel: VoiceCloudChannel = .wetype

    private static let host = "wetype.weixin.qq.com"
    private static let signKey = "zN7rB3bL4pO8jW1o"
    private static let bootKey = Data("D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6".utf8)
    private static let version = "2.2.3(657)"
    private static let osType = "5"
    private static let platform = "2"
    private static let systemVersion = "27.0.0"
    private static let deviceModel = "Mac16,12"

    private static let cmdDH: UInt64 = 2_147_483_646
    private static let cmdGenUin: UInt64 = 0x7FFF_FDFD
    private static let cmdNotify: UInt64 = 8074
    private static let cmdVoice: UInt64 = 4548
    private static let framesPerBatch = 6

    private struct Identity: Codable, Sendable {
        let device: String
        let uin: String
    }

    private struct InnerReply {
        let status: UInt64
        let headers: [String: String]
        let body: Data
    }

    private final class Connection {
        let ws: VoiceWebSocket
        var isDead = false
        var taskCounter: UInt64 = 0
        var uin: String = "0"
        var device: String = ""
        var sessionKey: Data?
        var serverPublicHex: String = ""
        var genUinToken: String = ""

        private init(ws: VoiceWebSocket) {
            self.ws = ws
        }

        static func open() async throws -> Connection {
            guard let url = URL(string: "wss://\(WeTypeASREngine.host)/") else {
                throw VoiceProtocolError.invalidURL("微信 WebSocket 地址无效")
            }
            let ws = try await VoiceWebSocket.connect(url: url, subprotocols: ["wxws_pb"], timeout: 10)
            let conn = Connection(ws: ws)
            do {
                try await conn.performHandshake()
                return conn
            } catch {
                conn.close()
                throw error
            }
        }

        func close() {
            isDead = true
            ws.close()
        }

        private static var identityFileURL: URL {
            VoiceDataStore.shared.fileURL(named: "wetype_identity.json")
        }

        private func performHandshake() async throws {
            _ = try await roundtrip(path: "/timestamp", body: Data(), cmd: 0, compressionType: "1", genUinToken: "")

            let cached = loadIdentity()
            if let cached {
                self.device = cached.device
                self.uin = cached.uin
                do {
                    try await exchangeKey(needUin: false)
                } catch {
                    try await registerNewIdentity()
                }
            } else {
                try await registerNewIdentity()
            }

            if cached?.device != device || cached?.uin != uin {
                saveIdentity(Identity(device: device, uin: uin))
            }

            let notifyBody = try VoiceCrypto.aesECBEncrypt(key: try requireSessionKey(), plaintext: Data())
            _ = try await roundtrip(path: "/api_v2", body: notifyBody, cmd: WeTypeASREngine.cmdNotify, compressionType: "1", genUinToken: "")
        }

        private func requireSessionKey() throws -> Data {
            guard let sessionKey else {
                throw VoiceProtocolError.cryptoFailed("微信会话密钥尚未协商")
            }
            return sessionKey
        }

        private func exchangeKey(needUin: Bool) async throws {
            let (privKey, pubHex) = Secp128r1ECDH.generateKeyPair()
            var req = ProtoWriter()
            req.writeString(field: 1, value: pubHex)
            req.writeString(field: 2, value: pubHex)
            if needUin {
                req.writeVarint(field: 3, value: 1)
            }
            req.writeString(field: 4, value: device)
            if !needUin {
                req.writeVarint(field: 5, value: UInt64(uin) ?? 0)
            }
            req.writeString(field: 7, value: "")
            req.writeString(field: 8, value: WeTypeASREngine.deviceModel)
            req.writeString(field: 9, value: "")

            let encryptedReq = try VoiceCrypto.aesECBEncrypt(key: WeTypeASREngine.bootKey, plaintext: req.data)
            let reply = try await roundtrip(path: "/oauth_pubkey_v2", body: encryptedReq, cmd: WeTypeASREngine.cmdDH, compressionType: "1", genUinToken: "")
            guard reply.status == 200, !reply.body.isEmpty else {
                throw VoiceProtocolError.handshakeFailed("微信密钥交换失败 (status \(reply.status))")
            }
            let plainResp = try VoiceCrypto.aesECBDecrypt(key: WeTypeASREngine.bootKey, ciphertext: reply.body)
            let msg = try ProtoMessage.decode(plainResp)
            guard let serverPub = msg.string(for: 2), !serverPub.isEmpty else {
                throw VoiceProtocolError.handshakeFailed("微信服务端公钥缺失")
            }
            let token = msg.string(for: 4) ?? ""
            if needUin && token.isEmpty {
                throw VoiceProtocolError.handshakeFailed("微信未下发 UIN 令牌")
            }
            let sharedHex = try Secp128r1ECDH.deriveSharedKeyHex(privateKey: privKey, peerPublicHex: serverPub)
            self.sessionKey = Data(sharedHex.utf8)
            self.serverPublicHex = serverPub
            self.genUinToken = token
        }

        private func registerNewIdentity() async throws {
            self.uin = "0"
            let padCount = max(0, 17 - WeTypeASREngine.deviceModel.count)
            let bodyPart = "MAC" + String(repeating: "0", count: padCount) + WeTypeASREngine.deviceModel + VoiceCrypto.randomLowerLetters(count: 12)
            let checksum = VoiceCrypto.md5Hex(Data((bodyPart + WeTypeASREngine.signKey).utf8), uppercase: true)
            self.device = bodyPart + checksum

            try await exchangeKey(needUin: true)

            var req = ProtoWriter()
            req.writeString(field: 1, value: device)
            req.writeString(field: 2, value: serverPublicHex)
            req.writeString(field: 4, value: genUinToken)

            let key = try requireSessionKey()
            let encryptedReq = try VoiceCrypto.aesECBEncrypt(key: key, plaintext: req.data)
            let reply = try await roundtrip(path: "/gen_uin_v2", body: encryptedReq, cmd: WeTypeASREngine.cmdGenUin, compressionType: "1", genUinToken: genUinToken)
            guard reply.status == 200, !reply.body.isEmpty else {
                throw VoiceProtocolError.handshakeFailed("微信签发 UIN 失败 (status \(reply.status))")
            }
            let plainResp = try VoiceCrypto.aesECBDecrypt(key: key, ciphertext: reply.body)
            let msg = try ProtoMessage.decode(plainResp)
            guard let issued = msg.varint(for: 2), issued != 0 else {
                throw VoiceProtocolError.handshakeFailed("微信未返回有效 UIN")
            }
            self.uin = String(issued)
        }

        func sendVoice(voiceID: String, opusPayload: Data?, seq: UInt64, totalBytes: Int, isEnd: Bool) async throws -> (partial: String, polished: String) {
            var inner = ProtoWriter()
            inner.writeString(field: 2, value: voiceID)
            if let opusPayload, !opusPayload.isEmpty {
                inner.writeBytes(field: 4, value: opusPayload)
            }
            inner.writeVarint(field: 5, value: 5)
            if isEnd {
                inner.writeVarint(field: 6, value: 1)
            }
            inner.writeVarint(field: 7, value: seq)
            if totalBytes > 0 {
                inner.writeVarint(field: 11, value: UInt64(totalBytes))
            }
            inner.writeVarint(field: 22, value: 1)
            inner.writeVarint(field: 23, value: 1)
            inner.writeVarint(field: 24, value: 1)

            var outer = ProtoWriter()
            outer.writeMessage(field: 1, value: inner)

            let key = try requireSessionKey()
            let compressed = RawSnappy.compress(outer.data)
            let encrypted = try VoiceCrypto.aesECBEncrypt(key: key, plaintext: compressed)
            let reply = try await roundtrip(path: "/api_v2", body: encrypted, cmd: WeTypeASREngine.cmdVoice, compressionType: "2", genUinToken: "")
            guard reply.status == 200, !reply.body.isEmpty else {
                throw VoiceProtocolError.serverError("微信语音请求失败 (status \(reply.status))")
            }

            var plain = try VoiceCrypto.aesECBDecrypt(key: key, ciphertext: reply.body)
            let compHeader = reply.headers["Kb-CompressionType"] ?? reply.headers["CompressionType"]
            if compHeader == "2" {
                plain = try RawSnappy.decompress(plain)
            }

            let top = try ProtoMessage.decode(plain)
            let payloadMsg = try top.bytes(for: 1).map { try ProtoMessage.decode($0) } ?? top
            let rawText = payloadMsg.string(for: 4) ?? ""
            let polishedText = payloadMsg.string(for: 14) ?? ""
            return (rawText, polishedText)
        }

        private func roundtrip(path: String, body: Data, cmd: UInt64, compressionType: String, genUinToken: String) async throws -> InnerReply {
            do {
                return try await performRoundtrip(path: path, body: body, cmd: cmd, compressionType: compressionType, genUinToken: genUinToken)
            } catch {
                isDead = true
                throw error
            }
        }

        private func performRoundtrip(path: String, body: Data, cmd: UInt64, compressionType: String, genUinToken: String) async throws -> InnerReply {
            let isDH = (cmd == WeTypeASREngine.cmdDH)
            let isGenUin = (cmd == WeTypeASREngine.cmdGenUin)
            if !(isDH || isGenUin) {
                taskCounter += 1
            }
            let taskID = (isDH || isGenUin) ? cmd : taskCounter
            let trace = VoiceCrypto.randomLowerLetters(count: 16)
            let bodyMD5 = VoiceCrypto.md5Hex(body, uppercase: true)
            let ts = String(VoiceCrypto.nowMilliseconds())

            let signParts: [String]
            if isDH {
                signParts = [WeTypeASREngine.osType, WeTypeASREngine.version, WeTypeASREngine.platform, ts, bodyMD5, trace, String(cmd)]
            } else if isGenUin {
                signParts = [WeTypeASREngine.osType, WeTypeASREngine.version, WeTypeASREngine.platform, ts, bodyMD5, genUinToken, trace, String(cmd)]
            } else {
                signParts = [WeTypeASREngine.osType, WeTypeASREngine.version, WeTypeASREngine.platform, String(cmd), "0", ts, bodyMD5, uin, trace, String(taskID)]
            }
            let signInput = signParts.joined() + WeTypeASREngine.signKey
            let sign = VoiceCrypto.sha256Hex(Data(signInput.utf8), uppercase: true)

            var headers: [(String, String)] = []
            if !genUinToken.isEmpty {
                headers.append(("Kb-GenUinToken", genUinToken))
            }
            headers.append(("Kb-Uin", uin))
            if isDH || isGenUin {
                headers.append(("Kb-DeviceCodeRestrictionV2", "1"))
            }
            if !isDH {
                if let key = sessionKey, key.count >= 4 {
                    let suffix = String(decoding: key.suffix(4), as: UTF8.self)
                    headers.append(("Kb-SharedKeySuffix", suffix))
                }
                headers.append(("Kb-CmdId", String(cmd)))
                headers.append(("Kb-SubCmdId", "0"))
            }
            headers.append(contentsOf: [
                ("Kb-OsType", WeTypeASREngine.osType),
                ("Kb-Version", WeTypeASREngine.version),
                ("Kb-SystemVersion", WeTypeASREngine.systemVersion),
                ("Kb-PackageType", "3"),
                ("Use_DebugNet", "0"),
                ("Kb-TimeStamp", ts),
                ("Kb-BodyMd5", bodyMD5),
                ("Kb-TraceId", trace),
                ("Kb-TaskId", String(taskID)),
                ("Kb-Scene", "2"),
                ("Kb-Sign", sign),
                ("Content-Length", String(body.count)),
                ("Kb-CompressionType", compressionType),
                ("Content-Type", "application/octet-stream"),
                ("HOST", WeTypeASREngine.host)
            ])

            var httpMsg = ProtoWriter()
            httpMsg.writeString(field: 1, value: "POST")
            httpMsg.writeString(field: 3, value: path)
            httpMsg.writeString(field: 4, value: "")
            for (k, v) in headers {
                httpMsg.writeKeyValue(field: 5, key: k, value: v)
            }
            httpMsg.writeBytes(field: 6, value: body)

            var frame = ProtoWriter()
            frame.writeVarint(field: 1, value: 0)
            frame.writeVarint(field: 2, value: 0)
            frame.writeVarint(field: 3, value: taskID)
            frame.writeMessage(field: 5, value: httpMsg)

            try await ws.sendBinary(frame.data)
            let rawResp = try await ws.receiveData(timeout: 15)
            let outerResp = try ProtoMessage.decode(rawResp)
            guard let httpRespBytes = outerResp.bytes(for: 4) else {
                return InnerReply(status: 0, headers: [:], body: Data())
            }
            let httpResp = try ProtoMessage.decode(httpRespBytes)

            var respHeaders: [String: String] = [:]
            for entry in httpResp.entries where entry.field != 5 {
                guard case .bytes(let kvData) = entry.value,
                      let kv = try? ProtoMessage.decode(kvData),
                      kv.entries.count >= 2,
                      case .bytes(let kBytes) = kv.entries[0].value,
                      case .bytes(let vBytes) = kv.entries[1].value else {
                    continue
                }
                let k = String(decoding: kBytes, as: UTF8.self)
                let v = String(decoding: vBytes, as: UTF8.self)
                respHeaders[k] = v
            }

            return InnerReply(
                status: httpResp.varint(for: 2) ?? 0,
                headers: respHeaders,
                body: httpResp.bytes(for: 5) ?? Data()
            )
        }

        private func loadIdentity() -> Identity? {
            guard let data = try? Data(contentsOf: Self.identityFileURL),
                  let id = try? JSONDecoder().decode(Identity.self, from: data),
                  !id.device.isEmpty, !id.uin.isEmpty, id.uin != "0" else {
                return nil
            }
            return id
        }

        private func saveIdentity(_ id: Identity) {
            guard let data = try? JSONEncoder().encode(id) else { return }
            try? data.write(to: Self.identityFileURL, options: .atomic)
        }
    }

    private actor ConnectionPool {
        private var idle: Connection?

        func take() async throws -> (conn: Connection, reused: Bool) {
            if let existing = idle, !existing.isDead, !existing.ws.isClosed {
                idle = nil
                return (existing, true)
            }
            idle?.close()
            idle = nil
            let fresh = try await Connection.open()
            return (fresh, false)
        }

        func put(_ conn: Connection) {
            if conn.isDead || conn.ws.isClosed {
                conn.close()
                return
            }
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

    private static func runSession(
        pool: ConnectionPool,
        audioStream: AsyncStream<[Int16]>,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var (conn, reused) = try await pool.take()
        var returnToPool = false
        defer {
            if !returnToPool {
                conn.close()
            }
        }

        let voiceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let encoder = try OpusEncoder(sampleRate: 16000, channels: 1, application: .audio, bitrate: 64000, complexity: 9)
        let paced = VoiceAudioPacer.pacedStream(from: audioStream, leadingSilenceFrames: 0, frameSamples: 320, intervalMs: 20)

        var seq: UInt64 = 0
        var totalBytes = 0
        var latestPartial = ""
        var polishedFinal = ""

        func sendPacket(payload: Data?, packetSeq: UInt64, isEnd: Bool) async throws {
            let result: (partial: String, polished: String)
            do {
                result = try await conn.sendVoice(voiceID: voiceID, opusPayload: payload, seq: packetSeq, totalBytes: totalBytes, isEnd: isEnd)
            } catch {
                guard reused else { throw error }
                conn.close()
                conn = try await Connection.open()
                result = try await conn.sendVoice(voiceID: voiceID, opusPayload: payload, seq: packetSeq, totalBytes: totalBytes, isEnd: isEnd)
            }
            reused = false
            if !result.partial.isEmpty {
                latestPartial = result.partial
                onPartial(result.partial)
            }
            if !result.polished.isEmpty {
                polishedFinal = result.polished
            }
        }

        func uploadBatch(_ packets: [Data], isEnd: Bool) async throws {
            seq += 1
            var framed = Data()
            if seq == 1 {
                framed.append(Data("#!OPUS_RAW_V1".utf8))
                framed.append(contentsOf: [0x02, 0x01, 0x00])
            }
            for pkt in packets {
                let len = UInt16(pkt.count)
                framed.append(UInt8(len & 0xFF))
                framed.append(UInt8((len >> 8) & 0xFF))
                framed.append(pkt)
            }
            totalBytes += framed.count
            try await sendPacket(payload: framed, packetSeq: seq, isEnd: isEnd)
        }

        var batch: [Data] = []
        batch.reserveCapacity(framesPerBatch)

        for await frame in paced {
            try Task.checkCancellation()
            let opusPacket = try encoder.encode(pcm16: frame)
            batch.append(opusPacket)
            if batch.count >= framesPerBatch {
                try await uploadBatch(batch, isEnd: false)
                batch.removeAll(keepingCapacity: true)
            }
        }

        try await uploadBatch(batch, isEnd: true)

        // Poll up to 8 times (every 250ms) for server-side polished final text
        for _ in 0..<8 {
            if !polishedFinal.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            try await sendPacket(payload: nil, packetSeq: 0, isEnd: true)
        }

        returnToPool = true
        await pool.put(conn)

        return polishedFinal.isEmpty ? latestPartial : polishedFinal
    }
}
