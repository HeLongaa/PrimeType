import Carbon
import Cocoa
import InputMethodKit

if CommandLine.arguments.contains("--register-input-source") {
    let appURL = URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app") as CFURL
    TISRegisterInputSource(appURL)
    let filter = [kTISPropertyInputSourceID as String: "com.lumocore.inputmethod.PrimeType.pinyin"] as CFDictionary
    if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
       let src = list.first {
        TISEnableInputSource(src)
        TISSelectInputSource(src)
    }
    exit(0)
}

if CommandLine.arguments.contains("--voice-test") {
    exit(VoiceEngineTestRunner.runCLI(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--self-test-experience") {
    var failures: [String] = []
    func assertCheck(_ condition: Bool, _ label: String) {
        if condition {
            print("TEST_PASS: \(label)")
        } else {
            print("TEST_FAIL: \(label)")
            failures.append(label)
        }
    }

    // 1. LatencyProbe P50 / P99 / over-16ms calculation
    let probe = LatencyProbe()
    for i in 1...100 {
        probe.recordSync(totalMs: Double(i) * 0.2, rimeMs: 2.0, tier1Ms: 0.3)
    }
    let snap = probe.snapshot()
    assertCheck(snap.sampleCount == 100 && snap.syncP50Ms >= 9.9 && snap.syncP99Ms >= 19.5 && snap.over16msCount == 20, "LatencyProbe percentiles and over-16ms tracking")

    // 2. Adaptive fetchLimit & CandidateDeduplicator index mapping
    assertCheck(
        CandidatePipeline.adaptiveFetchLimit(syllableCount: 2, isExpanded: false) == 36
        && CandidatePipeline.adaptiveFetchLimit(syllableCount: 8, isExpanded: false) == 18
        && CandidatePipeline.adaptiveFetchLimit(syllableCount: 12, isExpanded: false) == 12
        && CandidatePipeline.adaptiveFetchLimit(syllableCount: 12, isExpanded: true) == 80,
        "CandidatePipeline adaptive fetchLimit"
    )
    let rawCands = [
        RimeCandidateItem(text: "WeChat", comment: nil),
        RimeCandidateItem(text: "wechat", comment: nil),
        RimeCandidateItem(text: "微信", comment: nil),
        RimeCandidateItem(text: "ＷｅＣｈａｔ", comment: nil),
        RimeCandidateItem(text: "微信号", comment: nil)
    ]
    let built = CandidatePipeline.buildCandidates(rimeCandidates: rawCands, directPrefixItems: [], syllableCount: 2)
    assertCheck(
        built.count == 3 && built[0].text == "WeChat" && built[1].text == "微信" && built[1].originalRimeIndex == 2 && built[2].originalRimeIndex == 4,
        "CandidateDeduplicator removes semantic dupes and preserves originalRimeIndex"
    )

    // 3. UserRankingEngine: 3x mis-select + delete keeps word out of Top-3 even after 10 days; Shift+Delete blacklist
    let ranking = UserRankingEngine(storageURL: nil, persistEnabled: false)
    let t0 = Date().timeIntervalSince1970
    let sampleCands = [
        PresentedCandidate(text: "直道", comment: nil, originalRimeIndex: 0, isDirectCommit: false, isWholeSentence: true, baseRank: 0),
        PresentedCandidate(text: "知道", comment: nil, originalRimeIndex: 1, isDirectCommit: false, isWholeSentence: true, baseRank: 1),
        PresentedCandidate(text: "指导", comment: nil, originalRimeIndex: 2, isDirectCommit: false, isWholeSentence: true, baseRank: 2),
        PresentedCandidate(text: "之道", comment: nil, originalRimeIndex: 3, isDirectCommit: false, isWholeSentence: true, baseRank: 3)
    ]
    for round in 0..<3 {
        let rt = t0 + Double(round * 10)
        ranking.recordSelection(code: "zhidao", word: "直道", rank: 0, now: rt, bypassSecureCheck: true)
        _ = ranking.recordBackspaceAfterCommit(now: rt + 0.5, bypassSecureCheck: true)
        _ = ranking.recordBackspaceAfterCommit(now: rt + 0.7, bypassSecureCheck: true)
        ranking.recordSelection(code: "zhidao", word: "知道", rank: 1, skippedTopWords: ["直道"], now: rt + 1.5, bypassSecureCheck: true)
    }
    let after10Days = ranking.rerank(candidates: sampleCands, code: "zhidao", now: t0 + 10.0 * 86400.0)
    let misWordPos = after10Days.firstIndex(where: { $0.text == "直道" }) ?? -1
    assertCheck(after10Days.first?.text == "知道" && misWordPos >= 3, "UserRankingEngine 3x delete-after-commit sinks mis-word out of Top-3 for 10 days")
    ranking.blacklist(code: "zhidao", word: "之道", now: t0)
    let afterBlacklist = ranking.rerank(candidates: sampleCands, code: "zhidao", now: t0 + 1.0)
    assertCheck(!afterBlacklist.contains(where: { $0.text == "之道" }), "UserRankingEngine Shift+Delete blacklist hides candidate")

    // 4. EmitHistory: per-app isolation + entity boost
    let history = EmitHistory()
    history.recordCommit("我们在优化PrimeType架构", bundleID: "com.tencent.xinWeChat", now: t0, bypassSecureCheck: true)
    assertCheck(history.entityMatchBoost(for: "优化", bundleID: "com.tencent.xinWeChat", now: t0 + 1, bypassSecureCheck: true) > 0, "EmitHistory entity re-occurrence boost works in same app")
    assertCheck(history.entityMatchBoost(for: "优化", bundleID: "com.apple.Terminal", now: t0 + 1, bypassSecureCheck: true) == 0, "EmitHistory isolates context per host bundleID")

    // 5. CandidatePresenter: 150ms first-candidate lock & +0.15 lead threshold & max-1 flip
    let presenter = CandidatePresenter(lockFirstWindowSeconds: 0.15, top1LeadThreshold: 0.15)
    presenter.presentSync(preedit: "wo men dou zai xie cheng xu", candidates: sampleCands, now: 100.0)
    let swappedOrder = [sampleCands[1], sampleCands[0], sampleCands[2], sampleCands[3]]
    // Late async (> 150ms) MUST NOT touch index 0; inserts winner at index 1
    let lateRes = presenter.presentAsync(preedit: "wo men dou zai xie cheng xu", reranked: swappedOrder, leadMargin: 0.40, now: 100.30)
    assertCheck(presenter.currentCandidates[0].text == "直道" && presenter.currentCandidates[1].text == "知道" && !lateRes.flippedTop1, "CandidatePresenter locks index 0 after 150ms window")
    // Within 150ms + high margin allows at most 1 flip
    presenter.presentSync(preedit: "new preedit", candidates: sampleCands, now: 200.0)
    let earlyRes = presenter.presentAsync(preedit: "new preedit", reranked: swappedOrder, leadMargin: 0.25, now: 200.05)
    let secondFlipAttempt = presenter.presentAsync(preedit: "new preedit", reranked: [sampleCands[2], sampleCands[1], sampleCands[0], sampleCands[3]], leadMargin: 0.40, now: 200.08)
    assertCheck(earlyRes.flippedTop1 && presenter.currentCandidates[0].text == "知道" && !secondFlipAttempt.flippedTop1 && presenter.currentCandidates[1].text == "指导", "CandidatePresenter allows at most 1 async top-1 flip")

    // 6. QueryCoordinator: 20 rapid bursts leave only the latest token winning
    let coord = QueryCoordinator(debounceMs: 15, timeoutMs: 250)
    let sem = DispatchSemaphore(value: 0)
    var delivered: [Int] = []
    for i in 1...20 {
        coord.schedule(work: { i }, onResult: { val, _ in
            delivered.append(val)
            sem.signal()
        })
    }
    _ = sem.wait(timeout: .now() + 1.0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    assertCheck(delivered == [20], "QueryCoordinator cancels stale bursts and delivers only latest token")

    // 7. ClipboardManager sensitive pasteboard filtering
    assertCheck(
        ClipboardManager.containsSensitiveType([NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        && ClipboardManager.containsSensitiveType([NSPasteboard.PasteboardType("org.nspasteboard.TransientType")])
        && !ClipboardManager.containsSensitiveType([.string]),
        "ClipboardManager filters sensitive password manager pasteboard types"
    )

    // 8. Preedit syllable-left boundary navigation (da dao zhe li -> jumps by syllable boundaries)
    let raw = "dadaozheli"
    let pre = "da dao zhe li"
    let p1 = InputTypeController.previousSyllableBoundary(rawInput: raw, preedit: pre, currentCaret: 10)
    let p2 = InputTypeController.previousSyllableBoundary(rawInput: raw, preedit: pre, currentCaret: p1)
    let p3 = InputTypeController.previousSyllableBoundary(rawInput: raw, preedit: pre, currentCaret: p2)
    let p4 = InputTypeController.previousSyllableBoundary(rawInput: raw, preedit: pre, currentCaret: p3)
    let pMid = InputTypeController.previousSyllableBoundary(rawInput: raw, preedit: pre, currentCaret: 6)
    assertCheck(p1 == 8 && p2 == 5 && p3 == 2 && p4 == 0 && pMid == 5, "Preedit Left Arrow jumps cleanly across syllable boundaries")

    // 9. Smoothed UserRankingEngine: 1 single accidental select of #2 does NOT immediately hijack #1
    let calmRanking = UserRankingEngine(storageURL: nil, persistEnabled: false)
    calmRanking.recordSelection(code: "dadao", word: "打到", rank: 1, skippedTopWords: ["达到"], now: t0, bypassSecureCheck: true)
    let calmCands = [
        PresentedCandidate(text: "达到", comment: nil, originalRimeIndex: 0, isDirectCommit: false, isWholeSentence: true, baseRank: 0),
        PresentedCandidate(text: "打到", comment: nil, originalRimeIndex: 1, isDirectCommit: false, isWholeSentence: true, baseRank: 1)
    ]
    let afterOnePick = calmRanking.rerank(candidates: calmCands, code: "dadao", now: t0 + 1)
    assertCheck(afterOnePick.first?.text == "达到", "Smoothed UserRankingEngine does not overreact to a single selection")

    // 10. Visible pinyin syllable delimiter formatting (`xian zai shi shi` -> `xian'zai'shi'shi`) with exact UTF-8/UTF-16 alignment
    let rawPre1 = "xian zai shi shi"
    let fmtPre1 = InputTypeController.formatDisplayPreedit(rawPre1, selStartUTF8: 0)
    let rawPre2 = "现在shi shi"
    let fmtPre2 = InputTypeController.formatDisplayPreedit(rawPre2, selStartUTF8: "现在".utf8.count)
    let rawPre3 = "Hello World xian zai"
    let fmtPre3 = InputTypeController.formatDisplayPreedit(rawPre3, selStartUTF8: "Hello World ".utf8.count)
    assertCheck(
        fmtPre1 == "xian'zai'shi'shi"
        && fmtPre1.utf8.count == rawPre1.utf8.count
        && fmtPre1.utf16.count == rawPre1.utf16.count
        && fmtPre2 == "现在shi'shi"
        && fmtPre3 == "Hello World xian'zai",
        "Preedit syllable delimiter displays apostrophe cleanly with exact offset preservation"
    )

    // 11. VoiceActivationTracker (Layer 3): all-zero PCM warmup -> first non-zero confirmation + 300ms timeout fallback
    var tracker = VoiceActivationTracker()
    tracker.reset(captureGeneration: 1, startedAt: 100.0)
    let zeroFrame = [Int16](repeating: 0, count: VoicePreRollBuffer.frameSamples)
    let liveFrame = [Int16](repeating: 1200, count: VoicePreRollBuffer.frameSamples)
    let s1 = tracker.consume(frame: zeroFrame, now: 100.02)
    let s2 = tracker.consume(frame: zeroFrame, now: 100.04)
    let s3 = tracker.consume(frame: liveFrame, now: 100.06)
    var timeoutTracker = VoiceActivationTracker()
    timeoutTracker.reset(captureGeneration: 2, startedAt: 200.0)
    var lastTimeoutStep = VoiceActivationTracker.StepOutcome(isActivated: false, justConfirmed: false, shouldDropFrame: true, eventLog: nil)
    for i in 1...VoiceActivationTracker.maxZeroWarmupFrames {
        lastTimeoutStep = timeoutTracker.consume(frame: zeroFrame, now: 200.0 + Double(i) * 0.02)
    }
    assertCheck(
        !s1.isActivated && s1.shouldDropFrame && (s1.eventLog?.contains("all_zero_pcm_started") == true)
        && !s2.isActivated && s2.shouldDropFrame
        && s3.isActivated && s3.justConfirmed && !s3.shouldDropFrame && (s3.eventLog?.contains("activation_nonzero_pcm_confirmed") == true)
        && lastTimeoutStep.isActivated && lastTimeoutStep.justConfirmed && (lastTimeoutStep.eventLog?.contains("nonzero_pcm_timeout") == true),
        "VoiceActivationTracker distinguishes all-zero DMA warmup from first non-zero PCM and handles timeout"
    )

    // 12. VoicePreRollBuffer (Layer 4): 150ms (2400-sample) rolling pre-roll & cold-start begin-padding + short-stop flush
    var preRollBuf = VoicePreRollBuffer()
    for _ in 0..<10 {
        preRollBuf.appendRolling(liveFrame, maxSamples: VoicePreRollBuffer.beginPaddingSamples)
    }
    let rollingCount = preRollBuf.rollingSampleCount
    let flushedRolling = preRollBuf.beginCapture(useRollingPreRoll: true)
    var coldBuf = VoicePreRollBuffer()
    _ = coldBuf.beginCapture(useRollingPreRoll: false)
    var coldEmitted = 0
    for _ in 0..<7 { // 7 * 320 = 2240 < 2400
        coldEmitted += coldBuf.appendCaptureSamples(liveFrame).count
    }
    let after8th = coldBuf.appendCaptureSamples(liveFrame).count // 8 * 320 = 2560 >= 2400 -> flushes 8 frames
    var shortBuf = VoicePreRollBuffer()
    _ = shortBuf.beginCapture(useRollingPreRoll: false)
    _ = shortBuf.appendCaptureSamples(liveFrame)
    let shortFlushed = shortBuf.flushOnStop()
    assertCheck(
        rollingCount == VoicePreRollBuffer.beginPaddingSamples
        && flushedRolling.count == 7
        && coldEmitted == 0
        && after8th == 8
        && shortFlushed.count == 1,
        "VoicePreRollBuffer enforces 150ms (2400-sample) rolling pre-roll, cold begin-padding, and lossless short-stop flush"
    )

    print(failures.isEmpty ? "SELF_TEST_ALL_PASSED" : "SELF_TEST_FAILED: \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}

if let benchFlagIdx = CommandLine.arguments.firstIndex(of: "--bench") {
    let benchPath: String
    if benchFlagIdx + 1 < CommandLine.arguments.count && !CommandLine.arguments[benchFlagIdx + 1].hasPrefix("--") {
        benchPath = CommandLine.arguments[benchFlagIdx + 1]
    } else {
        benchPath = FileManager.default.currentDirectoryPath + "/docs/benchmarks/baseline_500.tsv"
    }
    guard let content = try? String(contentsOfFile: benchPath, encoding: .utf8) else {
        print("BENCH_FAIL: cannot read dataset at \(benchPath)")
        exit(1)
    }

    let presetArg: DictionaryPreset = {
        if let idx = CommandLine.arguments.firstIndex(of: "--preset"), idx + 1 < CommandLine.arguments.count {
            return DictionaryPreset(rawValue: CommandLine.arguments[idx + 1]) ?? .wanxiang
        }
        return .wanxiang
    }()

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrimeTypeBench-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

    let sharedDir = RimeEngine.shared.sharedDataDir(for: presetArg)
    // Write isolated custom YAML with typo correction + grammar (if installed)
    let customURL = tmpRoot.appendingPathComponent("\(presetArg.schemaID).custom.yaml")
    var customLines = [
        "patch:",
        "  translator/enable_word_completion: true",
        "  speller/algebra/+:",
        "    - derive/([aoei])ng$/$1gn/",
        "    - derive/([aoei])ng$/$1mg/",
        "    - derive/ian$/ina/",
        "    - derive/uan$/una/",
        "    - derive/^([bpmfdtnlgkhjqxzcsw])/$1$1/"
    ]
    if presetArg == .wanxiang {
        customLines.append("  super_processor/enable_backspace_limit: false")
    }
    GrammarModelManager.shared.ensureSymlinks(in: tmpRoot.path)
    if let gramLang = GrammarModelManager.shared.activeGrammarLanguage(preferred: .lightweight, enabled: true) {
        customLines.append("  grammar/language: \(gramLang)")
        customLines.append("  translator/contextual_suggestions: true")
    }
    try? (customLines.joined(separator: "\n") + "\n").write(to: customURL, atomically: true, encoding: .utf8)

    RimeEngine.shared.startIsolated(preset: presetArg, sharedDataDir: sharedDir, userDataDir: tmpRoot.path)
    let session = RimeEngine.shared.createSession()

    var total = 0
    var top1Hits = 0
    var top5Hits = 0
    var groupStats: [String: (total: Int, top1: Int, top5: Int)] = [:]
    var keyLatenciesMs: [Double] = []

    for line in content.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let cols = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 4 else { continue }
        let group = cols[0]
        let pinyin = cols[2]
        let expected = cols[3]

        RimeEngine.shared.clearComposition(sessionId: session)
        for ch in pinyin {
            if let scalar = ch.unicodeScalars.first {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = RimeEngine.shared.processKey(sessionId: session, keyCode: Int32(scalar.value), mask: 0)
                if let ctx = RimeEngine.shared.getContext(sessionId: session), !ctx.preedit.isEmpty {
                    let syl = CandidatePipeline.syllableCount(from: ctx.preedit)
                    let limit = CandidatePipeline.adaptiveFetchLimit(syllableCount: syl, isExpanded: false)
                    _ = RimeEngine.shared.getAllCandidates(sessionId: session, limit: limit)
                }
                keyLatenciesMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
            }
        }
        let ctx = RimeEngine.shared.getContext(sessionId: session)
        let syl = CandidatePipeline.syllableCount(from: ctx?.preedit ?? pinyin)
        let limit = CandidatePipeline.adaptiveFetchLimit(syllableCount: syl, isExpanded: false)
        let raw = RimeEngine.shared.getAllCandidates(sessionId: session, limit: limit)
        let presented = CandidatePipeline.buildCandidates(rimeCandidates: raw, directPrefixItems: [], syllableCount: syl)

        total += 1
        let isTop1 = presented.first?.text == expected
        let isTop5 = presented.prefix(5).contains(where: { $0.text == expected })
        if isTop1 { top1Hits += 1 }
        if isTop5 { top5Hits += 1 }
        var gs = groupStats[group] ?? (0, 0, 0)
        gs.total += 1
        if isTop1 { gs.top1 += 1 }
        if isTop5 { gs.top5 += 1 }
        groupStats[group] = gs
    }

    RimeEngine.shared.destroySession(session)
    RimeEngine.shared.shutdown()

    let sortedLat = keyLatenciesMs.sorted()
    let p50 = sortedLat.isEmpty ? 0 : sortedLat[min(sortedLat.count - 1, Int(Double(sortedLat.count) * 0.50))]
    let p99 = sortedLat.isEmpty ? 0 : sortedLat[min(sortedLat.count - 1, Int(Double(sortedLat.count) * 0.99))]
    print(String(format: "BENCH_SUMMARY preset=%@ total=%d top1=%.1f%% (%d/%d) top5=%.1f%% (%d/%d) keystroke_p50=%.2fms keystroke_p99=%.2fms",
                 presetArg.rawValue,
                 total,
                 total > 0 ? Double(top1Hits) * 100.0 / Double(total) : 0, top1Hits, total,
                 total > 0 ? Double(top5Hits) * 100.0 / Double(total) : 0, top5Hits, total,
                 p50, p99))
    for group in groupStats.keys.sorted() {
        let gs = groupStats[group]!
        print(String(format: "  group=%-8@ total=%2d top1=%5.1f%% (%d/%d) top5=%5.1f%% (%d/%d)",
                     group as NSString, gs.total,
                     Double(gs.top1) * 100.0 / Double(gs.total), gs.top1, gs.total,
                     Double(gs.top5) * 100.0 / Double(gs.total), gs.top5, gs.total))
    }
    exit(0)
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
        LocalNeuralReranker.shared.unloadNow()
        UserRankingEngine.shared.flushToDisk()
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
    if let expandableCls = NSClassFromString("IMKUIExpandableCandidateWindowController") {
        let sel = NSSelectorFromString("shouldShowSortingBar")
        if let method = class_getInstanceMethod(expandableCls, sel) {
            let block: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
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
let launchOnboarding = CommandLine.arguments.contains("--onboarding")
VoiceInputManager.shared.startMonitors()
TranslateManager.shared.startMonitors()
DispatchQueue.main.asyncAfter(deadline: .now() + (launchOnboarding ? 0.2 : 0.8)) {
    if launchOnboarding {
        OnboardingWindowController.shared.show(openSettingsOnFinish: true)
    } else {
        OnboardingWindowController.shared.showIfNeeded()
    }
}
if InputSettings.shared.autoCheckAppUpdates {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        AppUpdateManager.shared.checkForUpdates(silent: true)
    }
}
app.run()
