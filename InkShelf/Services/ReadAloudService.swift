import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum ReadAloudState: Equatable {
    case unavailable
    case ready
    case playing(sentence: Int)
    case paused(sentence: Int)
    case failed(message: String)
}

struct ReadAloudBookContext: Equatable {
    let id: UUID
    let title: String
    let author: String
    let coverData: Data?
    let coverStyle: Int
}

enum NowPlayingArtworkRenderer {
    static let preferredDimension: CGFloat = 1024

    static func squareImage(from source: UIImage, dimension: CGFloat) -> UIImage {
        let side = max(1, dimension.rounded(.up))
        guard source.size.width > 0, source.size.height > 0 else { return source }

        let scale = max(side / source.size.width, side / source.size.height)
        let drawSize = CGSize(
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let drawRect = CGRect(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { _ in
            source.draw(in: drawRect)
        }
    }
}

struct ReadAloudTimeline: Equatable {
    struct Position: Equatable {
        let pageIndex: Int
        let utf16Location: Int
    }

    static let estimatedUTF16UnitsPerSecond = 4.2

    let pageStarts: [Int]
    let pageLengths: [Int]
    let totalUnits: Int

    init(pages: [ReaderPage]) {
        var starts: [Int] = []
        var lengths: [Int] = []
        var cursor = 0
        for page in pages {
            let textLength = (page.text as NSString).length
            starts.append(cursor)
            lengths.append(textLength)
            cursor += max(1, textLength)
        }
        pageStarts = starts
        pageLengths = lengths
        totalUnits = cursor
    }

    var duration: TimeInterval {
        guard totalUnits > 0 else { return 0 }
        return Double(totalUnits) / Self.estimatedUTF16UnitsPerSecond
    }

    func elapsedTime(pageIndex: Int, utf16Location: Int) -> TimeInterval {
        guard pageStarts.indices.contains(pageIndex) else { return 0 }
        let localLength = pageLengths[pageIndex]
        let localPosition = min(max(0, utf16Location), localLength)
        return min(duration, Double(pageStarts[pageIndex] + localPosition) / Self.estimatedUTF16UnitsPerSecond)
    }

    func position(at elapsedTime: TimeInterval) -> Position? {
        guard !pageStarts.isEmpty else { return nil }
        let targetUnit = min(
            max(0, Int((elapsedTime * Self.estimatedUTF16UnitsPerSecond).rounded())),
            max(0, totalUnits - 1)
        )
        var lowerBound = 0
        var upperBound = pageStarts.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if pageStarts[middle] <= targetUnit {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let pageIndex = max(0, lowerBound - 1)
        let localPosition = min(
            max(0, targetUnit - pageStarts[pageIndex]),
            pageLengths[pageIndex]
        )
        return Position(pageIndex: pageIndex, utf16Location: localPosition)
    }
}

struct ReadAloudChapterNavigator {
    static func currentChapterPageIndices(in pages: [ReaderPage], from currentIndex: Int) -> [Int] {
        guard pages.indices.contains(currentIndex) else { return [] }
        let currentChapter = pages[currentIndex].location.chapterIndex
        return pages.indices.filter { pages[$0].location.chapterIndex == currentChapter }
    }

    static func nextChapterPageIndex(in pages: [ReaderPage], from currentIndex: Int) -> Int? {
        guard pages.indices.contains(currentIndex) else { return nil }
        let currentChapter = pages[currentIndex].location.chapterIndex
        return pages.indices.first {
            $0 > currentIndex && pages[$0].location.chapterIndex != currentChapter
        }
    }

    static func previousChapterPageIndex(in pages: [ReaderPage], from currentIndex: Int) -> Int? {
        guard pages.indices.contains(currentIndex) else { return nil }
        let currentChapter = pages[currentIndex].location.chapterIndex
        guard let previousPageIndex = pages.indices.last(where: {
            $0 < currentIndex && pages[$0].location.chapterIndex != currentChapter
        }) else { return nil }
        let previousChapter = pages[previousPageIndex].location.chapterIndex
        return pages.indices.first { pages[$0].location.chapterIndex == previousChapter }
    }
}

/// A stable UTF-16 text plan shared by speech and highlighting.
/// UIKit text ranges are UTF-16 based, so keeping one coordinate system prevents
/// Chinese punctuation and emoji from shifting the highlight.
struct ReadAloudTextPlan: Equatable {
    struct Sentence: Equatable {
        let text: String
        let range: NSRange
        let speaker: ReadAloudSpeaker
    }

    let sentences: [Sentence]

    init(text: String, speakers: [ReadAloudSpeaker]? = nil) {
        sentences = Self.units(in: text, option: .bySentences).enumerated().map { index, range in
            Sentence(
                text: (text as NSString).substring(with: range),
                range: range,
                speaker: speakers.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .narrator
            )
        }
    }

    func sentenceIndex(atOrAfterUTF16Location location: Int) -> Int? {
        guard !sentences.isEmpty else { return nil }
        let safeLocation = max(0, location)
        return sentences.firstIndex { NSMaxRange($0.range) > safeLocation }
            ?? sentences.indices.last
    }

    private static func units(
        in text: String,
        option: String.EnumerationOptions
    ) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        var ranges: [NSRange] = []

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [option, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let rawRange = NSRange(substringRange, in: text)
            let first = nsText.rangeOfCharacter(from: nonWhitespace, options: [], range: rawRange)
            guard first.location != NSNotFound else { return }
            let last = nsText.rangeOfCharacter(from: nonWhitespace, options: .backwards, range: rawRange)
            guard last.location != NSNotFound else { return }
            ranges.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        }
        return ranges
    }
}

struct ReadAloudSpeechPosition: Hashable, Sendable {
    let location: ReaderPageLocation
    let sentenceIndex: Int
}

struct ReadAloudCrossPageContinuation: Equatable, Sendable {
    let source: ReadAloudSpeechPosition
    let target: ReadAloudSpeechPosition
    let boundaryFraction: Double
}

struct ReadAloudSpeechRequest: Equatable, Sendable {
    let position: ReadAloudSpeechPosition
    let text: String
    let speaker: ReadAloudSpeaker
    let continuation: ReadAloudCrossPageContinuation?
}

enum ReadAloudPageBoundary {
    private static let terminalPunctuation = CharacterSet(charactersIn: "。！？!?；;…")
    private static let trailingClosers = CharacterSet(charactersIn: "\"'”’」』】）》〉〕）]}")

    static func shouldJoin(lastFragment: String, nextFragment: String) -> Bool {
        guard !lastFragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nextFragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var scalarView = Array(lastFragment.unicodeScalars)
        while let last = scalarView.last,
              CharacterSet.whitespacesAndNewlines.contains(last) || trailingClosers.contains(last) {
            scalarView.removeLast()
        }
        guard let last = scalarView.last else { return false }
        return !terminalPunctuation.contains(last)
    }
}

/// Automatic audiobook session with optional AI casting and interchangeable
/// cloud or on-device speech generation.
@MainActor
final class ReadAloudService: NSObject, ObservableObject {
    private static let settingsDefaultsKey = "readAloudSettings"

    @Published private(set) var state: ReadAloudState = .unavailable
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var currentSentenceRange: NSRange?
    @Published private(set) var currentPageLocation: ReaderPageLocation?
    @Published private(set) var bookContext: ReadAloudBookContext?
    @Published private(set) var visibleReaderBookID: UUID?
    @Published private(set) var applicationIsActive = true
    @Published private(set) var playbackRequested = false
    @Published private(set) var connectionState = AudiobookConnectionState.idle
    @Published private(set) var zipVoiceInstallState = ZipVoiceInstallState.notInstalled
    @Published private(set) var zipVoiceProfiles: [ZipVoiceProfile] = []
    @Published private(set) var localRoleModelState = LocalRoleModelState.notInstalled
    @Published var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            AudiobookCredentialStore.saveAPIKey(apiKey)
            connectionState = .idle
        }
    }
    @Published var settings: ReadAloudSettings {
        didSet {
            if oldValue != settings {
                connectionState = .idle
                prefetchTask?.cancel()
                prefetchTask = nil
                prefetchedAudio = nil
                prefetchTarget = nil
                waitingForPrefetchPosition = nil
            }
            if oldValue.roleDetectionMode != settings.roleDetectionMode
                || oldValue.analysisProvider != settings.analysisProvider
                || oldValue.analysisBaseURL != settings.analysisBaseURL
                || oldValue.analysisModel != settings.analysisModel
                || oldValue.localRoleModel != settings.localRoleModel {
                aiAnalyzedRoleChapters.removeAll()
                localAnalyzedRoleChapters.removeAll()
                refreshLocalRoleModelState()
            }
            persistSettings()
        }
    }

    var onPageFinished: (() -> Void)?
    var isPlaying: Bool { playbackRequested && hasSession }
    var hasSession: Bool { currentPageLocation != nil && !plan.sentences.isEmpty }
    var shouldShowPersistentFloater: Bool {
        hasSession && bookContext?.id != visibleReaderBookID
    }

    private let speechClient = AudiobookSpeechClient()
    private let aiRoleClient = AICharacterRoleClient()
    private let localRoleModel = LocalNovelRoleModel()
    private let zipVoiceStore = ZipVoiceStore()
    private let zipVoiceSynthesizer = ZipVoiceSynthesizer()
    private let speechPlayer = AudiobookAudioPlayer()
    private let previewPlayer = AudiobookAudioPlayer()
    private var plan = ReadAloudTextPlan(text: "")
    private var rolePlan = ReadAloudRolePlan.empty
    private var analyzedRoleChapters: Set<Int> = []
    private var synthesisTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedAudio: (request: ReadAloudSpeechRequest, data: Data)?
    private var prefetchTarget: ReadAloudSpeechRequest?
    private var waitingForPrefetchPosition: ReadAloudSpeechPosition?
    private var activeRequest: ReadAloudSpeechRequest?
    private var roleAnalysisTask: Task<Void, Never>?
    private var aiAnalyzedRoleChapters: Set<Int> = []
    private var localAnalyzedRoleChapters: Set<Int> = []
    private var modelDownloadTask: Task<Void, Never>?
    private var roleModelDownloadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var playbackToken = UUID()
    private var previewToken = UUID()
    private var activeSentenceIndex: Int?
    private var nextSentenceIndex = 0
    private var sessionPages: [ReaderPage] = []
    private var sessionPageIndex: Int?
    private var sessionChapterIndices: [Int] = []
    private var currentChapterPageIndices: [Int] = []
    private var timelineChapterIndex: Int?
    private var timeline = ReadAloudTimeline(pages: [])
    private var nowPlayingAnchorElapsed: TimeInterval = 0
    private var nowPlayingAnchorDate: Date?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var interruptionObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false

    override init() {
        apiKey = AudiobookCredentialStore.loadAPIKey()
        settings = Self.loadSettings()
        super.init()
        zipVoiceProfiles = zipVoiceStore.profiles()
        zipVoiceInstallState = zipVoiceStore.modelPaths() == nil ? .notInstalled : .installed
        refreshLocalRoleModelState()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        configureRemoteCommands()
        observeAudioInterruptions()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func readerDidAppear(bookID: UUID) {
        visibleReaderBookID = bookID
    }

    func readerDidDisappear(bookID: UUID) {
        guard visibleReaderBookID == bookID else { return }
        visibleReaderBookID = nil
        onPageFinished = nil
    }

    func applicationActivityChanged(isActive: Bool) {
        applicationIsActive = isActive
    }

    func isSession(for bookID: UUID) -> Bool {
        hasSession && bookContext?.id == bookID
    }

    var canStartReading: Bool {
        let synthesisReady: Bool
        switch settings.provider {
        case .localZipVoice:
            synthesisReady = zipVoiceStore.modelPaths() != nil && !zipVoiceProfiles.isEmpty
        case .mimo, .openAICompatible:
            synthesisReady = networkCredentialsReady
                && !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let analysisReady: Bool
        switch settings.roleDetectionMode {
        case .localRules:
            analysisReady = true
        case .localModel:
            analysisReady = LocalNovelRoleModel.isInstalled(settings.localRoleModel)
        case .ai:
            analysisReady = networkCredentialsReady
                && !settings.analysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return synthesisReady && analysisReady
    }

    var availableVoiceChoices: [AudiobookVoiceChoice] {
        if settings.provider == .localZipVoice {
            return zipVoiceProfiles.map { .init(id: $0.voiceIdentifier, name: $0.name) }
        }
        return AudiobookVoiceDirector.choices(for: settings.provider)
    }

    private var networkCredentialsReady: Bool {
        settings.allowsTextUpload
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyProviderDefaults(for provider: ReadAloudProvider) {
        settings.provider = provider
        settings.baseURL = provider.defaultBaseURL
        settings.model = provider.defaultModel
        if !availableVoiceChoices.contains(where: { $0.id == settings.selectedVoiceIdentifier }) {
            settings.selectedVoiceIdentifier = ""
        }
        if !availableVoiceChoices.contains(where: { $0.id == settings.narratorVoiceIdentifier }) {
            settings.narratorVoiceIdentifier = ""
        }
        if !availableVoiceChoices.contains(where: { $0.id == settings.thirdPersonVoiceIdentifier }) {
            settings.thirdPersonVoiceIdentifier = ""
        }
        if !availableVoiceChoices.contains(where: { $0.id == settings.characterVoiceIdentifier }) {
            settings.characterVoiceIdentifier = ""
        }
        connectionState = .idle
    }

    func applyAnalysisProviderDefaults(for provider: ReadAloudAIProvider) {
        settings.analysisProvider = provider
        settings.analysisBaseURL = provider.defaultBaseURL
        settings.analysisModel = provider.defaultModel
        connectionState = .idle
    }

    func refreshLocalRoleModelState() {
        localRoleModelState = LocalNovelRoleModel.isInstalled(settings.localRoleModel)
            ? .installed
            : .notInstalled
    }

    func downloadLocalRoleModel() {
        guard roleModelDownloadTask == nil else { return }
        let variant = settings.localRoleModel
        localRoleModelState = .downloading(progress: 0)
        roleModelDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await localRoleModel.download(variant) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.settings.localRoleModel == variant else { return }
                        self.localRoleModelState = .downloading(progress: progress)
                    }
                }
                try Task.checkCancellation()
                localRoleModelState = .installed
            } catch is CancellationError {
                refreshLocalRoleModelState()
            } catch {
                localRoleModelState = .failed(error.localizedDescription)
            }
            roleModelDownloadTask = nil
        }
    }

    func cancelLocalRoleModelDownload() {
        roleModelDownloadTask?.cancel()
        roleModelDownloadTask = nil
        refreshLocalRoleModelState()
    }

    func removeLocalRoleModel() async throws {
        let variant = settings.localRoleModel
        roleModelDownloadTask?.cancel()
        roleModelDownloadTask = nil
        try await localRoleModel.remove(variant)
        localAnalyzedRoleChapters.removeAll()
        refreshLocalRoleModelState()
    }

    func downloadZipVoiceModel() {
        guard modelDownloadTask == nil else { return }
        zipVoiceInstallState = .downloading(progress: 0)
        modelDownloadTask = Task { [weak self] in
            guard let self else { return }
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZipVoiceDownloads", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let archive = try await download(
                    ZipVoiceCatalog.archiveURL,
                    to: cache.appendingPathComponent("model.tar.bz2")
                )
                zipVoiceInstallState = .downloading(progress: 0.68)
                let vocoder = try await download(
                    ZipVoiceCatalog.vocoderURL,
                    to: cache.appendingPathComponent("vocos_24khz.onnx")
                )
                try Task.checkCancellation()
                zipVoiceInstallState = .installing
                try await zipVoiceStore.installModel(archiveURL: archive, vocoderURL: vocoder)
                try? FileManager.default.removeItem(at: cache)
                zipVoiceInstallState = .installed
            } catch is CancellationError {
                zipVoiceInstallState = zipVoiceStore.modelPaths() == nil ? .notInstalled : .installed
            } catch {
                zipVoiceInstallState = .failed(error.localizedDescription)
            }
            modelDownloadTask = nil
        }
    }

    func cancelZipVoiceDownload() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        zipVoiceInstallState = zipVoiceStore.modelPaths() == nil ? .notInstalled : .installed
    }

    func addZipVoiceProfile(
        from url: URL,
        name: String,
        gender: ZipVoiceProfileGender,
        referenceText: String
    ) async throws {
        _ = try await zipVoiceStore.addProfile(
            from: url,
            name: name,
            gender: gender,
            referenceText: referenceText
        )
        zipVoiceProfiles = zipVoiceStore.profiles()
    }

    func removeZipVoiceProfile(_ profile: ZipVoiceProfile) throws {
        try zipVoiceStore.removeProfile(profile)
        zipVoiceProfiles = zipVoiceStore.profiles()
        if settings.selectedVoiceIdentifier == profile.voiceIdentifier {
            settings.selectedVoiceIdentifier = ""
        }
    }

    private func download(_ source: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZipVoiceError.downloadFailed("服务器没有返回有效文件")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func testConnection() {
        guard connectionState != .testing else { return }
        stopVoicePreview()
        connectionState = .testing
        let configuration = settings
        let key = apiKey
        let token = UUID()
        previewToken = token
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await synthesizeAudio(
                    text: "夜色渐深，故事从这里缓缓开始。",
                    speaker: .narrator,
                    configuration: configuration,
                    key: key
                )
                try Task.checkCancellation()
                guard previewToken == token else { return }
                guard configureAudioSession() else { return }
                previewTask = nil
                connectionState = .connected
                try previewPlayer.play(audio) { }
            } catch is CancellationError {
                guard previewToken == token else { return }
                previewTask = nil
                connectionState = .idle
            } catch {
                guard previewToken == token else { return }
                previewTask = nil
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    func startSession(
        book: NovelBook,
        pages: [ReaderPage],
        location: ReaderPageLocation
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.location == location }) else {
            state = .failed(message: "当前朗读页面不存在")
            return
        }
        sessionPages = pages
        sessionPageIndex = pageIndex
        rolePlan = .empty
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
        localAnalyzedRoleChapters.removeAll()
        sessionChapterIndices = chapterIndices(in: pages)
        rebuildCurrentChapterTimeline(force: true)
        let context = ReadAloudBookContext(
            id: book.id,
            title: book.title,
            author: book.author,
            coverData: book.coverData,
            coverStyle: book.coverStyle
        )
        bookContext = context
        nowPlayingArtwork = makeNowPlayingArtwork(for: context)
        setPage(
            text: pages[pageIndex].text,
            location: pages[pageIndex].location
        )
        analyzeCurrentChapterThenPlayIfNeeded()
    }

    func moveSession(to location: ReaderPageLocation, continuePlaying: Bool) {
        _ = updateSession(
            to: location,
            continuePlaying: continuePlaying,
            stoppingCurrentSpeech: true
        )
    }

    @discardableResult
    func advanceSession(to location: ReaderPageLocation, continuePlaying: Bool) -> Bool {
        updateSession(
            to: location,
            continuePlaying: continuePlaying,
            stoppingCurrentSpeech: false
        )
    }

    private func updateSession(
        to location: ReaderPageLocation,
        continuePlaying: Bool,
        stoppingCurrentSpeech: Bool
    ) -> Bool {
        guard let pageIndex = sessionPages.firstIndex(where: { $0.location == location }) else {
            return false
        }
        sessionPageIndex = pageIndex
        let page = sessionPages[pageIndex]
        setPage(
            text: page.text,
            location: page.location,
            stoppingCurrentSpeech: stoppingCurrentSpeech
        )
        if continuePlaying {
            analyzeCurrentChapterThenPlayIfNeeded()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
        return true
    }

    func continueAfterPageFinishedWithoutTurningReader() {
        guard playbackRequested else { return }
        advanceInBackground()
    }

    func refreshSessionPages(_ pages: [ReaderPage], for bookID: UUID) {
        guard bookContext?.id == bookID, let currentPageLocation else { return }
        sessionPages = pages
        rolePlan = .empty
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
        localAnalyzedRoleChapters.removeAll()
        sessionChapterIndices = chapterIndices(in: pages)
        sessionPageIndex = pages.firstIndex { $0.location == currentPageLocation }
            ?? pages.lastIndex {
                $0.location.chapterIndex == currentPageLocation.chapterIndex
                    && $0.location.pageIndex <= currentPageLocation.pageIndex
            }
            ?? pages.firstIndex {
                $0.location.chapterIndex == currentPageLocation.chapterIndex
            }
        rebuildCurrentChapterTimeline(force: true)
        synchronizeNowPlayingAnchorToCurrentSentence()
        updateRemoteCommandAvailability()
        updateNowPlayingInfo()
    }

    func setPage(
        text: String,
        location: ReaderPageLocation,
        startAtUTF16Location: Int = 0,
        stoppingCurrentSpeech: Bool = true
    ) {
        if stoppingCurrentSpeech {
            cancelSpeechPlayback()
        }
        ensureRolePlan(forChapter: location.chapterIndex)
        plan = ReadAloudTextPlan(
            text: text,
            speakers: rolePlan.speakers(for: location)
        )
        currentPageLocation = location

        guard let startIndex = plan.sentenceIndex(atOrAfterUTF16Location: startAtUTF16Location) else {
            playbackRequested = false
            currentSentenceIndex = 0
            currentSentenceRange = nil
            currentPageLocation = nil
            state = .failed(message: "当前页面没有可朗读的正文")
            return
        }
        currentSentenceIndex = startIndex
        currentSentenceRange = plan.sentences[startIndex].range
        nextSentenceIndex = startIndex
        state = .ready
        rebuildCurrentChapterTimeline()
        synchronizeNowPlayingAnchorToCurrentSentence()
        updateRemoteCommandAvailability()
    }

    func play() {
        guard hasSession else { return }
        guard canStartReading else {
            playbackRequested = false
            state = .failed(message: "请先在主页右上角设置中完成朗读服务配置")
            updateNowPlayingInfo()
            return
        }
        stopVoicePreview()
        playbackRequested = true
        guard roleAnalysisTask == nil else {
            state = .ready
            updateNowPlayingInfo()
            return
        }
        guard configureAudioSession() else {
            playbackRequested = false
            updateNowPlayingInfo()
            return
        }
        if speechPlayer.isPaused {
            do {
                try speechPlayer.resume()
                state = .playing(sentence: currentSentenceIndex)
                nowPlayingAnchorDate = .now
                updateNowPlayingInfo()
            } catch {
                playbackRequested = false
                state = .failed(message: "无法恢复朗读音频：\(error.localizedDescription)")
                updateNowPlayingInfo()
            }
            return
        }
        guard synthesisTask == nil, !speechPlayer.hasScheduledAudio else {
            state = .playing(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
            return
        }
        enqueueSentence(at: nextSentenceIndex)
        state = .playing(sentence: currentSentenceIndex)
        nowPlayingAnchorDate = .now
        updateNowPlayingInfo()
    }

    func pause() {
        freezeNowPlayingPosition()
        playbackRequested = false
        if speechPlayer.hasScheduledAudio {
            speechPlayer.pause()
        } else if synthesisTask != nil {
            playbackToken = UUID()
            synthesisTask?.cancel()
            synthesisTask = nil
            activeSentenceIndex = nil
        }
        state = .paused(sentence: currentSentenceIndex)
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        if playbackRequested {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        resetSession(stoppingSpeech: true)
    }

    /// Finishes a naturally completed book after the final PCM buffer callback.
    func finishAtEndOfBook() {
        resetSession(stoppingSpeech: false)
    }

    func stopVoicePreview() {
        previewToken = UUID()
        previewTask?.cancel()
        previewTask = nil
        previewPlayer.stop()
        if !hasSession { deactivateAudioSession() }
    }

    private func resetSession(stoppingSpeech: Bool) {
        playbackRequested = false
        stopVoicePreview()
        if stoppingSpeech {
            cancelSpeechPlayback()
        }
        plan = ReadAloudTextPlan(text: "")
        rolePlan = .empty
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
        localAnalyzedRoleChapters.removeAll()
        roleAnalysisTask?.cancel()
        roleAnalysisTask = nil
        currentSentenceIndex = 0
        currentSentenceRange = nil
        currentPageLocation = nil
        bookContext = nil
        nextSentenceIndex = 0
        sessionPages = []
        sessionPageIndex = nil
        sessionChapterIndices = []
        currentChapterPageIndices = []
        timelineChapterIndex = nil
        timeline = ReadAloudTimeline(pages: [])
        nowPlayingAnchorElapsed = 0
        nowPlayingAnchorDate = nil
        nowPlayingArtwork = nil
        onPageFinished = nil
        shouldResumeAfterInterruption = false
        state = .unavailable
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
        if stoppingSpeech {
            deactivateAudioSession()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard self?.hasSession == false else { return }
                self?.deactivateAudioSession()
            }
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueueSentence(at index: Int) {
        guard let currentPageLocation,
              let request = speechRequest(at: .init(location: currentPageLocation, sentenceIndex: index)) else {
            playbackRequested = false
            state = .failed(message: "当前朗读位置不可用")
            updateNowPlayingInfo()
            return
        }
        activeSentenceIndex = index
        currentSentenceIndex = index
        currentSentenceRange = plan.sentences[index].range
        nextSentenceIndex = index
        state = .playing(sentence: index)
        synchronizeNowPlayingAnchorToCurrentSentence()
        updateNowPlayingInfo()

        if prefetchTask != nil, prefetchTarget == request {
            waitingForPrefetchPosition = request.position
            return
        }

        let token = UUID()
        playbackToken = token
        activeRequest = request
        waitingForPrefetchPosition = nil

        if let prefetchedAudio, prefetchedAudio.request == request {
            self.prefetchedAudio = nil
            startAudioPlayback(prefetchedAudio.data, request: request, token: token)
            return
        }

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await synthesizeAudio(
                    text: request.text,
                    speaker: request.speaker,
                    configuration: settings,
                    key: apiKey
                )
                try Task.checkCancellation()
                guard playbackToken == token, playbackRequested else { return }
                synthesisTask = nil
                startAudioPlayback(audio, request: request, token: token)
            } catch is CancellationError {
                return
            } catch {
                guard playbackToken == token else { return }
                synthesisTask = nil
                activeSentenceIndex = nil
                playbackRequested = false
                state = .failed(message: "朗读失败：\(error.localizedDescription)")
                updateNowPlayingInfo()
            }
        }
    }

    private func speechRequest(at position: ReadAloudSpeechPosition) -> ReadAloudSpeechRequest? {
        guard let pageIndex = sessionPages.firstIndex(where: { $0.location == position.location }) else { return nil }
        ensureRolePlan(forChapter: position.location.chapterIndex)
        let pagePlan = position.location == currentPageLocation
            ? plan
            : ReadAloudTextPlan(
                text: sessionPages[pageIndex].text,
                speakers: rolePlan.speakers(for: position.location)
            )
        guard pagePlan.sentences.indices.contains(position.sentenceIndex) else { return nil }
        let sentence = pagePlan.sentences[position.sentenceIndex]
        var continuation: ReadAloudCrossPageContinuation?
        var text = sentence.text
        if position.sentenceIndex == pagePlan.sentences.count - 1,
           sessionPages.indices.contains(pageIndex + 1) {
            let nextPage = sessionPages[pageIndex + 1]
            let nextPlan = ReadAloudTextPlan(
                text: nextPage.text,
                speakers: rolePlan.speakers(for: nextPage.location)
            )
            if nextPage.location.chapterIndex == position.location.chapterIndex,
               let nextSentence = nextPlan.sentences.first,
               ReadAloudPageBoundary.shouldJoin(
                    lastFragment: sentence.text,
                    nextFragment: nextSentence.text
               ) {
                let separator = Self.crossPageSeparator(from: sentence.text, to: nextSentence.text)
                let combinedText = sentence.text + separator + nextSentence.text
                let sourceLength = max(1, (sentence.text as NSString).length)
                let totalLength = max(sourceLength + 1, (combinedText as NSString).length)
                continuation = ReadAloudCrossPageContinuation(
                    source: position,
                    target: .init(location: nextPage.location, sentenceIndex: 0),
                    boundaryFraction: Double(sourceLength) / Double(totalLength)
                )
                text = combinedText
            }
        }
        return ReadAloudSpeechRequest(
            position: position,
            text: text,
            speaker: sentence.speaker,
            continuation: continuation
        )
    }

    private static func crossPageSeparator(from first: String, to second: String) -> String {
        guard let left = first.last, let right = second.first,
              left.isASCII, right.isASCII,
              (left.isLetter || left.isNumber), (right.isLetter || right.isNumber) else { return "" }
        return " "
    }

    private func requestAfter(_ request: ReadAloudSpeechRequest) -> ReadAloudSpeechRequest? {
        if let continuation = request.continuation {
            return speechRequest(at: .init(
                location: continuation.target.location,
                sentenceIndex: continuation.target.sentenceIndex + 1
            ))
        }
        if let samePage = speechRequest(at: .init(
            location: request.position.location,
            sentenceIndex: request.position.sentenceIndex + 1
        )) {
            return samePage
        }
        guard let pageIndex = sessionPages.firstIndex(where: { $0.location == request.position.location }),
              sessionPages.indices.contains(pageIndex + 1) else { return nil }
        let nextPage = sessionPages[pageIndex + 1]
        if nextPage.location.chapterIndex != request.position.location.chapterIndex,
           settings.roleDetectionMode != .localRules {
            return nil
        }
        return speechRequest(at: .init(location: nextPage.location, sentenceIndex: 0))
    }

    private func synthesizeAudio(
        text: String,
        speaker: ReadAloudSpeaker,
        configuration: ReadAloudSettings,
        key: String
    ) async throws -> Data {
        switch configuration.provider {
        case .mimo, .openAICompatible:
            return try await speechClient.synthesize(
                text: text,
                speaker: speaker,
                settings: configuration,
                apiKey: key
            )
        case .localZipVoice:
            guard let model = zipVoiceStore.modelPaths() else { throw ZipVoiceError.modelNotInstalled }
            guard let profile = zipVoiceProfile(for: speaker, settings: configuration) else {
                throw ZipVoiceError.noVoiceProfile
            }
            let audio = try await zipVoiceSynthesizer.synthesize(
                text: text,
                model: model,
                profile: profile,
                audioURL: zipVoiceStore.audioURL(for: profile),
                speed: Float(configuration.rateMultiplier)
            )
            return audio.wavData
        }
    }

    private func startAudioPlayback(_ audio: Data, request: ReadAloudSpeechRequest, token: UUID) {
        do {
            try speechPlayer.play(
                audio,
                boundaryFraction: request.continuation?.boundaryFraction,
                onBoundary: request.continuation.map { continuation in
                    { [weak self] in self?.crossPageBoundaryReached(continuation, token: token) }
                }
            ) { [weak self] in
                self?.sentenceAudioDidFinish(request: request, token: token)
            }
            beginPrefetch(after: request, token: token)
        } catch {
            guard playbackToken == token else { return }
            activeSentenceIndex = nil
            playbackRequested = false
            state = .failed(message: "音频播放失败：\(error.localizedDescription)")
            updateNowPlayingInfo()
        }
    }

    private func beginPrefetch(after request: ReadAloudSpeechRequest, token: UUID) {
        prefetchTask?.cancel()
        prefetchedAudio = nil
        guard let candidate = requestAfter(request) else {
            prefetchTask = nil
            prefetchTarget = nil
            return
        }
        let configuration = settings
        let key = apiKey
        prefetchTarget = candidate
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await synthesizeAudio(
                    text: candidate.text,
                    speaker: candidate.speaker,
                    configuration: configuration,
                    key: key
                )
                try Task.checkCancellation()
                guard playbackToken == token else { return }
                prefetchedAudio = (candidate, audio)
                prefetchTask = nil
                prefetchTarget = nil
                if waitingForPrefetchPosition == candidate.position, playbackRequested,
                   currentPageLocation == candidate.position.location {
                    enqueueSentence(at: candidate.position.sentenceIndex)
                }
            } catch {
                guard playbackToken == token else { return }
                prefetchTask = nil
                prefetchTarget = nil
                if waitingForPrefetchPosition == candidate.position, playbackRequested,
                   currentPageLocation == candidate.position.location {
                    enqueueSentence(at: candidate.position.sentenceIndex)
                }
            }
        }
    }

    private func zipVoiceProfile(
        for speaker: ReadAloudSpeaker,
        settings: ReadAloudSettings
    ) -> ZipVoiceProfile? {
        guard !zipVoiceProfiles.isEmpty else { return nil }
        if settings.voiceSelectionMode == .single,
           let selected = zipVoiceProfiles.first(where: { $0.voiceIdentifier == settings.selectedVoiceIdentifier }) {
            return selected
        }
        if settings.voiceSelectionMode == .roleBased {
            let identifier: String
            switch speaker {
            case .narrator: identifier = settings.narratorVoiceIdentifier
            case .thirdPersonNarrator: identifier = settings.thirdPersonVoiceIdentifier
            case .character, .unknownDialogue: identifier = settings.characterVoiceIdentifier
            }
            if let selected = zipVoiceProfiles.first(where: { $0.voiceIdentifier == identifier }) {
                return selected
            }
        }
        let index: Int
        switch speaker {
        case .narrator:
            index = 0
        case .thirdPersonNarrator:
            index = min(1, zipVoiceProfiles.count - 1)
        case let .unknownDialogue(turn):
            index = positiveModulo(turn + 1, zipVoiceProfiles.count)
        case let .character(name):
            index = stableVoiceIndex(name, count: zipVoiceProfiles.count)
        }
        return zipVoiceProfiles[index]
    }

    private func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private func stableVoiceIndex(_ value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    private func configureAudioSession() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
            try audioSession.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            return true
        } catch {
            state = .failed(message: "无法启动音频：\(error.localizedDescription)")
            return false
        }
    }

    private func cancelSpeechPlayback() {
        playbackToken = UUID()
        synthesisTask?.cancel()
        synthesisTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedAudio = nil
        prefetchTarget = nil
        waitingForPrefetchPosition = nil
        speechPlayer.stop()
        activeSentenceIndex = nil
        activeRequest = nil
    }

    private func crossPageBoundaryReached(
        _ continuation: ReadAloudCrossPageContinuation,
        token: UUID
    ) {
        guard playbackToken == token,
              currentPageLocation == continuation.source.location,
              playbackRequested else { return }
        currentSentenceRange = nil
        state = .ready
        if applicationIsActive,
           bookContext?.id == visibleReaderBookID,
           let onPageFinished {
            onPageFinished()
        } else {
            advanceInBackground()
        }
    }

    private func sentenceAudioDidFinish(request: ReadAloudSpeechRequest, token: UUID) {
        guard playbackToken == token, activeRequest == request else { return }
        activeSentenceIndex = nil
        activeRequest = nil
        if let continuation = request.continuation,
           currentPageLocation != continuation.target.location {
            guard let targetIndex = sessionPages.firstIndex(where: {
                $0.location == continuation.target.location
            }) else { return }
            sessionPageIndex = targetIndex
            let targetPage = sessionPages[targetIndex]
            setPage(
                text: targetPage.text,
                location: targetPage.location,
                stoppingCurrentSpeech: false
            )
        }
        let candidate = (request.continuation?.target.sentenceIndex ?? request.position.sentenceIndex) + 1
        guard playbackRequested else {
            nextSentenceIndex = min(candidate, max(0, plan.sentences.count - 1))
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
            return
        }
        guard candidate >= plan.sentences.count else {
            nextSentenceIndex = candidate
            let candidatePosition = ReadAloudSpeechPosition(
                location: currentPageLocation ?? request.position.location,
                sentenceIndex: candidate
            )
            if prefetchedAudio?.request.position == candidatePosition || prefetchTask == nil {
                enqueueSentence(at: candidate)
            } else {
                waitingForPrefetchPosition = candidatePosition
            }
            return
        }
        currentSentenceRange = nil
        nextSentenceIndex = 0
        state = .ready
        if applicationIsActive,
           bookContext?.id == visibleReaderBookID,
           let onPageFinished {
            onPageFinished()
        } else {
            advanceInBackground()
        }
    }

    private func ensureRolePlan(forChapter chapterIndex: Int) {
        guard !analyzedRoleChapters.contains(chapterIndex) else { return }
        let chapterPages = sessionPages.filter { $0.location.chapterIndex == chapterIndex }
        guard !chapterPages.isEmpty else { return }
        let chapterPlan = ReadAloudRoleAnalyzer.plan(
            for: chapterPages,
            alternatesUnattributedDialogue: true
        )
        var combined = rolePlan.speakersByPage
        combined.merge(chapterPlan.speakersByPage) { _, new in new }
        rolePlan = ReadAloudRolePlan(speakersByPage: combined)
        analyzedRoleChapters.insert(chapterIndex)
    }

    private func analyzeCurrentChapterThenPlayIfNeeded() {
        guard let chapterIndex = currentPageLocation?.chapterIndex else {
            play()
            return
        }
        let needsAnalysis: Bool
        switch settings.roleDetectionMode {
        case .localRules:
            needsAnalysis = false
        case .ai:
            needsAnalysis = !aiAnalyzedRoleChapters.contains(chapterIndex) && networkCredentialsReady
        case .localModel:
            needsAnalysis = !localAnalyzedRoleChapters.contains(chapterIndex)
                && LocalNovelRoleModel.isInstalled(settings.localRoleModel)
        }
        guard needsAnalysis else {
            play()
            return
        }
        ensureRolePlan(forChapter: chapterIndex)
        let chapterPages = sessionPages.filter { $0.location.chapterIndex == chapterIndex }
        let fallback = rolePlan
        let configuration = settings
        let key = apiKey
        let expectedLocation = currentPageLocation
        playbackRequested = true
        state = .ready
        roleAnalysisTask?.cancel()
        roleAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analyzed: ReadAloudRolePlan
                switch configuration.roleDetectionMode {
                case .ai:
                    analyzed = try await aiRoleClient.analyze(
                        pages: chapterPages,
                        settings: configuration,
                        apiKey: key,
                        fallback: fallback
                    )
                case .localModel:
                    localRoleModelState = .analyzing
                    analyzed = try await localRoleModel.analyze(
                        pages: chapterPages,
                        fallback: fallback,
                        variant: configuration.localRoleModel
                    )
                case .localRules:
                    analyzed = fallback
                }
                try Task.checkCancellation()
                var combined = rolePlan.speakersByPage
                combined.merge(analyzed.speakersByPage) { _, new in new }
                rolePlan = ReadAloudRolePlan(speakersByPage: combined)
                if configuration.roleDetectionMode == .ai {
                    aiAnalyzedRoleChapters.insert(chapterIndex)
                } else if configuration.roleDetectionMode == .localModel {
                    localAnalyzedRoleChapters.insert(chapterIndex)
                    localRoleModelState = .installed
                }
            } catch is CancellationError {
                return
            } catch {
                // Model analysis is an enhancement. Preserve uninterrupted
                // local-rule attribution if the selected model is unavailable.
                if configuration.roleDetectionMode == .ai {
                    aiAnalyzedRoleChapters.insert(chapterIndex)
                } else {
                    localAnalyzedRoleChapters.insert(chapterIndex)
                    localRoleModelState = .failed(error.localizedDescription)
                }
            }
            roleAnalysisTask = nil
            guard let expectedLocation,
                  currentPageLocation == expectedLocation,
                  let page = sessionPages.first(where: { $0.location == expectedLocation }) else { return }
            setPage(text: page.text, location: page.location, stoppingCurrentSpeech: false)
            if playbackRequested { play() }
        }
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
    }

    private static func loadSettings() -> ReadAloudSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsDefaultsKey),
              let decoded = try? JSONDecoder().decode(ReadAloudSettings.self, from: data) else {
            return ReadAloudSettings()
        }
        return decoded.normalized
    }

    private func advanceInBackground() {
        guard let currentIndex = sessionPageIndex else {
            stop()
            return
        }
        let nextIndex = currentIndex + 1
        guard sessionPages.indices.contains(nextIndex) else {
            finishAtEndOfBook()
            return
        }
        sessionPageIndex = nextIndex
        let nextPage = sessionPages[nextIndex]
        setPage(
            text: nextPage.text,
            location: nextPage.location,
            stoppingCurrentSpeech: false
        )
        analyzeCurrentChapterThenPlayIfNeeded()
    }

    private func seek(to elapsedTime: TimeInterval) {
        guard let position = timeline.position(at: elapsedTime),
              currentChapterPageIndices.indices.contains(position.pageIndex) else { return }
        let absolutePageIndex = currentChapterPageIndices[position.pageIndex]
        guard sessionPages.indices.contains(absolutePageIndex) else { return }
        let shouldContinuePlaying = isPlaying
        sessionPageIndex = absolutePageIndex
        let page = sessionPages[absolutePageIndex]
        setPage(
            text: page.text,
            location: page.location,
            startAtUTF16Location: position.utf16Location
        )
        if shouldContinuePlaying {
            play()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
    }

    private func skipChapter(forward: Bool) {
        guard let targetIndex = forward ? nextChapterPageIndex : previousChapterPageIndex,
              sessionPages.indices.contains(targetIndex) else { return }
        let shouldContinuePlaying = isPlaying
        sessionPageIndex = targetIndex
        let page = sessionPages[targetIndex]
        setPage(text: page.text, location: page.location)
        if shouldContinuePlaying {
            play()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
    }

    private var nextChapterPageIndex: Int? {
        guard let sessionPageIndex else { return nil }
        return ReadAloudChapterNavigator.nextChapterPageIndex(
            in: sessionPages,
            from: sessionPageIndex
        )
    }

    private var previousChapterPageIndex: Int? {
        guard let sessionPageIndex else { return nil }
        return ReadAloudChapterNavigator.previousChapterPageIndex(
            in: sessionPages,
            from: sessionPageIndex
        )
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.stop() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard self != nil,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .noActionableNowPlayingItem
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor in self?.seek(to: positionTime) }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.skipChapter(forward: true) }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.skipChapter(forward: false) }
            return .success
        }
        updateRemoteCommandAvailability()
    }

    private func updateRemoteCommandAvailability() {
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = timeline.duration > 0
        commands.nextTrackCommand.isEnabled = nextChapterPageIndex != nil
        commands.previousTrackCommand.isEnabled = previousChapterPageIndex != nil
    }

    private func observeAudioInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioInterruption(notification) }
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption, options.contains(.shouldResume) { play() }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func updateNowPlayingInfo() {
        guard let bookContext else { return }
        let page = sessionPageIndex.flatMap { sessionPages.indices.contains($0) ? sessionPages[$0] : nil }
        let chapterTitle = page?.chapterTitle ?? "正文"
        let elapsedTime = estimatedNowPlayingElapsedTime()
        let chapterQueueIndex = page.flatMap { currentPage in
            sessionChapterIndices.firstIndex(of: currentPage.location.chapterIndex)
        } ?? 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookContext.title,
            MPMediaItemPropertyArtist: chapterTitle,
            MPMediaItemPropertyAlbumArtist: bookContext.author,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: timeline.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: chapterQueueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: sessionChapterIndices.count
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func chapterIndices(in pages: [ReaderPage]) -> [Int] {
        pages.reduce(into: [Int]()) { indices, page in
            let chapterIndex = page.location.chapterIndex
            if indices.last != chapterIndex { indices.append(chapterIndex) }
        }
    }

    private func makeNowPlayingArtwork(for context: ReadAloudBookContext) -> MPMediaItemArtwork? {
        let coverImage = context.coverData.flatMap { UIImage(data: $0) }
            ?? UIImage(named: BookPalette.defaultCoverAssetName(for: context.coverStyle))
        guard let coverImage else { return nil }
        let boundsSize = CGSize(
            width: NowPlayingArtworkRenderer.preferredDimension,
            height: NowPlayingArtworkRenderer.preferredDimension
        )
        return MPMediaItemArtwork(boundsSize: boundsSize) { requestedSize in
            let requestedSide = max(requestedSize.width, requestedSize.height)
            return NowPlayingArtworkRenderer.squareImage(
                from: coverImage,
                dimension: requestedSide > 0
                    ? requestedSide
                    : NowPlayingArtworkRenderer.preferredDimension
            )
        }
    }

    private func synchronizeNowPlayingAnchorToCurrentSentence() {
        guard let sessionPageIndex,
              let chapterPageIndex = currentChapterPageIndices.firstIndex(of: sessionPageIndex) else { return }
        nowPlayingAnchorElapsed = timeline.elapsedTime(
            pageIndex: chapterPageIndex,
            utf16Location: currentSentenceRange?.location ?? 0
        )
        nowPlayingAnchorDate = isPlaying ? .now : nil
    }

    private func estimatedNowPlayingElapsedTime(at date: Date = .now) -> TimeInterval {
        let elapsedSinceAnchor: TimeInterval
        if isPlaying, let nowPlayingAnchorDate {
            elapsedSinceAnchor = max(0, date.timeIntervalSince(nowPlayingAnchorDate))
        } else {
            elapsedSinceAnchor = 0
        }
        return min(timeline.duration, max(0, nowPlayingAnchorElapsed + elapsedSinceAnchor))
    }

    private func freezeNowPlayingPosition() {
        nowPlayingAnchorElapsed = estimatedNowPlayingElapsedTime()
        nowPlayingAnchorDate = nil
    }

    private func rebuildCurrentChapterTimeline(force: Bool = false) {
        guard let sessionPageIndex, sessionPages.indices.contains(sessionPageIndex) else {
            currentChapterPageIndices = []
            timelineChapterIndex = nil
            timeline = ReadAloudTimeline(pages: [])
            return
        }
        let chapterIndex = sessionPages[sessionPageIndex].location.chapterIndex
        guard force || timelineChapterIndex != chapterIndex else { return }
        currentChapterPageIndices = ReadAloudChapterNavigator.currentChapterPageIndices(
            in: sessionPages,
            from: sessionPageIndex
        )
        timelineChapterIndex = chapterIndex
        timeline = ReadAloudTimeline(
            pages: currentChapterPageIndices.map { sessionPages[$0] }
        )
    }
}
