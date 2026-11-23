import Cocoa
import Carbon
import Combine

struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultClipboard = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static func from(event: NSEvent) -> HotKeyConfig? {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // Require at least one modifier so single letters don't hijack typing
        guard !flags.isEmpty else { return nil }
        // Ignore pure modifier keycodes
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeyCodes.contains(event.keyCode) else { return nil }

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return HotKeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    var displayString: String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined(separator: " ")
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
            0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
            0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↵", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
            0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
            0x31: "空格", 0x32: "`", 0x33: "⌫", 0x35: "⎋",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var eventHandlerRef: EventHandlerRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var voiceHotKeyRef: EventHotKeyRef?
    private var onClipboardTrigger: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    private let hotKeySignature: OSType = 0x49545043 // 'ITPC'
    private let clipboardHotKeyID: UInt32 = 1
    private let voiceHotKeyID: UInt32 = 2

    private init() {}

    func start(onClipboardTrigger: @escaping () -> Void) {
        self.onClipboardTrigger = onClipboardTrigger
        installHandlerIfNeeded()

        InputSettings.shared.$clipboardEnabled
            .combineLatest(InputSettings.shared.$clipboardHotKey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, config in
                self?.updateClipboardHotKey(enabled: enabled, config: config)
            }
            .store(in: &cancellables)

        InputSettings.shared.$shortcutVoiceStart
            .combineLatest(InputSettings.shared.$shortcutVoiceStartKey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, spec in
                self?.updateVoiceHotKey(enabled: enabled, spec: spec)
            }
            .store(in: &cancellables)
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    if hkID.signature == mgr.hotKeySignature {
                        if hkID.id == mgr.clipboardHotKeyID {
                            DispatchQueue.main.async {
                                mgr.onClipboardTrigger?()
                            }
                        } else if hkID.id == mgr.voiceHotKeyID {
                            DispatchQueue.main.async {
                                guard !VoiceInputManager.isRecordingShortcut else { return }
                                VoiceInputManager.shared.toggleTapRecording()
                            }
                        }
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func updateClipboardHotKey(enabled: Bool, config: HotKeyConfig?) {
        if let ref = clipboardHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardHotKeyRef = nil
        }
        guard enabled, let config else { return }

        let hkID = EventHotKeyID(signature: hotKeySignature, id: clipboardHotKeyID)
        RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyRef
        )
    }

    private func updateVoiceHotKey(enabled: Bool, spec: String) {
        if let ref = voiceHotKeyRef {
            UnregisterEventHotKey(ref)
            voiceHotKeyRef = nil
        }
        guard enabled, let config = VoiceShortcutFormatter.carbonHotKeyConfig(for: spec) else { return }

        let hkID = EventHotKeyID(signature: hotKeySignature, id: voiceHotKeyID)
        RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &voiceHotKeyRef
        )
    }
}
