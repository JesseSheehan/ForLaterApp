import SwiftUI
import SwiftData

/// Everything marked Done. Revive brings an item back to the desk (in purple);
/// Delete removes it for good, screenshot and all.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<ForLaterItem> { $0.completedAt != nil },
           sort: \ForLaterItem.completedAt, order: .reverse)
    private var archived: [ForLaterItem]

    @State private var pendingDelete: ForLaterItem?
    @State private var viewing: ForLaterItem?

    var body: some View {
        Group {
            if archived.isEmpty {
                ContentUnavailableView(
                    "Nothing archived yet",
                    systemImage: "archivebox",
                    description: Text("Items you mark Done land here.")
                )
            } else {
                List {
                    ForEach(archived) { item in
                        ArchiveRow(item: item, onRevive: { revive(item) })
                            .contentShape(Rectangle())
                            .onTapGesture { viewing = item }
                            .swipeActions(edge: .leading) {
                                Button("Revive", systemImage: "arrow.uturn.backward") { revive(item) }
                                    .tint(.purple)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash") { pendingDelete = item }
                                    .tint(.red)
                            }
                    }
                }
            }
        }
        .navigationTitle("Archive")
        .sheet(item: $viewing) { item in
            ItemDetailView(item: item)
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete permanently", role: .destructive) {
                withAnimation { Archive.deletePermanently(item, in: context) }
            }
        } message: { _ in
            Text("This removes the item and its screenshot for good. It can't be undone.")
        }
    }

    private func revive(_ item: ForLaterItem) {
        withAnimation { Archive.revive(item, in: context) }
    }
}

private struct ArchiveRow: View {
    let item: ForLaterItem
    let onRevive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = item.screenshot, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.fill.tertiary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let category = item.category { Text(category.name) }
                    if let completedAt = item.completedAt {
                        Text("Archived \(completedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Revive", action: onRevive)
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
        }
    }
}
