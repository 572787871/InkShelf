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
                Image(BookPalette.coverAssetName(for: book.coverStyle))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                coverDecoration
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.3), location: 0),
                    .init(color: .white.opacity(0.13), location: 0.12),
                    .init(color: .clear, location: 0.52),
                    .init(color: .black.opacity(0.25), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            bookSpine
        }
        .aspectRatio(0.68, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0.08), .black.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: compact ? 0.8 : 1.1
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 3 : 5, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 0.65)
                .padding(compact ? 5 : 7)
        }
        .shadow(color: .black.opacity(0.4), radius: compact ? 5 : 8, x: 3, y: compact ? 5 : 7)
        .accessibilityLabel("《\(book.title)》，作者 \(book.author)")
    }

    private var bookSpine: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.5), .white.opacity(0.15), .black.opacity(0.22), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: compact ? 9 : 13)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1)
            }
            Spacer(minLength: 0)
            Rectangle()
                .fill(.black.opacity(0.16))
                .frame(width: compact ? 1 : 1.5)
        }
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
        .shadow(color: .black.opacity(0.78), radius: 2, x: 0, y: 1)
        .padding(.vertical, compact ? 12 : 18)
    }
}
