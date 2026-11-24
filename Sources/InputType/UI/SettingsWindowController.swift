import AVFoundation
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case input
    case shortcuts
    case voice
    case phrasesAndClipboard
    case dictionary
    case provider
    case translate
    case rewrite
    case advanced
    case updates
    case about

    var id: String { rawValue }

    static let basicSections: [SettingsSection] = [
        .input,
        .shortcuts,
        .voice,
        .phrasesAndClipboard,
        .dictionary
    ]

    static let quickActionSections: [SettingsSection] = [
        .provider,
        .translate,
        .rewrite
    ]

    static let otherSections: [SettingsSection] = [
        .advanced,
        .updates,
        .about
    ]

    var title: String {
        switch self {
        case .input: return "输入"
        case .shortcuts: return "快捷键"
        case .voice: return "语音输入"
        case .phrasesAndClipboard: return "常用语和剪贴板"
        case .dictionary: return "词库"
        case .provider: return "提供商"
        case .translate: return "翻译"
        case .rewrite: return "改写"
        case .advanced: return "高级功能"
        case .updates: return "更新管理"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .input: return "keyboard.fill"
        case .shortcuts: return "command"
        case .voice: return "waveform.badge.mic"
        case .phrasesAndClipboard: return "cube"
        case .dictionary: return "books.vertical"
        case .provider: return "server.rack"
        case .translate: return "globe"
        case .rewrite: return "wand.and.stars"
        case .advanced: return "slider.horizontal.3"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

private struct GitHubMarkIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24.0
        let sy = rect.height / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        p.move(to: pt(12, 0.297))
        p.addCurve(to: pt(0, 12.297), control1: pt(5.37, 0.297), control2: pt(0, 5.67))
        p.addCurve(to: pt(8.205, 23.682), control1: pt(0, 17.6), control2: pt(3.438, 22.097))
        p.addCurve(to: pt(9.025, 23.105), control1: pt(8.805, 23.795), control2: pt(9.025, 23.424))
        p.addCurve(to: pt(9.01, 21.06), control1: pt(9.025, 22.82), control2: pt(9.015, 22.065))
        p.addCurve(to: pt(4.97, 20.13), control1: pt(5.672, 21.789), control2: pt(4.97, 19.455))
        p.addCurve(to: pt(3.635, 18.375), control1: pt(4.422, 18.74), control2: pt(3.633, 18.37))
        p.addCurve(to: pt(3.718, 17.673), control1: pt(2.546, 17.63), control2: pt(3.718, 17.645))
        p.addCurve(to: pt(5.555, 18.91), control1: pt(4.922, 17.757), control2: pt(5.555, 18.91))
        p.addCurve(to: pt(9.07, 19.73), control1: pt(6.625, 20.743), control2: pt(8.364, 20.213))
        p.addCurve(to: pt(9.83, 18.126), control1: pt(9.18, 18.955), control2: pt(9.49, 18.426))
        p.addCurve(to: pt(4.365, 12.195), control1: pt(7.165, 17.824), control2: pt(4.365, 16.794))
        p.addCurve(to: pt(5.605, 8.98), control1: pt(4.365, 10.885), control2: pt(4.835, 9.815))
        p.addCurve(to: pt(5.725, 5.81), control1: pt(5.48, 8.675), control2: pt(5.068, 7.45))
        p.addCurve(to: pt(9.025, 7.04), control1: pt(5.725, 5.81), control2: pt(6.735, 5.488))
        p.addCurve(to: pt(12.025, 6.635), control1: pt(9.985, 6.773), control2: pt(11.01, 6.638))
        p.addCurve(to: pt(15.025, 7.04), control1: pt(13.04, 6.638), control2: pt(14.065, 6.773))
        p.addCurve(to: pt(18.32, 5.81), control1: pt(17.31, 5.488), control2: pt(18.32, 5.81))
        p.addCurve(to: pt(18.44, 8.98), control1: pt(18.978, 7.45), control2: pt(18.565, 8.675))
        p.addCurve(to: pt(19.675, 12.195), control1: pt(19.21, 9.815), control2: pt(19.675, 10.885))
        p.addCurve(to: pt(14.195, 18.116), control1: pt(19.675, 16.805), control2: pt(16.87, 17.82))
        p.addCurve(to: pt(15.01, 20.335), control1: pt(14.625, 18.486), control2: pt(15.01, 19.216))
        p.addCurve(to: pt(14.995, 23.105), control1: pt(15.01, 21.935), control2: pt(14.995, 22.82))
        p.addCurve(to: pt(15.82, 23.68), control1: pt(14.995, 23.428), control2: pt(15.213, 23.802))
        p.addCurve(to: pt(24, 12.297), control1: pt(20.57, 22.094), control2: pt(24, 17.597))
        p.addCurve(to: pt(12, 0.297), control1: pt(24, 5.67), control2: pt(18.627, 0.297))
        p.closeSubpath()
        return p
    }
}

private struct SettingRowTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct KeycapBadge: View {
    let text: String
    var minWidth: CGFloat = 28

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            )
    }
}

private struct SettingsControlPillBackground: ViewModifier {
    var isHighlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
    }
}

private struct HotKeyRecorderControl: View {
    @Binding var hotKey: HotKeyConfig?
    let defaultHotKey: HotKeyConfig

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        ZStack {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (hotKey == nil ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85)))
                    .lineLimit(1)
                    .padding(.horizontal, 26)
                    .frame(minWidth: 120, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button {
                    stopRecording()
                    if hotKey == nil {
                        hotKey = defaultHotKey
                    } else {
                        hotKey = nil
                    }
                } label: {
                    Image(systemName: hotKey == nil ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(hotKey == nil ? "恢复默认快捷键" : "清除快捷键")
                .padding(.trailing, 7)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .modifier(SettingsControlPillBackground(isHighlighted: isRecording))
        .onDisappear {
            stopRecording()
        }
    }

    private var displayLabel: String {
        if isRecording {
            return "按下快捷键..."
        }
        return hotKey?.displayString ?? "点击录制"
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { // Escape cancels recording
                stopRecording()
                return nil
            }
            if let captured = HotKeyConfig.from(event: event) {
                hotKey = captured
                stopRecording()
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private struct ClearableShortcutBadge: View {
    @Binding var shortcutText: String
    let defaultText: String

    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var pendingSingleModifierCode: UInt16?

    var body: some View {
        ZStack {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isRecording
                            ? Color.accentColor
                            : (shortcutText.isEmpty ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    .padding(.horizontal, 26)
                    .frame(minWidth: 120, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button {
                    stopRecording()
                    shortcutText = shortcutText.isEmpty ? defaultText : ""
                } label: {
                    Image(systemName: shortcutText.isEmpty ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(shortcutText.isEmpty ? "恢复默认快捷键 (\(defaultText))" : "清除快捷键")
                .padding(.trailing, 7)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .modifier(SettingsControlPillBackground(isHighlighted: isRecording))
        .onDisappear {
            stopRecording()
        }
    }

    private var displayLabel: String {
        if isRecording {
            return "按下快捷键..."
        }
        return shortcutText.isEmpty ? "点击录制" : shortcutText
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        pendingSingleModifierCode = nil
        VoiceInputManager.isRecordingShortcut = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                pendingSingleModifierCode = nil
                if event.keyCode == 0x35 { // Escape cancels recording
                    stopRecording()
                    return nil
                }
                if let formatted = VoiceShortcutFormatter.format(keyDown: event) {
                    shortcutText = formatted
                    stopRecording()
                    return nil
                }
                NSSound.beep()
                return nil
            }

            if event.type == .flagsChanged {
                let code = event.keyCode
                guard let modLabel = VoiceShortcutFormatter.singleModifierKeyCodes[code] else {
                    return nil
                }
                let isPressed: Bool
                switch code {
                case 63: isPressed = event.modifierFlags.contains(.function)
                case 61, 58: isPressed = event.modifierFlags.contains(.option)
                case 54, 55: isPressed = event.modifierFlags.contains(.command)
                case 62, 59: isPressed = event.modifierFlags.contains(.control)
                case 60, 56: isPressed = event.modifierFlags.contains(.shift)
                default: isPressed = false
                }

                if isPressed {
                    // Only allow single-modifier recording if no other modifier was already held
                    pendingSingleModifierCode = (pendingSingleModifierCode == nil) ? code : 0xFFFF
                } else if pendingSingleModifierCode == code {
                    shortcutText = modLabel
                    stopRecording()
                }
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        pendingSingleModifierCode = nil
        VoiceInputManager.isRecordingShortcut = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private struct InputSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @State private var showAutoPairSheet = false
    @State private var showFuzzyPinyinSheet = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.smartSpelling) {
                    SettingRowTitle(
                        "智能拼写",
                        subtitle: "精准匹配候选词，大幅提升打字效率"
                    )
                }
                .toggleStyle(.switch)
            }

            Section {
                Toggle(isOn: $settings.autoConvertSymbols) {
                    SettingRowTitle(
                        "符号自动转换",
                        subtitle: "数字间部分符号处理为英文标点，例如 12：00 替换为 12:00"
                    )
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.autoNumbering) {
                    SettingRowTitle(
                        "自动编号",
                        subtitle: "输入编号后换行，自动填充下一个编号。例如输入 1. 换行后自动填充 2."
                    )
                }
                .toggleStyle(.switch)

                LabeledContent {
                    Button(settings.autoPairEnabled ? "设置..." : "启用...") {
                        showAutoPairSheet = true
                    }
                } label: {
                    SettingRowTitle(
                        "符号自动补全",
                        subtitle: "自动补全成对符号的右半部分，例如输入左括号（ 时，将自动补全右括号 ）"
                    )
                }

                LabeledContent {
                    Button("设置...") {
                        showFuzzyPinyinSheet = true
                    }
                } label: {
                    SettingRowTitle("模糊拼音")
                }
            }

            Section {
                Toggle(isOn: $settings.slashToEnumerationComma) {
                    SettingRowTitle("输入中文时，将「/?」按键替换为 、")
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.autoSpaceChineseEnglish) {
                    SettingRowTitle("中文与英文间自动添加空格")
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.autoSpaceChineseNumber) {
                    SettingRowTitle("中文与数字间自动添加空格")
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAutoPairSheet) {
            AutoPairSheet(settings: settings)
        }
        .sheet(isPresented: $showFuzzyPinyinSheet) {
            FuzzyPinyinSheet(settings: settings)
        }
    }
}

private struct ShortcutsSettingsView: View {
    @ObservedObject var settings = InputSettings.shared

    var body: some View {
        Form {
            // 1. 切换状态
            Section("切换状态") {
                HStack {
                    Toggle("简繁体输入切换", isOn: $settings.shortcutTraditional)
                        .toggleStyle(.checkbox)
                    Spacer()
                    KeycapBadge(text: "⌥ ⇧ F", minWidth: 64)
                }

                HStack {
                    Toggle("全半角输入切换", isOn: $settings.shortcutFullShape)
                        .toggleStyle(.checkbox)
                    Spacer()
                    KeycapBadge(text: "⌥ ⇧ H", minWidth: 64)
                }

                HStack {
                    Toggle("中文下中英标点切换", isOn: $settings.shortcutAsciiPunct)
                        .toggleStyle(.checkbox)
                    Spacer()
                    KeycapBadge(text: "⌥ ⇧ 。", minWidth: 64)
                }
            }

            // 2. 快捷使用
            Section("快捷使用") {
                HStack(alignment: .center) {
                    Toggle(isOn: $settings.shortcutVMode) {
                        SettingRowTitle(
                            "V 模式",
                            subtitle: "按「v」打开快捷功能栏，可使用计算、剪贴板、常用语、符号等功能"
                        )
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    KeycapBadge(text: "V")
                }

                HStack(alignment: .center) {
                    Toggle(isOn: $settings.clipboardEnabled) {
                        SettingRowTitle(
                            "打开剪贴板窗口",
                            subtitle: "随时呼出独立剪贴板历史弹窗，支持文本与图像检索粘贴"
                        )
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    HotKeyRecorderControl(
                        hotKey: $settings.clipboardHotKey,
                        defaultHotKey: .defaultClipboard
                    )
                }
            }

            // 4. 翻页找字
            Section {
                HStack {
                    Toggle("减号等号", isOn: $settings.pageMinusEqual)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 12) {
                        KeycapBadge(text: "−", minWidth: 34)
                        KeycapBadge(text: "=", minWidth: 34)
                    }
                }

                HStack {
                    Toggle("左右中括号", isOn: $settings.pageBrackets)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 12) {
                        KeycapBadge(text: "[", minWidth: 34)
                        KeycapBadge(text: "]", minWidth: 34)
                    }
                }

                HStack {
                    Toggle("逗号句号", isOn: $settings.pageCommaPeriod)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 12) {
                        KeycapBadge(text: "，", minWidth: 34)
                        KeycapBadge(text: "。", minWidth: 34)
                    }
                }

                HStack {
                    Toggle("shift + tab / tab", isOn: $settings.pageTab)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 12) {
                        KeycapBadge(text: "⇧ ⇥", minWidth: 44)
                        KeycapBadge(text: "⇥", minWidth: 34)
                    }
                }
            } header: {
                HStack {
                    Text("翻页找字")
                    Spacer()
                    HStack(spacing: 16) {
                        Text("向上翻")
                        Text("向下翻")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                }
            }

            // 6. 候选词选择
            Section("候选词选择") {
                HStack {
                    Toggle("使用分号、引号选择第 2 位、第 3 位候选词", isOn: $settings.selectWithSemicolonQuote)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 6) {
                        KeycapBadge(text: ";", minWidth: 28)
                        KeycapBadge(text: "'", minWidth: 28)
                    }
                }

                HStack {
                    Toggle("使用左右 command 选择第 2 位、第 3 位候选词", isOn: $settings.selectWithLeftRightCommand)
                        .toggleStyle(.checkbox)
                    Spacer()
                    HStack(spacing: 6) {
                        KeycapBadge(text: "⌘", minWidth: 28)
                        KeycapBadge(text: "␣", minWidth: 34)
                        KeycapBadge(text: "⌘", minWidth: 28)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutoPairSheet: View {
    @ObservedObject var settings: InputSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("启用符号自动补全", isOn: $settings.autoPairEnabled)
                        .toggleStyle(.switch)
                }

                Section("需要自动补全的成对符号") {
                    ForEach(SymbolPair.all) { pair in
                        Toggle(pair.label, isOn: Binding(
                            get: { settings.enabledPairIDs.contains(pair.id) },
                            set: { enabled in
                                if enabled {
                                    settings.enabledPairIDs.insert(pair.id)
                                } else {
                                    settings.enabledPairIDs.remove(pair.id)
                                }
                            }
                        ))
                        .disabled(!settings.autoPairEnabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 420)
    }
}

private struct FuzzyPinyinSheet: View {
    @ObservedObject var settings: InputSettings
    @Environment(\.dismiss) private var dismiss

    private let initialRules = FuzzyPinyinRule.allCases.filter { $0.isInitial }
    private let finalRules = FuzzyPinyinRule.allCases.filter { !$0.isInitial }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("启用模糊拼音", isOn: $settings.fuzzyPinyinEnabled)
                        .toggleStyle(.switch)
                }

                Section("声母模糊音") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(initialRules) { rule in
                            Toggle(rule.label, isOn: binding(for: rule))
                                .disabled(!settings.fuzzyPinyinEnabled)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("韵母模糊音") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(finalRules) { rule in
                            Toggle(rule.label, isOn: binding(for: rule))
                                .disabled(!settings.fuzzyPinyinEnabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("修改后将自动重新部署生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
    }

    private func binding(for rule: FuzzyPinyinRule) -> Binding<Bool> {
        Binding(
            get: { settings.fuzzyRules.contains(rule) },
            set: { enabled in
                if enabled {
                    settings.fuzzyRules.insert(rule)
                } else {
                    settings.fuzzyRules.remove(rule)
                }
            }
        )
    }
}

private struct NativeToolbarSegmentedControl: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentStyle = .automatic
        control.selectedSegment = selection
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        if nsView.selectedSegment != selection {
            nsView.selectedSegment = selection
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            selection.wrappedValue = sender.selectedSegment
        }
    }
}

private struct PhrasesAndClipboardSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @ObservedObject var clipboard = ClipboardManager.shared

    @State private var selectedTab = 0
    @State private var showAddPhraseSheet = false
    @State private var editingPhrase: CustomPhrase?
    @State private var importMessage: String?
    @State private var accessibilityGranted = ClipboardManager.shared.isAccessibilityTrusted

    var body: some View {
        ZStack {
            phrasesTab
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)

            clipboardTab
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NativeToolbarSegmentedControl(
                    labels: ["常用语", "剪贴板"],
                    selection: $selectedTab
                )
            }
        }
        .sheet(isPresented: $showAddPhraseSheet) {
            PhraseEditorSheet(phrase: nil) { code, content in
                settings.addPhrase(code: code, content: content)
            }
        }
        .sheet(item: $editingPhrase) { phrase in
            PhraseEditorSheet(phrase: phrase) { code, content in
                var updated = phrase
                updated.code = code
                updated.content = content
                settings.updatePhrase(updated)
            }
        }
    }

    private static let sampleYunnanAddresses: [String] = [
        "云南省昆明市五华区翠湖南路18号3栋2楼 李明",
        "云南省大理白族自治州大理市苍山路66号1单元402 王芳",
        "云南省丽江市古城区福慧路128号5栋3楼 陈宇",
        "云南省昆明市盘龙区北京路985号2栋12楼 林然",
        "云南省玉溪市红塔区凤凰路52号4栋6楼 周晨"
    ]

    @State private var sampleAddress: String = sampleYunnanAddresses.randomElement()
        ?? "云南省昆明市五华区翠湖南路18号3栋2楼 李明"

    private var phrasesTab: some View {
        VStack(spacing: 0) {
            if settings.customPhrases.isEmpty {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 2) {
                                    Text("yns")
                                        .font(.system(size: 16, weight: .medium))
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(width: 1.5, height: 18)
                                }

                                HStack(spacing: 10) {
                                    Text("1 \(sampleAddress)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color.accentColor)
                                        )
                                    Text("2 云南省")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor))
                                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )

                            Text("添加文字到「常用语」后，输入前 3 个字或其拼音首字母即可使用")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .formStyle(.grouped)
            } else {
                Form {
                    Section("已添加的常用语（输入触发码或前 3 字首字母调用，按 vc 可浏览全部）") {
                        ForEach(settings.customPhrases) { phrase in
                            HStack(spacing: 10) {
                                KeycapBadge(text: phrase.code.isEmpty ? "自动" : phrase.code, minWidth: 44)
                                Text(phrase.content)
                                    .lineLimit(2)
                                Spacer()
                                Button {
                                    editingPhrase = phrase
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    settings.removePhrase(id: phrase.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack(spacing: 10) {
                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入系统短语") {
                    let count = settings.importSystemTextReplacements()
                    importMessage = count > 0 ? "已导入 \(count) 条系统短语" : "没有新的系统短语可导入"
                }
                Button("添加") {
                    showAddPhraseSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var clipboardTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.clipboardEnabled) {
                    SettingRowTitle(
                        "剪贴板",
                        subtitle: "复制的内容将在剪贴板中展示"
                    )
                }
                .toggleStyle(.switch)

                LabeledContent {
                    HotKeyRecorderControl(
                        hotKey: $settings.clipboardHotKey,
                        defaultHotKey: .defaultClipboard
                    )
                } label: {
                    SettingRowTitle(
                        "打开剪贴板快捷键",
                        subtitle: "点击右侧录入自定义全局快捷键，随时呼出独立剪贴板弹窗"
                    )
                }

                LabeledContent {
                    Picker("", selection: $settings.clipboardRetentionDays) {
                        ForEach(ClipboardRetentionDays.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!settings.clipboardEnabled)
                } label: {
                    SettingRowTitle(
                        "剪贴板保留时间",
                        subtitle: "自动清理超过保留期限的历史记录与图片"
                    )
                }

                LabeledContent {
                    Button("打开剪贴板窗口") {
                        ClipboardPanelController.shared.show()
                    }
                    .disabled(!settings.clipboardEnabled)
                } label: {
                    SettingRowTitle(
                        "独立弹窗预览",
                        subtitle: "支持文本、图像、链接历史记录与按来源/类型筛选"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PhraseEditorSheet: View {
    let phrase: CustomPhrase?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var code: String
    @State private var userEditedCode: Bool
    @FocusState private var isContentFocused: Bool

    init(phrase: CustomPhrase?, onSave: @escaping (String, String) -> Void) {
        self.phrase = phrase
        self.onSave = onSave
        _content = State(initialValue: phrase?.content ?? "")
        _code = State(initialValue: phrase?.code ?? "")
        _userEditedCode = State(initialValue: phrase != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    HStack(spacing: 0) {
                        Text("内")
                        Spacer(minLength: 0)
                        Text("容")
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .frame(width: 44)
                    .padding(.top, 2)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $content)
                            .font(.system(size: 13.5))
                            .scrollContentBackground(.hidden)
                            .focused($isContentFocused)
                            .padding(.top, -1)
                            .padding(.leading, -5)
                            .frame(height: 54)
                            .onChange(of: content) { _, newValue in
                                if !userEditedCode {
                                    code = CustomPhrase.suggestedCode(for: newValue)
                                }
                            }

                        if content.isEmpty {
                            Text("输入常用语")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 14)

                HStack(alignment: .center, spacing: 14) {
                    Text("输入码")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.primary)
                        .frame(width: 44, alignment: .leading)

                    TextField(
                        "",
                        text: $code,
                        prompt: Text("默认输入码为前3个字或其拼音首字母")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onChange(of: code) { _, newValue in
                        let suggested = CustomPhrase.suggestedCode(for: content)
                        if newValue != suggested {
                            userEditedCode = !newValue.isEmpty
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
            )
            .padding(16)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(phrase == nil ? "添加" : "保存") {
                    onSave(code, content)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            DispatchQueue.main.async {
                isContentFocused = true
            }
        }
    }
}

private struct DiscoveredDictFile: Identifiable {
    let id: String
    let filename: String
    let displayName: String
    let formattedSize: String
}

private struct DictionarySettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @State private var statusMessage: String?
    @State private var switchingTarget: DictionaryPreset?
    @State private var isRedeploying = false

    private static let friendlyDictNames: [String: String] = [
        // 雾凇拼音
        "8105.dict.yaml": "8105 常用字表",
        "41448.dict.yaml": "41448 大字表",
        "base.dict.yaml": "基础词库（base）",
        "ext.dict.yaml": "扩展词库（ext）",
        "tencent.dict.yaml": "腾讯词向量（tencent）",
        "others.dict.yaml": "其他补充（others）",
        // 万象拼音
        "zi.dict.yaml": "单字字表（zi）",
        "jichu.dict.yaml": "基础词库（jichu）",
        "cuoyin.dict.yaml": "错音错字（cuoyin）",
        "duoyin.dict.yaml": "多音兼容（duoyin）",
        "diming.dict.yaml": "地名词库（diming）",
        "mingren.dict.yaml": "名人词库（mingren）",
        "yiren.dict.yaml": "艺人词库（yiren）",
        "yixue.dict.yaml": "医学词库（yixue）",
        "huaxue.dict.yaml": "化学词库（huaxue）",
        "yaopin.dict.yaml": "药品词库（yaopin）",
        "lianxiang.dict.yaml": "联想词库（lianxiang）",
        // 薄荷拼音
        "custom_simple.dict.yaml": "自定义短语（custom_simple）",
        "rime_mint.chars.dict.yaml": "单字字表（rime_mint.chars）",
        "rime_mint.base.dict.yaml": "基础词库（rime_mint.base）",
        "rime_mint.correlation.dict.yaml": "错音错字（correlation）",
        "rime_mint.compatible.dict.yaml": "多音兼容（compatible）",
        "rime_mint.places.dict.yaml": "地名词库（places）",
        "rime_mint.artists.dict.yaml": "艺人姓名（artists）",
        "rime_mint.famous.dict.yaml": "名人姓名（famous）",
        "other_kaomoji.dict.yaml": "颜文字表情（other_kaomoji）",
        "rime_ice.others.dict.yaml": "雾凇纠错补充（rime_ice.others）"
    ]

    var body: some View {
        Form {
            Section {
                ForEach(DictionaryPreset.allCases) { preset in
                    presetRow(preset)
                }
            } header: {
                Text("预置主流词库")
            } footer: {
                HStack(spacing: 6) {
                    if settings.isSwitchingDictionary {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在切换并部署「\(switchingTarget?.displayName ?? settings.selectedDictionary.displayName)」，首次切换编译索引约需数秒…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("三套词库共享同一份用户词频与自造词库，切换词库不会丢失打字习惯；首次切换到新词库将自动编译索引，之后可秒切。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("当前词库包含的词表（\(settings.selectedDictionary.displayName)）") {
                let files = discoveredDictFiles(for: settings.selectedDictionary)
                if files.isEmpty {
                    Text("未检测到词表文件")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                Text(item.filename)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(item.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            Section("词库目录与部署") {
                LabeledContent {
                    Button("在访达中打开") {
                        let path = RimeEngine.shared.userDataDir(for: settings.selectedDictionary)
                        let url = URL(fileURLWithPath: path)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    SettingRowTitle(
                        "当前词库用户目录",
                        subtitle: RimeEngine.shared.userDataDir(for: settings.selectedDictionary)
                    )
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        if isRedeploying {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("重新部署当前词库") {
                            redeployCurrentDictionary()
                        }
                        .disabled(settings.isSwitchingDictionary || isRedeploying)
                    }
                } label: {
                    SettingRowTitle(
                        "重建 Rime 词库索引",
                        subtitle: "修改用户目录中的自定义词库后，点击重新编译加载"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func presetRow(_ preset: DictionaryPreset) -> some View {
        let isSelected = (settings.selectedDictionary == preset)
        let isAvailable = RimeEngine.shared.isPresetAvailable(preset)
        let isThisSwitching = settings.isSwitchingDictionary && switchingTarget == preset

        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.displayName)
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    Text(preset.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                Text(preset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isThisSwitching {
                ProgressView()
                    .controlSize(.small)
            } else if isSelected {
                Text("当前使用")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.14))
                    )
            } else if !isAvailable {
                Text("未内置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isSelected && isAvailable && !settings.isSwitchingDictionary && !isRedeploying {
                selectPreset(preset)
            }
        }
    }

    private func selectPreset(_ preset: DictionaryPreset) {
        switchingTarget = preset
        statusMessage = nil
        settings.switchDictionary(to: preset) {
            switchingTarget = nil
            statusMessage = "已切换至「\(preset.displayName)」，在任意应用中直接输入即可生效"
        }
    }

    private func redeployCurrentDictionary() {
        isRedeploying = true
        let preset = settings.selectedDictionary
        statusMessage = "正在重新部署「\(preset.displayName)」…"
        DispatchQueue.global(qos: .userInitiated).async {
            settings.writeRimeCustomYAML(for: preset)
            RimeEngine.shared.deploy(waitForMaintenance: true)
            DispatchQueue.main.async {
                isRedeploying = false
                statusMessage = "「\(preset.displayName)」已重新部署完成"
            }
        }
    }

    private func discoveredDictFiles(for preset: DictionaryPreset) -> [DiscoveredDictFile] {
        let dir = (RimeEngine.shared.sharedDataDir(for: preset) as NSString)
            .appendingPathComponent(preset.dictSubdirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".dict.yaml") }
            .sorted()
            .compactMap { filename in
                let fullPath = (dir as NSString).appendingPathComponent(filename)
                let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int64) ?? 0
                let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let label = Self.friendlyDictNames[filename] ?? filename.replacingOccurrences(of: ".dict.yaml", with: "")
                return DiscoveredDictFile(
                    id: "\(preset.rawValue)/\(filename)",
                    filename: filename,
                    displayName: label,
                    formattedSize: sizeText
                )
            }
    }
}

private struct VoiceCookieSheet: View {
    let channel: VoiceCloudChannel
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookieText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VoiceChannelIconView(channel: channel, size: 32, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("配置「\(channel.displayName)」登录 Cookie")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(channel.cookieHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $cookieText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 100)

                    if cookieText.isEmpty {
                        Text("在此粘贴完整的 Cookie 字符串…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            errorMessage != nil ? Color.red.opacity(0.65) : Color.primary.opacity(0.12),
                            lineWidth: 0.8
                        )
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let urlStr = channel.loginURLString, let url = URL(string: urlStr) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                            Text("在浏览器打开官方登录页")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                }
            }

            Divider()

            HStack(spacing: 8) {
                if VoiceInputManager.shared.hasAccountCookie(for: channel) {
                    Button("清除已保存登录", role: .destructive) {
                        _ = VoiceInputManager.shared.setAccountCookie("", for: channel)
                        onSaved()
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("验证并保存") {
                    if VoiceInputManager.shared.setAccountCookie(cookieText, for: channel) {
                        onSaved()
                        dismiss()
                    } else {
                        errorMessage = "未检测到有效的登录 Cookie 字段，请检查后重试"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VoiceIntroBannerView: View {
    private static let waveformHeights: [CGFloat] = [7, 13, 21, 9, 15, 10, 10, 15, 11, 21, 14, 8]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                HStack(alignment: .center, spacing: 3.5) {
                    ForEach(Array(Self.waveformHeights.enumerated()), id: \.offset) { _, barHeight in
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.20))
                            .frame(width: 2.5, height: barHeight)
                    }
                }
                .frame(width: 96, alignment: .trailing)

                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.065))
                        .frame(width: 48, height: 48)
                    Image(systemName: "mic")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.68))
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Hello")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.22))
                    Text("你好")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.13))
                }
                .frame(width: 96, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 18)

            Divider()
                .opacity(0.65)

            VStack(alignment: .leading, spacing: 11) {
                featureRow(systemImage: "waveform", text: "语音实时流式转写到输入框，随说随出又快又准")
                featureRow(systemImage: "keyboard", text: "支持长按说话与点按自动断句，零延迟随时开口")
                featureRow(systemImage: "globe", text: "内置五大云端语音识别引擎，一键切换无需配置密钥")
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 4)
    }

    private func featureRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.84))
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.primary)
        }
    }
}

private struct VoiceSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @ObservedObject var voice = VoiceInputManager.shared

    @State private var microphones: [VoiceMicrophoneDevice] = VoiceMicrophoneDevice.all()
    @State private var systemSounds: [String] = VoiceSystemSoundPlayer.availableSystemSounds()
    @State private var editingCookieChannel: VoiceCloudChannel?
    @State private var cookieRefreshTick: Int = 0

    var body: some View {
        Form {
            Section {
                VoiceIntroBannerView()
            }

            Section {
                HStack(alignment: .center) {
                    Toggle(isOn: $settings.shortcutVoiceStart) {
                        SettingRowTitle(
                            "启动语音输入",
                            subtitle: "按下可开启语音输入，按任意键均可结束"
                        )
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    ClearableShortcutBadge(shortcutText: $settings.shortcutVoiceStartKey, defaultText: "fn 空格")
                }

                HStack(alignment: .center) {
                    Toggle(isOn: $settings.shortcutVoiceHold) {
                        SettingRowTitle(
                            "按住说话",
                            subtitle: "按住可语音输入，松手结束"
                        )
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    ClearableShortcutBadge(shortcutText: $settings.shortcutVoiceHoldKey, defaultText: "fn")
                }

                HStack(alignment: .center, spacing: 12) {
                    SettingRowTitle(
                        "静音自动结束",
                        subtitle: "不支持按住说话"
                    )
                    Spacer(minLength: 12)
                    if settings.voiceSilenceAutoStop {
                        Slider(
                            value: Binding(
                                get: { settings.voiceSilenceDuration },
                                set: { settings.voiceSilenceDuration = ($0 * 10).rounded() / 10 }
                            ),
                            in: 0.8...4.0
                        )
                        .frame(width: 120)
                        Text(String(format: "%.1f 秒", settings.voiceSilenceDuration))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Toggle("", isOn: $settings.voiceSilenceAutoStop)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                HStack(alignment: .center, spacing: 12) {
                    SettingRowTitle(
                        "录音时降低音量",
                        subtitle: "减少背景声音的干扰，结束后自动恢复"
                    )
                    Spacer(minLength: 12)
                    if settings.voiceDuckVolumeEnabled {
                        Slider(
                            value: Binding(
                                get: { settings.voiceDuckVolumePercent },
                                set: { settings.voiceDuckVolumePercent = ($0 / 5).rounded() * 5 }
                            ),
                            in: 10...100
                        )
                        .frame(width: 120)
                        Text("−\(Int(settings.voiceDuckVolumePercent))%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Toggle("", isOn: $settings.voiceDuckVolumeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                LabeledContent {
                    Picker("", selection: $settings.voiceMicrophoneUID) {
                        Text("系统默认麦克风").tag("")
                        ForEach(microphones) { mic in
                            Text(mic.name).tag(mic.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: settings.voiceMicrophoneUID) { _, _ in
                        VoiceInputManager.shared.syncMicrophonePreference()
                    }
                } label: {
                    SettingRowTitle("麦克风设备")
                }

                Toggle(isOn: $settings.voiceAlwaysOnMic) {
                    SettingRowTitle(
                        "麦克风预热",
                        subtitle: "麦克风后台常驻"
                    )
                }
                .toggleStyle(.switch)
                .onChange(of: settings.voiceAlwaysOnMic) { _, enabled in
                    VoiceInputManager.shared.handleAlwaysOnSettingChanged(enabled)
                }
            } header: {
                Text("基础设置")
            }

            Section {
                Toggle(isOn: $settings.voiceSoundEnabled) {
                    SettingRowTitle(
                        "提示音",
                        subtitle: "录音各阶段播放提示音"
                    )
                }
                .toggleStyle(.switch)

                soundCueRow(
                    title: "录音开始",
                    subtitle: "开始录入语音时",
                    selection: $settings.voiceSoundStart
                )

                soundCueRow(
                    title: "识别处理",
                    subtitle: "录音结束，进入识别处理",
                    selection: $settings.voiceSoundStop
                )

                soundCueRow(
                    title: "识别失败",
                    subtitle: "出错、超时或没有内容时",
                    selection: $settings.voiceSoundError
                )
            } header: {
                Text("提示音")
            }

            Section {
                ForEach(VoiceCloudChannel.allCases) { channel in
                    channelRow(channel)
                }
            } header: {
                Text("语音识别服务")
            } footer: {
                let _ = cookieRefreshTick
                Text("支持 5 个云端语音识别渠道：豆包、微信、Chatterfly、千问输入法免登录即用；八哥说支持配置有道账号 Cookie。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingCookieChannel) { channel in
            VoiceCookieSheet(channel: channel) {
                cookieRefreshTick &+= 1
            }
        }
        .onAppear {
            microphones = VoiceMicrophoneDevice.all()
            systemSounds = VoiceSystemSoundPlayer.availableSystemSounds()
        }
    }

    @ViewBuilder
    private func soundCueRow(title: String, subtitle: String, selection: Binding<String>) -> some View {
        let current = selection.wrappedValue
        HStack(alignment: .center, spacing: 10) {
            SettingRowTitle(title, subtitle: subtitle)
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                Text("不发声").tag("")
                Divider()
                ForEach(systemSounds, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Button("试听") {
                VoiceSystemSoundPlayer.play(named: current)
            }
            .disabled(current.isEmpty || !settings.voiceSoundEnabled)
        }
        .disabled(!settings.voiceSoundEnabled)
        .opacity(settings.voiceSoundEnabled ? 1.0 : 0.55)
    }

    @ViewBuilder
    private func channelRow(_ channel: VoiceCloudChannel) -> some View {
        let isPrimary = (settings.voicePrimaryChannel == channel)
        let hasCookie = voice.hasAccountCookie(for: channel)

        HStack(spacing: 12) {
            Image(systemName: isPrimary ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isPrimary ? Color.accentColor : Color.secondary.opacity(0.5))

            VoiceChannelIconView(channel: channel, size: 26, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.system(size: 13.5, weight: isPrimary ? .semibold : .medium))
                    if channel.requiresAccountCookie {
                        Text(hasCookie ? "已配置账号" : "需登录 Cookie")
                            .font(.caption2)
                            .foregroundStyle(hasCookie ? .green : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill((hasCookie ? Color.green : Color.orange).opacity(0.14))
                            )
                    }
                }
                Text(channel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if channel.requiresAccountCookie {
                Button(hasCookie ? "修改 Cookie" : "配置 Cookie") {
                    editingCookieChannel = channel
                }
                .controlSize(.small)
            }

            if isPrimary {
                Text("当前使用")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.14))
                    )
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if channel.requiresAccountCookie && !hasCookie {
                editingCookieChannel = channel
            } else {
                settings.voicePrimaryChannel = channel
                voice.prewarm(channel: channel)
            }
        }
    }
}

private struct SidebarIconView: View {
    let section: SettingsSection

    private static var cache: [String: NSImage] = [:]

    private var iconImage: NSImage? {
        if let cached = Self.cache[section.rawValue] {
            return cached
        }
        if let resPath = Bundle.main.resourcePath {
            let path = "\(resPath)/SidebarIcons/\(section.rawValue).png"
            if let img = NSImage(contentsOfFile: path) {
                Self.cache[section.rawValue] = img
                return img
            }
        }
        return nil
    }

    var body: some View {
        if let img = iconImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: section.systemImage)
                .frame(width: 20, height: 20)
        }
    }
}

private struct SettingsRootView: View {
    @State private var selectedSection: SettingsSection? = .input

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("PrimeType")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Prime 输入法")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)

                List(selection: $selectedSection) {
                    Section("基础设置") {
                        ForEach(SettingsSection.basicSections) { section in
                            HStack(spacing: 8) {
                                SidebarIconView(section: section)
                                Text(section.title)
                            }
                            .tag(section)
                        }
                    }

                    Section("快速操作") {
                        ForEach(SettingsSection.quickActionSections) { section in
                            HStack(spacing: 8) {
                                SidebarIconView(section: section)
                                Text(section.title)
                            }
                            .tag(section)
                        }
                    }

                    Section("其他") {
                        ForEach(SettingsSection.otherSections) { section in
                            HStack(spacing: 8) {
                                SidebarIconView(section: section)
                                Text(section.title)
                            }
                            .tag(section)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 185)
            .navigationSplitViewColumnWidth(185)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selectedSection ?? .input {
                case .input:
                    InputSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .voice:
                    VoiceSettingsView()
                case .phrasesAndClipboard:
                    PhrasesAndClipboardSettingsView()
                case .dictionary:
                    DictionarySettingsView()
                case .provider:
                    ProviderSettingsView()
                case .translate:
                    TranslateSettingsView()
                case .rewrite:
                    RewriteSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                case .updates:
                    UpdatesSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .navigationTitle(selectedSection?.title ?? "Prime 输入法")
            .toolbar {
                if selectedSection != .phrasesAndClipboard && selectedSection != .updates && selectedSection != .advanced {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .automatic) {
                            Color.clear
                                .frame(width: 1, height: 28)
                                .allowsHitTesting(false)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .automatic) {
                            Color.clear
                                .frame(width: 1, height: 28)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .primeTypeSelectAboutSection)) { _ in
            selectedSection = .about
        }
    }
}

extension Notification.Name {
    static let primeTypeSelectAboutSection = Notification.Name("com.lumocore.inputmethod.PrimeType.selectAboutSection")
}

private struct AdvancedSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @ObservedObject var clipboard = ClipboardManager.shared

    @State private var selectedTab = 0
    @State private var statusBanner: (message: String, isError: Bool)?
    @State private var isWorking = false
    @State private var showResetUserDBAlert = false
    @State private var showClearClipboardAlert = false
    @State private var showResetSettingsAlert = false
    @State private var accessibilityGranted = ClipboardManager.shared.isAccessibilityTrusted
    @State private var micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var localSignConfigured = LocalCodeSignManager.shared.isCertificateConfigured()
    @State private var isConfiguringLocalSign = false

    var body: some View {
        ZStack {
            dataTab
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)

            engineTab
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)

            permissionsTab
                .opacity(selectedTab == 2 ? 1 : 0)
                .allowsHitTesting(selectedTab == 2)

            diagnosticsTab
                .opacity(selectedTab == 3 ? 1 : 0)
                .allowsHitTesting(selectedTab == 3)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NativeToolbarSegmentedControl(
                    labels: ["数据", "引擎", "权限", "诊断"],
                    selection: $selectedTab
                )
            }
        }
        .onAppear {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if selectedTab == 2 {
                refreshPermissions()
            }
        }
        .alert("确定重置个人词频？", isPresented: $showResetUserDBAlert) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                performResetUserDB()
            }
        } message: {
            Text("将清空个人打字习惯与自造词频记忆（prime_shared.userdb），但会完整保留您的常用语、快捷键与所有偏好设置。")
        }
        .alert("确定清空剪贴板历史？", isPresented: $showClearClipboardAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clipboard.clearAll()
                showStatus("已清空剪贴板历史", isError: false)
            }
        } message: {
            Text("将删除本地保存的全部剪贴板历史记录，且无法撤销。")
        }
        .alert("确定恢复默认设置？", isPresented: $showResetSettingsAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                settings.resetToDefaults()
                showStatus("已恢复为默认设置", isError: false)
            }
        } message: {
            Text("将把所有偏好设置、快捷键与界面选项恢复为出厂默认值（不会删除您的个人词频库）。")
        }
    }

    // MARK: - 1. 数据

    private func refreshPermissions() {
        accessibilityGranted = ClipboardManager.shared.isAccessibilityTrusted
        micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        localSignConfigured = LocalCodeSignManager.shared.isCertificateConfigured()
    }

    private var permissionsTab: some View {
        Form {
            Section("系统权限状态") {
                LabeledContent {
                    if accessibilityGranted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Button("定位应用") {
                                ClipboardManager.shared.revealAppInFinder()
                            }
                            .help("在访达中显示 PrimeType.app，若列表中未出现可直接拖入辅助功能列表")

                            Button("前往授权") {
                                ClipboardManager.shared.requestAccessibilityPermission(openSystemSettings: true)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    refreshPermissions()
                                }
                            }
                        }
                    }
                } label: {
                    SettingRowTitle(
                        "辅助功能权限（图片/文件自动粘贴）",
                        subtitle: "文本与链接默认通过输入法直接上屏；图片、文件、划词翻译或非 PrimeType 状态下自动粘贴需在「系统设置 → 隐私与安全性 → 辅助功能」中启用 PrimeType（若未自动列出，可点「定位应用」拖入）"
                    )
                }

                LabeledContent {
                    if micAuthStatus == .authorized {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Button(micAuthStatus == .denied ? "打开设置" : "前往授权") {
                            if micAuthStatus == .notDetermined {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in
                                    DispatchQueue.main.async {
                                        refreshPermissions()
                                    }
                                }
                            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } label: {
                    SettingRowTitle(
                        "麦克风权限（流式语音输入）",
                        subtitle: "用于按住说话与点按听写语音识别；授权后可在任意应用中实时流式转写上屏"
                    )
                }
            }

            Section("安装引导") {
                LabeledContent {
                    Button("重新打开引导") {
                        OnboardingWindowController.shared.show(initialStep: .addInputSource, openSettingsOnFinish: false)
                    }
                } label: {
                    SettingRowTitle(
                        "权限与安装引导向导",
                        subtitle: "重新打开分步引导窗口，支持直接拖动 PrimeType.app 卡片至系统辅助功能列表"
                    )
                }
            }

            Section("持久化本地签名（进阶可选）") {
                statusSection

                LabeledContent {
                    if isConfiguringLocalSign {
                        ProgressView()
                            .controlSize(.small)
                    } else if localSignConfigured {
                        HStack(spacing: 10) {
                            Label("已启用", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                            Button("移除证书", role: .destructive) {
                                isConfiguringLocalSign = true
                                Task {
                                    do {
                                        try await LocalCodeSignManager.shared.removeCertificate()
                                        await MainActor.run {
                                            isConfiguringLocalSign = false
                                            refreshPermissions()
                                            showStatus("已从登录钥匙串移除本机签名证书", isError: false)
                                        }
                                    } catch {
                                        await MainActor.run {
                                            isConfiguringLocalSign = false
                                            showStatus("移除证书失败：\(error.localizedDescription)", isError: true)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Button("配置本机签名") {
                            isConfiguringLocalSign = true
                            Task {
                                do {
                                    try await LocalCodeSignManager.shared.setupCertificateAndSignApp()
                                    await MainActor.run {
                                        isConfiguringLocalSign = false
                                        refreshPermissions()
                                        showStatus("已启用本机签名，正在重启输入法以生效…", isError: false)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                            NSApp.terminate(nil)
                                        }
                                    }
                                } catch {
                                    await MainActor.run {
                                        isConfiguringLocalSign = false
                                        showStatus("配置失败：\(error.localizedDescription)", isError: true)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    SettingRowTitle(
                        "本机自签名证书（免重复授权）",
                        subtitle: "默认关闭。开启后会在您本机的登录钥匙串生成一张专属代码签名证书并重签 PrimeType.app，后续应用内自动更新将沿用该证书，不再丢失辅助功能与麦克风权限"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            statusSection

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "导出配置与用户词库",
                        subtitle: "将偏好设置、常用语与个人词频（prime_shared.userdb）打包为 .zip 备份文件"
                    )
                    Spacer()
                    Button("导出备份…") {
                        performExportBackup()
                    }
                    .disabled(isWorking)
                }

                HStack(alignment: .center) {
                    SettingRowTitle(
                        "导入配置与用户词库",
                        subtitle: "从已导出的备份文件恢复设置与词频数据，并自动重新部署生效"
                    )
                    Spacer()
                    Button("导入备份…") {
                        performImportBackup()
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("备份与恢复")
            }

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "重置个人词频",
                        subtitle: "仅清除个人打字习惯与自造词记录，保留常用语与所有设置"
                    )
                    Spacer()
                    Button("重置词频", role: .destructive) {
                        showResetUserDBAlert = true
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("用户词库维护")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 2. 引擎

    private var engineTab: some View {
        Form {
            statusSection

            Section {
                Toggle(isOn: $settings.smartEmailURLCompletion) {
                    SettingRowTitle(
                        "邮箱与网址智能补全",
                        subtitle: "拼音组词时输入「@」或「.」自动切换紧凑英文输入并提供常用邮箱与域名后缀补全"
                    )
                }
            } header: {
                Text("智能输入行为")
            }

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "重新部署 Rime 引擎",
                        subtitle: "立即重新加载当前词库方案（\(settings.selectedDictionary.displayName)）与自定义配置"
                    )
                    Spacer()
                    Button("重新部署") {
                        performDeploy()
                    }
                    .disabled(isWorking)
                }

                HStack(alignment: .center) {
                    SettingRowTitle(
                        "清理编译缓存并重建",
                        subtitle: "删除当前方案的 build 编译产物并重新构建，用于修复词库异常或候选缺失"
                    )
                    Spacer()
                    Button("清理并重建") {
                        performClearBuildCache()
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("Rime 引擎维护")
            }

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "打开本地目录",
                        subtitle: "直达用户配置目录（~/Library/InputType）或 Rime 运行日志目录"
                    )
                    Spacer()
                    HStack(spacing: 8) {
                        Button("配置目录") {
                            NSWorkspace.shared.open(settings.baseUserDirectoryURL)
                        }
                        Button("日志目录") {
                            let logURL = URL(fileURLWithPath: RimeEngine.shared.logDir)
                            try? FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(logURL)
                        }
                    }
                }
            } header: {
                Text("文件位置")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 3. 诊断

    private var diagnosticsTab: some View {
        Form {
            statusSection

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "清空剪贴板历史",
                        subtitle: clipboard.entries.isEmpty
                            ? "当前暂无剪贴板历史记录"
                            : "当前本地共保存 \(clipboard.entries.count) 条剪贴板记录"
                    )
                    Spacer()
                    Button("清空历史", role: .destructive) {
                        showClearClipboardAlert = true
                    }
                    .disabled(clipboard.entries.isEmpty || isWorking)
                }
            } header: {
                Text("隐私清理")
            }

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "导出诊断日志",
                        subtitle: "收集系统环境信息与最近 Rime 日志并打包为 .zip，便于排查与反馈问题"
                    )
                    Spacer()
                    Button("导出日志…") {
                        performExportDiagnostics()
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("问题排查")
            }

            Section {
                HStack(alignment: .center) {
                    SettingRowTitle(
                        "恢复默认设置",
                        subtitle: "将所有输入法偏好与快捷键还原为初始状态（不影响个人词频库）"
                    )
                    Spacer()
                    Button("恢复默认", role: .destructive) {
                        showResetSettingsAlert = true
                    }
                    .disabled(isWorking)
                }
            } header: {
                Text("重置")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let banner = statusBanner {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Color.orange : Color.green)
                    Text(banner.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        statusBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func showStatus(_ message: String, isError: Bool) {
        statusBanner = (message, isError)
    }

    private func performExportBackup() {
        let panel = NSSavePanel()
        panel.title = "导出 PrimeType 配置与用户词库"
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "PrimeType-Backup-\(formatter.string(from: Date())).zip"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try settings.exportBackupArchive(to: url)
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("备份已导出至 \(url.lastPathComponent)", isError: false)
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("导出失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func performImportBackup() {
        let panel = NSOpenPanel()
        panel.title = "选择 PrimeType 备份文件"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try settings.importBackupArchive(from: url)
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("已恢复备份并重新部署生效", isError: false)
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("导入失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func performResetUserDB() {
        isWorking = true
        settings.resetUserFrequencyDB {
            isWorking = false
            showStatus("已重置个人词频库并重新加载引擎", isError: false)
        }
    }

    private func performDeploy() {
        isWorking = true
        let preset = settings.selectedDictionary
        DispatchQueue.global(qos: .userInitiated).async {
            settings.writeRimeCustomYAML(for: preset)
            RimeEngine.shared.deploy(waitForMaintenance: true)
            DispatchQueue.main.async {
                isWorking = false
                showStatus("Rime 引擎已重新部署完成", isError: false)
            }
        }
    }

    private func performClearBuildCache() {
        isWorking = true
        settings.clearRimeBuildCacheAndRebuild {
            isWorking = false
            showStatus("已清理编译缓存并重建词库索引", isError: false)
        }
    }

    private func performExportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出 PrimeType 诊断日志"
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "PrimeType-Diagnostics-\(formatter.string(from: Date())).zip"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try settings.exportDiagnosticsArchive(to: url)
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("诊断日志已导出至 \(url.lastPathComponent)", isError: false)
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    showStatus("导出日志失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }
}

private struct UpdatesSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @ObservedObject var appUpdater = AppUpdateManager.shared
    @ObservedObject var dictUpdater = DictionaryUpdateManager.shared

    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            appUpdateTab
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)

            dictionaryUpdateTab
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NativeToolbarSegmentedControl(
                    labels: ["软件更新", "词库更新"],
                    selection: $selectedTab
                )
            }
        }
        .onAppear {
            dictUpdater.refreshLocalStates()
        }
    }

    // MARK: Tab 1 — 软件更新

    private var appUpdateTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("PrimeType")
                                .font(.system(size: 15, weight: .semibold))
                            Text("v\(appUpdater.currentVersion) (Build \(appUpdater.currentBuild))")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.13))
                                )
                        }

                        if let msg = appUpdater.statusMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(appUpdater.hasUpdate ? Color.accentColor : .secondary)
                        } else {
                            Text("点击右侧按钮检查 GitHub Releases 最新版本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if appUpdater.isChecking || appUpdater.isUpdating {
                        ProgressView()
                            .controlSize(.small)
                    } else if appUpdater.hasUpdate {
                        Button(appUpdater.assetDownloadURL != nil ? "立即更新" : "前往下载") {
                            appUpdater.downloadAndInstallUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("检查更新") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(appUpdater.isChecking || appUpdater.isUpdating)
                }
                .padding(.vertical, 4)

                if appUpdater.isUpdating {
                    ProgressView(value: appUpdater.downloadProgress)
                        .progressViewStyle(.linear)
                }
            } header: {
                Text("当前版本")
            }

            Section("更新设置") {
                Toggle(isOn: $settings.autoCheckAppUpdates) {
                    SettingRowTitle(
                        "自动检查软件更新",
                        subtitle: "启动时静默检查 GitHub 上游新版本"
                    )
                }
                .toggleStyle(.switch)

                LabeledContent("上游最新版本") {
                    Text(appUpdater.latestVersion ?? "未检查")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Tab 2 — 词库更新

    private var dictionaryUpdateTab: some View {
        Form {
            Section("自动更新") {
                Toggle(isOn: $settings.autoUpdateDictionaries) {
                    SettingRowTitle(
                        "自动更新词库",
                        subtitle: "定期检查并更新当前使用的词库，个人词频库保持独立不受影响"
                    )
                }
                .toggleStyle(.switch)
            }

            Section {
                ForEach(DictionaryPreset.allCases) { preset in
                    dictionaryUpdateRow(preset)
                }
            } header: {
                HStack {
                    Text("预置词库版本")
                    Spacer()
                    Button {
                        dictUpdater.checkAllUpdates(autoApplyIfEnabled: false)
                    } label: {
                        HStack(spacing: 4) {
                            if dictUpdater.isCheckingAll {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(dictUpdater.isCheckingAll ? "检查中…" : "检查全部更新")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(dictUpdater.isCheckingAll)
                }
            } footer: {
                Text("词库更新将下载到用户目录（~/Library/InputType/dictionaries/）以覆盖层方式加载，不会修改应用签名，也不会影响共享的用户词频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func dictionaryUpdateRow(_ preset: DictionaryPreset) -> some View {
        let st = dictUpdater.state(for: preset)
        let isUpToDate = !st.hasUpdate && st.latestVersion != nil
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                    if settings.selectedDictionary == preset {
                        Text("当前使用")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("本机:")
                            .foregroundStyle(.tertiary)
                        Text(st.localVersion)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("上游最新:")
                            .foregroundStyle(.tertiary)
                        Text(st.latestVersion ?? "未检查")
                            .foregroundStyle(st.hasUpdate ? Color.accentColor : .secondary)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))

                if let statusText = st.statusText,
                   statusText != "已是最新",
                   !statusText.hasPrefix("已更新至") {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if st.isUpdating || st.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                if st.hasUpdate {
                    Button("立即更新") {
                        Task {
                            await dictUpdater.updateDictionary(preset)
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                } else if isUpToDate {
                    Text("已是最新")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                } else {
                    Button("手动更新") {
                        Task {
                            await dictUpdater.updateDictionary(preset)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AboutSettingsView: View {
    @State private var showLicenseSheet = false
    @State private var showThirdPartySheet = false

    private var versionSummaryText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "版本 \(shortVersion) (Build \(build)) · librime 1.17.0"
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        Form {
            // 模块一：核心产品与版本信息
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)

                    VStack(spacing: 5) {
                        Text("PrimeType")
                            .font(.system(size: 20, weight: .semibold))

                        Text("轻量、低延迟的开源 macOS 中文与语音输入法")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Text(versionSummaryText)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.13))
                            )
                            .padding(.top, 2)
                    }

                    HStack(spacing: 10) {
                        Button {
                            openURL("https://github.com/HeLongaa/PrimeType/releases")
                        } label: {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            openURL("https://github.com/HeLongaa/PrimeType")
                        } label: {
                            HStack(spacing: 5) {
                                GitHubMarkIcon()
                                    .frame(width: 13.5, height: 13.5)
                                Text("GitHub 仓库")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            openURL("https://github.com/HeLongaa/PrimeType/issues")
                        } label: {
                            Label("问题反馈", systemImage: "exclamationmark.bubble")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            // 模块二：开源协议与隐私承诺
            Section("开源协议与隐私承诺") {
                LabeledContent {
                    Button("查看 LICENSE") {
                        showLicenseSheet = true
                    }
                    .controlSize(.small)
                } label: {
                    SettingRowTitle(
                        "GNU AGPL-3.0",
                        subtitle: "本软件基于 GNU AGPL-3.0 协议开源，可自由获取对应版本的完整源代码"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, alignment: .center)
                            .padding(.top, 1.5)
                        Text("输入内容完全本地化：常规键盘输入与词库学习完全在本地运行，不收集也不上传任何用户数据及输入记录。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, alignment: .center)
                            .padding(.top, 1.5)
                        Text("云端功能仅在触发时通信：语音识别与 AI 快捷操作仅在你主动调用时，将当前音频流或待处理文本发送至目标接口。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }

            // 模块三：开源致谢与第三方组件声明（二级弹窗）
            Section("开源致谢") {
                LabeledContent {
                    Button("查看详情…") {
                        showThirdPartySheet = true
                    }
                    .controlSize(.small)
                } label: {
                    SettingRowTitle(
                        "致谢",
                        subtitle: "查看 Rime、万象 / 雾凇 / 薄荷词库、VoiceKey、Handy / VoiceInk 等上游署名与许可"
                    )
                }
            }

            // 模块四：版权与联系方式（页脚）
            Section {
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        Button("作者主页") { openURL("https://github.com/HeLongaa") }
                            .buttonStyle(.link)
                        Text("·").foregroundStyle(.tertiary)
                        Button("GitHub Discussions") { openURL("https://github.com/HeLongaa/PrimeType/discussions") }
                            .buttonStyle(.link)
                        Text("·").foregroundStyle(.tertiary)
                        Button("提交 Issue") { openURL("https://github.com/HeLongaa/PrimeType/issues") }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 12))

                    Text("Copyright © 2026 HeLongaa. All rights reserved.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLicenseSheet) {
            AboutLicenseSheet()
        }
        .sheet(isPresented: $showThirdPartySheet) {
            ThirdPartyLicensesSheet()
        }
    }
}

private struct AboutLicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let licenseSummary = """
    PrimeType — 轻量、低延迟的开源 macOS 中文与语音输入法
    Copyright (C) 2026 HeLongaa

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GNU AGPL-3.0 开源许可证")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("在线查看全文") {
                    if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.en.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            ScrollView {
                Text(licenseSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
            )

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

private struct ThirdPartyCreditItem: Identifiable {
    let id = UUID()
    let name: String
    let license: String
    let note: String
    let url: String
}

private struct ThirdPartyLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let engineItems: [ThirdPartyCreditItem] = [
        ThirdPartyCreditItem(name: "Rime (librime 1.17.0)", license: "BSD-3-Clause", note: "中州韵核心输入法引擎", url: "https://github.com/rime/librime"),
        ThirdPartyCreditItem(name: "librime-lua", license: "BSD-3-Clause", note: "Rime Lua 扩展插件（内嵌 Lua 为 MIT）", url: "https://github.com/hchunhui/librime-lua"),
        ThirdPartyCreditItem(name: "librime-octagram / predict", license: "BSD-3-Clause", note: "语法模型与联想预测插件", url: "https://github.com/lotem/librime-octagram"),
        ThirdPartyCreditItem(name: "libopus 1.6.1", license: "BSD-3-Clause", note: "低延迟语音音频编码库", url: "https://github.com/xiph/opus")
    ]

    private let dictionaryItems: [ThirdPartyCreditItem] = [
        ThirdPartyCreditItem(name: "万象拼音 (amzxyz/rime_wanxiang)", license: "CC BY 4.0", note: "作者 amzxyz，遵循 CC BY 4.0 保留署名", url: "https://github.com/amzxyz/rime_wanxiang"),
        ThirdPartyCreditItem(name: "雾凇拼音 (iDvel/rime-ice)", license: "GPL-3.0", note: "作者 iDvel，现代简体拼音词库", url: "https://github.com/iDvel/rime-ice"),
        ThirdPartyCreditItem(name: "薄荷拼音 (Mintimate/oh-my-rime)", license: "LGPL-3.0", note: "作者 Mintimate，融合词库与方案配置", url: "https://github.com/Mintimate/oh-my-rime")
    ]

    private let voiceRefItems: [ThirdPartyCreditItem] = [
        ThirdPartyCreditItem(name: "VoiceKey (J3n5en/voicekey)", license: "参考致谢", note: "参考其语音输入交互实现", url: "https://github.com/J3n5en/voicekey"),
        ThirdPartyCreditItem(name: "Handy / VoiceInk", license: "参考致谢", note: "参考底层 CoreAudio 低延迟采集机制", url: "https://github.com/Beingpax/VoiceInk")
    ]

    private let emojiItems: [ThirdPartyCreditItem] = [
        ThirdPartyCreditItem(name: "rime-emoji", license: "LGPL-3.0", note: "Rime 表情候选数据", url: "https://github.com/rime/rime-emoji"),
        ThirdPartyCreditItem(name: "emojibase", license: "MIT", note: "Unicode 表情与符号元数据", url: "https://github.com/milesj/emojibase")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开源致谢与第三方组件许可")
                        .font(.system(size: 15, weight: .semibold))
                    Text("感谢以下开源项目作者与社区对中文输入与语音生态的贡献")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Form {
                creditSection("输入法引擎与扩展", items: engineItems)
                creditSection("内置 / 支持的拼音词库方案", items: dictionaryItems)
                creditSection("语音输入与底层音频参考", items: voiceRefItems)
                creditSection("表情与符号数据", items: emojiItems)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("CC BY 4.0 协议全文") {
                    if let url = URL(string: "https://creativecommons.org/licenses/by/4.0/deed.zh-hans") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 480)
    }

    private func creditSection(_ title: String, items: [ThirdPartyCreditItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(item.license)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.14))
                                )
                        }
                        Text(item.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: item.url) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("打开 \(item.url)")
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct MinimalInputField: View {
    @Binding var text: String
    var prompt: String = ""
    var isSecure: Bool = false
    var isMonospaced: Bool = false
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
            } else {
                TextField("", text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
            }
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .multilineTextAlignment(.leading)
        .font(isMonospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
        .focused($isFocused)
        .onSubmit {
            onSubmit?()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.14),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private enum ProviderEditorSession: Identifiable {
    case create(AIProviderConfig)
    case edit(AIProviderConfig)

    var id: UUID {
        switch self {
        case .create(let provider), .edit(let provider):
            return provider.id
        }
    }

    var isNew: Bool {
        if case .create = self { return true }
        return false
    }

    var initialProvider: AIProviderConfig {
        switch self {
        case .create(let provider), .edit(let provider):
            return provider
        }
    }
}

private struct ProviderSettingsView: View {
    @ObservedObject var settings = InputSettings.shared
    @State private var editorSession: ProviderEditorSession?

    var body: some View {
        VStack(spacing: 0) {
            if settings.aiProviders.isEmpty {
                Form {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.secondary)

                            Text("尚未添加提供商")
                                .font(.system(size: 14, weight: .semibold))

                            Text("添加一个 OpenAI 兼容 API 提供商并勾选模型后，即可在「翻译」和「改写」等快速操作中使用。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)

                            Button {
                                editorSession = .create(.defaultProvider)
                            } label: {
                                Label("新建提供商", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    }
                }
                .formStyle(.grouped)
            } else {
                Form {
                    Section {
                        ForEach(settings.aiProviders) { provider in
                            ProviderListRow(
                                provider: provider,
                                onEdit: {
                                    editorSession = .edit(provider)
                                },
                                onDelete: {
                                    settings.deleteProvider(id: provider.id)
                                }
                            )
                        }
                    } header: {
                        Text("提供商列表")
                    } footer: {
                        Text("支持任意 OpenAI 兼容接口。点击列表项可编辑密钥、自定义请求标头与接入模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }

            Divider()

            HStack(spacing: 10) {
                Text(settings.aiProviders.isEmpty
                     ? "点击右侧按钮新建提供商"
                     : "共 \(settings.aiProviders.count) 个提供商，点击条目可编辑")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    editorSession = .create(.defaultProvider)
                } label: {
                    Label("新建提供商", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(item: $editorSession) { session in
            ProviderEditorSheet(
                initialProvider: session.initialProvider,
                isNew: session.isNew,
                onSave: { updated in
                    settings.upsertProvider(updated)
                },
                onDelete: session.isNew ? nil : {
                    settings.deleteProvider(id: session.initialProvider.id)
                }
            )
        }
    }
}

private struct ProviderListRow: View {
    let provider: AIProviderConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var hasKey: Bool {
        !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusText: String {
        if !provider.selectedModels.isEmpty {
            return "已接入 \(provider.selectedModels.count) 个模型"
        }
        return hasKey ? "未选模型" : "待配置"
    }

    private var statusColor: Color {
        if !provider.selectedModels.isEmpty {
            return .accentColor
        }
        return hasKey ? .secondary : .orange
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(provider.selectedModels.isEmpty
                                  ? Color.secondary.opacity(0.12)
                                  : Color.accentColor.opacity(0.14))
                            .frame(width: 34, height: 34)
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(provider.selectedModels.isEmpty ? Color.secondary : Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "未填写基础 URL"
                             : provider.baseURL)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.12))
                        )

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("删除此提供商")
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderEditorSheet: View {
    let isNew: Bool
    let onSave: (AIProviderConfig) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var draft: AIProviderConfig
    @State private var showAPIKey = false
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var modelSearchText = ""
    @State private var manualModelID = ""

    init(
        initialProvider: AIProviderConfig,
        isNew: Bool,
        onSave: @escaping (AIProviderConfig) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: initialProvider)
    }

    private var allModels: [String] {
        var result = draft.availableModels
        let existing = Set(result)
        for m in draft.selectedModels where !existing.contains(m) {
            result.insert(m, at: 0)
        }
        return result
    }

    private var filteredModels: [String] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allModels }
        return allModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var canSave: Bool {
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "新建提供商" : "编辑提供商")
                        .font(.system(size: 15, weight: .semibold))
                    Text("配置 OpenAI 兼容接口地址、密钥、自定义请求标头及可用模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            Form {
                Section("基本信息") {
                    LabeledContent("名称") {
                        MinimalInputField(text: $draft.name, prompt: "例如 OpenAI / DeepSeek / OpenRouter")
                            .frame(maxWidth: 340)
                    }

                    LabeledContent("基础 URL") {
                        MinimalInputField(text: $draft.baseURL, prompt: "https://api.openai.com/v1", isMonospaced: true)
                            .frame(maxWidth: 340)
                    }

                    LabeledContent("API 密钥") {
                        HStack(spacing: 6) {
                            MinimalInputField(
                                text: $draft.apiKey,
                                prompt: "sk-...",
                                isSecure: !showAPIKey,
                                isMonospaced: true
                            )

                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(showAPIKey ? "隐藏 API 密钥" : "显示 API 密钥")
                        }
                        .frame(maxWidth: 340)
                    }
                }

                Section {
                    LabeledContent {
                        Button("添加标头") {
                            draft.headers.append(AIProviderHeader())
                        }
                        .controlSize(.small)
                    } label: {
                        SettingRowTitle(
                            "请求标头",
                            subtitle: "随每个请求发送，并替换同名的默认标头。"
                        )
                    }

                    ForEach($draft.headers) { $header in
                        HStack(spacing: 8) {
                            MinimalInputField(
                                text: $header.key,
                                prompt: "Header 名称",
                                isMonospaced: true
                            )

                            MinimalInputField(
                                text: $header.value,
                                prompt: "Header 值",
                                isMonospaced: true
                            )

                            Button(role: .destructive) {
                                let targetID = header.id
                                draft.headers.removeAll { $0.id == targetID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("删除标头")
                        }
                    }
                }

                Section {
                    let visibleModels = filteredModels
                    let selectedSet = Set(draft.selectedModels)
                    let allVisibleSelected = !visibleModels.isEmpty && visibleModels.allSatisfy { selectedSet.contains($0) }

                    HStack(spacing: 10) {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在获取模型列表…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if allModels.isEmpty {
                            Image(systemName: "key")
                                .foregroundStyle(.secondary)
                            Text(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "请输入 API 密钥以获取可用模型。"
                                 : "点击右侧按钮获取该接口的可用模型列表。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("已接入 \(draft.selectedModels.count) / \(allModels.count) 个模型")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer()

                        if !visibleModels.isEmpty {
                            Button(allVisibleSelected ? "取消全选" : "一键全选") {
                                toggleSelectAll(visibleModels: visibleModels, selectAll: !allVisibleSelected)
                            }
                            .controlSize(.small)
                        }

                        Button(allModels.isEmpty ? "获取模型" : "刷新列表") {
                            fetchModels()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isFetchingModels || !canSave)
                    }

                    if let fetchError {
                        Text(fetchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !allModels.isEmpty {
                        MinimalInputField(text: $modelSearchText, prompt: "搜索模型 ID…")

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(visibleModels, id: \.self) { modelID in
                                    let isOn = selectedSet.contains(modelID)
                                    HStack(spacing: 8) {
                                        Toggle(isOn: Binding(
                                            get: { isOn },
                                            set: { checked in
                                                toggleModel(modelID, selected: checked)
                                            }
                                        )) {
                                            Text(modelID)
                                                .font(.system(size: 12.5, design: .monospaced))
                                                .lineLimit(1)
                                        }
                                        .toggleStyle(.checkbox)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isOn ? Color.accentColor.opacity(0.10) : Color.clear)
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(minHeight: 110, maxHeight: 200)
                    }

                    LabeledContent("手动输入模型 ID") {
                        HStack(spacing: 8) {
                            MinimalInputField(
                                text: $manualModelID,
                                prompt: "例如 gpt-4o-mini",
                                isMonospaced: true,
                                onSubmit: addManualModel
                            )
                            .frame(maxWidth: 240)

                            Button("添加模型") {
                                addManualModel()
                            }
                            .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("支持 OpenAI 兼容接口（GET /models）。勾选一个或多个模型后点击保存即可在快速操作中选用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Text("删除提供商")
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isNew ? "创建" : "保存") {
                    var cleaned = draft
                    cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.baseURL = cleaned.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.headers = cleaned.headers.filter {
                        !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    onSave(cleaned)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 580)
    }

    private func fetchModels() {
        let snapshot = draft
        isFetchingModels = true
        fetchError = nil

        Task {
            do {
                let models = try await AIModelFetcher.fetchModels(for: snapshot)
                await MainActor.run {
                    isFetchingModels = false
                    draft.availableModels = models
                }
            } catch {
                await MainActor.run {
                    isFetchingModels = false
                    fetchError = error.localizedDescription
                }
            }
        }
    }

    private func toggleModel(_ modelID: String, selected: Bool) {
        if selected {
            if !draft.selectedModels.contains(modelID) {
                draft.selectedModels.append(modelID)
            }
        } else {
            draft.selectedModels.removeAll { $0 == modelID }
        }
    }

    private func toggleSelectAll(visibleModels: [String], selectAll: Bool) {
        var set = Set(draft.selectedModels)
        if selectAll {
            for m in visibleModels { set.insert(m) }
        } else {
            for m in visibleModels { set.remove(m) }
        }
        draft.selectedModels = allModels.filter { set.contains($0) }
    }

    private func addManualModel() {
        let trimmed = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draft.availableModels.contains(trimmed) {
            draft.availableModels.insert(trimmed, at: 0)
        }
        if !draft.selectedModels.contains(trimmed) {
            draft.selectedModels.append(trimmed)
        }
        manualModelID = ""
    }
}

private struct TranslateShortcutRecorder: View {
    @Binding var shortcutText: String
    let defaultText: String

    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var downModCode: UInt16?
    @State private var downModAt = Date.distantPast
    @State private var lastTapModCode: UInt16?
    @State private var lastTapAt = Date.distantPast

    var body: some View {
        ZStack {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "双击修饰键或按组合键..." : (shortcutText.isEmpty ? "点击录制" : shortcutText))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isRecording
                            ? Color.accentColor
                            : (shortcutText.isEmpty ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    .padding(.horizontal, 26)
                    .frame(minWidth: 120, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button {
                    stopRecording()
                    shortcutText = shortcutText.isEmpty ? defaultText : ""
                } label: {
                    Image(systemName: shortcutText.isEmpty ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(shortcutText.isEmpty ? "恢复默认 (\(defaultText))" : "清除快捷键")
                .padding(.trailing, 7)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .modifier(SettingsControlPillBackground(isHighlighted: isRecording))
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        downModCode = nil
        lastTapModCode = nil
        TranslateManager.isRecordingShortcut = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                downModCode = nil
                lastTapModCode = nil
                if event.keyCode == 0x35 {
                    stopRecording()
                    return nil
                }
                if let formatted = VoiceShortcutFormatter.format(keyDown: event) {
                    shortcutText = formatted
                    stopRecording()
                    return nil
                }
                NSSound.beep()
                return nil
            }

            if event.type == .flagsChanged {
                let code = event.keyCode
                guard let modLabel = VoiceShortcutFormatter.singleModifierKeyCodes[code] else { return nil }
                let pressed = TranslateShortcutHelper.isModifierPressed(code: code, flags: event.modifierFlags)
                let now = Date()
                if pressed {
                    // Reject multi-modifier holds from triggering a single-modifier double-tap
                    if downModCode == nil {
                        downModCode = code
                        downModAt = now
                    } else {
                        downModCode = 0xFFFF
                        lastTapModCode = nil
                    }
                } else if downModCode == code {
                    let pressDuration = now.timeIntervalSince(downModAt)
                    downModCode = nil
                    guard pressDuration < 0.35 else {
                        lastTapModCode = nil
                        return nil
                    }
                    if lastTapModCode == code && now.timeIntervalSince(lastTapAt) < 0.45 {
                        shortcutText = "\(TranslateShortcutHelper.doubleTapPrefix)\(modLabel)"
                        stopRecording()
                    } else {
                        lastTapModCode = code
                        lastTapAt = now
                    }
                }
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        downModCode = nil
        lastTapModCode = nil
        TranslateManager.isRecordingShortcut = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private struct TranslateSettingsView: View {
    @ObservedObject var settings = InputSettings.shared

    private struct ModelOption: Identifiable, Hashable {
        let providerID: UUID
        let providerName: String
        let modelID: String
        var id: String { "\(providerID.uuidString)::\(modelID)" }
        var label: String { "\(providerName) · \(modelID)" }
    }

    private var availableModelOptions: [ModelOption] {
        var result: [ModelOption] = []
        for provider in settings.aiProviders {
            for model in provider.selectedModels where !model.isEmpty {
                result.append(ModelOption(
                    providerID: provider.id,
                    providerName: provider.displayTitle,
                    modelID: model
                ))
            }
        }
        return result
    }

    private var selectedModelKey: Binding<String> {
        Binding(
            get: {
                if let pid = settings.translateProviderID, !settings.translateModelID.isEmpty {
                    let key = "\(pid.uuidString)::\(settings.translateModelID)"
                    if availableModelOptions.contains(where: { $0.id == key }) {
                        return key
                    }
                }
                return availableModelOptions.first?.id ?? ""
            },
            set: { newKey in
                if let opt = availableModelOptions.first(where: { $0.id == newKey }) {
                    settings.translateProviderID = opt.providerID
                    settings.translateModelID = opt.modelID
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("触发与模型") {
                Toggle(isOn: $settings.translateEnabled) {
                    SettingRowTitle(
                        "启用快速翻译",
                        subtitle: "选中任意文本或在输入框输入完成后，按下快捷键立即弹出翻译窗口"
                    )
                }
                .toggleStyle(.switch)

                LabeledContent {
                    TranslateShortcutRecorder(
                        shortcutText: $settings.translateShortcutKey,
                        defaultText: "双击 左 ⌘"
                    )
                } label: {
                    SettingRowTitle(
                        "快捷键",
                        subtitle: "支持双击修饰键（如双击 左 ⌘）或任意组合键（如 ⌥ T）"
                    )
                }

                if availableModelOptions.isEmpty {
                    LabeledContent("模型") {
                        Text("未配置可用模型")
                            .foregroundStyle(.secondary)
                    }
                    Text("请先在左侧「快速操作 → 提供商」中填写 API 密钥并勾选至少一个接入模型。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent {
                        Picker("", selection: selectedModelKey) {
                            ForEach(availableModelOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } label: {
                        SettingRowTitle(
                            "模型",
                            subtitle: "从「提供商」中已勾选的模型列表中选择用于翻译的大语言模型"
                        )
                    }
                }
            }

            Section {
                HStack(spacing: 12) {
                    VStack(spacing: 10) {
                        LabeledContent {
                            Picker("", selection: $settings.translatePrimaryLanguage) {
                                ForEach(TranslateLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        } label: {
                            HStack(spacing: 6) {
                                Text("1")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.accentColor))
                                SettingRowTitle(
                                    "第一语言（默认目标语言）",
                                    subtitle: "源文本为其他语言时将翻译为此语言"
                                )
                            }
                        }

                        LabeledContent {
                            Picker("", selection: $settings.translateSecondaryLanguage) {
                                ForEach(TranslateLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        } label: {
                            HStack(spacing: 6) {
                                Text("2")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.secondary.opacity(0.2)))
                                SettingRowTitle(
                                    "第二语言（互译语言）",
                                    subtitle: "源文本为第一语言时自动翻译为此语言"
                                )
                            }
                        }
                    }

                    Button {
                        let first = settings.translatePrimaryLanguage
                        settings.translatePrimaryLanguage = settings.translateSecondaryLanguage
                        settings.translateSecondaryLanguage = first
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help("交换第一语言与第二语言顺序")
                }
                .padding(.vertical, 4)
            } header: {
                Text("常用语言与翻译方向")
            } footer: {
                Text("系统会先按字符与语种占比识别原文主要语言：若属于上述两个常用语言之一，则自动互译；若为其他语言，则自动翻译为排在第 1 位的语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if settings.translateModelID.isEmpty, let first = availableModelOptions.first {
                settings.translateProviderID = first.providerID
                settings.translateModelID = first.modelID
            }
        }
    }
}

private struct RewriteSettingsView: View {
    @ObservedObject var settings = InputSettings.shared

    private struct ModelOption: Identifiable, Hashable {
        let providerID: UUID
        let providerName: String
        let modelID: String
        var id: String { "\(providerID.uuidString)::\(modelID)" }
        var label: String { "\(providerName) · \(modelID)" }
    }

    private var availableModelOptions: [ModelOption] {
        var result: [ModelOption] = []
        for provider in settings.aiProviders {
            for model in provider.selectedModels where !model.isEmpty {
                result.append(ModelOption(
                    providerID: provider.id,
                    providerName: provider.displayTitle,
                    modelID: model
                ))
            }
        }
        return result
    }

    private var selectedModelKey: Binding<String> {
        Binding(
            get: {
                if let pid = settings.rewriteProviderID, !settings.rewriteModelID.isEmpty {
                    let key = "\(pid.uuidString)::\(settings.rewriteModelID)"
                    if availableModelOptions.contains(where: { $0.id == key }) {
                        return key
                    }
                }
                return availableModelOptions.first?.id ?? ""
            },
            set: { newKey in
                if let opt = availableModelOptions.first(where: { $0.id == newKey }) {
                    settings.rewriteProviderID = opt.providerID
                    settings.rewriteModelID = opt.modelID
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("触发与模型") {
                Toggle(isOn: $settings.rewriteEnabled) {
                    SettingRowTitle(
                        "启用快速改写",
                        subtitle: "选中任意文本或在输入框输入完成后，按下快捷键立即弹出改写窗口"
                    )
                }
                .toggleStyle(.switch)

                LabeledContent {
                    TranslateShortcutRecorder(
                        shortcutText: $settings.rewriteShortcutKey,
                        defaultText: "双击 右 ⌘"
                    )
                } label: {
                    SettingRowTitle(
                        "快捷键",
                        subtitle: "支持双击修饰键（如双击 右 ⌘）或任意组合键（如 ⌥ R）"
                    )
                }

                if availableModelOptions.isEmpty {
                    LabeledContent("模型") {
                        Text("未配置可用模型")
                            .foregroundStyle(.secondary)
                    }
                    Text("请先在左侧「快速操作 → 提供商」中填写 API 密钥并勾选至少一个接入模型。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent {
                        Picker("", selection: selectedModelKey) {
                            ForEach(availableModelOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } label: {
                        SettingRowTitle(
                            "模型",
                            subtitle: "从「提供商」中已勾选的模型列表中选择用于改写的大语言模型"
                        )
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $settings.rewriteSystemPrompt)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                        )

                    HStack {
                        Text("控制改写风格的系统提示词，留空时自动使用默认提示词。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") {
                            settings.rewriteSystemPrompt = InputSettings.defaultRewriteSystemPrompt
                        }
                        .controlSize(.small)
                        .disabled(settings.rewriteSystemPrompt == InputSettings.defaultRewriteSystemPrompt)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("系统提示词")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if settings.rewriteModelID.isEmpty, let first = availableModelOptions.first {
                settings.rewriteProviderID = first.providerID
                settings.rewriteModelID = first.modelID
            }
        }
    }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command {
            switch key {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            case "z":
                if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
            case "w":
                performClose(nil)
                return true
            default:
                break
            }
        } else if mods == [.command, .shift], key == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var isOpen = false

    private init() {
        Self.ensureStandardEditMenu()
        let hostingController = NSHostingController(rootView: SettingsRootView())
        let window = SettingsWindow(contentViewController: hostingController)
        window.title = "Prime 输入法设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 580))
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    private static func ensureStandardEditMenu() {
        if NSApp.mainMenu?.item(withTitle: "Edit") != nil { return }
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if mainMenu.items.isEmpty {
            let appMenuItem = NSMenuItem()
            let appMenu = NSMenu(title: "Prime 输入法")
            appMenu.addItem(withTitle: "关闭设置", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            appMenuItem.submenu = appMenu
            mainMenu.addItem(appMenuItem)
        }
        let editMenuItem = NSMenuItem()
        editMenuItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        Self.ensureStandardEditMenu()
        if !isOpen {
            isOpen = true
            NSApp.setActivationPolicy(.regular)
            window.center()
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lockSidebarWidth(in: window, width: 185)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.lockSidebarWidth(in: window, width: 185)
        }
    }

    func showAbout() {
        NotificationCenter.default.post(name: .primeTypeSelectAboutSection, object: nil)
        show()
    }

    private func lockSidebarWidth(in window: NSWindow, width: CGFloat) {
        guard let root = window.contentView, let splitView = findSplitView(in: root) else { return }
        if let splitVC = splitView.delegate as? NSSplitViewController,
           let sidebarItem = splitVC.splitViewItems.first {
            sidebarItem.minimumThickness = width
            sidebarItem.maximumThickness = width
            sidebarItem.canCollapse = false
        }
        splitView.setPosition(width, ofDividerAt: 0)
    }

    private func findSplitView(in view: NSView) -> NSSplitView? {
        if let sv = view as? NSSplitView { return sv }
        for sub in view.subviews {
            if let found = findSplitView(in: sub) { return found }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        NSApp.setActivationPolicy(.accessory)
    }
}
