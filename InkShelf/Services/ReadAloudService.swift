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

/// A stable UTF-16 text plan shared by speech, highlighting and paragraph buttons.
/// UIKit text ranges are UTF-16 based, so keeping one coordinate system prevents
/// Chinese punctuation and emoji from shifting the highlight.
struct ReadAloudTextPlan: Equatable {
    struct Sentence: Equatable {
        let text: String
        let range: NSRange
    }

    let sentences: [Sentence]
    let paragraphRanges: [NSRange]

    init(text: String) {
        sentences = Self.units(in: text, option: .bySentences).map {
            Sentence(text: (text as NSString).substring(with: $0), range: $0)
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

/// Current built-in engine. The view talks only to this reading-session API, so
/// a cloud AI voice engine can later replace the utterance producer without
/// changing pagination, highlighting or player controls.
@MainActor
final class ReadAloudService: NSObject, ObservableObject {
    @Published private(set) var state: ReadAloudState = .unavailable
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var currentSentenceRange: NSRange?
    @Published private(set) var currentPageLocation: ReaderPageLocation?
    @Published private(set) var bookContext: ReadAloudBookContext?
    @Published private(set) var visibleReaderBookID: UUID?
    @Published private(set) var applicationIsActive = true
    @Published private(set) var playbackRequested = false

    var onPageFinished: (() -> Void)?
    var isPlaying: Bool { playbackRequested && hasSession }
    var hasSession: Bool { currentPageLocation != nil && !plan.sentences.isEmpty }
    var shouldShowPersistentFloater: Bool {
        hasSession && bookContext?.id != visibleReaderBookID
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var plan = ReadAloudTextPlan(text: "")
    private var queuedSentenceIndices: [ObjectIdentifier: Int] = [:]
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
        super.init()
        synthesizer.delegate = self
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
        guard let pageIndex = sessionPages.firstIndex(where: { $0.location == location }) else { return }
        sessionPageIndex = pageIndex
        let page = sessionPages[pageIndex]
        setPage(text: page.text, location: page.location)
        if continuePlaying {
            play()
        } else {
            playbackRequested = false
            state = .paused(sentence: currentSentenceIndex)
            updateNowPlayingInfo()
        }
    }

    func continueAfterPageFinishedWithoutTurningReader() {
        guard playbackRequested else { return }
        advanceInBackground()
    }

    func refreshSessionPages(_ pages: [ReaderPage], for bookID: UUID) {
        guard bookContext?.id == bookID, let currentPageLocation else { return }
        sessionPages = pages
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

    func setPage(text: String, location: ReaderPageLocation, startAtUTF16Location: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll(keepingCapacity: true)
        plan = ReadAloudTextPlan(text: text)
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
        playbackRequested = true
        guard configureAudioSession() else {
            playbackRequested = false
            updateNowPlayingInfo()
            return
        }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .playing(sentence: currentSentenceIndex)
            nowPlayingAnchorDate = .now
            updateNowPlayingInfo()
            return
        }
        guard !synthesizer.isSpeaking else {
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
        if synthesizer.isSpeaking, !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .immediate)
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
        playbackRequested = false
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll()
        plan = ReadAloudTextPlan(text: "")
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(fromUTF16Location location: Int) {
        guard let index = plan.sentenceIndex(atOrAfterUTF16Location: location) else { return }
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll(keepingCapacity: true)
        currentSentenceIndex = index
        currentSentenceRange = plan.sentences[index].range
        nextSentenceIndex = index
        synchronizeNowPlayingAnchorToCurrentSentence()
        play()
    }

    private func enqueueSentence(at index: Int) {
        guard plan.sentences.indices.contains(index) else { return }
        let sentence = plan.sentences[index].text
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = preferredVoice(for: sentence)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.86
        utterance.pitchMultiplier = isDialogue(sentence) ? 1.06 : 1
        utterance.preUtteranceDelay = index == currentSentenceIndex ? 0 : 0.035
        queuedSentenceIndices[ObjectIdentifier(utterance)] = index
        synthesizer.speak(utterance)
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

    private func preferredVoice(for sentence: String) -> AVSpeechSynthesisVoice? {
        if isDialogue(sentence) {
            for language in ["zh-TW", "zh-HK", "zh-CN"] {
                if let voice = AVSpeechSynthesisVoice(language: language) { return voice }
            }
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh") }
    }

    private func isDialogue(_ sentence: String) -> Bool {
        guard let first = sentence.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return "\"“「『".contains(first)
    }

    private func advanceInBackground() {
        guard let currentIndex = sessionPageIndex else {
            stop()
            return
        }
        let nextIndex = currentIndex + 1
        guard sessionPages.indices.contains(nextIndex) else {
            stop()
            return
        }
        sessionPageIndex = nextIndex
        let nextPage = sessionPages[nextIndex]
        setPage(text: nextPage.text, location: nextPage.location)
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

extension ReadAloudService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = queuedSentenceIndices[identifier], plan.sentences.indices.contains(index) else { return }
            currentSentenceIndex = index
            currentSentenceRange = plan.sentences[index].range
            nextSentenceIndex = index
            guard playbackRequested else {
                self.synthesizer.pauseSpeaking(at: .immediate)
                state = .paused(sentence: index)
                updateNowPlayingInfo()
                return
            }
            state = .playing(sentence: index)
            synchronizeNowPlayingAnchorToCurrentSentence()
            updateNowPlayingInfo()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let finishedIndex = queuedSentenceIndices.removeValue(forKey: identifier) else { return }
            let candidate = finishedIndex + 1
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
            queuedSentenceIndices.removeAll()
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
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if playbackRequested {
                self.synthesizer.continueSpeaking()
            } else {
                state = .paused(sentence: currentSentenceIndex)
                updateNowPlayingInfo()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard playbackRequested else {
                self.synthesizer.pauseSpeaking(at: .immediate)
                return
            }
            state = .playing(sentence: currentSentenceIndex)
            nowPlayingAnchorDate = .now
            updateNowPlayingInfo()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            queuedSentenceIndices.removeValue(forKey: identifier)
        }
    }
}
