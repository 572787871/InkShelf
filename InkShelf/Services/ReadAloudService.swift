import Foundation
import AVFoundation
import Combine

enum ReadAloudState: Equatable {
    case unavailable
    case ready
    case playing(sentence: Int)
    case paused(sentence: Int)
    case failed(message: String)
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

    var onPageFinished: (() -> Void)?
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }
    var hasSession: Bool { currentPageLocation != nil && !plan.sentences.isEmpty }

    private let synthesizer = AVSpeechSynthesizer()
    private var plan = ReadAloudTextPlan(text: "")
    private var queuedSentenceIndices: [ObjectIdentifier: Int] = [:]
    private var nextSentenceIndex = 0

    override init() {
        super.init()
        synthesizer.delegate = self
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
            return
        }
        guard !synthesizer.isSpeaking else {
            state = .playing(sentence: currentSentenceIndex)
            return
        }
        enqueueSentence(at: nextSentenceIndex)
        state = .playing(sentence: currentSentenceIndex)
    }

    func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused(sentence: currentSentenceIndex)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queuedSentenceIndices.removeAll()
        plan = ReadAloudTextPlan(text: "")
        currentSentenceIndex = 0
        currentSentenceRange = nil
        currentPageLocation = nil
        nextSentenceIndex = 0
        state = .unavailable
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
            onPageFinished?()
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
