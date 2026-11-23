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

        show(openSettingsOnFinish: true)
    }

    func show(openSettingsOnFinish: Bool = true) {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = OnboardingWizardView(
            onFinish: { [weak self] in
                InputSettings.shared.hasCompletedOnboarding = true
                self?.close()
                if openSettingsOnFinish {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        SettingsWindowController.shared.show()
                    }
                }
            }
        )
        let hosting = NSHostingController(rootView: contentView)

        let win = NSWindow(contentViewController: hosting)
        win.title = ""
        win.styleMask = [.titled, .closable]
        win.titlebarAppearsTransparent = false
        win.setContentSize(NSSize(width: 780, height: 500))
        win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        win.standardWindowButton(.zoomButton)?.isEnabled = false
        win.center()
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

private enum OnboardingStep: Int, CaseIterable {
    case addInputSource = 0
    case microphone = 1
    case voiceShortcut = 2
    case accessibility = 3

    var progress: Double {
        Double(rawValue + 1) / Double(Self.allCases.count)
    }
}

private struct OnboardingWizardView: View {
    let onFinish: () -> Void

    @ObservedObject private var settings = InputSettings.shared
    @State private var step: OnboardingStep = .addInputSource
    @State private var inputSourceAdded: Bool = Self.checkInputSourceEnabled()
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var isRecordingShortcut = false
    @State private var shortcutMonitor: Any?

    private let pollTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    private let brandBlue = Color(red: 0.27, green: 0.51, blue: 0.99)

    private var micGranted: Bool { micStatus == .authorized }

    var body: some View {
        VStack(spacing: 0) {
            // Top blue progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                    Rectangle()
                        .fill(brandBlue)
                        .frame(width: geo.size.width * step.progress)
                        .animation(.easeInOut(duration: 0.28), value: step)
                }
            }
            .frame(height: 3)

            HStack(spacing: 0) {
                // Left column: content & primary action
                leftPanel
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))

                // Right column: visual illustration
                rightIllustration
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            colors: [
                                brandBlue.opacity(0.04),
                                brandBlue.opacity(0.09)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: 780, height: 500)
        .onAppear {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            axGranted = AXIsProcessTrusted()
        }
        .onChange(of: step) { _, newStep in
            if newStep == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    requestMicrophoneAccess()
                }
            }
        }
        .onDisappear {
            stopRecordingShortcut()
        }
        .onReceive(pollTimer) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            axGranted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            switch step {
            case .addInputSource:
                stepBadge(icon: "globe")
                Spacer().frame(height: 22)
                Text("添加 Prime 输入法")
                    .font(.system(size: 26, weight: .bold))
                Spacer().frame(height: 12)
                Text("请先在「系统设置 → 键盘 → 输入法」中点击「编辑… → +」，选择「简体中文 → Prime 输入法」完成添加。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                Spacer().frame(height: 28)
                primaryButton(title: "打开键盘设置") {
                    openKeyboardSettings()
                }
                Spacer().frame(height: 12)
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        step = .microphone
                    }
                } label: {
                    Text("已添加，下一步")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(brandBlue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            Capsule()
                                .stroke(brandBlue.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

            case .microphone:
                stepBadge(icon: "mic")
                Spacer().frame(height: 22)
                Text("开启麦克风权限")
                    .font(.system(size: 26, weight: .bold))
                Spacer().frame(height: 12)
                Text(micGranted
                     ? "已获得麦克风权限，点击下方按钮继续设置语音快捷键。"
                     : "Prime 输入法需要此权限才能实现语音输入功能，请在弹出的系统提示框中点击「允许」。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                Spacer().frame(height: 32)
                primaryButton(title: micGranted ? "下一步" : "去授权") {
                    if micGranted {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            step = .voiceShortcut
                        }
                    } else {
                        requestMicrophoneAccess()
                    }
                }
                if !micGranted {
                    Button("暂不开启，跳过") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            step = .voiceShortcut
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                }

            case .voiceShortcut:
                stepBadge(icon: "keyboard")
                Spacer().frame(height: 22)
                Text("语音快捷键设置")
                    .font(.system(size: 26, weight: .bold))
                Spacer().frame(height: 12)
                Text("推荐使用 fn 键，也可更换为其他快捷键。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Spacer().frame(height: 22)

                Button(action: toggleRecordingShortcut) {
                    HStack {
                        Spacer()
                        Text(isRecordingShortcut ? "请按下快捷键…" : displayShortcutLabel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isRecordingShortcut ? brandBlue : .primary)
                        Spacer()
                    }
                    .frame(height: 46)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        Capsule()
                            .stroke(isRecordingShortcut ? brandBlue : Color.primary.opacity(0.14), lineWidth: isRecordingShortcut ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)

                Text("点击输入框录入快捷键，最多 3 个键。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 6)

                Spacer().frame(height: 24)
                primaryButton(title: "下一步") {
                    stopRecordingShortcut()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        step = .accessibility
                    }
                }

            case .accessibility:
                stepBadge(icon: "hand.raised")
                Spacer().frame(height: 22)
                Text("开启辅助功能权限")
                    .font(.system(size: 26, weight: .bold))
                Spacer().frame(height: 12)
                Text(axGranted
                     ? "已开启辅助功能权限，点击下方按钮进入 Prime 输入法设置。"
                     : "用于划词翻译、剪贴板自动粘贴与光标位置跟随，请在系统设置中勾选「Prime 输入法」。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                Spacer().frame(height: 32)
                primaryButton(title: axGranted ? "进入设置" : "去授权") {
                    if axGranted {
                        onFinish()
                    } else {
                        requestAccessibilityAccess()
                    }
                }
                if !axGranted {
                    Button("稍后开启，直接进入设置") {
                        onFinish()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var rightIllustration: some View {
        ZStack {
            // Subtle concentric rings
            ForEach(0..<4, id: \.self) { idx in
                Circle()
                    .stroke(brandBlue.opacity(0.08 - Double(idx) * 0.015), lineWidth: 1.5)
                    .frame(width: CGFloat(140 + idx * 64), height: CGFloat(140 + idx * 64))
            }

            switch step {
            case .addInputSource:
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(inputSourceAdded ? Color.green.opacity(0.15) : brandBlue.opacity(0.14))
                            .frame(width: 64, height: 64)
                        Image(systemName: inputSourceAdded ? "checkmark.circle.fill" : "keyboard")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(inputSourceAdded ? .green : brandBlue)
                    }

                    Text("系统设置 → 键盘 → 输入法")
                        .font(.system(size: 14, weight: .semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("1. 点击「输入法」右侧的「编辑…」", systemImage: "1.circle.fill")
                        Label("2. 点击左下角「+」按钮", systemImage: "2.circle.fill")
                        Label("3. 选择「简体中文 → Prime 输入法」", systemImage: "3.circle.fill")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(width: 260, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
                )

            case .microphone:
                VStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(brandBlue)
                            .frame(width: 56, height: 56)
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 4, y: 4)
                    }

                    Text("“Prime 输入法”想访问麦克风。")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Prime 输入法需要麦克风权限，以便在您按下快捷键时录制语音进行转写。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)

                    HStack(spacing: 10) {
                        Text("不允许")
                            .font(.system(size: 12.5))
                            .frame(width: 100, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                        Text("允许")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 100, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(brandBlue))
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
                )

            case .voiceShortcut:
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                                .frame(width: 56, height: 48)
                        }
                    }
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(brandBlue)
                                .frame(width: 68, height: 64)
                                .shadow(color: brandBlue.opacity(0.35), radius: 12, y: 6)
                            VStack {
                                HStack {
                                    Spacer()
                                    Text(displayShortcutLabel)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                HStack {
                                    Image(systemName: "globe")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white.opacity(0.9))
                                    Spacer()
                                }
                            }
                            .padding(8)
                            .frame(width: 68, height: 64)
                        }
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                                .frame(width: 56, height: 56)
                        }
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
                )

            case .accessibility:
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(axGranted ? Color.green.opacity(0.15) : brandBlue.opacity(0.14))
                            .frame(width: 60, height: 60)
                        Image(systemName: axGranted ? "checkmark.shield.fill" : "figure.stand")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(axGranted ? .green : brandBlue)
                    }

                    Text("隐私与安全性 → 辅助功能")
                        .font(.system(size: 14, weight: .semibold))

                    // Draggable PrimeType.app card: user can drag directly into System Settings Accessibility list or '+' picker
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PrimeType.app")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(axGranted ? "已授权" : "按住拖动到系统设置列表")
                                .font(.system(size: 11))
                                .foregroundStyle(axGranted ? .green : .secondary)
                        }
                        Spacer()
                        Image(systemName: axGranted ? "checkmark.circle.fill" : "hand.draw")
                            .font(.system(size: 17))
                            .foregroundStyle(axGranted ? .green : brandBlue)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(width: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(axGranted ? Color.green.opacity(0.35) : brandBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: axGranted ? [] : [4, 3]))
                    )
                    .onDrag {
                        NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                    }

                    if !axGranted {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        } label: {
                            Label("在访达中显示 PrimeType.app", systemImage: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
                )
            }
        }
    }

    private func stepBadge(icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(brandBlue.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(brandBlue)
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(brandBlue))
        }
        .buttonStyle(.plain)
    }

    private var displayShortcutLabel: String {
        let key = settings.shortcutVoiceHoldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? "fn" : key
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

    private func requestMicrophoneAccess() {
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

    private func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleRecordingShortcut() {
        if isRecordingShortcut {
            stopRecordingShortcut()
            return
        }
        isRecordingShortcut = true
        VoiceInputManager.isRecordingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown && event.keyCode == 0x35 {
                stopRecordingShortcut()
                return nil
            }
            if event.type == .flagsChanged {
                let modifierLabels: [UInt16: String] = [
                    63: "fn", 61: "右 ⌥", 58: "左 ⌥", 54: "右 ⌘", 55: "左 ⌘",
                    62: "右 ⌃", 59: "左 ⌃", 60: "右 ⇧", 56: "左 ⇧"
                ]
                if let label = modifierLabels[event.keyCode] {
                    settings.shortcutVoiceHoldKey = label
                    stopRecordingShortcut()
                    return nil
                }
            } else if event.type == .keyDown {
                if let formatted = VoiceShortcutFormatter.format(keyDown: event), !formatted.isEmpty {
                    settings.shortcutVoiceHoldKey = formatted
                    stopRecordingShortcut()
                    return nil
                }
            }
            return event
        }
    }

    private func stopRecordingShortcut() {
        isRecordingShortcut = false
        VoiceInputManager.isRecordingShortcut = false
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }
}
