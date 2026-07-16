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
                Image(BookPalette.defaultCoverAssetName(for: book.coverStyle))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                LinearGradient(
                    colors: [.black.opacity(0.08), .clear, .black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            CoverMaterialTexture(seed: book.coverStyle)
                .blendMode(.softLight)
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

}

private struct CoverMaterialTexture: View {
    let seed: Int

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let normalizedSeed = abs(seed) + 1
            for index in 0..<18 {
                let x = size.width * CGFloat(index + 1) / 19
                var fiber = Path()
                fiber.move(to: CGPoint(x: x, y: 0))
                for step in 1...12 {
                    let y = size.height * CGFloat(step) / 12
                    let wave = sin(CGFloat(step * normalizedSeed + index * 3) * 0.47) * 0.9
                    fiber.addLine(to: CGPoint(x: x + wave, y: y))
                }
                context.stroke(
                    fiber,
                    with: .color(index.isMultiple(of: 4) ? .white.opacity(0.13) : .black.opacity(0.08)),
                    lineWidth: 0.45
                )
            }

            for index in 0..<24 {
                let xUnit = CGFloat((index * 37 + normalizedSeed * 11) % 101) / 101
                let yUnit = CGFloat((index * 53 + normalizedSeed * 7) % 103) / 103
                let diameter = CGFloat(index.isMultiple(of: 5) ? 1.4 : 0.75)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: size.width * xUnit,
                        y: size.height * yUnit,
                        width: diameter,
                        height: diameter
                    )),
                    with: .color(.white.opacity(index.isMultiple(of: 3) ? 0.12 : 0.07))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
