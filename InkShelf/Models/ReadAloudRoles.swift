import Foundation

enum ReadAloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case localZipVoice
    case mimo
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localZipVoice: "本地 ZipVoice"
        case .mimo: "小米 MiMo"
        case .openAICompatible: "OpenAI 兼容"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .localZipVoice: ""
        case .mimo: "https://api.xiaomimimo.com/v1"
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .localZipVoice: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"
        case .mimo: "mimo-v2.5-tts"
        case .openAICompatible: "gpt-4o-mini-tts"
        }
    }
}

enum ReadAloudRoleDetectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case localRules
    case ai

    var id: String { rawValue }
    var title: String {
        switch self {
        case .localRules: "本地增强解析"
        case .ai: "AI 智能分析（本地兜底）"
        }
    }
}

enum ReadAloudAIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case mimo
    case openAICompatible

    var id: String { rawValue }
    var title: String { self == .mimo ? "小米 MiMo" : "OpenAI 兼容" }
    var defaultBaseURL: String {
        self == .mimo ? "https://api.xiaomimimo.com/v1" : "https://api.openai.com/v1"
    }
    var defaultModel: String { self == .mimo ? "mimo-v2-flash" : "gpt-4.1-mini" }
}

enum ReadAloudVoiceSelectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case roleBased

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动选择"
        case .roleBased: "逐角色指定"
        }
    }
}

/// Persisted engine, role-detection, voice-selection and playback preferences.
struct ReadAloudSettings: Codable, Equatable, Sendable {
    var provider = ReadAloudProvider.mimo
    var baseURL = ReadAloudProvider.mimo.defaultBaseURL
    var model = ReadAloudProvider.mimo.defaultModel
    var rateMultiplier = 0.9
    var allowsTextUpload = false
    var roleDetectionMode = ReadAloudRoleDetectionMode.ai
    var analysisProvider = ReadAloudAIProvider.mimo
    var analysisBaseURL = ReadAloudAIProvider.mimo.defaultBaseURL
    var analysisModel = ReadAloudAIProvider.mimo.defaultModel
    var voiceSelectionMode = ReadAloudVoiceSelectionMode.automatic
    var narratorVoiceIdentifier = ""
    var thirdPersonVoiceIdentifier = ""
    var characterVoiceIdentifier = ""
    var characterVoiceIdentifiers: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, model, rateMultiplier, allowsTextUpload
        case roleDetectionMode, analysisProvider, analysisBaseURL, analysisModel
        case voiceSelectionMode, narratorVoiceIdentifier
        case thirdPersonVoiceIdentifier, characterVoiceIdentifier, characterVoiceIdentifiers
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case selectedVoiceIdentifier
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(ReadAloudProvider.self, forKey: .provider) ?? .mimo
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? provider.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? provider.defaultModel
        rateMultiplier = try container.decodeIfPresent(Double.self, forKey: .rateMultiplier) ?? 0.9
        allowsTextUpload = try container.decodeIfPresent(Bool.self, forKey: .allowsTextUpload) ?? false
        let roleModeRaw = try container.decodeIfPresent(String.self, forKey: .roleDetectionMode)
        roleDetectionMode = roleModeRaw.flatMap(ReadAloudRoleDetectionMode.init(rawValue:))
            ?? .ai
        analysisProvider = try container.decodeIfPresent(ReadAloudAIProvider.self, forKey: .analysisProvider) ?? .mimo
        analysisBaseURL = try container.decodeIfPresent(String.self, forKey: .analysisBaseURL)
            ?? analysisProvider.defaultBaseURL
        analysisModel = try container.decodeIfPresent(String.self, forKey: .analysisModel)
            ?? analysisProvider.defaultModel
        let voiceModeRaw = try container.decodeIfPresent(String.self, forKey: .voiceSelectionMode)
        voiceSelectionMode = ReadAloudVoiceSelectionMode(rawValue: voiceModeRaw ?? "")
            ?? (voiceModeRaw == "single" ? .roleBased : .automatic)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacySelectedVoice = try legacyContainer.decodeIfPresent(
            String.self,
            forKey: .selectedVoiceIdentifier
        ) ?? ""
        narratorVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .narratorVoiceIdentifier) ?? ""
        thirdPersonVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .thirdPersonVoiceIdentifier) ?? ""
        characterVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .characterVoiceIdentifier) ?? ""
        characterVoiceIdentifiers = try container.decodeIfPresent(
            [String: String].self,
            forKey: .characterVoiceIdentifiers
        ) ?? [:]
        if voiceModeRaw == "single", !legacySelectedVoice.isEmpty {
            if narratorVoiceIdentifier.isEmpty { narratorVoiceIdentifier = legacySelectedVoice }
            if thirdPersonVoiceIdentifier.isEmpty { thirdPersonVoiceIdentifier = legacySelectedVoice }
            if characterVoiceIdentifier.isEmpty { characterVoiceIdentifier = legacySelectedVoice }
        }
    }

    var normalized: ReadAloudSettings {
        var copy = self
        copy.baseURL = copy.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.analysisBaseURL = copy.analysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.analysisModel = copy.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.rateMultiplier = min(1.2, max(0.7, copy.rateMultiplier))
        return copy
    }
}

enum ReadAloudSpeaker: Equatable, Sendable {
    case narrator
    case thirdPersonNarrator
    case character(String)
    case unknownDialogue(turn: Int)

    var isDialogue: Bool {
        switch self {
        case .narrator, .thirdPersonNarrator: return false
        case .character, .unknownDialogue: return true
        }
    }
}

enum NovelCharacterGender: String, Codable, Equatable, Sendable {
    case female
    case male
    case unspecified

    var title: String {
        switch self {
        case .female: "女声"
        case .male: "男声"
        case .unspecified: "未定"
        }
    }
}

struct ReadAloudRolePlan: Equatable, Sendable {
    let speakersByPage: [ReaderPageLocation: [ReadAloudSpeaker]]

    static let empty = ReadAloudRolePlan(speakersByPage: [:])

    func speakers(for location: ReaderPageLocation) -> [ReadAloudSpeaker]? {
        speakersByPage[location]
    }
}

struct ReadAloudLocalRoleAnalysis: Equatable, Sendable {
    let plan: ReadAloudRolePlan
    let characterGenders: [String: NovelCharacterGender]
}

/// A deterministic, local-first dialogue attribution pass. It deliberately
/// leaves ambiguous dialogue unnamed instead of inventing character identities.
struct ReadAloudRoleAnalyzer {
    private static let attributionExpression = try? NSRegularExpression(
        pattern: #"([\p{Han}·]{1,10}?)(?:轻声|低声|高声|沉声|冷声|柔声|小声|大声|缓缓|认真|急忙|连忙|笑着|哭着|咬牙|皱眉|点头|摇头|叹息着|犹豫着)?(?:说道|说罢|说|问道|追问|反问|质问|询问|问|答道|回答|答|喊道|喊|叫道|叫|回应道|回应|应道|应声|开口道|开口|解释道|解释|补充道|补充|提醒道|提醒|劝道|反驳道|附和道|嘀咕道|嘀咕|呢喃道|呢喃|喃喃道|吼道|吼|喝道|斥道|骂道|惊呼道|惊呼|叹道|笑道|哭道|嚷道|道)(?=\s*[：:，,。“”\"「」『』！？!?]|\s*$)"#
    )
    private static let namedQuoteExpression = try? NSRegularExpression(
        pattern: #"(?:^|[。！？!?；;\n])\s*([\p{Han}·]{1,8})\s*(?:轻声|低声|高声|沉声|冷声|柔声|小声|大声|笑着|哭着|咬牙|皱眉|点头|摇头)?\s*[：:]\s*[“\"「『]"#
    )

    private struct Context {
        var chapterIndex: Int?
        var pendingSpeaker: String?
        var recentSpeakers: [String] = []
        var lastDialogueSpeaker: String?
        var lastUnitWasDialogue = false
        var unknownTurn = 0
        var knownCharacters: Set<String>
        var characterGenders: [String: NovelCharacterGender] = [:]

        init(knownCharacters: [String]) {
            self.knownCharacters = Set(knownCharacters)
        }

        mutating func reset(for chapterIndex: Int) {
            self.chapterIndex = chapterIndex
            pendingSpeaker = nil
            recentSpeakers = []
            lastDialogueSpeaker = nil
            lastUnitWasDialogue = false
            unknownTurn = 0
        }

        mutating func remember(_ name: String) {
            knownCharacters.insert(name)
            recentSpeakers.removeAll { $0 == name }
            recentSpeakers.append(name)
            if recentSpeakers.count > 2 { recentSpeakers.removeFirst() }
        }

        mutating func observeGender(of name: String, in text: String) {
            let femaleMarkers = ["小姐", "姑娘", "夫人", "女士", "母亲", "妈妈", "姐姐", "妹妹", "女儿", "妻子", "皇后", "公主", "女帝", "丫鬟"]
            let maleMarkers = ["先生", "公子", "少爷", "丈夫", "父亲", "爸爸", "哥哥", "弟弟", "儿子", "皇帝", "王爷", "男爵"]
            let female = femaleMarkers.contains { text.contains(name + $0) || text.contains($0 + name) || name.contains($0) }
            let male = maleMarkers.contains { text.contains(name + $0) || text.contains($0 + name) || name.contains($0) }
            guard female != male else { return }
            characterGenders[name] = female ? .female : .male
        }

        func speaker(forPronoun pronoun: String) -> String? {
            let requestedGender: NovelCharacterGender?
            switch pronoun {
            case "她": requestedGender = .female
            case "他": requestedGender = .male
            default: requestedGender = nil
            }
            if let requestedGender,
               let matched = recentSpeakers.reversed().first(where: {
                   characterGenders[$0] == requestedGender
               }) {
                return matched
            }
            return recentSpeakers.count == 1 ? recentSpeakers[0] : nil
        }
    }

    static func plan(
        for pages: [ReaderPage],
        alternatesUnattributedDialogue: Bool = true,
        knownCharacters: [String] = []
    ) -> ReadAloudRolePlan {
        analyze(
            pages: pages,
            alternatesUnattributedDialogue: alternatesUnattributedDialogue,
            knownCharacters: knownCharacters
        ).plan
    }

    static func analyze(
        pages: [ReaderPage],
        alternatesUnattributedDialogue: Bool = true,
        knownCharacters: [String] = []
    ) -> ReadAloudLocalRoleAnalysis {
        var result: [ReaderPageLocation: [ReadAloudSpeaker]] = [:]
        var context = Context(knownCharacters: knownCharacters)

        for page in pages {
            if context.chapterIndex != page.location.chapterIndex {
                context.reset(for: page.location.chapterIndex)
            }
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            var consumedLookahead = Set<Int>()
            var pageSpeakers: [ReadAloudSpeaker] = []

            for index in sentences.indices {
                let text = sentences[index].text
                let explicitSpeaker = consumedLookahead.contains(index)
                    ? nil
                    : attributedSpeaker(in: text, context: context)
                let dialogue = containsDialogue(in: text)

                if !dialogue {
                    context.pendingSpeaker = explicitSpeaker
                    if let explicitSpeaker {
                        context.remember(explicitSpeaker)
                        context.observeGender(of: explicitSpeaker, in: text)
                    }
                    context.lastUnitWasDialogue = false
                    context.unknownTurn = 0
                    pageSpeakers.append(narrationSpeaker(for: text))
                    continue
                }

                var resolvedSpeaker = explicitSpeaker
                if resolvedSpeaker == nil, sentences.indices.contains(index + 1) {
                    resolvedSpeaker = attributedSpeaker(
                        in: sentences[index + 1].text,
                        context: context
                    )
                    if resolvedSpeaker != nil { consumedLookahead.insert(index + 1) }
                }
                if resolvedSpeaker == nil {
                    resolvedSpeaker = context.pendingSpeaker
                }
                if resolvedSpeaker == nil, alternatesUnattributedDialogue {
                    resolvedSpeaker = alternatingSpeaker(in: context)
                }

                if let resolvedSpeaker {
                    pageSpeakers.append(.character(resolvedSpeaker))
                    context.remember(resolvedSpeaker)
                    context.observeGender(of: resolvedSpeaker, in: text)
                    context.lastDialogueSpeaker = resolvedSpeaker
                    context.unknownTurn = 0
                } else {
                    let turn = alternatesUnattributedDialogue ? context.unknownTurn : 0
                    pageSpeakers.append(.unknownDialogue(turn: turn))
                    if alternatesUnattributedDialogue {
                        context.unknownTurn = context.lastUnitWasDialogue ? (turn + 1) % 2 : 1
                    }
                }
                context.pendingSpeaker = nil
                context.lastUnitWasDialogue = true
            }
            result[page.location] = pageSpeakers
        }
        return ReadAloudLocalRoleAnalysis(
            plan: ReadAloudRolePlan(speakersByPage: result),
            characterGenders: context.characterGenders
        )
    }

    private static func narrationSpeaker(for text: String) -> ReadAloudSpeaker {
        let firstPersonMarkers = ["我", "我们", "咱们", "本人", "我的", "我们的"]
        return firstPersonMarkers.contains(where: text.contains) ? .narrator : .thirdPersonNarrator
    }

    private static func alternatingSpeaker(in context: Context) -> String? {
        guard !context.recentSpeakers.isEmpty else { return nil }
        guard context.recentSpeakers.count > 1, let last = context.lastDialogueSpeaker else {
            return context.recentSpeakers.last
        }
        return context.recentSpeakers.last(where: { $0 != last }) ?? context.recentSpeakers.last
    }

    private static func containsDialogue(in text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "\"“”「」『』")) != nil
    }

    private static func attributedSpeaker(in text: String, context: Context) -> String? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let expressions = [
            namedQuoteExpression.map { ($0, true) },
            attributionExpression.map { ($0, false) }
        ].compactMap { $0 }
        for (expression, permitsDialoguePrefix) in expressions {
            let matches = expression.matches(in: text, range: fullRange)
            for match in matches.reversed() {
                guard match.numberOfRanges > 1 else { continue }
                guard permitsDialoguePrefix
                    || !isInsideDialogue(atUTF16Location: match.range.location, in: nsText) else { continue }
                let raw = nsText.substring(with: match.range(at: 1))
                if ["他", "她", "它"].contains(raw),
                   let resolved = context.speaker(forPronoun: raw) {
                    return resolved
                }
                let candidate = normalizedSpeakerName(
                    raw,
                    knownCharacters: context.knownCharacters
                )
                if let candidate { return candidate }
            }
        }
        return nil
    }

    private static func isInsideDialogue(atUTF16Location location: Int, in text: NSString) -> Bool {
        let prefix = text.substring(to: min(max(0, location), text.length))
        var closingQuotes: [Character] = []
        var straightQuoteIsOpen = false

        for character in prefix {
            switch character {
            case "“": closingQuotes.append("”")
            case "「": closingQuotes.append("」")
            case "『": closingQuotes.append("』")
            case "”", "」", "』":
                if closingQuotes.last == character { closingQuotes.removeLast() }
            case "\"": straightQuoteIsOpen.toggle()
            default: break
            }
        }
        return !closingQuotes.isEmpty || straightQuoteIsOpen
    }

    private static func normalizedSpeakerName(
        _ rawName: String,
        knownCharacters: Set<String>
    ) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = knownCharacters
            .sorted(by: { $0.count > $1.count })
            .first(where: { name.hasPrefix($0) || name == $0 }) {
            return known
        }
        let narrativePrefixes = ["与此同时", "就在这时", "这时候", "那时候", "紧接着", "这时", "此时", "随后", "忽然", "于是", "只见", "却见", "然后", "接着", "可是", "但是", "而后", "便", "就"]
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in narrativePrefixes where name.hasPrefix(prefix) && name.count > prefix.count {
                name.removeFirst(prefix.count)
                removedPrefix = true
                break
            }
        }

        let speechVerbSuffixes = [
            "开口道", "提醒道", "解释道", "补充道", "回应道", "回答道",
            "说道", "问道", "答道", "喊道", "叫道", "应道", "笑道", "哭道",
            "追问", "反问", "质问", "询问", "回答", "提醒", "解释", "补充",
            "回应", "开口", "说罢", "说", "问", "答", "喊", "叫", "道"
        ]
        if let suffix = speechVerbSuffixes.first(where: { name.hasSuffix($0) }),
           name.count > suffix.count {
            name.removeLast(suffix.count)
        }

        let speechModifierSuffixes = [
            "叹息着", "犹豫着", "笑着", "哭着", "轻声", "低声", "高声",
            "沉声", "冷声", "柔声", "小声", "大声", "缓缓", "认真", "急忙",
            "连忙", "咬牙", "皱眉", "点头", "摇头"
        ]
        var removedModifier = true
        while removedModifier {
            removedModifier = false
            if let suffix = speechModifierSuffixes.first(where: { name.hasSuffix($0) }),
               name.count > suffix.count {
                name.removeLast(suffix.count)
                removedModifier = true
            }
        }

        let honorificSuffixes = ["小姐", "先生", "姑娘", "夫人", "公子", "少爷", "女士"]
        if let suffix = honorificSuffixes.first(where: { name.hasSuffix($0) }),
           name.count - suffix.count >= 2 {
            name.removeLast(suffix.count)
        }

        let rejectedNames: Set<String> = [
            "我", "你", "您", "他", "她", "它", "我们", "你们", "他们", "她们", "它们",
            "有人", "众人", "大家", "对方", "男人", "女人", "老人", "少年", "少女",
            "什么", "怎么", "为何", "为什么", "哪里", "这里", "那里", "这边", "那边",
            "声音", "语气", "话音", "心里", "心中", "此人", "那人", "来人"
        ]
        guard (1...6).contains(name.count), !rejectedNames.contains(name) else { return nil }
        return name
    }
}
