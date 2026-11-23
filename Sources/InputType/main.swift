import Cocoa
import InputMethodKit

if CommandLine.arguments.contains("--voice-test") {
    exit(VoiceEngineTestRunner.runCLI(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--smoke-test-all") {
    let presetsToTest: [DictionaryPreset] = CommandLine.arguments.contains("--smoke-test-all")
        ? DictionaryPreset.allCases
        : [.rimeIce]

    var allPassed = true
    for (index, preset) in presetsToTest.enumerated() {
        if index == 0 {
            RimeEngine.shared.start(preset: preset, waitForMaintenance: true)
        } else {
            RimeEngine.shared.switchPreset(preset, waitForMaintenance: true)
        }
        let session = RimeEngine.shared.createSession()
        for ch in "nihao" {
            if let scalar = ch.unicodeScalars.first {
                _ = RimeEngine.shared.processKey(sessionId: session, keyCode: Int32(scalar.value), mask: 0)
            }
        }
        let allCandidates = RimeEngine.shared.getAllCandidates(sessionId: session, limit: 20)
        if let ctx = RimeEngine.shared.getContext(sessionId: session), !allCandidates.isEmpty {
            print("SMOKE_OK preset=\(preset.rawValue) schema=\(preset.schemaID) preedit=\(ctx.preedit) totalCandidates=\(allCandidates.count) top=\(allCandidates.prefix(8).map { $0.text }.joined(separator: ","))")
        } else {
            print("SMOKE_FAIL preset=\(preset.rawValue) schema=\(preset.schemaID)")
            allPassed = false
        }
        RimeEngine.shared.destroySession(session)
    }
    RimeEngine.shared.shutdown()
    exit(allPassed ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedServer: IMKServer?
    static var sharedCandidates: IMKCandidates?

    func applicationWillTerminate(_ notification: Notification) {
        VoiceInputManager.shared.shutdown()
        RimeEngine.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SettingsWindowController.shared.isOpen {
            SettingsWindowController.shared.show()
        }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "com.lumocore.inputmethod.PrimeType_Connection"
let bundleId = Bundle.main.bundleIdentifier ?? "com.lumocore.inputmethod.PrimeType"

let server = IMKServer(name: connectionName, bundleIdentifier: bundleId)
AppDelegate.sharedServer = server

if let server {
    let candidates = IMKCandidates(
        server: server,
        panelType: kIMKScrollingGridCandidatePanel,
        styleType: kIMKMain
    )
    let setSortingModesSel = NSSelectorFromString("setSortingModes:")
    if let candidates, candidates.responds(to: setSortingModesSel) {
        candidates.perform(setSortingModesSel, with: ["词频"])
    }
    candidates?.setDismissesAutomatically(false)
    candidates?.setAttributes([
        IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true)
    ])
    let topLevel = Int(CGWindowLevelForKey(.screenSaverWindow)) + 1
    candidates?.setValue(NSNumber(value: topLevel), forKey: "windowLevel")
    let setAllowAnimSel = NSSelectorFromString("setAllowImplicitAnimations:")
    if let candidates, candidates.responds(to: setAllowAnimSel) {
        candidates.setValue(false, forKey: "allowImplicitAnimations")
    }
    if let ctrl = candidates?.value(forKey: "expandableWindowController") as? NSWindowController {
        if ctrl.responds(to: setAllowAnimSel) {
            ctrl.setValue(false, forKey: "allowImplicitAnimations")
        }
        let loadWinSel = NSSelectorFromString("loadWindow")
        if ctrl.responds(to: loadWinSel) {
            ctrl.perform(loadWinSel)
        }
        if let win = ctrl.window {
            win.animationBehavior = .none
            win.level = NSWindow.Level(rawValue: topLevel)
            win.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        }
    }
    AppDelegate.sharedCandidates = candidates
}

let initialPreset = InputSettings.shared.selectedDictionary
InputSettings.shared.writeRimeCustomYAML(for: initialPreset)
RimeEngine.shared.start(preset: initialPreset, waitForMaintenance: false)
ClipboardManager.shared.syncWithSettings()
HotKeyManager.shared.start {
    ClipboardPanelController.shared.toggle()
}
VoiceInputManager.shared.startMonitors()
TranslateManager.shared.startMonitors()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
    OnboardingWindowController.shared.showIfNeeded()
}
if InputSettings.shared.autoCheckAppUpdates {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        AppUpdateManager.shared.checkForUpdates(silent: true)
    }
}
app.run()
