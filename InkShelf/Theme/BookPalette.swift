import SwiftUI

enum BookPalette {
    static let styles: [[Color]] = [
        [Color(hex: "274C56"), Color(hex: "122B32")],
        [Color(hex: "9C4A38"), Color(hex: "59271F")],
        [Color(hex: "455B3F"), Color(hex: "263523")],
        [Color(hex: "6B5278"), Color(hex: "392B42")],
        [Color(hex: "B07835"), Color(hex: "6A421C")],
        [Color(hex: "385B79"), Color(hex: "20364A")]
    ]

    static func colors(for style: Int) -> [Color] { styles[abs(style) % styles.count] }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            opacity: 1
        )
    }
}
