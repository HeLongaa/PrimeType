import Foundation
import os

// MARK: - Pure Swift ASR Abstractions

enum VoiceASREvent: Sendable, Equatable {
    case partial(String)
    case final(String)
    case error(String)
}

protocol VoiceASRSession: AnyObject {
    func push(pcm16: [Int16])
    func finish()
    func cancel()
}

protocol VoiceASREngine: AnyObject {
    var channel: VoiceCloudChannel { get }
    func start(sampleRate: UInt32, onEvent: @escaping (VoiceASREvent) -> Void) -> (any VoiceASRSession)?
    func prewarm()
}

extension VoiceASREngine {
    func prewarm() {}
}

// MARK: - Local Voice Storage & Account Cookie Store

final class VoiceDataStore {
    static let shared = VoiceDataStore()

    let dataDirectoryURL: URL
    private let accountsFileURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [String: String]())

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/InputType/voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dataDirectoryURL = dir
        self.accountsFileURL = dir.appendingPathComponent("accounts.json")
        loadFromDisk()
    }

    func fileURL(named filename: String) -> URL {
        dataDirectoryURL.appendingPathComponent(filename)
    }

    func cookie(for channel: VoiceCloudChannel) -> String? {
        lock.withLock { $0[channel.rawValue] }
    }

    func hasCookie(for channel: VoiceCloudChannel) -> Bool {
        guard channel.requiresAccountCookie else { return true }
        guard let stored = cookie(for: channel), !stored.isEmpty else { return false }
        return Self.isValidCookie(stored, for: channel)
    }

    @discardableResult
    func setCookie(_ rawCookie: String, for channel: VoiceCloudChannel) -> Bool {
        guard channel.requiresAccountCookie else { return false }
        let trimmed = rawCookie.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            let snapshot = lock.withLock { store -> [String: String] in
                store.removeValue(forKey: channel.rawValue)
                return store
            }
            saveToDisk(snapshot)
            return true
        }

        guard Self.isValidCookie(trimmed, for: channel) else {
            return false
        }

        let snapshot = lock.withLock { store -> [String: String] in
            store[channel.rawValue] = trimmed
            return store
        }
        saveToDisk(snapshot)
        return true
    }

    private static func isValidCookie(_ cookie: String, for channel: VoiceCloudChannel) -> Bool {
        let parsed = parseCookieHeader(cookie)
        switch channel {
        case .bageshuo:
            if let pers = parsed["DICT_PERS"], !pers.isEmpty {
                return true
            }
            if let sess = parsed["DICT_SESS"], !sess.isEmpty,
               let login = parsed["DICT_LOGIN"], !login.isEmpty {
                return true
            }
            return false
        default:
            return !cookie.isEmpty
        }
    }

    private static func parseCookieHeader(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: accountsFileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        lock.withLock { $0 = decoded }
    }

    private func saveToDisk(_ snapshot: [String: String]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: accountsFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsFileURL.path)
    }
}

#if !PRIMETYPE_SETTINGS_HELPER
// MARK: - Engine Registry

final class VoiceASREngineRegistry {
    static let shared = VoiceASREngineRegistry()

    private let lock: OSAllocatedUnfairLock<[VoiceCloudChannel: any VoiceASREngine]>

    private init() {
        let engines: [VoiceCloudChannel: any VoiceASREngine] = [
            .doubao: DoubaoASREngine(),
            .wetype: WeTypeASREngine(),
            .chatterfly: ChatterflyASREngine(),
            .qwen: QwenASREngine(),
            .bageshuo: BageshuoASREngine()
        ]
        self.lock = OSAllocatedUnfairLock(initialState: engines)
    }

    func register(_ engine: any VoiceASREngine) {
        lock.withLock { $0[engine.channel] = engine }
    }

    func engine(for channel: VoiceCloudChannel) -> any VoiceASREngine {
        lock.withLock { engines in
            if let existing = engines[channel] {
                return existing
            }
            let fallback = DoubaoASREngine()
            return fallback
        }
    }
}
#endif
