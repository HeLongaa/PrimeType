import Darwin
import Foundation
import os

/// Coalesced idle memory reclamation controller.
/// Periodically returns unused `Malloc Small` heap pages to macOS via `malloc_zone_pressure_relief(nil, 0)`
/// strictly during typing idle windows (30s after last keystroke or 5s after losing input focus),
/// ensuring zero latency impact on active typing or popup presentation.
final class MemoryPressureManager {
    static let shared = MemoryPressureManager()

    private let queue = DispatchQueue(label: "com.lumocore.inputmethod.PrimeType.memoryTrim", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var lastTrimAt: CFAbsoluteTime = 0
        var lastActivityAt: CFAbsoluteTime = 0
        var pendingWork: DispatchWorkItem?
    }

    private let typingIdleDelay: TimeInterval = 30.0
    private let deactivatedIdleDelay: TimeInterval = 5.0
    private let minTrimInterval: TimeInterval = 12.0

    private init() {}

    /// Called cheaply on active keystrokes; coalesces an idle trim 30 seconds after typing pauses.
    func noteTypingActivity() {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldReschedule: Bool = state.withLock { s in
            let delta = now - s.lastActivityAt
            s.lastActivityAt = now
            // Avoid churn on every single rapid keystroke; reschedule at most once per second
            return s.pendingWork == nil || delta >= 1.0
        }
        guard shouldReschedule else { return }
        scheduleTrim(after: typingIdleDelay, reason: "typing_idle")
    }

    /// Called when the IME controller deactivates (user switched app / left text field).
    func noteInputDeactivated() {
        scheduleTrim(after: deactivatedIdleDelay, reason: "input_deactivated")
    }

    /// Schedules a trim after `delay` seconds (e.g. after closing a panel or tearing down audio).
    func scheduleTrim(after delay: TimeInterval, reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.performTrimOnQueue(reason: reason)
            }
            self.state.withLock { s in
                s.pendingWork?.cancel()
                s.pendingWork = work
            }
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Immediately trims heap pages on the utility queue (rate-limited).
    func trimNow(reason: String, force: Bool = false) {
        queue.async { [weak self] in
            self?.performTrimOnQueue(reason: reason, force: force)
        }
    }

    private func performTrimOnQueue(reason: String, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let allowed: Bool = state.withLock { s in
            s.pendingWork = nil
            if !force && (now - s.lastTrimAt) < minTrimInterval {
                return false
            }
            s.lastTrimAt = now
            return true
        }
        guard allowed else { return }

        UserRankingEngine.shared.flushToDisk()
        DispatchQueue.main.async {
            InputTypeController.trimCachesIfNeeded()
        }
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Returns current process physical memory footprint (`phys_footprint`) in megabytes via Mach `task_vm_info`.
    static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}
