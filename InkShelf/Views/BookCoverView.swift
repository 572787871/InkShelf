import SwiftUI
import UIKit

struct BookCoverView: View {
    let book: NovelBook
    var compact = false

    var body: some View {
        ZStack {
            if let data = book.coverData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: BookPalette.colors(for: book.coverStyle), startPoint: .topLeading, endPoint: .bottomTrailing)
                coverDecoration
            }
            LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
            Rectangle().fill(.white.opacity(0.16)).frame(width: 2).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 7)
        }
        .aspectRatio(0.68, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 5 : 7).stroke(.white.opacity(0.18), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.32), radius: 5, x: 3, y: 5)
        .accessibilityLabel("《\(book.title)》，作者 \(book.author)")
    }

    private var coverDecoration: some View {
        VStack(spacing: compact ? 6 : 12) {
            Text("墨 架")
                .font(.system(size: compact ? 7 : 9, weight: .semibold, design: .serif))
                .tracking(3)
                .opacity(0.68)
            Rectangle().fill(.white.opacity(0.55)).frame(width: 28, height: 1)
            Text(book.title)
                .font(.custom("Songti SC", size: compact ? 14 : 19).weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, compact ? 9 : 15)
            Spacer(minLength: 0)
            Text(book.author)
                .font(.system(size: compact ? 8 : 10, design: .serif))
                .opacity(0.72)
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(.vertical, compact ? 12 : 18)
    }
}
