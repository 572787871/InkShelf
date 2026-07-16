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
    let coverData: Data?
    let coverStyle: Int
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

    var onPageFinished: (() -> Void)?
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }
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
    private var interruptionObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false

    override init() {
        super.init()
        synthesizer.delegate = self
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
        bookContext = ReadAloudBookContext(
            id: book.id,
            title: book.title,
            coverData: book.coverData,
            coverStyle: book.coverStyle
        )
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
        if continuePlaying { play() }
    }

    func refreshSessionPages(_ pages: [ReaderPage], for bookID: UUID) {
        guard bookContext?.id == bookID, let currentPageLocation else { return }
        sessionPages = pages
        sessionPageIndex = pages.firstIndex { $0.location == currentPageLocation }
            ?? pages.lastIndex {
                $0.location.chapterIndex == currentPageLocation.chapterIndex
                    && $0.location.pageIndex <= currentPageLocation.pageIndex
            }
            ?? pages.firstIndex {
                $0.location.chapterIndex == currentPageLocation.chapterIndex
            }
    }

    func setPage(text: String, location: ReaderPageLocation, startAtUTF16Location: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll(keepingCapacity: true)
        plan = ReadAloudTextPlan(text: text)
        currentPageLocation = location

        guard let startIndex = plan.sentenceIndex(atOrAfterUTF16Location: startAtUTF16Location) else {
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
    }

    func play() {
        guard hasSession else { return }
        guard configureAudioSession() else { return }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .playing(sentence: currentSentenceIndex)
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
        updateNowPlayingInfo()
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused(sentence: currentSentenceIndex)
        updateNowPlayingInfo()
    }

    func stop() {
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
        onPageFinished = nil
        shouldResumeAfterInterruption = false
        state = .unavailable
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(fromUTF16Location location: Int) {
        guard let index = plan.sentenceIndex(atOrAfterUTF16Location: location) else { return }
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll(keepingCapacity: true)
        currentSentenceIndex = index
        currentSentenceRange = plan.sentences[index].range
        nextSentenceIndex = index
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
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
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

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying { self.pause() } else { self.play() }
            }
            return .success
        }
        commands.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookContext.title,
            MPMediaItemPropertyArtist: "墨架朗读",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        let coverImage = bookContext.coverData.flatMap { UIImage(data: $0) }
            ?? UIImage(named: BookPalette.defaultCoverAssetName(for: bookContext.coverStyle))
        if let coverImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: coverImage.size) { _ in coverImage }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
            state = .playing(sentence: index)
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
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            queuedSentenceIndices.removeValue(forKey: identifier)
        }
    }
}
