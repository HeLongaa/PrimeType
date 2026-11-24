import AudioToolbox
import Cocoa
import Carbon
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
                    let finalID = sid
                    soundCache.withLock { $0[name] = finalID }
                    return finalID
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

    #if !PRIMETYPE_SETTINGS_HELPER
    /// Converts a modifier+key spec (without `fn`) into a Carbon `HotKeyConfig` for global registration
    static func carbonHotKeyConfig(for spec: String) -> HotKeyConfig? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, singleModifierKeyCode(for: trimmed) == nil else { return nil }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let keyToken = tokens.last else { return nil }
        let modTokens = Set(tokens.dropLast().map { $0.lowercased() })
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
    #endif
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
