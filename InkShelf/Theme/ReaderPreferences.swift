import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper = "羊皮纸"
    case white = "纯白"
    case green = "护眼"
    case gray = "灰色"
    case night = "夜间"

    var id: String { rawValue }
    var background: Color {
        switch self {
        case .paper: return Color(hex: "F3E9D2")
        case .white: return Color(hex: "FAFAF8")
        case .green: return Color(hex: "DCE8D5")
        case .gray: return Color(hex: "E4E2DE")
        case .night: return Color(hex: "171A1F")
        }
    }
    var pageBack: Color {
        switch self {
        case .paper: return Color(hex: "E9DDC3")
        case .white: return Color(hex: "F0EEE9")
        case .green: return Color(hex: "D1DDCB")
        case .gray: return Color(hex: "D8D6D1")
        case .night: return Color(hex: "202329")
        }
    }
    var foreground: Color { self == .night ? Color(hex: "CAC6BD") : Color(hex: "27231F") }
}

enum ReaderBackgroundStyle: String, CaseIterable, Identifiable {
    case plain = "纯色"
    case ricePaper = "宣纸"
    case bamboo = "竹影"
    case mist = "远山"
    case warmGlow = "暖光"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .plain: return "rectangle.fill"
        case .ricePaper: return "text.page"
        case .bamboo: return "leaf"
        case .mist: return "mountain.2"
        case .warmGlow: return "sun.haze"
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
    var id: String { rawValue }
    var name: String? {
        switch self {
        case .system: return nil
        case .song: return "Songti SC"
        case .kai: return "Kaiti SC"
        }
    }
}
