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
