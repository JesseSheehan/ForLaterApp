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

/// Shakes the view now and every 15 seconds while it's overdue.
/// Skipped when the user has Reduce Motion turned on.
private struct OverdueShake: ViewModifier {
    let isOverdue: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakes: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(animatableData: shakes))
            .task(id: isOverdue) {
                guard isOverdue, !reduceMotion else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 0.5)) { shakes += 1 }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
    }
}

extension View {
    func overdueShake(_ isOverdue: Bool) -> some View {
        modifier(OverdueShake(isOverdue: isOverdue))
    }
}
