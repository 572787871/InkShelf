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

struct AudiobookTranscriptSegment: Identifiable, Equatable {
    let id: String
    let location: ReaderPageLocation
    let sentenceIndex: Int
    let text: String
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

/// A stable UTF-16 text plan shared by speech, highlighting and paragraph interactions.
/// UIKit text ranges are UTF-16 based, so keeping one coordinate system prevents
/// Chinese punctuation and emoji from shifting the highlight.
struct ReadAloudTextPlan: Equatable {
    struct Sentence: Equatable {
        let text: String
        let range: NSRange
        let speaker: ReadAloudSpeaker
    }

    let sentences: [Sentence]
    let paragraphRanges: [NSRange]

    init(text: String, speakers: [ReadAloudSpeaker]? = nil) {
        sentences = Self.units(in: text, option: .bySentences).enumerated().map { index, range in
            Sentence(
                text: (text as NSString).substring(with: range),
                range: range,
                speaker: speakers.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .narrator
            )
        }
        paragraphRanges = Self.units(in: text, option: .byParagraphs)
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
    let targetEndingSentenceIndex: Int
    let targetHighlightedRange: NSRange
    let boundaryFraction: Double
}

struct ReadAloudHighlightCue: Equatable, Sendable {
    let location: ReaderPageLocation
    let sentenceIndex: Int
    let range: NSRange
    let startFraction: Double
}

struct ReadAloudSpeechRequest: Equatable, Sendable {
    let position: ReadAloudSpeechPosition
    let endingSentenceIndex: Int
    let highlightedRange: NSRange
    let text: String
    let speaker: ReadAloudSpeaker
    let continuation: ReadAloudCrossPageContinuation?
    let highlightCues: [ReadAloudHighlightCue]
}

enum ReadAloudLocalSpeechChunkPolicy {
    // ZipVoice has a sizeable fixed inference cost. A longer block gives the
    // rolling prefetcher enough spoken time to prepare the following blocks,
    // while highlight cues still advance one visible segment at a time.
    static let maximumSentenceCount = 6
    static let maximumUTF16Length = 360

    static func canAppend(
        currentSentenceCount: Int,
        currentUTF16Length: Int,
        nextUTF16Length: Int
    ) -> Bool {
        currentSentenceCount < maximumSentenceCount
            && currentUTF16Length + nextUTF16Length <= maximumUTF16Length
    }
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
struct WholeBookRoleAnalysisProgress: Equatable, Sendable {
    let bookID: UUID
    let completedChapters: Int
    let totalChapters: Int
    let chapterTitle: String

    var fraction: Double {
        guard totalChapters > 0 else { return 0 }
        return Double(completedChapters) / Double(totalChapters)
    }
}

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
    @Published private(set) var localVoiceGenerationState = LocalVoiceGenerationState.idle
    @Published private(set) var detectedCharacterNames: [String] = []
    @Published private(set) var detectedCharacterGenders: [String: NovelCharacterGender] = [:]
    @Published private(set) var wholeBookRoleProgress: WholeBookRoleAnalysisProgress?
    @Published private(set) var roleAnalysisMessage: String?
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
                prefetchedAudio.removeAll()
                prefetchTargets.removeAll()
                waitingForPrefetchPosition = nil
            }
            if oldValue.roleDetectionMode != settings.roleDetectionMode
                || oldValue.analysisProvider != settings.analysisProvider
                || oldValue.analysisBaseURL != settings.analysisBaseURL
                || oldValue.analysisModel != settings.analysisModel {
                aiAnalyzedRoleChapters.removeAll()
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
    var currentChapterTitle: String {
        sessionPageIndex.flatMap { sessionPages.indices.contains($0) ? sessionPages[$0].chapterTitle : nil }
            ?? "正文"
    }
    var currentChapterDuration: TimeInterval { timeline.duration / playbackTimelineRate }
    var currentChapterElapsedTime: TimeInterval { estimatedNowPlayingElapsedTime() }
    var canSkipToPreviousChapter: Bool { previousChapterPageIndex != nil }
    var canSkipToNextChapter: Bool { nextChapterPageIndex != nil }
    var currentTranscriptSegmentID: String? {
        guard let location = currentPageLocation, let range = currentSentenceRange else { return nil }
        return Self.transcriptSegmentID(location: location, utf16Location: range.location)
    }
    var currentChapterTranscript: [AudiobookTranscriptSegment] {
        currentChapterPageIndices.flatMap { pageIndex -> [AudiobookTranscriptSegment] in
            guard sessionPages.indices.contains(pageIndex) else { return [] }
            let page = sessionPages[pageIndex]
            return ReadAloudTextPlan(text: page.text).sentences.enumerated().map { sentenceIndex, sentence in
                AudiobookTranscriptSegment(
                    id: Self.transcriptSegmentID(
                        location: page.location,
                        utf16Location: sentence.range.location
                    ),
                    location: page.location,
                    sentenceIndex: sentenceIndex,
                    text: sentence.text
                )
            }
        }
    }

    private let speechClient = AudiobookSpeechClient()
    private let aiRoleClient = AICharacterRoleClient()
    private let novelCastStore = NovelCastStore()
    private let zipVoiceStore = ZipVoiceStore()
    private let zipVoiceSynthesizer = ZipVoiceSynthesizer()
    private let speechPlayer = AudiobookAudioPlayer()
    private let previewPlayer = AudiobookAudioPlayer()
    private let localVoiceDiskCache = ZipVoiceAudioDiskCache()
    private let localAudioCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 16
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()
    private var plan = ReadAloudTextPlan(text: "")
    private var rolePlan = ReadAloudRolePlan.empty
    private var analyzedRoleChapters: Set<Int> = []
    private var synthesisTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedAudio: [ReadAloudSpeechPosition: (request: ReadAloudSpeechRequest, data: Data)] = [:]
    private var prefetchTargets: Set<ReadAloudSpeechPosition> = []
    private var waitingForPrefetchPosition: ReadAloudSpeechPosition?
    private var activeRequest: ReadAloudSpeechRequest?
    private var roleAnalysisTask: Task<Void, Never>?
    private var wholeBookRoleAnalysisTask: Task<Void, Never>?
    private var aiAnalyzedRoleChapters: Set<Int> = []
    private var modelDownloadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var localVoiceCancellation: ISZipVoiceSynthesisCancellation?
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
    private var memoryWarningObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false

    override init() {
        apiKey = AudiobookCredentialStore.loadAPIKey()
        settings = Self.loadSettings()
        super.init()
        Task.detached(priority: .utility) { Self.removeRetiredLocalRoleModels() }
        zipVoiceInstallState = zipVoiceStore.modelPaths() == nil ? .notInstalled : .installed
        // The built-in catalog is available before the inference model is
        // downloaded, so users can inspect and assign voices up front.
        do {
            try zipVoiceStore.ensureBuiltInProfiles()
            zipVoiceProfiles = try zipVoiceStore.profiles()
            removeUnavailableZipVoiceAssignments()
        } catch {
            zipVoiceInstallState = .failed("音色资料无法读取：\(error.localizedDescription)")
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        configureRemoteCommands()
        observeAudioInterruptions()
        observeMemoryWarnings()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
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
        canPreviewVoice
    }

    var canPreviewVoice: Bool {
        switch settings.provider {
        case .localZipVoice:
            return zipVoiceStore.modelPaths() != nil && !zipVoiceProfiles.isEmpty
        case .mimo, .openAICompatible:
            return networkCredentialsReady
                && !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
        if !availableVoiceChoices.contains(where: { $0.id == settings.narratorVoiceIdentifier }) {
            settings.narratorVoiceIdentifier = ""
        }
        if !availableVoiceChoices.contains(where: { $0.id == settings.thirdPersonVoiceIdentifier }) {
            settings.thirdPersonVoiceIdentifier = ""
        }
        if !availableVoiceChoices.contains(where: { $0.id == settings.characterVoiceIdentifier }) {
            settings.characterVoiceIdentifier = ""
        }
        settings.characterVoiceIdentifiers = settings.characterVoiceIdentifiers.filter { _, identifier in
            availableVoiceChoices.contains(where: { $0.id == identifier })
        }
        connectionState = .idle
    }

    func applyAnalysisProviderDefaults(for provider: ReadAloudAIProvider) {
        settings.analysisProvider = provider
        settings.analysisBaseURL = provider.defaultBaseURL
        settings.analysisModel = provider.defaultModel
        connectionState = .idle
    }

    func loadStoredCastCharacters(for book: NovelBook) {
        let store = novelCastStore
        Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) {
                var names = Set<String>()
                var genders: [String: NovelCharacterGender] = [:]
                for chapter in book.chapters {
                    guard let cast = store.load(
                        bookID: book.id,
                        chapterIndex: chapter.index,
                        chapterText: chapter.content
                    ) else { continue }
                    names.formUnion(cast.characterNames)
                    genders.merge(cast.characterGenders) { existing, new in
                        existing == .unspecified ? new : existing
                    }
                }
                return (names.sorted(), genders)
            }.value
            guard let self else { return }
            detectedCharacterNames = summary.0
            detectedCharacterGenders = summary.1
        }
    }

    func analyzeWholeBook(_ book: NovelBook) {
        guard wholeBookRoleAnalysisTask == nil else {
            roleAnalysisMessage = "整书角色分析正在运行"
            return
        }
        guard !book.chapters.isEmpty else {
            roleAnalysisMessage = "这本书没有可分析的章节"
            return
        }

        let configuration = settings
        let key = apiKey
        let store = novelCastStore
        let total = book.chapters.count
        let usesAI = configuration.roleDetectionMode == .ai
            && configuration.allowsTextUpload
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.analysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        roleAnalysisMessage = configuration.roleDetectionMode == .localRules
            ? "正在本地解析《\(book.title)》…"
            : "正在建立《\(book.title)》角色档案…"
        wholeBookRoleProgress = WholeBookRoleAnalysisProgress(
            bookID: book.id,
            completedChapters: 0,
            totalChapters: total,
            chapterTitle: book.chapters[0].title
        )
        wholeBookRoleAnalysisTask = Task { [weak self] in
            guard let self else { return }
            var allNames = Set<String>()
            var allGenders: [String: NovelCharacterGender] = [:]
            var usedLocalFallback = configuration.roleDetectionMode == .ai && !usesAI
            do {
                for (offset, chapter) in book.chapters.enumerated() {
                    try Task.checkCancellation()
                    wholeBookRoleProgress = WholeBookRoleAnalysisProgress(
                        bookID: book.id,
                        completedChapters: offset,
                        totalChapters: total,
                        chapterTitle: chapter.title
                    )
                    let existing = await Task.detached(priority: .utility) {
                        store.load(
                            bookID: book.id,
                            chapterIndex: chapter.index,
                            chapterText: chapter.content
                        )
                    }.value
                    let cast: NovelCastChapter
                    if let existing {
                        cast = existing
                    } else {
                        if usesAI {
                            do {
                                cast = try await analyzeCastChapter(
                                    chapter,
                                    settings: configuration,
                                    apiKey: key,
                                    knownCharacters: allNames.sorted(),
                                    batchProgress: { [weak self] completed, batchTotal in
                                        Task { @MainActor in
                                            guard let self else { return }
                                            self.roleAnalysisMessage = "\(chapter.title) · AI 批次 \(completed)/\(batchTotal)"
                                        }
                                    }
                                )
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                usedLocalFallback = true
                                roleAnalysisMessage = "\(chapter.title) · AI 暂不可用，正在改用本地增强解析"
                                cast = await localCastChapter(
                                    chapter,
                                    knownCharacters: allNames.sorted()
                                )
                            }
                        } else {
                            cast = await localCastChapter(
                                chapter,
                                knownCharacters: allNames.sorted()
                            )
                        }
                        try await Task.detached(priority: .utility) {
                            try store.save(cast, bookID: book.id)
                        }.value
                    }
                    allNames.formUnion(cast.characterNames)
                    allGenders.merge(cast.characterGenders) { existing, new in
                        existing == .unspecified ? new : existing
                    }
                    wholeBookRoleProgress = WholeBookRoleAnalysisProgress(
                        bookID: book.id,
                        completedChapters: offset + 1,
                        totalChapters: total,
                        chapterTitle: chapter.title
                    )
                }
                if configuration.roleDetectionMode == .localRules {
                    roleAnalysisMessage = "本地角色解析已完成：\(allNames.count) 个明确角色"
                } else if usedLocalFallback {
                    roleAnalysisMessage = "角色档案已完成：\(allNames.count) 个明确角色；AI 不可用的章节已用本地增强解析"
                } else {
                    roleAnalysisMessage = "整书角色档案已完成：\(allNames.count) 个明确角色"
                }
                detectedCharacterNames = allNames.sorted()
                detectedCharacterGenders = allGenders
            } catch is CancellationError {
                roleAnalysisMessage = "整书分析已暂停，再次开始会从已完成章节继续"
            } catch {
                roleAnalysisMessage = "整书分析失败：\(error.localizedDescription)；再次开始会续传"
            }
            wholeBookRoleProgress = nil
            wholeBookRoleAnalysisTask = nil
        }
    }

    func cancelWholeBookRoleAnalysis() {
        wholeBookRoleAnalysisTask?.cancel()
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
                if FileManager.default.fileExists(atPath: cache.path) {
                    try FileManager.default.removeItem(at: cache)
                }
                try zipVoiceStore.ensureBuiltInProfiles()
                zipVoiceProfiles = try zipVoiceStore.profiles()
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

    func prepareLocalVoiceAudio(
        from url: URL,
        trimRange: ClosedRange<TimeInterval>? = nil
    ) async throws -> ProcessedVoiceAudio {
        guard let model = zipVoiceStore.modelPaths() else { throw ZipVoiceError.modelNotInstalled }
        localVoiceGenerationState = .loadingModel
        let sampleRate = try await zipVoiceSynthesizer.modelSampleRate(model: model)
        guard sampleRate > 0 else { throw LocalVoiceError.modelSampleRateUnavailable }
        localVoiceGenerationState = .processingReference
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkShelfVoiceDrafts", isDirectory: true)
        let destination = destinationDirectory
            .appendingPathComponent("reference-\(UUID().uuidString.lowercased()).wav")
        do {
            return try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor().process(
                    sourceURL: url,
                    destinationURL: destination,
                    targetSampleRate: Double(sampleRate),
                    trimRange: trimRange
                )
            }.value
        } catch {
            localVoiceGenerationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func generateLocalVoicePreview(
        referenceURL: URL,
        referenceText: String,
        speed: Double = 1
    ) async throws -> URL {
        let transcript = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw LocalVoiceError.emptyReferenceText }
        guard let model = zipVoiceStore.modelPaths() else { throw ZipVoiceError.modelNotInstalled }
        localVoiceCancellation?.cancel()
        let cancellation = ISZipVoiceSynthesisCancellation()
        localVoiceCancellation = cancellation
        localVoiceGenerationState = .generatingPreview
        let temporaryProfile = VoiceProfile(
            name: "试听",
            sourceType: .imported,
            referenceAudioRelativePath: referenceURL.lastPathComponent,
            originalAudioRelativePath: nil,
            referenceText: transcript,
            previewAudioRelativePath: nil,
            originalFilename: nil,
            sampleRate: 0,
            duration: 0,
            voiceCategory: .unspecified,
            modelVersion: ZipVoiceCatalog.modelVersion,
            isAuthorized: true
        )
        do {
            let audio = try await zipVoiceSynthesizer.synthesize(
                text: "夜色渐深，他终于推开了那扇尘封多年的门。",
                model: model,
                profile: temporaryProfile,
                audioURL: referenceURL,
                speed: Float(speed),
                cancellation: cancellation
            )
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InkShelfVoiceDrafts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("preview-\(UUID().uuidString.lowercased()).wav")
            try audio.wavData.write(to: output, options: .atomic)
            localVoiceCancellation = nil
            localVoiceGenerationState = .completed
            return output
        } catch is CancellationError {
            localVoiceCancellation = nil
            localVoiceGenerationState = .idle
            throw CancellationError()
        } catch {
            localVoiceCancellation = nil
            localVoiceGenerationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func cancelLocalVoiceGeneration() {
        localVoiceCancellation?.cancel()
        localVoiceCancellation = nil
        localVoiceGenerationState = .idle
    }

    func saveLocalVoiceProfile(
        name: String,
        sourceType: VoiceProfileSourceType,
        voiceCategory: ZipVoiceProfileGender,
        originalURL: URL,
        processedAudio: ProcessedVoiceAudio,
        referenceText: String,
        previewURL: URL,
        originalFilename: String?,
        isAuthorized: Bool
    ) async throws -> VoiceProfile {
        let store = zipVoiceStore
        let profile = try await Task.detached(priority: .userInitiated) {
            try store.saveProfile(
                name: name,
                sourceType: sourceType,
                voiceCategory: voiceCategory,
                originalURL: originalURL,
                processedAudio: processedAudio,
                referenceText: referenceText,
                previewURL: previewURL,
                originalFilename: originalFilename,
                isAuthorized: isAuthorized
            )
        }.value
        zipVoiceProfiles = try zipVoiceStore.profiles()
        localVoiceGenerationState = .completed
        return profile
    }

    func removeZipVoiceProfile(_ profile: ZipVoiceProfile) throws {
        try zipVoiceStore.removeProfile(profile)
        do {
            try localVoiceDiskCache.invalidate(profileID: profile.id)
        } catch {
            NSLog("已删除音色，但关联音频缓存清理失败：%@", error.localizedDescription)
        }
        localAudioCache.removeAllObjects()
        if settings.narratorVoiceIdentifier == profile.voiceIdentifier { settings.narratorVoiceIdentifier = "" }
        if settings.thirdPersonVoiceIdentifier == profile.voiceIdentifier { settings.thirdPersonVoiceIdentifier = "" }
        if settings.characterVoiceIdentifier == profile.voiceIdentifier { settings.characterVoiceIdentifier = "" }
        settings.characterVoiceIdentifiers = settings.characterVoiceIdentifiers.filter {
            $0.value != profile.voiceIdentifier
        }
        zipVoiceProfiles = try zipVoiceStore.profiles()
    }

    func renameVoiceProfile(_ profile: VoiceProfile, to name: String) throws {
        var updated = profile
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updated.name = String(trimmed.prefix(30))
        try zipVoiceStore.updateProfile(updated)
        zipVoiceProfiles = try zipVoiceStore.profiles()
    }

    func voiceProfileBindings(_ profile: VoiceProfile) -> [String] {
        var bindings: [String] = []
        if settings.narratorVoiceIdentifier == profile.voiceIdentifier { bindings.append("第一人称旁白") }
        if settings.thirdPersonVoiceIdentifier == profile.voiceIdentifier { bindings.append("第三人称旁白") }
        if settings.characterVoiceIdentifier == profile.voiceIdentifier { bindings.append("未识别角色") }
        bindings += settings.characterVoiceIdentifiers
            .filter { $0.value == profile.voiceIdentifier }
            .map { "角色 · \($0.key)" }
            .sorted()
        return bindings
    }

    func assignVoiceProfile(_ profile: VoiceProfile, to binding: String) throws {
        switch binding {
        case "第一人称旁白": settings.narratorVoiceIdentifier = profile.voiceIdentifier
        case "第三人称旁白": settings.thirdPersonVoiceIdentifier = profile.voiceIdentifier
        case "未识别角色": settings.characterVoiceIdentifier = profile.voiceIdentifier
        default: settings.characterVoiceIdentifiers[binding] = profile.voiceIdentifier
        }
        try synchronizeProfileBindings()
    }

    func unbindVoiceProfile(_ profile: VoiceProfile, from binding: String) throws {
        switch binding {
        case "第一人称旁白":
            if settings.narratorVoiceIdentifier == profile.voiceIdentifier { settings.narratorVoiceIdentifier = "" }
        case "第三人称旁白":
            if settings.thirdPersonVoiceIdentifier == profile.voiceIdentifier { settings.thirdPersonVoiceIdentifier = "" }
        case "未识别角色":
            if settings.characterVoiceIdentifier == profile.voiceIdentifier { settings.characterVoiceIdentifier = "" }
        default:
            if settings.characterVoiceIdentifiers[binding] == profile.voiceIdentifier {
                settings.characterVoiceIdentifiers[binding] = nil
            }
        }
        try synchronizeProfileBindings()
    }

    func refreshVoiceProfileBindings() throws {
        try synchronizeProfileBindings()
    }

    func playStoredVoicePreview(_ profile: VoiceProfile) throws {
        guard let previewURL = zipVoiceStore.previewAudioURL(for: profile),
              FileManager.default.fileExists(atPath: previewURL.path) else {
            previewVoice(profile.voiceIdentifier)
            return
        }
        stopVoicePreview()
        guard configureAudioSession() else { return }
        try previewPlayer.play(Data(contentsOf: previewURL)) { }
    }

    func regenerateVoiceProfilePreview(_ profile: VoiceProfile) async throws {
        let preview = try await generateLocalVoicePreview(
            referenceURL: zipVoiceStore.audioURL(for: profile),
            referenceText: profile.referenceText
        )
        _ = try zipVoiceStore.replacePreview(for: profile, from: preview)
        try localVoiceDiskCache.invalidate(profileID: profile.id)
        localAudioCache.removeAllObjects()
        zipVoiceProfiles = try zipVoiceStore.profiles()
    }

    func originalAudioURL(for profile: VoiceProfile) -> URL? {
        zipVoiceStore.originalAudioURL(for: profile)
    }

    private func removeUnavailableZipVoiceAssignments() {
        let valid = Set(zipVoiceProfiles.map(\.voiceIdentifier))
        func normalized(_ identifier: String) -> String {
            guard identifier.hasPrefix("zipvoice::"), !valid.contains(identifier) else { return identifier }
            return ""
        }
        settings.narratorVoiceIdentifier = normalized(settings.narratorVoiceIdentifier)
        settings.thirdPersonVoiceIdentifier = normalized(settings.thirdPersonVoiceIdentifier)
        settings.characterVoiceIdentifier = normalized(settings.characterVoiceIdentifier)
        settings.characterVoiceIdentifiers = settings.characterVoiceIdentifiers.mapValues(normalized)
    }

    private func synchronizeProfileBindings() throws {
        var changed = false
        for profile in zipVoiceProfiles where profile.sourceType != .builtIn {
            var updated = profile
            let current = voiceProfileBindings(profile)
            if updated.boundCharacterIds != current {
                updated.boundCharacterIds = current
                try zipVoiceStore.updateProfile(updated)
                changed = true
            }
        }
        if changed { zipVoiceProfiles = try zipVoiceStore.profiles() }
    }

    private func download(_ source: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZipVoiceError.downloadFailed("服务器没有返回有效文件")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func testConnection() {
        previewVoice(nil)
    }

    func previewVoice(_ voiceIdentifier: String?) {
        guard connectionState != .testing else { return }
        stopVoicePreview()
        connectionState = .testing
        var configuration = settings
        if let voiceIdentifier {
            configuration.voiceSelectionMode = .roleBased
            configuration.narratorVoiceIdentifier = voiceIdentifier
        }
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
        location: ReaderPageLocation,
        startAtUTF16Location: Int = 0
    ) {
        guard let pageIndex = pages.firstIndex(where: { $0.location == location }) else {
            state = .failed(message: "当前朗读页面不存在")
            return
        }
        sessionPages = pages
        sessionPageIndex = pageIndex
        rolePlan = .empty
        detectedCharacterNames = []
        detectedCharacterGenders = [:]
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
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
            location: pages[pageIndex].location,
            startAtUTF16Location: startAtUTF16Location
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
        if !stoppingCurrentSpeech,
           let continuation = activeRequest?.continuation,
           continuation.target.location == location {
            currentSentenceIndex = continuation.target.sentenceIndex
            currentSentenceRange = continuation.targetHighlightedRange
            nextSentenceIndex = continuation.targetEndingSentenceIndex + 1
            state = .playing(sentence: continuation.target.sentenceIndex)
        }
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
        detectedCharacterNames = []
        detectedCharacterGenders = [:]
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
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
        guard configureAudioSession() else {
            playbackRequested = false
            updateNowPlayingInfo()
            return
        }
        do {
            try speechPlayer.beginSessionKeepAlive()
        } catch {
            // Spoken audio can still play without the silent continuity bed.
            NSLog("朗读后台连续音频启动失败：%@", error.localizedDescription)
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
        speechPlayer.endSessionKeepAlive()
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
        speechPlayer.endSessionKeepAlive()
        stopVoicePreview()
        if stoppingSpeech {
            cancelSpeechPlayback()
        }
        plan = ReadAloudTextPlan(text: "")
        rolePlan = .empty
        detectedCharacterNames = []
        detectedCharacterGenders = [:]
        analyzedRoleChapters.removeAll()
        aiAnalyzedRoleChapters.removeAll()
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
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("朗读音频会话关闭失败：%@", error.localizedDescription)
        }
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
        currentSentenceRange = request.highlightedRange
        nextSentenceIndex = index
        state = .playing(sentence: index)
        synchronizeNowPlayingAnchorToCurrentSentence()
        updateNowPlayingInfo()

        if let cached = prefetchedAudio.removeValue(forKey: request.position),
           cached.request == request {
            let token = playbackToken
            activeRequest = request
            waitingForPrefetchPosition = nil
            startAudioPlayback(cached.data, request: request, token: token)
            return
        }

        if prefetchTargets.contains(request.position) {
            waitingForPrefetchPosition = request.position
            return
        }

        let token = playbackToken
        activeRequest = request
        waitingForPrefetchPosition = nil

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
        var endingSentenceIndex = position.sentenceIndex
        var continuation: ReadAloudCrossPageContinuation?
        var text = sentence.text
        var cueSeeds: [(location: ReaderPageLocation, sentenceIndex: Int, range: NSRange, offset: Int)] = [
            (position.location, position.sentenceIndex, sentence.range, 0)
        ]
        if settings.provider == .localZipVoice {
            while endingSentenceIndex + 1 < pagePlan.sentences.count,
                  ReadAloudLocalSpeechChunkPolicy.canAppend(
                    currentSentenceCount: endingSentenceIndex - position.sentenceIndex + 1,
                    currentUTF16Length: (text as NSString).length,
                    nextUTF16Length: (pagePlan.sentences[endingSentenceIndex + 1].text as NSString).length
                ) {
                let nextSentence = pagePlan.sentences[endingSentenceIndex + 1]
                guard nextSentence.speaker == sentence.speaker else { break }
                let nextOffset = (text as NSString).length
                text += nextSentence.text
                endingSentenceIndex += 1
                cueSeeds.append((position.location, endingSentenceIndex, nextSentence.range, nextOffset))
            }
        }
        let lastSentence = pagePlan.sentences[endingSentenceIndex]
        let highlightedRange = sentence.range
        if endingSentenceIndex == pagePlan.sentences.count - 1,
           sessionPages.indices.contains(pageIndex + 1) {
            let nextPage = sessionPages[pageIndex + 1]
            let nextPlan = ReadAloudTextPlan(
                text: nextPage.text,
                speakers: rolePlan.speakers(for: nextPage.location)
            )
            if nextPage.location.chapterIndex == position.location.chapterIndex,
               let nextSentence = nextPlan.sentences.first {
                let joinsSplitSentence = ReadAloudPageBoundary.shouldJoin(
                    lastFragment: lastSentence.text,
                    nextFragment: nextSentence.text
                )
                let canGroupAcrossPage = settings.provider == .localZipVoice
                    && nextSentence.speaker == sentence.speaker
                    && ReadAloudLocalSpeechChunkPolicy.canAppend(
                        currentSentenceCount: endingSentenceIndex - position.sentenceIndex + 1,
                        currentUTF16Length: (text as NSString).length,
                        nextUTF16Length: (nextSentence.text as NSString).length
                    )
                guard joinsSplitSentence || canGroupAcrossPage else {
                    let totalLength = max(1, (text as NSString).length)
                    return ReadAloudSpeechRequest(
                        position: position,
                        endingSentenceIndex: endingSentenceIndex,
                        highlightedRange: highlightedRange,
                        text: text,
                        speaker: sentence.speaker,
                        continuation: nil,
                        highlightCues: cueSeeds.map {
                            ReadAloudHighlightCue(
                                location: $0.location,
                                sentenceIndex: $0.sentenceIndex,
                                range: $0.range,
                                startFraction: Double($0.offset) / Double(totalLength)
                            )
                        }
                    )
                }
                var targetEndingSentenceIndex = 0
                var targetText = nextSentence.text
                let separator = joinsSplitSentence
                    ? Self.crossPageSeparator(from: lastSentence.text, to: nextSentence.text)
                    : ""
                let targetBaseOffset = (text as NSString).length + (separator as NSString).length
                cueSeeds.append((nextPage.location, 0, nextSentence.range, targetBaseOffset))
                if settings.provider == .localZipVoice {
                    while targetEndingSentenceIndex + 1 < nextPlan.sentences.count,
                          ReadAloudLocalSpeechChunkPolicy.canAppend(
                            currentSentenceCount: endingSentenceIndex - position.sentenceIndex
                                + targetEndingSentenceIndex + 2,
                            currentUTF16Length: (text as NSString).length + (targetText as NSString).length,
                            nextUTF16Length: (nextPlan.sentences[targetEndingSentenceIndex + 1].text as NSString).length
                    ) {
                        let following = nextPlan.sentences[targetEndingSentenceIndex + 1]
                        guard following.speaker == sentence.speaker else { break }
                        let followingOffset = targetBaseOffset + (targetText as NSString).length
                        targetText += following.text
                        targetEndingSentenceIndex += 1
                        cueSeeds.append((
                            nextPage.location,
                            targetEndingSentenceIndex,
                            following.range,
                            followingOffset
                        ))
                    }
                }
                let targetHighlightedRange = nextSentence.range
                let combinedText = text + separator + targetText
                let sourceLength = max(1, (text as NSString).length)
                let totalLength = max(sourceLength + 1, (combinedText as NSString).length)
                continuation = ReadAloudCrossPageContinuation(
                    source: position,
                    target: .init(location: nextPage.location, sentenceIndex: 0),
                    targetEndingSentenceIndex: targetEndingSentenceIndex,
                    targetHighlightedRange: targetHighlightedRange,
                    boundaryFraction: Double(sourceLength) / Double(totalLength)
                )
                text = combinedText
            }
        }
        let totalLength = max(1, (text as NSString).length)
        return ReadAloudSpeechRequest(
            position: position,
            endingSentenceIndex: endingSentenceIndex,
            highlightedRange: highlightedRange,
            text: text,
            speaker: sentence.speaker,
            continuation: continuation,
            highlightCues: cueSeeds.map {
                ReadAloudHighlightCue(
                    location: $0.location,
                    sentenceIndex: $0.sentenceIndex,
                    range: $0.range,
                    startFraction: Double($0.offset) / Double(totalLength)
                )
            }
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
                sentenceIndex: continuation.targetEndingSentenceIndex + 1
            ))
        }
        if let samePage = speechRequest(at: .init(
            location: request.position.location,
            sentenceIndex: request.endingSentenceIndex + 1
        )) {
            return samePage
        }
        guard let pageIndex = sessionPages.firstIndex(where: { $0.location == request.position.location }),
              sessionPages.indices.contains(pageIndex + 1) else { return nil }
        let nextPage = sessionPages[pageIndex + 1]
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
                apiKey: key,
                characterGenders: detectedCharacterGenders
            )
        case .localZipVoice:
            guard let model = zipVoiceStore.modelPaths() else { throw ZipVoiceError.modelNotInstalled }
            guard let profile = zipVoiceProfile(for: speaker, settings: configuration) else {
                throw ZipVoiceError.noVoiceProfile
            }
            let cacheKey = "\(profile.id.uuidString)|\(configuration.rateMultiplier)|\(text)" as NSString
            if let cached = localAudioCache.object(forKey: cacheKey) {
                return cached as Data
            }
            let diskCacheKey = localVoiceDiskCache.key(
                text: text,
                speed: configuration.rateMultiplier,
                modelVersion: profile.modelVersion
            )
            let diskCache = localVoiceDiskCache
            do {
                if let diskData = try await Task.detached(priority: .utility, operation: {
                    try diskCache.data(profileID: profile.id, key: diskCacheKey)
                }).value {
                    localAudioCache.setObject(diskData as NSData, forKey: cacheKey, cost: diskData.count)
                    return diskData
                }
            } catch {
                NSLog("ZipVoice 片段缓存读取失败：%@", error.localizedDescription)
            }
            let audio = try await zipVoiceSynthesizer.synthesize(
                text: text,
                model: model,
                profile: profile,
                audioURL: zipVoiceStore.audioURL(for: profile),
                speed: Float(configuration.rateMultiplier)
            )
            let wav = audio.wavData
            localAudioCache.setObject(wav as NSData, forKey: cacheKey, cost: wav.count)
            do {
                try await Task.detached(priority: .utility) {
                    try diskCache.store(wav, profileID: profile.id, key: diskCacheKey)
                }.value
            } catch {
                NSLog("ZipVoice 片段缓存写入失败：%@", error.localizedDescription)
            }
            return wav
        }
    }

    private func startAudioPlayback(_ audio: Data, request: ReadAloudSpeechRequest, token: UUID) {
        do {
            try speechPlayer.play(
                audio,
                preparedIdentifier: speechRequestIdentifier(request),
                playbackRate: localPlaybackRate,
                boundaryFraction: request.continuation?.boundaryFraction,
                onBoundary: request.continuation.map { continuation in
                    { [weak self] in self?.crossPageBoundaryReached(continuation, token: token) }
                },
                cueFractions: request.highlightCues.map(\.startFraction),
                onCue: { [weak self] index in
                    self?.highlightCueReached(index, request: request, token: token)
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
        guard prefetchTask == nil else { return }
        guard requestAfter(request) != nil else { return }
        let configuration = settings
        let key = apiKey
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            var candidate = requestAfter(request)
            while let next = candidate, prefetchedAudio.count < 3 {
                do {
                    try Task.checkCancellation()
                    guard playbackToken == token else { return }
                    if prefetchedAudio[next.position] == nil {
                        prefetchTargets.insert(next.position)
                        let audio = try await synthesizeAudio(
                            text: next.text,
                            speaker: next.speaker,
                            configuration: configuration,
                            key: key
                        )
                        try Task.checkCancellation()
                        guard playbackToken == token else { return }
                        prefetchTargets.remove(next.position)
                        prefetchedAudio[next.position] = (next, audio)
                        if requestAfter(activeRequest ?? request)?.position == next.position {
                            do {
                                try speechPlayer.prepare(audio, identifier: speechRequestIdentifier(next))
                            } catch {
                                NSLog("下一朗读块预解码失败：%@", error.localizedDescription)
                            }
                        }
                        if waitingForPrefetchPosition == next.position, playbackRequested,
                           currentPageLocation == next.position.location {
                            enqueueSentence(at: next.position.sentenceIndex)
                        }
                    }
                    candidate = requestAfter(next)
                } catch is CancellationError {
                    prefetchTargets.remove(next.position)
                    return
                } catch {
                    prefetchTargets.remove(next.position)
                    if waitingForPrefetchPosition == next.position, playbackRequested,
                       currentPageLocation == next.position.location {
                        enqueueSentence(at: next.position.sentenceIndex)
                    }
                    break
                }
            }
            guard playbackToken == token else { return }
            prefetchTask = nil
        }
    }

    private var localPlaybackRate: Float {
        guard settings.provider == .localZipVoice, settings.rateMultiplier > 1.2 else { return 1 }
        return Float(settings.rateMultiplier / 1.2)
    }

    private func speechRequestIdentifier(_ request: ReadAloudSpeechRequest) -> String {
        let location = request.position.location
        return "\(location.chapterIndex):\(location.pageIndex):\(request.position.sentenceIndex):\(request.endingSentenceIndex)"
    }

    private func zipVoiceProfile(
        for speaker: ReadAloudSpeaker,
        settings: ReadAloudSettings
    ) -> ZipVoiceProfile? {
        guard !zipVoiceProfiles.isEmpty else { return nil }
        if settings.voiceSelectionMode == .roleBased {
            let identifier: String
            switch speaker {
            case .narrator: identifier = settings.narratorVoiceIdentifier
            case .thirdPersonNarrator: identifier = settings.thirdPersonVoiceIdentifier
            case let .character(name):
                identifier = settings.characterVoiceIdentifiers[name] ?? settings.characterVoiceIdentifier
            case .unknownDialogue: identifier = settings.characterVoiceIdentifier
            }
            if let selected = zipVoiceProfiles.first(where: { $0.voiceIdentifier == identifier }) {
                return selected
            }
        }
        let preferredGender: ZipVoiceProfileGender?
        let stableKey: String
        switch speaker {
        case .narrator:
            preferredGender = .female
            stableKey = "first-person-narrator"
        case .thirdPersonNarrator:
            preferredGender = .male
            stableKey = "third-person-narrator"
        case let .unknownDialogue(turn):
            preferredGender = turn.isMultiple(of: 2) ? .female : .male
            stableKey = "unknown-dialogue-\(turn)"
        case let .character(name):
            switch detectedCharacterGenders[name] {
            case .female: preferredGender = .female
            case .male: preferredGender = .male
            case .unspecified, .none: preferredGender = nil
            }
            stableKey = name
        }
        let candidates = preferredGender.map { gender in
            zipVoiceProfiles.filter { $0.gender == gender }
        }.flatMap { $0.isEmpty ? nil : $0 } ?? zipVoiceProfiles
        return candidates[stableVoiceIndex(stableKey, count: candidates.count)]
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
        prefetchedAudio.removeAll()
        prefetchTargets.removeAll()
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
        currentSentenceRange = continuation.targetHighlightedRange
        state = .playing(sentence: continuation.target.sentenceIndex)
        if applicationIsActive,
           bookContext?.id == visibleReaderBookID,
           let onPageFinished {
            onPageFinished()
        } else {
            advanceInBackground()
        }
    }

    private func highlightCueReached(
        _ index: Int,
        request: ReadAloudSpeechRequest,
        token: UUID
    ) {
        guard playbackToken == token,
              request.highlightCues.indices.contains(index),
              playbackRequested else { return }
        let cue = request.highlightCues[index]
        guard currentPageLocation == cue.location else { return }
        currentSentenceIndex = cue.sentenceIndex
        currentSentenceRange = cue.range
        state = .playing(sentence: cue.sentenceIndex)
        synchronizeNowPlayingAnchorToCurrentSentence()
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
        let candidate = request.continuation.map { $0.targetEndingSentenceIndex + 1 }
            ?? (request.endingSentenceIndex + 1)
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
            if prefetchedAudio[candidatePosition] != nil || !prefetchTargets.contains(candidatePosition) {
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
        let chapterPages = sessionPages
            .filter { $0.location.chapterIndex == chapterIndex }
            .sorted { $0.location.pageIndex < $1.location.pageIndex }
        guard !chapterPages.isEmpty else { return }
        let localAnalysis = ReadAloudRoleAnalyzer.analyze(
            pages: chapterPages,
            alternatesUnattributedDialogue: true,
            knownCharacters: detectedCharacterNames
        )
        var chapterPlan = localAnalysis.plan
        detectedCharacterGenders.merge(localAnalysis.characterGenders) { existing, new in
            existing == .unspecified ? new : existing
        }
        if let bookID = bookContext?.id,
           let cast = novelCastStore.load(
               bookID: bookID,
               chapterIndex: chapterIndex,
               chapterText: chapterPages.map(\.text).joined()
           ) {
            chapterPlan = cast.plan(for: chapterPages, fallback: chapterPlan)
            detectedCharacterGenders.merge(cast.characterGenders) { existing, new in
                existing == .unspecified ? new : existing
            }
            aiAnalyzedRoleChapters.insert(chapterIndex)
        }
        var combined = rolePlan.speakersByPage
        combined.merge(chapterPlan.speakersByPage) { _, new in new }
        rolePlan = ReadAloudRolePlan(speakersByPage: combined)
        refreshDetectedCharacterNames()
        analyzedRoleChapters.insert(chapterIndex)
    }

    private func analyzeCurrentChapterThenPlayIfNeeded() {
        guard let chapterIndex = currentPageLocation?.chapterIndex else {
            play()
            return
        }
        ensureRolePlan(forChapter: chapterIndex)
        play()
        let needsAnalysis = settings.roleDetectionMode == .ai
            && !aiAnalyzedRoleChapters.contains(chapterIndex)
            && networkCredentialsReady
            && !settings.analysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard needsAnalysis, roleAnalysisTask == nil else { return }
        let chapterPages = sessionPages
            .filter { $0.location.chapterIndex == chapterIndex }
            .sorted { $0.location.pageIndex < $1.location.pageIndex }
        let chapterText = chapterPages.map(\.text).joined()
        let chapter = NovelChapter(
            index: chapterIndex,
            title: chapterPages.first?.chapterTitle ?? "正文",
            content: chapterText
        )
        let configuration = settings
        let key = apiKey
        let store = novelCastStore
        let bookID = bookContext?.id
        roleAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cast = try await analyzeCastChapter(
                    chapter,
                    settings: configuration,
                    apiKey: key,
                    knownCharacters: detectedCharacterNames
                )
                try Task.checkCancellation()
                if let bookID {
                    try await Task.detached(priority: .utility) {
                        try store.save(cast, bookID: bookID)
                    }.value
                }
                let baseline = ReadAloudRoleAnalyzer.plan(
                    for: chapterPages,
                    alternatesUnattributedDialogue: true,
                    knownCharacters: detectedCharacterNames
                )
                detectedCharacterGenders.merge(cast.characterGenders) { existing, new in
                    existing == .unspecified ? new : existing
                }
                mergeRolePlan(cast.plan(for: chapterPages, fallback: baseline))
                aiAnalyzedRoleChapters.insert(chapterIndex)
            } catch is CancellationError {
                roleAnalysisTask = nil
                return
            } catch {
                // The persisted smart cast is an enhancement. Keep the local
                // baseline attribution and never interrupt audiobook playback.
                aiAnalyzedRoleChapters.insert(chapterIndex)
                roleAnalysisMessage = "本章 AI 暂不可用，已使用本地增强角色解析"
            }
            roleAnalysisTask = nil
            if playbackRequested,
               currentPageLocation?.chapterIndex != chapterIndex {
                analyzeCurrentChapterThenPlayIfNeeded()
            }
        }
    }

    private func localCastChapter(
        _ chapter: NovelChapter,
        knownCharacters: [String]
    ) async -> NovelCastChapter {
        await Task.detached(priority: .userInitiated) {
            let page = ReaderPage(
                location: ReaderPageLocation(chapterIndex: chapter.index, pageIndex: 0),
                chapterTitle: chapter.title,
                text: chapter.content,
                pageInChapter: 1,
                pageCountInChapter: 1,
                overallIndex: 0,
                overallCount: 1
            )
            let analysis = ReadAloudRoleAnalyzer.analyze(
                pages: [page],
                alternatesUnattributedDialogue: true,
                knownCharacters: knownCharacters
            )
            return NovelCastChapter.make(
                chapterIndex: chapter.index,
                text: chapter.content,
                plan: analysis.plan,
                characterGenders: analysis.characterGenders
            )
        }.value
    }

    private func analyzeCastChapter(
        _ chapter: NovelChapter,
        settings: ReadAloudSettings,
        apiKey: String,
        knownCharacters: [String] = [],
        batchProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> NovelCastChapter {
        let page = ReaderPage(
            location: ReaderPageLocation(chapterIndex: chapter.index, pageIndex: 0),
            chapterTitle: chapter.title,
            text: chapter.content,
            pageInChapter: 1,
            pageCountInChapter: 1,
            overallIndex: 0,
            overallCount: 1
        )
        let pages = [page]
        let fallback = await Task.detached(priority: .userInitiated) {
            ReadAloudRoleAnalyzer.plan(
                for: pages,
                alternatesUnattributedDialogue: true,
                knownCharacters: knownCharacters
            )
        }.value
        let analyzed = try await aiRoleClient.analyze(
            pages: pages,
            settings: settings,
            apiKey: apiKey,
            fallback: fallback,
            knownCharacters: knownCharacters,
            progress: batchProgress
        )
        return NovelCastChapter.make(
            chapterIndex: chapter.index,
            text: chapter.content,
            plan: analyzed.plan,
            characterGenders: analyzed.characterGenders
        )
    }

    private func mergeRolePlan(_ plan: ReadAloudRolePlan) {
        var combined = rolePlan.speakersByPage
        combined.merge(plan.speakersByPage) { _, new in new }
        rolePlan = ReadAloudRolePlan(speakersByPage: combined)
        refreshDetectedCharacterNames()
    }

    private func refreshDetectedCharacterNames() {
        detectedCharacterNames = characterNames(in: rolePlan)
    }

    private func characterNames(in plan: ReadAloudRolePlan) -> [String] {
        Array(Set(plan.speakersByPage.values.flatMap { speakers in
            speakers.compactMap { speaker -> String? in
                if case let .character(name) = speaker { return name }
                return nil
            }
        })).sorted()
    }

    private func persistSettings() {
        do {
            let data = try JSONEncoder().encode(settings.normalized)
            UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
        } catch {
            NSLog("朗读设置保存失败：%@", error.localizedDescription)
        }
    }

    private static func loadSettings() -> ReadAloudSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsDefaultsKey) else {
            return ReadAloudSettings()
        }
        do {
            return try JSONDecoder().decode(ReadAloudSettings.self, from: data).normalized
        } catch {
            NSLog("朗读设置读取失败，将使用默认设置：%@", error.localizedDescription)
            return ReadAloudSettings()
        }
    }

    /// The removed MLX role-model flow stored its two supported repositories
    /// under the app's Documents/huggingface model snapshot directory. Delete
    /// only those exact retired targets so upgrading users recover the space.
    nonisolated private static func removeRetiredLocalRoleModels() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let root = documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx-community", isDirectory: true)
            .standardizedFileURL
        for modelName in ["Qwen3-0.6B-4bit", "Qwen3-1.7B-4bit"] {
            let target = root.appendingPathComponent(modelName, isDirectory: true).standardizedFileURL
            guard target.deletingLastPathComponent() == root,
                  FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                NSLog("旧本地角色模型清理失败：%@", error.localizedDescription)
            }
        }
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

    func seekToChapterTime(_ elapsedTime: TimeInterval) {
        seek(to: elapsedTime * playbackTimelineRate)
    }

    func skipToPreviousChapter() {
        skipChapter(forward: false)
    }

    func skipToNextChapter() {
        skipChapter(forward: true)
    }

    func playChapter(at chapterIndex: Int) {
        guard let targetIndex = sessionPages.firstIndex(where: {
            $0.location.chapterIndex == chapterIndex
        }) else { return }
        let shouldContinue = isPlaying
        sessionPageIndex = targetIndex
        let page = sessionPages[targetIndex]
        setPage(text: page.text, location: page.location)
        if shouldContinue {
            play()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let supported = [0.75, 1.0, 1.2, 1.5, 2.0]
        let selected = supported.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1
        guard settings.rateMultiplier != selected else { return }
        let shouldContinue = isPlaying
        freezeNowPlayingPosition()
        cancelSpeechPlayback()
        nextSentenceIndex = currentSentenceIndex
        settings.rateMultiplier = selected
        if shouldContinue {
            playbackRequested = true
            play()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
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
            Task { @MainActor in self?.seekToChapterTime(positionTime) }
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

    private func observeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.localAudioCache.removeAllObjects()
                let activeProfile = self.activeRequest.flatMap {
                    self.zipVoiceProfile(for: $0.speaker, settings: self.settings)
                }
                do {
                    try await self.zipVoiceSynthesizer.releaseReferenceAudioCache(
                        keeping: activeProfile.map { self.zipVoiceStore.audioURL(for: $0) }
                    )
                } catch {
                    NSLog("ZipVoice 参考音频缓存释放失败：%@", error.localizedDescription)
                }
            }
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
            MPMediaItemPropertyPlaybackDuration: currentChapterDuration,
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

    private static func transcriptSegmentID(
        location: ReaderPageLocation,
        utf16Location: Int
    ) -> String {
        "\(location.chapterIndex):\(location.pageIndex):\(utf16Location)"
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
        ) / playbackTimelineRate
        nowPlayingAnchorDate = isPlaying ? .now : nil
    }

    private func estimatedNowPlayingElapsedTime(at date: Date = .now) -> TimeInterval {
        let elapsedSinceAnchor: TimeInterval
        if isPlaying, let nowPlayingAnchorDate {
            elapsedSinceAnchor = max(0, date.timeIntervalSince(nowPlayingAnchorDate))
        } else {
            elapsedSinceAnchor = 0
        }
        return min(currentChapterDuration, max(0, nowPlayingAnchorElapsed + elapsedSinceAnchor))
    }

    private func freezeNowPlayingPosition() {
        nowPlayingAnchorElapsed = estimatedNowPlayingElapsedTime()
        nowPlayingAnchorDate = nil
    }

    private var playbackTimelineRate: Double {
        min(2, max(0.5, settings.rateMultiplier))
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
