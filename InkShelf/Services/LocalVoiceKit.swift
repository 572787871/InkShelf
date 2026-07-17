import AVFoundation
import CryptoKit
import Foundation
import SWCompression
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

struct LocalVoiceCatalogModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let language: String
    let downloadURL: URL
    let downloadBytes: Int64
    let archiveSHA256: String
    let archiveRoot: String
    let licenseName: String
    let licenseURL: URL
    let sourceURL: URL
    let manifest: LocalVoicePackageManifest

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

enum LocalVoiceCatalog {
    static let models: [LocalVoiceCatalogModel] = [
        LocalVoiceCatalogModel(
            id: "kokoro-int8-multi-lang-v1_1",
            name: "Kokoro 中文多音色 · 轻量版",
            summary: "中英双语，55 个中文女声、45 个中文男声和 3 个英文声线。INT8 模型更适合在 iPhone 上长期朗读。",
            language: "中文 / English",
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!,
            downloadBytes: 147_031_220,
            archiveSHA256: "a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6",
            archiveRoot: "kokoro-int8-multi-lang-v1_1",
            licenseName: "Apache-2.0",
            licenseURL: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/blob/main/LICENSE")!,
            sourceURL: URL(string: "https://k2-fsa.github.io/sherpa/onnx/tts/all/Chinese-English/kokoro-multi-lang-v1_1.html")!,
            manifest: LocalVoicePackageManifest(
                name: "Kokoro 中文多音色 · 轻量版",
                engine: .kokoro,
                model: "model.int8.onnx",
                voices: "voices.bin",
                tokens: "tokens.txt",
                lexicons: ["lexicon-us-en.txt", "lexicon-zh.txt"],
                dataDirectory: "espeak-ng-data",
                speakers: kokoroSpeakers
            )
        )
    ]

    private static let kokoroSpeakerNames = [
        "af_maple", "af_sol", "bf_vale",
        "zf_001", "zf_002", "zf_003", "zf_004", "zf_005", "zf_006", "zf_007", "zf_008",
        "zf_017", "zf_018", "zf_019", "zf_021", "zf_022", "zf_023", "zf_024", "zf_026",
        "zf_027", "zf_028", "zf_032", "zf_036", "zf_038", "zf_039", "zf_040", "zf_042",
        "zf_043", "zf_044", "zf_046", "zf_047", "zf_048", "zf_049", "zf_051", "zf_059",
        "zf_060", "zf_067", "zf_070", "zf_071", "zf_072", "zf_073", "zf_074", "zf_075",
        "zf_076", "zf_077", "zf_078", "zf_079", "zf_083", "zf_084", "zf_085", "zf_086",
        "zf_087", "zf_088", "zf_090", "zf_092", "zf_093", "zf_094", "zf_099",
        "zm_009", "zm_010", "zm_011", "zm_012", "zm_013", "zm_014", "zm_015", "zm_016",
        "zm_020", "zm_025", "zm_029", "zm_030", "zm_031", "zm_033", "zm_034", "zm_035",
        "zm_037", "zm_041", "zm_045", "zm_050", "zm_052", "zm_053", "zm_054", "zm_055",
        "zm_056", "zm_057", "zm_058", "zm_061", "zm_062", "zm_063", "zm_064", "zm_065",
        "zm_066", "zm_068", "zm_069", "zm_080", "zm_081", "zm_082", "zm_089", "zm_091",
        "zm_095", "zm_096", "zm_097", "zm_098", "zm_100"
    ]

    private static let kokoroSpeakers = kokoroSpeakerNames.enumerated().map { id, name in
        LocalVoiceSpeaker(id: id, name: displayName(for: name))
    }

    private static func displayName(for rawName: String) -> String {
        if rawName.hasPrefix("zf_") { return "中文女声 \(rawName.dropFirst(3))" }
        if rawName.hasPrefix("zm_") { return "中文男声 \(rawName.dropFirst(3))" }
        switch rawName {
        case "af_maple": return "美式女声 Maple"
        case "af_sol": return "美式女声 Sol"
        case "bf_vale": return "英式女声 Vale"
        default: return rawName
        }
    }
}

enum LocalVoiceCatalogState: Equatable {
    case available
    case downloading(progress: Double)
    case installing
    case installed
    case failed(message: String)
}

struct LocalVoicePackage: Identifiable, Equatable, Sendable {
    let id: String
    let directoryURL: URL
    let manifest: LocalVoicePackageManifest
    let catalogID: String?

    init(
        id: String,
        directoryURL: URL,
        manifest: LocalVoicePackageManifest,
        catalogID: String? = nil
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.manifest = manifest
        self.catalogID = catalogID
    }

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
    case downloadFailed(String)
    case checksumMismatch

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
        case let .downloadFailed(reason): "模型下载失败：\(reason)"
        case .checksumMismatch: "模型文件校验失败，请重新下载"
        }
    }
}

struct LocalVoicePackageStore: Sendable {
    private struct InstalledRecord: Codable {
        let id: String
        let manifest: LocalVoicePackageManifest
        let catalogID: String?
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
            return LocalVoicePackage(
                id: record.id,
                directoryURL: directory,
                manifest: record.manifest,
                catalogID: record.catalogID
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importPackage(from sourceURL: URL) async throws -> LocalVoicePackage {
        try await Task.detached(priority: .userInitiated) {
            try self.importSynchronously(from: sourceURL)
        }.value
    }

    func installCatalogModel(
        _ model: LocalVoiceCatalogModel,
        from archiveURL: URL
    ) async throws -> LocalVoicePackage {
        try await Task.detached(priority: .userInitiated) {
            try self.installCatalogModelSynchronously(model, from: archiveURL)
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

        return try finishInstallation(packageRoot: packageRoot, manifest: manifest, catalogID: nil)
    }

    private func installCatalogModelSynchronously(
        _ model: LocalVoiceCatalogModel,
        from archiveURL: URL
    ) throws -> LocalVoicePackage {
        let actualChecksum = try Self.sha256(of: archiveURL)
        guard actualChecksum.caseInsensitiveCompare(model.archiveSHA256) == .orderedSame else {
            throw LocalVoicePackageError.checksumMismatch
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let stagingURL = rootURL.appendingPathComponent(".store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        var compressed = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        var tarData = try BZip2.decompress(data: compressed)
        compressed = Data()
        let entries = try TarContainer.open(container: tarData)
        tarData = Data()
        guard entries.count <= 20_000 else { throw LocalVoicePackageError.invalidArchive }

        var totalSize: UInt64 = 0
        for entry in entries {
            let path = entry.info.name
            guard Self.isSafeArchivePath(path),
                  path == model.archiveRoot || path.hasPrefix(model.archiveRoot + "/") else {
                throw LocalVoicePackageError.unsafePath
            }
            totalSize += UInt64(entry.data?.count ?? 0)
            guard totalSize <= 2_000_000_000 else { throw LocalVoicePackageError.packageTooLarge }
            let destination = stagingURL.appendingPathComponent(path)
            switch entry.info.type {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .regular, .contiguous:
                guard let data = entry.data else { throw LocalVoicePackageError.invalidArchive }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
            default:
                throw LocalVoicePackageError.unsafePath
            }
        }

        let packageRoot = stagingURL.appendingPathComponent(model.archiveRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalVoicePackageError.invalidArchive
        }
        let manifestData = try JSONEncoder().encode(model.manifest)
        try manifestData.write(
            to: packageRoot.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )
        try validate(model.manifest, in: packageRoot)
        return try finishInstallation(
            packageRoot: packageRoot,
            manifest: model.manifest,
            catalogID: model.id
        )
    }

    private func finishInstallation(
        packageRoot: URL,
        manifest: LocalVoicePackageManifest,
        catalogID: String?
    ) throws -> LocalVoicePackage {
        let identifier = UUID().uuidString.lowercased()
        let destination = rootURL.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.moveItem(at: packageRoot, to: destination)
        let record = InstalledRecord(id: identifier, manifest: manifest, catalogID: catalogID)
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(
            to: destination.appendingPathComponent(Self.installedFileName),
            options: .atomic
        )
        return LocalVoicePackage(
            id: identifier,
            directoryURL: destination,
            manifest: manifest,
            catalogID: catalogID
        )
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
