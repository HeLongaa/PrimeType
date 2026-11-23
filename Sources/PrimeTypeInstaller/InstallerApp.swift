import Carbon
import Cocoa
import SwiftUI

@main
struct PrimeTypeInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            InstallerRootView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.title = ""
                window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
                window.standardWindowButton(.zoomButton)?.isEnabled = false
                window.center()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct InstallerRootView: View {
    @State private var isInstalling = false
    @State private var errorMessage: String?

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

            Spacer().frame(height: 18)

            Text("Prime 输入法")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)

            Spacer().frame(height: 8)

            Text("高效输入 享受输出")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Spacer().frame(height: 10)

            Text(versionString)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 28)

            Button(action: startInstall) {
                Text(isInstalling ? "正在安装" : "安装")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 260, height: 48)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.27, green: 0.51, blue: 0.99).opacity(isInstalling ? 0.55 : 1.0))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 32)
            }

            Spacer(minLength: 24)

            Text("适用于 macOS 14.0 或更高版本")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 22)
        }
        .frame(width: 520, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func startInstall() {
        guard !isInstalling else { return }
        errorMessage = nil

        guard let bundledAppURL = Bundle.main.url(forResource: "PrimeType", withExtension: "app") else {
            errorMessage = "安装包不完整：未找到内置的 PrimeType.app"
            return
        }

        isInstalling = true

        Task.detached(priority: .userInitiated) {
            do {
                try Self.installBundledApp(from: bundledAppURL)

                // Register with TIS and refresh imklaunchagent so System Settings lists Prime 输入法 immediately
                await MainActor.run {
                    let appURL = URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app") as CFURL
                    TISRegisterInputSource(appURL)
                }
                let refresh = Process()
                refresh.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                refresh.arguments = ["TextInputMenuAgent"]
                try? refresh.run()
                refresh.waitUntilExit()
                try? await Task.sleep(nanoseconds: 400_000_000)

                await Self.launchOnboardingViaLaunchServices()
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func installBundledApp(from sourceURL: URL) throws {
        let targetApp = "/Library/Input Methods/PrimeType.app"
        let shellScript = """
        set -e
        mkdir -p "\(targetApp)"
        killall PrimeType 2>/dev/null || true
        rsync -a --delete "\(sourceURL.path)/" "\(targetApp)/"
        xattr -dr com.apple.quarantine "\(targetApp)" 2>/dev/null || true
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "\(targetApp)" 2>/dev/null || true
        """

        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            if errStr.contains("User canceled") || errStr.contains("-128") {
                throw NSError(domain: "PrimeTypeInstaller", code: -128, userInfo: [
                    NSLocalizedDescriptionKey: "已取消安装"
                ])
            }
            throw NSError(domain: "PrimeTypeInstaller", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "安装失败，请确认已输入管理员密码"
            ])
        }
    }

    private static func findPrimeParentAndMode() -> (parent: TISInputSource?, mode: TISInputSource?) {
        var parent: TISInputSource?
        var mode: TISInputSource?
        if let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
            for src in all {
                guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.lumocore.inputmethod.PrimeType" {
                    parent = src
                } else if id == "com.lumocore.inputmethod.PrimeType.pinyin" {
                    mode = src
                }
            }
        }
        return (parent, mode)
    }

    private static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/primetype_installer.log")
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func isPrimeInputSourceEnabled() -> Bool {
        let filter = [kTISPropertyInputSourceID as String: "com.lumocore.inputmethod.PrimeType.pinyin"] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        return !list.isEmpty
    }

    private static func selectPrimePinyinMode() {
        let filter = [kTISPropertyInputSourceID as String: "com.lumocore.inputmethod.PrimeType.pinyin"] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
           let src = list.first {
            TISSelectInputSource(src)
        }
    }

    private static func launchOnboardingViaLaunchServices() async {
        let appURL = URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--onboarding"]
        config.activates = true
        config.createsNewApplicationInstance = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
}
