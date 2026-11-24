import Cocoa
import Foundation

final class SettingsHelperAppDelegate: NSObject, NSApplicationDelegate {
    private var closeCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request fresh live diagnostics from the resident PrimeType IME process
        PrimeTypeIPC.post(PrimeTypeIPC.requestMetrics)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleHelperActivate(_:)),
            name: Notification.Name("com.lumocore.inputmethod.PrimeType.helperActivate"),
            object: nil
        )

        // Watch window close notifications to auto-exit cleanly so 0 bytes remain resident
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnyWindowClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let args = CommandLine.arguments
        if args.contains("--onboarding-accessibility") {
            OnboardingWindowController.shared.show(initialStep: .accessibility, openSettingsOnFinish: false)
        } else if args.contains("--onboarding") {
            OnboardingWindowController.shared.show(openSettingsOnFinish: true)
        } else if args.contains("--onboarding-only") {
            OnboardingWindowController.shared.show(openSettingsOnFinish: false)
        } else if args.contains("--about") {
            SettingsWindowController.shared.showAbout()
        } else {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func handleHelperActivate(_ note: Notification) {
        let arg = note.object as? String ?? "--settings"
        DispatchQueue.main.async {
            PrimeTypeIPC.post(PrimeTypeIPC.requestMetrics)
            switch arg {
            case "--about":
                SettingsWindowController.shared.showAbout()
            case "--onboarding-accessibility":
                OnboardingWindowController.shared.show(initialStep: .accessibility, openSettingsOnFinish: false)
            case "--onboarding":
                OnboardingWindowController.shared.show(openSettingsOnFinish: true)
            case "--onboarding-only":
                OnboardingWindowController.shared.show(openSettingsOnFinish: false)
            default:
                SettingsWindowController.shared.show()
            }
        }
    }

    @objc private func handleAnyWindowClosed(_ note: Notification) {
        scheduleTerminateCheckIfIdle()
    }

    private func hasActiveDownload() -> Bool {
        GrammarModelManager.shared.isDownloading
            || LocalNeuralReranker.shared.isDownloading
            || AppUpdateManager.shared.isUpdating
            || DictionaryUpdateManager.shared.states.values.contains { $0.isUpdating }
    }

    private func scheduleTerminateCheckIfIdle() {
        closeCheckTimer?.invalidate()
        closeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible }
            if hasVisibleWindow {
                timer.invalidate()
                self.closeCheckTimer = nil
                return
            }
            if !self.hasActiveDownload() {
                timer.invalidate()
                self.closeCheckTimer = nil
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SettingsWindowController.shared.show()
        }
        return true
    }
}

let app = NSApplication.shared
let helperDelegate = SettingsHelperAppDelegate()
app.delegate = helperDelegate
app.run()
