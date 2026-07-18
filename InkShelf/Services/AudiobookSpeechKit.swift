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
                .init(id: "茉莉", name: "茉莉 · 女声")
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
        if settings.voiceSelectionMode == .single,
           choices(for: settings.provider).contains(where: { $0.id == settings.selectedVoiceIdentifier }) {
            return .init(voiceID: settings.selectedVoiceIdentifier, instruction: instruction(for: speaker))
        }
        switch settings.provider {
        case .localZipVoice:
            return .init(voiceID: "", instruction: instruction(for: speaker))
        case .mimo:
            switch speaker {
            case .narrator:
                return .init(voiceID: "白桦", instruction: "沉稳、自然地进行有声书旁白，吐字清晰。")
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
        case let .character(name): "保持人物“\(name)”的声音稳定，以自然的角色口吻朗读对白。"
        case .unknownDialogue: "以自然的角色口吻朗读对白，不要读出额外说明。"
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

        var sentenceLookup: [String: (ReaderPageLocation, Int)] = [:]
        var sourceLines: [String] = []
        for (pageOffset, page) in pages.enumerated() {
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let id = "p\(pageOffset)s\(sentenceIndex)"
                sentenceLookup[id] = (page.location, sentenceIndex)
                sourceLines.append("\(id)\t\(sentence.text.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        let source = String(sourceLines.joined(separator: "\n").prefix(48_000))
        let instruction = """
        你是小说有声书导演。判断每句是旁白还是哪位人物说话。不得改写原文，不得虚构姓名。
        只返回 JSON：{"assignments":[{"id":"p0s0","speaker":"旁白"},{"id":"p0s1","speaker":"人物名"}]}。
        不确定说话人时 speaker 写“未知”。句子如下：
        \(source)
        """
        let body: [String: Any] = [
            "model": settings.analysisModel,
            "messages": [
                ["role": "system", "content": "你只输出严格 JSON。"],
                ["role": "user", "content": instruction]
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
              let content = message["content"] as? String,
              let jsonData = Self.jsonObjectData(in: content),
              let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let assignments = result["assignments"] as? [[String: Any]] else {
            throw AudiobookSpeechError.invalidResponse
        }

        var combined = fallback.speakersByPage
        for assignment in assignments {
            guard let id = assignment["id"] as? String,
                  let rawSpeaker = assignment["speaker"] as? String,
                  let (location, index) = sentenceLookup[id],
                  var speakers = combined[location], speakers.indices.contains(index) else { continue }
            let speaker = rawSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker == "旁白" {
                speakers[index] = .narrator
            } else if !speaker.isEmpty, speaker != "未知", speaker.count <= 12 {
                speakers[index] = .character(speaker)
            }
            combined[location] = speakers
        }
        return ReadAloudRolePlan(speakersByPage: combined)
    }

    private static func jsonObjectData(in content: String) -> Data? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return Data(content[start...end].utf8)
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
    private(set) var isPaused = false

    var hasScheduledAudio: Bool { player != nil }

    func play(_ data: Data, completion: @escaping () -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        self.player = player
        self.completion = completion
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            stop()
            throw AudiobookSpeechError.invalidResponse
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
        player?.stop()
        player = nil
        completion = nil
        isPaused = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let currentPlayer = self.player, player === currentPlayer else { return }
        let completion = self.completion
        self.player = nil
        self.completion = nil
        isPaused = false
        if flag { completion?() }
    }
}
