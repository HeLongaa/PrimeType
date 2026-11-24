# PrimeType 输入体验优化方案（v2 · 工程落地版）

> **目标**：在 PrimeType 现有架构上达到 **微信输入法 80%–90% 的综合打字体验**（快、稳、准、懂语境、越用越顺手、低内存不反弹）。
> **定位**：基于初版《PrimeType 输入体验优化方案》重构，保留其全部核心体验理念与量化验收标准，修正其中与 `PrimeType`（Swift/IMKit + `librime` + 三套词库预设）不匹配的实现细节，并补齐通往“80%–90% 微信输入法体验”不可或缺的**语法模型（`.gram`）与可选端侧语境重排**两块核心拼图。
> **当前基线**：`PrimeType v1.0.11`（已完成单 Rime Session 复用、剪贴板缩略图瘦身、IMK 协议上屏修复，常态物理内存约 `45–60 MB`）。

---

## 0. 为什么微信输入法“好用”，以及 PrimeType 现在的差距在哪

把微信输入法的“好用”拆解到可工程化的 5 个维度，对照 PrimeType 现状：

| 体验维度 | 微信输入法为什么强 | PrimeType (`v1.0.11`) 现状 | 差距来源 |
| :--- | :--- | :--- | :--- |
| **1. 整句准确率** | 大规模统计语言模型 + 神经网络整句打分 | 仅靠词典静态词频 + `userdb`（虽已打包 `librime-octagram.dylib`，但**缺 `.gram` 模型文件**） | **最大差距（占 40%）** |
| **2. 跨句语境理解** | 记住刚发出的上下文，理解话题关联（如“去北京出差 → 订机票”） | 仅在当前行做中英文空格与编号跟踪，无跨消息语境重排 | **第二大差距（占 25%）** |
| **3. 越用越准与纠错** | 选中加权、删字强惩罚、邻键/换位/漏键容错 | 仅有 Rime 基础词频记忆（万象自带部分回滚，雾凇/薄荷无）；缺统一负反馈和一键删错词 | **第三大差距（占 20%）** |
| **4. 手感与帧率稳定** | 极速同步首屏 + 异步精排不顶掉第 1 位 + 严格 16ms 帧预算 | 纯同步单帧 10–15ms，但长句仍固定拉 36 候选、缺少实时 P99 打点与异步护栏 | **第四大差距（占 10%）** |
| **5. 细节与隐私** | 候选去重信息密度高、密码框/敏感剪贴板零学习 | `uniquifier` 仅做完全相同去重；剪贴板尚未过滤 1Password 等敏感类型 | **收尾细节（占 5%）** |

**核心结论**：
单靠写几个 Lua filter 和 Swift 防抖，只能做到微信输入法 60%–65% 的体验；**必须用「三层混合管线」把统计语法（Tier 0）、个人反馈（Tier 1）、端侧语义重排（Tier 2）打通，才能真正摸到 80%–90%**，而且全程不依赖云端、不破坏 PrimeType 轻量低内存的优势。

---

## 1. 总体架构：三层混合候选管线

```text
按键到来 (InputTypeController.handle)
  │
  ├── [打点] LatencyProbe.beginKeystroke()
  │
  ├── Tier 0 · 同步极速底座（预算 ≤ 8ms，100% 击键触发，零 GPU）
  │     ├── RimeEngine (librime + librime-octagram.dylib + .gram 语法模型)
  │     ├── Rime 原生 speller/algebra 错键容错（邻键/换位/漏键/多键，降权不抢首位）
  │     └── Swift 层自适应 fetchLimit（短词 36 / 中句 24 / 长句 16；展开网格按需拉 160）
  │
  ├── Tier 1 · 同步个性化与去重层（预算 ≤ 1.5ms，纯内存哈希，零磁盘 I/O）
  │     ├── CandidateDeduplicator（繁简/全半角/英文大小写语义去重，保留原始 Rime 下标映射）
  │     ├── UserRankingEngine（选中正反馈 + 删字/改选强负反馈 + 30d/14d 指数衰减）
  │     └── EmitHistory 实体复现轻加权（最近 5 条 / 80 字，专有名词短时提权）
  │     └── 立即渲染候选栏（P99 ≤ 16ms，零卡顿）
  │
  └── Tier 2 · 异步语境精排层（可选下载，仅 ≥ 6 音节整句 + 有前文时触发）
        ├── QueryCoordinator（generation token 可中断，新击键立即作废旧任务，200ms 超时丢弃）
        ├── LocalNeuralReranker（llama.cpp Metal / mlx-swift + Qwen2.5-0.5B-4bit）
        │     └── 前文 C 的 KV Cache 复用 + Top-6~8 整句并行 Teacher-Forcing Log-Prob 打分
        │     └── 与 Rime 排名做 RRF 融合（不依赖 librime 内部不可见的原始分数）
        └── CandidatePresenter（首位保护：150ms 锁定窗 + 抢占阈值 +0.15，超时仅插 index 1）
```

### 关键架构红线（修正原方案中的 4 个工程坑）

1. **Swift 层重排必须维护「展示下标 ↔ Rime 原始下标」双向映射**
   - 原因：如果只在 UI 改顺序而不把选词映射回 Rime 原始候选索引，会导致 `prime_shared.userdb` 记错词频、长句分段上屏错位。
   - 规则：每个展示候选包装为 `PresentedCandidate(text, originalRimeIndex, isWholeSentence, source)`；按空格/数字选词时，始终以 `originalRimeIndex` 调用 `RimeEngine.shared.selectCandidate(sessionId:index:)`；且 **Tier 1 / Tier 2 只在“完整覆盖整串拼音的整句候选”内部重排**，不把半截词与整句混排。
2. **禁止在 Lua 里全量遍历 `input:iter()` + `table.sort`，禁止每次击键读写文件**
   - 原方案 §2.4 / §2.6 让 Lua 读磁盘文件并对整条 `input:iter()` 流排序，会把单键延迟拉爆到 40–100ms。
   - 修正：**个性化打分（`UserRankingEngine`）、跨消息历史（`EmitHistory`）、语义去重全部放在 Swift 内存层处理**（只处理 Rime 拉出的 Top-16~36 候选，耗时 `< 0.5ms`，且雾凇/万象/薄荷三套词库 100% 通用，不侵入任何词库 Lua 脚本）。
3. **候选预算自适应放在 Swift 层 `fetchLimit`，而非 Lua 猜音节**
   - `RimeEngine.getAllCandidates(sessionId:limit:)` 本身是惰性迭代拉取的，直接在 [InputTypeController.swift](/Users/lumocore/Git/InputType/Sources/InputType/InputTypeController.swift) 按 `preedit` 音节数动态收紧 `fetchLimit` 即可立竿见影降长句耗时，且展开候选网格（按下箭头 / Tab）时仍按需拉取 160 条。
4. **本地 AI 模型作为可选下载插件，严格守住内存红线**
   - 不打进 72 MB 主安装包；用户在「设置 → 高级 → 引擎」按需下载到 `~/Library/InputType/models/`（默认关闭）。
   - 懒加载 + **空闲 5 分钟自动卸载**释放显存与 RAM，未开启或空闲时物理内存稳在 `45–60 MB`。

---

## 2. 完整优化清单总览

| # | 模块 | 所属层 | 文件落点 | 预期收益 | 风险 |
| :---: | :--- | :---: | :--- | :---: | :---: |
| **1** | 离线评测基准 + `LatencyProbe` 实时打点 | 基建 | `Rime/LatencyProbe.swift`, `main.swift` (`--bench`) | **量化底盘** | 无 |
| **2** | 激活 `librime-octagram` + `.gram` 语法模型 | Tier 0 | `App/GrammarModelManager.swift`, `InputSettings.swift`, `RimeEngine.swift` | **极高**（整句首选 +8~15%） | 低 |
| **3** | Swift 层自适应 `fetchLimit` + 候选语义去重 | Tier 0/1 | `Rime/CandidatePipeline.swift`, `InputTypeController.swift` | **高**（长句提速 + 信息密度） | 无 |
| **4** | `UserRankingEngine` 反馈闭环 + `Shift+Delete` 删词 | Tier 1 | `Rime/UserRankingEngine.swift`, `InputTypeController.swift` | **极高**（越用越准 + 错词秒沉底） | 低 |
| **5** | `EmitHistory` 跨发送上下文缓冲 | Tier 1 | `Rime/EmitHistory.swift`, `InputTypeController.swift` | **中高**（专词复现 + 供 Tier 2 前文） | 无 |
| **6** | Rime 原生 4 类错键容错（`speller/algebra`） | Tier 0 | `InputSettings.swift` (`custom.yaml`) | **中**（快打容错） | 中 |
| **7** | 安全输入与剪贴板敏感信息零学习 | 安全 | `InputTypeController.swift`, `ClipboardManager.swift` | **必须** | 无 |
| **8** | `QueryCoordinator`（可中断）+ `CandidatePresenter`（首位保护） | Tier 2 调度 | `Rime/QueryCoordinator.swift`, `Rime/CandidatePresenter.swift` | **极高**（异步零跳变底座） | 无 |
| **9** | 端侧 `Qwen2.5-0.5B` Teacher-Forcing 语境重排（可选） | Tier 2 引擎 | `Rime/LocalNeuralReranker.swift` + 设置页下载管理 | **极高**（长句跨句语境质变） | 中 |

---

## 3. 核心模块详细设计

### 3.1 量化基线与实时打点（`LatencyProbe` + `--bench`）

**目标**：让每一项改动都有客观数据对比，不靠“感觉”。

1. **在线实时打点（`LatencyProbe`）**
   - 内存固定容量环形缓冲（最近 2000 次击键，占用 `< 64 KB`，零磁盘写入）。
   - 分段记录：`rimeProcessMs`、`candidateFetchMs`、`tier1RankMs`、`uiRenderMs`、`syncTotalMs`、`asyncTotalMs`、`top1FlipCount`、`asyncDroppedCount`。
   - 暴露在「设置 → 高级 → 诊断」中实时展示 P50 / P95 / P99、超 16ms 占比与一键导出。
2. **离线评测 CLI（`PrimeType --bench <dataset.tsv>`）**
   - 复用现有 [main.swift](/Users/lumocore/Git/InputType/Sources/InputType/main.swift) 的 `--smoke-test` 入口模式，支持喂入 `前文\t拼音\t期望整句` 的 500 句 TSV 测试集。
   - 自动输出 4 个分组（日常短句 / 长句整句 / 简拼混拼 / 中英混合+错键）的 **Top-1 命中率、Top-5 命中率、逐键 P50/P99、RSS/Footprint**。

---

### 3.2 激活 `librime-octagram` + `.gram` 语法模型（Tier 0 核心）

**现状**：`PrimeType.app/Contents/Frameworks/rime-plugins/librime-octagram.dylib` **已编译打包且启动时已加载**，[wanxiang.schema.yaml:116-123](/Users/lumocore/Git/InputType/Resources/Dictionaries/wanxiang/wanxiang.schema.yaml:116-123) 也已声明 `grammar: wanxiang-lts-zh-hans`，只缺 `.gram` 文件与三套预设的统一配置。

**落点**：
- `Sources/InputType/App/GrammarModelManager.swift`（或集成进 [UpdateManager.swift](/Users/lumocore/Git/InputType/Sources/InputType/App/UpdateManager.swift)）
- [InputSettings.swift](/Users/lumocore/Git/InputType/Sources/InputType/App/InputSettings.swift)（`writeRimeCustomYAML`）

**实现方案**：
1. **模型分发**：
   - 将轻量高质语法模型（如 `wanxiang-lts-zh-hans.gram`，约 15–30 MB，`mmap` 只读映射，几乎零 Dirty 物理内存）支持**随词库共享一份软链接**到三个 profile 目录（`~/Library/InputType/models/grammar.gram` → 软链至 `wanxiang` / `rime_ice` / `oh_my_rime`，避免三份重复占磁盘）。
   - 提供「内置默认启用」或「设置 → 词库一键下载/更新」两种打包策略（推荐直接内嵌一份轻量 `.gram` 或首次联网静默补齐，让用户开箱即享长句提升）。
2. **三套预设统一挂载**：
   - 在 `writeRimeCustomYAML(for:)` 中为 `rime_ice`、`oh_my_rime`、`wanxiang` 统一补齐 `grammar` 参数与 `translator/contextual_suggestions: true`、`translator/max_homophones: 7`。
   - **关键修复**：在 [RimeEngine.swift](/Users/lumocore/Git/InputType/Sources/InputType/Rime/RimeEngine.swift) 中增加 `.custom.yaml` mtime 校验——当 `.custom.yaml` 比 `build/<schema>.schema.yaml` 更新时自动触发轻量重新部署，确保升级用户无需手动点“重新部署”就能立即生效。

**量化验收**：
- 500 句测试集长句整句 Top-1 命中率提升 **≥ 8%**；
- 单键 `rimeProcessMs` 增量 **≤ 1.0 ms**，Dirty Footprint 增量 **≤ 2 MB**。

---

### 3.3 Swift 层自适应候选预算 + 语义去重与多样性（Tier 0/1）

**落点**：`Sources/InputType/Rime/CandidatePipeline.swift`、[InputTypeController.swift](/Users/lumocore/Git/InputType/Sources/InputType/InputTypeController.swift)

**1. 自适应 `fetchLimit`（替代原方案 Lua 截断）**
- 统计 `context.preedit` 经空格/撇号切分后的真实音节数 `syllableCount`（Rime 已经切好，比元音猜测准确得多）：

| 音节数 | 收起态 `fetchLimit` | 展开网格态 `fetchLimit` |
| :---: | :---: | :---: |
| 1 ~ 2 | 36 | 160 |
| 3 ~ 5 | 28 | 160 |
| 6 ~ 10 | 18 | 120 |
| 11+ | 12 | 80 |

- 始终保留 Rime 返回的首选与首音节单字（Rime 原生结果已自带），不会漏单字。

**2. 候选语义去重（`CandidateDeduplicator`）**
- 仅在拉取出的 Top-N（12–36 条）上做纯内存 `O(N)` 扫描（`< 0.1ms`）：
  - 归一化判重 Key：去首尾空白 + 全角转半角 + 纯英文 ASCII 小写折叠 +（简体模式下）简繁归一；
  - 输出保留原始文本与 `originalRimeIndex`，遇到重复项跳过并从后续候选补齐展示位；
  - 若是用户手动置顶的自定义常用语，优先级高于去重折叠。

**量化验收**：
- 15 音节长句与 2 音节短词的同步耗时差 **≤ 4 ms**；
- 前 10 候选中无重复语义变体（如 `WeChat` / `wechat`、全半角重复）。

---

### 3.4 个人反馈闭环 + `Shift+Delete` 删错词（`UserRankingEngine`）

**问题**：只靠 Rime `userdb` 存在两个痛点——① 误选一次后会长期霸榜；② 跨雾凇/万象/薄荷词库行为不统一，缺少“上屏后立即删掉”的强负反馈。

**落点**：`Sources/InputType/Rime/UserRankingEngine.swift`、[InputTypeController.swift](/Users/lumocore/Git/InputType/Sources/InputType/InputTypeController.swift)

**核心设计**：
1. **数据结构（按 `(normalizedPinyin, word)` 联合建索引，而非仅按 `word`！）**
   - 修正原方案关键漏洞：如果只按 `word` 存分，用户在 `zhidao` 误选并删掉「直道」，会导致打 `zhidao` 其他语境或子词全被连坐；按 `(code, word)` + 全局 `word` 衰减双维度记录更精准。
   ```swift
   struct CandidateFeedback: Codable {
       var score: Double          // 当前累计分
       var selectCount: Int
       var deleteCount: Int
       var lastUpdated: TimeInterval
       var isSelfMade: Bool
   }
   ```
2. **4 类行为信号与精确判定**

| 行为信号 | 触发判定条件 | 权重变化 |
| :--- | :--- | :---: |
| **正常选中** | 选中第 1 位 / 第 2~N 位 | `+1.0` / `+0.6`（同屏排在被选项之前的 Top-3 轻度 `-0.25`） |
| **上屏后立即删除** | 上屏后 **3 秒内**未输入其他字，连续按 `Backspace` 删除 ≥ 刚上屏词长的 50% | **`-5.0`**（强负反馈） |
| **删后立刻改选** | 触发“上屏后删除”后 **5 秒内**对相同拼音改选了另一候选 B | 原词 **`-8.0`**，新词 B **`+2.0`** |
| **`Shift + Delete` 主动移除** | 组词态高亮某候选按 `Shift+Backspace` / `Shift+Delete` | 永久拉黑该 `(code, word)`（`-50.0`）并调用 Rime 原生删除用户词条 |

3. **时间衰减与持久化**
   - 读取时按半衰期衰减：`effective = score * pow(0.5, days / halfLife)`（普通词 `30` 天，自造词/未满 3 次词 `14` 天）；衰减后 `|effective| < 0.03` 自动清理。
   - 内存哈希表直接读取（`< 0.1ms`），持久化采用 **5 秒防抖异步写盘**（`~/Library/InputType/user_ranking.json`），零击键 I/O 阻塞。
4. **安全重排边界 & 万象协同**
   - 仅在 Rime 返回的**前 10 个同长度/整句候选**内融合重排（绝不把单字顶到整句前面）；
   - 使用「排名先验 + 反馈分」混合，保证必须有明确正/负分差才调整顺位；
   - 使用万象词库时自动降低重叠信号的重复扣分，防止和 `context_reorder.lua` 叠加过冲。

**量化验收**：
- 同一误选词连续“误选 → 立刻删掉” 3 次后，10 天内不再进入 Top-3；
- `Shift+Delete` 后该误学词立即消失且不再复现；
- 内存占用 `< 2 MB`（上限保留 20,000 条高频记录 LRU 淘汰）。

---

### 3.5 跨发送历史上下文（`EmitHistory`）

**落点**：`Sources/InputType/Rime/EmitHistory.swift`、[InputTypeController.swift](/Users/lumocore/Git/InputType/Sources/InputType/InputTypeController.swift)

**设计修正**：
- 保持纯内存环形缓冲（**不写临时文件给 Lua**），按 `bundleID` 分桶隔离（防止你在终端敲的代码污染微信聊天的语境，或把 ChatGPT 的对话带到 Spotlight）。
- 每桶保留最近 **5 条已提交文本 / 最多 80 字**，超 10 分钟自动过期。
- **双用途**：
  1. **给 Tier 1（0ms）**：提取上文中的 2–6 字高频词/专有名词（如刚提过的人名、产品名、项目名），若当前候选完全命中则给温和提权（`+0.8`，约等效提升 1–2 名），解决“刚打过一次的生僻专词下一句立刻进首选”。
  2. **给 Tier 2（本地小模型）**：作为真实语义前文 `C` 拼入 Transformer Prefill，真正实现 **「明天去北京出差」→ 下一句 `dingjipiao` → 「订机票」** 这种跨句语义推理。

---

### 3.6 4 类错键容错（Rime 原生 `speller/algebra`）+ 模糊音护栏

**设计修正**：
- **不用 Lua 暴力枚举 4 类错键**，改用 Rime 原生编译期 `speller/algebra` 推导 + 惩罚权重，性能快 100 倍且零额外运行时复杂度：
  1. **换位错键**（高频）：`iu/ui` 之外补常见快打换位（如 `gn→ng`、`mg→ng`、`ou→uo` 视韵母表、`ie→ei`、`ni/in` 受控规则）；
  2. **邻键/多键/漏键**（受控白名单）：常见高频错拼（如 `zhognguo` 类型的双写/漏写 `ng`/`en`/`an` 规则，以及双字母误连击去重 `([a-z])\1 → $1` 惩罚推导，例如 `nihhao → nihao`）；
  3. **硬约束**：所有纠错规则均通过 `derive` + 较低权重注入（或仅在精确切分无整句命中时回退触发），**绝对保证精确拼写永远排在纠错候选之前**。
- **模糊音**：沿用现有 [InputSettings.swift:158](/Users/lumocore/Git/InputType/Sources/InputType/App/InputSettings.swift:158) 逐项开关，并在设置 UI 增加提示（“建议仅勾选个人习惯的 1–2 项，全开会增加候选数”）。

---

### 3.7 异步调度护栏 + 可选端侧 `Qwen2.5-0.5B` 语境精排（Tier 2，冲刺 85%–90%）

这是把原方案 §2.1（首位保护）、§2.2（可中断）、§2.3（16ms 同步/异步双轨）真正落地并发挥巨大价值的地方。

#### 1. 触发门槛（省电、零发热、不拖累短词）
仅当同时满足以下条件时才派发异步精排：
- 用户在设置中开启并下载了本地语义模型；
- 当前拼音 **≥ 6 个音节**（长句）或 **前文 `EmitHistory` 非空且存在明显同音歧义**；
- 距上次击键已短暂停顿 **45 ms**（防抖：高速连击时不浪费 GPU 算力，一旦停顿准备选词瞬间起算）。

#### 2. `QueryCoordinator`（可中断调度）
- 维护单调递增 `generation: UInt64` 与唯一 `inFlightTask`；
- 新击键到达瞬间 `generation &+= 1` 并取消旧任务；
- 推理返回后严格校验 `token == generation && currentPreedit == snapshotPreedit`，过期或超过 **200 ms** 直接丢弃。

#### 3. `LocalNeuralReranker`（端侧 Teacher-Forcing 打分）
- **运行时**：优先 **`llama.cpp`（Metal 静态库）** 或 **`mlx-swift`**（不选 CoreML，避免静态 shape 与 KV Cache 共享困难）。
- **模型**：`Qwen2.5-0.5B-Instruct`（4-bit GGUF/MLX，体积 ~350 MB，按需下载到 `~/Library/InputType/models/`）。
- **算分机制**：
  1. 缓存前文 `C`（来自 `EmitHistory`）的 **KV Cache**；
  2. 只取 Rime 召回的 **Top-6~8 完整整句候选**做单次 Batch Prefill（不自回归生成！），计算每个候选词部分的长度归一化平均条件对数概率 $S_{\text{llm}}$；
  3. **混合融合（解决 `librime` 不暴露 `S_rime` 的问题）**：用 **RRF（倒数排名先验）** 替代缺失的 $S_{\text{rime}}$：
     $$\text{FinalScore}(i) = w_1 \cdot \frac{1}{k + \text{rank}_{\text{rime}}(i)} + w_2 \cdot \text{Norm}(S_{\text{llm}}(i)) + w_3 \cdot \text{Norm}(S_{\text{user}}(i))$$
- **生命周期与内存护栏**：
  - 懒加载（首次触发长句时加载）；
  - **空闲 5 分钟自动卸载**（释放全部显存与内存，并调用 `malloc_zone_pressure_relief`）；
  - 优先放进独立 **XPC Helper**（或异常保护隔离），确保模型/Metal 异常绝不带崩输入法主进程。

#### 4. `CandidatePresenter`（首位保护防跳变）
- 同步路径（Tier 0 + Tier 1）在 **≤ 8–12 ms** 内立刻上屏渲染，不等待模型；
- 异步结果到达时执行双保险规则：
  1. **时间锁**：若距离上次击键已超过 **150 ms**（用户可能正准备按空格确认），**永不修改 `index 0`**，只将高分新候选插入 **`index 1`**（并保证原 `index 0` 纹丝不动）；
  2. **置信度锁**：即使在 150 ms 窗口内，也只有当新候选得分领先原第 1 名超过 **`+0.15`** 时才允许替换首位；整个组词周期内首位因异步结果最多只允许变动 **1 次**。

**量化验收**：
- 长句（8–15 音节）和跨句语境测试集 Top-1 命中率再提升 **≥ 8–12%**；
- 端到端同步击键 P99 **≤ 16 ms**；
- 模拟 300ms 慢推理下连续快打，**0 次因首位跳变导致的误上屏**；
- 停打 5 分钟后进程 Footprint 自动回落至 **≤ 65 MB**。

---

### 3.8 安全输入与隐私保护（硬性底线）

1. **安全输入框（密码框）**：
   - 在记录 `UserRankingEngine`、`EmitHistory` 前双重检查 `IsSecureEventInputEnabled()`（Carbon HIToolbox API）及客户端类型；一旦处于安全输入态，**不记录、不读取、不打日志**。
2. **剪贴板敏感信息过滤（[ClipboardManager.swift](/Users/lumocore/Git/InputType/Sources/InputType/App/ClipboardManager.swift)）**：
   - 监听 `NSPasteboard.general` 时，若 `pb.types` 包含以下标准隐私标记之一，直接跳过不入历史：
     - `org.nspasteboard.ConcealedType`（1Password / Bitwarden / 钥匙串密码）
     - `org.nspasteboard.TransientType`（临时剪贴板内容）
     - `org.nspasteboard.AutoGeneratedType`
     - `com.agilebits.onepassword`

---

## 4. 分阶段实施路线与里程碑

每个阶段结束都必须用 **500 句评测集 + 同机对照（改动前 PrimeType / 微信输入法 / 系统拼音）** 验收达标后，再进入下一阶段：

| 阶段 | 核心交付 | 预计工期 | 体验到达水位（相对微信输入法） | 关键验收指标 |
| :--- | :--- | :---: | :---: | :--- |
| **Phase 0 · 基线与打点** | `LatencyProbe` 环形打点 + 设置诊断展示 + `PrimeType --bench` 离线评测脚本 + 500 句基准集 | 2 天 | 建立客观基线 | 能一键跑出 Top-1 / Top-5 / P50 / P99 报告 |
| **Phase 1 · 语法底座与提速** | 激活 `librime-octagram` + `.gram` 语法模型（三套预设共享）+ Swift 自适应 `fetchLimit` + 候选语义去重 + 密码/敏感剪贴板过滤 | 4 天 | **~70%** | 长句 Top-1 **+8%~15%**；15 音节与 2 音节同步耗时差 ≤ 4ms；内存稳在 ≤ 60 MB |
| **Phase 2 · 个性化与容错** | `UserRankingEngine`（选中/删字/改选/衰减 + 原始索引映射）+ `Shift+Delete` 删错词 + `EmitHistory` 分 App 上下文 + Rime 原生 4 类错键容错 | 1 周 | **~78%–82%** | 误选词连删 3 次后 10 天不进 Top-3；高频错键纠错不挤占正确首选；P99 ≤ 16ms |
| **Phase 3 · 端侧 AI 语境精排** | `QueryCoordinator` 可中断调度 + `CandidatePresenter` 150ms 首位保护 + 可选下载 `Qwen2.5-0.5B-4bit` Teacher-Forcing 重排（KV Cache 复用 + 5 分钟空闲卸载） | 1.5–2 周 | **~85%–90%** | 跨句语义测试（北京出差→订机票）进 Top-3；首位误跳变 = 0；空闲卸载后回落 ≤ 65 MB |
| **Phase 4 · 回归与调参** | 500 句全量对比微信输入法 / 系统拼音，微调融合权重与阈值，封版发布 | 3 天 | **稳定 85%–90%** | 总首选命中率 ≥ 92%，Top-5 ≥ 97%，P99 ≤ 16ms，误上屏率 ≤ 0.5% |

---

## 5. 参数速查表

```text
[响应与调度]
  同步路径预算               ≤ 8 ms（Tier 0 + Tier 1）
  端到端同步 P50 / P99       ≤ 10 ms / ≤ 16 ms
  异步触发防抖               45 ms（且 ≥ 6 音节或有上下文歧义）
  异步结果超时丢弃           200 ms
  首位保护时间窗             150 ms（超时永不碰 index 0，仅插 index 1）
  首位抢占领先阈值           +0.15（且单次组词最多跳变 1 次）

[候选预算（Swift 层 fetchLimit）]
  1–2 音节                   36（展开 160）
  3–5 音节                   28（展开 160）
  6–10 音节                  18（展开 120）
  11+ 音节                   12（展开 80）

[个人反馈闭环（UserRankingEngine）]
  选中加分                   首选 +1.0 / 非首选 +0.6（跳过的前位 -0.25）
  上屏后 3s 内删字惩罚       -5.0
  删后 5s 内改选惩罚         原词 -8.0 / 新词 +2.0
  Shift+Delete 主动移除      -50.0 + 同步删 userdb 词条
  半衰期                     普通词 30 天 / 自造词 14 天
  淘汰阈值                   |effective| < 0.03（且 LRU 上限 20,000 条）

[跨消息上下文（EmitHistory）]
  隔离维度                   按宿主 App bundleID 分桶
  保留窗口                   最近 5 条 / 最多 80 字 / 10 分钟过期
  Tier 1 实体复现加权        +0.8（仅 2–6 字词）

[端侧 AI 模型（Tier 2 可选）]
  默认状态                   关闭（设置页按需下载 ~350 MB）
  精排候选池                 Top-6 ~ Top-8 完整整句候选
  空闲自动卸载               5 分钟无长句触发即卸载并归还内存页
  基础内存红线（未开/空闲）  Footprint ≤ 65 MB
```
