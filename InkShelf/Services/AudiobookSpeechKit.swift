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

/// Stable automatic casting inspired by mimo-tts. Manual mode intentionally
/// selects one voice for the whole book; automatic mode keeps character roles.
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
        settings: ReadAloudSettings
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
                let voices = ["冰糖", "苏打", "茉莉"]
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
                let voices = ["nova", "echo", "shimmer", "onyx", "fable"]
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
        case .single:
            return settings.selectedVoiceIdentifier
        case .roleBased:
            switch speaker {
            case .narrator:
                return settings.narratorVoiceIdentifier
            case .thirdPersonNarrator:
                return settings.thirdPersonVoiceIdentifier
            case .character, .unknownDialogue:
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

    static func loadAPIKey() -> String {
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
        apiKey: String
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
        let direction = AudiobookVoiceDirector.direction(for: speaker, settings: configuration)
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
}

enum NovelRoleAnalysisCodec {
    static func makeInput(pages: [ReaderPage], maximumCharacters: Int) -> NovelRoleAnalysisInput {
        var sentenceLookup: [String: (ReaderPageLocation, Int)] = [:]
        var sourceLines: [String] = []
        var characterCount = 0
        for (pageOffset, page) in pages.enumerated() {
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let id = "p\(pageOffset)s\(sentenceIndex)"
                let line = "\(id)\t\(sentence.text.replacingOccurrences(of: "\n", with: " "))"
                guard characterCount + line.count <= maximumCharacters else { break }
                sentenceLookup[id] = (page.location, sentenceIndex)
                sourceLines.append(line)
                characterCount += line.count + 1
            }
        }
        let prompt = """
        你是小说有声书角色导演。结合章节上下文、引号、说话动词、人物称谓、代词和连续对话，判断每个文本单元的声音类型。
        type 只能是“第一人称旁白”“第三人称旁白”或“角色”。角色必须填写原文已经出现的人名；不确定人物时 speaker 写“未知”。不得改写原文或虚构人物。
        只返回严格 JSON：{"assignments":[{"id":"p0s0","type":"第三人称旁白","speaker":""},{"id":"p0s1","type":"角色","speaker":"人物名"}]}。
        文本单元如下：
        \(sourceLines.joined(separator: "\n"))
        """
        return NovelRoleAnalysisInput(prompt: prompt, sentenceLookup: sentenceLookup)
    }

    static func decode(
        content: String,
        input: NovelRoleAnalysisInput,
        fallback: ReadAloudRolePlan
    ) throws -> ReadAloudRolePlan {
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
                if !rawSpeaker.isEmpty, rawSpeaker != "未知", rawSpeaker.count <= 12 {
                    speakers[index] = .character(rawSpeaker)
                }
            }
            combined[location] = speakers
        }
        return ReadAloudRolePlan(speakersByPage: combined)
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
        fallback: ReadAloudRolePlan
    ) async throws -> ReadAloudRolePlan {
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

        let input = NovelRoleAnalysisCodec.makeInput(pages: pages, maximumCharacters: 48_000)
        let body: [String: Any] = [
            "model": settings.analysisModel,
            "messages": [
                ["role": "system", "content": "你只输出严格 JSON。"],
                ["role": "user", "content": input.prompt]
            ],
            "temperature": 0
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AudiobookSpeechError.invalidResponse }
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
        return try NovelRoleAnalysisCodec.decode(content: content, input: input, fallback: fallback)
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
final class AudiobookAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (() -> Void)?
    private var boundaryTimer: Timer?
    private var boundaryHandler: (() -> Void)?
    private(set) var isPaused = false

    var hasScheduledAudio: Bool { player != nil }

    func play(
        _ data: Data,
        boundaryFraction: Double? = nil,
        onBoundary: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        self.player = player
        self.completion = completion
        boundaryHandler = onBoundary
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            stop()
            throw AudiobookSpeechError.invalidResponse
        }
        if let boundaryFraction, onBoundary != nil {
            let fraction = min(0.98, max(0.02, boundaryFraction))
            let boundaryTime = player.duration * fraction
            boundaryTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak player] timer in
                guard let self, let player, self.player === player else {
                    timer.invalidate()
                    return
                }
                guard player.currentTime >= boundaryTime else { return }
                timer.invalidate()
                self.boundaryTimer = nil
                let handler = self.boundaryHandler
                self.boundaryHandler = nil
                handler?()
            }
        }
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
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryHandler = nil
        player?.stop()
        player = nil
        completion = nil
        isPaused = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let currentPlayer = self.player, player === currentPlayer else { return }
        let completion = self.completion
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryHandler = nil
        self.player = nil
        self.completion = nil
        isPaused = false
        if flag { completion?() }
    }
}
