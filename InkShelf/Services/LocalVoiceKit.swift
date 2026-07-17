import AVFoundation
import Foundation
import ZIPFoundation

enum LocalVoiceEngineKind: String, Codable, CaseIterable, Sendable {
    case kokoro
    case vits

    var displayName: String {
        switch self {
        case .kokoro: "Kokoro"
        case .vits: "VITS"
        }
    }
}

struct LocalVoiceSpeaker: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct LocalVoicePackageManifest: Codable, Equatable, Sendable {
    let formatVersion: Int
    let name: String
    let engine: LocalVoiceEngineKind
    let model: String
    let voices: String?
    let tokens: String
    let lexicons: [String]
    let dataDirectory: String?
    let speakers: [LocalVoiceSpeaker]

    init(
        formatVersion: Int = 1,
        name: String,
        engine: LocalVoiceEngineKind,
        model: String,
        voices: String? = nil,
        tokens: String,
        lexicons: [String] = [],
        dataDirectory: String? = nil,
        speakers: [LocalVoiceSpeaker] = [LocalVoiceSpeaker(id: 0, name: "默认音色")]
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.engine = engine
        self.model = model
        self.voices = voices
        self.tokens = tokens
        self.lexicons = lexicons
        self.dataDirectory = dataDirectory
        self.speakers = speakers
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, engine, model, voices, tokens, lexicons, dataDirectory, speakers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try container.decode(String.self, forKey: .name)
        engine = try container.decode(LocalVoiceEngineKind.self, forKey: .engine)
        model = try container.decode(String.self, forKey: .model)
        voices = try container.decodeIfPresent(String.self, forKey: .voices)
        tokens = try container.decode(String.self, forKey: .tokens)
        lexicons = try container.decodeIfPresent([String].self, forKey: .lexicons) ?? []
        dataDirectory = try container.decodeIfPresent(String.self, forKey: .dataDirectory)
        speakers = try container.decodeIfPresent([LocalVoiceSpeaker].self, forKey: .speakers)
            ?? [LocalVoiceSpeaker(id: 0, name: "默认音色")]
    }
}

struct LocalVoicePackage: Identifiable, Equatable, Sendable {
    let id: String
    let directoryURL: URL
    let manifest: LocalVoicePackageManifest

    var name: String { manifest.name }
    var engineName: String { manifest.engine.displayName }
    var voiceCount: Int { manifest.speakers.count }

    func fileURL(for relativePath: String) throws -> URL {
        let root = directoryURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { throw LocalVoicePackageError.unsafePath }
        return candidate
    }
}

enum LocalVoicePackageError: LocalizedError, Equatable {
    case inaccessibleFile
    case invalidArchive
    case missingManifest
    case unsupportedVersion
    case unsafePath
    case packageTooLarge
    case missingFile(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .inaccessibleFile: "无法访问所选音色包"
        case .invalidArchive: "音色包不是有效的 ZIP 文件"
        case .missingManifest: "音色包缺少 voice.json"
        case .unsupportedVersion: "音色包版本暂不支持"
        case .unsafePath: "音色包包含不安全的文件路径"
        case .packageTooLarge: "音色包展开后超过 2 GB"
        case let .missingFile(path): "音色包缺少文件：\(path)"
        case let .invalidManifest(reason): "voice.json 配置无效：\(reason)"
        }
    }
}

struct LocalVoicePackageStore: Sendable {
    private struct InstalledRecord: Codable {
        let id: String
        let manifest: LocalVoicePackageManifest
    }

    static let manifestFileName = "voice.json"
    private static let installedFileName = ".inkshelf-voice.json"
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("LocalVoices", isDirectory: true)
        }
    }

    func installedPackages() -> [LocalVoicePackage] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return directories.compactMap { directory -> LocalVoicePackage? in
            let recordURL = directory.appendingPathComponent(Self.installedFileName)
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(InstalledRecord.self, from: data),
                  (try? validate(record.manifest, in: directory)) != nil else { return nil }
            return LocalVoicePackage(id: record.id, directoryURL: directory, manifest: record.manifest)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importPackage(from sourceURL: URL) async throws -> LocalVoicePackage {
        try await Task.detached(priority: .userInitiated) {
            try self.importSynchronously(from: sourceURL)
        }.value
    }

    func remove(_ package: LocalVoicePackage) throws {
        let root = rootURL.standardizedFileURL.path + "/"
        let target = package.directoryURL.standardizedFileURL
        guard target.path.hasPrefix(root) else { throw LocalVoicePackageError.unsafePath }
        try FileManager.default.removeItem(at: target)
    }

    private func importSynchronously(from sourceURL: URL) throws -> LocalVoicePackage {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let stagingURL = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw LocalVoicePackageError.inaccessibleFile
        }
        guard let archive = try? Archive(url: sourceURL, accessMode: .read) else {
            throw LocalVoicePackageError.invalidArchive
        }

        var totalSize: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= 20_000 else { throw LocalVoicePackageError.invalidArchive }
            totalSize += UInt64(entry.uncompressedSize)
            guard totalSize <= 2_000_000_000 else { throw LocalVoicePackageError.packageTooLarge }
            guard Self.isSafeArchivePath(entry.path), entry.type != .symlink else {
                throw LocalVoicePackageError.unsafePath
            }
            let destination = stagingURL.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file:
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
            case .symlink:
                throw LocalVoicePackageError.unsafePath
            }
        }

        guard let manifestURL = Self.findManifest(in: stagingURL) else {
            throw LocalVoicePackageError.missingManifest
        }
        let packageRoot = manifestURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            LocalVoicePackageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try validate(manifest, in: packageRoot)

        let identifier = UUID().uuidString.lowercased()
        let destination = rootURL.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.moveItem(at: packageRoot, to: destination)
        let record = InstalledRecord(id: identifier, manifest: manifest)
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(
            to: destination.appendingPathComponent(Self.installedFileName),
            options: .atomic
        )
        return LocalVoicePackage(id: identifier, directoryURL: destination, manifest: manifest)
    }

    private func validate(_ manifest: LocalVoicePackageManifest, in directory: URL) throws {
        guard manifest.formatVersion == 1 else { throw LocalVoicePackageError.unsupportedVersion }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalVoicePackageError.invalidManifest("名称不能为空")
        }
        guard !manifest.speakers.isEmpty,
              manifest.speakers.allSatisfy({ $0.id >= 0 && !$0.name.isEmpty }),
              Set(manifest.speakers.map(\.id)).count == manifest.speakers.count else {
            throw LocalVoicePackageError.invalidManifest("speakers 必须包含不重复的非负 ID")
        }

        let package = LocalVoicePackage(id: "validation", directoryURL: directory, manifest: manifest)
        let required = [manifest.model, manifest.tokens] + manifest.lexicons
        for path in required {
            let url = try package.fileURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LocalVoicePackageError.missingFile(path)
            }
        }
        if manifest.engine == .kokoro {
            guard let voices = manifest.voices, !voices.isEmpty else {
                throw LocalVoicePackageError.invalidManifest("Kokoro 必须配置 voices")
            }
            let voicesURL = try package.fileURL(for: voices)
            guard FileManager.default.fileExists(atPath: voicesURL.path) else {
                throw LocalVoicePackageError.missingFile(voices)
            }
        }
        if let dataDirectory = manifest.dataDirectory {
            let directoryURL = try package.fileURL(for: dataDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw LocalVoicePackageError.missingFile(dataDirectory)
            }
        }
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func findManifest(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == manifestFileName {
            return url
        }
        return nil
    }
}

struct LocalVoiceSelection: Equatable, Sendable {
    static let separator = "::"
    let packageID: String
    let speakerID: Int

    var identifier: String { "\(packageID)\(Self.separator)\(speakerID)" }

    init(packageID: String, speakerID: Int) {
        self.packageID = packageID
        self.speakerID = speakerID
    }

    init?(identifier: String) {
        let parts = identifier.components(separatedBy: Self.separator)
        guard parts.count == 2, !parts[0].isEmpty, let speakerID = Int(parts[1]) else { return nil }
        self.init(packageID: parts[0], speakerID: speakerID)
    }
}

struct LocalSynthesizedAudio: Sendable {
    let pcmFloat32: Data
    let sampleRate: Double
}

actor LocalVoiceSynthesizer {
    private var bridge: ISLocalTTSBridge?
    private var loadedPackageID: String?

    func unload(packageID: String? = nil) {
        guard packageID == nil || packageID == loadedPackageID else { return }
        bridge = nil
        loadedPackageID = nil
    }

    func synthesize(
        text: String,
        package: LocalVoicePackage,
        speakerID: Int,
        speed: Float
    ) throws -> LocalSynthesizedAudio {
        if loadedPackageID != package.id || bridge == nil {
            bridge = try makeBridge(for: package)
            loadedPackageID = package.id
        }
        guard let bridge else { throw LocalVoicePackageError.invalidManifest("模型未加载") }
        var sampleRate = 0
        let data = try bridge.synthesizeText(
            text,
            speakerID: speakerID,
            speed: speed,
            sampleRate: &sampleRate
        )
        guard sampleRate > 0, !data.isEmpty else {
            throw LocalVoicePackageError.invalidManifest("模型没有生成音频")
        }
        return LocalSynthesizedAudio(pcmFloat32: data, sampleRate: Double(sampleRate))
    }

    private func makeBridge(for package: LocalVoicePackage) throws -> ISLocalTTSBridge {
        let manifest = package.manifest
        let modelPath = try package.fileURL(for: manifest.model).path
        let tokensPath = try package.fileURL(for: manifest.tokens).path
        let voicesPath = try manifest.voices.map { try package.fileURL(for: $0).path }
        let lexiconPath = try manifest.lexicons.map { try package.fileURL(for: $0).path }.joined(separator: ",")
        let dataDirectory = try manifest.dataDirectory.map { try package.fileURL(for: $0).path }
        return try ISLocalTTSBridge(
            engine: manifest.engine.rawValue,
            modelPath: modelPath,
            voicesPath: voicesPath,
            tokensPath: tokensPath,
            lexiconPath: lexiconPath.isEmpty ? nil : lexiconPath,
            dataDirectory: dataDirectory
        )
    }
}

@MainActor
final class LocalSpeechAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackToken = UUID()
    private(set) var isPaused = false
    private(set) var hasScheduledAudio = false

    init() {
        engine.attach(player)
    }

    func play(_ audio: LocalSynthesizedAudio, completion: @escaping () -> Void) throws {
        stop()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ), audio.pcmFloat32.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw LocalVoicePackageError.invalidManifest("音频格式无效")
        }
        let frameCount = audio.pcmFloat32.count / MemoryLayout<Float>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ), let channel = buffer.floatChannelData?[0] else {
            throw LocalVoicePackageError.invalidManifest("无法创建音频缓冲区")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        audio.pcmFloat32.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: channel,
            count: audio.pcmFloat32.count
        ))

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let token = playbackToken
        hasScheduledAudio = true
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackToken == token else { return }
                self.hasScheduledAudio = false
                self.isPaused = false
                completion()
            }
        }
        player.play()
    }

    func pause() {
        guard hasScheduledAudio, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() throws {
        guard hasScheduledAudio, isPaused else { return }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
        isPaused = false
    }

    func stop() {
        playbackToken = UUID()
        player.stop()
        hasScheduledAudio = false
        isPaused = false
    }
}
