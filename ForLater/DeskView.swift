import SwiftUI
import SwiftData

/// The "desk": every For Later that hasn't been completed yet.
struct DeskView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(filter: #Predicate<ForLaterItem> { $0.completedAt == nil },
           sort: \ForLaterItem.remindAt)
    private var openItems: [ForLaterItem]

    @State private var editingItem: ForLaterItem?

    var body: some View {
        NavigationStack {
            Group {
                if openItems.isEmpty {
                    ContentUnavailableView(
                        "Your desk is clear",
                        systemImage: "checkmark.seal",
                        description: Text("Take a screenshot of something for later, then share it to For Later.")
                    )
                } else {
                    List {
                        ForEach(openItems) { item in
                            DeskRow(item: item, onComplete: { complete(item) })
                                .contentShape(Rectangle())
                                .onTapGesture { editingItem = item }
                                .swipeActions(edge: .leading) {
                                    Button("Done") { complete(item) }
                                        .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { delete(item) }
                                }
                        }
                    }
                }
            }
            .navigationTitle("For Later")
            .sheet(item: $editingItem) { item in
                NavigationStack {
                    ForLaterCardView(item: item, onDone: { editingItem = nil })
                }
            }
        }
        .task {
            DataStore.seedIfNeeded(context)
            await ScreenshotAnalyzer.processPending(in: context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await ScreenshotAnalyzer.processPending(in: context) }
            }
        }
    }

    private func complete(_ item: ForLaterItem) {
        withAnimation {
            item.completedAt = Date()
            try? context.save()
        }
    }

    private func delete(_ item: ForLaterItem) {
        withAnimation {
            context.delete(item)
            try? context.save()
        }
    }
}

private struct DeskRow: View {
    let item: ForLaterItem
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark as done")

            if let data = item.screenshot, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let category = item.category {
                        Text(category.name)
                    }
                    Text(item.remindAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.needsAnalysis {
                    Text("Waiting for AI…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
