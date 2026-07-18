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
    case ai
    case localModel
    case localRules

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ai: "云端 AI"
        case .localModel: "本地大模型"
        case .localRules: "本地规则"
        }
    }
}

enum LocalRoleModelVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen3_0_6B
    case qwen3_1_7B

    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen3_0_6B: "Qwen3 0.6B · 轻量"
        case .qwen3_1_7B: "Qwen3 1.7B · 精准"
        }
    }
    var repositoryID: String {
        switch self {
        case .qwen3_0_6B: "mlx-community/Qwen3-0.6B-4bit"
        case .qwen3_1_7B: "mlx-community/Qwen3-1.7B-4bit"
        }
    }
    var approximateDownload: String { self == .qwen3_0_6B ? "约 335 MB" : "约 938 MB" }
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
    case single

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动选择"
        case .roleBased: "按类型指定"
        case .single: "统一音色"
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
    var localRoleModel = LocalRoleModelVariant.qwen3_0_6B
    var analysisProvider = ReadAloudAIProvider.mimo
    var analysisBaseURL = ReadAloudAIProvider.mimo.defaultBaseURL
    var analysisModel = ReadAloudAIProvider.mimo.defaultModel
    var voiceSelectionMode = ReadAloudVoiceSelectionMode.automatic
    var selectedVoiceIdentifier = ""
    var narratorVoiceIdentifier = ""
    var thirdPersonVoiceIdentifier = ""
    var characterVoiceIdentifier = ""

    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, model, rateMultiplier, allowsTextUpload
        case roleDetectionMode, localRoleModel, analysisProvider, analysisBaseURL, analysisModel
        case voiceSelectionMode, selectedVoiceIdentifier, narratorVoiceIdentifier
        case thirdPersonVoiceIdentifier, characterVoiceIdentifier
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
        roleDetectionMode = try container.decodeIfPresent(ReadAloudRoleDetectionMode.self, forKey: .roleDetectionMode) ?? .ai
        localRoleModel = try container.decodeIfPresent(LocalRoleModelVariant.self, forKey: .localRoleModel) ?? .qwen3_0_6B
        analysisProvider = try container.decodeIfPresent(ReadAloudAIProvider.self, forKey: .analysisProvider) ?? .mimo
        analysisBaseURL = try container.decodeIfPresent(String.self, forKey: .analysisBaseURL)
            ?? analysisProvider.defaultBaseURL
        analysisModel = try container.decodeIfPresent(String.self, forKey: .analysisModel)
            ?? analysisProvider.defaultModel
        voiceSelectionMode = try container.decodeIfPresent(ReadAloudVoiceSelectionMode.self, forKey: .voiceSelectionMode) ?? .automatic
        selectedVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .selectedVoiceIdentifier) ?? ""
        narratorVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .narratorVoiceIdentifier) ?? ""
        thirdPersonVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .thirdPersonVoiceIdentifier) ?? ""
        characterVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .characterVoiceIdentifier) ?? ""
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

struct ReadAloudRolePlan: Equatable, Sendable {
    let speakersByPage: [ReaderPageLocation: [ReadAloudSpeaker]]

    static let empty = ReadAloudRolePlan(speakersByPage: [:])

    func speakers(for location: ReaderPageLocation) -> [ReadAloudSpeaker]? {
        speakersByPage[location]
    }
}

/// A deterministic, local-first dialogue attribution pass. It deliberately
/// leaves ambiguous dialogue unnamed instead of inventing character identities.
struct ReadAloudRoleAnalyzer {
    private static let attributionExpression = try? NSRegularExpression(
        pattern: #"([\p{Han}·]{1,8}?)(?:轻声|低声|高声|沉声|冷声|笑着|哭着)?(?:说道|说|问道|问|答道|答|喊道|喊|叫道|叫|回应道|回应)(?=\s*[：:，,。“”\"「」『』！？!?]|\s*$)"#
    )

    private struct Context {
        var chapterIndex: Int?
        var pendingSpeaker: String?
        var recentSpeakers: [String] = []
        var lastDialogueSpeaker: String?
        var lastUnitWasDialogue = false
        var unknownTurn = 0

        mutating func reset(for chapterIndex: Int) {
            self.chapterIndex = chapterIndex
            pendingSpeaker = nil
            recentSpeakers = []
            lastDialogueSpeaker = nil
            lastUnitWasDialogue = false
            unknownTurn = 0
        }

        mutating func remember(_ name: String) {
            recentSpeakers.removeAll { $0 == name }
            recentSpeakers.append(name)
            if recentSpeakers.count > 2 { recentSpeakers.removeFirst() }
        }
    }

    static func plan(for pages: [ReaderPage], alternatesUnattributedDialogue: Bool = true) -> ReadAloudRolePlan {
        var result: [ReaderPageLocation: [ReadAloudSpeaker]] = [:]
        var context = Context()

        for page in pages {
            if context.chapterIndex != page.location.chapterIndex {
                context.reset(for: page.location.chapterIndex)
            }
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            var consumedLookahead = Set<Int>()
            var pageSpeakers: [ReadAloudSpeaker] = []

            for index in sentences.indices {
                let text = sentences[index].text
                let explicitSpeaker = consumedLookahead.contains(index) ? nil : attributedSpeaker(in: text)
                let dialogue = containsDialogue(in: text)

                if !dialogue {
                    context.pendingSpeaker = explicitSpeaker
                    if let explicitSpeaker { context.remember(explicitSpeaker) }
                    context.lastUnitWasDialogue = false
                    context.unknownTurn = 0
                    pageSpeakers.append(narrationSpeaker(for: text))
                    continue
                }

                var resolvedSpeaker = explicitSpeaker
                if resolvedSpeaker == nil, sentences.indices.contains(index + 1) {
                    resolvedSpeaker = attributedSpeaker(in: sentences[index + 1].text)
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
        return ReadAloudRolePlan(speakersByPage: result)
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

    private static func attributedSpeaker(in text: String) -> String? {
        guard let expression = attributionExpression else { return nil }
        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            guard !isInsideDialogue(atUTF16Location: match.range.location, in: nsText) else { continue }
            let candidate = normalizedSpeakerName(nsText.substring(with: match.range(at: 1)))
            if let candidate { return candidate }
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

    private static func normalizedSpeakerName(_ rawName: String) -> String? {
        var name = rawName
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

        let rejectedNames: Set<String> = [
            "我", "你", "您", "他", "她", "它", "我们", "你们", "他们", "她们", "它们",
            "有人", "众人", "大家", "对方", "男人", "女人", "老人", "少年", "少女"
        ]
        guard (1...6).contains(name.count), !rejectedNames.contains(name) else { return nil }
        return name
    }
}
