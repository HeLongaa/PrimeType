import Foundation

struct RimeCandidateItem: Equatable {
    let text: String
    let comment: String?
}

struct RimeContextSnapshot: Equatable {
    let preedit: String
    let cursorPos: Int
    let selStart: Int
    let selEnd: Int
    let pageSize: Int
    let pageNo: Int
    let isLastPage: Bool
    let highlightedIndex: Int
    let candidates: [RimeCandidateItem]
}

final class RimeEngine {
    static let shared = RimeEngine()
    static let sharedUserDictName = "prime_shared"

    private let lock = NSLock()
    private var api: UnsafeMutablePointer<RimeApi>?
    private var isStarted = false
    private var didSetupRime = false

    private let baseUserDir: String
    let logDir: String

    private(set) var currentPreset: DictionaryPreset = .rimeIce
    private(set) var sharedDataDir: String
    private(set) var userDataDir: String
    private(set) var generation: UInt64 = 0

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.baseUserDir = "\(home)/Library/InputType"
        self.logDir = "\(home)/Library/Logs/InputType"
        self.sharedDataDir = Self.resolveSharedDataDir(for: .rimeIce, fallback: baseUserDir)
        self.userDataDir = "\(baseUserDir)/profiles/\(DictionaryPreset.rimeIce.profileDirectoryName)"
    }

    func sharedDataDir(for preset: DictionaryPreset) -> String {
        Self.resolveSharedDataDir(for: preset, fallback: baseUserDir)
    }

    func userDataDir(for preset: DictionaryPreset) -> String {
        "\(baseUserDir)/profiles/\(preset.profileDirectoryName)"
    }

    func isPresetAvailable(_ preset: DictionaryPreset) -> Bool {
        let dir = sharedDataDir(for: preset)
        let schemaFile = (dir as NSString).appendingPathComponent("\(preset.schemaID).schema.yaml")
        return FileManager.default.fileExists(atPath: schemaFile)
    }

    private static func resolveSharedDataDir(for preset: DictionaryPreset, fallback: String) -> String {
        let overlayDir = "\(fallback)/dictionaries/\(preset.profileDirectoryName)"
        let overlaySchema = "\(overlayDir)/\(preset.schemaID).schema.yaml"
        if FileManager.default.fileExists(atPath: overlaySchema) {
            return overlayDir
        }
        if let resourcePath = Bundle.main.resourcePath {
            return "\(resourcePath)/\(preset.sharedSubpath)"
        }
        return fallback
    }

    private func migrateLegacyRimeIceIfNeeded(to targetProfileDir: String) {
        let fm = FileManager.default
        let legacyUserDB = "\(baseUserDir)/rime_ice.userdb"
        let targetUserDB = "\(targetProfileDir)/rime_ice.userdb"
        if fm.fileExists(atPath: legacyUserDB) && !fm.fileExists(atPath: targetUserDB) {
            try? fm.copyItem(atPath: legacyUserDB, toPath: targetUserDB)
        }
        let legacyCustom = "\(baseUserDir)/rime_ice.custom.yaml"
        let targetCustom = "\(targetProfileDir)/rime_ice.custom.yaml"
        if fm.fileExists(atPath: legacyCustom) && !fm.fileExists(atPath: targetCustom) {
            try? fm.copyItem(atPath: legacyCustom, toPath: targetCustom)
        }
    }

    private func ensureSharedUserDBLinked(in targetProfileDir: String) {
        let fm = FileManager.default
        let sharedPath = "\(baseUserDir)/\(Self.sharedUserDictName).userdb"

        // First-time migration: preserve existing user typing history from any previous preset
        if !fm.fileExists(atPath: sharedPath) {
            let candidates = [
                "\(baseUserDir)/profiles/rime_ice/rime_ice.userdb",
                "\(baseUserDir)/rime_ice.userdb",
                "\(baseUserDir)/profiles/wanxiang/wanxiang.userdb",
                "\(baseUserDir)/profiles/oh_my_rime/rime_mint.userdb"
            ]
            if let existing = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                try? fm.copyItem(atPath: existing, toPath: sharedPath)
            } else {
                try? fm.createDirectory(atPath: sharedPath, withIntermediateDirectories: true)
            }
        }

        let linkPath = "\(targetProfileDir)/\(Self.sharedUserDictName).userdb"
        if let attrs = try? fm.attributesOfItem(atPath: linkPath) {
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath), dest == sharedPath {
                    return
                }
                try? fm.removeItem(atPath: linkPath)
            } else {
                return
            }
        }
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: sharedPath)
    }

    private func initializeRimeLocked(
        preset: DictionaryPreset,
        forceMaintenance: Bool,
        waitForMaintenance: Bool
    ) {
        let targetShared = sharedDataDir(for: preset)
        let targetUser = userDataDir(for: preset)
        try? FileManager.default.createDirectory(atPath: targetUser, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        if preset == .rimeIce {
            migrateLegacyRimeIceIfNeeded(to: targetUser)
        }
        ensureSharedUserDBLinked(in: targetUser)

        let prismPath = "\(targetUser)/build/\(preset.schemaID).prism.bin"
        let tablePath = "\(targetUser)/build/\(preset.schemaID).table.bin"
        let needsFullBuild = forceMaintenance
            || !FileManager.default.fileExists(atPath: prismPath)
            || !FileManager.default.fileExists(atPath: tablePath)

        self.currentPreset = preset
        self.sharedDataDir = targetShared
        self.userDataDir = targetUser

        guard let rimeApi = self.api ?? rime_get_api() else {
            NSLog("InputType: failed to obtain RimeApi")
            return
        }
        self.api = rimeApi

        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)

        targetShared.withCString { sharedCStr in
            targetUser.withCString { userCStr in
                logDir.withCString { logCStr in
                    "InputType".withCString { distName in
                        "InputType".withCString { distCode in
                            "0.1.0".withCString { distVer in
                                "rime.inputtype".withCString { appName in
                                    traits.shared_data_dir = sharedCStr
                                    traits.user_data_dir = userCStr
                                    traits.log_dir = logCStr
                                    traits.distribution_name = distName
                                    traits.distribution_code_name = distCode
                                    traits.distribution_version = distVer
                                    traits.app_name = appName

                                    if !didSetupRime {
                                        rimeApi.pointee.setup(&traits)
                                        didSetupRime = true
                                    }
                                    rimeApi.pointee.initialize(&traits)
                                    let started = rimeApi.pointee.start_maintenance(needsFullBuild ? 1 : 0) != 0
                                    if started && waitForMaintenance {
                                        rimeApi.pointee.join_maintenance_thread()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        generation &+= 1
        isStarted = true
    }

    func start(preset: DictionaryPreset = .rimeIce, waitForMaintenance: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        let effectivePreset = isPresetAvailable(preset) ? preset : .rimeIce
        initializeRimeLocked(
            preset: effectivePreset,
            forceMaintenance: false,
            waitForMaintenance: waitForMaintenance
        )
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted, let api else { return }
        api.pointee.finalize()
        generation &+= 1
        isStarted = false
    }

    func deploy(waitForMaintenance: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let api else { return }
        api.pointee.finalize()
        initializeRimeLocked(
            preset: currentPreset,
            forceMaintenance: true,
            waitForMaintenance: waitForMaintenance
        )
    }

    func switchPreset(_ preset: DictionaryPreset, waitForMaintenance: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let targetPreset = isPresetAvailable(preset) ? preset : .rimeIce
        if isStarted, let api {
            api.pointee.finalize()
            isStarted = false
        }
        let buildDir = "\(userDataDir(for: targetPreset))/build"
        let hasExistingBuild = FileManager.default.fileExists(atPath: buildDir)
        initializeRimeLocked(
            preset: targetPreset,
            forceMaintenance: !hasExistingBuild,
            waitForMaintenance: waitForMaintenance
        )
    }

    func createSession() -> RimeSessionId {
        lock.lock()
        defer { lock.unlock() }
        guard let api, isStarted else { return 0 }
        let sid = api.pointee.create_session()
        if sid != 0 {
            let schemaID = currentPreset.schemaID
            schemaID.withCString { cStr in
                _ = api.pointee.select_schema(sid, cStr)
            }
        }
        return sid
    }

    func destroySession(_ sessionId: RimeSessionId) {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return }
        _ = api.pointee.destroy_session(sessionId)
    }

    func processKey(sessionId: RimeSessionId, keyCode: Int32, mask: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return false }
        return api.pointee.process_key(sessionId, keyCode, mask) != 0
    }

    func commitComposition(sessionId: RimeSessionId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return false }
        return api.pointee.commit_composition(sessionId) != 0
    }

    func clearComposition(sessionId: RimeSessionId) {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return }
        api.pointee.clear_composition(sessionId)
    }

    func getRawInput(sessionId: RimeSessionId) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0, let getInput = api.pointee.get_input else { return nil }
        guard let cStr = getInput(sessionId) else { return nil }
        return String(cString: cStr)
    }

    @discardableResult
    func setRawInput(sessionId: RimeSessionId, input: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0, let setInput = api.pointee.set_input else { return false }
        return input.withCString { setInput(sessionId, $0) != 0 }
    }

    func getCommitText(sessionId: RimeSessionId) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return nil }

        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit(sessionId, &commit) != 0 else { return nil }
        defer { _ = api.pointee.free_commit(&commit) }

        guard let textPtr = commit.text else { return nil }
        return String(cString: textPtr)
    }

    func getContext(sessionId: RimeSessionId) -> RimeContextSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return nil }

        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context(sessionId, &context) != 0 else { return nil }
        defer { _ = api.pointee.free_context(&context) }

        let preedit = context.composition.preedit.map { String(cString: $0) } ?? ""
        let numCandidates = Int(context.menu.num_candidates)
        var candidates: [RimeCandidateItem] = []
        candidates.reserveCapacity(numCandidates)

        if let ptr = context.menu.candidates, numCandidates > 0 {
            for i in 0..<numCandidates {
                let c = ptr[i]
                let text = c.text.map { String(cString: $0) } ?? ""
                let comment = c.comment.map { String(cString: $0) }
                candidates.append(RimeCandidateItem(text: text, comment: comment))
            }
        }

        return RimeContextSnapshot(
            preedit: preedit,
            cursorPos: Int(context.composition.cursor_pos),
            selStart: Int(context.composition.sel_start),
            selEnd: Int(context.composition.sel_end),
            pageSize: Int(context.menu.page_size),
            pageNo: Int(context.menu.page_no),
            isLastPage: context.menu.is_last_page != 0,
            highlightedIndex: Int(context.menu.highlighted_candidate_index),
            candidates: candidates
        )
    }

    func selectCandidate(sessionId: RimeSessionId, index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0, index >= 0 else { return false }
        return api.pointee.select_candidate(sessionId, index) != 0
    }

    func getAllCandidates(sessionId: RimeSessionId, limit: Int = 100) -> [RimeCandidateItem] {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0, limit > 0 else { return [] }

        var iterator = RimeCandidateListIterator()
        guard api.pointee.candidate_list_begin(sessionId, &iterator) != 0 else { return [] }
        defer { api.pointee.candidate_list_end(&iterator) }

        var results: [RimeCandidateItem] = []
        results.reserveCapacity(min(limit, 32))
        while results.count < limit && api.pointee.candidate_list_next(&iterator) != 0 {
            let text = iterator.candidate.text.map { String(cString: $0) } ?? ""
            let comment = iterator.candidate.comment.map { String(cString: $0) }
            if !text.isEmpty {
                results.append(RimeCandidateItem(text: text, comment: comment))
            }
        }
        return results
    }

    func getOption(sessionId: RimeSessionId, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return false }
        return name.withCString { api.pointee.get_option(sessionId, $0) != 0 }
    }

    func setOption(sessionId: RimeSessionId, name: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return }
        name.withCString { api.pointee.set_option(sessionId, $0, enabled ? 1 : 0) }
    }

    @discardableResult
    func toggleOption(sessionId: RimeSessionId, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let api, sessionId != 0 else { return false }
        let current = name.withCString { api.pointee.get_option(sessionId, $0) != 0 }
        let next = !current
        name.withCString { api.pointee.set_option(sessionId, $0, next ? 1 : 0) }
        return next
    }

    func isAsciiMode(sessionId: RimeSessionId) -> Bool {
        return getOption(sessionId: sessionId, name: "ascii_mode")
    }

    func setAsciiMode(sessionId: RimeSessionId, enabled: Bool) {
        setOption(sessionId: sessionId, name: "ascii_mode", enabled: enabled)
    }
}
