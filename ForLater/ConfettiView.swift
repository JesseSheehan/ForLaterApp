import SwiftUI

/// Placeholder confetti for a cleared desk. To be swapped for Jesse's graphics.
struct ConfettiView: View {
    private struct Piece {
        let x: CGFloat          // 0...1 across the screen
        let delay: Double
        let speed: Double       // screen heights per second
        let drift: CGFloat
        let spin: Double
        let size: CGSize
        let color: Color
    }

    private let pieces: [Piece] = (0..<90).map { _ in
        Piece(
            x: .random(in: 0...1),
            delay: .random(in: 0...0.8),
            speed: .random(in: 0.35...0.7),
            drift: .random(in: -40...40),
            spin: .random(in: 180...720),
            size: CGSize(width: .random(in: 6...11), height: .random(in: 10...16)),
            color: [Color.red, .orange, .yellow, .green, .blue, .purple, .pink].randomElement()!
        )
    }

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0 else { continue }
                    let y = -20 + CGFloat(t * piece.speed) * size.height
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + sin(t * 3) * piece.drift
                    var pieceContext = context
                    pieceContext.translateBy(x: x, y: y)
                    pieceContext.rotate(by: .degrees(piece.spin * t))
                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2,
                                      width: piece.size.width, height: piece.size.height)
                    pieceContext.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear { start = Date() }
    }
}
