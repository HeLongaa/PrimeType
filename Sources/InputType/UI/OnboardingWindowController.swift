import AVFoundation
import ApplicationServices
import Carbon
import Cocoa
import SwiftUI

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func showIfNeeded() {
        let settings = InputSettings.shared
        guard !settings.hasCompletedOnboarding else { return }

        let axGranted = AXIsProcessTrusted()
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if axGranted && micGranted {
            settings.hasCompletedOnboarding = true
            return
        }

        show()
    }

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = OnboardingView(
            onFinish: { [weak self] in
                InputSettings.shared.hasCompletedOnboarding = true
                self?.close()
            }
        )
        let hosting = NSHostingController(rootView: contentView)

        let win = NSWindow(contentViewController: hosting)
        win.title = "欢迎使用 Prime 输入法"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.setContentSize(NSSize(width: 520, height: 470))
        win.center()
        win.level = .floating
        win.delegate = self

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var inputSourceEnabled: Bool = Self.checkInputSourceEnabled()

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var micGranted: Bool { micStatus == .authorized }
    private var allReady: Bool { axGranted && micGranted }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 64, height: 64)

                Text("欢迎使用 Prime 输入法")
                    .font(.system(size: 20, weight: .bold))

                Text("完成以下权限配置，即可完整使用剪贴板、AI 划词翻译与语音输入")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)
            .padding(.horizontal, 28)

            // Steps
            VStack(spacing: 12) {
                permissionRow(
                    icon: "keyboard",
                    iconColor: .blue,
                    title: "启用 Prime 输入法",
                    subtitle: inputSourceEnabled
                        ? "已添加到系统输入法列表"
                        : "在系统设置 → 键盘 → 输入法 中添加「Prime 输入法」",
                    granted: inputSourceEnabled,
                    actionTitle: "打开键盘设置",
                    action: openKeyboardSettings
                )

                permissionRow(
                    icon: "hand.raised.fill",
                    iconColor: .orange,
                    title: "辅助功能权限",
                    subtitle: axGranted
                        ? "已授权，支持划词翻译、剪贴板自动粘贴与光标跟随"
                        : "用于获取选中文本、光标位置及剪贴板一键粘贴",
                    granted: axGranted,
                    actionTitle: "前往授权",
                    action: requestAccessibility
                )

                permissionRow(
                    icon: "mic.fill",
                    iconColor: .red,
                    title: "麦克风权限",
                    subtitle: micGranted
                        ? "已授权，支持低延迟流式语音输入"
                        : (micStatus == .denied
                            ? "已被拒绝，请在系统设置中重新开启"
                            : "用于按住说话与语音听写识别"),
                    granted: micGranted,
                    actionTitle: micStatus == .denied ? "打开设置" : "授权麦克风",
                    action: requestMicrophone
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            Divider()

            // Footer
            HStack {
                Button("稍后配置") {
                    onFinish()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button(allReady ? "开始使用" : "完成") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 470)
        .onReceive(pollTimer) { _ in
            axGranted = AXIsProcessTrusted()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            inputSourceEnabled = Self.checkInputSourceEnabled()
        }
    }

    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if granted {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func checkInputSourceEnabled() -> Bool {
        let filter = [kTISPropertyInputSourceID as String: "com.lumocore.inputmethod.PrimeType.pinyin"] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        return !list.isEmpty
    }
}
