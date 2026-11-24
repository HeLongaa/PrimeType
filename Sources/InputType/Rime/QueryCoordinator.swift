import Foundation

/// Cancellable single-flight async query coordinator for Tier-2 neural reranking.
/// Guarantees at most 1 in-flight async task at any instant; new keystrokes immediately invalidate
/// older queries via monotonic generation token and cancel pending tasks.
final class QueryCoordinator {
    private let lock = NSLock()
    private var token: UInt64 = 0
    private var inFlight: Task<Void, Never>?

    let debounceNanoseconds: UInt64
    let timeoutSeconds: TimeInterval

    init(debounceMs: UInt64 = 45, timeoutMs: UInt64 = 200) {
        self.debounceNanoseconds = debounceMs * 1_000_000
        self.timeoutSeconds = Double(timeoutMs) / 1000.0
    }

    var currentToken: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func cancelAll() {
        lock.lock()
        token &+= 1
        let task = inFlight
        inFlight = nil
        lock.unlock()
        task?.cancel()
    }

    func schedule<Result: Sendable>(
        work: @escaping @Sendable () async -> Result?,
        onResult: @escaping @MainActor (Result, Double) -> Void
    ) {
        lock.lock()
        token &+= 1
        let myToken = token
        let previous = inFlight
        let startedAt = CFAbsoluteTimeGetCurrent()
        let debounceNs = debounceNanoseconds
        let timeoutSec = timeoutSeconds

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
            }
            guard let self, !Task.isCancelled, self.isCurrent(myToken) else {
                LatencyProbe.shared.recordAsyncDropped()
                return
            }

            let result = await work()
            let elapsedSec = CFAbsoluteTimeGetCurrent() - startedAt

            guard !Task.isCancelled,
                  self.isCurrent(myToken),
                  elapsedSec <= timeoutSec,
                  let result else {
                LatencyProbe.shared.recordAsyncDropped()
                return
            }

            await MainActor.run {
                guard self.isCurrent(myToken) else {
                    LatencyProbe.shared.recordAsyncDropped()
                    return
                }
                onResult(result, elapsedSec * 1000.0)
            }
        }
        inFlight = task
        lock.unlock()

        previous?.cancel()
    }

    private func isCurrent(_ myToken: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == myToken
    }
}

/// Manages candidate presentation with first-candidate stability protection (150ms lock window,
/// +0.15 confidence lead threshold, max 1 async Top-1 flip per preedit session).
final class CandidatePresenter {
    private(set) var currentPreedit: String = ""
    private(set) var currentCandidates: [PresentedCandidate] = []
    private(set) var lastKeystrokeAt: CFAbsoluteTime = 0
    private(set) var asyncTop1FlipCount: Int = 0

    let lockFirstWindowSeconds: CFAbsoluteTime
    let top1LeadThreshold: Double

    init(lockFirstWindowSeconds: CFAbsoluteTime = 0.15, top1LeadThreshold: Double = 0.15) {
        self.lockFirstWindowSeconds = lockFirstWindowSeconds
        self.top1LeadThreshold = top1LeadThreshold
    }

    func noteKeystroke(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lastKeystrokeAt = now
    }

    func reset() {
        currentPreedit = ""
        currentCandidates = []
        asyncTop1FlipCount = 0
    }

    /// Synchronous Tier-0/Tier-1 update. Always applies immediately.
    func presentSync(
        preedit: String,
        candidates: [PresentedCandidate],
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        if preedit != currentPreedit {
            asyncTop1FlipCount = 0
        }
        currentPreedit = preedit
        currentCandidates = candidates
        lastKeystrokeAt = now
    }

    /// Asynchronous Tier-2 update with strict first-candidate protection:
    /// - Drops if `preedit` no longer matches.
    /// - If elapsed > 150ms OR Top-1 already flipped once OR `leadMargin < 0.15`, NEVER touches index 0;
    ///   instead inserts the top reranked winner at index 1 (deduping its old slot).
    /// - Returns `(didChange, flippedTop1)`.
    @discardableResult
    func presentAsync(
        preedit: String,
        reranked: [PresentedCandidate],
        leadMargin: Double,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> (didChange: Bool, flippedTop1: Bool) {
        guard preedit == currentPreedit, !preedit.isEmpty, !reranked.isEmpty, !currentCandidates.isEmpty else {
            return (false, false)
        }

        let newTop = reranked[0]
        let oldTop = currentCandidates[0]

        // Already identical top-1 and order -> check if any lower rank changed
        if newTop.text == oldTop.text {
            if reranked != currentCandidates {
                currentCandidates = reranked
                return (true, false)
            }
            return (false, false)
        }

        let elapsed = now - lastKeystrokeAt
        let canSwapTop1 = (elapsed <= lockFirstWindowSeconds)
            && (asyncTop1FlipCount < 1)
            && (leadMargin >= top1LeadThreshold)

        if canSwapTop1 {
            currentCandidates = reranked
            asyncTop1FlipCount += 1
            return (true, true)
        } else {
            // First-candidate protection: NEVER replace index 0; promote winner to index 1
            var merged = currentCandidates.filter { $0.text != newTop.text }
            let insertIdx = min(1, merged.count)
            merged.insert(newTop, at: insertIdx)
            if merged != currentCandidates {
                currentCandidates = merged
                return (true, false)
            }
            return (false, false)
        }
    }
}
