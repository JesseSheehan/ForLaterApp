import SwiftUI
import Vortex

/// Confetti when the desk is cleared, using Vortex's confetti preset.
struct ConfettiView: View {
    var body: some View {
        VortexViewReader { proxy in
            VortexView(.confetti) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .tag("square")

                Circle()
                    .fill(.white)
                    .frame(width: 16)
                    .tag("circle")
            }
            .onAppear {
                Task { @MainActor in
                    // Give the particle system a moment to start, then fire two bursts.
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.burst()
                    try? await Task.sleep(for: .milliseconds(450))
                    proxy.burst()
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
