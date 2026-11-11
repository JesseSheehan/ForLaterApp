import SwiftUI
import SwiftData

/// Opens when you tap a card or row: everything about the item, read-only.
/// The Edit button in the corner switches to the editable card.
struct ItemDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: ForLaterItem
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            if isEditing {
                ForLaterCardView(item: item, allowsPhotoPicking: true, onDone: {
                    withAnimation { isEditing = false }
                })
            } else {
                TimelineView(.everyMinute) { timeline in
                    details(now: timeline.date)
                }
                .navigationTitle(item.category?.name ?? "For Later")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation { isEditing = true }
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
            }
        }
    }

    private func details(now: Date) -> some View {
        let highlight = item.highlightColor(at: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = item.screenshot, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                ItemBadges(item: item, now: now)

                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(highlight ?? Color.primary)

                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.body)
                }

                if !item.link.isEmpty, let url = URL(string: item.link) {
                    Link(destination: url) {
                        Label(item.link, systemImage: "link")
                            .lineLimit(2)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let due = item.dueLabel {
                        infoRow("Due", due, systemImage: "calendar", color: item.isOverdue(at: now) ? Color.red : nil)
                    }
                    infoRow("Reminder", item.remindAt.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
                    infoRow("Added", item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "plus.circle")
                    if let engine = AnalysisEngine(rawValue: item.analysisEngineRaw), engine != .none {
                        infoRow("Filled in by", engine.label, systemImage: "cpu")
                    }
                    if let revivedAt = item.revivedAt, item.isRevived {
                        infoRow("Revived", revivedAt.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "arrow.uturn.backward.circle", color: .purple)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !item.isCompleted {
                    Button {
                        Archive.archive(item, in: context)
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }

    private func infoRow(_ title: String, _ value: String, systemImage: String, color: Color? = nil) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(color ?? Color.primary)
        }
        .font(.subheadline)
    }
}
