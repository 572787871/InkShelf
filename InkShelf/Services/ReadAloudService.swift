import Foundation
import Combine

/// AI 配音接入点。未来可用网络 TTS 实现替换 `DisabledReadAloudService`。
@MainActor
protocol ReadAloudService: AnyObject {
    var state: ReadAloudState { get }
    func prepare(book: NovelBook, chapter: NovelChapter) async throws
    func play() async
    func pause()
    func stop()
    func seek(to sentence: Int)
}

enum ReadAloudState: Equatable {
    case unavailable
    case preparing
    case ready
    case playing(sentence: Int)
    case paused(sentence: Int)
    case failed(message: String)
}

@MainActor
final class DisabledReadAloudService: ObservableObject, ReadAloudService {
    @Published private(set) var state: ReadAloudState = .unavailable
    func prepare(book: NovelBook, chapter: NovelChapter) async throws { }
    func play() async { }
    func pause() { }
    func stop() { }
    func seek(to sentence: Int) { }
}
