import Carbon
import Foundation

/// Pure in-memory cross-message context buffer partitioned by host app `bundleID`.
/// Keeps the last 5 committed messages / up to 80 characters (10-minute TTL) for:
/// 1) Tier-1 zero-latency proper-noun / term re-occurrence boost (+0.8)
/// 2) Tier-2 local neural reranker semantic prefix `C`
final class EmitHistory {
    static let shared = EmitHistory()

    private struct Entry {
        let text: String
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private let maxMessagesPerApp = 5
    private let maxContextChars = 80
    private let ttlSeconds: TimeInterval = 600 // 10 minutes
    private let maxTrackedApps = 20

    private var buckets: [String: [Entry]] = [:]

    func recordCommit(
        _ text: String,
        bundleID: String?,
        now: TimeInterval = Date().timeIntervalSince1970,
        bypassSecureCheck: Bool = false
    ) {
        guard bypassSecureCheck || !IsSecureEventInputEnabled() else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let key = bundleID ?? "_default"
        lock.lock()
        defer { lock.unlock() }

        var list = buckets[key] ?? []
        list.removeAll { (now - $0.timestamp) > ttlSeconds }
        if let last = list.last, (now - last.timestamp) < 12.0, last.text.count + cleaned.count <= maxContextChars {
            // Merge adjacent commits from the same utterance/sentence into one context turn
            list[list.count - 1] = Entry(text: last.text + cleaned, timestamp: now)
        } else {
            list.append(Entry(text: String(cleaned.suffix(maxContextChars)), timestamp: now))
        }
        if list.count > maxMessagesPerApp {
            list.removeFirst(list.count - maxMessagesPerApp)
        }
        buckets[key] = list

        if buckets.count > maxTrackedApps {
            let oldestKey = buckets.min {
                ($0.value.last?.timestamp ?? 0) < ($1.value.last?.timestamp ?? 0)
            }?.key
            if let oldestKey {
                buckets.removeValue(forKey: oldestKey)
            }
        }
    }

    /// Returns concatenated recent context `C` for the given app (max `maxChars` characters).
    func recentContext(
        forBundleID bundleID: String?,
        maxChars: Int = 80,
        now: TimeInterval = Date().timeIntervalSince1970,
        bypassSecureCheck: Bool = false
    ) -> String {
        guard bypassSecureCheck || !IsSecureEventInputEnabled() else { return "" }
        let key = bundleID ?? "_default"

        lock.lock()
        let entries = (buckets[key] ?? []).filter { (now - $0.timestamp) <= ttlSeconds }
        lock.unlock()

        var out = ""
        for entry in entries.reversed() {
            let sep = out.isEmpty ? "" : " "
            if out.count + entry.text.count + sep.count > maxChars {
                let remaining = max(0, maxChars - out.count - sep.count)
                if remaining > 0 {
                    out = String(entry.text.suffix(remaining)) + sep + out
                }
                break
            }
            out = entry.text + sep + out
        }
        return out
    }

    /// Tier-1 zero-latency re-occurrence boost for 2–6 character terms (proper nouns, project names)
    /// that appeared verbatim in recent messages within the same app.
    func entityMatchBoost(
        for candidateText: String,
        bundleID: String?,
        now: TimeInterval = Date().timeIntervalSince1970,
        bypassSecureCheck: Bool = false
    ) -> Double {
        let count = candidateText.count
        guard count >= 2 && count <= 6 else { return 0.0 }
        let ctx = recentContext(forBundleID: bundleID, maxChars: maxContextChars, now: now, bypassSecureCheck: bypassSecureCheck)
        guard !ctx.isEmpty else { return 0.0 }
        return ctx.contains(candidateText) ? 0.35 : 0.0
    }

    func clearAll() {
        lock.lock()
        buckets.removeAll()
        lock.unlock()
    }
}
