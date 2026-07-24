import AVFoundation
import CryptoKit
import Foundation
import UIKit

enum VoiceProfileSourceType: String, Codable, CaseIterable, Sendable {
    case recorded
    case imported
    case builtIn

    var title: String {
        switch self {
        case .recorded: "App 内录音"
        case .imported: "文件导入"
        case .builtIn: "内置音色"
        }
    }
}

struct VoiceProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var sourceType: VoiceProfileSourceType
    var referenceAudioRelativePath: String
    var originalAudioRelativePath: String?
    var referenceText: String
    var previewAudioRelativePath: String?
    var originalFilename: String?
    var sampleRate: Double
    var duration: TimeInterval
    var languageCode: String
    var voiceCategory: ZipVoiceProfileGender
    var modelVersion: String
    var isAuthorized: Bool
    let createdAt: Date
    var boundCharacterIds: [String]

    var voiceIdentifier: String { "zipvoice::\(id.uuidString.lowercased())" }
    var gender: ZipVoiceProfileGender {
        get { voiceCategory }
        set { voiceCategory = newValue }
    }
    var audioFileName: String { URL(fileURLWithPath: referenceAudioRelativePath).lastPathComponent }

    init(
        id: UUID = UUID(),
        name: String,
        sourceType: VoiceProfileSourceType,
        referenceAudioRelativePath: String,
        originalAudioRelativePath: String?,
        referenceText: String,
        previewAudioRelativePath: String?,
        originalFilename: String?,
        sampleRate: Double,
        duration: TimeInterval,
        languageCode: String = "zh-CN",
        voiceCategory: ZipVoiceProfileGender,
        modelVersion: String = ZipVoiceCatalog.modelID,
        isAuthorized: Bool,
        createdAt: Date = Date(),
        boundCharacterIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.referenceAudioRelativePath = referenceAudioRelativePath
        self.originalAudioRelativePath = originalAudioRelativePath
        self.referenceText = referenceText
        self.previewAudioRelativePath = previewAudioRelativePath
        self.originalFilename = originalFilename
        self.sampleRate = sampleRate
        self.duration = duration
        self.languageCode = languageCode
        self.voiceCategory = voiceCategory
        self.modelVersion = modelVersion
        self.isAuthorized = isAuthorized
        self.createdAt = createdAt
        self.boundCharacterIds = boundCharacterIds
    }

    /// Decodes the former flat `profiles.json` records during migration.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        sourceType = try values.decodeIfPresent(VoiceProfileSourceType.self, forKey: .sourceType) ?? .imported
        let legacyAudioFileName = try values.decodeIfPresent(String.self, forKey: .audioFileName)
        referenceAudioRelativePath = try values.decodeIfPresent(String.self, forKey: .referenceAudioRelativePath)
            ?? legacyAudioFileName
            ?? "reference.wav"
        originalAudioRelativePath = try values.decodeIfPresent(String.self, forKey: .originalAudioRelativePath)
        referenceText = try values.decode(String.self, forKey: .referenceText)
        previewAudioRelativePath = try values.decodeIfPresent(String.self, forKey: .previewAudioRelativePath)
        originalFilename = try values.decodeIfPresent(String.self, forKey: .originalFilename)
        sampleRate = try values.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 24_000
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode) ?? "zh-CN"
        voiceCategory = try values.decodeIfPresent(ZipVoiceProfileGender.self, forKey: .voiceCategory)
            ?? values.decodeIfPresent(ZipVoiceProfileGender.self, forKey: .gender)
            ?? .unspecified
        modelVersion = try values.decodeIfPresent(String.self, forKey: .modelVersion) ?? ZipVoiceCatalog.modelID
        isAuthorized = try values.decodeIfPresent(Bool.self, forKey: .isAuthorized) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        boundCharacterIds = try values.decodeIfPresent([String].self, forKey: .boundCharacterIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(sourceType, forKey: .sourceType)
        try values.encode(referenceAudioRelativePath, forKey: .referenceAudioRelativePath)
        try values.encodeIfPresent(originalAudioRelativePath, forKey: .originalAudioRelativePath)
        try values.encode(referenceText, forKey: .referenceText)
        try values.encodeIfPresent(previewAudioRelativePath, forKey: .previewAudioRelativePath)
        try values.encodeIfPresent(originalFilename, forKey: .originalFilename)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(duration, forKey: .duration)
        try values.encode(languageCode, forKey: .languageCode)
        try values.encode(voiceCategory, forKey: .voiceCategory)
        try values.encode(modelVersion, forKey: .modelVersion)
        try values.encode(isAuthorized, forKey: .isAuthorized)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(boundCharacterIds, forKey: .boundCharacterIds)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceType, referenceAudioRelativePath, originalAudioRelativePath
        case referenceText, previewAudioRelativePath, originalFilename, sampleRate, duration
        case languageCode, voiceCategory, modelVersion, isAuthorized, createdAt, boundCharacterIds
        case audioFileName, gender
    }
}

typealias ZipVoiceProfile = VoiceProfile

enum VoiceAudioQualityIssue: String, Codable, Identifiable, Sendable {
    case severeClipping
    case lowVolume
    case excessiveSilence

    var id: String { rawValue }
    var message: String {
        switch self {
        case .severeClipping: "录音存在明显爆音，建议降低距离或输入音量后重录。"
        case .lowVolume: "人声音量偏低，建议靠近麦克风重新录制。"
        case .excessiveSilence: "静音占比过高，建议裁掉无声部分或重新录制。"
        }
    }
}

struct VoiceAudioMetadata: Equatable, Sendable {
    let filename: String
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let fileSize: Int64
}

struct ProcessedVoiceAudio: Equatable, Sendable {
    let referenceURL: URL
    let sampleRate: Double
    let duration: TimeInterval
    let effectiveVoiceDuration: TimeInterval
    let issues: [VoiceAudioQualityIssue]
}

enum LocalVoiceError: LocalizedError, Equatable {
    case authorizationRequired
    case microphoneDenied
    case recordingFailed(String)
    case inaccessibleAudio
    case unsupportedAudio
    case invalidTrimRange
    case requiresTrimming(TimeInterval)
    case insufficientVoice(TimeInterval)
    case emptyReferenceText
    case modelSampleRateUnavailable
    case profileNotFound
    case cannotRemoveBuiltIn

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: "请先确认声音授权后再创建模拟音色"
        case .microphoneDenied: "麦克风权限已被拒绝，请在系统“设置”中允许墨架访问麦克风"
        case let .recordingFailed(message): "录音失败：\(message)"
        case .inaccessibleAudio: "无法访问所选音频文件"
        case .unsupportedAudio: "无法解码该音频，请选择 WAV、M4A、MP3、AAC 或 CAF 文件"
        case .invalidTrimRange: "裁剪范围无效，请至少保留 3 秒"
        case let .requiresTrimming(duration): "音频时长为 \(Self.durationText(duration))，请裁剪到 30 秒以内"
        case let .insufficientVoice(duration): "有效人声只有 \(Self.durationText(duration))，至少需要 3 秒"
        case .emptyReferenceText: "参考文字不能为空，并且必须与录音内容一致"
        case .modelSampleRateUnavailable: "无法读取当前 ZipVoice 模型的采样率"
        case .profileNotFound: "找不到该模拟音色文件"
        case .cannotRemoveBuiltIn: "内置音色不能删除"
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.1f 秒", max(0, duration))
    }
}

enum LocalVoiceGenerationState: Equatable {
    case idle
    case loadingModel
    case processingReference
    case generatingPreview
    case completed
    case failed(String)

    var title: String? {
        switch self {
        case .idle: nil
        case .loadingModel: "正在加载模型"
        case .processingReference: "正在处理参考音频"
        case .generatingPreview: "正在生成试听"
        case .completed: "生成完成"
        case let .failed(message): message
        }
    }

    var isWorking: Bool {
        switch self {
        case .loadingModel, .processingReference, .generatingPreview: true
        case .idle, .completed, .failed: false
        }
    }
}

struct AudioPreprocessor: Sendable {
    static let maximumDuration: TimeInterval = 30
    static let minimumEffectiveVoiceDuration: TimeInterval = 3

    func inspect(_ sourceURL: URL) throws -> VoiceAudioMetadata {
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw LocalVoiceError.inaccessibleAudio
        }
        do {
            let file = try AVAudioFile(forReading: sourceURL)
            let format = file.processingFormat
            let duration = Double(file.length) / max(1, format.sampleRate)
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return .init(
                filename: sourceURL.lastPathComponent,
                duration: duration,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                fileSize: size
            )
        } catch let error as LocalVoiceError {
            throw error
        } catch {
            throw LocalVoiceError.unsupportedAudio
        }
    }

    func process(
        sourceURL: URL,
        destinationURL: URL,
        targetSampleRate: Double,
        trimRange: ClosedRange<TimeInterval>? = nil
    ) throws -> ProcessedVoiceAudio {
        guard targetSampleRate > 0 else { throw LocalVoiceError.modelSampleRateUnavailable }
        let metadata = try inspect(sourceURL)
        let selectedRange: ClosedRange<TimeInterval>
        if let trimRange {
            selectedRange = trimRange
        } else {
            guard metadata.duration <= Self.maximumDuration else {
                throw LocalVoiceError.requiresTrimming(metadata.duration)
            }
            selectedRange = 0...metadata.duration
        }
        guard selectedRange.lowerBound >= 0,
              selectedRange.upperBound <= metadata.duration + 0.05,
              selectedRange.upperBound - selectedRange.lowerBound >= Self.minimumEffectiveVoiceDuration else {
            throw LocalVoiceError.invalidTrimRange
        }

        let samples = try decodeMonoSamples(
            sourceURL,
            targetSampleRate: targetSampleRate,
            trimRange: selectedRange
        )
        guard !samples.isEmpty else { throw LocalVoiceError.unsupportedAudio }
        let analysis = analyze(samples: samples, sampleRate: targetSampleRate)
        guard analysis.effectiveDuration >= Self.minimumEffectiveVoiceDuration else {
            throw LocalVoiceError.insufficientVoice(analysis.effectiveDuration)
        }
        let paddedStart = max(0, analysis.firstSignalFrame - Int(targetSampleRate * 0.08))
        let paddedEnd = min(samples.count, analysis.lastSignalFrame + Int(targetSampleRate * 0.12) + 1)
        var trimmed = Array(samples[paddedStart..<paddedEnd])
        normalize(&trimmed)
        try Self.writePCM16WAV(samples: trimmed, sampleRate: targetSampleRate, to: destinationURL)
        return .init(
            referenceURL: destinationURL,
            sampleRate: targetSampleRate,
            duration: Double(trimmed.count) / targetSampleRate,
            effectiveVoiceDuration: analysis.effectiveDuration,
            issues: analysis.issues
        )
    }

    private func decodeMonoSamples(
        _ sourceURL: URL,
        targetSampleRate: Double,
        trimRange: ClosedRange<TimeInterval>
    ) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: sourceURL)
            let inputFormat = file.processingFormat
            let startFrame = AVAudioFramePosition((trimRange.lowerBound * inputFormat.sampleRate).rounded(.down))
            let requestedFrames = AVAudioFrameCount(
                ((trimRange.upperBound - trimRange.lowerBound) * inputFormat.sampleRate).rounded(.up)
            )
            guard requestedFrames > 0,
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: requestedFrames),
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: targetSampleRate,
                    channels: 1,
                    interleaved: false
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw LocalVoiceError.unsupportedAudio
            }
            file.framePosition = min(startFrame, file.length)
            try file.read(into: inputBuffer, frameCount: min(requestedFrames, AVAudioFrameCount(file.length - file.framePosition)))
            let ratio = targetSampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw LocalVoiceError.unsupportedAudio
            }
            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                if suppliedInput {
                    statusPointer.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                statusPointer.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw conversionError }
            guard status != .error,
                  outputBuffer.frameLength > 0,
                  let channel = outputBuffer.floatChannelData?[0] else {
                throw LocalVoiceError.unsupportedAudio
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        } catch let error as LocalVoiceError {
            throw error
        } catch {
            throw LocalVoiceError.unsupportedAudio
        }
    }

    private func analyze(samples: [Float], sampleRate: Double) -> (
        firstSignalFrame: Int,
        lastSignalFrame: Int,
        effectiveDuration: TimeInterval,
        issues: [VoiceAudioQualityIssue]
    ) {
        let finite = samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
        let meanSquare = finite.reduce(Double(0)) { $0 + Double($1 * $1) } / Double(max(1, finite.count))
        let rms = sqrt(meanSquare)
        let windowSize = max(1, Int(sampleRate * 0.02))
        var activeFrames = 0
        var firstSignalFrame: Int?
        var lastSignalFrame: Int?
        for start in stride(from: 0, to: finite.count, by: windowSize) {
            let end = min(finite.count, start + windowSize)
            let windowEnergy = finite[start..<end].reduce(Double(0)) { $0 + Double($1 * $1) }
            let windowRMS = sqrt(windowEnergy / Double(max(1, end - start)))
            if windowRMS >= 0.006 {
                activeFrames += end - start
                firstSignalFrame = firstSignalFrame ?? start
                lastSignalFrame = end - 1
            }
        }
        let first = firstSignalFrame ?? 0
        let last = lastSignalFrame ?? max(0, finite.count - 1)
        let clippingRatio = Double(finite.lazy.filter { abs($0) >= 0.985 }.count) / Double(max(1, finite.count))
        let silenceRatio = 1 - Double(activeFrames) / Double(max(1, finite.count))
        var issues: [VoiceAudioQualityIssue] = []
        if clippingRatio > 0.005 { issues.append(.severeClipping) }
        if rms < 0.012 { issues.append(.lowVolume) }
        if silenceRatio > 0.6 { issues.append(.excessiveSilence) }
        return (first, last, Double(activeFrames) / sampleRate, issues)
    }

    private func normalize(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        for index in samples.indices { samples[index] -= mean }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard rms > 0.000_001, peak > 0.000_001 else { return }
        let targetRMS = Float(pow(10, -20.0 / 20.0))
        let gain = min(4, min(targetRMS / rms, 0.95 / peak))
        for index in samples.indices { samples[index] *= gain }
    }

    private static func writePCM16WAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func appendASCII(_ text: String) { wav.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        let rate = UInt32(targetedSampleRate(sampleRate))
        appendASCII("RIFF")
        append(UInt32(36 + pcm.count))
        appendASCII("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        appendASCII("data")
        append(UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: url, options: .atomic)
    }

    private static func targetedSampleRate(_ value: Double) -> Int {
        max(1, Int(value.rounded()))
    }
}

@MainActor
final class LocalVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case stopped
        case interrupted
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var recordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeLifecycle()
    }

    deinit {
        meterTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                if allowed {
                    self.startOrResume()
                } else {
                    self.state = .failed(LocalVoiceError.microphoneDenied.localizedDescription)
                }
            }
        }
    }

    func startOrResume() {
        if let recorder, state == .paused || state == .interrupted {
            do {
                try configureAudioSession()
                guard recorder.record() else { throw LocalVoiceError.recordingFailed("录音设备没有开始工作") }
                state = .recording
                startMetering()
            } catch {
                state = .failed(error.localizedDescription)
            }
            return
        }
        do {
            try configureAudioSession()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InkShelfVoiceDrafts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording-\(UUID().uuidString.lowercased()).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
                AVEncoderBitRateKey: 192_000
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw LocalVoiceError.recordingFailed("录音设备没有开始工作")
            }
            self.recorder = recorder
            recordingURL = url
            duration = 0
            level = 0
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        stopMetering()
    }

    func stop() {
        guard recorder != nil else { return }
        let recordedDuration = recorder?.currentTime ?? duration
        recorder?.stop()
        duration = max(duration, recordedDuration)
        state = .stopped
        stopMetering()
        deactivateAudioSession()
    }

    func reset() {
        stop()
        if let recordingURL, FileManager.default.fileExists(atPath: recordingURL.path) {
            do {
                try FileManager.default.removeItem(at: recordingURL)
            } catch {
                state = .failed("无法清理旧录音：\(error.localizedDescription)")
                return
            }
        }
        recorder = nil
        recordingURL = nil
        duration = 0
        level = 0
        state = .idle
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finishedDuration = recorder.currentTime
        Task { @MainActor [weak self] in
            guard let self else { return }
            stopMetering()
            duration = max(duration, finishedDuration)
            state = flag ? .stopped : .failed("录音文件没有正确写入")
            deactivateAudioSession()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "音频编码失败"
        Task { @MainActor [weak self] in
            guard let self else { return }
            stopMetering()
            state = .failed(message)
            deactivateAudioSession()
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            if case .failed = state { return }
            state = .failed("无法恢复音频会话：\(error.localizedDescription)")
        }
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.duration = recorder.currentTime
                let power = max(-60, recorder.averagePower(forChannel: 0))
                self.level = min(1, max(0, Double((power + 60) / 60)))
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.recorder?.pause()
                self.state = .interrupted
                self.stopMetering()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.state == .recording,
                      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
                self.recorder?.pause()
                self.state = .interrupted
                self.stopMetering()
            }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard state == .recording else { return }
            recorder?.pause()
            state = .interrupted
            stopMetering()
        case .ended:
            state = .paused
        @unknown default:
            state = .paused
        }
    }
}

@MainActor
final class LocalVoiceAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) throws {
        if isPlaying {
            stop()
            return
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { throw LocalVoiceError.recordingFailed("音频无法播放") }
        self.player = player
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.isPlaying = false
        }
    }
}

struct ZipVoiceAudioDiskCache: Sendable {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZipVoiceAudio", isDirectory: true)
        }
    }

    func data(profileID: UUID, key: String) throws -> Data? {
        let url = cacheURL(profileID: profileID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func store(_ data: Data, profileID: UUID, key: String) throws {
        let directory = rootURL.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL(profileID: profileID, key: key), options: .atomic)
    }

    func invalidate(profileID: UUID) throws {
        let directory = rootURL.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func key(text: String, speed: Double, modelVersion: String) -> String {
        let digest = SHA256.hash(data: Data("\(modelVersion)|\(speed)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".wav"
    }

    private func cacheURL(profileID: UUID, key: String) -> URL {
        rootURL
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(key)
    }
}
