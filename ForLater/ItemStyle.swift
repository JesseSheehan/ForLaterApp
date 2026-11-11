import SwiftUI

extension ForLaterItem {
    /// Red when overdue, purple when revived from the archive, otherwise none.
    /// Overdue wins, since it needs attention first.
    func highlightColor(at now: Date = Date()) -> Color? {
        if isOverdue(at: now) { return .red }
        if isRevived { return .purple }
        return nil
    }
}

/// Category chip plus "Revived" / "Overdue" labels, shown on cards, rows and details.
struct ItemBadges: View {
    let item: ForLaterItem
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(item.category?.name ?? "No category")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
            Spacer(minLength: 0)
            if item.isRevived {
                Label("Revived", systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(Color.purple)
            }
            if item.isOverdue(at: now) {
                Label("Overdue", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.caption.weight(.semibold))
    }
}

// MARK: - Overdue shake

/// A quick side-to-side shake. One unit of `animatableData` is one full shake.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var wiggles: CGFloat = 4
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * wiggles), y: 0))
    }
}

/// Shakes an overdue view as soon as it's fully on screen (and, for the cards,
/// the one in focus), then every 15 seconds while it stays there. Swiping or
/// scrolling away stops the timer; coming back shakes it right away and starts
/// the timer again. Skipped when the user has Reduce Motion turned on.
private struct OverdueShake: ViewModifier {
    let isOverdue: Bool
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFullyVisible = false
    @State private var shakes: CGFloat = 0

    private var shouldShake: Bool {
        isOverdue && isFocused && isFullyVisible && scenePhase == .active && !reduceMotion
    }

    func body(content: Content) -> some View {
        content
            // Measured before the shake is applied, so the shake itself never
            // nudges the view "off screen" and stops the timer.
            .onGeometryChange(for: Bool.self) { proxy in
                Self.isFullyOnScreen(proxy.frame(in: .global))
            } action: { isFullyVisible = $0 }
            .modifier(ShakeEffect(animatableData: shakes))
            .task(id: shouldShake) {
                guard shouldShake else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 0.5)) { shakes += 1 }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
    }

    private static func isFullyOnScreen(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let screen = UIScreen.main.bounds.insetBy(dx: -1, dy: -1)
        return screen.contains(frame)
    }
}

extension View {
    /// - Parameter isFocused: false for a card that isn't the one in the middle.
    func overdueShake(_ isOverdue: Bool, isFocused: Bool = true) -> some View {
        modifier(OverdueShake(isOverdue: isOverdue, isFocused: isFocused))
    }
}
