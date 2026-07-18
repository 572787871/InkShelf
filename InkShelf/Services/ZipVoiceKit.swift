import AVFoundation
import CryptoKit
import Foundation
import SWCompression

enum ZipVoiceProfileGender: String, Codable, CaseIterable, Identifiable, Sendable {
    case unspecified
    case female
    case male

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: "未指定"
        case .female: "女声"
        case .male: "男声"
        }
    }
}

struct ZipVoiceProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var gender: ZipVoiceProfileGender
    var referenceText: String
    let audioFileName: String

    var voiceIdentifier: String { "zipvoice::\(id.uuidString.lowercased())" }
}

struct ZipVoiceModelPaths: Equatable, Sendable {
    let tokens: URL
    let encoder: URL
    let decoder: URL
    let vocoder: URL
    let dataDirectory: URL
    let lexicon: URL
}

enum ZipVoiceInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installing
    case installed
    case failed(String)
}

enum ZipVoiceError: LocalizedError, Equatable {
    case inaccessibleAudio
    case invalidAudio
    case invalidTranscript
    case downloadFailed(String)
    case checksumMismatch
    case invalidArchive
    case unsafeArchive
    case missingModelFile(String)
    case modelNotInstalled
    case noVoiceProfile
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .inaccessibleAudio: "无法访问参考音频"
        case .invalidAudio: "无法读取该音频，请选择 WAV、M4A、MP3、AAC 或其他系统支持的音频文件"
        case .invalidTranscript: "请填写与参考音频完全一致的文字"
        case let .downloadFailed(message): "ZipVoice 下载失败：\(message)"
        case .checksumMismatch: "ZipVoice 文件校验失败，请重新下载"
        case .invalidArchive: "ZipVoice 模型压缩包无效"
        case .unsafeArchive: "ZipVoice 模型压缩包包含不安全路径"
        case let .missingModelFile(file): "ZipVoice 模型缺少文件：\(file)"
        case .modelNotInstalled: "请先下载 ZipVoice 本地模型"
        case .noVoiceProfile: "请先导入至少一个本地参考音色"
        case let .synthesisFailed(message): "ZipVoice 生成失败：\(message)"
        }
    }
}

enum ZipVoiceBuiltInProfiles {
    static let transcript = "欢迎来到墨架，愿每一个故事，都有属于自己的声音。"
    static let definitions: [(id: UUID, resource: String, name: String, gender: ZipVoiceProfileGender)] = [
        (UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459101")!, "ink_stable", "墨沉 · 沉稳", .male),
        (UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459102")!, "ink_warm", "墨暖 · 温和", .female),
        (UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459103")!, "ink_clear", "墨清 · 清亮", .female)
    ]

    static func contains(_ profile: ZipVoiceProfile) -> Bool {
        definitions.contains { $0.id == profile.id }
    }
}

enum ZipVoiceCatalog {
    static let modelID = "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"
    static let archiveRoot = modelID
    static let archiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(modelID).tar.bz2")!
    static let archiveBytes: Int64 = 109_162_785
    static let archiveSHA256 = "77219c8b40f4ee8d73a7f902305ff6c1128ef9b54461c41b4ca6ed890b6c2803"
    static let vocoderURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx")!
    static let vocoderBytes: Int64 = 54_157_409
    static let vocoderSHA256 = "bcb3b970e384161c4d634f0bb9e999ff1c471b34c9bc0b1049a5014065ed3cc0"
    static let totalBytes = archiveBytes + vocoderBytes
}

struct ZipVoiceStore: Sendable {
    private static let profilesFileName = "profiles.json"
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("ZipVoice", isDirectory: true)
        }
    }

    var modelDirectory: URL { rootURL.appendingPathComponent("Model", isDirectory: true) }
    var profilesDirectory: URL { rootURL.appendingPathComponent("Profiles", isDirectory: true) }

    func modelPaths() -> ZipVoiceModelPaths? {
        let paths = ZipVoiceModelPaths(
            tokens: modelDirectory.appendingPathComponent("tokens.txt"),
            encoder: modelDirectory.appendingPathComponent("encoder.int8.onnx"),
            decoder: modelDirectory.appendingPathComponent("decoder.int8.onnx"),
            vocoder: modelDirectory.appendingPathComponent("vocos_24khz.onnx"),
            dataDirectory: modelDirectory.appendingPathComponent("espeak-ng-data", isDirectory: true),
            lexicon: modelDirectory.appendingPathComponent("lexicon.txt")
        )
        return validate(paths) ? paths : nil
    }

    func profiles() -> [ZipVoiceProfile] {
        let url = profilesDirectory.appendingPathComponent(Self.profilesFileName)
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([ZipVoiceProfile].self, from: data) else { return [] }
        return profiles.filter {
            FileManager.default.fileExists(atPath: audioURL(for: $0).path)
        }
    }

    func audioURL(for profile: ZipVoiceProfile) -> URL {
        profilesDirectory.appendingPathComponent(profile.audioFileName)
    }

    func addProfile(
        from sourceURL: URL,
        name: String,
        gender: ZipVoiceProfileGender,
        referenceText: String
    ) async throws -> ZipVoiceProfile {
        try await Task.detached(priority: .userInitiated) {
            try self.addProfileSynchronously(
                from: sourceURL,
                name: name,
                gender: gender,
                referenceText: referenceText
            )
        }.value
    }

    func ensureBuiltInProfiles(bundle: Bundle = .main) throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        var all = profiles()
        for definition in ZipVoiceBuiltInProfiles.definitions where !all.contains(where: { $0.id == definition.id }) {
            guard let source = bundle.url(
                forResource: definition.resource,
                withExtension: "wav",
                subdirectory: "Voices"
            ) ?? bundle.url(forResource: definition.resource, withExtension: "wav") else { continue }
            let fileName = "\(definition.id.uuidString.lowercased()).wav"
            let destination = profilesDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try convertToReferenceWAV(source, destination: destination)
            all.append(ZipVoiceProfile(
                id: definition.id,
                name: definition.name,
                gender: definition.gender,
                referenceText: ZipVoiceBuiltInProfiles.transcript,
                audioFileName: fileName
            ))
        }
        try persist(all)
    }

    func removeProfile(_ profile: ZipVoiceProfile) throws {
        var all = profiles()
        all.removeAll { $0.id == profile.id }
        try? FileManager.default.removeItem(at: audioURL(for: profile))
        try persist(all)
    }

    func installModel(archiveURL: URL, vocoderURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.installSynchronously(archiveURL: archiveURL, vocoderURL: vocoderURL)
        }.value
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func addProfileSynchronously(
        from sourceURL: URL,
        name: String,
        gender: ZipVoiceProfileGender,
        referenceText: String
    ) throws -> ZipVoiceProfile {
        let transcript = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw ZipVoiceError.invalidTranscript }
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasScope { sourceURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ZipVoiceError.inaccessibleAudio
        }
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).wav"
        let destination = profilesDirectory.appendingPathComponent(fileName)
        do {
            try convertToReferenceWAV(sourceURL, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ZipVoiceError.invalidAudio
        }
        let profile = ZipVoiceProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "本地音色" : name,
            gender: gender,
            referenceText: transcript,
            audioFileName: fileName
        )
        var all = profiles()
        all.append(profile)
        try persist(all)
        return profile
    }

    private func convertToReferenceWAV(_ source: URL, destination: URL) throws {
        let inputFile = try AVAudioFile(forReading: source)
        guard inputFile.length > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            throw ZipVoiceError.invalidAudio
        }
        try? FileManager.default.removeItem(at: destination)
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let inputCapacity: AVAudioFrameCount = 4_096
        var reachedEnd = false
        while !reachedEnd {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: inputCapacity
            ) else { throw ZipVoiceError.invalidAudio }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: inputCapacity
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
            if status == .error { throw ZipVoiceError.invalidAudio }
            if status == .endOfStream { reachedEnd = true }
        }
        guard outputFile.length > 0 else { throw ZipVoiceError.invalidAudio }
    }

    private func persist(_ profiles: [ZipVoiceProfile]) throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(
            to: profilesDirectory.appendingPathComponent(Self.profilesFileName),
            options: .atomic
        )
    }

    private func installSynchronously(archiveURL: URL, vocoderURL: URL) throws {
        guard try Self.sha256(of: archiveURL) == ZipVoiceCatalog.archiveSHA256,
              try Self.sha256(of: vocoderURL) == ZipVoiceCatalog.vocoderSHA256 else {
            throw ZipVoiceError.checksumMismatch
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let staging = rootURL.appendingPathComponent(".model-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var compressed = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        var tarData = try BZip2.decompress(data: compressed)
        compressed = Data()
        let entries = try TarContainer.open(container: tarData)
        tarData = Data()
        guard entries.count <= 20_000 else { throw ZipVoiceError.invalidArchive }

        for entry in entries {
            let path = entry.info.name
            guard isSafe(path),
                  path == ZipVoiceCatalog.archiveRoot || path.hasPrefix(ZipVoiceCatalog.archiveRoot + "/") else {
                throw ZipVoiceError.unsafeArchive
            }
            let relative = String(path.dropFirst(ZipVoiceCatalog.archiveRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.isEmpty { continue }
            if relative == "test_wavs" || relative.hasPrefix("test_wavs/") {
                continue
            }
            let destination = staging.appendingPathComponent(relative)
            switch entry.info.type {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .regular, .contiguous:
                guard let data = entry.data else { throw ZipVoiceError.invalidArchive }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            default:
                throw ZipVoiceError.unsafeArchive
            }
        }
        try fileManager.copyItem(at: vocoderURL, to: staging.appendingPathComponent("vocos_24khz.onnx"))
        let paths = ZipVoiceModelPaths(
            tokens: staging.appendingPathComponent("tokens.txt"),
            encoder: staging.appendingPathComponent("encoder.int8.onnx"),
            decoder: staging.appendingPathComponent("decoder.int8.onnx"),
            vocoder: staging.appendingPathComponent("vocos_24khz.onnx"),
            dataDirectory: staging.appendingPathComponent("espeak-ng-data", isDirectory: true),
            lexicon: staging.appendingPathComponent("lexicon.txt")
        )
        guard validate(paths) else {
            let missing = [paths.tokens, paths.encoder, paths.decoder, paths.vocoder, paths.lexicon]
                .first { !fileManager.fileExists(atPath: $0.path) }?.lastPathComponent ?? "espeak-ng-data"
            throw ZipVoiceError.missingModelFile(missing)
        }
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        try fileManager.moveItem(at: staging, to: modelDirectory)
    }

    private func validate(_ paths: ZipVoiceModelPaths) -> Bool {
        let manager = FileManager.default
        let files = [paths.tokens, paths.encoder, paths.decoder, paths.vocoder, paths.lexicon]
        var isDirectory: ObjCBool = false
        return files.allSatisfy { manager.fileExists(atPath: $0.path) }
            && manager.fileExists(atPath: paths.dataDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

struct ZipVoiceSynthesizedAudio: Sendable {
    let pcmFloat32: Data
    let sampleRate: Double

    var wavData: Data {
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let sampleRate = UInt32(max(1, self.sampleRate.rounded()))
        let dataSize = UInt32(min(Int(UInt32.max), pcmFloat32.count))
        appendASCII("RIFF")
        append(UInt32(36) + dataSize)
        appendASCII("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(3))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 4)
        append(UInt16(4))
        append(UInt16(32))
        appendASCII("data")
        append(dataSize)
        data.append(pcmFloat32.prefix(Int(dataSize)))
        return data
    }
}

actor ZipVoiceSynthesizer {
    private var bridge: ISZipVoiceTTSBridge?
    private var loadedPaths: ZipVoiceModelPaths?

    func unload() {
        bridge = nil
        loadedPaths = nil
    }

    func synthesize(
        text: String,
        model: ZipVoiceModelPaths,
        profile: ZipVoiceProfile,
        audioURL: URL,
        speed: Float
    ) throws -> ZipVoiceSynthesizedAudio {
        if bridge == nil || loadedPaths != model {
            bridge = try ISZipVoiceTTSBridge(
                encoderPath: model.encoder.path,
                decoderPath: model.decoder.path,
                vocoderPath: model.vocoder.path,
                tokensPath: model.tokens.path,
                lexiconPath: model.lexicon.path,
                dataDirectory: model.dataDirectory.path
            )
            loadedPaths = model
        }
        guard let bridge else { throw ZipVoiceError.modelNotInstalled }
        var sampleRate = 0
        let pcm = try bridge.synthesizeText(
            text,
            referenceAudioPath: audioURL.path,
            referenceText: profile.referenceText,
            speed: speed,
            sampleRate: &sampleRate
        )
        guard !pcm.isEmpty, sampleRate > 0 else {
            throw ZipVoiceError.synthesisFailed("模型没有返回音频")
        }
        return .init(pcmFloat32: pcm, sampleRate: Double(sampleRate))
    }
}
