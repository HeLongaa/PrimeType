import Foundation

struct LatencySnapshot: Equatable {
    let sampleCount: Int
    let syncP50Ms: Double
    let syncP95Ms: Double
    let syncP99Ms: Double
    let rimeP50Ms: Double
    let tier1P50Ms: Double
    let asyncP50Ms: Double
    let asyncP99Ms: Double
    let over16msCount: Int
    let over16msRatio: Double
    let top1FlipCount: Int
    let asyncAppliedCount: Int
    let asyncDroppedCount: Int

    static let empty = LatencySnapshot(
        sampleCount: 0,
        syncP50Ms: 0,
        syncP95Ms: 0,
        syncP99Ms: 0,
        rimeP50Ms: 0,
        tier1P50Ms: 0,
        asyncP50Ms: 0,
        asyncP99Ms: 0,
        over16msCount: 0,
        over16msRatio: 0,
        top1FlipCount: 0,
        asyncAppliedCount: 0,
        asyncDroppedCount: 0
    )

    var summaryText: String {
        guard sampleCount > 0 else {
            return "暂无击键采样数据，正常输入拼音后可在此查看实时延迟指标"
        }
        return String(
            format: "采样 %d 次 · 同步 P50 %.1fms / P95 %.1fms / P99 %.1fms（超 16ms: %.1f%%）· Rime %.1fms · 个性化 %.2fms · 首位跳变 %d 次",
            sampleCount,
            syncP50Ms,
            syncP95Ms,
            syncP99Ms,
            over16msRatio * 100.0,
            rimeP50Ms,
            tier1P50Ms,
            top1FlipCount
        )
    }
}

/// Zero-I/O fixed-capacity ring buffer for real-time keystroke latency telemetry (< 64 KB RAM).
final class LatencyProbe {
    static let shared = LatencyProbe()

    private let lock = NSLock()
    private let capacity = 2000

    private var syncSamples: [Double] = []
    private var rimeSamples: [Double] = []
    private var tier1Samples: [Double] = []
    private var asyncSamples: [Double] = []
    private var writeIndex = 0
    private var asyncWriteIndex = 0

    private var over16msTotal = 0
    private var totalKeystrokes = 0
    private var top1FlipTotal = 0
    private var asyncAppliedTotal = 0
    private var asyncDroppedTotal = 0

    init() {
        syncSamples.reserveCapacity(capacity)
        rimeSamples.reserveCapacity(capacity)
        tier1Samples.reserveCapacity(capacity)
        asyncSamples.reserveCapacity(512)
    }

    func recordSync(totalMs: Double, rimeMs: Double, tier1Ms: Double) {
        lock.lock()
        defer { lock.unlock() }

        totalKeystrokes += 1
        if totalMs > 16.0 {
            over16msTotal += 1
        }
        if syncSamples.count < capacity {
            syncSamples.append(totalMs)
            rimeSamples.append(rimeMs)
            tier1Samples.append(tier1Ms)
        } else {
            syncSamples[writeIndex] = totalMs
            rimeSamples[writeIndex] = rimeMs
            tier1Samples[writeIndex] = tier1Ms
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    func recordAsyncApplied(ms: Double, flippedTop1: Bool) {
        lock.lock()
        defer { lock.unlock() }
        asyncAppliedTotal += 1
        if flippedTop1 {
            top1FlipTotal += 1
        }
        if asyncSamples.count < 512 {
            asyncSamples.append(ms)
        } else {
            asyncSamples[asyncWriteIndex] = ms
            asyncWriteIndex = (asyncWriteIndex + 1) % 512
        }
    }

    func recordAsyncDropped() {
        lock.lock()
        defer { lock.unlock() }
        asyncDroppedTotal += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        syncSamples.removeAll(keepingCapacity: true)
        rimeSamples.removeAll(keepingCapacity: true)
        tier1Samples.removeAll(keepingCapacity: true)
        asyncSamples.removeAll(keepingCapacity: true)
        writeIndex = 0
        asyncWriteIndex = 0
        over16msTotal = 0
        totalKeystrokes = 0
        top1FlipTotal = 0
        asyncAppliedTotal = 0
        asyncDroppedTotal = 0
    }

    func snapshot() -> LatencySnapshot {
        lock.lock()
        let syncCopy = syncSamples
        let rimeCopy = rimeSamples
        let tier1Copy = tier1Samples
        let asyncCopy = asyncSamples
        let total = totalKeystrokes
        let over16 = over16msTotal
        let flips = top1FlipTotal
        let applied = asyncAppliedTotal
        let dropped = asyncDroppedTotal
        lock.unlock()

        guard !syncCopy.isEmpty else { return .empty }
        let sortedSync = syncCopy.sorted()
        let sortedRime = rimeCopy.sorted()
        let sortedTier1 = tier1Copy.sorted()
        let sortedAsync = asyncCopy.sorted()

        return LatencySnapshot(
            sampleCount: total,
            syncP50Ms: Self.percentile(sortedSync, p: 0.50),
            syncP95Ms: Self.percentile(sortedSync, p: 0.95),
            syncP99Ms: Self.percentile(sortedSync, p: 0.99),
            rimeP50Ms: Self.percentile(sortedRime, p: 0.50),
            tier1P50Ms: Self.percentile(sortedTier1, p: 0.50),
            asyncP50Ms: Self.percentile(sortedAsync, p: 0.50),
            asyncP99Ms: Self.percentile(sortedAsync, p: 0.99),
            over16msCount: over16,
            over16msRatio: total > 0 ? Double(over16) / Double(total) : 0,
            top1FlipCount: flips,
            asyncAppliedCount: applied,
            asyncDroppedCount: dropped
        )
    }

    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))
        return sorted[idx]
    }
}
