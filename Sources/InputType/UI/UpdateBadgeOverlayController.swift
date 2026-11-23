import Cocoa
import SwiftUI

final class UpdateBadgeOverlayController {
    static let shared = UpdateBadgeOverlayController()

    private var panel: NSPanel?
    private var lastVersionText: String = ""

    private init() {}

    func showIfAvailable(below candidateWindow: NSWindow?) {
        let updater = AppUpdateManager.shared
        guard updater.hasUpdate, let rawVersion = updater.latestVersion, !rawVersion.isEmpty,
              let candidateWindow, candidateWindow.isVisible else {
            hide()
            return
        }

        let normalized = rawVersion.hasPrefix("v") || rawVersion.hasPrefix("V")
            ? "V" + rawVersion.dropFirst()
            : "V" + rawVersion
        let badgeText = "\(normalized) NEW"

        let panel = ensurePanel(badgeText: badgeText)
        let candidateFrame = candidateWindow.frame
        let badgeSize = panel.frame.size
        let origin = NSPoint(
            x: candidateFrame.minX + 6,
            y: candidateFrame.minY - badgeSize.height - 4
        )
        panel.setFrameOrigin(origin)
        panel.level = NSWindow.Level(rawValue: candidateWindow.level.rawValue + 1)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel(badgeText: String) -> NSPanel {
        if let existing = panel, lastVersionText == badgeText {
            return existing
        }
        lastVersionText = badgeText

        let hosting = NSHostingView(rootView: UpdateBadgePillView(text: badgeText) { [weak self] in
            self?.hide()
            SettingsWindowController.shared.show()
        })
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 72), height: max(fitting.height, 20))
        hosting.frame = NSRect(origin: .zero, size: size)

        let p: NSPanel = panel ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = hosting
        p.setContentSize(size)
        self.panel = p
        return p
    }
}

private struct UpdateBadgePillView: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.25, green: 0.16, blue: 0.0))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.99, green: 0.86, blue: 0.42),
                                    Color(red: 0.93, green: 0.72, blue: 0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(Color(red: 0.78, green: 0.56, blue: 0.10).opacity(0.6), lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
