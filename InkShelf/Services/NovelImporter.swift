import Foundation
import CoreFoundation
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

struct ImportedNovel: Sendable {
    let title: String
    let author: String
    let content: String
    let format: BookFormat
    let coverData: Data?
}

enum ImportError: LocalizedError {
    case unsupported
    case invalidEPUB
    case empty
    case fileTooLarge(megabytes: Int)
    case cannotRead
    case cannotDecode

    var errorDescription: String? {
        switch self {
        case .unsupported: return "暂不支持这种文件格式"
        case .invalidEPUB: return "EPUB 文件结构损坏或缺少正文"
        case .empty: return "文件中没有可阅读的正文"
        case let .fileTooLarge(megabytes): return "文件超过 \(megabytes) MB，请拆分后再导入"
        case .cannotRead: return "无法读取这个文件，请确认文件已下载到本机后重试"
        case .cannotDecode: return "无法识别文本编码，建议转换为 UTF-8、GBK 或 GB18030"
        }
    }
}

enum NovelImporter {
    static let maximumFileSize = 200 * 1_024 * 1_024

    static let supportedTypes: [UTType] = [
        .text,
        .plainText,
        .utf8PlainText,
        .utf16PlainText,
        .data,
        UTType(filenameExtension: "txt") ?? .plainText,
        UTType(filenameExtension: "md") ?? .plainText,
        .epub
    ]

    static func readFile(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile != false else { throw ImportError.cannotRead }
                if let size = values.fileSize, size > maximumFileSize {
                    throw ImportError.fileTooLarge(megabytes: maximumFileSize / 1_024 / 1_024)
                }
                return try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            }
        }
        if coordinationError != nil, result == nil { throw ImportError.cannotRead }
        guard let result else { throw ImportError.cannotRead }
        do { return try result.get() } catch let error as ImportError { throw error } catch { throw ImportError.cannotRead }
    }

    static func parse(data: Data, fileName: String, pathExtension: String) throws -> ImportedNovel {
        let fileExtension = pathExtension.lowercased()
        if fileExtension == "epub" {
            return try EPUBParser.parse(data: data, fallbackTitle: fileName)
        }
        guard fileExtension.isEmpty || ["txt", "text", "md", "markdown"].contains(fileExtension) else {
            throw ImportError.unsupported
        }
        guard let text = decode(data) else { throw ImportError.cannotDecode }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        return ImportedNovel(
            title: fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名小说" : fileName,
            author: "佚名",
            content: text,
            format: ["md", "markdown"].contains(fileExtension) ? .markdown : .txt,
            coverData: nil
        )
    }

    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(4))

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) {
            return normalized(value)
        }
        if bytes.starts(with: [0xFF, 0xFE]),
           let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return normalized(value)
        }
        if bytes.starts(with: [0xFE, 0xFF]),
           let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return normalized(value)
        }
        if let value = String(data: data, encoding: .utf8) { return normalized(value) }

        if likelyUTF16(data) {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let value = String(data: data, encoding: encoding), isPlausible(value) {
                    return normalized(value)
                }
            }
        }

        let legacyEncodings = [
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )),
            String.Encoding.windowsCP1252
        ]
        for encoding in legacyEncodings {
            if let value = String(data: data, encoding: encoding), isPlausible(value) {
                return normalized(value)
            }
        }
        return nil
    }

    private static func likelyUTF16(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(4_096))
        guard sample.count >= 4 else { return false }
        let evenZeros = stride(from: 0, to: sample.count, by: 2).reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        let oddZeros = stride(from: 1, to: sample.count, by: 2).reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        return max(evenZeros, oddZeros) > sample.count / 8
    }

    private static func isPlausible(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let sample = text.prefix(4_096)
        let invalidControls = sample.reduce(0) { count, character in
            guard let scalar = character.unicodeScalars.first else { return count }
            return count + ((scalar.value < 0x20 && !"\n\r\t".unicodeScalars.contains(scalar)) ? 1 : 0)
        }
        return invalidControls * 50 < sample.count
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\0", with: "")
    }
}

private enum EPUBParser {
    static func parse(data: Data, fallbackTitle: String) throws -> ImportedNovel {
        let archive = try Archive(data: data, accessMode: .read)
        guard let container = read("META-INF/container.xml", from: archive),
              let containerText = String(data: container, encoding: .utf8),
              let opfPath = firstCapture(#"full-path\s*=\s*[\"']([^\"']+)[\"']"#, in: containerText),
              let opfData = read(opfPath, from: archive),
              let opf = String(data: opfData, encoding: .utf8) else { throw ImportError.invalidEPUB }

        let directory = (opfPath as NSString).deletingLastPathComponent
        let title = decodedXML(firstCapture(#"<dc:title[^>]*>(.*?)</dc:title>"#, in: opf) ?? fallbackTitle)
        let author = decodedXML(firstCapture(#"<dc:creator[^>]*>(.*?)</dc:creator>"#, in: opf) ?? "佚名")
        let manifest = manifestItems(in: opf)
        let spineIDs = captures(#"<itemref[^>]+idref\s*=\s*[\"']([^\"']+)[\"'][^>]*/?>"#, in: opf)

        var sections: [(title: String, text: String)] = []
        for id in spineIDs {
            guard let item = manifest[id],
                  item.mediaType.contains("html"),
                  let htmlData = read(join(directory, item.href), from: archive),
                  let text = htmlText(htmlData),
                  !text.isEmpty else { continue }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let sectionTitle = firstLine.count <= 60 ? firstLine : ""
            sections.append((sectionTitle, text))
        }
        guard !sections.isEmpty else { throw ImportError.invalidEPUB }

        let coverID = firstCapture(#"<meta[^>]+name\s*=\s*[\"']cover[\"'][^>]+content\s*=\s*[\"']([^\"']+)[\"']"#, in: opf)
        let coverItem = manifest.values.first(where: { $0.properties.contains("cover-image") }) ?? coverID.flatMap { manifest[$0] }
        let coverData = coverItem.flatMap { read(join(directory, $0.href), from: archive) }

        return ImportedNovel(
            title: title,
            author: author,
            content: sections.enumerated().map {
                let suffix = $0.element.title.isEmpty ? "" : " \($0.element.title)"
                return "第\($0.offset + 1)章\(suffix)\n\n\($0.element.text)"
            }.joined(separator: "\n\n"),
            format: .epub,
            coverData: coverData
        )
    }

    private struct ManifestItem { let href: String; let mediaType: String; let properties: String }

    private static func manifestItems(in xml: String) -> [String: ManifestItem] {
        guard let regex = try? NSRegularExpression(pattern: #"<item\s+([^>]+)/?>"#, options: [.caseInsensitive]) else { return [:] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        var result: [String: ManifestItem] = [:]
        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[range])
            guard let id = attribute("id", in: attributes), let href = attribute("href", in: attributes) else { continue }
            result[id] = ManifestItem(
                href: href.removingPercentEncoding ?? href,
                mediaType: attribute("media-type", in: attributes) ?? "",
                properties: attribute("properties", in: attributes) ?? ""
            )
        }
        return result
    }

    private static func read(_ path: String, from archive: Archive) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        do { _ = try archive.extract(entry) { data.append($0) } } catch { return nil }
        return data
    }

    private static func join(_ directory: String, _ path: String) -> String {
        let joined = directory.isEmpty ? path : (directory as NSString).appendingPathComponent(path)
        var components: [String] = []
        for part in joined.split(separator: "/").map(String.init) {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        return components.joined(separator: "/")
    }

    private static func attribute(_ name: String, in source: String) -> String? {
        firstCapture("\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']", in: source)
    }

    private static func firstCapture(_ pattern: String, in source: String) -> String? { captures(pattern, in: source).first }

    private static func captures(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }

    private static func decodedXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlText(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
