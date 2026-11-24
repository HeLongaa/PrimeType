import Cocoa
import Combine

enum VModeMenuItem: Int, CaseIterable, Identifiable {
    case calculator = 1
    case clipboard = 2
    case phrases = 3
    case voice = 4
    case symbols = 5
    case translate = 6
    case rewrite = 7
    case dateTime = 8
    case settings = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .calculator: return "计算"
        case .clipboard: return "剪贴板"
        case .phrases: return "常用语"
        case .voice: return "语音输入"
        case .symbols: return "符号"
        case .translate: return "翻译"
        case .rewrite: return "改写"
        case .dateTime: return "日期时间"
        case .settings: return "设置"
        }
    }

    var badgeLabel: String {
        switch self {
        case .calculator: return "1"
        case .clipboard: return "j"
        case .phrases: return "c"
        case .voice: return "y"
        case .symbols: return "e"
        case .translate: return "f"
        case .rewrite: return "r"
        case .dateTime: return "d"
        case .settings: return "s"
        }
    }

    static func fromTriggerCharacter(_ char: String) -> VModeMenuItem? {
        switch char.lowercased() {
        case "j": return .clipboard
        case "c": return .phrases
        case "y": return .voice
        case "e": return .symbols
        case "f": return .translate
        case "r": return .rewrite
        case "d": return .dateTime
        case "s": return .settings
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .calculator: return "plus.forwardslash.minus"
        case .clipboard: return "doc.on.clipboard"
        case .phrases: return "shippingbox"
        case .voice: return "mic"
        case .symbols: return "face.smiling"
        case .translate: return "globe"
        case .rewrite: return "wand.and.stars"
        case .dateTime: return "calendar.badge.clock"
        case .settings: return "gearshape"
        }
    }
}

enum VModeSymbolCategory: Int, CaseIterable, Identifiable {
    case common
    case punctuation
    case math
    case arrows
    case numbers
    case units
    case greek
    case emoji

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .common: return "常用"
        case .punctuation: return "标点"
        case .math: return "数学"
        case .arrows: return "箭头"
        case .numbers: return "序号"
        case .units: return "单位"
        case .greek: return "希腊"
        case .emoji: return "表情"
        }
    }

    var symbols: [String] {
        switch self {
        case .common:
            return [
                "·", "—", "…", "「", "」", "『", "』", "【", "】", "《", "》", "※",
                "★", "☆", "✓", "✔", "✗", "✘", "●", "○", "◆", "◇", "■", "□",
                "▲", "△", "▼", "▽", "♠", "♥", "♣", "♦", "♪", "♫", "☀", "☁",
                "⌘", "⌥", "⇧", "⌃", "↩", "⇥", "⌫", "⎋", "©", "®", "™", "§",
                "¶", "†", "‡", "•", "‣", "⁃", "№", "℗", "℠", "℃", "℉", "¥"
            ]
        case .punctuation:
            return [
                "，", "。", "、", "；", "：", "？", "！", "“", "”", "‘", "’", "—",
                "…", "·", "（", "）", "《", "》", "〈", "〉", "【", "】", "〔", "〕",
                "「", "」", "『", "』", "〖", "〗", "〝", "〞", "﹏", "＿", "～", "｜",
                "／", "＼", "＠", "＃", "＄", "％", "＆", "＊", "＋", "－", "＝", "＜",
                "＞", "［", "］", "｛", "｝", "¡", "¿", "«", "»", "‹", "›", "„"
            ]
        case .math:
            return [
                "±", "×", "÷", "≈", "≠", "≤", "≥", "≡", "≢", "∝", "∞", "√",
                "∛", "∜", "∑", "∏", "∫", "∬", "∮", "∂", "∇", "∆", "π", "°",
                "′", "″", "‰", "‱", "∠", "∟", "∥", "⊥", "⌒", "⊙", "≌", "∽",
                "∈", "∉", "⊂", "⊃", "⊆", "⊇", "∪", "∩", "∅", "∀", "∃", "¬",
                "∧", "∨", "⇒", "⇔", "∴", "∵", "½", "⅓", "⅔", "¼", "¾", "²",
                "³", "ⁿ", "₀", "₁", "₂", "₃"
            ]
        case .arrows:
            return [
                "→", "←", "↑", "↓", "↔", "↕", "↗", "↘", "↙", "↖", "⇒", "⇐",
                "⇑", "⇓", "⇔", "⇕", "➔", "➜", "➝", "➞", "➡", "⬅", "⬆", "⬇",
                "↩", "↪", "↰", "↱", "↲", "↳", "↴", "↵", "↶", "↷", "↺", "↻",
                "⇄", "⇅", "⇆", "⇇", "⇈", "⇉", "⇊", "⇤", "⇥", "⇪", "⇧", "⇩",
                "▶", "◀", "▲", "▼", "▷", "◁", "△", "▽", "»", "«", "›", "‹"
            ]
        case .numbers:
            return [
                "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫",
                "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳", "❶", "❷", "❸", "❹",
                "❺", "❻", "❼", "❽", "❾", "❿", "⑴", "⑵", "⑶", "⑷", "⑸", "⑹",
                "⑺", "⑻", "⑼", "⑽", "㈠", "㈡", "㈢", "㈣", "㈤", "㈥", "㈦", "㈧",
                "㈨", "㈩", "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
                "Ⅺ", "Ⅻ", "ⅰ", "ⅱ", "ⅲ", "ⅳ", "ⅴ", "ⅵ", "ⅶ", "ⅷ", "ⅸ", "ⅹ"
            ]
        case .units:
            return [
                "¥", "$", "€", "£", "₩", "₽", "₹", "฿", "¢", "¤", "℃", "℉",
                "°", "′", "″", "‰", "‱", "㎡", "㎥", "㎞", "㎝", "㎜", "㎛", "㎚",
                "㎏", "㎎", "㎍", "㎖", "㎗", "㎘", "㎐", "㎑", "㎒", "㎓", "㎔", "㎷",
                "㎸", "㎹", "㎃", "㎄", "㎽", "㎾", "㎿", "Ω", "㏀", "㏁", "㎩", "㍱",
                "㎪", "㎫", "㎬", "㏂", "㏘", "Å", "ℓ", "㎧", "㎨", "㎭", "㎮", "㎯"
            ]
        case .greek:
            return [
                "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ",
                "ν", "ξ", "ο", "π", "ρ", "σ", "τ", "υ", "φ", "χ", "ψ", "ω",
                "Α", "Β", "Γ", "Δ", "Ε", "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ",
                "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ", "Χ", "Ψ", "Ω"
            ]
        case .emoji:
            return [
                "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🥹", "😊", "😇", "🙂",
                "😉", "😍", "🥰", "😘", "😋", "😜", "🤪", "🤔", "🫡", "🤨", "😐", "😏",
                "😒", "🙄", "😬", "😌", "😔", "😴", "😷", "🤯", "🥳", "😎", "🤓", "😭",
                "😤", "😡", "😱", "🤗", "👍", "👎", "👏", "🙌", "🤝", "🙏", "💪", "👌",
                "✌️", "🫶", "❤️", "🧡", "💛", "💚", "💙", "💜", "🔥", "✨", "🎉", "🎊",
                "💯", "✅", "❌", "⚠️", "💡", "⚡", "🚀", "🌟", "🌈", "☕️", "🍺", "🎂"
            ]
        }
    }
}

enum VModePage: Equatable {
    case menu
    case calculator
    case phrases
    case symbols
    case dateTime
}

struct VModeResultItem: Identifiable, Equatable {
    let id: String
    let value: String
    let subtitle: String?
}

final class VModeState: ObservableObject {
    @Published var page: VModePage = .menu
    @Published var selectedMenuIndex: Int = 0
    @Published var hasNavigatedMenu: Bool = false
    @Published var selectedListIndex: Int = 0
    @Published var calcExpression: String = ""
    @Published var symbolCategory: VModeSymbolCategory = .common
    @Published var isDark: Bool = true

    func reset() {
        page = .menu
        selectedMenuIndex = 0
        hasNavigatedMenu = false
        selectedListIndex = 0
        calcExpression = ""
        symbolCategory = .common
    }

    var calcResults: [VModeResultItem] {
        let expr = calcExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { return [] }

        // State 1: Pure number (e.g. "v1", "v25", "v2026") -> Chinese uppercase/lowercase/circled/parenthesized
        if VModeMathEvaluator.isPureNumber(expr), let value = Double(expr), value.isFinite {
            return VModeMathEvaluator.numberCandidates(for: expr, value: value)
        }

        // State 2: Math expression (e.g. "v1+1", "v12*8") -> result, equation, uppercase RMB, lowercase RMB
        if let value = VModeMathEvaluator.evaluate(expr), value.isFinite {
            let formatted = VModeMathEvaluator.formatNumber(value)
            var items: [VModeResultItem] = [
                VModeResultItem(id: "val", value: formatted, subtitle: nil),
                VModeResultItem(id: "eq", value: "\(expr)=\(formatted)", subtitle: nil)
            ]
            if let upperRMB = VModeMathEvaluator.chineseRMB(value, uppercase: true) {
                items.append(VModeResultItem(id: "rmb-up", value: upperRMB, subtitle: nil))
            }
            if let lowerRMB = VModeMathEvaluator.chineseRMB(value, uppercase: false) {
                items.append(VModeResultItem(id: "rmb-low", value: lowerRMB, subtitle: nil))
            }
            return items
        }

        // State 3: Incomplete expression while typing (e.g. "v1+") -> show prefix value if available
        let trimmedOps = expr.trimmingCharacters(in: CharacterSet(charactersIn: "+-*/%^("))
        if !trimmedOps.isEmpty, let partial = VModeMathEvaluator.evaluate(trimmedOps), partial.isFinite {
            let formatted = VModeMathEvaluator.formatNumber(partial)
            return [
                VModeResultItem(id: "partial", value: formatted, subtitle: nil)
            ]
        }
        return []
    }

    var phraseItems: [VModeResultItem] {
        InputSettings.shared.customPhrases.prefix(9).enumerated().map { idx, phrase in
            VModeResultItem(id: "\(idx)-\(phrase.id.uuidString)", value: phrase.content, subtitle: phrase.code.isEmpty ? nil : phrase.code)
        }
    }

    private static let dateTimeFormatters: [(id: String, subtitle: String, formatter: DateFormatter)] = {
        let specs: [(String, String, String)] = [
            ("d1", "标准日期", "yyyy-MM-dd"),
            ("d2", "中文日期", "yyyy年M月d日"),
            ("d3", "当前时间", "HH:mm"),
            ("d4", "日期与时间", "yyyy-MM-dd HH:mm"),
            ("d5", "中文日期时间", "yyyy年M月d日 HH:mm"),
            ("d6", "星期", "EEEE")
        ]
        let locale = Locale(identifier: "zh_CN")
        return specs.map { id, subtitle, format in
            let fmt = DateFormatter()
            fmt.locale = locale
            fmt.dateFormat = format
            return (id, subtitle, fmt)
        }
    }()

    var dateTimeItems: [VModeResultItem] {
        let now = Date()
        return Self.dateTimeFormatters.map { spec in
            VModeResultItem(id: spec.id, value: spec.formatter.string(from: now), subtitle: spec.subtitle)
        }
    }
}

// MARK: - Safe Recursive-Descent Math Evaluator

enum VModeMathEvaluator {
    static func evaluate(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        guard !cleaned.isEmpty else { return nil }
        var parser = Parser(Array(cleaned))
        guard let result = parser.parseExpression(), parser.isAtEnd else { return nil }
        return result
    }

    static func formatNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-10, abs(rounded) < 1e15 {
            return String(format: "%.0f", rounded)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func isPureNumber(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        var hasDigit = false
        var dotCount = 0
        for ch in raw {
            if ch.isNumber && ch.isASCII {
                hasDigit = true
            } else if ch == "." {
                dotCount += 1
                if dotCount > 1 { return false }
            } else {
                return false
            }
        }
        return hasDigit
    }

    private static let circledNumbers: [String] = [
        "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
        "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳"
    ]

    private static let parenthesizedChineseNumbers: [String] = [
        "(一)", "(二)", "(三)", "(四)", "(五)", "(六)", "(七)", "(八)", "(九)", "(十)",
        "(十一)", "(十二)", "(十三)", "(十四)", "(十五)", "(十六)", "(十七)", "(十八)", "(十九)", "(二十)"
    ]

    static func numberCandidates(for raw: String, value: Double) -> [VModeResultItem] {
        var items: [VModeResultItem] = []
        var seen: Set<String> = []
        func appendUnique(id: String, _ text: String) {
            guard !text.isEmpty, !seen.contains(text) else { return }
            seen.insert(text)
            items.append(VModeResultItem(id: id, value: text, subtitle: nil))
        }

        if let upper = chineseNumber(value, uppercase: true) {
            appendUnique(id: "num-up", upper)
        }
        if let lower = chineseNumber(value, uppercase: false) {
            appendUnique(id: "num-low", lower)
        }

        if !raw.contains("."), let intVal = Int(raw), (1...20).contains(intVal) {
            appendUnique(id: "circled", circledNumbers[intVal - 1])
            appendUnique(id: "paren", parenthesizedChineseNumbers[intVal - 1])
        } else {
            if let rmbUp = chineseRMB(value, uppercase: true) {
                appendUnique(id: "rmb-up", rmbUp)
            }
            if let rmbLow = chineseRMB(value, uppercase: false) {
                appendUnique(id: "rmb-low", rmbLow)
            }
        }
        return items
    }

    static func chineseNumber(_ value: Double, uppercase: Bool) -> String? {
        guard value >= 0, value < 1_000_000_000_000 else { return nil }
        let digits = uppercase
            ? ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
            : ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let smallUnits = uppercase ? ["", "拾", "佰", "仟"] : ["", "十", "百", "千"]
        let bigUnits = ["", "万", "亿"]

        let intPart = Int64(value.rounded(.towardZero))

        func sectionToChinese(_ n: Int) -> String {
            var res = ""
            var zeroFlag = false
            var num = n
            for i in 0..<4 {
                let d = num % 10
                num /= 10
                if d == 0 {
                    if !res.isEmpty { zeroFlag = true }
                } else {
                    if zeroFlag {
                        res = digits[0] + res
                        zeroFlag = false
                    }
                    res = digits[d] + smallUnits[i] + res
                }
            }
            return res
        }

        var integerStr = ""
        if intPart == 0 {
            integerStr = digits[0]
        } else {
            var temp = intPart
            var unitIdx = 0
            var needZero = false
            while temp > 0 {
                let sec = Int(temp % 10000)
                if sec != 0 {
                    var secStr = sectionToChinese(sec)
                    if needZero {
                        secStr += digits[0]
                        needZero = false
                    }
                    integerStr = secStr + bigUnits[unitIdx] + integerStr
                    if sec < 1000 && temp >= 10000 {
                        needZero = true
                    }
                } else if !integerStr.isEmpty {
                    needZero = true
                }
                temp /= 10000
                unitIdx += 1
            }
            if !uppercase && (10...19).contains(intPart) && integerStr.hasPrefix("一十") {
                integerStr.removeFirst()
            }
        }

        let formatted = formatNumber(value)
        if let dotIdx = formatted.firstIndex(of: ".") {
            let fracPart = formatted[formatted.index(after: dotIdx)...]
            if !fracPart.isEmpty {
                var fracStr = "点"
                for ch in fracPart {
                    if let d = Int(String(ch)) {
                        fracStr += digits[d]
                    }
                }
                return integerStr + fracStr
            }
        }
        return integerStr
    }

    static func chineseRMB(_ value: Double, uppercase: Bool = true) -> String? {
        guard value >= 0, value < 1_000_000_000_000 else { return nil }
        let totalCents = Int64((value * 100.0).rounded())
        let yuan = totalCents / 100
        let jiao = Int((totalCents % 100) / 10)
        let fen = Int(totalCents % 10)

        let digits = uppercase
            ? ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
            : ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let smallUnits = uppercase ? ["", "拾", "佰", "仟"] : ["", "十", "百", "千"]
        let bigUnits = ["", "万", "亿"]

        func sectionToChinese(_ n: Int) -> String {
            var res = ""
            var zeroFlag = false
            var num = n
            for i in 0..<4 {
                let d = num % 10
                num /= 10
                if d == 0 {
                    if !res.isEmpty { zeroFlag = true }
                } else {
                    if zeroFlag {
                        res = digits[0] + res
                        zeroFlag = false
                    }
                    res = digits[d] + smallUnits[i] + res
                }
            }
            return res
        }

        var integerPart = ""
        if yuan == 0 {
            integerPart = digits[0]
        } else {
            var temp = yuan
            var unitIdx = 0
            var needZero = false
            while temp > 0 {
                let sec = Int(temp % 10000)
                if sec != 0 {
                    var secStr = sectionToChinese(sec)
                    if needZero {
                        secStr += digits[0]
                        needZero = false
                    }
                    integerPart = secStr + bigUnits[unitIdx] + integerPart
                    if sec < 1000 && temp >= 10000 {
                        needZero = true
                    }
                } else if !integerPart.isEmpty {
                    needZero = true
                }
                temp /= 10000
                unitIdx += 1
            }
            if !uppercase && (10...19).contains(yuan) && integerPart.hasPrefix("一十") {
                integerPart.removeFirst()
            }
        }

        var result = "\(integerPart)元"
        if jiao == 0 && fen == 0 {
            result += "整"
        } else {
            if jiao > 0 {
                result += "\(digits[jiao])角"
            } else if yuan > 0 {
                result += digits[0]
            }
            if fen > 0 {
                result += "\(digits[fen])分"
            }
        }
        return result
    }

    private struct Parser {
        let chars: [Character]
        var idx: Int = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        var isAtEnd: Bool { idx >= chars.count }
        var peek: Character? { idx < chars.count ? chars[idx] : nil }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                idx += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = (op == "+") ? (lhs + rhs) : (lhs - rhs)
            }
            return lhs
        }

        mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while let op = peek, op == "*" || op == "/" || op == "%" {
                idx += 1
                guard let rhs = parsePower() else { return nil }
                if op == "*" {
                    lhs *= rhs
                } else if op == "/" {
                    guard rhs != 0 else { return nil }
                    lhs /= rhs
                } else {
                    guard rhs != 0 else { return nil }
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        mutating func parsePower() -> Double? {
            guard var base = parseUnary() else { return nil }
            if peek == "^" {
                idx += 1
                guard let exp = parsePower() else { return nil }
                base = pow(base, exp)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if peek == "+" {
                idx += 1
                return parseUnary()
            }
            if peek == "-" {
                idx += 1
                guard let val = parseUnary() else { return nil }
                return -val
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            if peek == "(" {
                idx += 1
                guard let val = parseExpression(), peek == ")" else { return nil }
                idx += 1
                return val
            }
            let start = idx
            var hasDot = false
            while let ch = peek {
                if ch.isNumber {
                    idx += 1
                } else if ch == "." && !hasDot {
                    hasDot = true
                    idx += 1
                } else {
                    break
                }
            }
            guard idx > start else { return nil }
            return Double(String(chars[start..<idx]))
        }
    }
}

// MARK: - Pure AppKit V-Mode Panel View (Zero SwiftUI)

private final class VModeClickableRowNSView: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class VModeFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class VModeContentNSView: NSView {
    private let state: VModeState
    private let onSelectMenuItem: (VModeMenuItem) -> Void
    private let onCommitText: (String) -> Void
    private let onBackToMenu: () -> Void
    private let onOpenSettings: () -> Void

    private var computedSize = NSSize(width: 254, height: 180)
    private var symbolGridScrollView: NSScrollView?
    private var symbolCategoryScrollView: NSScrollView?
    private var lastSymbolCategory: VModeSymbolCategory?

    override var isFlipped: Bool { true }

    init(
        state: VModeState,
        onSelectMenuItem: @escaping (VModeMenuItem) -> Void,
        onCommitText: @escaping (String) -> Void,
        onBackToMenu: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.state = state
        self.onSelectMenuItem = onSelectMenuItem
        self.onCommitText = onCommitText
        self.onBackToMenu = onBackToMenu
        self.onOpenSettings = onOpenSettings
        super.init(frame: NSRect(x: 0, y: 0, width: 254, height: 180))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var panelWidth: CGFloat {
        switch state.page {
        case .calculator: return 216
        case .symbols: return 316
        default: return 254
        }
    }

    func preferredSize() -> NSSize {
        computedSize
    }

    func rebuild() {
        for sub in subviews { sub.removeFromSuperview() }
        symbolGridScrollView = nil
        symbolCategoryScrollView = nil

        let w = panelWidth
        let h: CGFloat
        switch state.page {
        case .menu:
            h = buildMenuGrid(width: w)
        case .calculator:
            h = buildCalculator(width: w)
        case .phrases:
            h = buildPhrases(width: w)
        case .dateTime:
            h = buildDateTime(width: w)
        case .symbols:
            h = buildSymbols(width: w)
        }
        computedSize = NSSize(width: w, height: max(h, 36))
    }

    // MARK: 2-Column Main Menu

    private func buildMenuGrid(width: CGFloat) -> CGFloat {
        let items = VModeMenuItem.allCases
        let rowCount = (items.count + 1) / 2
        let colW = (width - 8 - 3) * 0.5
        var y: CGFloat = 1.5

        for row in 0..<rowCount {
            let leftIdx = row * 2
            let rightIdx = leftIdx + 1
            y += 2.5

            let leftCell = makeMenuCell(item: items[leftIdx], index: leftIdx, frame: NSRect(x: 4, y: y, width: colW, height: 27))
            addSubview(leftCell)
            if rightIdx < items.count {
                let rightCell = makeMenuCell(item: items[rightIdx], index: rightIdx, frame: NSRect(x: 4 + colW + 3, y: y, width: colW, height: 27))
                addSubview(rightCell)
            }
            y += 27 + 2.5

            if row < rowCount - 1 {
                addSubview(makeDivider(y: y, width: width, alpha: state.isDark ? 0.16 : 0.22))
                y += 1
            }
        }
        return y + 1.5
    }

    private func makeMenuCell(item: VModeMenuItem, index: Int, frame: NSRect) -> NSView {
        let isSelected = (state.selectedMenuIndex == index)
        let cell = VModeClickableRowNSView(frame: frame)
        cell.wantsLayer = true
        cell.layer?.cornerCurve = .continuous
        cell.layer?.cornerRadius = 6
        cell.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        cell.onClick = { [weak self] in self?.onSelectMenuItem(item) }

        let badge = NSTextField(labelWithString: item.badgeLabel)
        let baseFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let desc = baseFont.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: desc, size: 12) {
            badge.font = f
        } else {
            badge.font = baseFont
        }
        badge.alignment = .center
        badge.textColor = isSelected ? NSColor.white.withAlphaComponent(0.95) : .secondaryLabelColor
        badge.frame = NSRect(x: 7, y: 6, width: 11, height: 15)
        cell.addSubview(badge)

        let icon = NSImageView(frame: NSRect(x: 23.5, y: 6, width: 15, height: 15))
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = isSelected ? .white : NSColor.labelColor.withAlphaComponent(0.85)
        icon.imageScaling = .scaleProportionallyDown
        cell.addSubview(icon)

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12.5, weight: isSelected ? .medium : .regular)
        title.textColor = isSelected ? .white : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 44, y: 5.5, width: max(20, frame.width - 50), height: 16)
        cell.addSubview(title)

        return cell
    }

    // MARK: Calculator Sub-Mode

    private func buildCalculator(width: CGFloat) -> CGFloat {
        let results = state.calcResults
        var y: CGFloat = 4.5
        if results.isEmpty {
            let label = NSTextField(labelWithString: state.calcExpression.isEmpty ? "输入数字或算式，如 128*6+50" : state.calcExpression)
            label.font = .systemFont(ofSize: 12.5)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 10, y: y + 7, width: width - 20, height: 16)
            addSubview(label)
            return y + 30 + 4.5
        }
        for (idx, item) in results.enumerated() {
            let row = makeResultRow(
                index: idx,
                item: item,
                showNumber: false,
                showReturnBadge: true,
                frame: NSRect(x: 4.5, y: y, width: width - 9, height: 27)
            )
            addSubview(row)
            y += 27 + (idx < results.count - 1 ? 1.5 : 0)
        }
        return y + 4.5
    }

    // MARK: Phrases Sub-Mode

    private func buildPhrases(width: CGFloat) -> CGFloat {
        let items = state.phraseItems
        var y = addSubHeader(title: "常用语", icon: "shippingbox", hint: "数字键或回车上屏", width: width)
        addSubview(makeDivider(y: y, width: width, alpha: state.isDark ? 0.18 : 0.25))
        y += 1

        if items.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "暂无常用语")
            emptyLabel.font = .systemFont(ofSize: 13)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.frame = NSRect(x: 12, y: y + 13, width: 100, height: 18)
            addSubview(emptyLabel)

            let btn = NSButton(title: "去设置添加", target: self, action: #selector(handleOpenSettings))
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            let bSize = btn.fittingSize
            btn.frame = NSRect(x: width - 12 - bSize.width, y: y + 10, width: bSize.width, height: bSize.height)
            addSubview(btn)
            return y + 44
        }

        y += 6
        for (idx, item) in items.enumerated() {
            let row = makeResultRow(index: idx, item: item, showNumber: true, showReturnBadge: false, frame: NSRect(x: 6, y: y, width: width - 12, height: 27))
            addSubview(row)
            y += 27 + (idx < items.count - 1 ? 2 : 0)
        }
        return y + 6
    }

    // MARK: DateTime Sub-Mode

    private func buildDateTime(width: CGFloat) -> CGFloat {
        let items = state.dateTimeItems
        var y = addSubHeader(title: "日期时间", icon: "calendar.badge.clock", hint: "数字键或回车上屏", width: width)
        addSubview(makeDivider(y: y, width: width, alpha: state.isDark ? 0.18 : 0.25))
        y += 7

        for (idx, item) in items.enumerated() {
            let row = makeResultRow(index: idx, item: item, showNumber: true, showReturnBadge: false, frame: NSRect(x: 6, y: y, width: width - 12, height: 27))
            addSubview(row)
            y += 27 + (idx < items.count - 1 ? 2 : 0)
        }
        return y + 6
    }

    // MARK: Symbols Sub-Mode

    private func buildSymbols(width: CGFloat) -> CGFloat {
        var y = addSubHeader(title: "符号", icon: "face.smiling", hint: "Tab 切换分类 · 方向键选择", width: width)
        addSubview(makeDivider(y: y, width: width, alpha: state.isDark ? 0.18 : 0.25))
        y += 1

        // Horizontal category strip
        let catScroll = NSScrollView(frame: NSRect(x: 0, y: y, width: width, height: 32))
        catScroll.hasHorizontalScroller = false
        catScroll.hasVerticalScroller = false
        catScroll.drawsBackground = false
        catScroll.borderType = .noBorder

        let catDoc = VModeFlippedDocumentView()
        var cx: CGFloat = 8
        var activeCatRect: NSRect = .zero
        for cat in VModeSymbolCategory.allCases {
            let active = (cat == state.symbolCategory)
            let pill = VModeClickableRowNSView()
            pill.wantsLayer = true
            pill.layer?.cornerCurve = .continuous
            pill.layer?.cornerRadius = 11
            pill.layer?.backgroundColor = active ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            pill.onClick = { [weak self] in
                self?.state.symbolCategory = cat
                self?.state.selectedListIndex = 0
                VModePanelController.shared.updateLayout()
            }

            let label = NSTextField(labelWithString: cat.title)
            label.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
            label.textColor = active ? .white : .secondaryLabelColor
            label.sizeToFit()
            let pw = ceil(label.fittingSize.width) + 16
            pill.frame = NSRect(x: cx, y: 5, width: pw, height: 22)
            label.frame = NSRect(x: 8, y: 3, width: ceil(label.fittingSize.width), height: 16)
            pill.addSubview(label)
            catDoc.addSubview(pill)
            if active { activeCatRect = pill.frame }
            cx += pw + 3
        }
        catDoc.frame = NSRect(x: 0, y: 0, width: max(width, cx + 5), height: 32)
        catScroll.documentView = catDoc
        if !activeCatRect.isEmpty {
            catDoc.scrollToVisible(activeCatRect.insetBy(dx: -12, dy: 0))
        }
        addSubview(catScroll)
        symbolCategoryScrollView = catScroll
        y += 32

        addSubview(makeDivider(y: y, width: width, alpha: state.isDark ? 0.18 : 0.25))
        y += 1

        // 6-column scrollable symbol grid
        let symbols = state.symbolCategory.symbols
        let gridHeight: CGFloat = 196
        let gridScroll = NSScrollView(frame: NSRect(x: 0, y: y, width: width, height: gridHeight))
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = false
        gridScroll.borderType = .noBorder

        let cols = 6
        let pad: CGFloat = 8
        let gap: CGFloat = 4
        let cellW = floor((width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let cellH: CGFloat = 32
        let rows = (symbols.count + cols - 1) / cols
        let docH = pad * 2 + CGFloat(rows) * cellH + CGFloat(max(0, rows - 1)) * gap

        let gridDoc = VModeFlippedDocumentView(frame: NSRect(x: 0, y: 0, width: width, height: max(gridHeight, docH)))
        var selectedRect: NSRect = .zero
        for (idx, sym) in symbols.enumerated() {
            let r = idx / cols
            let c = idx % cols
            let x = pad + CGFloat(c) * (cellW + gap)
            let cy = pad + CGFloat(r) * (cellH + gap)
            let isSelected = (state.selectedListIndex == idx)

            let cell = VModeClickableRowNSView(frame: NSRect(x: x, y: cy, width: cellW, height: cellH))
            cell.wantsLayer = true
            cell.layer?.cornerCurve = .continuous
            cell.layer?.cornerRadius = 7
            cell.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.labelColor.withAlphaComponent(0.05).cgColor
            cell.onClick = { [weak self] in self?.onCommitText(sym) }

            let lbl = NSTextField(labelWithString: sym)
            lbl.font = .systemFont(ofSize: 16)
            lbl.alignment = .center
            lbl.textColor = isSelected ? .white : .labelColor
            lbl.frame = NSRect(x: 0, y: 6, width: cellW, height: 20)
            cell.addSubview(lbl)
            gridDoc.addSubview(cell)
            if isSelected { selectedRect = cell.frame }
        }
        gridScroll.documentView = gridDoc
        if !selectedRect.isEmpty {
            gridDoc.scrollToVisible(selectedRect.insetBy(dx: 0, dy: -16))
        }
        addSubview(gridScroll)
        symbolGridScrollView = gridScroll
        lastSymbolCategory = state.symbolCategory
        return y + gridHeight
    }

    // MARK: Shared Subviews

    private func addSubHeader(title: String, icon: String, hint: String, width: CGFloat) -> CGFloat {
        let headerH: CGFloat = 34
        let backBtn = VModeClickableRowNSView(frame: NSRect(x: 10, y: 7, width: 20, height: 20))
        backBtn.onClick = { [weak self] in self?.onBackToMenu() }
        let chev = NSImageView(frame: NSRect(x: 4, y: 4, width: 12, height: 12))
        let chevCfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        chev.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?.withSymbolConfiguration(chevCfg)
        chev.contentTintColor = .secondaryLabelColor
        backBtn.addSubview(chev)
        addSubview(backBtn)

        let iconView = NSImageView(frame: NSRect(x: 34, y: 9.5, width: 15, height: 15))
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLbl.textColor = .labelColor
        titleLbl.sizeToFit()
        titleLbl.frame = NSRect(x: 54, y: 8.5, width: ceil(titleLbl.fittingSize.width), height: 17)
        addSubview(titleLbl)

        let hintLbl = NSTextField(labelWithString: hint)
        hintLbl.font = .systemFont(ofSize: 11)
        hintLbl.textColor = .secondaryLabelColor
        hintLbl.alignment = .right
        hintLbl.sizeToFit()
        let hw = ceil(hintLbl.fittingSize.width)
        hintLbl.frame = NSRect(x: width - 10 - hw, y: 10, width: hw, height: 14)
        addSubview(hintLbl)

        return headerH
    }

    private func makeResultRow(index: Int, item: VModeResultItem, showNumber: Bool, showReturnBadge: Bool, frame: NSRect) -> NSView {
        let isSelected = (state.selectedListIndex == index)
        let row = VModeClickableRowNSView(frame: frame)
        row.wantsLayer = true
        row.layer?.cornerCurve = .continuous
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        row.onClick = { [weak self] in self?.onCommitText(item.value) }

        var x: CGFloat = 8
        if showNumber {
            let num = NSTextField(labelWithString: "\(index + 1)")
            let base = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            if let desc = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: desc, size: 11.5) {
                num.font = f
            } else {
                num.font = base
            }
            num.alignment = .center
            num.textColor = isSelected ? NSColor.white.withAlphaComponent(0.95) : .secondaryLabelColor
            num.frame = NSRect(x: x, y: 6, width: 12, height: 15)
            row.addSubview(num)
            x += 18
        }

        var rightEdge = frame.width - 8
        if showReturnBadge && isSelected {
            let badge = NSView(frame: NSRect(x: rightEdge - 17, y: 5, width: 17, height: 17))
            badge.wantsLayer = true
            badge.layer?.cornerCurve = .continuous
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
            let ret = NSTextField(labelWithString: "↵")
            ret.font = .systemFont(ofSize: 10, weight: .medium)
            ret.alignment = .center
            ret.textColor = NSColor.white.withAlphaComponent(0.92)
            ret.frame = NSRect(x: 0, y: 1.5, width: 17, height: 14)
            badge.addSubview(ret)
            row.addSubview(badge)
            rightEdge -= 23
        }

        if let sub = item.subtitle, !sub.isEmpty {
            let subLbl = NSTextField(labelWithString: sub)
            subLbl.font = .systemFont(ofSize: 11)
            subLbl.textColor = isSelected ? NSColor.white.withAlphaComponent(0.80) : .secondaryLabelColor
            subLbl.lineBreakMode = .byTruncatingTail
            let sw = min(84, ceil(subLbl.fittingSize.width))
            subLbl.frame = NSRect(x: rightEdge - sw, y: 6.5, width: sw, height: 14)
            row.addSubview(subLbl)
            rightEdge -= (sw + 6)
        }

        let valLbl = NSTextField(labelWithString: item.value)
        valLbl.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        valLbl.textColor = isSelected ? .white : .labelColor
        valLbl.lineBreakMode = .byTruncatingTail
        valLbl.frame = NSRect(x: x, y: 5.5, width: max(20, rightEdge - x), height: 16)
        row.addSubview(valLbl)

        return row
    }

    private func makeDivider(y: CGFloat, width: CGFloat, alpha: CGFloat) -> NSView {
        let div = NSView(frame: NSRect(x: 0, y: y, width: width, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(alpha).cgColor
        return div
    }

    @objc private func handleOpenSettings() {
        onOpenSettings()
    }
}

// MARK: - VModePanelController

final class VModePanelController {
    static let shared = VModePanelController()

    let state = VModeState()

    var onSelectMenuItem: ((VModeMenuItem) -> Void)?
    var onCommitText: ((String) -> Void)?
    var onBackToMenu: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private let contentNSView: VModeContentNSView
    private var glassContainerView: NSView?
    private var fallbackEffectView: NSVisualEffectView?
    private var lastAnchorRect: NSRect?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    var isVisible: Bool { panel.isVisible }

    private init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 254, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = p

        let view = VModeContentNSView(
            state: state,
            onSelectMenuItem: { item in VModePanelController.shared.onSelectMenuItem?(item) },
            onCommitText: { text in VModePanelController.shared.onCommitText?(text) },
            onBackToMenu: { VModePanelController.shared.onBackToMenu?() },
            onOpenSettings: { VModePanelController.shared.onSelectMenuItem?(.settings) }
        )
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 14
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 14
            glass.layer?.masksToBounds = true
            glass.contentView = view
            p.contentView = glass
            self.glassContainerView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.cornerRadius = 14
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                view.topAnchor.constraint(equalTo: effect.topAnchor),
                view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
            self.fallbackEffectView = effect
        }

        self.contentNSView = view
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.contentNSView.rebuild()
                self.positionPanel(anchorRect: self.lastAnchorRect)
            }
            .store(in: &cancellables)
    }

    func show(near anchorRect: NSRect?, isDark: Bool) {
        state.isDark = isDark
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel.appearance = appearance
        contentNSView.appearance = appearance
        if #available(macOS 26.0, *), let glass = glassContainerView as? NSGlassEffectView {
            glass.appearance = appearance
        } else if let effect = fallbackEffectView {
            effect.appearance = appearance
        }
        lastAnchorRect = anchorRect
        contentNSView.rebuild()
        positionPanel(anchorRect: anchorRect)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
    }

    func updateAnchor(_ anchorRect: NSRect?) {
        guard panel.isVisible else { return }
        lastAnchorRect = anchorRect
        positionPanel(anchorRect: anchorRect)
    }

    func updateLayout() {
        guard panel.isVisible else { return }
        contentNSView.rebuild()
        positionPanel(anchorRect: lastAnchorRect)
    }

    func hide() {
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.onDismiss?()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.window !== self.panel && !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.onDismiss?()
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func positionPanel(anchorRect: NSRect?) {
        let size = contentNSView.preferredSize()
        guard size.width > 0 && size.height > 0 else { return }

        let mouse = NSEvent.mouseLocation
        let screen = (anchorRect.flatMap { rect in NSScreen.screens.first { $0.frame.contains(rect.origin) } })
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: NSPoint
        if let anchor = anchorRect {
            let spacing: CGFloat = 6
            var x = anchor.minX
            var y = anchor.minY - size.height - spacing
            if y < visible.minY + 4 {
                y = anchor.maxY + spacing
            }
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
            origin = NSPoint(x: round(x), y: round(y))
        } else {
            var x = mouse.x + 10
            var y = mouse.y - 10 - size.height
            if y < visible.minY + 8 {
                y = mouse.y + 10
            }
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
            origin = NSPoint(x: round(x), y: round(y))
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }
}
