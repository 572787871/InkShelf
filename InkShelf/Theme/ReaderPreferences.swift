import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper = "羊皮纸"
    case white = "纯白"
    case green = "护眼"
    case night = "夜间"

    var id: String { rawValue }
    var background: Color {
        switch self {
        case .paper: return Color(hex: "F3E9D2")
        case .white: return Color(hex: "FAFAF8")
        case .green: return Color(hex: "DCE8D5")
        case .night: return Color(hex: "171A1F")
        }
    }
    var foreground: Color { self == .night ? Color(hex: "CAC6BD") : Color(hex: "27231F") }
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
