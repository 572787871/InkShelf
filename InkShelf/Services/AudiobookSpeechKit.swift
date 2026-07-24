import AVFoundation
import Foundation
import Security

enum AudiobookConnectionState: Equatable {
    case idle
    case testing
    case connected
    case failed(String)
}

enum AudiobookSpeechError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case textUploadNotAllowed
    case missingAPIKey
    case invalidResponse
    case service(statusCode: Int, message: String)
    case audioTooLarge

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case .textUploadNotAllowed: "请先在主页设置中允许把朗读片段发送给语音服务"
        case .missingAPIKey: "请先在主页设置中填写 API Key"
        case .invalidResponse: "语音服务返回了无法识别的数据"
        case let .service(statusCode, message): "语音服务错误（\(statusCode)）：\(message)"
        case .audioTooLarge: "语音服务返回的音频过大"
        }
    }
}

struct AudiobookVoiceDirection: Equatable, Sendable {
    let voiceID: String
    let instruction: String
}

struct AudiobookVoiceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Stable automatic casting for narration and named roles. Role-based mode
/// preserves explicit per-character choices while automatic mode derives a
/// stable voice from the persisted cast metadata.
enum AudiobookVoiceDirector {
    static func choices(for provider: ReadAloudProvider) -> [AudiobookVoiceChoice] {
        switch provider {
        case .localZipVoice:
            return []
        case .mimo:
            return [
                .init(id: "白桦", name: "白桦 · 男声"),
                .init(id: "苏打", name: "苏打 · 男声"),
                .init(id: "冰糖", name: "冰糖 · 女声"),
                .init(id: "茉莉", name: "茉莉 · 女声"),
                .init(id: "Mia", name: "Mia · 英文女声"),
                .init(id: "Chloe", name: "Chloe · 英文女声"),
                .init(id: "Milo", name: "Milo · 英文男声"),
                .init(id: "Dean", name: "Dean · 英文男声")
            ]
        case .openAICompatible:
            return ["alloy", "nova", "echo", "shimmer", "onyx", "fable"].map {
                .init(id: $0, name: $0)
            }
        }
    }

    static func direction(
        for speaker: ReadAloudSpeaker,
        settings: ReadAloudSettings,
        characterGenders: [String: NovelCharacterGender] = [:]
    ) -> AudiobookVoiceDirection {
        let choices = choices(for: settings.provider)
        if let selectedIdentifier = selectedVoiceIdentifier(for: speaker, settings: settings),
           choices.contains(where: { $0.id == selectedIdentifier }) {
            return .init(voiceID: selectedIdentifier, instruction: instruction(for: speaker))
        }
        switch settings.provider {
        case .localZipVoice:
            return .init(voiceID: "", instruction: instruction(for: speaker))
        case .mimo:
            switch speaker {
            case .narrator:
                return .init(voiceID: "白桦", instruction: "沉稳、自然地进行有声书旁白，吐字清晰。")
            case .thirdPersonNarrator:
                return .init(voiceID: "苏打", instruction: "以客观、连贯的第三人称旁白口吻朗读，吐字清晰。")
            case let .unknownDialogue(turn):
                let voices = ["冰糖", "苏打"]
                return .init(
                    voiceID: voices[positiveModulo(turn, voices.count)],
                    instruction: "以自然的角色口吻朗读对白，不要读出额外说明。"
                )
            case let .character(name):
                let voices: [String]
                switch characterGenders[name] {
                case .female: voices = ["冰糖", "茉莉"]
                case .male: voices = ["苏打", "白桦"]
                case .unspecified, .none: voices = ["冰糖", "苏打", "茉莉"]
                }
                return .init(
                    voiceID: voices[stableIndex(name, count: voices.count)],
                    instruction: "保持人物“\(name)”的声音稳定，以自然的角色口吻朗读对白。"
                )
            }
        case .openAICompatible:
            switch speaker {
            case .narrator:
                return .init(voiceID: "alloy", instruction: "Read as a calm, natural audiobook narrator in the text's language.")
            case .thirdPersonNarrator:
                return .init(voiceID: "fable", instruction: "Read as an objective third-person audiobook narrator in the text's language.")
            case let .unknownDialogue(turn):
                let voices = ["nova", "echo"]
                return .init(
                    voiceID: voices[positiveModulo(turn, voices.count)],
                    instruction: "Read as natural character dialogue in the text's language. Do not add words."
                )
            case let .character(name):
                let voices: [String]
                switch characterGenders[name] {
                case .female: voices = ["nova", "shimmer"]
                case .male: voices = ["echo", "onyx", "fable"]
                case .unspecified, .none: voices = ["nova", "echo", "shimmer", "onyx", "fable"]
                }
                return .init(
                    voiceID: voices[stableIndex(name, count: voices.count)],
                    instruction: "Keep a consistent audiobook character performance for \(name). Do not add words."
                )
            }
        }
    }

    private static func instruction(for speaker: ReadAloudSpeaker) -> String {
        switch speaker {
        case .narrator: "沉稳、自然地进行有声书旁白，吐字清晰。"
        case .thirdPersonNarrator: "以客观、连贯的第三人称旁白口吻朗读，吐字清晰。"
        case let .character(name): "保持人物“\(name)”的声音稳定，以自然的角色口吻朗读对白。"
        case .unknownDialogue: "以自然的角色口吻朗读对白，不要读出额外说明。"
        }
    }

    private static func selectedVoiceIdentifier(
        for speaker: ReadAloudSpeaker,
        settings: ReadAloudSettings
    ) -> String? {
        switch settings.voiceSelectionMode {
        case .automatic:
            return nil
        case .roleBased:
            switch speaker {
            case .narrator:
                return settings.narratorVoiceIdentifier
            case .thirdPersonNarrator:
                return settings.thirdPersonVoiceIdentifier
            case let .character(name):
                return settings.characterVoiceIdentifiers[name] ?? settings.characterVoiceIdentifier
            case .unknownDialogue:
                return settings.characterVoiceIdentifier
            }
        }
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func stableIndex(_ value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

enum AudiobookCredentialStore {
    private static let service = "com.example.InkShelf.audiobook"
    private static let account = "tts-api-key"
    private static let analysisAccount = "role-analysis-api-key"

    static func loadAPIKey() -> String {
        load(account: account)
    }

    static func loadAnalysisAPIKey() -> String {
        load(account: analysisAccount)
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func saveAPIKey(_ key: String) {
        save(key, account: account)
    }

    static func saveAnalysisAPIKey(_ key: String) {
        save(key, account: analysisAccount)
    }

    private static func save(_ key: String, account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if key.isEmpty {
            SecItemDelete(match as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(match as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insertion = match
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insertion as CFDictionary, nil)
        }
    }
}

actor AudiobookSpeechClient {
    private static let maximumAudioBytes = 50 * 1_024 * 1_024
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func synthesize(
        text: String,
        speaker: ReadAloudSpeaker,
        settings: ReadAloudSettings,
        apiKey: String,
        characterGenders: [String: NovelCharacterGender] = [:]
    ) async throws -> Data {
        let configuration = settings.normalized
        guard configuration.allowsTextUpload else { throw AudiobookSpeechError.textUploadNotAllowed }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AudiobookSpeechError.missingAPIKey }
        guard !configuration.model.isEmpty else {
            throw AudiobookSpeechError.invalidConfiguration("模型名称不能为空")
        }
        guard let baseURL = URL(string: configuration.baseURL),
              baseURL.scheme?.lowercased() == "https" else {
            throw AudiobookSpeechError.invalidConfiguration("服务地址必须是 HTTPS 地址")
        }

        guard configuration.provider != .localZipVoice else {
            throw AudiobookSpeechError.invalidConfiguration("本地 ZipVoice 不使用网络语音接口")
        }
        let direction = AudiobookVoiceDirector.direction(
            for: speaker,
            settings: configuration,
            characterGenders: characterGenders
        )
        var request: URLRequest
        switch configuration.provider {
        case .localZipVoice:
            throw AudiobookSpeechError.invalidConfiguration("本地 ZipVoice 不使用网络语音接口")
        case .mimo:
            request = try mimoRequest(
                baseURL: baseURL,
                model: configuration.model,
                text: text,
                direction: direction,
                speed: configuration.rateMultiplier,
                apiKey: key
            )
        case .openAICompatible:
            request = try compatibleRequest(
                baseURL: baseURL,
                model: configuration.model,
                text: text,
                direction: direction,
                speed: configuration.rateMultiplier,
                apiKey: key
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AudiobookSpeechError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AudiobookSpeechError.service(
                statusCode: http.statusCode,
                message: Self.serviceMessage(from: data)
            )
        }

        let audio: Data
        switch configuration.provider {
        case .localZipVoice:
            throw AudiobookSpeechError.invalidConfiguration("本地 ZipVoice 不使用网络语音接口")
        case .mimo:
            audio = try Self.decodeMiMoAudio(from: data)
        case .openAICompatible:
            audio = data
        }
        guard !audio.isEmpty else { throw AudiobookSpeechError.invalidResponse }
        guard audio.count <= Self.maximumAudioBytes else { throw AudiobookSpeechError.audioTooLarge }
        return audio
    }

    private func mimoRequest(
        baseURL: URL,
        model: String,
        text: String,
        direction: AudiobookVoiceDirection,
        speed: Double,
        apiKey: String
    ) throws -> URLRequest {
        var request = authorizedRequest(
            url: endpoint("chat/completions", under: baseURL),
            apiKey: apiKey
        )
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "\(direction.instruction) 语速约为正常速度的 \(String(format: "%.2f", speed)) 倍。"
                ],
                ["role": "assistant", "content": text]
            ],
            "audio": ["format": "wav", "voice": direction.voiceID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func compatibleRequest(
        baseURL: URL,
        model: String,
        text: String,
        direction: AudiobookVoiceDirection,
        speed: Double,
        apiKey: String
    ) throws -> URLRequest {
        var request = authorizedRequest(
            url: endpoint("audio/speech", under: baseURL),
            apiKey: apiKey
        )
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": direction.voiceID,
            "instructions": direction.instruction,
            "response_format": "wav",
            "speed": speed
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func authorizedRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpoint(_ path: String, under baseURL: URL) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private static func decodeMiMoAudio(from data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let audio = message["audio"] as? [String: Any],
              let encoded = audio["data"] as? String,
              let decoded = Data(base64Encoded: encoded) else {
            throw AudiobookSpeechError.invalidResponse
        }
        return decoded
    }

    private static func serviceMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(240))
        }
        return "请求失败，请检查地址、模型和密钥"
    }
}

struct NovelRoleAnalysisInput: Sendable {
    let prompt: String
    let sentenceLookup: [String: (ReaderPageLocation, Int)]
    let sourceLines: [String]
}

struct NovelRoleAnalysisResult: Equatable, Sendable {
    let plan: ReadAloudRolePlan
    let characterGenders: [String: NovelCharacterGender]
}

enum NovelRoleAnalysisCodec {
    static func makeInput(
        pages: [ReaderPage],
        maximumCharacters: Int,
        knownCharacters: [String] = []
    ) -> NovelRoleAnalysisInput {
        makeInputs(
            pages: pages,
            maximumCharacters: maximumCharacters,
            maximumSentences: .max,
            knownCharacters: knownCharacters
        ).first ?? NovelRoleAnalysisInput(
            prompt: prompt(for: [], knownCharacters: knownCharacters),
            sentenceLookup: [:],
            sourceLines: []
        )
    }

    static func makeInputs(
        pages: [ReaderPage],
        maximumCharacters: Int,
        maximumSentences: Int,
        knownCharacters: [String] = []
    ) -> [NovelRoleAnalysisInput] {
        var inputs: [NovelRoleAnalysisInput] = []
        var sentenceLookup: [String: (ReaderPageLocation, Int)] = [:]
        var sourceLines: [String] = []
        var characterCount = 0
        var batchIndex = 0
        for (pageOffset, page) in pages.enumerated() {
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let previewID = "b\(batchIndex)p\(pageOffset)s\(sentenceIndex)"
                let previewLine = "\(previewID)\t\(sentence.text.replacingOccurrences(of: "\n", with: " "))"
                if !sourceLines.isEmpty,
                   (characterCount + previewLine.count > maximumCharacters
                    || sourceLines.count >= maximumSentences) {
                    inputs.append(NovelRoleAnalysisInput(
                        prompt: prompt(for: sourceLines, knownCharacters: knownCharacters),
                        sentenceLookup: sentenceLookup,
                        sourceLines: sourceLines
                    ))
                    batchIndex += 1
                    sentenceLookup = [:]
                    sourceLines = []
                    characterCount = 0
                }
                let effectiveID = "b\(batchIndex)p\(pageOffset)s\(sentenceIndex)"
                let effectiveLine = "\(effectiveID)\t\(sentence.text.replacingOccurrences(of: "\n", with: " "))"
                sentenceLookup[effectiveID] = (page.location, sentenceIndex)
                sourceLines.append(effectiveLine)
                characterCount += effectiveLine.count + 1
            }
        }
        if !sourceLines.isEmpty {
            inputs.append(NovelRoleAnalysisInput(
                prompt: prompt(for: sourceLines, knownCharacters: knownCharacters),
                sentenceLookup: sentenceLookup,
                sourceLines: sourceLines
            ))
        }
        return inputs
    }

    static func refreshing(
        _ input: NovelRoleAnalysisInput,
        knownCharacters: [String]
    ) -> NovelRoleAnalysisInput {
        NovelRoleAnalysisInput(
            prompt: prompt(
                for: input.sourceLines,
                knownCharacters: Array(knownCharacters.prefix(120))
            ),
            sentenceLookup: input.sentenceLookup,
            sourceLines: input.sourceLines
        )
    }

    private static func prompt(for sourceLines: [String], knownCharacters: [String]) -> String {
        """
        你是小说有声书角色导演。结合整章上下文、引号范围、说话动词、人物称谓、代词和连续对话，判断每个文本单元的声音类型。
        type 只能是“第一人称旁白”“第三人称旁白”或“角色”。角色填写原文人物名；称谓或别名明确对应此前角色时，speaker 必须沿用此前规范名。不确定人物时 speaker 写“未知”。不得虚构人物。连续对话必须结合上下句判断说话人，不能因为省略姓名就随意更换声线。
        同一对引号内的连续句子必须使用同一个 speaker，除非文本明确开启了新的嵌套引号。不要因为句子中出现“他说”“问道”等转述词就切换当前引号内的说话人。
        每个 id 都必须返回一条 assignment；type 为“角色”时 speaker 必须是规范人物名或“未知”。
        本书此前已确认的角色：\(knownCharacters.isEmpty ? "暂无" : knownCharacters.joined(separator: "、"))。
        只返回严格 JSON：{"characters":[{"name":"人物名","gender":"女或男或未知"}],"assignments":[{"id":"b0p0s0","type":"第三人称旁白","speaker":""},{"id":"b0p0s1","type":"角色","speaker":"人物名"}]}。
        文本单元如下：
        \(sourceLines.joined(separator: "\n"))
        """
    }

    static func decode(
        content: String,
        input: NovelRoleAnalysisInput,
        fallback: ReadAloudRolePlan
    ) throws -> ReadAloudRolePlan {
        try decodeResult(content: content, input: input, fallback: fallback).plan
    }

    static func decodeResult(
        content: String,
        input: NovelRoleAnalysisInput,
        fallback: ReadAloudRolePlan
    ) throws -> NovelRoleAnalysisResult {
        guard let jsonData = jsonObjectData(in: content),
              let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let assignments = result["assignments"] as? [[String: Any]] else {
            throw AudiobookSpeechError.invalidResponse
        }
        var combined = fallback.speakersByPage
        for assignment in assignments {
            guard let id = assignment["id"] as? String,
                  let (location, index) = input.sentenceLookup[id],
                  var speakers = combined[location], speakers.indices.contains(index) else { continue }
            let type = (assignment["type"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawSpeaker = (assignment["speaker"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if type.contains("第三人称") || rawSpeaker.contains("第三人称") {
                speakers[index] = .thirdPersonNarrator
            } else if type.contains("第一人称") || rawSpeaker == "旁白" || rawSpeaker.contains("第一人称") {
                speakers[index] = .narrator
            } else if type == "角色" || (!rawSpeaker.isEmpty && rawSpeaker != "未知") {
                if rawSpeaker == "未知" {
                    // AI is authoritative for this unit. Do not retain a
                    // potentially wrong local character assignment.
                    speakers[index] = .unknownDialogue(turn: 0)
                } else if !rawSpeaker.isEmpty, rawSpeaker.count <= 12 {
                    speakers[index] = .character(rawSpeaker)
                }
            }
            combined[location] = speakers
        }
        var genders: [String: NovelCharacterGender] = [:]
        for character in result["characters"] as? [[String: Any]] ?? [] {
            let name = (character["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 12 else { continue }
            let rawGender = (character["gender"] as? String ?? "").lowercased()
            if rawGender.contains("女") || rawGender == "female" {
                genders[name] = .female
            } else if rawGender.contains("男") || rawGender == "male" {
                genders[name] = .male
            } else {
                genders[name] = .unspecified
            }
        }
        return NovelRoleAnalysisResult(
            plan: ReadAloudRolePlan(speakersByPage: combined),
            characterGenders: genders
        )
    }

    private static func jsonObjectData(in content: String) -> Data? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start <= end else { return nil }
        return Data(content[start...end].utf8)
    }
}

actor AICharacterRoleClient {
    func analyze(
        pages: [ReaderPage],
        settings: ReadAloudSettings,
        apiKey: String,
        fallback: ReadAloudRolePlan,
        knownCharacters: [String] = [],
        progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> NovelRoleAnalysisResult {
        guard settings.allowsTextUpload else { throw AudiobookSpeechError.textUploadNotAllowed }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AudiobookSpeechError.missingAPIKey }
        guard !settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudiobookSpeechError.invalidConfiguration("角色分析模型不能为空")
        }
        guard let baseURL = URL(string: settings.analysisBaseURL),
              baseURL.scheme?.lowercased() == "https" else {
            throw AudiobookSpeechError.invalidConfiguration("角色分析地址必须是 HTTPS 地址")
        }

        let inputs = NovelRoleAnalysisCodec.makeInputs(
            pages: pages,
            maximumCharacters: 7_000,
            maximumSentences: 36,
            knownCharacters: knownCharacters
        )
        guard !inputs.isEmpty else {
            return NovelRoleAnalysisResult(plan: fallback, characterGenders: [:])
        }
        var combined = fallback
        var characterGenders: [String: NovelCharacterGender] = [:]
        var continuityNames = Set(knownCharacters)
        progress(0, inputs.count)
        for (index, rawInput) in inputs.enumerated() {
            try Task.checkCancellation()
            // Feed names discovered in earlier batches back into later ones so
            // long chapters keep aliases and alternating dialogue stable.
            let input = NovelRoleAnalysisCodec.refreshing(
                rawInput,
                knownCharacters: continuityNames.sorted()
            )
            var decoded: NovelRoleAnalysisResult?
            var decodeError: Error?
            for decodeAttempt in 0..<2 {
                let content = try await responseContent(
                    input: input,
                    settings: settings,
                    apiKey: key,
                    baseURL: baseURL
                )
                do {
                    decoded = try NovelRoleAnalysisCodec.decodeResult(
                        content: content,
                        input: input,
                        fallback: combined
                    )
                    break
                } catch {
                    decodeError = error
                    if decodeAttempt == 0 {
                        try await Task.sleep(for: .milliseconds(350))
                    }
                }
            }
            guard let decoded else {
                throw decodeError ?? AudiobookSpeechError.invalidResponse
            }
            combined = decoded.plan
            characterGenders.merge(decoded.characterGenders) { existing, new in
                existing == .unspecified ? new : existing
            }
            continuityNames.formUnion(decoded.characterGenders.keys)
            for speakers in decoded.plan.speakersByPage.values {
                for speaker in speakers {
                    if case let .character(name) = speaker { continuityNames.insert(name) }
                }
            }
            progress(index + 1, inputs.count)
        }
        return NovelRoleAnalysisResult(
            plan: combined,
            characterGenders: characterGenders
        )
    }

    private func responseContent(
        input: NovelRoleAnalysisInput,
        settings: ReadAloudSettings,
        apiKey: String,
        baseURL: URL
    ) async throws -> String {
        let body: [String: Any] = [
            "model": settings.analysisModel,
            "messages": [
                ["role": "system", "content": "你是有声书角色导演，只输出严格 JSON，不输出解释或 Markdown。"],
                ["role": "user", "content": input.prompt]
            ],
            "temperature": 0
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AudiobookSpeechError.invalidResponse
                }
                guard (200...299).contains(http.statusCode) else {
                    throw AudiobookSpeechError.service(
                        statusCode: http.statusCode,
                        message: Self.serviceMessage(from: data)
                    )
                }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw AudiobookSpeechError.invalidResponse
                }
                return content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt == 0 {
                    try await Task.sleep(for: .milliseconds(650))
                }
            }
        }
        throw lastError ?? AudiobookSpeechError.invalidResponse
    }

    private static func serviceMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(240))
        }
        return "AI 角色分析请求失败"
    }
}

@MainActor
final class AudiobookAudioPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var preparedPlayer: AVAudioPlayer?
    private var preparedIdentifier: String?
    private var keepAlivePlayer: AVAudioPlayer?
    private var completion: (() -> Void)?
    private var progressTimer: Timer?
    private var boundaryHandler: (() -> Void)?
    private var boundaryTime: TimeInterval?
    private var cueFractions: [Double] = []
    private var nextCueIndex = 0
    private var cueHandler: ((Int) -> Void)?
    private(set) var isPaused = false

    var hasScheduledAudio: Bool { player != nil }

    func play(
        _ data: Data,
        preparedIdentifier: String? = nil,
        playbackRate: Float = 1,
        boundaryFraction: Double? = nil,
        onBoundary: (() -> Void)? = nil,
        cueFractions: [Double] = [],
        onCue: ((Int) -> Void)? = nil,
        completion: @escaping () -> Void
    ) throws {
        stopCurrentSpeech()
        let player: AVAudioPlayer
        if let preparedIdentifier,
           self.preparedIdentifier == preparedIdentifier,
           let preparedPlayer {
            player = preparedPlayer
            self.preparedPlayer = nil
            self.preparedIdentifier = nil
        } else {
            player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
        }
        self.player = player
        self.completion = completion
        boundaryHandler = onBoundary
        player.delegate = self
        player.enableRate = true
        player.rate = min(2, max(0.5, playbackRate))
        self.cueFractions = cueFractions.map { min(0.995, max(0, $0)) }
        nextCueIndex = self.cueFractions.firstIndex(where: { $0 > 0.001 }) ?? self.cueFractions.count
        cueHandler = onCue
        guard player.play() else {
            stopCurrentSpeech()
            throw AudiobookSpeechError.invalidResponse
        }
        if let boundaryFraction, onBoundary != nil {
            let fraction = min(0.98, max(0.02, boundaryFraction))
            boundaryTime = player.duration * fraction
        }
        if boundaryTime != nil || nextCueIndex < self.cueFractions.count {
            progressTimer = Timer.scheduledTimer(
                timeInterval: 0.05,
                target: self,
                selector: #selector(checkPlaybackProgress),
                userInfo: nil,
                repeats: true
            )
        }
    }

    func prepare(_ data: Data, identifier: String) throws {
        guard preparedIdentifier != identifier else { return }
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        preparedPlayer?.stop()
        preparedPlayer = player
        preparedIdentifier = identifier
    }

    /// Keeps the background-audio session alive while the next local block is
    /// still being generated. The silent bed is inaudible and is stopped for a
    /// real user pause, so lock-screen controls continue to reflect intent.
    func beginSessionKeepAlive() throws {
        guard keepAlivePlayer == nil else { return }
        let player = try AVAudioPlayer(data: Self.silentWAVData)
        player.numberOfLoops = -1
        player.volume = 0.0001
        player.prepareToPlay()
        guard player.play() else { throw AudiobookSpeechError.invalidResponse }
        keepAlivePlayer = player
    }

    func endSessionKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() throws {
        guard let player, isPaused, player.play() else { return }
        isPaused = false
    }

    func stop() {
        stopCurrentSpeech()
        preparedPlayer?.stop()
        preparedPlayer = nil
        preparedIdentifier = nil
        endSessionKeepAlive()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let currentPlayer = self.player, player === currentPlayer else { return }
        let completion = self.completion
        clearCurrentSpeechState()
        if flag { completion?() }
    }

    @objc private func checkPlaybackProgress() {
        guard let player, player.duration > 0 else { return }
        let fraction = player.currentTime / player.duration
        if let boundaryTime, player.currentTime >= boundaryTime {
            self.boundaryTime = nil
            let handler = boundaryHandler
            boundaryHandler = nil
            handler?()
        }
        while nextCueIndex < cueFractions.count, fraction >= cueFractions[nextCueIndex] {
            let cueIndex = nextCueIndex
            nextCueIndex += 1
            cueHandler?(cueIndex)
        }
        if boundaryTime == nil, nextCueIndex >= cueFractions.count {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func stopCurrentSpeech() {
        player?.stop()
        clearCurrentSpeechState()
    }

    private func clearCurrentSpeechState() {
        progressTimer?.invalidate()
        progressTimer = nil
        boundaryHandler = nil
        boundaryTime = nil
        cueFractions = []
        nextCueIndex = 0
        cueHandler = nil
        player = nil
        completion = nil
        isPaused = false
    }

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 24_000
        let sampleCount: UInt32 = 6_000
        let bytesPerSample: UInt16 = 2
        let dataSize = sampleCount * UInt32(bytesPerSample)
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLittleEndian(UInt32(36) + dataSize)
        appendASCII("WAVEfmt ")
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(sampleRate)
        appendLittleEndian(sampleRate * UInt32(bytesPerSample))
        appendLittleEndian(bytesPerSample)
        appendLittleEndian(UInt16(16))
        appendASCII("data")
        appendLittleEndian(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()
}
