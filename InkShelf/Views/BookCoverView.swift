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
                coverOrnament
                coverDecoration
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

    private var coverOrnament: some View {
        GeometryReader { proxy in
            Canvas(rendersAsynchronously: true) { context, size in
                let ink = Color.white.opacity(0.2)
                switch abs(book.coverStyle) % 3 {
                case 0:
                    var mountains = Path()
                    mountains.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.7))
                    mountains.addCurve(
                        to: CGPoint(x: size.width * 0.92, y: size.height * 0.64),
                        control1: CGPoint(x: size.width * 0.3, y: size.height * 0.46),
                        control2: CGPoint(x: size.width * 0.56, y: size.height * 0.78)
                    )
                    context.stroke(mountains, with: .color(ink), lineWidth: compact ? 0.7 : 1)
                case 1:
                    let moon = CGRect(
                        x: size.width * 0.62,
                        y: size.height * 0.17,
                        width: size.width * 0.18,
                        height: size.width * 0.18
                    )
                    context.stroke(Path(ellipseIn: moon), with: .color(ink), lineWidth: compact ? 0.8 : 1.2)
                    var water = Path()
                    for line in 0..<4 {
                        let y = size.height * (0.68 + CGFloat(line) * 0.045)
                        water.move(to: CGPoint(x: size.width * 0.17, y: y))
                        water.addCurve(
                            to: CGPoint(x: size.width * 0.83, y: y),
                            control1: CGPoint(x: size.width * 0.36, y: y - 3),
                            control2: CGPoint(x: size.width * 0.61, y: y + 3)
                        )
                    }
                    context.stroke(water, with: .color(ink.opacity(0.72)), lineWidth: 0.65)
                default:
                    var branch = Path()
                    branch.move(to: CGPoint(x: size.width * 0.75, y: size.height * 0.2))
                    branch.addCurve(
                        to: CGPoint(x: size.width * 0.36, y: size.height * 0.77),
                        control1: CGPoint(x: size.width * 0.68, y: size.height * 0.4),
                        control2: CGPoint(x: size.width * 0.52, y: size.height * 0.57)
                    )
                    context.stroke(branch, with: .color(ink), lineWidth: compact ? 0.8 : 1.1)
                    for leaf in 0..<5 {
                        let x = size.width * (0.67 - CGFloat(leaf) * 0.065)
                        let y = size.height * (0.31 + CGFloat(leaf) * 0.085)
                        let leafRect = CGRect(x: x, y: y, width: size.width * 0.1, height: size.height * 0.035)
                        context.stroke(Path(ellipseIn: leafRect), with: .color(ink.opacity(0.78)), lineWidth: 0.65)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
        .padding(.vertical, compact ? 12 : 18)
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
