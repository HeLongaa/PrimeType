import Cocoa
import Carbon
import AVFoundation
import AudioToolbox
import CoreAudio
import os

enum VoiceSystemSoundPlayer {
    private static let fallbackSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private static let soundCache = OSAllocatedUnfairLock(initialState: [String: SystemSoundID]())

    static func availableSystemSounds() -> [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return fallbackSoundNames
        }
        let names = items
            .filter { ["aiff", "aif", "wav", "caf", "m4a"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names.isEmpty ? fallbackSoundNames : names
    }

    static func play(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let id = systemSoundID(for: trimmed) {
            AudioServicesPlaySystemSound(id)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async {
            if let named = NSSound(named: NSSound.Name(trimmed)) {
                named.play()
            }
        }
    }

    static func playCueIfEnabled(_ soundName: String) {
        guard InputSettings.shared.voiceSoundEnabled, !soundName.isEmpty else { return }
        play(named: soundName)
    }

    private static func systemSoundID(for name: String) -> SystemSoundID? {
        if let cached = soundCache.withLock({ $0[name] }) {
            return cached
        }
        let exts = ["aiff", "aif", "wav", "caf", "m4a"]
        for ext in exts {
            let path = "/System/Library/Sounds/\(name).\(ext)"
            if FileManager.default.fileExists(atPath: path) {
                var sid: SystemSoundID = 0
                let url = URL(fileURLWithPath: path) as CFURL
                if AudioServicesCreateSystemSoundID(url, &sid) == kAudioServicesNoError, sid != 0 {
                    soundCache.withLock { $0[name] = sid }
                    return sid
                }
            }
        }
        return nil
    }
}

enum VoiceShortcutFormatter {
    static let singleModifierKeyCodes: [UInt16: String] = [
        63: "fn",
        54: "右 ⌘",
        55: "左 ⌘",
        61: "右 ⌥",
        58: "左 ⌥",
        62: "右 ⌃",
        59: "左 ⌃",
        60: "右 ⇧",
        56: "左 ⇧"
    ]

    static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F
    ]

    static let keyLabels: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↵", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
        0x31: "空格", 0x32: "`", 0x33: "⌫",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
    ]

    static func format(keyDown event: NSEvent) -> String? {
        guard singleModifierKeyCodes[event.keyCode] == nil else { return nil }
        guard let baseLabel = keyLabels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(),
              !baseLabel.isEmpty else {
            return nil
        }

        let flags = event.modifierFlags.intersection([.function, .control, .option, .shift, .command])
        let isFnKey = functionKeyCodes.contains(event.keyCode)
        guard !flags.isEmpty || isFnKey else { return nil }

        var parts: [String] = []
        if flags.contains(.function) && !isFnKey { parts.append("fn") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(baseLabel)
        return parts.joined(separator: " ")
    }

    static func singleModifierKeyCode(for spec: String) -> UInt16? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for (code, label) in singleModifierKeyCodes {
            if label.caseInsensitiveCompare(trimmed) == .orderedSame {
                return code
            }
        }
        return nil
    }

    static func matches(keyDown event: NSEvent, spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, singleModifierKeyCode(for: trimmed) == nil else { return false }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let keyToken = tokens.last else { return false }
        let modTokens = Set(tokens.dropLast().map { $0.lowercased() })

        let expectedFn = modTokens.contains("fn")
        let expectedCtrl = modTokens.contains("⌃") || modTokens.contains("ctrl") || modTokens.contains("control")
        let expectedOpt = modTokens.contains("⌥") || modTokens.contains("opt") || modTokens.contains("option")
        let expectedShift = modTokens.contains("⇧") || modTokens.contains("shift")
        let expectedCmd = modTokens.contains("⌘") || modTokens.contains("cmd") || modTokens.contains("command")

        let isFnKey = functionKeyCodes.contains(event.keyCode)
        let flags = event.modifierFlags
        guard (flags.contains(.function) && !isFnKey) == expectedFn,
              flags.contains(.control) == expectedCtrl,
              flags.contains(.option) == expectedOpt,
              flags.contains(.shift) == expectedShift,
              flags.contains(.command) == expectedCmd else {
            return false
        }

        let eventLabel = keyLabels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        if eventLabel.caseInsensitiveCompare(keyToken) == .orderedSame {
            return true
        }
        if (keyToken.lowercased() == "space" || keyToken == "空格") && event.keyCode == 0x31 {
            return true
        }
        return false
    }

    /// Converts a modifier+key spec (without `fn`) into a Carbon `HotKeyConfig` for global registration
    static func carbonHotKeyConfig(for spec: String) -> HotKeyConfig? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, singleModifierKeyCode(for: trimmed) == nil else { return nil }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let keyToken = tokens.last else { return nil }
        let modTokens = Set(tokens.dropLast().map { $0.lowercased() })
        // Carbon RegisterEventHotKey doesn't support `fn` modifier
        if modTokens.contains("fn") { return nil }

        guard let keyCode = keyLabels.first(where: { $0.value.caseInsensitiveCompare(keyToken) == .orderedSame })?.key else {
            return nil
        }

        var carbon: UInt32 = 0
        if modTokens.contains("⌃") || modTokens.contains("ctrl") { carbon |= UInt32(controlKey) }
        if modTokens.contains("⌥") || modTokens.contains("opt") { carbon |= UInt32(optionKey) }
        if modTokens.contains("⇧") || modTokens.contains("shift") { carbon |= UInt32(shiftKey) }
        if modTokens.contains("⌘") || modTokens.contains("cmd") { carbon |= UInt32(cmdKey) }

        guard carbon != 0 || functionKeyCodes.contains(keyCode) else { return nil }
        return HotKeyConfig(keyCode: UInt32(keyCode), carbonModifiers: carbon)
    }
}

struct VoiceMicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID

    static func all() -> [VoiceMicrophoneDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = copyStringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("CADefaultDeviceAggregate"),
                  let name = copyStringProperty(id, kAudioObjectPropertyName) else {
                return nil
            }
            return VoiceMicrophoneDevice(id: uid, name: name, deviceID: id)
        }
    }

    static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        inputChannelCount(id) > 0
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func copyStringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
}

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

/// Low-latency CoreAudio HAL input recorder.
/// - Opens the target AudioDeviceID directly at its native hardware sample rate (bypassing default Bluetooth handoff)
/// - Dispatches off CoreAudio's RT thread via HAL's serial dispatch queue + `OSAllocatedUnfairLock`
/// - Uses adaptive multi-channel downmix + Apple `AudioConverterFillComplexBuffer` high-quality anti-aliasing resampling
/// - Handles USB hot-unplug/replug, system default device changes, external sample-rate changes, and Mac sleep/wake.
private final class VoiceAudioRecorder {
    static let frameSamples = 320 // 20ms @ 16kHz
    static let defaultWarmStandbyDuration: TimeInterval = 8.0
    private static let leadingSilenceFrameCount = 6 // 120ms leading silence for cloud ASR VAD stability
    private static let maxPreRollFrames = 30 // up to 600ms during keypress pre-roll
    private static let maxStandbyFrames = 12 // keep last 240ms rolling during warm standby / always-on
    private static let maxZeroWarmupFrames = 15 // fallback 300ms if mic is hardware-muted / ultra-quiet

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
        var pending: [Int16] = []
        var preRollFrames: [[Int16]] = []
        var liveSessions: [any VoiceASRSession] = []
        var hasSeenLiveAudio = false
        var warmupFrameCount = 0
        var standbyToken: Int = 0
        var captureGeneration: Int = 0
    }

    private let audioCallbackQueue = DispatchQueue(label: "com.lumocore.inputtype.voice.hal.callback", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.lumocore.inputtype.voice.hal.control", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: SharedState())

    // Owned exclusively by controlQueue
    private var activeDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var activeIOProcID: AudioDeviceIOProcID?
    private var activeMicUID: String?
    private var standbyTimer: DispatchWorkItem?
    private var wakeRestoreWorkItem: DispatchWorkItem?

    // Per-device CoreAudio listeners (registered/removed on controlQueue)
    private var aliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var streamFormatListenerBlock: AudioObjectPropertyListenerBlock?

    // System-wide CoreAudio & Sleep/Wake listeners
    private var devicesListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Owned exclusively by audioCallbackQueue (reconfigured via audioCallbackQueue.sync before starting/updating)
    private var activeStreamFormat = AudioStreamBasicDescription()
    private var downmixer = SmartChannelDownmixer()
    private var resampler = MemoryAudioConverterResampler(sourceSampleRate: 48000.0)
    private var monoScratch: [Float] = []
    private var resampledScratch: [Int16] = []

    var onLevel: ((Float) -> Void)?
    var onMicReady: ((Int) -> Void)?
    var onStartError: ((Int, Error) -> Void)?

    init() {
        monoScratch.reserveCapacity(2048)
        resampledScratch.reserveCapacity(1024)
        installSystemListeners()
    }

    deinit {
        removeSystemListeners()
    }

    /// Configures optional always-on low-power standby (0ms instant start) or switches standby device.
    func setAlwaysOn(_ enabled: Bool, microphoneUID: String) {
        enum Action {
            case none
            case startOrSwitchWarm
            case stopStandby
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
                    s.pending.removeAll(keepingCapacity: true)
                    s.preRollFrames.removeAll(keepingCapacity: true)
                    s.hasSeenLiveAudio = false
                    s.warmupFrameCount = 0
                    return .startOrSwitchWarm
                case .warmStandby:
                    if deviceChanged {
                        s.desiredMicUID = microphoneUID
                        s.pending.removeAll(keepingCapacity: true)
                        s.preRollFrames.removeAll(keepingCapacity: true)
                        s.hasSeenLiveAudio = false
                        s.warmupFrameCount = 0
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
                    s.pending.removeAll(keepingCapacity: true)
                    s.preRollFrames.removeAll(keepingCapacity: true)
                    s.hasSeenLiveAudio = false
                    s.warmupFrameCount = 0
                    return .stopStandby
                case .idle, .preRolling, .capturing:
                    if deviceChanged && s.mode == .idle {
                        s.desiredMicUID = microphoneUID
                    }
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
                    _ = self.ensureHALRunningOnControlQueue(microphoneUID: microphoneUID)
                }
            }
        case .stopStandby:
            controlQueue.async { [weak self] in
                guard let self else { return }
                self.standbyTimer?.cancel()
                self.standbyTimer = nil
                let stillIdle = self.state.withLock { $0.mode == .idle }
                if stillIdle {
                    self.stopAndDisposeOnControlQueue()
                }
            }
        }
    }

    /// Begins warming up the microphone immediately on key-down and buffering frames into memory.
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
                s.preRollFrames.removeAll(keepingCapacity: true)
                s.hasSeenLiveAudio = false
                s.warmupFrameCount = 0
                return true
            case .warmStandby:
                s.standbyToken &+= 1
                s.mode = .preRolling
                s.startedForPreRoll = false
                if s.desiredMicUID != microphoneUID {
                    s.desiredMicUID = microphoneUID
                    s.preRollFrames.removeAll(keepingCapacity: true)
                    s.hasSeenLiveAudio = false
                    s.warmupFrameCount = 0
                    return true
                }
                return false
            case .idle:
                s.standbyToken &+= 1
                s.mode = .preRolling
                s.startedForPreRoll = true
                s.desiredMicUID = microphoneUID
                s.pending.removeAll(keepingCapacity: true)
                s.preRollFrames.removeAll(keepingCapacity: true)
                s.hasSeenLiveAudio = false
                s.warmupFrameCount = 0
                return true
            }
        }

        guard let shouldStartDevice else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            if shouldStartDevice || self.activeIOProcID == nil || self.activeMicUID != microphoneUID {
                _ = self.ensureHALRunningOnControlQueue(microphoneUID: microphoneUID)
            }
        }
    }

    /// Cancels a pending key-down pre-roll (e.g. user pressed Right-Cmd + C).
    func cancelPreRoll(warmStandbyDuration: TimeInterval = defaultWarmStandbyDuration) {
        let decision: (action: Int, token: Int, keepForever: Bool) = state.withLock { s in
            guard s.mode == .preRolling else { return (0, 0, false) }
            if s.startedForPreRoll && !s.alwaysOnEnabled {
                s.mode = .idle
                s.startedForPreRoll = false
                s.pending.removeAll(keepingCapacity: true)
                s.preRollFrames.removeAll(keepingCapacity: true)
                s.hasSeenLiveAudio = false
                s.warmupFrameCount = 0
                return (1, s.standbyToken, false)
            } else {
                s.standbyToken &+= 1
                s.mode = .warmStandby
                s.startedForPreRoll = false
                Self.trimPreRoll(&s.preRollFrames, limit: Self.maxStandbyFrames)
                return (2, s.standbyToken, s.alwaysOnEnabled)
            }
        }

        if decision.action == 1 {
            controlQueue.async { [weak self] in
                guard let self else { return }
                let stillIdle = self.state.withLock { $0.mode == .idle }
                if stillIdle {
                    self.stopAndDisposeOnControlQueue()
                }
            }
        } else if decision.action == 2 && !decision.keepForever {
            scheduleStandbyDispose(token: decision.token, duration: warmStandbyDuration)
        }
    }

    /// Transitions into active capture, atomically injecting leading silence + pre-roll frames before live streaming.
    /// Returns whether the microphone is already producing live audio frames (true => 0ms warm start).
    func startCapture(
        microphoneUID: String,
        sessions: [any VoiceASRSession],
        generation: Int
    ) -> Bool {
        let (alreadyLive, needDeviceSwitch): (Bool, Bool) = state.withLock { s in
            s.standbyToken &+= 1
            s.captureGeneration = generation
            s.startedForPreRoll = false

            let sameDevice = (s.desiredMicUID == microphoneUID)
            let wasRunning = (s.mode == .preRolling || s.mode == .warmStandby) && sameDevice
            let switchNeeded = !wasRunning

            if !sameDevice {
                s.desiredMicUID = microphoneUID
                s.pending.removeAll(keepingCapacity: true)
                s.preRollFrames.removeAll(keepingCapacity: true)
                s.hasSeenLiveAudio = false
                s.warmupFrameCount = 0
            }

            // 1. Inject 120ms leading silence so cloud ASR frontend VAD stabilizes cleanly without clipping first syllable
            let silenceFrame = [Int16](repeating: 0, count: Self.frameSamples)
            for _ in 0..<Self.leadingSilenceFrameCount {
                for session in sessions {
                    session.push(pcm16: silenceFrame)
                }
            }

            // 2. Flush any pre-roll audio already captured on the same device (skipping pure-zero DMA warmup frames)
            if wasRunning && !s.preRollFrames.isEmpty {
                let framesToFlush = Self.trimLeadingAllZeroFrames(s.preRollFrames)
                for frame in framesToFlush {
                    for session in sessions {
                        session.push(pcm16: frame)
                    }
                }
                s.preRollFrames.removeAll(keepingCapacity: true)
            } else {
                s.preRollFrames.removeAll(keepingCapacity: true)
            }

            // 3. Atomically attach live sessions so the very next callback streams with zero gap
            s.liveSessions = sessions
            s.mode = .capturing
            return (wasRunning && s.hasSeenLiveAudio, switchNeeded)
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil

            let stillThisCapture = self.state.withLock {
                $0.mode == .capturing && $0.captureGeneration == generation
            }
            guard stillThisCapture else { return }

            if needDeviceSwitch || self.activeIOProcID == nil || self.activeMicUID != microphoneUID {
                if let err = self.ensureHALRunningOnControlQueue(microphoneUID: microphoneUID) {
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

    /// Flushes any trailing partial frame to the active sessions, detaches them, and keeps the microphone warm briefly (8s by default, or indefinitely when always-on is enabled).
    func finishCaptureAndWarmStandby(duration: TimeInterval = defaultWarmStandbyDuration) {
        let result: (didFinish: Bool, token: Int, keepForever: Bool) = state.withLock { s in
            guard s.mode == .capturing else {
                s.liveSessions.removeAll()
                return (false, 0, false)
            }
            if !s.pending.isEmpty && !s.liveSessions.isEmpty {
                let padded = s.pending + [Int16](repeating: 0, count: max(0, Self.frameSamples - s.pending.count))
                for session in s.liveSessions {
                    session.push(pcm16: padded)
                }
                s.pending.removeAll(keepingCapacity: true)
            }
            s.liveSessions.removeAll()
            s.standbyToken &+= 1
            s.mode = .warmStandby
            s.preRollFrames.removeAll(keepingCapacity: true)
            return (true, s.standbyToken, s.alwaysOnEnabled)
        }

        if result.didFinish && !result.keepForever {
            scheduleStandbyDispose(token: result.token, duration: duration)
        }
    }

    /// Stops immediately and releases the CoreAudio HAL IOProc (used on app termination).
    func stopImmediately() {
        state.withLock { s in
            s.alwaysOnEnabled = false
            s.standbyToken &+= 1
            s.mode = .idle
            s.startedForPreRoll = false
            s.pending.removeAll()
            s.preRollFrames.removeAll()
            s.liveSessions.removeAll()
            s.hasSeenLiveAudio = false
            s.warmupFrameCount = 0
        }

        controlQueue.sync {
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            self.wakeRestoreWorkItem?.cancel()
            self.wakeRestoreWorkItem = nil
            self.stopAndDisposeOnControlQueue()
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
            self?.handleHardwareTopologyChangedOnControlQueue()
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
            self?.handleHardwareTopologyChangedOnControlQueue()
        }
        if AudioObjectAddPropertyListenerBlock(systemObj, &defaultInAddr, controlQueue, defaultInBlock) == noErr {
            defaultInputListenerBlock = defaultInBlock
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
            s.pending.removeAll(keepingCapacity: true)
            s.preRollFrames.removeAll(keepingCapacity: true)
            s.hasSeenLiveAudio = false
            s.warmupFrameCount = 0
        }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            self.standbyTimer = nil
            self.wakeRestoreWorkItem?.cancel()
            self.wakeRestoreWorkItem = nil
            self.stopAndDisposeOnControlQueue()
        }
    }

    private func handleSystemDidWake() {
        let (shouldRestore, micUID): (Bool, String) = state.withLock { s in
            s.isSystemSleeping = false
            return (s.alwaysOnEnabled && s.mode == .idle, s.desiredMicUID)
        }
        guard shouldRestore else { return }

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.wakeRestoreWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let (stillNeed, uid): (Bool, String) = self.state.withLock { s in
                    guard s.alwaysOnEnabled && !s.isSystemSleeping && s.mode == .idle else {
                        return (false, "")
                    }
                    s.mode = .warmStandby
                    s.pending.removeAll(keepingCapacity: true)
                    s.preRollFrames.removeAll(keepingCapacity: true)
                    s.hasSeenLiveAudio = false
                    s.warmupFrameCount = 0
                    return (true, s.desiredMicUID)
                }
                if stillNeed {
                    _ = self.ensureHALRunningOnControlQueue(microphoneUID: uid)
                }
            }
            self.wakeRestoreWorkItem = work
            // Give USB / CoreAudio ~1.0s after Mac wake to finish re-enumerating audio interfaces
            self.controlQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    private func handleHardwareTopologyChangedOnControlQueue() {
        let (isActive, desiredUID): (Bool, String) = state.withLock { s in
            (s.mode != .idle && !s.isSystemSleeping, s.desiredMicUID)
        }
        guard isActive else { return }

        guard let resolvedID = Self.resolveInputDevice(uid: desiredUID) else {
            stopAndDisposeOnControlQueue()
            return
        }

        // Automatically reconnect when preferred USB mic is plugged back in,
        // or switch seamlessly when the active device was unplugged / default input changed.
        if resolvedID != activeDeviceID || activeIOProcID == nil {
            state.withLock { s in
                s.pending.removeAll(keepingCapacity: true)
                s.preRollFrames.removeAll(keepingCapacity: true)
                s.hasSeenLiveAudio = false
                s.warmupFrameCount = 0
            }
            _ = ensureHALRunningOnControlQueue(microphoneUID: desiredUID)
        }
    }

    // MARK: - Internal CoreAudio HAL Control & Processing

    private func scheduleStandbyDispose(token: Int, duration: TimeInterval) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.standbyTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldDispose = self.state.withLock { s -> Bool in
                    if s.mode == .warmStandby && !s.alwaysOnEnabled && s.standbyToken == token {
                        s.mode = .idle
                        s.pending.removeAll(keepingCapacity: true)
                        s.preRollFrames.removeAll(keepingCapacity: true)
                        s.hasSeenLiveAudio = false
                        s.warmupFrameCount = 0
                        return true
                    }
                    return false
                }
                if shouldDispose {
                    self.stopAndDisposeOnControlQueue()
                }
            }
            self.standbyTimer = work
            self.controlQueue.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    @discardableResult
    private func ensureHALRunningOnControlQueue(microphoneUID: String) -> Error? {
        guard let targetDeviceID = Self.resolveInputDevice(uid: microphoneUID) else {
            return NSError(domain: "VoiceAudioRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "未找到可用的麦克风输入设备"
            ])
        }

        if activeIOProcID != nil && activeDeviceID == targetDeviceID && activeMicUID == microphoneUID {
            return nil
        }

        stopAndDisposeOnControlQueue()

        guard let streamFormat = Self.inputStreamFormat(for: targetDeviceID) else {
            return NSError(domain: "VoiceAudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无法读取麦克风音频格式"
            ])
        }

        // Configure downmixer & AudioConverter on audioCallbackQueue before starting IOProc
        audioCallbackQueue.sync {
            self.activeStreamFormat = streamFormat
            self.downmixer.reset()
            self.resampler = MemoryAudioConverterResampler(sourceSampleRate: streamFormat.mSampleRate)
            self.monoScratch.removeAll(keepingCapacity: true)
            self.resampledScratch.removeAll(keepingCapacity: true)
        }

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, targetDeviceID, audioCallbackQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handleHALInputBuffer(inInputData)
        }
        guard createStatus == noErr, let procID else {
            return NSError(domain: "VoiceAudioRecorder", code: Int(createStatus), userInfo: [
                NSLocalizedDescriptionKey: "麦克风采集通道创建失败 (\(createStatus))"
            ])
        }

        state.withLock { s in
            s.pending.removeAll(keepingCapacity: true)
            s.hasSeenLiveAudio = false
            s.warmupFrameCount = 0
        }

        let startStatus = AudioDeviceStart(targetDeviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(targetDeviceID, procID)
            return NSError(domain: "VoiceAudioRecorder", code: Int(startStatus), userInfo: [
                NSLocalizedDescriptionKey: "麦克风启动失败 (\(startStatus))"
            ])
        }

        activeDeviceID = targetDeviceID
        activeIOProcID = procID
        activeMicUID = microphoneUID
        installDeviceListeners(for: targetDeviceID)
        return nil
    }

    private func installDeviceListeners(for deviceID: AudioDeviceID) {
        var aliveAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            var checkAddr = aliveAddr
            let status = AudioObjectGetPropertyData(deviceID, &checkAddr, 0, nil, &size, &alive)
            if status != noErr || alive == 0 {
                self.handleActiveDeviceDisconnected(deviceID)
            }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddr, controlQueue, aliveBlock) == noErr {
            aliveListenerBlock = aliveBlock
        }

        // Listen for external sample rate changes (e.g. Zoom / Tencent Meeting forcing 16kHz/24kHz)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleActiveDeviceFormatChanged(deviceID)
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &rateAddr, controlQueue, rateBlock) == noErr {
            sampleRateListenerBlock = rateBlock
        }

        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let fmtBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleActiveDeviceFormatChanged(deviceID)
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &fmtAddr, controlQueue, fmtBlock) == noErr {
            streamFormatListenerBlock = fmtBlock
        }
    }

    private func removeDeviceListeners() {
        guard activeDeviceID != kAudioObjectUnknown else { return }
        if let block = aliveListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(activeDeviceID, &addr, controlQueue, block)
            aliveListenerBlock = nil
        }
        if let block = sampleRateListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(activeDeviceID, &addr, controlQueue, block)
            sampleRateListenerBlock = nil
        }
        if let block = streamFormatListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(activeDeviceID, &addr, controlQueue, block)
            streamFormatListenerBlock = nil
        }
    }

    private func handleActiveDeviceFormatChanged(_ deviceID: AudioDeviceID) {
        guard activeDeviceID == deviceID, activeIOProcID != nil else { return }
        guard let newFormat = Self.inputStreamFormat(for: deviceID) else { return }

        audioCallbackQueue.sync {
            let rateChanged = abs(self.activeStreamFormat.mSampleRate - newFormat.mSampleRate) >= 1.0
            let layoutChanged = (self.activeStreamFormat.mChannelsPerFrame != newFormat.mChannelsPerFrame)
                || (self.activeStreamFormat.mFormatFlags != newFormat.mFormatFlags)
                || (self.activeStreamFormat.mBitsPerChannel != newFormat.mBitsPerChannel)
            guard rateChanged || layoutChanged else { return }

            self.activeStreamFormat = newFormat
            if layoutChanged {
                self.downmixer.reset()
            }
            if rateChanged {
                self.resampler = MemoryAudioConverterResampler(sourceSampleRate: newFormat.mSampleRate)
            }
        }
    }

    private func handleActiveDeviceDisconnected(_ deviceID: AudioDeviceID) {
        guard activeDeviceID == deviceID else { return }
        stopAndDisposeOnControlQueue()

        let (shouldRestart, fallbackUID): (Bool, String) = state.withLock { s in
            s.pending.removeAll(keepingCapacity: true)
            s.preRollFrames.removeAll(keepingCapacity: true)
            s.hasSeenLiveAudio = false
            s.warmupFrameCount = 0
            return (s.mode != .idle && !s.isSystemSleeping, s.desiredMicUID)
        }
        if shouldRestart {
            _ = ensureHALRunningOnControlQueue(microphoneUID: fallbackUID)
        }
    }

    private func stopAndDisposeOnControlQueue() {
        removeDeviceListeners()
        guard activeDeviceID != kAudioObjectUnknown, let procID = activeIOProcID else {
            activeDeviceID = kAudioObjectUnknown
            activeIOProcID = nil
            activeMicUID = nil
            return
        }
        let devID = activeDeviceID
        activeDeviceID = kAudioObjectUnknown
        activeIOProcID = nil
        activeMicUID = nil
        _ = AudioDeviceStop(devID, procID)
        _ = AudioDeviceDestroyIOProcID(devID, procID)
    }

    /// Runs on `audioCallbackQueue` (dispatched off CoreAudio's real-time IO thread by HAL).
    private func handleHALInputBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        downmixer.extractMonoFloats(from: inputData, format: activeStreamFormat, into: &monoScratch)
        guard !monoScratch.isEmpty else { return }

        resampledScratch.removeAll(keepingCapacity: true)
        resampler.process(monoScratch, into: &resampledScratch)
        guard !resampledScratch.isEmpty else { return }

        let (readyGenToNotify, latestLevelToNotify): (Int?, Float?) = state.withLock { s in
            guard s.mode != .idle else { return (nil, nil) }

            var readyGen: Int?
            var latestLevel: Float?

            s.pending.append(contentsOf: resampledScratch)
            while s.pending.count >= Self.frameSamples {
                let frame = Array(s.pending.prefix(Self.frameSamples))
                s.pending.removeFirst(Self.frameSamples)

                if !s.hasSeenLiveAudio {
                    s.warmupFrameCount += 1
                    if Self.hasNonZeroSample(frame) || s.warmupFrameCount >= Self.maxZeroWarmupFrames {
                        s.hasSeenLiveAudio = true
                        if s.mode == .capturing {
                            readyGen = s.captureGeneration
                        }
                    }
                }

                switch s.mode {
                case .capturing:
                    for session in s.liveSessions {
                        session.push(pcm16: frame)
                    }
                    latestLevel = Self.computeLevel(frame)
                case .preRolling:
                    s.preRollFrames.append(frame)
                    Self.trimPreRoll(&s.preRollFrames, limit: Self.maxPreRollFrames)
                case .warmStandby:
                    s.preRollFrames.append(frame)
                    Self.trimPreRoll(&s.preRollFrames, limit: Self.maxStandbyFrames)
                case .idle:
                    break
                }
            }
            return (readyGen, latestLevel)
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

    private static func trimPreRoll(_ frames: inout [[Int16]], limit: Int) {
        if frames.count > limit {
            frames.removeFirst(frames.count - limit)
        }
    }

    private static func resolveInputDevice(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = uid as CFString
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
            if status == noErr, devID != kAudioObjectUnknown, VoiceMicrophoneDevice.hasInputChannels(devID) {
                return devID
            }
        }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown,
              VoiceMicrophoneDevice.hasInputChannels(devID) else {
            return nil
        }
        return devID
    }

    private static func inputStreamFormat(for deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            return format
        }

        // Fallback: query nominal sample rate and assume standard HAL 32-bit float mono
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &sampleRate) == noErr,
              sampleRate > 0 else {
            return nil
        }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func hasNonZeroSample(_ frame: [Int16]) -> Bool {
        frame.contains { $0 != 0 }
    }

    private static func trimLeadingAllZeroFrames(_ frames: [[Int16]]) -> [[Int16]] {
        guard let firstLiveIdx = frames.firstIndex(where: { hasNonZeroSample($0) }) else {
            return []
        }
        return Array(frames[firstLiveIdx...])
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
