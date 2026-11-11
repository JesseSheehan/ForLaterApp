import SwiftUI

/// A light band that sweeps down over a view, like it's being scanned.
/// Used on the screenshot while the AI reads it.
struct ScanShimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geometry.size.height * 0.4)
                    .offset(y: phase * geometry.size.height)
                    .opacity(reduceMotion ? 0.4 : 1)
                }
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
                .onAppear {
                    phase = -0.4
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

extension View {
    func scanShimmer(_ isActive: Bool) -> some View {
        modifier(ScanShimmer(isActive: isActive))
    }
}
