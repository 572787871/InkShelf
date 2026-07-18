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
    case invalidDuration
    case invalidTranscript
    case downloadFailed(String)
    case checksumMismatch
    case invalidArchive
    case unsafeArchive
    case missingModelFile(String)
    case modelNotInstalled
    case noVoiceProfile
    case unauthorizedVoice
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .inaccessibleAudio: "无法访问参考音频"
        case .invalidAudio: "无法读取该音频，请选择 WAV、M4A、MP3、AAC 或其他系统支持的音频文件"
        case .invalidDuration: "参考音频请控制在 2 到 30 秒，并只保留清晰人声"
        case .invalidTranscript: "请填写与参考音频完全一致的文字"
        case let .downloadFailed(message): "ZipVoice 下载失败：\(message)"
        case .checksumMismatch: "ZipVoice 文件校验失败，请重新下载"
        case .invalidArchive: "ZipVoice 模型压缩包无效"
        case .unsafeArchive: "ZipVoice 模型压缩包包含不安全路径"
        case let .missingModelFile(file): "ZipVoice 模型缺少文件：\(file)"
        case .modelNotInstalled: "请先下载 ZipVoice 本地模型"
        case .noVoiceProfile: "请先导入至少一个本地参考音色"
        case .unauthorizedVoice: "该模拟音色缺少声音所有者授权，请重新创建"
        case let .synthesisFailed(message): "ZipVoice 生成失败：\(message)"
        }
    }
}

enum ZipVoiceBuiltInProfiles {
    struct Definition: Codable, Sendable {
        let id: UUID
        let resource: String
        let name: String
        let gender: ZipVoiceProfileGender
        let referenceText: String?
    }

    private struct Catalog: Codable {
        let transcript: String
        let voices: [Definition]
    }

    private static let catalog: Catalog = {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Voices")
            ?? bundle.url(forResource: "catalog", withExtension: "json")
        guard let url else {
            return Catalog(
                transcript: "愿每一个故事，都有属于自己的声音。",
                voices: []
            )
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            assertionFailure("内置音色目录无法读取：\(error.localizedDescription)")
            return Catalog(
                transcript: "愿每一个故事，都有属于自己的声音。",
                voices: []
            )
        }
    }()

    static let transcript = catalog.transcript
    private static let retiredProfileIDs: Set<UUID> = [
        UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459101")!,
        UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459102")!,
        UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459103")!,
        UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459201")!,
        UUID(uuidString: "347D8335-91A6-4D9D-91B8-67C504459202")!
    ]
    static let definitions = catalog.voices

    static func contains(_ profile: ZipVoiceProfile) -> Bool {
        definitions.contains { $0.id == profile.id }
    }

    static func definition(for profile: ZipVoiceProfile) -> Definition? {
        definitions.first { $0.id == profile.id }
    }

    static func isRetired(_ profile: ZipVoiceProfile) -> Bool {
        retiredProfileIDs.contains(profile.id)
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
    static let modelVersion = "\(modelID)-sherpa-onnx-1.13.1"
}

struct ZipVoiceStore: Sendable {
    private static let profilesFileName = "profiles.json"
    private static let profileFileName = "profile.json"
    let rootURL: URL
    let voiceProfilesRootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
            self.voiceProfilesRootURL = rootURL.appendingPathComponent("VoiceProfiles", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("ZipVoice", isDirectory: true)
            self.voiceProfilesRootURL = support.appendingPathComponent("VoiceProfiles", isDirectory: true)
        }
    }

    var modelDirectory: URL { rootURL.appendingPathComponent("Model", isDirectory: true) }
    /// Legacy flat directory retained only for one-time migration.
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

    func profiles(bundle: Bundle = .main) throws -> [ZipVoiceProfile] {
        let builtIns = try ZipVoiceBuiltInProfiles.definitions.compactMap { definition -> ZipVoiceProfile? in
            guard let audioURL = bundle.url(
                forResource: definition.resource,
                withExtension: "wav",
                subdirectory: "Voices"
            ) ?? bundle.url(forResource: definition.resource, withExtension: "wav") else { return nil }
            let file = try AVAudioFile(forReading: audioURL)
            return VoiceProfile(
                id: definition.id,
                name: definition.name,
                sourceType: .builtIn,
                referenceAudioRelativePath: "Bundled/Voices/\(definition.resource).wav",
                originalAudioRelativePath: nil,
                referenceText: definition.referenceText ?? ZipVoiceBuiltInProfiles.transcript,
                previewAudioRelativePath: nil,
                originalFilename: nil,
                sampleRate: file.processingFormat.sampleRate,
                duration: Double(file.length) / max(1, file.processingFormat.sampleRate),
                voiceCategory: definition.gender,
                modelVersion: ZipVoiceCatalog.modelVersion,
                isAuthorized: true,
                createdAt: .distantPast
            )
        }
        guard FileManager.default.fileExists(atPath: voiceProfilesRootURL.path) else { return builtIns }
        let directories = try FileManager.default.contentsOfDirectory(
            at: voiceProfilesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var custom: [VoiceProfile] = []
        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let metadataURL = directory.appendingPathComponent(Self.profileFileName)
            guard FileManager.default.fileExists(atPath: metadataURL.path) else { continue }
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(VoiceProfile.self, from: data)
            guard FileManager.default.fileExists(atPath: audioURL(for: profile).path) else { continue }
            custom.append(profile)
        }
        return builtIns + custom.sorted { $0.createdAt > $1.createdAt }
    }

    func audioURL(for profile: ZipVoiceProfile) -> URL {
        if let definition = ZipVoiceBuiltInProfiles.definition(for: profile),
           let bundled = Bundle.main.url(
               forResource: definition.resource,
               withExtension: "wav",
               subdirectory: "Voices"
           ) ?? Bundle.main.url(forResource: definition.resource, withExtension: "wav") {
            return bundled
        }
        return voiceProfilesRootURL.appendingPathComponent(profile.referenceAudioRelativePath)
    }

    func originalAudioURL(for profile: VoiceProfile) -> URL? {
        guard let path = profile.originalAudioRelativePath else { return nil }
        return voiceProfilesRootURL.appendingPathComponent(path)
    }

    func previewAudioURL(for profile: VoiceProfile) -> URL? {
        guard let path = profile.previewAudioRelativePath else { return nil }
        return voiceProfilesRootURL.appendingPathComponent(path)
    }

    func saveProfile(
        name: String,
        sourceType: VoiceProfileSourceType,
        voiceCategory: ZipVoiceProfileGender,
        originalURL: URL,
        processedAudio: ProcessedVoiceAudio,
        referenceText: String,
        previewURL: URL,
        originalFilename: String?,
        isAuthorized: Bool
    ) throws -> VoiceProfile {
        guard isAuthorized else { throw LocalVoiceError.authorizationRequired }
        let transcript = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw LocalVoiceError.emptyReferenceText }
        let identifier = UUID()
        let directoryName = identifier.uuidString.lowercased()
        let finalDirectory = voiceProfilesRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let staging = voiceProfilesRootURL.appendingPathComponent(".\(directoryName)-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceProfilesRootURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let sourceExtension = supportedOriginalExtension(originalURL.pathExtension)
            let originalName = "original.\(sourceExtension)"
            let stagedOriginal = staging.appendingPathComponent(originalName)
            try FileManager.default.copyItem(at: originalURL, to: stagedOriginal)
            try FileManager.default.copyItem(
                at: processedAudio.referenceURL,
                to: staging.appendingPathComponent("reference.wav")
            )
            try FileManager.default.copyItem(at: previewURL, to: staging.appendingPathComponent("preview.wav"))
            try Data(transcript.utf8).write(to: staging.appendingPathComponent("reference.txt"), options: .atomic)

            let profile = VoiceProfile(
                id: identifier,
                name: normalizedName(name),
                sourceType: sourceType,
                referenceAudioRelativePath: "\(directoryName)/reference.wav",
                originalAudioRelativePath: "\(directoryName)/\(originalName)",
                referenceText: transcript,
                previewAudioRelativePath: "\(directoryName)/preview.wav",
                originalFilename: originalFilename,
                sampleRate: processedAudio.sampleRate,
                duration: processedAudio.duration,
                voiceCategory: voiceCategory,
                modelVersion: ZipVoiceCatalog.modelVersion,
                isAuthorized: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(profile).write(
                to: staging.appendingPathComponent(Self.profileFileName),
                options: .atomic
            )
            let consent = VoiceConsentRecord(
                voiceID: identifier,
                isAuthorized: true,
                confirmedAt: Date(),
                sourceType: sourceType,
                statement: "我确认这是本人的声音，或我已经获得声音所有者的明确授权。我不会使用该功能进行冒充、欺骗或侵犯他人权益。"
            )
            try encoder.encode(consent).write(
                to: staging.appendingPathComponent("consent.json"),
                options: .atomic
            )
            if FileManager.default.fileExists(atPath: finalDirectory.path) {
                try FileManager.default.removeItem(at: finalDirectory)
            }
            try FileManager.default.moveItem(at: staging, to: finalDirectory)
            return profile
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch let cleanupError {
                    throw ZipVoiceError.synthesisFailed(
                        "保存音色失败：\(error.localizedDescription)；临时文件清理失败：\(cleanupError.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    func ensureBuiltInProfiles(bundle: Bundle = .main) throws {
        try FileManager.default.createDirectory(at: voiceProfilesRootURL, withIntermediateDirectories: true)
        try migrateLegacyProfiles(bundle: bundle)
    }

    func removeProfile(_ profile: ZipVoiceProfile) throws {
        guard profile.sourceType != .builtIn else { throw LocalVoiceError.cannotRemoveBuiltIn }
        let directory = voiceProfilesRootURL.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw LocalVoiceError.profileNotFound }
        try FileManager.default.removeItem(at: directory)
    }

    func updateProfile(_ profile: VoiceProfile) throws {
        guard profile.sourceType != .builtIn else { throw LocalVoiceError.cannotRemoveBuiltIn }
        let directory = voiceProfilesRootURL.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw LocalVoiceError.profileNotFound }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(
            to: directory.appendingPathComponent(Self.profileFileName),
            options: .atomic
        )
    }

    func replacePreview(for profile: VoiceProfile, from sourceURL: URL) throws -> VoiceProfile {
        guard profile.sourceType != .builtIn else { throw LocalVoiceError.cannotRemoveBuiltIn }
        var updated = profile
        let directoryName = profile.id.uuidString.lowercased()
        let destination = voiceProfilesRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("preview.wav")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        updated.previewAudioRelativePath = "\(directoryName)/preview.wav"
        try updateProfile(updated)
        return updated
    }

    func installModel(archiveURL: URL, vocoderURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.installSynchronously(archiveURL: archiveURL, vocoderURL: vocoderURL)
        }.value
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func migrateLegacyProfiles(bundle: Bundle) throws {
        let legacyURL = profilesDirectory.appendingPathComponent(Self.profilesFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let data = try Data(contentsOf: legacyURL)
        let profiles = try JSONDecoder().decode([VoiceProfile].self, from: data)
        for legacy in profiles where ZipVoiceBuiltInProfiles.definition(for: legacy) == nil {
            let finalDirectory = voiceProfilesRootURL
                .appendingPathComponent(legacy.id.uuidString.lowercased(), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: finalDirectory.path) else { continue }
            let legacyAudio = profilesDirectory.appendingPathComponent(legacy.audioFileName)
            guard FileManager.default.fileExists(atPath: legacyAudio.path) else { continue }
            let audioFile = try AVAudioFile(forReading: legacyAudio)
            try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
            let referenceDestination = finalDirectory.appendingPathComponent("reference.wav")
            try FileManager.default.copyItem(at: legacyAudio, to: referenceDestination)
            let directoryName = legacy.id.uuidString.lowercased()
            let migrated = VoiceProfile(
                id: legacy.id,
                name: legacy.name,
                sourceType: .imported,
                referenceAudioRelativePath: "\(directoryName)/reference.wav",
                originalAudioRelativePath: nil,
                referenceText: legacy.referenceText,
                previewAudioRelativePath: nil,
                originalFilename: nil,
                sampleRate: audioFile.processingFormat.sampleRate,
                duration: Double(audioFile.length) / max(1, audioFile.processingFormat.sampleRate),
                voiceCategory: legacy.gender,
                modelVersion: ZipVoiceCatalog.modelVersion,
                isAuthorized: legacy.isAuthorized,
                createdAt: legacy.createdAt
            )
            try Data(migrated.referenceText.utf8).write(
                to: finalDirectory.appendingPathComponent("reference.txt"),
                options: .atomic
            )
            try updateProfile(migrated)
        }
        let migratedURL = profilesDirectory.appendingPathComponent("profiles.migrated.json")
        if FileManager.default.fileExists(atPath: migratedURL.path) { try FileManager.default.removeItem(at: migratedURL) }
        try FileManager.default.moveItem(at: legacyURL, to: migratedURL)
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "我的模拟音色" : String(trimmed.prefix(30))
    }

    private func supportedOriginalExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["wav", "m4a", "mp3", "aac", "caf"].contains(normalized) ? normalized : "audio"
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
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch {
                    assertionFailure("ZipVoice 模型临时目录清理失败：\(error.localizedDescription)")
                }
            }
        }

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

    private struct VoiceConsentRecord: Codable {
        let voiceID: UUID
        let isAuthorized: Bool
        let confirmedAt: Date
        let sourceType: VoiceProfileSourceType
        let statement: String
    }
}

struct ZipVoiceSynthesizedAudio: Sendable {
    let pcmFloat32: Data
    let sampleRate: Double

    var wavData: Data {
        let polishedPCM = polishedPCMFloat32
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let sampleRate = UInt32(max(1, self.sampleRate.rounded()))
        let dataSize = UInt32(min(Int(UInt32.max), polishedPCM.count))
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
        data.append(polishedPCM.prefix(Int(dataSize)))
        return data
    }

    /// ZipVoice can leave a short block of near-digital silence at each edge.
    /// Removing it before the next prefetched block starts avoids an audible
    /// stop/start rhythm while a short fade keeps the cut click-free.
    private var polishedPCMFloat32: Data {
        let sampleCount = pcmFloat32.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return pcmFloat32 }
        var samples = [Float](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { destination in
            pcmFloat32.copyBytes(to: destination)
        }
        for index in samples.indices where !samples[index].isFinite {
            samples[index] = 0
        }
        let originalPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard originalPeak > 0.000_01 else { return pcmFloat32 }
        let threshold = max(Float(0.0015), originalPeak * 0.0025)
        guard let firstSignal = samples.firstIndex(where: { abs($0) >= threshold }),
              let lastSignal = samples.lastIndex(where: { abs($0) >= threshold }) else {
            return pcmFloat32
        }
        let rate = max(1, Int(sampleRate.rounded()))
        let start = max(0, firstSignal - rate / 50)
        let end = min(samples.count, lastSignal + rate * 3 / 100 + 1)
        var polished = Array(samples[start..<end])

        let mean = polished.reduce(Float(0), +) / Float(max(1, polished.count))
        for index in polished.indices { polished[index] -= mean }
        let peak = polished.reduce(Float(0)) { max($0, abs($1)) }
        let gain = peak > 0.98 ? 0.94 / peak : min(1.2, 0.86 / max(peak, 0.000_01))
        if gain != 1 {
            for index in polished.indices { polished[index] *= gain }
        }

        let fadeFrames = min(polished.count / 2, max(1, rate / 200))
        for index in 0..<fadeFrames {
            let envelope = Float(index) / Float(fadeFrames)
            polished[index] *= envelope
            polished[polished.count - index - 1] *= envelope
        }
        return polished.withUnsafeBytes { Data($0) }
    }
}

actor ZipVoiceSynthesizer {
    private var bridge: ISZipVoiceTTSBridge?
    private var loadedPaths: ZipVoiceModelPaths?

    func unload() {
        bridge = nil
        loadedPaths = nil
    }

    func modelSampleRate(model: ZipVoiceModelPaths) throws -> Int {
        let bridge = try loadBridgeIfNeeded(model: model)
        let sampleRate = bridge.modelSampleRate
        guard sampleRate > 0 else { throw LocalVoiceError.modelSampleRateUnavailable }
        return sampleRate
    }

    func releaseReferenceAudioCache(keeping audioURL: URL?) throws {
        bridge?.clearReferenceAudioCache(keepingPath: audioURL?.path)
    }

    func synthesize(
        text: String,
        model: ZipVoiceModelPaths,
        profile: ZipVoiceProfile,
        audioURL: URL,
        speed: Float,
        cancellation: ISZipVoiceSynthesisCancellation? = nil
    ) throws -> ZipVoiceSynthesizedAudio {
        guard profile.isAuthorized else { throw ZipVoiceError.unauthorizedVoice }
        let bridge = try loadBridgeIfNeeded(model: model)
        var sampleRate = 0
        let pcm: Data
        do {
            pcm = try bridge.synthesizeText(
                text,
                referenceAudioPath: audioURL.path,
                referenceText: profile.referenceText,
                speed: speed,
                cancellation: cancellation,
                sampleRate: &sampleRate
            )
        } catch {
            if cancellation?.isCancelled == true { throw CancellationError() }
            throw error
        }
        guard !pcm.isEmpty, sampleRate > 0 else {
            throw ZipVoiceError.synthesisFailed("模型没有返回音频")
        }
        return .init(pcmFloat32: pcm, sampleRate: Double(sampleRate))
    }

    private func loadBridgeIfNeeded(model: ZipVoiceModelPaths) throws -> ISZipVoiceTTSBridge {
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
        return bridge
    }
}
