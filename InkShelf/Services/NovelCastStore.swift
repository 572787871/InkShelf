import CryptoKit
import Foundation

struct NovelCastAssignment: Codable, Equatable, Sendable {
    enum Voice: Codable, Equatable, Sendable {
        case firstPersonNarrator
        case thirdPersonNarrator
        case character(String)
        case unknownDialogue(Int)
    }

    let utf16Location: Int
    let utf16Length: Int
    let voice: Voice

    var range: NSRange {
        NSRange(location: utf16Location, length: utf16Length)
    }

    init(range: NSRange, speaker: ReadAloudSpeaker) {
        utf16Location = range.location
        utf16Length = range.length
        switch speaker {
        case .narrator:
            voice = .firstPersonNarrator
        case .thirdPersonNarrator:
            voice = .thirdPersonNarrator
        case let .character(name):
            voice = .character(name)
        case let .unknownDialogue(turn):
            voice = .unknownDialogue(turn)
        }
    }

    var speaker: ReadAloudSpeaker {
        switch voice {
        case .firstPersonNarrator: .narrator
        case .thirdPersonNarrator: .thirdPersonNarrator
        case let .character(name): .character(name)
        case let .unknownDialogue(turn): .unknownDialogue(turn: turn)
        }
    }
}

struct NovelCastChapter: Codable, Equatable, Sendable {
    let chapterIndex: Int
    let contentSignature: String
    let assignments: [NovelCastAssignment]
    let characterGenders: [String: NovelCharacterGender]
    let analyzedAt: Date

    private enum CodingKeys: String, CodingKey {
        case chapterIndex, contentSignature, assignments, characterGenders, analyzedAt
    }

    init(
        chapterIndex: Int,
        contentSignature: String,
        assignments: [NovelCastAssignment],
        characterGenders: [String: NovelCharacterGender],
        analyzedAt: Date
    ) {
        self.chapterIndex = chapterIndex
        self.contentSignature = contentSignature
        self.assignments = assignments
        self.characterGenders = characterGenders
        self.analyzedAt = analyzedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        contentSignature = try container.decode(String.self, forKey: .contentSignature)
        assignments = try container.decode([NovelCastAssignment].self, forKey: .assignments)
        characterGenders = try container.decodeIfPresent(
            [String: NovelCharacterGender].self,
            forKey: .characterGenders
        ) ?? [:]
        analyzedAt = try container.decode(Date.self, forKey: .analyzedAt)
    }

    static func make(
        chapterIndex: Int,
        text: String,
        plan: ReadAloudRolePlan,
        characterGenders: [String: NovelCharacterGender] = [:]
    ) -> NovelCastChapter {
        let location = ReaderPageLocation(chapterIndex: chapterIndex, pageIndex: 0)
        let sentences = ReadAloudTextPlan(text: text).sentences
        let speakers = plan.speakers(for: location) ?? []
        let assignments: [NovelCastAssignment] = sentences.enumerated().compactMap {
            index, sentence -> NovelCastAssignment? in
            guard speakers.indices.contains(index) else { return nil }
            return NovelCastAssignment(range: sentence.range, speaker: speakers[index])
        }
        return NovelCastChapter(
            chapterIndex: chapterIndex,
            contentSignature: NovelCastStore.signature(for: text),
            assignments: assignments,
            characterGenders: characterGenders,
            analyzedAt: .now
        )
    }

    func plan(
        for pages: [ReaderPage],
        fallback: ReadAloudRolePlan
    ) -> ReadAloudRolePlan {
        let orderedPages = pages.sorted { $0.location.pageIndex < $1.location.pageIndex }
        guard NovelCastStore.signature(for: orderedPages.map(\.text).joined()) == contentSignature else {
            return fallback
        }
        var combined = fallback.speakersByPage
        var chapterOffset = 0
        var assignmentIndex = 0

        for page in orderedPages {
            let sentences = ReadAloudTextPlan(text: page.text).sentences
            var speakers = combined[page.location]
                ?? Array(repeating: ReadAloudSpeaker.thirdPersonNarrator, count: sentences.count)
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let globalRange = NSRange(
                    location: chapterOffset + sentence.range.location,
                    length: sentence.range.length
                )
                while assignmentIndex < assignments.count,
                      NSMaxRange(assignments[assignmentIndex].range) <= globalRange.location {
                    assignmentIndex += 1
                }
                guard assignmentIndex < assignments.count else { continue }
                let assignment = assignments[assignmentIndex]
                if NSIntersectionRange(globalRange, assignment.range).length > 0,
                   speakers.indices.contains(sentenceIndex) {
                    speakers[sentenceIndex] = assignment.speaker
                }
            }
            combined[page.location] = speakers
            chapterOffset += (page.text as NSString).length
        }
        return ReadAloudRolePlan(speakersByPage: combined)
    }

    var characterNames: [String] {
        Array(Set(assignments.compactMap { assignment in
            if case let .character(name) = assignment.voice { return name }
            return nil
        })).sorted()
    }
}

struct NovelCastStore: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootURL = support.appendingPathComponent("NovelCasts", isDirectory: true)
        }
    }

    func load(
        bookID: UUID,
        chapterIndex: Int,
        chapterText: String
    ) -> NovelCastChapter? {
        let url = chapterURL(bookID: bookID, chapterIndex: chapterIndex)
        guard let data = try? Data(contentsOf: url),
              let chapter = try? JSONDecoder().decode(NovelCastChapter.self, from: data),
              chapter.contentSignature == Self.signature(for: chapterText) else { return nil }
        return chapter
    }

    func save(_ chapter: NovelCastChapter, bookID: UUID) throws {
        let directory = bookDirectory(bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(chapter)
        try data.write(
            to: chapterURL(bookID: bookID, chapterIndex: chapter.chapterIndex),
            options: .atomic
        )
    }

    func remove(bookID: UUID) throws {
        let directory = bookDirectory(bookID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static func signature(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func bookDirectory(_ bookID: UUID) -> URL {
        rootURL.appendingPathComponent(bookID.uuidString.lowercased(), isDirectory: true)
    }

    private func chapterURL(bookID: UUID, chapterIndex: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("chapter-\(chapterIndex).json")
    }
}
