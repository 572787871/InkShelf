import CoreText
import ImageIO
import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper = "羊皮纸"
    case white = "纯白"
    case green = "护眼"
    case gray = "灰色"
    case night = "夜间"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "柔和米纸"
        case .white: return "暖白素纸"
        case .green: return "青竹护眼"
        case .gray: return "竹林暖茶"
        case .night: return "夜竹墨黑"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(hex: "EEE3CD")
        case .white: return Color(hex: "F6F3EB")
        case .green: return Color(hex: "DCE5D4")
        case .gray: return Color(hex: "E7D7B9")
        case .night: return Color(hex: "121922")
        }
    }

    var pageBack: Color {
        switch self {
        case .paper: return Color(hex: "E3D6BC")
        case .white: return Color(hex: "EAE7DF")
        case .green: return Color(hex: "D0DAC9")
        case .gray: return Color(hex: "DCC9A6")
        case .night: return Color(hex: "1C2530")
        }
    }

    var foreground: Color {
        switch self {
        case .paper: return Color(hex: "302A22")
        case .white: return Color(hex: "292824")
        case .green: return Color(hex: "273027")
        case .gray: return Color(hex: "34291E")
        case .night: return Color(hex: "C9C6BC")
        }
    }
}

enum ReaderBackgroundStyle: String, CaseIterable, Identifiable {
    case plain = "纯净纸色"
    case bambooWhite = "竹影素白"
    case bambooRice = "竹韵米黄"
    case bambooGreen = "青竹护眼"
    case bambooTea = "竹林暖茶"
    case bambooNight = "夜竹墨黑"
    case custom = "自定义"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .plain: return "rectangle.fill"
        case .bambooWhite: return "leaf"
        case .bambooRice: return "text.page"
        case .bambooGreen: return "camera.macro"
        case .bambooTea: return "sun.haze"
        case .bambooNight: return "moon.stars.fill"
        case .custom: return "plus"
        }
    }

    var recommendedTheme: ReaderTheme? {
        switch self {
        case .plain, .custom: return nil
        case .bambooWhite: return .white
        case .bambooRice: return .paper
        case .bambooGreen: return .green
        case .bambooTea: return .gray
        case .bambooNight: return .night
        }
    }

    var usesBundledArtwork: Bool {
        switch self {
        case .bambooWhite, .bambooRice, .bambooGreen, .bambooTea, .bambooNight: return true
        case .plain, .custom: return false
        }
    }

    var readabilityOverlayOpacity: CGFloat {
        switch self {
        case .plain: return 0
        case .custom: return 0.66
        case .bambooNight: return 0.84
        case .bambooWhite, .bambooRice, .bambooGreen, .bambooTea: return 0.73
        }
    }
}

enum ReaderCustomBackgroundTone: String, CaseIterable, Identifiable {
    case light = "白"
    case dark = "黑"

    var id: String { rawValue }
    var theme: ReaderTheme { self == .light ? .white : .night }
    var overlayColor: Color { self == .light ? .white : Color(hex: "10151C") }
    var previewTextColor: Color { self == .light ? Color(hex: "25231F") : Color(hex: "D3D0C8") }
}

enum ReaderCustomBackgroundBlur: String, CaseIterable, Identifiable {
    case none = "无"
    case low = "低"
    case medium = "中"
    case high = "高"

    var id: String { rawValue }

    var previewRadius: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 2.5
        case .medium: return 6
        case .high: return 12
        }
    }

    func effectStyle(isDark: Bool) -> UIBlurEffect.Style? {
        switch (self, isDark) {
        case (.none, _): return nil
        case (.low, false): return .systemUltraThinMaterialLight
        case (.medium, false): return .systemThinMaterialLight
        case (.high, false): return .systemMaterialLight
        case (.low, true): return .systemUltraThinMaterialDark
        case (.medium, true): return .systemThinMaterialDark
        case (.high, true): return .systemMaterialDark
        }
    }
}

enum PageTurnStyle: String, CaseIterable, Identifiable {
    case curl = "仿真"
    case slide = "覆盖"
    case vertical = "滚动"
    case none = "无动画"
    var id: String { rawValue }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case system = "系统"
    case song = "宋体"
    case kai = "楷体"
    case sourceHanSans = "思源黑体"

    var id: String { rawValue }

    var name: String? {
        ReaderFontRegistry.registerBundledFonts()
        switch self {
        case .system: return nil
        case .song: return "NotoSerifCJKsc-Regular"
        case .kai: return "LXGWWenKai-Regular"
        case .sourceHanSans: return "NotoSansCJKsc-Regular"
        }
    }

    var displayName: String {
        switch self {
        case .system: return "系统"
        case .song: return "思源宋体"
        case .kai: return "霞鹜文楷"
        case .sourceHanSans: return "思源黑体"
        }
    }
}

enum ReaderFontRegistry {
    private static let fonts: [(resource: String, fileExtension: String)] = [
        ("NotoSerifCJKsc-Regular", "otf"),
        ("LXGWWenKai-Regular", "ttf"),
        ("NotoSansCJKsc-Regular", "otf")
    ]

    private static let registration: Void = {
        for font in fonts {
            let url = Bundle.main.url(
                forResource: font.resource,
                withExtension: font.fileExtension,
                subdirectory: "Fonts"
            ) ?? Bundle.main.url(forResource: font.resource, withExtension: font.fileExtension)
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerBundledFonts() {
        _ = registration
    }
}

enum ReaderCustomBackgroundError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取所选背景图片"
        case .encodingFailed: return "无法生成阅读背景图片"
        }
    }
}

enum ReaderCustomBackgroundStore {
    private static let maximumPixelSize = 2560

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    @discardableResult
    static func save(sourceData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw ReaderCustomBackgroundError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else {
            throw ReaderCustomBackgroundError.encodingFailed
        }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try encoded.write(to: fileURL, options: .atomic)
        return encoded
    }

    private static var storageDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("InkShelf", isDirectory: true)
    }

    private static var fileURL: URL {
        storageDirectory.appendingPathComponent("reader-custom-background.jpg")
    }
}
