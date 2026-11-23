import Cocoa
import SwiftUI

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

// MARK: - SwiftUI V-Mode Panel View

private struct VModePopupView: View {
    @ObservedObject var state: VModeState
    let onSelectMenuItem: (VModeMenuItem) -> Void
    let onCommitText: (String) -> Void
    let onBackToMenu: () -> Void
    let onOpenSettings: () -> Void

    private var highlightColor: Color {
        Color.accentColor
    }

    private var panelWidth: CGFloat {
        switch state.page {
        case .calculator: return 216
        case .symbols: return 316
        default: return 254
        }
    }

    var body: some View {
        Group {
            switch state.page {
            case .menu:
                menuGridView
            case .calculator:
                calculatorView
            case .phrases:
                phrasesView
            case .symbols:
                symbolsView
            case .dateTime:
                dateTimeView
            }
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, state.isDark ? .dark : .light)
    }

    // MARK: 2-Column Main Menu (Matches WeType V-Mode Grid)

    private var menuGridView: some View {
        let items = VModeMenuItem.allCases
        let rowCount = (items.count + 1) / 2
        return VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                let leftIdx = row * 2
                let rightIdx = leftIdx + 1
                HStack(spacing: 3) {
                    menuCell(item: items[leftIdx], index: leftIdx)
                    if rightIdx < items.count {
                        menuCell(item: items[rightIdx], index: rightIdx)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 27)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2.5)

                if row < rowCount - 1 {
                    Divider()
                        .opacity(state.isDark ? 0.16 : 0.22)
                }
            }
        }
        .padding(.vertical, 1.5)
    }

    private func menuCell(item: VModeMenuItem, index: Int) -> some View {
        let isSelected = (state.selectedMenuIndex == index)
        return Button {
            onSelectMenuItem(item)
        } label: {
            HStack(spacing: 5.5) {
                Text(item.badgeLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.secondary)
                    .frame(width: 11, alignment: .center)

                Image(systemName: item.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .frame(width: 15, alignment: .center)

                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? highlightColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Calculator Sub-Mode (Matches Image 1 & Image 2 Clean Candidate List)

    private var calculatorView: some View {
        let results = state.calcResults
        return VStack(alignment: .leading, spacing: 1.5) {
            if results.isEmpty {
                HStack(spacing: 6) {
                    Text(state.calcExpression.isEmpty ? "输入数字或算式，如 128*6+50" : state.calcExpression)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                    resultRow(index: idx, item: item, showNumber: false, showReturnBadge: true)
                }
            }
        }
        .padding(4.5)
    }

    // MARK: Phrases Sub-Mode

    private var phrasesView: some View {
        let items = state.phraseItems
        return VStack(alignment: .leading, spacing: 0) {
            subHeader(title: "常用语", icon: "shippingbox", hint: "数字键或回车上屏")
            Divider().opacity(state.isDark ? 0.18 : 0.25)

            if items.isEmpty {
                HStack {
                    Text("暂无常用语")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("去设置添加") {
                        onOpenSettings()
                    }
                    .controlSize(.small)
                }
                .padding(12)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        resultRow(index: idx, item: item, showNumber: true)
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: DateTime Sub-Mode

    private var dateTimeView: some View {
        let items = state.dateTimeItems
        return VStack(alignment: .leading, spacing: 0) {
            subHeader(title: "日期时间", icon: "calendar.badge.clock", hint: "数字键或回车上屏")
            Divider().opacity(state.isDark ? 0.18 : 0.25)

            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    resultRow(index: idx, item: item, showNumber: true)
                }
            }
            .padding(6)
        }
    }

    // MARK: Symbols Sub-Mode

    private var symbolsView: some View {
        let symbols = state.symbolCategory.symbols
        return VStack(alignment: .leading, spacing: 0) {
            subHeader(title: "符号", icon: "face.smiling", hint: "Tab 切换分类 · 方向键选择")
            Divider().opacity(state.isDark ? 0.18 : 0.25)

            ScrollViewReader { tabProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(VModeSymbolCategory.allCases) { cat in
                            let active = (cat == state.symbolCategory)
                            Button {
                                state.symbolCategory = cat
                                state.selectedListIndex = 0
                            } label: {
                                Text(cat.title)
                                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? Color.white : Color.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(active ? highlightColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .id(cat)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: state.symbolCategory) { newCat in
                    withAnimation(.easeOut(duration: 0.12)) {
                        tabProxy.scrollTo(newCat, anchor: .center)
                    }
                }
            }

            Divider().opacity(state.isDark ? 0.18 : 0.25)

            ScrollViewReader { gridProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                        ForEach(Array(symbols.enumerated()), id: \.offset) { idx, sym in
                            let isSelected = (state.selectedListIndex == idx)
                            Button {
                                onCommitText(sym)
                            } label: {
                                Text(sym)
                                    .font(.system(size: 16))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(isSelected ? highlightColor : Color.primary.opacity(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 196)
                .onChange(of: state.selectedListIndex) { newIdx in
                    gridProxy.scrollTo(newIdx, anchor: .center)
                }
                .onChange(of: state.symbolCategory) { _ in
                    gridProxy.scrollTo(0, anchor: .top)
                }
            }
        }
    }

    // MARK: Shared Subview Helpers

    private func subHeader(title: String, icon: String, hint: String) -> some View {
        HStack(spacing: 6) {
            Button {
                onBackToMenu()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)

            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))

            Spacer()

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func resultRow(index: Int, item: VModeResultItem, showNumber: Bool, showReturnBadge: Bool = false) -> some View {
        let isSelected = (state.selectedListIndex == index)
        return Button {
            onCommitText(item.value)
        } label: {
            HStack(spacing: 6) {
                if showNumber {
                    Text("\(index + 1)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.secondary)
                        .frame(width: 12, alignment: .center)
                }
                Text(item.value)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                if showReturnBadge && isSelected {
                    Text("↵")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 17, height: 17)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.20))
                        )
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? highlightColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    private let hostingView: NSHostingView<VModePopupView>
    private var glassContainerView: NSView?
    private var fallbackEffectView: NSVisualEffectView?
    private var lastAnchorRect: NSRect?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    private init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
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

        let stateRef = self.state
        let host = NSHostingView(rootView: VModePopupView(
            state: stateRef,
            onSelectMenuItem: { item in
                VModePanelController.shared.onSelectMenuItem?(item)
            },
            onCommitText: { text in
                VModePanelController.shared.onCommitText?(text)
            },
            onBackToMenu: {
                VModePanelController.shared.onBackToMenu?()
            },
            onOpenSettings: {
                VModePanelController.shared.onSelectMenuItem?(.settings)
            }
        ))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerCurve = .continuous
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = 14
            glass.wantsLayer = true
            glass.layer?.cornerCurve = .continuous
            glass.layer?.cornerRadius = 14
            glass.layer?.masksToBounds = true
            glass.contentView = host
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
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            p.contentView = effect
            self.fallbackEffectView = effect
        }

        self.hostingView = host
    }

    func show(near anchorRect: NSRect?, isDark: Bool) {
        state.isDark = isDark
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel.appearance = appearance
        hostingView.appearance = appearance
        if #available(macOS 26.0, *), let glass = glassContainerView as? NSGlassEffectView {
            glass.appearance = appearance
        } else if let effect = fallbackEffectView {
            effect.appearance = appearance
        }
        lastAnchorRect = anchorRect
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
        positionPanel(anchorRect: lastAnchorRect)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.positionPanel(anchorRect: self.lastAnchorRect)
        }
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
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
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
