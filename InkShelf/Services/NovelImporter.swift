import Foundation
import CoreFoundation
import OSLog
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

struct ImportedNovel: Sendable {
    let title: String
    let author: String
    let content: String
    let format: BookFormat
    let coverData: Data?
    let detectedEncoding: String?
}

struct StagedNovelFile: Sendable {
    let localURL: URL
    let cleanupURL: URL
    let originalFileName: String
    let pathExtension: String
    let fileSize: Int
}

struct DecodedNovelText: Sendable {
    let text: String
    let encodingName: String
}

enum ImportLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InkShelf",
        category: "NovelImport"
    )
}

enum ImportError: LocalizedError, Equatable {
    case unsupported
    case invalidEPUB
    case empty
    case fileTooLarge(megabytes: Int)
    case noFileSelected
    case cannotAccess
    case iCloudNotDownloaded
    case cannotCopy
    case cannotRead
    case cannotDecode
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return "文件格式不支持，请选择 TXT、Markdown 或 EPUB 文件"
        case .invalidEPUB: return "EPUB 文件结构损坏或缺少正文"
        case .empty: return "文件为空，没有可阅读的正文"
        case let .fileTooLarge(megabytes): return "文件超过 \(megabytes) MB，请拆分后再导入"
        case .noFileSelected: return "文件选择器没有返回可导入的文件"
        case .cannotAccess: return "无法访问文件，请在“文件”App 中确认它仍然可用"
        case .iCloudNotDownloaded: return "iCloud 文件尚未下载，请联网后重试"
        case .cannotCopy: return "无法将文件复制到 App 沙盒，请检查可用存储空间"
        case .cannotRead: return "无法读取文件，请确认文件完整且已下载到本机"
        case .cannotDecode: return "无法识别文本编码，建议转换为 UTF-8、UTF-16、GBK 或 GB18030"
        case .saveFailed: return "保存失败，请检查设备可用存储空间后重试"
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
        UTType(filenameExtension: "txt") ?? .plainText,
        UTType(filenameExtension: "md") ?? .plainText,
        .epub,
        .data
    ]

    static func copyToSandbox(from sourceURL: URL, stagingDirectory: URL) throws -> StagedNovelFile {
        try prepareUbiquitousFileIfNeeded(at: sourceURL)

        let fileManager = FileManager.default
        let importDirectory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        } catch {
            ImportLog.logger.error("创建导入临时目录失败：\(error.localizedDescription, privacy: .public)")
            throw ImportError.cannotCopy
        }

        let sourceName = sourceURL.lastPathComponent.isEmpty ? "未命名.txt" : sourceURL.lastPathComponent
        let destinationURL = importDirectory.appendingPathComponent(sourceName, isDirectory: false)
        var coordinationError: NSError?
        var operationError: Error?
        var copiedSize = 0

        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile != false else { throw ImportError.cannotRead }
                if let size = values.fileSize, size > maximumFileSize {
                    throw ImportError.fileTooLarge(megabytes: maximumFileSize / 1_024 / 1_024)
                }
                try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                copiedSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if copiedSize > maximumFileSize {
                    throw ImportError.fileTooLarge(megabytes: maximumFileSize / 1_024 / 1_024)
                }
            } catch {
                operationError = error
            }
        }

        if let error = operationError {
            try? fileManager.removeItem(at: importDirectory)
            throw mappedFileError(error)
        }
        if let coordinationError {
            ImportLog.logger.error("文件协调读取失败：\(coordinationError.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: importDirectory)
            throw mappedFileError(coordinationError)
        }
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try? fileManager.removeItem(at: importDirectory)
            throw ImportError.cannotCopy
        }

        ImportLog.logger.info("文件已复制到沙盒：\(destinationURL.lastPathComponent, privacy: .public)，大小 \(copiedSize, privacy: .public) 字节")
        return StagedNovelFile(
            localURL: destinationURL,
            cleanupURL: importDirectory,
            originalFileName: sourceURL.deletingPathExtension().lastPathComponent,
            pathExtension: sourceURL.pathExtension,
            fileSize: copiedSize
        )
    }

    static func removeStagedFile(_ stagedFile: StagedNovelFile) {
        do {
            try FileManager.default.removeItem(at: stagedFile.cleanupURL)
        } catch {
            ImportLog.logger.error("清理导入临时文件失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    static func readFile(at url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else { throw ImportError.cannotRead }
            if let size = values.fileSize, size > maximumFileSize {
                throw ImportError.fileTooLarge(megabytes: maximumFileSize / 1_024 / 1_024)
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as ImportError {
            throw error
        } catch {
            ImportLog.logger.error("读取沙盒文件失败：\(error.localizedDescription, privacy: .public)")
            throw ImportError.cannotRead
        }
    }

    static func parse(data: Data, fileName: String, pathExtension: String) throws -> ImportedNovel {
        let fileExtension = pathExtension.lowercased()
        if fileExtension == "epub" {
            return try EPUBParser.parse(data: data, fallbackTitle: fileName)
        }
        guard fileExtension.isEmpty || ["txt", "text", "md", "markdown"].contains(fileExtension) else {
            throw ImportError.unsupported
        }
        guard !data.isEmpty else { throw ImportError.empty }
        guard let decoded = decodeText(data) else { throw ImportError.cannotDecode }
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        return ImportedNovel(
            title: fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名小说" : fileName,
            author: "佚名",
            content: decoded.text,
            format: ["md", "markdown"].contains(fileExtension) ? .markdown : .txt,
            coverData: nil,
            detectedEncoding: decoded.encodingName
        )
    }

    static func decode(_ data: Data) -> String? {
        decodeText(data)?.text
    }

    static func decodeText(_ data: Data) -> DecodedNovelText? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(4))

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) {
            return DecodedNovelText(text: normalized(value), encodingName: "UTF-8 BOM")
        }
        if bytes.starts(with: [0xFF, 0xFE]),
           let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return DecodedNovelText(text: normalized(value), encodingName: "UTF-16 LE")
        }
        if bytes.starts(with: [0xFE, 0xFF]),
           let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return DecodedNovelText(text: normalized(value), encodingName: "UTF-16 BE")
        }
        if let value = String(data: data, encoding: .utf8) {
            return DecodedNovelText(text: normalized(value), encodingName: "UTF-8")
        }

        if likelyUTF16(data) {
            for (encoding, name) in utf16Candidates(for: data) {
                if let value = String(data: data, encoding: encoding), isPlausible(value) {
                    return DecodedNovelText(text: normalized(value), encodingName: name)
                }
            }
        }

        let legacyEncodings = [
            (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )), "GB18030 / GBK"),
            (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
            )), "GBK"),
            (String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )), "Big5")
        ]
        for (encoding, name) in legacyEncodings {
            if let value = String(data: data, encoding: encoding), isPlausible(value) {
                return DecodedNovelText(text: normalized(value), encodingName: name)
            }
        }
        return nil
    }

    private static func prepareUbiquitousFileIfNeeded(at url: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey
        ]
        let initialValues: URLResourceValues
        do {
            initialValues = try url.resourceValues(forKeys: keys)
        } catch {
            throw mappedFileError(error)
        }
        guard initialValues.isUbiquitousItem == true else { return }
        if isDownloaded(initialValues.ubiquitousItemDownloadingStatus) { return }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            ImportLog.logger.error("启动 iCloud 下载失败：\(error.localizedDescription, privacy: .public)")
            throw ImportError.iCloudNotDownloaded
        }

        let deadline = Date().addingTimeInterval(30)
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            let values = try? url.resourceValues(forKeys: keys)
            if let downloadError = values?.ubiquitousItemDownloadingError {
                ImportLog.logger.error("iCloud 下载失败：\(downloadError.localizedDescription, privacy: .public)")
                throw ImportError.iCloudNotDownloaded
            }
            if isDownloaded(values?.ubiquitousItemDownloadingStatus) { return }
        } while Date() < deadline

        throw ImportError.iCloudNotDownloaded
    }

    private static func isDownloaded(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .current || status == .downloaded
    }

    private static func mappedFileError(_ error: Error) -> ImportError {
        if let importError = error as? ImportError { return importError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return .cannotAccess
        }
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError].contains(nsError.code) {
            return .cannotCopy
        }
        return .cannotRead
    }

    private static func utf16Candidates(for data: Data) -> [(String.Encoding, String)] {
        let sample = [UInt8](data.prefix(4_096))
        let evenZeros = stride(from: 0, to: sample.count, by: 2).reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        let oddZeros = stride(from: 1, to: sample.count, by: 2).reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        if oddZeros >= evenZeros {
            return [(.utf16LittleEndian, "UTF-16 LE"), (.utf16BigEndian, "UTF-16 BE")]
        }
        return [(.utf16BigEndian, "UTF-16 BE"), (.utf16LittleEndian, "UTF-16 LE")]
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
            coverData: coverData,
            detectedEncoding: nil
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
