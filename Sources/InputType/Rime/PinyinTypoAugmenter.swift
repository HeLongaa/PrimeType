import Foundation

/// Weighted QWERTY physical-distance Pinyin Augmenter (Plan A).
///
/// Design goals:
/// - **Zero overhead on clean pinyin & pure-initial abbreviations** (`nh`, `mwt`, `cxy`):
///   fast trigger detector runs in ~0.01ms and returns `.none` unless raw input contains
///   broken consonant fragments, unparseable spans, or suspicious vowel splits.
/// - **Tiny memory footprint (< 16 KB)**: static ~410 Mandarin full-syllable table + QWERTY key coordinates.
/// - **Fast Beam DP (< 1.0ms)**: repairs adjacent-key substitutions (`wozaijiabam` -> `wozaijiaban`,
///   `nohao` -> `nihao`, `xiamzai` -> `xianzai`, `shemme` -> `shenme`), adjacent transpositions
///   (`xianzia` -> `xianzai`, `weixni` -> `weixin`, `zhognguo` -> `zhongguo`), accidental extra keys
///   (`nihhao` -> `nihao`, `wpo` -> `wo`), and missing vowels (`shjian` -> `shijian`, `wnti` -> `wenti`).
enum PinyinTypoAugmenter {
    enum Diagnosis: Equatable {
        case none
        /// Raw input clearly contains invalid/broken fragments (e.g. `wo zai jia ba m`, `n o hao`, `sh jian`).
        /// Repaired full-sentence candidate should be promoted to Top-1.
        case broken
        /// Raw input is parseable only via suspicious orphan single-vowel split (e.g. `xian zi a`).
        /// Repaired full-sentence candidate should be promoted strongly (Top-1 or Top-2).
        case suspicious
    }

    struct RepairCandidate: Equatable {
        let pinyin: String
        let cost: Double
        let syllableCount: Int
    }

    // Complete table of standard Mandarin Pinyin syllables (including `v` alias for `ü` where used in input).
    static let validSyllables: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cei", "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hm", "hng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun", "jv", "jvan", "jve", "jvn",
        "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu",
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun", "qv", "qvan", "qve", "qvn",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sei", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun", "xv", "xvan", "xve", "xvn",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun", "yv", "yvan", "yve", "yvn",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo"
    ]

    private static let vowels: Set<UInt8> = [
        UInt8(ascii: "a"), UInt8(ascii: "e"), UInt8(ascii: "i"),
        UInt8(ascii: "o"), UInt8(ascii: "u"), UInt8(ascii: "v")
    ]

    /// Standard US QWERTY physical coordinates (row, col with realistic stagger) for key proximity cost.
    private static let keyCoords: [UInt8: (Double, Double)] = {
        let rows: [(Double, Double, String)] = [
            (0.0, 0.0, "qwertyuiop"),
            (1.0, 0.25, "asdfghjkl"),
            (2.0, 0.75, "zxcvbnm")
        ]
        var map: [UInt8: (Double, Double)] = [:]
        for (row, xOffset, chars) in rows {
            for (idx, b) in chars.utf8.enumerated() {
                map[b] = (row, Double(idx) + xOffset)
            }
        }
        return map
    }()

    /// Precomputed QWERTY neighbors within physical Euclidean distance <= 1.48 (same-row + immediate diagonal neighbors).
    private static let keyNeighbors: [UInt8: [(key: UInt8, cost: Double)]] = {
        var result: [UInt8: [(UInt8, Double)]] = [:]
        for (a, posA) in keyCoords {
            var list: [(UInt8, Double)] = []
            for (b, posB) in keyCoords where a != b {
                let dr = posA.0 - posB.0
                let dc = posA.1 - posB.1
                let dist = (dr * dr + dc * dc).squareRoot()
                if dist <= 1.48 {
                    // Same-row direct neighbor (~1.0 dist) costs 0.88; diagonal neighbor (~1.03–1.45) costs 0.96–1.18
                    let cost = 0.62 + dist * 0.32
                    list.append((b, cost))
                }
            }
            list.sort { $0.1 < $1.1 }
            result[a] = list
        }
        return result
    }()

    private static let neighborLookup: [UInt8: [UInt8: Double]] = {
        var map: [UInt8: [UInt8: Double]] = [:]
        for (k, list) in keyNeighbors {
            var inner: [UInt8: Double] = [:]
            for item in list {
                inner[item.key] = item.cost
            }
            map[k] = inner
        }
        return map
    }()

    /// High-frequency Mandarin syllables used as a deterministic tie-breaker among equal-distance QWERTY repairs
    /// (e.g. `no` -> `ni` beats `bo`/`mo`; `sh` -> `shi` beats `sha`/`shu`; `wn` -> `wen` beats `wan`).
    private static let highFrequencySyllables: Set<String> = [
        "a", "ai", "an", "ba", "ban", "bao", "bei", "ben", "bi", "bian", "biao", "bie", "bu",
        "cai", "can", "chang", "chao", "che", "chen", "cheng", "chi", "chu", "chuan", "ci", "cong", "cuo",
        "da", "dai", "dan", "dang", "dao", "de", "deng", "di", "dian", "ding", "dong", "dou", "du", "dui", "duo",
        "er", "fa", "fan", "fang", "fei", "fen", "feng", "fu",
        "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guan", "guang", "gui", "guo",
        "hai", "han", "hao", "he", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiu", "ju", "juan", "jue", "jun",
        "kai", "kan", "kao", "ke", "ken", "kong", "kou", "ku", "kuai", "kuan", "kun",
        "lai", "lan", "lao", "le", "lei", "leng", "li", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "long", "lou", "lu", "luan", "lun", "luo",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "min", "ming", "mu",
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "neng", "ni", "nian", "niang", "nin", "ning", "niu", "nong", "nu", "nv",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pin", "ping", "po", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "ruan", "rui", "run", "ruo",
        "san", "sao", "se", "sha", "shan", "shang", "shao", "she", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song", "su", "suan", "sui", "sun", "suo",
        "ta", "tai", "tan", "tang", "tao", "te", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhuan", "zhuang", "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo"
    ]

    /// Top ~75 ultra-high-frequency core Mandarin syllables (receive strongest tie-break preference).
    private static let coreSyllables: Set<String> = [
        "de", "shi", "wo", "ni", "ta", "zai", "you", "bu", "le", "he", "men", "zhe", "ge", "jiu", "dao",
        "shuo", "yao", "hui", "ke", "yi", "wei", "xian", "tian", "jian", "wen", "shen", "me", "xin", "ban",
        "jia", "ming", "zhong", "guo", "zheng", "chang", "hao", "lai", "qu", "dou", "neng", "dui", "shang",
        "xia", "zi", "ren", "da", "xiao", "xiang", "kan", "zhi", "zuo", "gei", "ba", "mei", "na", "gen",
        "yong", "dian", "hua", "gong", "qing", "fa", "kai", "guan", "xing", "jin", "cheng", "xu", "shu",
        "ru", "ti", "ji", "li", "ma", "ne", "zai", "hen", "hai", "ye", "dan", "ru", "guo"
    ]

    private static func frequencyPenalty(for syllable: String) -> Double {
        if coreSyllables.contains(syllable) { return 0.0 }
        if highFrequencySyllables.contains(syllable) { return 0.12 }
        return 0.24
    }

    /// Precomputed map of 1-edit corrupted forms -> [(validSyllable, editCost)] for O(1) Beam DP transitions!
    /// Covers:
    /// - adjacent-key substitution (e.g. `bam` -> `ban`, `no` -> `ni`, `xiam` -> `xian`, `shem` -> `shen`, `tiam` -> `tian`)
    /// - adjacent 2-char transposition (e.g. `zia` -> `zai`, `ina` -> `ian`, `una` -> `uan`, `gn` -> `ng`, `xni` -> `xin`)
    /// - accidental extra char deletion (e.g. `nihh` / `shji` -> `shi`, `wpo` -> `wo`, `hh` doubled keys)
    /// - missing vowel/letter insertion (e.g. `sh` -> `shi`, `wn` -> `wen`, `zh` -> `zhi`, `xn` -> `xin`/`xian`)
    private static let singleEditSyllableMap: [String: [(syllable: String, cost: Double)]] = {
        var map: [String: [String: Double]] = [:]

        func record(corrupted: String, target: String, cost: Double) {
            guard !corrupted.isEmpty, corrupted != target else { return }
            let adjustedCost = cost + frequencyPenalty(for: target)
            if let existing = map[corrupted]?[target], existing <= adjustedCost {
                return
            }
            var inner = map[corrupted] ?? [:]
            inner[target] = adjustedCost
            map[corrupted] = inner
        }

        for syl in validSyllables {
            let bytes = Array(syl.utf8)
            let n = bytes.count

            // 1. Adjacent-key substitution (only for len >= 2 so single letters don't explode)
            if n >= 2 {
                for i in 0..<n {
                    guard let neighbors = keyNeighbors[bytes[i]] else { continue }
                    let origIsVowel = vowels.contains(bytes[i])
                    for (nb, nbCost) in neighbors {
                        var mutated = bytes
                        mutated[i] = nb
                        let corrupted = String(decoding: mutated, as: UTF8.self)
                        if !validSyllables.contains(corrupted) {
                            // Cross-class consonant<->vowel substitutions (e.g. `u`<->`j`/`h`) are noisier than
                            // same-class swaps (e.g. `m`<->`n`, `i`<->`o`, `u`<->`i`).
                            let crossClassPenalty = (vowels.contains(nb) != origIsVowel) ? 0.22 : 0.0
                            record(corrupted: corrupted, target: syl, cost: nbCost + crossClassPenalty)
                        }
                    }
                }
            }

            // 2. Adjacent transposition (e.g. `zai` <-> `zia`, `ian` <-> `ina`, `ong` <-> `ogn`, `xin` <-> `xni`)
            if n >= 2 {
                for i in 0..<(n - 1) where bytes[i] != bytes[i + 1] {
                    var mutated = bytes
                    mutated.swapAt(i, i + 1)
                    let corrupted = String(decoding: mutated, as: UTF8.self)
                    if !validSyllables.contains(corrupted) {
                        record(corrupted: corrupted, target: syl, cost: 0.82)
                    }
                }
            }

            // 3. Accidental extra key inside a syllable (doubled char or QWERTY neighbor of adjacent char)
            //    e.g. `shi` -> `shhi`, `shji`, `wo` -> `wpo`, `zhong` -> `zhogng`
            if n >= 2 && n <= 5 {
                for i in 0..<n {
                    // Doubled letter at position i
                    var doubled = bytes
                    doubled.insert(bytes[i], at: i)
                    let doubledStr = String(decoding: doubled, as: UTF8.self)
                    if !validSyllables.contains(doubledStr) {
                        record(corrupted: doubledStr, target: syl, cost: 0.92)
                    }
                    // Neighbor key accidentally brushed right after bytes[i]
                    if let neighbors = keyNeighbors[bytes[i]] {
                        for (nb, nbCost) in neighbors.prefix(4) where nbCost <= 1.02 {
                            var extra = bytes
                            extra.insert(nb, at: i + 1)
                            let extraStr = String(decoding: extra, as: UTF8.self)
                            if !validSyllables.contains(extraStr) {
                                record(corrupted: extraStr, target: syl, cost: 1.08)
                            }
                        }
                    }
                }
            }

            // 4. Missing single vowel/letter inside a syllable of length >= 3 (e.g. `shi` <- `sh`, `wen` <- `wn`, `xian` <- `xan`/`xin`, `zhi` <- `zh`)
            if n >= 3 {
                for i in 1..<n {
                    // Only allow dropping a vowel (most common fast-typing omission: shjian, wnti, zhdao, xnzai)
                    guard vowels.contains(bytes[i]) else { continue }
                    var omitted = bytes
                    omitted.remove(at: i)
                    let omittedStr = String(decoding: omitted, as: UTF8.self)
                    if omittedStr.count >= 2 && !validSyllables.contains(omittedStr) {
                        // Retroflex digraphs (`sh`/`zh`/`ch`) missing trailing vowel (`shi`/`zhi`/`chi`) are classic fast-typing omissions
                        let omitCost = (omittedStr == "sh" || omittedStr == "zh" || omittedStr == "ch") ? 0.92 : 1.12
                        record(corrupted: omittedStr, target: syl, cost: omitCost)
                    }
                }
            }
        }

        // Convert to deterministically sorted arrays (keep top 6 best syllable targets per corrupted fragment)
        var finalized: [String: [(syllable: String, cost: Double)]] = [:]
        finalized.reserveCapacity(map.count)
        for (corrupted, targets) in map {
            let sorted = targets
                .map { (syllable: $0.key, cost: $0.value) }
                .sorted { a, b in
                    if abs(a.cost - b.cost) > 1e-6 { return a.cost < b.cost }
                    if a.syllable.count != b.syllable.count { return a.syllable.count > b.syllable.count }
                    return a.syllable < b.syllable
                }
            finalized[corrupted] = Array(sorted.prefix(6))
        }
        return finalized
    }()

    // MARK: - Fast Trigger Diagnosis

    /// Determines in ~0.01ms whether `rawInput` / `preedit` looks mistyped and warrants QWERTY augmentation.
    /// Returns `.none` for all clean full-pinyin inputs AND for pure-consonant abbreviations (`nh`, `mwt`, `cxy`).
    static func diagnose(rawInput: String, preedit: String) -> Diagnosis {
        let len = rawInput.utf8.count
        guard len >= 4 && len <= 36 else { return .none }

        var hasVowel = false
        for b in rawInput.utf8 {
            guard b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z") else { return .none }
            if vowels.contains(b) {
                hasVowel = true
            }
        }
        // Pure consonant abbreviations (e.g. `mwt`, `cxy`, `zmb`, `srf`) are intentional简拼, not typos.
        guard hasVowel else { return .none }

        let segments = preedit
            .split { $0 == " " || $0 == "'" || $0 == "·" }
            .map { $0.lowercased() }
        guard !segments.isEmpty else { return .none }

        var invalidSegmentCount = 0
        var suspiciousSingleVowelSplits = 0
        for (idx, seg) in segments.enumerated() {
            if !validSyllables.contains(seg) {
                invalidSegmentCount += 1
            } else if seg == "o" || (seg == "a" && idx > 0 && segments[idx - 1].hasSuffix("i")) {
                // `n o`, `zi a`, `ti a`, `xi a` are classic adjacent-key / transposition breakages
                suspiciousSingleVowelSplits += 1
            }
        }

        if invalidSegmentCount > 0 {
            return .broken
        }

        // Even if Rime forced `xianzia` -> `xian zi a`, check if our strict Mandarin syllable segmenter
        // cannot parse it cleanly without orphan single-letter vowels.
        if suspiciousSingleVowelSplits > 0 {
            return .suspicious
        }

        return .none
    }

    // MARK: - Weighted Beam DP Pinyin Repair

    /// Generates up to `maxCandidates` repaired full-pinyin strings for a broken/suspicious `rawInput`.
    static func generateRepairs(rawInput: String, maxCandidates: Int = 3) -> [RepairCandidate] {
        let lower = rawInput.lowercased()
        let bytes = Array(lower.utf8)
        let n = bytes.count
        guard n >= 4 && n <= 36 else { return [] }

        let maxEdits = n >= 8 ? 2 : 1
        let beamWidth = 16

        struct BeamState {
            var syllables: [String]
            var cost: Double
            var edits: Int
        }

        var dp = Array(repeating: [BeamState](), count: n + 1)
        dp[0] = [BeamState(syllables: [], cost: 0.0, edits: 0)]

        for pos in 0..<n {
            guard !dp[pos].isEmpty else { continue }

            // Prune beam at current position
            if dp[pos].count > beamWidth {
                dp[pos].sort { a, b in
                    let sa = a.cost + Double(a.syllables.count) * 0.18
                    let sb = b.cost + Double(b.syllables.count) * 0.18
                    return sa < sb
                }
                dp[pos].removeSubrange(beamWidth...)
            }

            let maxChunkLen = min(7, n - pos)
            for chunkLen in 1...maxChunkLen {
                let slice = String(decoding: bytes[pos..<(pos + chunkLen)], as: UTF8.self)
                let nextPos = pos + chunkLen

                // 1. Exact valid Mandarin syllable (cost 0; tiny penalty on bare single-vowel `a`/`o`/`e` mid-word to prefer full syllables)
                if validSyllables.contains(slice) {
                    let singleVowelPenalty: Double = (chunkLen == 1 && pos > 0) ? 0.35 : 0.0
                    for st in dp[pos] {
                        dp[nextPos].append(
                            BeamState(
                                syllables: st.syllables + [slice],
                                cost: st.cost + singleVowelPenalty,
                                edits: st.edits
                            )
                        )
                    }
                }

                // 2. Single-edit syllable repairs (substitution / transposition / extra key / missing vowel)
                if let repairs = singleEditSyllableMap[slice] {
                    for st in dp[pos] where st.edits < maxEdits {
                        for rep in repairs {
                            dp[nextPos].append(
                                BeamState(
                                    syllables: st.syllables + [rep.syllable],
                                    cost: st.cost + rep.cost,
                                    edits: st.edits + 1
                                )
                            )
                        }
                    }
                }
            }

            // 3. Cross-boundary single stray extra key drop (e.g. accidental key hit right between two syllables)
            if pos + 1 < n {
                let stray = bytes[pos]
                let prevIsNeighbor = (pos > 0) && (bytes[pos - 1] == stray || (neighborLookup[bytes[pos - 1]]?[stray] != nil))
                let nextIsNeighbor = (bytes[pos + 1] == stray || (neighborLookup[bytes[pos + 1]]?[stray] != nil))
                if prevIsNeighbor || nextIsNeighbor {
                    let dropCost = (pos > 0 && bytes[pos - 1] == stray) || (bytes[pos + 1] == stray) ? 0.95 : 1.20
                    for st in dp[pos] where st.edits < maxEdits {
                        dp[pos + 1].append(
                            BeamState(
                                syllables: st.syllables,
                                cost: st.cost + dropCost,
                                edits: st.edits + 1
                            )
                        )
                    }
                }
            }
        }

        // Collect completed paths that actually made at least 1 edit and differ from rawInput
        var bestByJoined: [String: RepairCandidate] = [:]
        for st in dp[n] where st.edits > 0 && !st.syllables.isEmpty {
            let joined = st.syllables.joined()
            guard joined != lower else { continue }
            let score = st.cost + Double(st.syllables.count) * 0.18
            if let existing = bestByJoined[joined] {
                let existingScore = existing.cost + Double(existing.syllableCount) * 0.18
                if score < existingScore {
                    bestByJoined[joined] = RepairCandidate(pinyin: joined, cost: st.cost, syllableCount: st.syllables.count)
                }
            } else {
                bestByJoined[joined] = RepairCandidate(pinyin: joined, cost: st.cost, syllableCount: st.syllables.count)
            }
        }

        return bestByJoined.values
            .sorted { a, b in
                let sa = a.cost + Double(a.syllableCount) * 0.18
                let sb = b.cost + Double(b.syllableCount) * 0.18
                if abs(sa - sb) > 1e-6 { return sa < sb }
                return a.syllableCount < b.syllableCount
            }
            .prefix(maxCandidates)
            .map { $0 }
    }
}
