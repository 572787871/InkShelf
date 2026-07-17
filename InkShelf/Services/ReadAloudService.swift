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

struct ReadAloudVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let packageID: String
    let packageName: String
    let speakerID: Int
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

/// A stable UTF-16 text plan shared by speech, highlighting and paragraph buttons.
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

/// Fully offline reading session. Text is synthesized by imported Kokoro/VITS
/// models and played as local PCM; no system voice or network service is used.
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
    @Published private(set) var localVoicePackages: [LocalVoicePackage]
    @Published private(set) var localVoiceCatalogStates: [String: LocalVoiceCatalogState]
    @Published var settings: ReadAloudSettings {
        didSet {
            if oldValue.alternatesUnattributedDialogue != settings.alternatesUnattributedDialogue {
                rolePlan = .empty
                analyzedRoleChapters.removeAll()
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

    private let voiceStore: LocalVoicePackageStore
    private let localSynthesizer = LocalVoiceSynthesizer()
    private let speechPlayer = LocalSpeechAudioPlayer()
    private let previewPlayer = LocalSpeechAudioPlayer()
    private var plan = ReadAloudTextPlan(text: "")
    private var rolePlan = ReadAloudRolePlan.empty
    private var analyzedRoleChapters: Set<Int> = []
    private var synthesisTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var catalogDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private var catalogProgressTasks: [String: Task<Void, Never>] = [:]
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
        let voiceStore = LocalVoicePackageStore()
        self.voiceStore = voiceStore
        let installedPackages = voiceStore.installedPackages()
        localVoicePackages = installedPackages
        var catalogStates = Dictionary(
            uniqueKeysWithValues: LocalVoiceCatalog.models.map { ($0.id, LocalVoiceCatalogState.available) }
        )
        for package in installedPackages {
            if let catalogID = package.catalogID { catalogStates[catalogID] = .installed }
        }
        localVoiceCatalogStates = catalogStates
        settings = Self.loadSettings()
        super.init()
        Self.cleanAbandonedCatalogDownloads()
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

    var availableLocalVoices: [ReadAloudVoiceOption] {
        localVoicePackages.flatMap { package in
            package.manifest.speakers.map { speaker in
                let selection = LocalVoiceSelection(packageID: package.id, speakerID: speaker.id)
                return ReadAloudVoiceOption(
                    id: selection.identifier,
                    name: speaker.name,
                    packageID: package.id,
                    packageName: package.name,
                    speakerID: speaker.id
                )
            }
        }
    }

    var canStartLocalReading: Bool { !availableLocalVoices.isEmpty }

    var localVoiceCatalog: [LocalVoiceCatalogModel] { LocalVoiceCatalog.models }

    func catalogState(for model: LocalVoiceCatalogModel) -> LocalVoiceCatalogState {
        localVoiceCatalogStates[model.id] ?? .available
    }

    func importLocalVoicePackage(from url: URL) async throws {
        let package = try await voiceStore.importPackage(from: url)
        localVoicePackages.append(package)
        localVoicePackages.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if resolvedVoice(identifier: settings.narratorVoiceIdentifier) == nil,
           let first = availableLocalVoices.first {
            settings.narratorVoiceIdentifier = first.id
        }
    }

    func downloadCatalogModel(_ model: LocalVoiceCatalogModel) {
        guard catalogDownloadTasks[model.id] == nil,
              catalogState(for: model) != .installed,
              catalogState(for: model) != .installing else { return }

        let destination: URL
        do {
            destination = try Self.catalogDownloadURL(for: model)
        } catch {
            localVoiceCatalogStates[model.id] = .failed(message: error.localizedDescription)
            return
        }
        localVoiceCatalogStates[model.id] = .downloading(progress: 0)

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { [weak self] temporaryURL, response, error in
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode) else {
                    throw LocalVoicePackageError.downloadFailed("服务器没有返回有效文件")
                }
                guard let temporaryURL else {
                    throw LocalVoicePackageError.downloadFailed("下载文件不存在")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                self?.catalogDownloadFinished(model, result: result)
            }
        }
        catalogDownloadTasks[model.id] = task
        catalogProgressTasks[model.id] = Task { [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let task,
                      self.catalogDownloadTasks[model.id] === task else { return }
                let expected = task.countOfBytesExpectedToReceive > 0
                    ? task.countOfBytesExpectedToReceive
                    : model.downloadBytes
                let progress = min(1, max(0, Double(task.countOfBytesReceived) / Double(expected)))
                self.localVoiceCatalogStates[model.id] = .downloading(progress: progress)
            }
        }
        task.resume()
    }

    func cancelCatalogModelDownload(_ model: LocalVoiceCatalogModel) {
        catalogDownloadTasks.removeValue(forKey: model.id)?.cancel()
        catalogProgressTasks.removeValue(forKey: model.id)?.cancel()
        localVoiceCatalogStates[model.id] = .available
        if let url = try? Self.catalogDownloadURL(for: model) { try? FileManager.default.removeItem(at: url) }
    }

    func removeLocalVoicePackage(_ package: LocalVoicePackage) throws {
        let removedVoiceIDs = Set(availableLocalVoices.filter { $0.packageID == package.id }.map(\.id))
        stopVoicePreview()
        if activeVoiceUses(packageID: package.id) || currentSentenceUses(packageID: package.id) { stop() }
        try voiceStore.remove(package)
        localVoicePackages.removeAll { $0.id == package.id }
        if let catalogID = package.catalogID { localVoiceCatalogStates[catalogID] = .available }
        Task { await localSynthesizer.unload(packageID: package.id) }
        if removedVoiceIDs.contains(settings.narratorVoiceIdentifier) {
            settings.narratorVoiceIdentifier = availableLocalVoices.first?.id ?? ""
        }
        settings.roleVoiceIdentifiers = settings.roleVoiceIdentifiers.map {
            removedVoiceIDs.contains($0) ? "" : $0
        }
    }

    private func catalogDownloadFinished(
        _ model: LocalVoiceCatalogModel,
        result: Result<URL, Error>
    ) {
        guard catalogDownloadTasks.removeValue(forKey: model.id) != nil else {
            if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }
        catalogProgressTasks.removeValue(forKey: model.id)?.cancel()
        switch result {
        case let .failure(error):
            if (error as? URLError)?.code == .cancelled {
                localVoiceCatalogStates[model.id] = .available
            } else {
                localVoiceCatalogStates[model.id] = .failed(message: error.localizedDescription)
            }
        case let .success(archiveURL):
            localVoiceCatalogStates[model.id] = .installing
            Task { [weak self] in
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                do {
                    let package = try await voiceStore.installCatalogModel(model, from: archiveURL)
                    localVoicePackages.removeAll { $0.catalogID == model.id }
                    localVoicePackages.append(package)
                    localVoicePackages.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    localVoiceCatalogStates[model.id] = .installed
                    if resolvedVoice(identifier: settings.narratorVoiceIdentifier) == nil,
                       let first = availableLocalVoices.first(where: { $0.packageID == package.id }) {
                        settings.narratorVoiceIdentifier = first.id
                    }
                } catch {
                    localVoiceCatalogStates[model.id] = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    private static func catalogDownloadURL(for model: LocalVoiceCatalogModel) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("VoiceModelDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(model.id).appendingPathExtension("tar.bz2")
    }

    private static func cleanAbandonedCatalogDownloads() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("VoiceModelDownloads", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
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
        analyzedRoleChapters.removeAll()
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
        play()
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
            play()
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
        guard canStartLocalReading else {
            playbackRequested = false
            state = .failed(message: "请先导入 Kokoro 或 VITS 本地音色包")
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
        if speechPlayer.isPaused {
            do {
                try speechPlayer.resume()
                state = .playing(sentence: currentSentenceIndex)
                nowPlayingAnchorDate = .now
                updateNowPlayingInfo()
            } catch {
                playbackRequested = false
                state = .failed(message: "无法恢复本地音频：\(error.localizedDescription)")
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

    func previewVoice(roleSlot: Int?) {
        if isPlaying { pause() }
        stopVoicePreview()
        guard configureAudioSession() else { return }

        let speaker: ReadAloudSpeaker
        let sample: String
        if let roleSlot {
            let safeSlot = min(max(0, roleSlot), ReadAloudSettings.roleVoiceCount - 1)
            speaker = .unknownDialogue(turn: safeSlot)
            sample = "你好，这是角色声线 \(safeSlot + 1) 的试听。"
        } else {
            speaker = .narrator
            sample = "夜色渐深，故事从这里缓缓开始。"
        }
        guard let choice = preferredLocalVoice(for: speaker) else {
            state = .failed(message: "请先导入并选择本地音色")
            return
        }
        let token = UUID()
        previewToken = token
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await localSynthesizer.synthesize(
                    text: sample,
                    package: choice.package,
                    speakerID: choice.voice.speakerID,
                    speed: Float(settings.rateMultiplier)
                )
                try Task.checkCancellation()
                guard previewToken == token else { return }
                previewTask = nil
                try previewPlayer.play(audio) {}
            } catch is CancellationError {
                return
            } catch {
                guard previewToken == token else { return }
                previewTask = nil
                state = .failed(message: "音色试听失败：\(error.localizedDescription)")
            }
        }
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

    func play(fromUTF16Location location: Int) {
        guard let index = plan.sentenceIndex(atOrAfterUTF16Location: location) else { return }
        cancelSpeechPlayback()
        currentSentenceIndex = index
        currentSentenceRange = plan.sentences[index].range
        nextSentenceIndex = index
        synchronizeNowPlayingAnchorToCurrentSentence()
        play()
    }

    private func enqueueSentence(at index: Int) {
        guard plan.sentences.indices.contains(index),
              let choice = preferredLocalVoice(for: plan.sentences[index].speaker) else {
            playbackRequested = false
            state = .failed(message: "当前声线不可用，请在朗读设置中重新选择")
            updateNowPlayingInfo()
            return
        }
        let sentence = plan.sentences[index]
        let token = UUID()
        playbackToken = token
        activeSentenceIndex = index
        currentSentenceIndex = index
        currentSentenceRange = sentence.range
        nextSentenceIndex = index
        state = .playing(sentence: index)
        synchronizeNowPlayingAnchorToCurrentSentence()
        updateNowPlayingInfo()

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await localSynthesizer.synthesize(
                    text: sentence.text,
                    package: choice.package,
                    speakerID: choice.voice.speakerID,
                    speed: Float(settings.rateMultiplier)
                )
                try Task.checkCancellation()
                guard playbackToken == token, playbackRequested else { return }
                synthesisTask = nil
                try speechPlayer.play(audio) { [weak self] in
                    self?.sentenceAudioDidFinish(index: index, token: token)
                }
            } catch is CancellationError {
                return
            } catch {
                guard playbackToken == token else { return }
                synthesisTask = nil
                activeSentenceIndex = nil
                playbackRequested = false
                state = .failed(message: "本地朗读失败：\(error.localizedDescription)")
                updateNowPlayingInfo()
            }
        }
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

    private func preferredLocalVoice(
        for speaker: ReadAloudSpeaker
    ) -> (voice: ReadAloudVoiceOption, package: LocalVoicePackage)? {
        let narrator = resolvedVoice(identifier: settings.narratorVoiceIdentifier)
            ?? availableLocalVoices.first
        let selected: ReadAloudVoiceOption?
        if settings.automaticallyAssignsCharacterVoices, speaker.isDialogue {
            let slot = voiceSlot(for: speaker)
            let configuredIdentifier = settings.roleVoiceIdentifiers.indices.contains(slot)
                ? settings.roleVoiceIdentifiers[slot]
                : ""
            if let configured = resolvedVoice(identifier: configuredIdentifier) {
                selected = configured
            } else {
                let alternatives = availableLocalVoices.filter { $0.id != narrator?.id }
                selected = alternatives.isEmpty ? narrator : alternatives[slot % alternatives.count]
            }
        } else {
            selected = narrator
        }
        guard let selected,
              let package = localVoicePackages.first(where: { $0.id == selected.packageID }) else {
            return nil
        }
        return (selected, package)
    }

    private func voiceSlot(for speaker: ReadAloudSpeaker) -> Int {
        switch speaker {
        case .narrator:
            return 0
        case let .unknownDialogue(turn):
            return abs(turn) % ReadAloudSettings.roleVoiceCount
        case let .character(name):
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in name.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return Int(hash % UInt64(ReadAloudSettings.roleVoiceCount))
        }
    }

    private func resolvedVoice(identifier: String) -> ReadAloudVoiceOption? {
        guard LocalVoiceSelection(identifier: identifier) != nil else { return nil }
        return availableLocalVoices.first { $0.id == identifier }
    }

    private func activeVoiceUses(packageID: String) -> Bool {
        let identifiers = [settings.narratorVoiceIdentifier] + settings.roleVoiceIdentifiers
        return identifiers.contains {
            LocalVoiceSelection(identifier: $0)?.packageID == packageID
        }
    }

    private func currentSentenceUses(packageID: String) -> Bool {
        guard plan.sentences.indices.contains(currentSentenceIndex) else { return false }
        return preferredLocalVoice(for: plan.sentences[currentSentenceIndex].speaker)?.package.id == packageID
    }

    private func cancelSpeechPlayback() {
        playbackToken = UUID()
        synthesisTask?.cancel()
        synthesisTask = nil
        speechPlayer.stop()
        activeSentenceIndex = nil
    }

    private func sentenceAudioDidFinish(index: Int, token: UUID) {
        guard playbackToken == token, activeSentenceIndex == index else { return }
        activeSentenceIndex = nil
        let candidate = index + 1
        guard playbackRequested else {
            nextSentenceIndex = min(candidate, max(0, plan.sentences.count - 1))
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
            return
        }
        guard candidate >= plan.sentences.count else {
            nextSentenceIndex = candidate
            enqueueSentence(at: candidate)
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
            alternatesUnattributedDialogue: settings.alternatesUnattributedDialogue
        )
        var combined = rolePlan.speakersByPage
        combined.merge(chapterPlan.speakersByPage) { _, new in new }
        rolePlan = ReadAloudRolePlan(speakersByPage: combined)
        analyzedRoleChapters.insert(chapterIndex)
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
        play()
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
