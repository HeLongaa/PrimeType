import Cocoa
import Carbon
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import os

/// Pure in-memory Apple `AudioConverter` streaming resampler (Float32 mono @ native rate -> Int16 mono @ 16kHz).
/// Uses Apple's high-quality polyphase FIR anti-aliasing filter with microsecond per-frame latency,
/// zero hardware binding, and seamless support for 48kHz / 44.1kHz / 96kHz / 24kHz / 16kHz / 8kHz.
private final class MemoryAudioConverterResampler {
    private static let noMoreDataErr: OSStatus = 10001
    private var converter: AudioConverterRef?
    private var outScratch = [Int16](repeating: 0, count: 2048)
    private let sourceRate: Double

    private struct InputContext {
        var basePtr: UnsafeMutableRawPointer
        var byteOffset: Int
        var remainingFrames: UInt32
    }

    init(sourceSampleRate: Double) {
        self.sourceRate = max(1000.0, sourceSampleRate)
        if abs(self.sourceRate - 16000.0) < 1.0 {
            // 16kHz native: direct float->Int16 conversion needs no AudioConverter
            self.converter = nil
            return
        }

        var src = AudioStreamBasicDescription(
            mSampleRate: self.sourceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var dst = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var conv: AudioConverterRef?
        if AudioConverterNew(&src, &dst, &conv) == noErr, let conv {
            var quality = UInt32(kAudioConverterQuality_High)
            _ = AudioConverterSetProperty(
                conv,
                kAudioConverterSampleRateConverterQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &quality
            )
            self.converter = conv
        }
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    func reset() {
        if let converter {
            AudioConverterReset(converter)
        }
    }

    func process(_ input: [Float], into output: inout [Int16]) {
        guard !input.isEmpty else { return }

        guard let converter else {
            // Exact 16kHz fast path (or fallback if AudioConverter creation ever failed)
            output.reserveCapacity(output.count + input.count)
            for s in input {
                let clamped = max(-1.0, min(1.0, Double(s)))
                output.append(Int16((clamped * 32767.0).rounded()))
            }
            return
        }

        input.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var ctx = InputContext(
                basePtr: UnsafeMutableRawPointer(mutating: base),
                byteOffset: 0,
                remainingFrames: UInt32(input.count)
            )
            while true {
                var outFrames = UInt32(outScratch.count)
                let status: OSStatus = outScratch.withUnsafeMutableBytes { outRaw in
                    var abl = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(outRaw.count),
                            mData: outRaw.baseAddress
                        )
                    )
                    return withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                        AudioConverterFillComplexBuffer(
                            converter,
                            { _, ioPackets, ioData, _, userData in
                                guard let userData else {
                                    ioPackets.pointee = 0
                                    return MemoryAudioConverterResampler.noMoreDataErr
                                }
                                let c = userData.assumingMemoryBound(to: InputContext.self)
                                if c.pointee.remainingFrames == 0 {
                                    ioPackets.pointee = 0
                                    return MemoryAudioConverterResampler.noMoreDataErr
                                }
                                let n = min(ioPackets.pointee, c.pointee.remainingFrames)
                                ioData.pointee.mNumberBuffers = 1
                                ioData.pointee.mBuffers.mNumberChannels = 1
                                ioData.pointee.mBuffers.mDataByteSize = n * 4
                                ioData.pointee.mBuffers.mData = c.pointee.basePtr.advanced(by: c.pointee.byteOffset)
                                c.pointee.byteOffset += Int(n) * 4
                                c.pointee.remainingFrames -= n
                                ioPackets.pointee = n
                                return noErr
                            },
                            ctxPtr,
                            &outFrames,
                            &abl,
                            nil
                        )
                    }
                }
                if outFrames > 0 {
                    output.append(contentsOf: outScratch[0..<Int(outFrames)])
                }
                if status == Self.noMoreDataErr || status != noErr || outFrames == 0 {
                    break
                }
            }
        }
    }
}

/// Adaptive multi-channel downmixer that avoids 50% volume halving on single-sided USB mics
/// (e.g. mono hardware reporting 2ch with silent R) and avoids phase cancellation on out-of-phase arrays.
private final class SmartChannelDownmixer {
    private var channelEnergyEMA: [Double] = []
    private var stereoCorrelationEMA: Double = 1.0
    private var preferredChannel: Int = 0
    private var challengerChannel: Int = 0
    private var challengerStreak: Int = 0

    func reset() {
        channelEnergyEMA.removeAll(keepingCapacity: true)
        stereoCorrelationEMA = 1.0
        preferredChannel = 0
        challengerChannel = 0
        challengerStreak = 0
    }

    func extractMonoFloats(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        into output: inout [Float]
    ) {
        output.removeAll(keepingCapacity: true)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !list.isEmpty else { return }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = format.mBitsPerChannel

        if isFloat && bits == 32 {
            if list.count == 1 {
                let buf = list[0]
                guard let raw = buf.mData, buf.mDataByteSize > 0 else { return }
                let channels = max(1, Int(buf.mNumberChannels))
                let frames = (Int(buf.mDataByteSize) / MemoryLayout<Float>.size) / channels
                guard frames > 0 else { return }
                let ptr = raw.assumingMemoryBound(to: Float.self)
                output.reserveCapacity(frames)

                if channels == 1 {
                    output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
                    return
                }

                let strategy = decideInterleavedFloatStrategy(ptr: ptr, frames: frames, channels: channels)
                switch strategy {
                case .averageStereo:
                    for i in 0..<frames {
                        let base = i * 2
                        output.append((ptr[base] + ptr[base + 1]) * 0.5)
                    }
                case .singleChannel(let ch):
                    for i in 0..<frames {
                        output.append(ptr[i * channels + ch])
                    }
                }
            } else {
                var validPtrs: [UnsafePointer<Float>] = []
                var minFrames = Int.max
                for buf in list {
                    guard let raw = buf.mData, buf.mDataByteSize > 0 else { continue }
                    let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                    if frames > 0 {
                        validPtrs.append(UnsafePointer(raw.assumingMemoryBound(to: Float.self)))
                        minFrames = min(minFrames, frames)
                    }
                }
                guard !validPtrs.isEmpty, minFrames > 0, minFrames < Int.max else { return }
                output.reserveCapacity(minFrames)

                if validPtrs.count == 1 {
                    output.append(contentsOf: UnsafeBufferPointer(start: validPtrs[0], count: minFrames))
                    return
                }

                let strategy = decidePlanarFloatStrategy(ptrs: validPtrs, frames: minFrames)
                switch strategy {
                case .averageStereo:
                    let p0 = validPtrs[0]
                    let p1 = validPtrs[1]
                    for i in 0..<minFrames {
                        output.append((p0[i] + p1[i]) * 0.5)
                    }
                case .singleChannel(let ch):
                    let p = validPtrs[ch]
                    output.append(contentsOf: UnsafeBufferPointer(start: p, count: minFrames))
                }
            }
            return
        }

        if !isFloat && bits == 16 {
            let buf = list[0]
            guard let raw = buf.mData, buf.mDataByteSize > 0 else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = (Int(buf.mDataByteSize) / MemoryLayout<Int16>.size) / channels
            guard frames > 0 else { return }
            let ptr = raw.assumingMemoryBound(to: Int16.self)
            output.reserveCapacity(frames)
            let ch = min(preferredChannel, channels - 1)
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frames {
                output.append(Float(ptr[i * channels + ch]) * scale)
            }
            return
        }

        if !isFloat && bits == 32 {
            let buf = list[0]
            guard let raw = buf.mData, buf.mDataByteSize > 0 else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = (Int(buf.mDataByteSize) / MemoryLayout<Int32>.size) / channels
            guard frames > 0 else { return }
            let ptr = raw.assumingMemoryBound(to: Int32.self)
            output.reserveCapacity(frames)
            let ch = min(preferredChannel, channels - 1)
            let scale: Float = 1.0 / 2147483648.0
            for i in 0..<frames {
                output.append(Float(ptr[i * channels + ch]) * scale)
            }
        }
    }

    private enum Strategy {
        case averageStereo
        case singleChannel(Int)
    }

    private func ensureChannelState(count: Int) {
        if channelEnergyEMA.count != count {
            channelEnergyEMA = [Double](repeating: 0, count: count)
            preferredChannel = 0
            challengerChannel = 0
            challengerStreak = 0
            stereoCorrelationEMA = 1.0
        }
    }

    private func decideInterleavedFloatStrategy(ptr: UnsafePointer<Float>, frames: Int, channels: Int) -> Strategy {
        ensureChannelState(count: channels)
        var frameEnergy = [Double](repeating: 0, count: channels)
        var dotLR: Double = 0

        if channels == 2 {
            for i in 0..<frames {
                let l = Double(ptr[i * 2])
                let r = Double(ptr[i * 2 + 1])
                frameEnergy[0] += l * l
                frameEnergy[1] += r * r
                dotLR += l * r
            }
        } else {
            for i in 0..<frames {
                let base = i * channels
                for c in 0..<channels {
                    let v = Double(ptr[base + c])
                    frameEnergy[c] += v * v
                }
            }
        }

        return evaluateStrategy(frameEnergy: frameEnergy, dotLR: dotLR, channels: channels)
    }

    private func decidePlanarFloatStrategy(ptrs: [UnsafePointer<Float>], frames: Int) -> Strategy {
        let channels = ptrs.count
        ensureChannelState(count: channels)
        var frameEnergy = [Double](repeating: 0, count: channels)
        var dotLR: Double = 0

        if channels == 2 {
            let p0 = ptrs[0]
            let p1 = ptrs[1]
            for i in 0..<frames {
                let l = Double(p0[i])
                let r = Double(p1[i])
                frameEnergy[0] += l * l
                frameEnergy[1] += r * r
                dotLR += l * r
            }
        } else {
            for c in 0..<channels {
                let p = ptrs[c]
                var e: Double = 0
                for i in 0..<frames {
                    let v = Double(p[i])
                    e += v * v
                }
                frameEnergy[c] = e
            }
        }

        return evaluateStrategy(frameEnergy: frameEnergy, dotLR: dotLR, channels: channels)
    }

    private func evaluateStrategy(frameEnergy: [Double], dotLR: Double, channels: Int) -> Strategy {
        let alpha = 0.25
        for c in 0..<channels {
            channelEnergyEMA[c] = channelEnergyEMA[c] * (1.0 - alpha) + frameEnergy[c] * alpha
        }

        // Find strongest channel with hysteresis to prevent chattering
        var bestIdx = 0
        var bestVal = channelEnergyEMA[0]
        for c in 1..<channels where channelEnergyEMA[c] > bestVal {
            bestVal = channelEnergyEMA[c]
            bestIdx = c
        }

        let currentVal = channelEnergyEMA[preferredChannel]
        if bestIdx != preferredChannel && bestVal > max(currentVal * 2.0, 1e-10) {
            if challengerChannel == bestIdx {
                challengerStreak += 1
                if challengerStreak >= 4 {
                    preferredChannel = bestIdx
                    challengerStreak = 0
                }
            } else {
                challengerChannel = bestIdx
                challengerStreak = 1
            }
        } else {
            challengerStreak = 0
        }

        if channels == 2 {
            let e0 = channelEnergyEMA[0]
            let e1 = channelEnergyEMA[1]
            let maxE = max(e0, e1)
            let minE = min(e0, e1)
            if frameEnergy[0] > 1e-10 && frameEnergy[1] > 1e-10 {
                let corr = dotLR / (frameEnergy[0] * frameEnergy[1]).squareRoot()
                stereoCorrelationEMA = stereoCorrelationEMA * 0.8 + corr * 0.2
            }
            // Only average stereo when both channels carry comparable energy AND are in-phase;
            // otherwise select the active channel directly to avoid 50% halving or phase cancellation.
            if maxE > 1e-10 && (minE / maxE) >= 0.15 && stereoCorrelationEMA >= 0.25 {
                return .averageStereo
            }
            return .singleChannel(preferredChannel)
        }

        return .singleChannel(preferredChannel)
    }
}

// MARK: - Layer 3: Non-Zero PCM Activation Detector

/// Distinguishes `AVCaptureSession.startRunning()` returning from real audio arriving from the hardware/Bluetooth ADC.
/// Tracks leading all-zero DMA frames and confirms real activation on the first non-zero sample (or 300ms fallback timeout).
struct VoiceActivationTracker {
    enum Phase: Equatable {
        case waiting
        case allZeroStarted
        case confirmedNonZero
        case confirmedTimeout
    }

    struct StepOutcome: Equatable {
        let isActivated: Bool
        let justConfirmed: Bool
        let shouldDropFrame: Bool
        let eventLog: String?
    }

    static let maxZeroWarmupFrames = 15 // 15 * 20ms = 300ms timeout fallback for muted/silent mics

    private(set) var phase: Phase = .waiting
    private(set) var zeroFrameCount: Int = 0
    private(set) var captureGeneration: Int = 0
    private(set) var captureStartedAt: CFAbsoluteTime = 0
    private(set) var confirmedWakeupMs: Double?

    var isActivated: Bool {
        phase == .confirmedNonZero || phase == .confirmedTimeout
    }

    mutating func reset(captureGeneration: Int, startedAt: CFAbsoluteTime) {
        self.phase = .waiting
        self.zeroFrameCount = 0
        self.captureGeneration = captureGeneration
        self.captureStartedAt = startedAt
        self.confirmedWakeupMs = nil
    }

    mutating func markAlreadyActive(captureGeneration: Int) {
        self.captureGeneration = captureGeneration
        self.phase = .confirmedNonZero
        self.confirmedWakeupMs = 0
    }

    mutating func consume(frame: [Int16], now: CFAbsoluteTime) -> StepOutcome {
        if isActivated {
            return StepOutcome(isActivated: true, justConfirmed: false, shouldDropFrame: false, eventLog: nil)
        }

        let elapsedMs = max(0.0, (now - captureStartedAt) * 1000.0)
        let hasNonZero = frame.contains { $0 != 0 }

        if hasNonZero {
            phase = .confirmedNonZero
            confirmedWakeupMs = elapsedMs
            let log = String(
                format: "[AVCaptureSessionAudioRecorder] first_nonzero_pcm capture=%d zeroFrames=%d elapsedMs=%.1f | activation_nonzero_pcm_confirmed",
                captureGeneration,
                zeroFrameCount,
                elapsedMs
            )
            return StepOutcome(isActivated: true, justConfirmed: true, shouldDropFrame: false, eventLog: log)
        }

        zeroFrameCount += 1
        if zeroFrameCount >= Self.maxZeroWarmupFrames {
            phase = .confirmedTimeout
            confirmedWakeupMs = elapsedMs
            let log = String(
                format: "[AVCaptureSessionAudioRecorder] nonzero_pcm_timeout capture=%d zeroFrames=%d elapsedMs=%.1f",
                captureGeneration,
                zeroFrameCount,
                elapsedMs
            )
            return StepOutcome(isActivated: true, justConfirmed: true, shouldDropFrame: false, eventLog: log)
        }

        if phase == .waiting {
            phase = .allZeroStarted
            let log = String(
                format: "[AVCaptureSessionAudioRecorder] all_zero_pcm_started capture=%d elapsedMs=%.1f",
                captureGeneration,
                elapsedMs
            )
            return StepOutcome(isActivated: false, justConfirmed: false, shouldDropFrame: true, eventLog: log)
        }

        return StepOutcome(isActivated: false, justConfirmed: false, shouldDropFrame: true, eventLog: nil)
    }
}

// MARK: - Layer 4: 150ms Pre-Roll & Begin-Padding Buffer (2400 samples @ 16kHz)

/// Preserves the leading 150ms (`begin_padding_ms = 150`, 2400 Int16 samples @ 16kHz) across both:
/// 1. Warm standby / key-down pre-roll (rolling ring buffer flushed atomically at capture start), and
/// 2. Cold capture start (accumulating the first 150ms before contiguous flush, with lossless flush on short stops).
struct VoicePreRollBuffer {
    static let sampleRate = 16_000
    static let frameSamples = 320 // 20ms @ 16kHz
    static let beginPaddingMs = 150
    static let beginPaddingSamples = 2400 // 150ms @ 16kHz
    static let maxHoldPreRollSamples = 9600 // 600ms @ 16kHz while holding modifier key

    private var rollingSamples: [Int16] = []
    private var coldStartSamples: [Int16] = []
    private var streamPending: [Int16] = []
    private(set) var isColdStartPaddingPending = false

    var rollingSampleCount: Int { rollingSamples.count }
    var coldStartBufferedCount: Int { coldStartSamples.count }

    mutating func resetAll() {
        rollingSamples.removeAll(keepingCapacity: true)
        coldStartSamples.removeAll(keepingCapacity: true)
        streamPending.removeAll(keepingCapacity: true)
        isColdStartPaddingPending = false
    }

    mutating func appendRolling(_ samples: [Int16], maxSamples: Int) {
        guard !samples.isEmpty else { return }
        rollingSamples.append(contentsOf: samples)
        if rollingSamples.count > maxSamples {
            rollingSamples.removeFirst(rollingSamples.count - maxSamples)
        }
    }

    mutating func trimRolling(to maxSamples: Int) {
        if rollingSamples.count > maxSamples {
            rollingSamples.removeFirst(rollingSamples.count - maxSamples)
        }
    }

    /// Transitions into active capture. Returns any non-zero pre-roll frames ready for immediate flush.
    /// If no live pre-roll samples existed (cold start), arms the 150ms (2400-sample) begin-padding accumulator.
    mutating func beginCapture(useRollingPreRoll: Bool) -> [[Int16]] {
        coldStartSamples.removeAll(keepingCapacity: true)
        streamPending.removeAll(keepingCapacity: true)

        guard useRollingPreRoll, !rollingSamples.isEmpty else {
            rollingSamples.removeAll(keepingCapacity: true)
            isColdStartPaddingPending = true
            return []
        }

        let trimmed: [Int16]
        if let firstNonZero = rollingSamples.firstIndex(where: { $0 != 0 }) {
            // Preserve up to 20ms (320 samples) of natural silence lead-in right before first non-zero sample
            let startIdx = max(0, firstNonZero - Self.frameSamples)
            trimmed = Array(rollingSamples[startIdx...])
        } else {
            trimmed = []
        }
        rollingSamples.removeAll(keepingCapacity: true)

        guard !trimmed.isEmpty else {
            isColdStartPaddingPending = true
            return []
        }

        // We already have live pre-roll audio; stream directly with 0ms additional padding delay
        isColdStartPaddingPending = false
        streamPending.append(contentsOf: trimmed)
        return popCompleteFrames(from: &streamPending)
    }

    /// Feeds post-activation 16kHz Int16 samples during `.capturing`, returning 20ms (320-sample) frames to push to ASR.
    mutating func appendCaptureSamples(_ samples: [Int16]) -> [[Int16]] {
        guard !samples.isEmpty else { return [] }

        if isColdStartPaddingPending {
            coldStartSamples.append(contentsOf: samples)
            guard coldStartSamples.count >= Self.beginPaddingSamples else {
                return []
            }
            isColdStartPaddingPending = false
            streamPending.append(contentsOf: coldStartSamples)
            coldStartSamples.removeAll(keepingCapacity: true)
            return popCompleteFrames(from: &streamPending)
        }

        streamPending.append(contentsOf: samples)
        return popCompleteFrames(from: &streamPending)
    }

    /// Flushes any buffered cold-start padding (<150ms short utterances) and trailing partial frame on capture stop.
    mutating func flushOnStop() -> [[Int16]] {
        if !coldStartSamples.isEmpty {
            streamPending.append(contentsOf: coldStartSamples)
            coldStartSamples.removeAll(keepingCapacity: true)
        }
        isColdStartPaddingPending = false

        var frames = popCompleteFrames(from: &streamPending)
        if !streamPending.isEmpty {
            let padded = streamPending + [Int16](repeating: 0, count: max(0, Self.frameSamples - streamPending.count))
            frames.append(padded)
            streamPending.removeAll(keepingCapacity: true)
        }
        return frames
    }

    private func popCompleteFrames(from buffer: inout [Int16]) -> [[Int16]] {
        var out: [[Int16]] = []
        let count = buffer.count / Self.frameSamples
        guard count > 0 else { return out }
        out.reserveCapacity(count)
        var offset = 0
        for _ in 0..<count {
            out.append(Array(buffer[offset..<(offset + Self.frameSamples)]))
            offset += Self.frameSamples
        }
        buffer.removeFirst(offset)
        return out
    }
}

/// Four-layer low-latency `AVCaptureSession` voice recorder modeled after WeType's fast-wakeup architecture:
/// 1. **VoiceAudioFrameworkPrewarmer**: Pre-enumerates audio devices (incl. Bluetooth) and builds/configures
///    the `AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureAudioDataOutput` (16kHz/Mono/Int16) graph
///    on a background queue with `captureStarted = false` (no orange mic dot while idle).
/// 2. **Capture Graph Reuse**: Keeps the configured session resident across presses; keypress only calls
///    `session.startRunning()` (~10–30ms). Keeps running in `.warmStandby` for 30s for 0ms repeat wakeup,
///    then calls `stopRunning()` while retaining the configured graph for fast re-start.
/// 3. **Non-Zero PCM Activation Detection**: Separates `startRunning()` from real audio arrival via
///    `VoiceActivationTracker` (`all_zero_pcm_started` -> `first_nonzero_pcm` / `nonzero_pcm_timeout`).
/// 4. **150ms Pre-Roll / Begin Padding**: Preserves leading 150ms (`2400` Int16 samples @ 16kHz) via
///    `VoicePreRollBuffer` so the first syllable spoken at keypress is never clipped.
private final class VoiceAudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let frameSamples = VoicePreRollBuffer.frameSamples // 320 (20ms @ 16kHz)
    static let defaultWarmStandbyDuration: TimeInterval = 30.0 // 30s hot standby before stopRunning()
    static let defaultGraphTeardownDuration: TimeInterval = 300.0 // 5min idle before tearing down AVCaptureSession graph & returning RAM
    private static let leadingSilenceFrameCount = 6 // 120ms leading silence for cloud ASR VAD stability

    private enum Mode {
        case idle
        case preRolling
        case capturing
        case warmStandby
    }

    private struct SharedState {
        var mode: Mode = .idle
        var alwaysOnEnabled = false
        var startedForPreRoll = false
        var isSystemSleeping = false
        var desiredMicUID: String = ""
        var activation = VoiceActivationTracker()
        var preRoll = VoicePreRollBuffer()
        var rawFrameAccumulator: [Int16] = []
        var liveSessions: [any VoiceASRSession] = []
        var standbyToken: Int = 0
        var captureGeneration: Int = 0
    }

    private let sampleBufferQueue = DispatchQueue(label: "com.lumocore.inputtype.voice.capture.sample", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.lumocore.inputtype.voice.capture.control", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: SharedState())

    // Owned exclusively by controlQueue
    private var captureSession: AVCaptureSession?
    private var captureInput: AVCaptureDeviceInput?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var preparedDeviceUID: String?
    private var preparedDesiredMicUID: String?
    private var standbyTimer: DispatchWorkItem?
    private var graphTeardownTimer: DispatchWorkItem?
    private var wakeRestoreWorkItem: DispatchWorkItem?
    private var topologyDebounceWorkItem: DispatchWorkItem?

    // System-wide CoreAudio, AVFoundation & Sleep/Wake listeners
    private var devicesListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Owned exclusively by sampleBufferQueue (fallback conversion if hardware ignores 16kHz Int16 audioSettings)
    private var fallbackDownmixer = SmartChannelDownmixer()
    private var fallbackResampler: MemoryAudioConverterResampler?
    private var fallbackSourceRate: Double = 0
    private var fallbackMonoScratch: [Float] = []
    private var fallbackResampledScratch: [Int16] = []
    private var fastInt16Scratch: [Int16] = []

    var onLevel: ((Float) -> Void)?
    var onMicReady: ((Int) -> Void)?
    var onStartError: ((Int, Error) -> Void)?

    override init() {
        super.init()
        fallbackMonoScratch.reserveCapacity(2048)
        fallbackResampledScratch.reserveCapacity(1024)
        fastInt16Scratch.reserveCapacity(1024)
        installSystemListeners()
    }

    deinit {
        removeSystemListeners()
    }

    // MARK: - Layer 1: Passive Graph Prewarming (captureStarted = false)

    /// Pre-enumerates audio devices and builds the `AVCaptureSession` capture graph on a background queue
    /// WITHOUT starting capture (`captureStarted = false`), so no mic privacy indicator appears while idle.
    func prewarm(microphoneUID: String, trigger: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[VoicePrewarm] skip reason=not_authorized trigger=%@", trigger)
            return
        }

        let shouldProceed: Bool = state.withLock { s in
            guard !s.isSystemSleeping else { return false }
            if s.mode == .idle {
                s.desiredMicUID = microphoneUID
            }
            return s.mode == .idle
        }
        guard shouldProceed else { return }

        controlQueue.async { [weak self] in
            guard let self else { return }
            let stillIdle = self.state.withLock { $0.mode == .idle && !$0.isSystemSleeping }
            guard stillIdle else {
                NSLog("[VoicePrewarm] cancelled stage=before_query trigger=%@", trigger)
                return
            }
            _ = self.prepareCaptureGraphOnControlQueue(microphoneUID: microphoneUID, trigger: trigger)
        }
    }

    /// Configures optional always-on low-power standby (0ms instant start) or switches standby/prewarmed device.
    func setAlwaysOn(_ enabled: Bool, microphoneUID: String) {
        enum Action {
            case none
            case startOrSwitchWarm
            case stopStandbyKeepGraph
            case prewarmIdleGraph
        }

        let action: Action = state.withLock { s in
            s.alwaysOnEnabled = enabled
            let deviceChanged = (s.desiredMicUID != microphoneUID)

            if enabled {
                s.standbyToken &+= 1
                guard !s.isSystemSleeping else {
                    s.desiredMicUID = microphoneUID
                    return .none
                }
                switch s.mode {
                case .idle:
                    s.mode = .warmStandby
                    s.desiredMicUID = microphoneUID
                    s.preRoll.resetAll()
                    s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                    s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                    return .startOrSwitchWarm
                case .warmStandby:
                    if deviceChanged {
                        s.desiredMicUID = microphoneUID
                        s.preRoll.resetAll()
                        s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                        s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                    }
                    return .startOrSwitchWarm
                case .preRolling, .capturing:
                    return .none
                }
            } else {
                switch s.mode {
                case .warmStandby:
                    s.standbyToken &+= 1
                    s.mode = .idle
                    s.desiredMicUID = microphoneUID
                    s.preRoll.resetAll()
                    s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                    s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                    return .stopStandbyKeepGraph
                case .idle:
                    s.desiredMicUID = microphoneUID
                    return .prewarmIdleGraph
                case .preRolling, .capturing:
                    return .none
                }
            }
        }

        switch action {
        case .none:
            break
        case .startOrSwitchWarm:
            controlQueue.async { [weak self] in
                guard let self else { return }
                self.standbyTimer?.cancel()
                self.standbyTimer = nil
                let shouldRun = self.state.withLock { $0.mode != .idle && !$0.isSystemSleeping }
                if shouldRun {
                    _ = self.ensureCaptureRunningOnControlQueue(microphoneUID: microphoneUID, trigger: "always_on")
                }
            }
        case .stopStandbyKeepGraph:
            controlQueue.async { [weak self] in
                guard let self else { return }
                self.standbyTimer?.cancel()
                self.standbyTimer = nil
                let stillIdle = self.state.withLock { $0.mode == .idle }
                if stillIdle {
                    self.stopRunningKeepingGraphOnControlQueue()
                    if self.preparedDesiredMicUID != microphoneUID,
                       AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        _ = self.prepareCaptureGraphOnControlQueue(microphoneUID: microphoneUID, trigger: "device_switch_idle")
                    }
                }
            }
        case .prewarmIdleGraph:
            prewarm(microphoneUID: microphoneUID, trigger: "preference_sync")
        }
    }

    // MARK: - Layer 2: Fast Capture Start & Graph Reuse

    /// Begins warming up & rolling-buffering the microphone immediately on modifier key-down.
    func startPreRoll(microphoneUID: String) {
        let shouldStartDevice: Bool? = state.withLock { s in
            guard !s.isSystemSleeping else { return nil }
            switch s.mode {
            case .capturing:
                return nil
            case .preRolling:
                if s.desiredMicUID == microphoneUID {
                    return nil
                }
                s.desiredMicUID = microphoneUID
                s.preRoll.resetAll()
                s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                return true
            case .warmStandby:
                s.standbyToken &+= 1
                s.mode = .preRolling
                s.startedForPreRoll = false
                if s.desiredMicUID != microphoneUID {
                    s.desiredMicUID = microphoneUID
                    s.preRoll.resetAll()
                    s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                    s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                    return true
                }
                return false
            case .idle:
                s.standbyToken &+= 1
                s.mode = .preRolling
                s.startedForPreRoll = true
                s.desiredMicUID = microphoneUID
                s.preRoll.resetAll()
                s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                return true
            }
        }

        guard let shouldStartDevice else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            if shouldStartDevice || self.captureSession?.isRunning != true || self.preparedDesiredMicUID != microphoneUID {
                _ = self.ensureCaptureRunningOnControlQueue(microphoneUID: microphoneUID, trigger: "key_down_preroll")
            }
        }
    }

    /// Cancels a pending key-down pre-roll (e.g. user pressed Right-Cmd + C).
    /// Stops capture immediately if it wasn't previously in warm standby, while retaining the prewarmed graph.
    func cancelPreRoll(warmStandbyDuration: TimeInterval = defaultWarmStandbyDuration) {
        let decision: (action: Int, token: Int, keepForever: Bool) = state.withLock { s in
            guard s.mode == .preRolling else { return (0, 0, false) }
            if s.startedForPreRoll && !s.alwaysOnEnabled {
                s.mode = .idle
                s.startedForPreRoll = false
                s.preRoll.resetAll()
                s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                return (1, s.standbyToken, false)
            } else {
                s.standbyToken &+= 1
                s.mode = .warmStandby
                s.startedForPreRoll = false
                s.preRoll.trimRolling(to: VoicePreRollBuffer.beginPaddingSamples)
                return (2, s.standbyToken, s.alwaysOnEnabled)
            }
        }

        if decision.action == 1 {
            controlQueue.async { [weak self] in
                guard let self else { return }
                let stillIdle = self.state.withLock { $0.mode == .idle }
                if stillIdle {
                    self.stopRunningKeepingGraphOnControlQueue()
                }
            }
        } else if decision.action == 2 && !decision.keepForever {
            scheduleStandbyPause(token: decision.token, duration: warmStandbyDuration)
        }
    }

    /// Transitions into active capture, atomically injecting leading silence + 150ms pre-roll frames before live streaming.
    /// Returns whether real non-zero audio is already flowing (true => 0ms warm start).
    func startCapture(
        microphoneUID: String,
        sessions: [any VoiceASRSession],
        generation: Int
    ) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let (alreadyLive, needStartOrSwitch): (Bool, Bool) = state.withLock { s in
            s.standbyToken &+= 1
            s.captureGeneration = generation
            s.startedForPreRoll = false

            let sameDevice = (s.desiredMicUID == microphoneUID)
            let wasRunning = (s.mode == .preRolling || s.mode == .warmStandby) && sameDevice
            let switchNeeded = !wasRunning

            if !sameDevice {
                s.desiredMicUID = microphoneUID
                s.preRoll.resetAll()
                s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                s.activation.reset(captureGeneration: generation, startedAt: now)
            } else if wasRunning && s.activation.isActivated {
                s.activation.markAlreadyActive(captureGeneration: generation)
            } else {
                s.activation.reset(captureGeneration: generation, startedAt: now)
            }

            // 1. Inject 120ms leading silence so cloud ASR frontend VAD stabilizes cleanly without clipping first syllable
            let silenceFrame = [Int16](repeating: 0, count: Self.frameSamples)
            for _ in 0..<Self.leadingSilenceFrameCount {
                for session in sessions {
                    session.push(pcm16: silenceFrame)
                }
            }

            // 2. Flush any rolling 150ms+ pre-roll captured on the same device (or arm cold-start 150ms begin_padding)
            let preRollFrames = s.preRoll.beginCapture(useRollingPreRoll: wasRunning)
            for frame in preRollFrames {
                for session in sessions {
                    session.push(pcm16: frame)
                }
            }

            // 3. Atomically attach live sessions so the very next callback streams with zero gap
            s.liveSessions = sessions
            s.mode = .capturing
            return (wasRunning && s.activation.isActivated, switchNeeded)
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil

            let stillThisCapture = self.state.withLock {
                $0.mode == .capturing && $0.captureGeneration == generation
            }
            guard stillThisCapture else { return }

            if needStartOrSwitch || self.captureSession?.isRunning != true || self.preparedDesiredMicUID != microphoneUID {
                if let err = self.ensureCaptureRunningOnControlQueue(microphoneUID: microphoneUID, trigger: "start_capture") {
                    let stillActive = self.state.withLock { s -> Bool in
                        if s.mode == .capturing && s.captureGeneration == generation {
                            s.mode = .idle
                            s.liveSessions.removeAll()
                            return true
                        }
                        return false
                    }
                    if stillActive {
                        DispatchQueue.main.async {
                            self.onStartError?(generation, err)
                        }
                    }
                }
            }
        }

        return alreadyLive
    }

    /// Flushes any remaining cold-start padding / trailing partial frame to the active sessions, detaches them,
    /// and keeps the capture graph hot in `.warmStandby` for 30s (or forever when always-on is enabled) before stopping.
    func finishCaptureAndWarmStandby(duration: TimeInterval = defaultWarmStandbyDuration) {
        let result: (didFinish: Bool, token: Int, keepForever: Bool) = state.withLock { s in
            guard s.mode == .capturing else {
                s.liveSessions.removeAll()
                return (false, 0, false)
            }
            let remainingFrames = s.preRoll.flushOnStop()
            if !remainingFrames.isEmpty && !s.liveSessions.isEmpty {
                for frame in remainingFrames {
                    for session in s.liveSessions {
                        session.push(pcm16: frame)
                    }
                }
            }
            s.liveSessions.removeAll()
            s.standbyToken &+= 1
            s.mode = .warmStandby
            s.preRoll.resetAll()
            return (true, s.standbyToken, s.alwaysOnEnabled)
        }

        if result.didFinish && !result.keepForever {
            scheduleStandbyPause(token: result.token, duration: duration)
        }
    }

    /// Stops immediately and tears down the `AVCaptureSession` (used on app termination).
    func stopImmediately() {
        state.withLock { s in
            s.alwaysOnEnabled = false
            s.standbyToken &+= 1
            s.mode = .idle
            s.startedForPreRoll = false
            s.preRoll.resetAll()
            s.rawFrameAccumulator.removeAll()
            s.liveSessions.removeAll()
            s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
        }

        controlQueue.sync {
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            self.wakeRestoreWorkItem?.cancel()
            self.wakeRestoreWorkItem = nil
            self.topologyDebounceWorkItem?.cancel()
            self.topologyDebounceWorkItem = nil
            self.teardownSessionOnControlQueue()
        }
    }

    // MARK: - System Hot-Plug & Sleep/Wake Listeners

    private func installSystemListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleTopologyReconcileOnControlQueue(reason: "coreaudio_devices_changed")
        }
        if AudioObjectAddPropertyListenerBlock(systemObj, &devicesAddr, controlQueue, devicesBlock) == noErr {
            devicesListListenerBlock = devicesBlock
        }

        var defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultInBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleTopologyReconcileOnControlQueue(reason: "coreaudio_default_input_changed")
        }
        if AudioObjectAddPropertyListenerBlock(systemObj, &defaultInAddr, controlQueue, defaultInBlock) == noErr {
            defaultInputListenerBlock = defaultInBlock
        }

        let center = NotificationCenter.default
        deviceConnectedObserver = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let dev = notification.object as? AVCaptureDevice, dev.hasMediaType(.audio) else { return }
            self?.controlQueue.async {
                self?.scheduleTopologyReconcileOnControlQueue(reason: "avcapture_connected")
            }
        }
        deviceDisconnectedObserver = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let dev = notification.object as? AVCaptureDevice, dev.hasMediaType(.audio) else { return }
            self?.controlQueue.async {
                self?.scheduleTopologyReconcileOnControlQueue(reason: "avcapture_disconnected")
            }
        }

        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleSystemWillSleep()
        }
        wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleSystemDidWake()
        }
    }

    private func removeSystemListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        if let block = devicesListListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, controlQueue, block)
            devicesListListenerBlock = nil
        }
        if let block = defaultInputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, controlQueue, block)
            defaultInputListenerBlock = nil
        }
        let center = NotificationCenter.default
        if let deviceConnectedObserver { center.removeObserver(deviceConnectedObserver) }
        if let deviceDisconnectedObserver { center.removeObserver(deviceDisconnectedObserver) }
        deviceConnectedObserver = nil
        deviceDisconnectedObserver = nil

        let nc = NSWorkspace.shared.notificationCenter
        if let sleepObserver { nc.removeObserver(sleepObserver) }
        if let wakeObserver { nc.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func handleSystemWillSleep() {
        state.withLock { s in
            s.isSystemSleeping = true
            s.standbyToken &+= 1
            if s.mode != .capturing {
                s.mode = .idle
                s.startedForPreRoll = false
            }
            s.preRoll.resetAll()
            s.rawFrameAccumulator.removeAll(keepingCapacity: true)
            s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            self.wakeRestoreWorkItem?.cancel()
            self.wakeRestoreWorkItem = nil
            self.topologyDebounceWorkItem?.cancel()
            self.topologyDebounceWorkItem = nil
            self.teardownSessionOnControlQueue()
        }
    }

    private func handleSystemDidWake() {
        let (shouldRestoreAlwaysOn, micUID): (Bool, String) = state.withLock { s in
            s.isSystemSleeping = false
            return (s.alwaysOnEnabled && s.mode == .idle, s.desiredMicUID)
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.wakeRestoreWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if shouldRestoreAlwaysOn {
                    let (stillNeed, uid): (Bool, String) = self.state.withLock { s in
                        guard s.alwaysOnEnabled && !s.isSystemSleeping && s.mode == .idle else {
                            return (false, "")
                        }
                        s.mode = .warmStandby
                        s.preRoll.resetAll()
                        s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                        s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                        return (true, s.desiredMicUID)
                    }
                    if stillNeed {
                        _ = self.ensureCaptureRunningOnControlQueue(microphoneUID: uid, trigger: "system_wake_always_on")
                    }
                } else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    let canPrewarm = self.state.withLock { $0.mode == .idle && !$0.isSystemSleeping }
                    if canPrewarm {
                        _ = self.prepareCaptureGraphOnControlQueue(microphoneUID: micUID, trigger: "system_wake")
                    }
                }
            }
            self.wakeRestoreWorkItem = work
            // Give USB / Bluetooth / CoreAudio ~1.0s after Mac wake to finish re-enumerating audio interfaces
            self.controlQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    private func scheduleTopologyReconcileOnControlQueue(reason: String) {
        topologyDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleHardwareTopologyChangedOnControlQueue(reason: reason)
        }
        topologyDebounceWorkItem = work
        controlQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func handleHardwareTopologyChangedOnControlQueue(reason: String) {
        let (mode, sleeping, desiredUID): (Mode, Bool, String) = state.withLock { s in
            (s.mode, s.isSystemSleeping, s.desiredMicUID)
        }
        guard !sleeping else { return }

        guard let resolved = Self.resolveCaptureDevice(uid: desiredUID) else {
            if mode != .idle {
                teardownSessionOnControlQueue()
            }
            return
        }

        let currentValid = (captureSession != nil)
            && (preparedDeviceUID == resolved.uniqueID)
            && (captureInput?.device.isConnected == true)

        if mode != .idle {
            if !currentValid || captureSession?.isRunning != true {
                state.withLock { s in
                    s.preRoll.resetAll()
                    s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                    s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                }
                _ = ensureCaptureRunningOnControlQueue(microphoneUID: desiredUID, trigger: reason)
            }
        } else if !currentValid, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            // Device plugged in or default input switched while idle (e.g. AirPods connected):
            // quietly re-prewarm the capture graph (`captureStarted = false`) so the next keypress is instant.
            _ = prepareCaptureGraphOnControlQueue(microphoneUID: desiredUID, trigger: reason)
        }
    }

    // MARK: - Internal AVCaptureSession Control & Reuse

    private func scheduleStandbyPause(token: Int, duration: TimeInterval) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldStopRunning = self.state.withLock { s -> Bool in
                    if s.mode == .warmStandby && !s.alwaysOnEnabled && s.standbyToken == token {
                        s.mode = .idle
                        s.preRoll.resetAll()
                        s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                        s.activation.reset(captureGeneration: s.captureGeneration, startedAt: CFAbsoluteTimeGetCurrent())
                        return true
                    }
                    return false
                }
                if shouldStopRunning {
                    // Stop capture (turns off macOS mic indicator) but retain the prewarmed AVCaptureSession graph!
                    self.stopRunningKeepingGraphOnControlQueue()
                }
            }
            self.standbyTimer = work
            self.controlQueue.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    /// Builds (or verifies reuse of) the `AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureAudioDataOutput` graph
    /// on `controlQueue` WITHOUT starting capture (`captureStarted = false`).
    @discardableResult
    private func prepareCaptureGraphOnControlQueue(microphoneUID: String, trigger: String) -> Error? {
        NSLog("[VoicePrewarm] inventory_query_requested trigger=%@", trigger)

        guard let device = Self.resolveCaptureDevice(uid: microphoneUID) else {
            NSLog("[VoicePrewarm] skip reason=device_unavailable deviceUID=%@", microphoneUID)
            return NSError(domain: "VoiceAudioRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "未找到可用的麦克风输入设备"
            ])
        }

        // Reuse existing capture graph if already bound to the exact same connected device
        if captureSession != nil,
           preparedDeviceUID == device.uniqueID,
           captureInput?.device.isConnected == true {
            preparedDesiredMicUID = microphoneUID
            return nil
        }

        teardownSessionOnControlQueue()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            NSLog("[VoicePrewarm] input_creation_failed deviceUID=%@ error=%@", device.uniqueID, error.localizedDescription)
            return NSError(domain: "VoiceAudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无法打开麦克风设备：\(error.localizedDescription)"
            ])
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(VoicePreRollBuffer.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: sampleBufferQueue)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return NSError(domain: "VoiceAudioRecorder", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "无法连接麦克风采集输入"
            ])
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return NSError(domain: "VoiceAudioRecorder", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "无法连接音频采集输出"
            ])
        }
        session.addOutput(output)
        session.commitConfiguration()

        sampleBufferQueue.sync {
            self.fallbackDownmixer.reset()
            self.fallbackResampler = nil
            self.fallbackSourceRate = 0
            self.fallbackMonoScratch.removeAll(keepingCapacity: true)
            self.fallbackResampledScratch.removeAll(keepingCapacity: true)
            self.fastInt16Scratch.removeAll(keepingCapacity: true)
        }

        captureSession = session
        captureInput = input
        captureOutput = output
        preparedDeviceUID = device.uniqueID
        preparedDesiredMicUID = microphoneUID

        let isBT = Self.isBluetoothDevice(device)
        NSLog(
            "[VoicePrewarm] preparation_complete captureStarted=false mixerInitializedNow=1 trigger=%@ deviceUID=%@ bluetooth=%d",
            trigger,
            device.uniqueID,
            isBT ? 1 : 0
        )
        let isCurrentlyIdle = state.withLock { $0.mode == .idle && !$0.alwaysOnEnabled }
        if isCurrentlyIdle {
            scheduleGraphTeardownOnControlQueue()
        }
        return nil
    }

    @discardableResult
    private func ensureCaptureRunningOnControlQueue(microphoneUID: String, trigger: String) -> Error? {
        graphTeardownTimer?.cancel()
        graphTeardownTimer = nil
        if let err = prepareCaptureGraphOnControlQueue(microphoneUID: microphoneUID, trigger: trigger) {
            return err
        }
        guard let session = captureSession else {
            return NSError(domain: "VoiceAudioRecorder", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "音频采集会话未就绪"
            ])
        }

        if !session.isRunning {
            let startT0 = CFAbsoluteTimeGetCurrent()
            state.withLock { s in
                s.rawFrameAccumulator.removeAll(keepingCapacity: true)
                s.activation.reset(captureGeneration: s.captureGeneration, startedAt: startT0)
            }
            session.startRunning()
            let startMs = (CFAbsoluteTimeGetCurrent() - startT0) * 1000.0
            NSLog(
                "[AVCaptureSessionAudioRecorder] session_start_running trigger=%@ running=%d startRunningMs=%.1f",
                trigger,
                session.isRunning ? 1 : 0,
                startMs
            )
            if !session.isRunning {
                return NSError(domain: "VoiceAudioRecorder", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "麦克风采集启动失败，请检查麦克风连接或权限"
                ])
            }
        }
        return nil
    }

    /// Stops hardware capture (turns off macOS mic indicator) while retaining the prewarmed `AVCaptureSession` graph
    /// for 5 minutes; after 5 minutes of idle, tears down the graph and returns audio buffers to macOS.
    private func stopRunningKeepingGraphOnControlQueue() {
        if let session = captureSession, session.isRunning {
            session.stopRunning()
            NSLog("[AVCaptureSessionAudioRecorder] session_stopped_graph_retained deviceUID=%@", preparedDeviceUID ?? "")
        }
        scheduleGraphTeardownOnControlQueue()
    }

    private func scheduleGraphTeardownOnControlQueue(duration: TimeInterval = defaultGraphTeardownDuration) {
        graphTeardownTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldTeardown = self.state.withLock { $0.mode == .idle && !$0.alwaysOnEnabled }
            guard shouldTeardown, self.captureSession != nil else { return }
            self.teardownSessionOnControlQueue()
            NSLog("[AVCaptureSessionAudioRecorder] idle_graph_torn_down_for_memory")
            MemoryPressureManager.shared.trimNow(reason: "voice_graph_teardown")
        }
        graphTeardownTimer = work
        controlQueue.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Completely tears down the `AVCaptureSession` (used on device switch, 5-min idle, sleep, or shutdown).
    private func teardownSessionOnControlQueue() {
        graphTeardownTimer?.cancel()
        graphTeardownTimer = nil
        if let output = captureOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
        }
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            session.commitConfiguration()
        }
        captureSession = nil
        captureInput = nil
        captureOutput = nil
        preparedDeviceUID = nil
        preparedDesiredMicUID = nil
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (runs on sampleBufferQueue)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee

        var bufferListSizeNeeded: Int = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard queryStatus == noErr, bufferListSizeNeeded > 0 else { return }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }

        let ablPtr = rawABL.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlock: CMBlockBuffer?
        let copyStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )
        guard copyStatus == noErr else { return }

        withExtendedLifetime(retainedBlock) {
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0

            // Fast path: AVCaptureAudioDataOutput mixer delivered 16kHz / Mono / Int16 directly
            if asbd.mFormatID == kAudioFormatLinearPCM,
               !isFloat, !isBigEndian,
               asbd.mBitsPerChannel == 16,
               asbd.mChannelsPerFrame == 1,
               abs(asbd.mSampleRate - Double(VoicePreRollBuffer.sampleRate)) < 1.0 {
                let list = UnsafeMutableAudioBufferListPointer(ablPtr)
                guard let first = list.first, let dataPtr = first.mData, first.mDataByteSize >= 2 else { return }
                let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Int16>.size
                let typed = dataPtr.assumingMemoryBound(to: Int16.self)
                fastInt16Scratch.removeAll(keepingCapacity: true)
                fastInt16Scratch.append(contentsOf: UnsafeBufferPointer(start: typed, count: sampleCount))
                handle16kInt16Samples(fastInt16Scratch)
                return
            }

            // Fallback path: hardware/virtual mic delivered native format (e.g. 48kHz Float32 / stereo)
            fallbackDownmixer.extractMonoFloats(from: UnsafePointer(ablPtr), format: asbd, into: &fallbackMonoScratch)
            guard !fallbackMonoScratch.isEmpty else { return }
            if fallbackResampler == nil || abs(fallbackSourceRate - asbd.mSampleRate) >= 1.0 {
                fallbackSourceRate = asbd.mSampleRate
                fallbackResampler = MemoryAudioConverterResampler(sourceSampleRate: asbd.mSampleRate)
            }
            fallbackResampledScratch.removeAll(keepingCapacity: true)
            fallbackResampler?.process(fallbackMonoScratch, into: &fallbackResampledScratch)
            guard !fallbackResampledScratch.isEmpty else { return }
            handle16kInt16Samples(fallbackResampledScratch)
        }
    }

    private func handle16kInt16Samples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()

        let (readyGenToNotify, latestLevelToNotify, logsToEmit): (Int?, Float?, [String]) = state.withLock { s in
            guard s.mode != .idle else { return (nil, nil, []) }

            var readyGen: Int?
            var latestLevel: Float?
            var logs: [String] = []

            s.rawFrameAccumulator.append(contentsOf: samples)
            while s.rawFrameAccumulator.count >= Self.frameSamples {
                let frame = Array(s.rawFrameAccumulator.prefix(Self.frameSamples))
                s.rawFrameAccumulator.removeFirst(Self.frameSamples)

                let step = s.activation.consume(frame: frame, now: now)
                if let log = step.eventLog {
                    logs.append(log)
                }
                if step.justConfirmed && s.mode == .capturing {
                    readyGen = s.captureGeneration
                }

                switch s.mode {
                case .capturing:
                    // Drop leading all-zero DMA warmup frames until first non-zero PCM (or timeout) confirms activation
                    if step.shouldDropFrame {
                        continue
                    }
                    latestLevel = Self.computeLevel(frame)
                    let readyFrames = s.preRoll.appendCaptureSamples(frame)
                    for readyFrame in readyFrames {
                        for session in s.liveSessions {
                            session.push(pcm16: readyFrame)
                        }
                    }
                case .preRolling:
                    if !step.shouldDropFrame {
                        s.preRoll.appendRolling(frame, maxSamples: VoicePreRollBuffer.maxHoldPreRollSamples)
                    }
                case .warmStandby:
                    if !step.shouldDropFrame {
                        s.preRoll.appendRolling(frame, maxSamples: VoicePreRollBuffer.beginPaddingSamples)
                    }
                case .idle:
                    break
                }
            }
            return (readyGen, latestLevel, logs)
        }

        for log in logsToEmit {
            NSLog("%@", log)
        }
        if let gen = readyGenToNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onMicReady?(gen)
            }
        }
        if let lvl = latestLevelToNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(lvl)
            }
        }
    }

    // MARK: - Device Discovery & Bluetooth Helpers

    private static func resolveCaptureDevice(uid: String) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices

        if !uid.isEmpty, let matched = devices.first(where: { $0.uniqueID == uid && $0.isConnected }) {
            return matched
        }
        if let defaultDev = AVCaptureDevice.default(for: .audio), defaultDev.isConnected {
            return defaultDev
        }
        return devices.first(where: { $0.isConnected })
    }

    private static func isBluetoothDevice(_ device: AVCaptureDevice) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = device.uniqueID as CFString
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                UInt32(MemoryLayout<CFString>.size),
                ptr,
                &size,
                &devID
            )
        }
        if status == noErr, devID != kAudioObjectUnknown {
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(devID, &transportAddr, 0, nil, &tSize, &transport) == noErr {
                return transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE
            }
        }
        let lower = device.localizedName.lowercased()
        return lower.contains("airpods") || lower.contains("bluetooth") || lower.contains("beats")
    }

    static func computeLevel(_ frame: [Int16]) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        let rms = (sum / Float(frame.count)).squareRoot() / 32768.0
        let db = 20.0 * log10(max(rms, 1e-6))
        return min(max((db + 50.0) / 40.0, 0), 1)
    }
}

/// Live incremental typer fallback when InputType is not the active IMK input source (e.g. user is on ABC layout)
private final class VoiceStreamTyper {
    private var typed: [Character] = []
    private var done = false
    private let source = CGEventSource(stateID: .privateState)

    var hasTyped: Bool { !typed.isEmpty }

    func update(_ text: String) {
        guard !done else { return }
        let next = Array(text)
        var common = 0
        while common < typed.count, common < next.count, typed[common] == next[common] {
            common += 1
        }
        for _ in common..<typed.count {
            postKey(51, nil)
        }
        let tail = String(next[common...])
        if !tail.isEmpty {
            let units = Array(tail.utf16)
            for i in stride(from: 0, to: units.count, by: 20) {
                let end = min(i + 20, units.count)
                postKey(0, Array(units[i..<end]))
            }
        }
        typed = next
    }

    func clear() {
        guard !done else { return }
        for _ in 0..<typed.count {
            postKey(51, nil)
        }
        typed.removeAll()
        done = true
    }

    func finish() {
        done = true
    }

    private func postKey(_ code: CGKeyCode, _ unicode: [UniChar]?) {
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            e.flags = []
            if let unicode {
                e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            e.post(tap: .cghidEventTap)
        }
    }
}

final class VoiceInputManager: ObservableObject {
    static let shared = VoiceInputManager()
    static var isRecordingShortcut = false

    @Published private(set) var isRecording = false
    @Published private(set) var isMicReady = true
    @Published private(set) var isRecognizing = false
    @Published private(set) var isErrorState = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var liveText: String = ""
    @Published private(set) var statusText: String = ""
    @Published private(set) var activeChannel: VoiceCloudChannel = .doubao

    private let recorder = VoiceAudioRecorder()
    private let engineRegistry = VoiceASREngineRegistry.shared
    private let dataStore = VoiceDataStore.shared
    private let prewarmQueue = DispatchQueue(label: "com.lumocore.inputtype.voice.prewarm", qos: .utility)
    private var lastPrewarmByChannel: [VoiceCloudChannel: Date] = [:]
    private var activeSession: (any VoiceASRSession)?
    private var streamTyper: VoiceStreamTyper?
    private var usedIMKMarkedStreaming = false
    private var sessionGeneration: Int = 0
    private var autoStopOnSilence = false
    private var heardVoice = false
    private var lastVoiceTime = Date()
    private var recognitionTimeoutWork: DispatchWorkItem?
    private var targetAppBeforeVoice: NSRunningApplication?

    // Global & local modifier/hotkey monitors
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private var holdKeyDownCode: UInt16?
    private var holdKeyPressedAt = Date.distantPast
    private var holdTimer: Timer?
    private var holdTriggeredRecording = false
    private static let holdThreshold: TimeInterval = 0.14
    private var cachedMicAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private var lastFlagsStamp: (code: UInt16, rawFlags: UInt, timeMs: Int) = (0, 0, -1000)
    private var lastKeyDownStamp: (code: UInt16, timeMs: Int) = (0, -1000)

    private init() {
        // Ensure ~/Library/InputType/voice exists on initialization
        _ = dataStore.dataDirectoryURL

        recorder.onLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }
        recorder.onMicReady = { [weak self] gen in
            guard let self, self.sessionGeneration == gen, self.isRecording else { return }
            self.isMicReady = true
            self.lastVoiceTime = Date()
        }
        recorder.onStartError = { [weak self] gen, error in
            guard let self, self.sessionGeneration == gen, self.isRecording else { return }
            self.activeSession?.cancel()
            self.activeSession = nil
            self.showTransientFailure(error.localizedDescription)
        }
    }

    func shutdown() {
        cancelSession(silent: true)
        recorder.stopImmediately()
    }

    func startMonitors() {
        guard globalFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChangedEvent(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChangedEvent(event)
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyDownEvent(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDownEvent(event) == true {
                return nil
            }
            return event
        }

        // Warm up default cloud channel credentials & connection in the background shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.prewarmActiveChannels(force: true)
            self?.syncMicrophonePreference()
        }
    }

    func syncMicrophonePreference() {
        let settings = InputSettings.shared
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        cachedMicAuthStatus = status
        let authorized = (status == .authorized)
        recorder.setAlwaysOn(settings.voiceAlwaysOnMic && authorized, microphoneUID: settings.voiceMicrophoneUID)
    }

    func handleAlwaysOnSettingChanged(_ enabled: Bool) {
        if !enabled {
            recorder.setAlwaysOn(false, microphoneUID: InputSettings.shared.voiceMicrophoneUID)
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            recorder.setAlwaysOn(true, microphoneUID: InputSettings.shared.voiceMicrophoneUID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.syncMicrophonePreference()
                    } else {
                        InputSettings.shared.voiceAlwaysOnMic = false
                    }
                }
            }
        default:
            InputSettings.shared.voiceAlwaysOnMic = false
            showTransientFailure("请先在系统设置 → 隐私与安全性 → 麦克风中开启权限")
        }
    }

    // MARK: - Account Cookie Helpers

    func hasAccountCookie(for channel: VoiceCloudChannel) -> Bool {
        dataStore.hasCookie(for: channel)
    }

    @discardableResult
    func setAccountCookie(_ cookie: String, for channel: VoiceCloudChannel) -> Bool {
        dataStore.setCookie(cookie, for: channel)
    }

    func prewarm(channel: VoiceCloudChannel, force: Bool = false) {
        if channel.requiresAccountCookie && !hasAccountCookie(for: channel) {
            return
        }
        prewarmQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if !force, let last = self.lastPrewarmByChannel[channel], now.timeIntervalSince(last) < 25.0 {
                return
            }
            self.lastPrewarmByChannel[channel] = now
            self.engineRegistry.engine(for: channel).prewarm()
        }
    }

    func prewarmActiveChannels(force: Bool = false) {
        prewarm(channel: InputSettings.shared.voicePrimaryChannel, force: force)
    }

    // MARK: - Keyboard Event Handling (Both IMK & Global)

    func handleFlagsChangedEvent(_ event: NSEvent) {
        guard !Self.isRecordingShortcut else { return }

        let nowMs = Int(event.timestamp * 1000)
        let rawFlags = event.modifierFlags.intersection([.function, .command, .option, .control, .shift]).rawValue
        if event.keyCode == lastFlagsStamp.code && rawFlags == lastFlagsStamp.rawFlags && abs(nowMs - lastFlagsStamp.timeMs) < 20 {
            return
        }
        lastFlagsStamp = (event.keyCode, rawFlags, nowMs)

        let settings = InputSettings.shared
        let holdCode: UInt16? = settings.shortcutVoiceHold
            ? (VoiceShortcutFormatter.singleModifierKeyCode(for: settings.shortcutVoiceHoldKey)
                ?? (VoiceHoldKeyOption(rawValue: settings.shortcutVoiceHoldKey) ?? .fn).keyCode)
            : nil
        let tapModifierCode: UInt16? = settings.shortcutVoiceStart
            ? VoiceShortcutFormatter.singleModifierKeyCode(for: settings.shortcutVoiceStartKey)
            : nil

        guard holdCode != nil || tapModifierCode != nil else { return }

        let code = event.keyCode

        // If another modifier was pressed while waiting, cancel pending hold/tap
        if let downCode = holdKeyDownCode, code != downCode {
            if !holdTriggeredRecording {
                cancelPendingHold()
            }
            return
        }

        guard code == holdCode || code == tapModifierCode else { return }

        let isPressed = isHoldModifierPressed(code: code, flags: event.modifierFlags)
        if isPressed && holdKeyDownCode == nil {
            holdKeyDownCode = code
            holdKeyPressedAt = Date()
            holdTriggeredRecording = false
            prewarmActiveChannels()

            // Immediately wake up & pre-roll the microphone on key-down when idle, so USB/Bluetooth mics
            // are already capturing audio during the keypress and before release / hold threshold.
            if !isRecording && !isRecognizing,
               cachedMicAuthStatus == .authorized {
                recorder.startPreRoll(microphoneUID: settings.voiceMicrophoneUID)
            }

            if code == holdCode && !isRecording && !isRecognizing {
                holdTimer?.invalidate()
                // When the hold key is distinct from the tap key, use a snappy 120ms threshold;
                // when both share the same modifier key, use 170ms to distinguish tap vs hold.
                let threshold: TimeInterval = (holdCode == tapModifierCode) ? 0.17 : Self.holdThreshold
                let timer = Timer(timeInterval: threshold, repeats: false) { [weak self] _ in
                    guard let self, self.holdKeyDownCode == code else { return }
                    self.holdTriggeredRecording = true
                    if !self.isRecording && !self.isRecognizing {
                        self.startRecording(autoStopOnSilence: false)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                holdTimer = timer
            }
        } else if !isPressed && holdKeyDownCode == code {
            let elapsed = Date().timeIntervalSince(holdKeyPressedAt)
            holdKeyDownCode = nil
            holdTimer?.invalidate()
            holdTimer = nil
            let tapLimit: TimeInterval = (code == holdCode) ? 0.22 : 0.60
            if holdTriggeredRecording {
                holdTriggeredRecording = false
                if isRecording {
                    finishRecording()
                }
            } else if code == tapModifierCode && (isRecording || isRecognizing || elapsed < tapLimit) {
                toggleTapRecording()
            } else {
                recorder.cancelPreRoll()
            }
        }
    }

    @discardableResult
    func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        guard !Self.isRecordingShortcut else { return false }

        let nowMs = Int(event.timestamp * 1000)
        if event.keyCode == lastKeyDownStamp.code && abs(nowMs - lastKeyDownStamp.timeMs) < 20 {
            return isRecording
        }
        lastKeyDownStamp = (event.keyCode, nowMs)

        // Any non-modifier keyDown cancels a pending hold timer that hasn't triggered yet
        if holdKeyDownCode != nil && !holdTriggeredRecording {
            cancelPendingHold()
        }

        // Escape cancels active recording/recognizing
        if event.keyCode == 0x35 && (isRecording || isRecognizing) {
            cancelSession()
            return true
        }

        // Check tap-to-start/stop shortcut (default: fn + Space, or any custom recorded shortcut)
        let settings = InputSettings.shared
        if settings.shortcutVoiceStart && VoiceShortcutFormatter.matches(keyDown: event, spec: settings.shortcutVoiceStartKey) {
            toggleTapRecording()
            return true
        }

        // In tap-to-talk mode, pressing any key ends recording and finishes transcription
        if isRecording && !holdTriggeredRecording {
            finishRecording()
            return true
        }

        return false
    }

    private func isHoldModifierPressed(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 63: return flags.contains(.function)
        case 61, 58: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 62, 59: return flags.contains(.control)
        case 60, 56: return flags.contains(.shift)
        default: return false
        }
    }

    private func cancelPendingHold() {
        holdKeyDownCode = nil
        holdTriggeredRecording = false
        holdTimer?.invalidate()
        holdTimer = nil
        recorder.cancelPreRoll()
    }

    // MARK: - Recording & Recognition Lifecycle

    func toggleTapRecording() {
        if isRecording {
            finishRecording()
        } else if isRecognizing {
            cancelSession()
        } else {
            startRecording(autoStopOnSilence: InputSettings.shared.voiceSilenceAutoStop)
        }
    }

    func startRecording(autoStopOnSilence: Bool) {
        let authStatus = (cachedMicAuthStatus == .authorized)
            ? .authorized
            : AVCaptureDevice.authorizationStatus(for: .audio)
        cachedMicAuthStatus = authStatus
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cachedMicAuthStatus = granted ? .authorized : .denied
                    if granted {
                        self?.startRecording(autoStopOnSilence: autoStopOnSilence)
                    } else {
                        self?.showTransientFailure("未授予麦克风权限，请在系统设置中开启")
                    }
                }
            }
            return
        } else if authStatus == .denied || authStatus == .restricted {
            showTransientFailure("麦克风权限未开启，请前往系统设置 → 隐私与安全性 → 麦克风")
            return
        }

        let channel = InputSettings.shared.voicePrimaryChannel
        if channel.requiresAccountCookie && !hasAccountCookie(for: channel) {
            showTransientFailure("\(channel.displayName) 未配置登录 Cookie，请在设置 → 语音输入中配置")
            return
        }

        cancelSession(silent: true)

        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetAppBeforeVoice = front
        } else if let bid = InputTypeController.latestActiveBundleID {
            targetAppBeforeVoice = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }
        }

        sessionGeneration &+= 1
        let gen = sessionGeneration
        self.autoStopOnSilence = autoStopOnSilence
        self.heardVoice = false
        self.lastVoiceTime = Date()
        self.liveText = ""
        self.statusText = ""
        self.isErrorState = false
        self.audioLevel = 0
        self.usedIMKMarkedStreaming = false
        self.streamTyper = nil
        self.activeChannel = channel

        let engine = engineRegistry.engine(for: channel)
        guard let session = engine.start(sampleRate: 16000, onEvent: { [weak self] event in
            DispatchQueue.main.async {
                self?.handleSessionEvent(event, generation: gen)
            }
        }) else {
            showTransientFailure("语音识别会话初始化失败")
            return
        }
        self.activeSession = session

        let alreadyLive = recorder.startCapture(
            microphoneUID: InputSettings.shared.voiceMicrophoneUID,
            sessions: [session],
            generation: gen
        )

        self.isMicReady = alreadyLive
        self.isRecording = true
        self.isRecognizing = false

        // Show HUD first for 0ms instant visual feedback before playing sound or ducking volume
        VoiceHUDController.shared.show()
        VoiceSystemSoundPlayer.playCueIfEnabled(InputSettings.shared.voiceSoundStart)
        if InputSettings.shared.voiceDuckVolumeEnabled {
            VoiceSystemVolumeDucker.shared.duck(byPercent: InputSettings.shared.voiceDuckVolumePercent)
        }
    }

    func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        isMicReady = true
        isRecognizing = true
        autoStopOnSilence = false
        VoiceSystemVolumeDucker.shared.restoreIfNeeded()
        recorder.finishCaptureAndWarmStandby()
        audioLevel = 0
        VoiceSystemSoundPlayer.playCueIfEnabled(InputSettings.shared.voiceSoundStop)

        activeSession?.finish()
        statusText = "识别中…"
        VoiceHUDController.shared.updateLayout()

        scheduleRecognitionTimeout()
    }

    func cancelSession(silent: Bool = false) {
        recognitionTimeoutWork?.cancel()
        recognitionTimeoutWork = nil
        sessionGeneration &+= 1
        VoiceSystemVolumeDucker.shared.restoreIfNeeded()
        if isRecording {
            recorder.finishCaptureAndWarmStandby()
        }
        isRecording = false
        isMicReady = true
        isRecognizing = false
        isErrorState = false
        activeSession?.cancel()
        activeSession = nil
        audioLevel = 0
        liveText = ""
        statusText = ""
        clearStreamingPreviewIfNeeded()
        if !silent {
            VoiceHUDController.shared.hide()
        }
    }

    // MARK: - Event & Silence Processing

    private func handleAudioLevel(_ level: Float) {
        guard isRecording else { return }
        audioLevel = level

        guard isMicReady && autoStopOnSilence && InputSettings.shared.voiceSilenceAutoStop else { return }
        if level > 0.28 {
            heardVoice = true
            lastVoiceTime = Date()
        } else {
            let limit = heardVoice ? max(0.8, InputSettings.shared.voiceSilenceDuration) : 8.0
            if Date().timeIntervalSince(lastVoiceTime) >= limit {
                finishRecording()
            }
        }
    }

    private func handleSessionEvent(
        _ event: VoiceASREvent,
        generation: Int
    ) {
        guard generation == sessionGeneration else { return }

        switch event {
        case .partial(let text):
            guard !text.isEmpty else { return }
            liveText = text
            updateStreamingPreview(text)

        case .final(let text):
            recognitionTimeoutWork?.cancel()
            recognitionTimeoutWork = nil
            if isRecording {
                recorder.finishCaptureAndWarmStandby()
                isRecording = false
                isMicReady = true
            }
            isRecognizing = false
            activeSession = nil

            let finalText = text.isEmpty ? liveText : text
            liveText = ""
            if !finalText.isEmpty {
                VoiceHUDController.shared.hide()
                deliverFinalText(finalText)
            } else {
                clearStreamingPreviewIfNeeded()
                showTransientFailure("没有识别到语音内容", duration: 1.2)
            }

        case .error(let err):
            recognitionTimeoutWork?.cancel()
            recognitionTimeoutWork = nil
            if isRecording {
                recorder.finishCaptureAndWarmStandby()
                isRecording = false
                isMicReady = true
            }
            isRecognizing = false
            activeSession = nil

            let kept = liveText
            liveText = ""
            if !kept.isEmpty {
                deliverFinalText(kept)
                showTransientFailure("识别中断，已保留已识别文字", duration: 2.0)
            } else {
                clearStreamingPreviewIfNeeded()
                showTransientFailure(err.isEmpty ? "语音识别失败" : err, duration: 2.5)
            }
        }
    }

    private func scheduleRecognitionTimeout() {
        recognitionTimeoutWork?.cancel()
        let gen = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == gen else { return }
            let kept = self.liveText
            self.cancelSession(silent: true)
            if !kept.isEmpty {
                self.deliverFinalText(kept)
                self.showTransientFailure("识别超时，已保留已识别文字", duration: 2.0)
            } else {
                self.showTransientFailure("语音识别超时", duration: 2.0)
            }
        }
        recognitionTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: work)
    }

    private func showTransientFailure(_ message: String, duration: TimeInterval = 2.4) {
        activeChannel = InputSettings.shared.voicePrimaryChannel
        isErrorState = true
        statusText = message
        liveText = ""
        isRecording = false
        isRecognizing = false
        VoiceSystemSoundPlayer.playCueIfEnabled(InputSettings.shared.voiceSoundError)
        VoiceHUDController.shared.show()
        VoiceHUDController.shared.hide(after: duration)
    }

    // MARK: - Native IMK Streaming Preview & Commit

    private func updateStreamingPreview(_ text: String) {
        if let controller = InputTypeController.latestActiveController,
           controller.updateVoiceMarkedText(text) {
            usedIMKMarkedStreaming = true
            return
        }

        if ClipboardManager.shared.isAccessibilityTrusted {
            if streamTyper == nil {
                streamTyper = VoiceStreamTyper()
            }
            streamTyper?.update(text)
        }
    }

    private func clearStreamingPreviewIfNeeded() {
        if usedIMKMarkedStreaming {
            usedIMKMarkedStreaming = false
            InputTypeController.latestActiveController?.clearVoiceMarkedText()
        }
        if let typer = streamTyper {
            typer.clear()
            streamTyper = nil
        }
    }

    private func deliverFinalText(_ text: String) {
        guard !text.isEmpty else { return }

        // If incremental CGEvent StreamTyper was used during this session, finalize via diff update
        if let typer = streamTyper {
            streamTyper = nil
            usedIMKMarkedStreaming = false
            typer.update(text)
            typer.finish()
            return
        }

        // Path 1: Direct InputMethodKit commit (zero permissions required, automatically replaces marked preview)
        if let controller = InputTypeController.latestActiveController,
           controller.insertClipboardTextDirectly(text) {
            usedIMKMarkedStreaming = false
            return
        }

        usedIMKMarkedStreaming = false

        // Path 2: Arm pending IMK text paste & activate target app (or fallback to Clipboard + Cmd+V)
        let entry = ClipboardEntry(kind: .text, text: text, byteSize: text.utf8.count)
        ClipboardManager.shared.pasteEntry(entry, into: targetAppBeforeVoice)
    }
}

private final class VoiceSystemVolumeDucker {
    static let shared = VoiceSystemVolumeDucker()

    private let queue = DispatchQueue(label: "com.lumocore.inputtype.voice.ducker", qos: .userInitiated)
    private var savedDeviceID: AudioDeviceID?
    private var savedVolume: Float32?

    private init() {}

    func duck(byPercent percent: Double) {
        queue.async { [weak self] in
            guard let self, self.savedVolume == nil else { return }
            guard let deviceID = self.defaultOutputDeviceID(),
                  let current = self.readOutputVolume(deviceID: deviceID) else {
                return
            }
            let clamped = max(0.0, min(100.0, percent))
            let target = Float32(max(0.0, min(1.0, Double(current) * (1.0 - clamped / 100.0))))
            self.savedDeviceID = deviceID
            self.savedVolume = current
            _ = self.writeOutputVolume(deviceID: deviceID, volume: target)
        }
    }

    func restoreIfNeeded() {
        queue.async { [weak self] in
            guard let self, let deviceID = self.savedDeviceID, let volume = self.savedVolume else { return }
            self.savedDeviceID = nil
            self.savedVolume = nil
            _ = self.writeOutputVolume(deviceID: deviceID, volume: volume)
        }
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func readOutputVolume(deviceID: AudioDeviceID) -> Float32? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddr),
           AudioObjectGetPropertyData(deviceID, &virtualAddr, 0, nil, &size, &volume) == noErr {
            return volume
        }

        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &scalarAddr),
           AudioObjectGetPropertyData(deviceID, &scalarAddr, 0, nil, &size, &volume) == noErr {
            return volume
        }
        return nil
    }

    @discardableResult
    private func writeOutputVolume(deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var v = max(Float32(0), min(Float32(1), volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddr),
           AudioObjectSetPropertyData(deviceID, &virtualAddr, 0, nil, size, &v) == noErr {
            return true
        }

        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &scalarAddr),
           AudioObjectSetPropertyData(deviceID, &scalarAddr, 0, nil, size, &v) == noErr {
            return true
        }
        return false
    }
}
