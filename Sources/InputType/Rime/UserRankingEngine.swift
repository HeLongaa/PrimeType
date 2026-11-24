import Carbon
import Foundation

struct CandidateFeedback: Codable, Equatable {
    var score: Double
    var selectCount: Int
    var deleteCount: Int
    var lastUpdated: TimeInterval
    var isSelfMade: Bool
    var isBlacklisted: Bool
}

/// In-memory personal ranking & negative-feedback engine with time decay and debounced async persistence.
/// Zero keystroke disk I/O; operates strictly on top-N candidate windows while preserving Rime indices.
final class UserRankingEngine {
    static let shared = UserRankingEngine()

    private struct PersistedStore: Codable {
        var version: Int = 1
        var byCodeWord: [String: CandidateFeedback] = [:]
        var byWord: [String: CandidateFeedback] = [:]
    }

    private struct PendingCommitContext {
        let code: String
        let word: String
        let committedAt: TimeInterval
        var deletedChars: Int
        var penaltyApplied: Bool
        var deletedAt: TimeInterval?
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.lumocore.inputmethod.PrimeType.userRankingIO", qos: .utility)
    private let storageURL: URL
    private let persistEnabled: Bool
    private let maxEntries = 20_000

    private var byCodeWord: [String: CandidateFeedback] = [:]
    private var byWord: [String: CandidateFeedback] = [:]
    private var pendingCommit: PendingCommitContext?
    private var saveWorkItem: DispatchWorkItem?

    // Tuning constants aligned with v2 spec
    static let selectTop1Bonus: Double = 1.0
    static let selectOtherBonus: Double = 0.6
    static let skippedCandidatePenalty: Double = -0.25
    static let deleteAfterCommitPenalty: Double = -5.0
    static let reselectExtraPenalty: Double = -3.0 // Total -8.0 with delete penalty
    static let reselectWinnerBonus: Double = 2.0
    static let blacklistScore: Double = -50.0
    static let deleteWindowSeconds: TimeInterval = 3.0
    static let reselectWindowSeconds: TimeInterval = 5.0
    static let regularHalfLifeDays: Double = 30.0
    static let selfMadeHalfLifeDays: Double = 14.0
    static let pruneThreshold: Double = 0.03

    init(storageURL: URL? = nil, persistEnabled: Bool = true) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/InputType", isDirectory: true)
            self.storageURL = dir.appendingPathComponent("user_ranking.json")
        }
        self.persistEnabled = persistEnabled
        if persistEnabled {
            loadFromDisk()
        }
    }

    static func compositeKey(code: String, word: String) -> String {
        "\(code)\u{1F}\(word)"
    }

    static func normalizeCode(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
    }

    private static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Recording Signals

    func recordSelection(
        code rawCode: String,
        word: String,
        rank: Int,
        skippedTopWords: [String] = [],
        isSelfMade: Bool = false,
        isWanxiangPreset: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970,
        bypassSecureCheck: Bool = false
    ) {
        guard bypassSecureCheck || !Self.isSecureInputActive() else { return }
        let code = Self.normalizeCode(rawCode)
        guard !code.isEmpty, !word.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // Check for "delete then immediately reselect a different candidate for the same code"
        var isReselectBoost = false
        if let pending = pendingCommit,
           pending.penaltyApplied,
           let delAt = pending.deletedAt,
           (now - delAt) <= Self.reselectWindowSeconds,
           pending.code == code,
           pending.word != word {
            applyDeltaLocked(
                code: pending.code,
                word: pending.word,
                delta: isWanxiangPreset ? Self.reselectExtraPenalty * 0.7 : Self.reselectExtraPenalty,
                isSelect: false,
                isDelete: true,
                isSelfMade: false,
                now: now
            )
            isReselectBoost = true
        }

        let bonus = isReselectBoost
            ? Self.reselectWinnerBonus
            : (rank == 0 ? Self.selectTop1Bonus : Self.selectOtherBonus)

        applyDeltaLocked(
            code: code,
            word: word,
            delta: bonus,
            isSelect: true,
            isDelete: false,
            isSelfMade: isSelfMade,
            now: now
        )

        // Mild negative signal on top candidates skipped above the chosen rank
        for skipped in skippedTopWords.prefix(3) where skipped != word {
            applyDeltaLocked(
                code: code,
                word: skipped,
                delta: Self.skippedCandidatePenalty,
                isSelect: false,
                isDelete: false,
                isSelfMade: false,
                now: now
            )
        }

        pendingCommit = PendingCommitContext(
            code: code,
            word: word,
            committedAt: now,
            deletedChars: 0,
            penaltyApplied: false,
            deletedAt: nil
        )
        schedulePersistLocked()
    }

    /// Call on non-composing Backspace. If the user deletes >= 50% of the just-committed word
    /// within 3 seconds, record strong negative feedback (-5.0).
    @discardableResult
    func recordBackspaceAfterCommit(
        isWanxiangPreset: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970,
        bypassSecureCheck: Bool = false
    ) -> Bool {
        guard bypassSecureCheck || !Self.isSecureInputActive() else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard var pending = pendingCommit else { return false }
        if (now - pending.committedAt) > Self.deleteWindowSeconds {
            pendingCommit = nil
            return false
        }

        pending.deletedChars += 1
        let requiredDeletes = max(1, (pending.word.count + 1) / 2)
        var appliedNow = false
        if !pending.penaltyApplied && pending.deletedChars >= requiredDeletes {
            let penalty = isWanxiangPreset ? Self.deleteAfterCommitPenalty * 0.8 : Self.deleteAfterCommitPenalty
            applyDeltaLocked(
                code: pending.code,
                word: pending.word,
                delta: penalty,
                isSelect: false,
                isDelete: true,
                isSelfMade: false,
                now: now
            )
            pending.penaltyApplied = true
            pending.deletedAt = now
            appliedNow = true
            schedulePersistLocked()
        }
        pendingCommit = pending
        return appliedNow
    }

    func noteNonDeleteActivity() {
        lock.lock()
        if let pending = pendingCommit, !pending.penaltyApplied {
            pendingCommit = nil
        }
        lock.unlock()
    }

    /// Permanently demote / blacklist a mis-learned candidate (`Shift+Delete`).
    func blacklist(
        code rawCode: String,
        word: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let code = Self.normalizeCode(rawCode)
        guard !code.isEmpty, !word.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        let key = Self.compositeKey(code: code, word: word)
        byCodeWord[key] = CandidateFeedback(
            score: Self.blacklistScore,
            selectCount: 0,
            deleteCount: (byCodeWord[key]?.deleteCount ?? 0) + 1,
            lastUpdated: now,
            isSelfMade: false,
            isBlacklisted: true
        )
        schedulePersistLocked()
    }

    func resetAll() {
        lock.lock()
        byCodeWord.removeAll()
        byWord.removeAll()
        pendingCommit = nil
        lock.unlock()

        if persistEnabled {
            ioQueue.async { [storageURL] in
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return byCodeWord.count
    }

    // MARK: - Scoring & Safe Top-N Reranking

    func effectiveScore(
        code rawCode: String,
        word: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> (score: Double, isBlacklisted: Bool) {
        let code = Self.normalizeCode(rawCode)
        let key = Self.compositeKey(code: code, word: word)

        lock.lock()
        let pairStat = byCodeWord[key]
        let wordStat = byWord[word]
        lock.unlock()

        if pairStat?.isBlacklisted == true {
            return (Self.blacklistScore, true)
        }
        let pairScore = pairStat.map { Self.decayedScore(for: $0, now: now) } ?? 0.0
        let globalScore = wordStat.map { Self.decayedScore(for: $0, now: now) * 0.25 } ?? 0.0
        return (pairScore + globalScore, false)
    }

    static func decayedScore(for stat: CandidateFeedback, now: TimeInterval) -> Double {
        if stat.isBlacklisted { return blacklistScore }
        let days = max(0.0, (now - stat.lastUpdated) / 86400.0)
        let halfLife = (stat.isSelfMade || stat.selectCount < 3) ? selfMadeHalfLifeDays : regularHalfLifeDays
        let value = stat.score * pow(0.5, days / halfLife)
        return abs(value) < pruneThreshold ? 0.0 : value
    }

    /// Reorders ONLY whole-sentence / same-granularity Rime candidates inside the Top-10 window,
    /// keeping direct-commit custom phrases anchored at the top and preserving every `originalRimeIndex`.
    func rerank(
        candidates: [PresentedCandidate],
        code rawCode: String,
        emitBoostForWord: ((String) -> Double)? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [PresentedCandidate] {
        guard candidates.count > 1 else { return candidates }
        let code = Self.normalizeCode(rawCode)
        guard !code.isEmpty else { return candidates }

        var prefixDirect: [PresentedCandidate] = []
        var rimeCandidates: [PresentedCandidate] = []
        for cand in candidates {
            if cand.isDirectCommit {
                prefixDirect.append(cand)
            } else {
                rimeCandidates.append(cand)
            }
        }
        guard rimeCandidates.count > 1 else { return candidates }

        let windowCount = min(10, rimeCandidates.count)
        let window = Array(rimeCandidates.prefix(windowCount))
        let tail = Array(rimeCandidates.dropFirst(windowCount))

        // Only rerank the contiguous whole-sentence prefix inside the Top-10 window so single characters
        // never jump ahead of multi-syllable full sentences.
        var rerankable: [PresentedCandidate] = []
        var nonWholeInWindow: [PresentedCandidate] = []
        for cand in window {
            if cand.isWholeSentence {
                rerankable.append(cand)
            } else {
                nonWholeInWindow.append(cand)
            }
        }

        guard rerankable.count > 1 else { return candidates }

        var hasAnySignal = false
        var scored: [(cand: PresentedCandidate, score: Double, originalPos: Int, blacklisted: Bool)] = []
        scored.reserveCapacity(rerankable.count)

        for (pos, cand) in rerankable.enumerated() {
            let (userScore, blacklisted) = effectiveScore(code: code, word: cand.text, now: now)
            let contextBoost = emitBoostForWord?(cand.text) ?? 0.0
            if userScore != 0 || contextBoost != 0 || blacklisted {
                hasAnySignal = true
            }
            // Rank prior decreases smoothly (~3.0 -> 0.5) so mild positive signals gently promote,
            // while strong negative feedback (-5.0 / -8.0 / -50.0) reliably sinks mis-selected words below Top-3.
            let rankPrior = 6.0 / Double(2 + pos)
            let clampedUser = max(-60.0, min(8.0, userScore * 0.55))
            let total = rankPrior + clampedUser + contextBoost
            scored.append((cand, total, pos, blacklisted))
        }

        guard hasAnySignal else { return candidates }

        let visible = scored.filter { !$0.blacklisted }
            .sorted { a, b in
                if abs(a.score - b.score) > 1e-6 {
                    return a.score > b.score
                }
                return a.originalPos < b.originalPos
            }
            .map(\.cand)

        // Keep blacklisted items only if everything else would disappear (safety fallback)
        let finalRerankable = visible.isEmpty ? rerankable : visible
        return prefixDirect + finalRerankable + nonWholeInWindow + tail
    }

    // MARK: - Internal Helpers & Persistence

    private func applyDeltaLocked(
        code: String,
        word: String,
        delta: Double,
        isSelect: Bool,
        isDelete: Bool,
        isSelfMade: Bool,
        now: TimeInterval
    ) {
        let key = Self.compositeKey(code: code, word: word)
        var pair = byCodeWord[key] ?? CandidateFeedback(
            score: 0,
            selectCount: 0,
            deleteCount: 0,
            lastUpdated: now,
            isSelfMade: isSelfMade,
            isBlacklisted: false
        )
        let decayed = Self.decayedScore(for: pair, now: now)
        pair.score = decayed + delta
        if isSelect {
            pair.selectCount += 1
            pair.isBlacklisted = false
        }
        if isDelete {
            pair.deleteCount += 1
        }
        pair.lastUpdated = now
        if isSelfMade { pair.isSelfMade = true }
        byCodeWord[key] = pair

        var global = byWord[word] ?? CandidateFeedback(
            score: 0,
            selectCount: 0,
            deleteCount: 0,
            lastUpdated: now,
            isSelfMade: isSelfMade,
            isBlacklisted: false
        )
        global.score = Self.decayedScore(for: global, now: now) + delta * 0.4
        if isSelect { global.selectCount += 1 }
        if isDelete { global.deleteCount += 1 }
        global.lastUpdated = now
        byWord[word] = global

        if byCodeWord.count > maxEntries {
            pruneOldestLocked(now: now)
        }
    }

    private func pruneOldestLocked(now: TimeInterval) {
        byCodeWord = byCodeWord.filter { _, stat in
            stat.isBlacklisted || abs(Self.decayedScore(for: stat, now: now)) >= Self.pruneThreshold
        }
        if byCodeWord.count > maxEntries {
            let sorted = byCodeWord.sorted { $0.value.lastUpdated > $1.value.lastUpdated }
            byCodeWord = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries * 8 / 10).map { ($0.key, $0.value) })
        }
        if byWord.count > maxEntries / 2 {
            let sorted = byWord.sorted { $0.value.lastUpdated > $1.value.lastUpdated }
            byWord = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries * 4 / 10).map { ($0.key, $0.value) })
        }
    }

    private func schedulePersistLocked() {
        guard persistEnabled else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushToDisk()
        }
        saveWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    func flushToDisk() {
        guard persistEnabled else { return }
        lock.lock()
        let payload = PersistedStore(version: 1, byCodeWord: byCodeWord, byWord: byWord)
        lock.unlock()

        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(PersistedStore.self, from: data) else {
            return
        }
        lock.lock()
        byCodeWord = decoded.byCodeWord
        byWord = decoded.byWord
        lock.unlock()
    }
}
