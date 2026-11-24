import AVFoundation
import Carbon
import Cocoa
import Combine
import Foundation

#if PRIMETYPE_SETTINGS_HELPER

struct RimeCandidateItem: Equatable {
    let text: String
    let comment: String?
}

/// Lightweight helper-side shims so `SettingsWindowController` and `OnboardingWindowController`
/// run untouched in the isolated `PrimeTypeSettings.app` process (zero `librime`/`libopus` linkage)
/// and forward all engine/IME mutations cleanly to the resident `PrimeType.app` via Darwin IPC.

final class RimeEngine {
    static let shared = RimeEngine()
    static let sharedUserDictName = "prime_shared"

    private let baseUserDir: String
    let logDir: String
    private(set) var currentPreset: DictionaryPreset = .rimeIce

    private let deployLock = NSLock()
    private var deployWaiters: [DispatchSemaphore] = []

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.baseUserDir = "\(home)/Library/InputType"
        self.logDir = "\(home)/Library/Logs/InputType"
        if let raw = PrimeTypeIPC.readMetrics()?.currentPresetRaw, let p = DictionaryPreset(rawValue: raw) {
            self.currentPreset = p
        }
        PrimeTypeIPC.observe(PrimeTypeIPC.rimeDeployCompleted, observer: self) { _, _, _, _, _ in
            RimeEngine.shared.signalDeployCompleted()
        }
    }

    private func signalDeployCompleted() {
        deployLock.lock()
        let waiters = deployWaiters
        deployWaiters.removeAll()
        deployLock.unlock()
        for sem in waiters { sem.signal() }
    }

    private var parentIMEBundleURL: URL {
        // PrimeType.app/Contents/Helpers/PrimeTypeSettings.app -> PrimeType.app
        let candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if candidate.pathExtension == "app" {
            return candidate
        }
        return URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app")
    }

    func sharedDataDir(for preset: DictionaryPreset) -> String {
        let overlayDir = "\(baseUserDir)/dictionaries/\(preset.profileDirectoryName)"
        let overlaySchema = "\(overlayDir)/\(preset.schemaID).schema.yaml"
        if FileManager.default.fileExists(atPath: overlaySchema) {
            return overlayDir
        }
        let parentResources = parentIMEBundleURL.appendingPathComponent("Contents/Resources").path
        return "\(parentResources)/\(preset.sharedSubpath)"
    }

    func userDataDir(for preset: DictionaryPreset) -> String {
        "\(baseUserDir)/profiles/\(preset.profileDirectoryName)"
    }

    func isPresetAvailable(_ preset: DictionaryPreset) -> Bool {
        let dir = sharedDataDir(for: preset)
        let schemaFile = (dir as NSString).appendingPathComponent("\(preset.schemaID).schema.yaml")
        return FileManager.default.fileExists(atPath: schemaFile)
    }

    func deploy(waitForMaintenance: Bool = false) {
        if waitForMaintenance {
            let sem = DispatchSemaphore(value: 0)
            deployLock.lock()
            deployWaiters.append(sem)
            deployLock.unlock()
            PrimeTypeIPC.post(PrimeTypeIPC.redeployRime)
            _ = sem.wait(timeout: .now() + 12.0)
        } else {
            PrimeTypeIPC.post(PrimeTypeIPC.redeployRime)
        }
    }

    func switchPreset(_ preset: DictionaryPreset, waitForMaintenance: Bool = true) {
        currentPreset = preset
        if waitForMaintenance {
            let sem = DispatchSemaphore(value: 0)
            deployLock.lock()
            deployWaiters.append(sem)
            deployLock.unlock()
            PrimeTypeIPC.post(PrimeTypeIPC.switchDictionary)
            _ = sem.wait(timeout: .now() + 15.0)
        } else {
            PrimeTypeIPC.post(PrimeTypeIPC.switchDictionary)
        }
    }

    func start(preset: DictionaryPreset = .rimeIce, waitForMaintenance: Bool = false) {
        currentPreset = preset
        if waitForMaintenance {
            deploy(waitForMaintenance: true)
        }
    }

    func shutdown() {
        // Main IME owns the live librime instance; handled via IPC notifications.
    }
}

final class VoiceInputManager: ObservableObject {
    static let shared = VoiceInputManager()
    static var isRecordingShortcut = false

    private let dataStore = VoiceDataStore.shared
    private init() {
        _ = dataStore.dataDirectoryURL
    }

    func hasAccountCookie(for channel: VoiceCloudChannel) -> Bool {
        dataStore.hasCookie(for: channel)
    }

    @discardableResult
    func setAccountCookie(_ cookie: String, for channel: VoiceCloudChannel) -> Bool {
        dataStore.setCookie(cookie, for: channel)
    }

    func syncMicrophonePreference() {
        PrimeTypeIPC.post(PrimeTypeIPC.syncVoiceMic)
    }

    func prewarm(channel: VoiceCloudChannel) {
        PrimeTypeIPC.post(PrimeTypeIPC.syncVoiceMic)
    }

    func handleAlwaysOnSettingChanged(_ enabled: Bool) {
        if !enabled {
            PrimeTypeIPC.post(PrimeTypeIPC.syncVoiceMic)
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            PrimeTypeIPC.post(PrimeTypeIPC.syncVoiceMic)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        PrimeTypeIPC.post(PrimeTypeIPC.syncVoiceMic)
                    } else {
                        InputSettings.shared.voiceAlwaysOnMic = false
                    }
                }
            }
        default:
            InputSettings.shared.voiceAlwaysOnMic = false
        }
    }
}

final class ClipboardPanelController {
    static let shared = ClipboardPanelController()
    private init() {}

    func show() {
        PrimeTypeIPC.post(PrimeTypeIPC.openClipboardPanel)
    }
}

final class InputTypeController {
    static var isServerCurrentlyActive = false
    static weak var latestActiveController: InputTypeController?
    static var latestActiveBundleID: String?

    func insertClipboardTextDirectly(_ text: String) -> Bool { false }
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}
    func reloadFromSettings() {}
}

struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultClipboard = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static func from(event: NSEvent) -> HotKeyConfig? {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard !flags.isEmpty else { return nil }
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

enum TranslateLanguage: String, CaseIterable, Identifiable, Codable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"
    case es = "es"
    case ru = "ru"
    case it = "it"
    case pt = "pt"
    case ar = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .en: return "英语"
        case .ja: return "日语"
        case .ko: return "韩语"
        case .fr: return "法语"
        case .de: return "德语"
        case .es: return "西班牙语"
        case .ru: return "俄语"
        case .it: return "意大利语"
        case .pt: return "葡萄牙语"
        case .ar: return "阿拉伯语"
        }
    }
}

enum TranslateShortcutHelper {
    static let doubleTapPrefix = "双击 "

    static func doubleTapModifierKeyCode(for spec: String) -> UInt16? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(doubleTapPrefix) else { return nil }
        let rest = String(trimmed.dropFirst(doubleTapPrefix.count))
        return VoiceShortcutFormatter.singleModifierKeyCode(for: rest)
    }

    static func isDoubleTapSpec(_ spec: String) -> Bool {
        doubleTapModifierKeyCode(for: spec) != nil
    }

    static func isModifierPressed(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 63: return flags.contains(.function)
        case 61, 58: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 62, 59: return flags.contains(.control)
        case 60, 56: return flags.contains(.shift)
        default: return false
        }
    }
}

final class TranslateManager {
    static let shared = TranslateManager()
    static var isRecordingShortcut = false
    private init() {}
}

#endif
