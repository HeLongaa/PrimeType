import Foundation
import os

final class ChatterflyASREngine: VoiceASREngine {
    let channel: VoiceCloudChannel = .chatterfly

    private static let endpointURL = "wss://srss.speech.sogou.com/srss/v1/speech/streaming_recognize"
    private static let productID = "com.tencent.inputmethod.chatterfly"
    private static let productVersion = "1.0.9.13509"

    static let serverPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA042we0tp1Qf9oJ5HPTtD
    bevvl883q/e3FXXwnQbE7b4p6OqtVjQxprCusNKCiPPctzWUzOmLCnozWp/7j3sR
    OdTDPK7ZtElf6fLL+l2bbdHijfSr0Z98yLwQOumOOPWtcxT34Ssrq5G3Sqaw8/RC
    9ZluoONqouzEl2ausPo21W+yctmIzQ8otMKOkTunNSg+f5bM7phhsYoNy4nkCiIS
    uXjlVpEnvb9V0t4ih2sAAvqCmGim4PQODJqDDz68Iz0a32kMUIR1ydMqjoHokRdO
    k/VXgjE7OmJsVVe7Fn4ezdg7hYfnKVCPJxvzh0cgdbCMUUSXOP8foKnJEEoGIQcV
    +lYgKqNUSJJRrfzG33i58aRwJ29UOVHuhGJ/SqFXqNmTvYQR5/Y8kvMCoTdxQG6c
    5bWy9jTesrc/OliezEMS9GlepeiNdlHh3couDyn2zyYwE6aBpqp7k3uVQr/7PiAJ
    6ZDBQkzVX2PGyqFeAoPFE4xg6LLTYH4EydbpZXIDg4zzAgMBAAE=
    -----END PUBLIC KEY-----
    """

    func start(sampleRate: UInt32, onEvent: @escaping (VoiceASREvent) -> Void) -> (any VoiceASRSession)? {
        StreamingVoiceASRSession(onEvent: onEvent) { audioStream, onPartial in
            try await Self.runSession(audioStream: audioStream, onPartial: onPartial)
        }
    }

    // MARK: - Envelope Sealing

    struct SealedEnvelope {
        let encryptedBodyBase64: String
        let encryptedKeyBase64: String
        let ivBase64: String
    }

    static func sealConfigPayload(_ plaintext: Data) throws -> SealedEnvelope {
        let aesKey = VoiceCrypto.randomBytes(count: 32)
        let aesIV = VoiceCrypto.randomBytes(count: 16)
        let cipherBody = try VoiceCrypto.aesCBCEncrypt(key: aesKey, iv: aesIV, plaintext: plaintext)
        let wrappedKey = try VoiceCrypto.rsaOAEPSHA256Encrypt(spkiPEM: serverPublicKeyPEM, plaintext: aesKey)
        return SealedEnvelope(
            encryptedBodyBase64: cipherBody.base64EncodedString(),
            encryptedKeyBase64: wrappedKey.base64EncodedString(),
            ivBase64: aesIV.base64EncodedString()
        )
    }

    private static func buildConfigJSON(token: String) throws -> Data {
        let language = ProcessInfo.processInfo.environment["CHATTERFLY_LANG"] ?? "zh-cmn-Hans-CN"
        let deviceInfo: [String: Any] = [
            "device_category": "mac",
            "device_uuid": VoiceCrypto.randomHex(byteCount: 16),
            "device_aid": VoiceCrypto.randomHex(byteCount: 16),
            "device_qid": VoiceCrypto.randomHex(byteCount: 16)
        ]
        let osInfo: [String: Any] = [
            "os_category": "mac",
            "os_id": "mac",
            "os_version": "14.0"
        ]

        var configDict: [String: Any] = [
            "encoding": "LINEAR16",
            "language_code": language,
            "model": "default",
            "punctuation_mode": "NORMAL_PUNCTUATION",
            "convert_number": true,
            "metadata": [
                "client_info": [
                    "product_category": "ime",
                    "product_id": productID,
                    "product_version": productVersion
                ],
                "sdk_info": [
                    "sdk_category": "mac",
                    "sdk_id": "nsrss",
                    "sdk_version": "1.0.0"
                ],
                "record_device_info": deviceInfo,
                "record_os_info": osInfo,
                "host_device_info": deviceInfo,
                "host_os_info": osInfo,
                "user_info": [
                    "user_category": "normal",
                    "user_id": "0"
                ],
                "audio_info": [
                    "audio_id": VoiceCrypto.randomHex(byteCount: 16),
                    "audio_slice_id": VoiceCrypto.randomHex(byteCount: 16)
                ],
                "network_info": [
                    "network_type": "wifi",
                    "network_proxy_type": "none"
                ],
                "runtime_info": [
                    "consumer_product_id": productID,
                    "consumer_purpose": "ime",
                    "consumer_input_type": "voice"
                ]
            ]
        ]

        if !token.isEmpty {
            configDict["auth_token"] = token
        }

        let root: [String: Any] = [
            "config": configDict,
            "interim_results": true,
            "single_utterance": false
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - Streaming Session

    private static func runSession(
        audioStream: AsyncStream<[Int16]>,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: endpointURL) else {
            throw VoiceProtocolError.invalidURL("Chatterfly WebSocket 地址无效")
        }

        let token = ProcessInfo.processInfo.environment["CHATTERFLY_TOKEN"] ?? ""
        let configData = try buildConfigJSON(token: token)
        let sealed = try sealConfigPayload(configData)

        var headers: [(String, String)] = [
            ("X-Srss-Cipher-Key-Type", "1"),
            ("X-Srss-Cipher-Key-Sec", sealed.encryptedKeyBase64),
            ("X-Srss-Cipher-Key-Vec", sealed.ivBase64)
        ]
        if !token.isEmpty {
            headers.append(("Authorization", "Bearer \(token)"))
        }

        let ws = try await VoiceWebSocket.connect(url: url, headers: headers, timeout: 10)
        defer { ws.close() }

        try await ws.sendText(sealed.encryptedBodyBase64)

        let sharedState = OSAllocatedUnfairLock(initialState: (text: "", sentSamples: 0))

        let senderTask = Task<Void, Error> {
            for await frame in audioStream {
                try Task.checkCancellation()
                let pcmData = VoiceCrypto.pcm16LittleEndianData(frame)
                sharedState.withLock { $0.sentSamples += frame.count }
                try await ws.sendBinary(pcmData)
            }
            try await ws.sendText("{}")
        }
        defer { senderTask.cancel() }

        var finalError: Error?
        while !Task.isCancelled {
            do {
                let raw = try await ws.receiveData(timeout: 30)
                guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                    continue
                }
                if let errObj = obj["error"] as? [String: Any] {
                    let code = (errObj["code"] as? Int) ?? -1
                    let msg = (errObj["message"] as? String) ?? "识别失败"
                    finalError = VoiceProtocolError.serverError("Chatterfly \(msg) (\(code))")
                    break
                }
                let text = extractTranscript(from: obj)
                let changed = sharedState.withLock { s -> Bool in
                    guard text != s.text else { return false }
                    s.text = text
                    return true
                }
                if changed && !text.isEmpty {
                    onPartial(text)
                }
                if isFinalResponse(obj) {
                    break
                }
            } catch {
                finalError = error
                break
            }
        }

        senderTask.cancel()
        let snapshot = sharedState.withLock { $0 }
        if let finalError {
            if !snapshot.text.isEmpty {
                return snapshot.text
            }
            throw finalError
        }
        if snapshot.text.isEmpty && snapshot.sentSamples == 0 {
            throw VoiceProtocolError.serverError("没有采集到音频")
        }
        return snapshot.text
    }

    private static func extractTranscript(from json: [String: Any]) -> String {
        guard let results = json["results"] as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for item in results {
            if let alts = item["alternatives"] as? [[String: Any]],
               let first = alts.first,
               let t = first["transcript"] as? String {
                pieces.append(t)
            }
        }
        return pieces.joined()
    }

    private static func isFinalResponse(_ json: [String: Any]) -> Bool {
        guard let results = json["results"] as? [[String: Any]] else { return false }
        return results.contains { ($0["is_final"] as? Bool) == true }
    }
}
