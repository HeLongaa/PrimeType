import AVFoundation
import ApplicationServices
import Cocoa
import Darwin
import Foundation

/// Cross-process Darwin notification & lightweight state bridge between the main `PrimeType.app` IME
/// and the on-demand `PrimeTypeSettings.app` helper (keeps 5,100+ lines of SwiftUI Settings/Onboarding
/// completely out of the resident IME process).
enum PrimeTypeIPC {
    static let settingsChanged = "com.lumocore.inputmethod.PrimeType.ipc.settingsChanged"
    static let redeployRime = "com.lumocore.inputmethod.PrimeType.ipc.redeployRime"
    static let rimeDeployCompleted = "com.lumocore.inputmethod.PrimeType.ipc.rimeDeployCompleted"
    static let switchDictionary = "com.lumocore.inputmethod.PrimeType.ipc.switchDictionary"
    static let resetUserDB = "com.lumocore.inputmethod.PrimeType.ipc.resetUserDB"
    static let clearRimeBuildCache = "com.lumocore.inputmethod.PrimeType.ipc.clearRimeBuildCache"
    static let resetUserRanking = "com.lumocore.inputmethod.PrimeType.ipc.resetUserRanking"
    static let clearClipboard = "com.lumocore.inputmethod.PrimeType.ipc.clearClipboard"
    static let openClipboardPanel = "com.lumocore.inputmethod.PrimeType.ipc.openClipboardPanel"
    static let syncVoiceMic = "com.lumocore.inputmethod.PrimeType.ipc.syncVoiceMic"
    static let unloadLocalReranker = "com.lumocore.inputmethod.PrimeType.ipc.unloadLocalReranker"
    static let requestMetrics = "com.lumocore.inputmethod.PrimeType.ipc.requestMetrics"
    static let metricsUpdated = "com.lumocore.inputmethod.PrimeType.ipc.metricsUpdated"
    static let importBackupDone = "com.lumocore.inputmethod.PrimeType.ipc.importBackupDone"
    static let requestAccessibility = "com.lumocore.inputmethod.PrimeType.ipc.requestAccessibility"
    static let requestMicrophone = "com.lumocore.inputmethod.PrimeType.ipc.requestMicrophone"
    static let restartIME = "com.lumocore.inputmethod.PrimeType.ipc.restartIME"

    struct RuntimeMetrics: Codable {
        var sampleCount: Int
        var syncP50Ms: Double
        var syncP95Ms: Double
        var syncP99Ms: Double
        var over16msCount: Int
        var over16msRatio: Double
        var asyncAppliedCount: Int
        var asyncDroppedCount: Int
        var asyncTop1FlipCount: Int
        var summaryText: String
        var userRankingEntryCount: Int
        var localRerankerStateRaw: String
        var currentPresetRaw: String
        var accessibilityGranted: Bool?
        var micAuthStatusRaw: Int?
        var updatedAt: TimeInterval
    }

    static var parentIMEBundleURL: URL {
        #if PRIMETYPE_SETTINGS_HELPER
        // PrimeType.app/Contents/Helpers/PrimeTypeSettings.app -> PrimeType.app
        let candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if candidate.pathExtension == "app" {
            return candidate
        }
        return URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app")
        #else
        return Bundle.main.bundleURL
        #endif
    }

    static var metricsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/InputType/runtime_metrics.json")
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    static func observe(_ name: String, observer: AnyObject, callback: CFNotificationCallback) {
        let ptr = Unmanaged.passUnretained(observer).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ptr,
            callback,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    static func removeAllObservers(for observer: AnyObject) {
        let ptr = Unmanaged.passUnretained(observer).toOpaque()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), ptr)
    }

    static func writeMetrics(_ metrics: RuntimeMetrics) {
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        try? data.write(to: metricsFileURL, options: .atomic)
    }

    static func readMetrics() -> RuntimeMetrics? {
        guard let data = try? Data(contentsOf: metricsFileURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeMetrics.self, from: data)
    }
}

#if !PRIMETYPE_SETTINGS_HELPER
/// Launches the embedded `PrimeTypeSettings.app` helper on demand and handles Darwin IPC commands
/// sent back from the Settings/Onboarding helper to the resident IME process.
final class SettingsHelperLauncher {
    static let shared = SettingsHelperLauncher()
    private var isListening = false

    private init() {}

    private var helperAppURL: URL? {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PrimeTypeSettings.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: embedded.path) {
            return embedded
        }
        // Development fallback: sibling build product in DerivedData
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PrimeTypeSettings.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    func showSettings() {
        publishRuntimeMetrics()
        launchHelper(arguments: ["--settings"])
    }

    func showAbout() {
        publishRuntimeMetrics()
        launchHelper(arguments: ["--about"])
    }

    func showOnboarding(openSettingsOnFinish: Bool = true) {
        publishRuntimeMetrics()
        launchHelper(arguments: openSettingsOnFinish ? ["--onboarding"] : ["--onboarding-only"])
    }

    func showOnboardingIfNeeded() {
        let settings = InputSettings.shared
        let shortVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let buildVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let currentFullVersion = "\(shortVer) (\(buildVer))"

        if !settings.hasCompletedOnboarding {
            settings.lastLaunchedVersion = currentFullVersion
            let axGranted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
            let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if axGranted && micGranted {
                settings.hasCompletedOnboarding = true
                return
            }
            showOnboarding(openSettingsOnFinish: true)
            return
        }

        // Post-update check: if app version changed and Accessibility permission was invalidated
        // (due to ad-hoc signing CDHash change), clean stale TCC entry and show quick re-auth card.
        let previousVersion = settings.lastLaunchedVersion
        if previousVersion != currentFullVersion {
            settings.lastLaunchedVersion = currentFullVersion
            let axGranted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
            if !previousVersion.isEmpty && !axGranted {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "Accessibility", "com.lumocore.inputmethod.PrimeType"]
                try? reset.run()
                reset.waitUntilExit()
                publishRuntimeMetrics()
                launchHelper(arguments: ["--onboarding-accessibility"])
            }
        }
    }

    private func launchHelper(arguments: [String]) {
        guard let helperURL = helperAppURL else {
            NSLog("PrimeType: PrimeTypeSettings.app helper not found inside bundle")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: config) { app, error in
            if let error {
                NSLog("PrimeType: failed to launch PrimeTypeSettings.app: %@", error.localizedDescription)
                return
            }
            if let app, !arguments.isEmpty {
                // If already running, notify via DistributedNotification so the helper switches tab/brings window front
                DispatchQueue.main.async {
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("com.lumocore.inputmethod.PrimeType.helperActivate"),
                        object: arguments.first
                    )
                    app.activate()
                }
            }
        }
    }

    // MARK: - Main IME IPC Receiver

    func startIPCListener() {
        guard !isListening else { return }
        isListening = true

        let names = [
            PrimeTypeIPC.settingsChanged,
            PrimeTypeIPC.redeployRime,
            PrimeTypeIPC.switchDictionary,
            PrimeTypeIPC.resetUserDB,
            PrimeTypeIPC.clearRimeBuildCache,
            PrimeTypeIPC.resetUserRanking,
            PrimeTypeIPC.clearClipboard,
            PrimeTypeIPC.openClipboardPanel,
            PrimeTypeIPC.syncVoiceMic,
            PrimeTypeIPC.unloadLocalReranker,
            PrimeTypeIPC.requestMetrics,
            PrimeTypeIPC.importBackupDone,
            PrimeTypeIPC.requestAccessibility,
            PrimeTypeIPC.requestMicrophone,
            PrimeTypeIPC.restartIME
        ]
        for name in names {
            PrimeTypeIPC.observe(name, observer: self) { _, _, cfName, _, _ in
                guard let raw = cfName?.rawValue as String? else { return }
                DispatchQueue.main.async {
                    SettingsHelperLauncher.shared.handleIPC(raw)
                }
            }
        }
        publishRuntimeMetrics()
    }

    func publishRuntimeMetrics() {
        let snap = LatencyProbe.shared.snapshot()
        let metrics = PrimeTypeIPC.RuntimeMetrics(
            sampleCount: snap.sampleCount,
            syncP50Ms: snap.syncP50Ms,
            syncP95Ms: snap.syncP95Ms,
            syncP99Ms: snap.syncP99Ms,
            over16msCount: snap.over16msCount,
            over16msRatio: snap.over16msRatio,
            asyncAppliedCount: snap.asyncAppliedCount,
            asyncDroppedCount: snap.asyncDroppedCount,
            asyncTop1FlipCount: snap.top1FlipCount,
            summaryText: snap.summaryText,
            userRankingEntryCount: UserRankingEngine.shared.entryCount,
            localRerankerStateRaw: LocalNeuralReranker.shared.runtimeState.rawValue,
            currentPresetRaw: RimeEngine.shared.currentPreset.rawValue,
            accessibilityGranted: ClipboardManager.shared.isAccessibilityTrusted,
            micAuthStatusRaw: AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            updatedAt: Date().timeIntervalSince1970
        )
        PrimeTypeIPC.writeMetrics(metrics)
        PrimeTypeIPC.post(PrimeTypeIPC.metricsUpdated)
    }

    private func handleIPC(_ name: String) {
        switch name {
        case PrimeTypeIPC.settingsChanged:
            InputSettings.shared.reloadFromDiskAndSync()
            GrammarModelManager.shared.refreshInstalledModels()
            LocalNeuralReranker.shared.refreshInstallState()
            VoiceInputManager.shared.syncMicrophonePreference()
            ClipboardManager.shared.syncWithSettings()
            publishRuntimeMetrics()

        case PrimeTypeIPC.redeployRime:
            InputSettings.shared.reloadFromDiskAndSync()
            GrammarModelManager.shared.refreshInstalledModels()
            InputSettings.shared.redeployCurrentPreset {
                PrimeTypeIPC.post(PrimeTypeIPC.rimeDeployCompleted)
            }

        case PrimeTypeIPC.switchDictionary:
            InputSettings.shared.reloadFromDiskAndSync()
            let target = InputSettings.shared.selectedDictionary
            InputSettings.shared.switchDictionary(to: target) {
                PrimeTypeIPC.post(PrimeTypeIPC.rimeDeployCompleted)
                self.publishRuntimeMetrics()
            }

        case PrimeTypeIPC.resetUserDB:
            InputSettings.shared.resetUserFrequencyDB {
                PrimeTypeIPC.post(PrimeTypeIPC.rimeDeployCompleted)
            }

        case PrimeTypeIPC.clearRimeBuildCache:
            InputSettings.shared.clearRimeBuildCacheAndRebuild {
                PrimeTypeIPC.post(PrimeTypeIPC.rimeDeployCompleted)
            }

        case PrimeTypeIPC.resetUserRanking:
            UserRankingEngine.shared.resetAll()
            EmitHistory.shared.clearAll()
            publishRuntimeMetrics()

        case PrimeTypeIPC.clearClipboard:
            ClipboardManager.shared.clearAll()

        case PrimeTypeIPC.openClipboardPanel:
            ClipboardPanelController.shared.show()

        case PrimeTypeIPC.syncVoiceMic:
            InputSettings.shared.reloadFromDiskAndSync()
            VoiceInputManager.shared.syncMicrophonePreference()

        case PrimeTypeIPC.unloadLocalReranker:
            LocalNeuralReranker.shared.unloadNow()
            publishRuntimeMetrics()

        case PrimeTypeIPC.requestMetrics:
            publishRuntimeMetrics()

        case PrimeTypeIPC.requestAccessibility:
            ClipboardManager.shared.requestAccessibilityPermission(openSystemSettings: false)
            publishRuntimeMetrics()

        case PrimeTypeIPC.requestMicrophone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async {
                        VoiceInputManager.shared.syncMicrophonePreference()
                        SettingsHelperLauncher.shared.publishRuntimeMetrics()
                    }
                }
            } else {
                publishRuntimeMetrics()
            }

        case PrimeTypeIPC.restartIME:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }

        case PrimeTypeIPC.importBackupDone:
            RimeEngine.shared.shutdown()
            InputSettings.shared.reloadFromDiskAndSync()
            RimeEngine.shared.start(preset: InputSettings.shared.selectedDictionary, waitForMaintenance: true)
            PrimeTypeIPC.post(PrimeTypeIPC.rimeDeployCompleted)
            publishRuntimeMetrics()

        default:
            break
        }
    }
}
#endif
