import Foundation
import os

enum VoiceEngineTestRunner {
    static func runCLI(arguments: [String]) -> Int32 {
        var allPassed = true

        print("=== [1/2] Running Protocol & Crypto Unit Tests ===")
        if !runUnitTests() {
            allPassed = false
        }

        // Optional live audio test: --voice-test <wav_path> [comma_separated_channels]
        if let flagIdx = arguments.firstIndex(of: "--voice-test"), flagIdx + 1 < arguments.count {
            let wavPath = arguments[flagIdx + 1]
            let channelArg = (flagIdx + 2 < arguments.count) ? arguments[flagIdx + 2] : "doubao,wetype,chatterfly,qwen"
            let channels: [VoiceCloudChannel] = channelArg
                .split(separator: ",")
                .compactMap { VoiceCloudChannel(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }

            print("\n=== [2/2] Running Live Cloud ASR Tests (\(wavPath)) ===")
            do {
                let frames = try loadWAVAs20msFrames(path: wavPath)
                print("Loaded WAV: \(frames.count) frames (\(String(format: "%.2f", Double(frames.count) * 0.02))s @ 16kHz mono Int16)")
                for ch in channels {
                    let ok = runLiveChannelTest(channel: ch, frames: frames)
                    if !ok {
                        allPassed = false
                    }
                }
            } catch {
                print("FAIL: Unable to load WAV \(wavPath): \(error.localizedDescription)")
                allPassed = false
            }
        }

        return allPassed ? 0 : 1
    }

    // MARK: - Unit Tests

    private static func runUnitTests() -> Bool {
        var passed = true
        func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
            if condition() {
                print("  [PASS] \(name)")
            } else {
                print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                passed = false
            }
        }

        // 1. Bageshuo signature & abtest test vector from spec
        let vectorDevice = "3f2a7c1e-9b4d-4e8a-a1c2-5d6e7f809a1b"
        let vectorTime: UInt64 = 1_700_000_000_000
        let abtest = BageshuoASREngine.computeABTest(device: vectorDevice)
        let query = BageshuoASREngine.buildSignedQueryItems(device: vectorDevice, timestampMs: vectorTime)
        let queryMap = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        check("Bageshuo abtest vector", abtest == 6, "got \(abtest)")
        check("Bageshuo sign vector", queryMap["sign"] == "7bb9c7bc03e44cd83603facb55604fba", "got \(queryMap["sign"] ?? "nil")")
        check(
            "Bageshuo pointParam vector",
            queryMap["pointParam"] == "abtest,appVersion,client,imei,keyfrom,keyid,mid,model,mysticTime,network,product,screen,vendor,yduuid"
        )

        // 2. Bageshuo WSS host validation
        check("Bageshuo WSS valid official URL", BageshuoASREngine.validateOfficialYoudaoWSS("wss://dict-typeless.youdao.com/ws?ticket=1") != nil)
        check("Bageshuo WSS rejects ws://", BageshuoASREngine.validateOfficialYoudaoWSS("ws://dict-typeless.youdao.com/ws") == nil)
        check("Bageshuo WSS rejects evil suffix", BageshuoASREngine.validateOfficialYoudaoWSS("wss://youdao.com.evil.com/ws") == nil)
        check("Bageshuo WSS rejects userinfo spoofing", BageshuoASREngine.validateOfficialYoudaoWSS("wss://a.youdao.com@evil.com/ws") == nil)

        // 3. secp128r1 ECDH symmetry
        let alice = Secp128r1ECDH.generateKeyPair()
        let bob = Secp128r1ECDH.generateKeyPair()
        let sharedA = try? Secp128r1ECDH.deriveSharedKeyHex(privateKey: alice.privateKey, peerPublicHex: bob.publicKeyHex)
        let sharedB = try? Secp128r1ECDH.deriveSharedKeyHex(privateKey: bob.privateKey, peerPublicHex: alice.publicKeyHex)
        check("secp128r1 ECDH shared secret symmetry", sharedA != nil && sharedA == sharedB && sharedA?.count == 32)

        // 4. Raw Snappy roundtrip & back-reference copy decode
        let samplePayload = Data(String(repeating: "PrimeType-ASR-Snappy-Test-1234567890!", count: 8).utf8)
        let compressed = RawSnappy.compress(samplePayload)
        let decompressed = try? RawSnappy.decompress(compressed)
        check("RawSnappy literal compress/decompress", decompressed == samplePayload)
        // Hand-crafted Snappy block with copy-1 tag: uncompressed "abcdabcd" (len=8): varint(8), lit(4)="abcd", copy1(len=4, off=4)
        let copyBlock = Data([0x08, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x01, 0x04])
        let decodedCopy = try? RawSnappy.decompress(copyBlock)
        check("RawSnappy copy-1 back-reference decode", decodedCopy == Data("abcdabcd".utf8))

        // 5. AES-256-ECB + PKCS7 roundtrip (including empty block -> 16 bytes)
        let key32 = Data("D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6".utf8)
        let encEmpty = try? VoiceCrypto.aesECBEncrypt(key: key32, plaintext: Data())
        let decEmpty = encEmpty.flatMap { try? VoiceCrypto.aesECBDecrypt(key: key32, ciphertext: $0) }
        check("AES-256-ECB empty PKCS7 block", encEmpty?.count == 16 && decEmpty == Data())

        // 6. Chatterfly RSA-OAEP(SHA-256) + AES-256-CBC envelope sealing
        let sealed = try? ChatterflyASREngine.sealConfigPayload(Data("{\"test\":true}".utf8))
        let wrappedBytes = sealed.flatMap { Data(base64Encoded: $0.encryptedKeyBase64) }
        check("Chatterfly 3072-bit RSA-OAEP-SHA256 seal", wrappedBytes?.count == 384, "got \(wrappedBytes?.count ?? -1) bytes")

        // 7. Protobuf encode/decode roundtrip
        var pb = ProtoWriter()
        pb.writeVarint(field: 1, value: 42)
        pb.writeString(field: 2, value: "hello")
        pb.writeKeyValue(field: 3, key: "k", value: "v")
        let decodedPB = try? ProtoMessage.decode(pb.data)
        let kvSub = decodedPB?.bytes(for: 3).flatMap { try? ProtoMessage.decode($0) }
        check("Protobuf encode/decode", decodedPB?.varint(for: 1) == 42 && decodedPB?.string(for: 2) == "hello" && kvSub?.string(for: 1) == "k" && kvSub?.string(for: 2) == "v")

        // 8. libopus VOIP & AUDIO encoding
        let silence320 = [Int16](repeating: 0, count: 320)
        let opusVoip = try? OpusEncoder(application: .voip, bitrate: 16000, complexity: 5).encode(pcm16: silence320)
        let opusAudio = try? OpusEncoder(application: .audio, bitrate: 64000, complexity: 9).encode(pcm16: silence320)
        check("libopus VOIP & AUDIO 20ms encode", (opusVoip?.count ?? 0) > 0 && (opusAudio?.count ?? 0) > 0)

        // 9. Cancellation safety: no callbacks after cancel()
        let callbackAfterCancel = OSAllocatedUnfairLock(initialState: false)
        let session = StreamingVoiceASRSession(onEvent: { _ in
            callbackAfterCancel.withLock { $0 = true }
        }) { _, onPartial in
            try await Task.sleep(nanoseconds: 50_000_000)
            onPartial("late")
            return "late"
        }
        session.cancel()
        Thread.sleep(forTimeInterval: 0.1)
        check("Session cancel suppresses late callbacks", !callbackAfterCancel.withLock { $0 })

        return passed
    }

    // MARK: - Live Channel WAV Test

    private static func runLiveChannelTest(channel: VoiceCloudChannel, frames: [[Int16]]) -> Bool {
        let engine = VoiceASREngineRegistry.shared.engine(for: channel)
        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()

        let resultBox = OSAllocatedUnfairLock(initialState: (partials: [String](), finalText: Optional<String>.none, error: Optional<String>.none))

        guard let session = engine.start(sampleRate: 16000, onEvent: { event in
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
            switch event {
            case .partial(let text):
                resultBox.withLock { $0.partials.append(text) }
                print("  [\(channel.rawValue) +\(elapsed)] PARTIAL: \(text)")
            case .final(let text):
                resultBox.withLock { $0.finalText = text }
                print("  [\(channel.rawValue) +\(elapsed)] FINAL:   \(text)")
                semaphore.signal()
            case .error(let err):
                resultBox.withLock { $0.error = err }
                print("  [\(channel.rawValue) +\(elapsed)] ERROR:   \(err)")
                semaphore.signal()
            }
        }) else {
            print("  [FAIL] \(channel.rawValue): failed to create session")
            return false
        }

        // Stream frames at realtime 20ms pace (plus 300ms trailing silence)
        let feeder = DispatchQueue.global(qos: .userInitiated)
        feeder.async {
            for frame in frames {
                session.push(pcm16: frame)
                usleep(20_000)
            }
            let trailingSilence = [Int16](repeating: 0, count: 320)
            for _ in 0..<15 {
                session.push(pcm16: trailingSilence)
                usleep(20_000)
            }
            session.finish()
        }

        let waitResult = semaphore.wait(timeout: .now() + 30.0)
        if waitResult == .timedOut {
            session.cancel()
            print("  [FAIL] \(channel.rawValue): timed out after 30s")
            return false
        }

        let snapshot = resultBox.withLock { $0 }
        let totalElapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
        if let finalText = snapshot.finalText, !finalText.isEmpty {
            print("  [PASS] \(channel.rawValue) (\(totalElapsed), partials=\(snapshot.partials.count)): \"\(finalText)\"")
            return true
        } else {
            print("  [FAIL] \(channel.rawValue) (\(totalElapsed)): error=\(snapshot.error ?? "empty result")")
            return false
        }
    }

    // MARK: - Minimal 16kHz Mono 16-bit PCM WAV Reader

    private static func loadWAVAs20msFrames(path: String) throws -> [[Int16]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw VoiceProtocolError.protocolViolation("不是有效的 RIFF WAVE 文件")
        }

        var offset = 12
        var pcmOffset: Int?
        var pcmSize = 0
        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(UInt32(data[offset + 4]) |
                                (UInt32(data[offset + 5]) << 8) |
                                (UInt32(data[offset + 6]) << 16) |
                                (UInt32(data[offset + 7]) << 24))
            let bodyStart = offset + 8
            if chunkID == "data" {
                pcmOffset = bodyStart
                pcmSize = min(chunkSize, data.count - bodyStart)
                break
            }
            offset = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard let start = pcmOffset, pcmSize > 0 else {
            throw VoiceProtocolError.protocolViolation("WAV 文件缺少 data 块")
        }

        let sampleCount = pcmSize / 2
        var samples = [Int16](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let src = base.advanced(by: start).assumingMemoryBound(to: UInt8.self)
            for i in 0..<sampleCount {
                let lo = UInt16(src[i * 2])
                let hi = UInt16(src[i * 2 + 1])
                samples[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }

        let frameSize = 320
        var frames: [[Int16]] = []
        var idx = 0
        while idx < samples.count {
            let end = min(idx + frameSize, samples.count)
            var frame = Array(samples[idx..<end])
            if frame.count < frameSize {
                frame.append(contentsOf: [Int16](repeating: 0, count: frameSize - frame.count))
            }
            frames.append(frame)
            idx += frameSize
        }
        return frames
    }
}
