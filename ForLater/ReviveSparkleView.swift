import SwiftUI
import Vortex

/// A one-shot purple sparkle burst, shown when an item is revived from the archive.
struct ReviveSparkleView: View {
    private static func makeSystem() -> VortexSystem {
        VortexSystem(
            tags: ["sparkle"],
            shape: .ring(radius: 0.12),
            birthRate: 0,
            burstCount: 70,
            lifespan: 1.2,
            lifespanVariation: 0.3,
            speed: 0.45,
            speedVariation: 0.25,
            angleRange: .degrees(360),
            dampingFactor: 2,
            angularSpeedVariation: [0, 0, 8],
            colors: .random(
                .purple,
                .pink,
                .white,
                VortexSystem.Color(red: 0.75, green: 0.55, blue: 1)
            ),
            size: 0.6,
            sizeVariation: 0.4,
            sizeMultiplierAtDeath: 0.01
        )
    }

    @State private var system = ReviveSparkleView.makeSystem()

    var body: some View {
        VortexViewReader { proxy in
            VortexView(system) {
                Image(systemName: "sparkle")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .tag("sparkle")
            }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.burst()
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
