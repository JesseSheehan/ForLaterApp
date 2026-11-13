import SwiftUI
import SwiftData

/// The Today card, pinned as the first card on the desk: a short summary,
/// a to-do list built from your For Laters, and what's coming up.
struct TodayCard: View {
    let summary: TodaySummary?
    /// Every open For Later, to look up the ones the to-dos point to.
    let items: [ForLaterItem]
    let isGenerating: Bool
    /// In the list layout the card sits in a list row and doesn't scroll on its own.
    var compact: Bool = false
    let onRefresh: () -> Void
    let onOpen: (ForLaterItem) -> Void
    let onDone: (ForLaterItem) -> Void
    let onToggleChecked: (TodoEntry) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if compact {
                content
            } else {
                ScrollView(.vertical, showsIndicators: false) { content }
            }
        }
        .padding(compact ? 0 : 16)
        .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
        .background {
            if !compact {
                shape.fill(
                    LinearGradient(colors: [Color.accentColor.opacity(0.12), Color(.secondarySystemBackground)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let summary {
                Text(summary.overview)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                let todos = visibleTodos(summary)
                if !todos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("To do")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(todos) { todo in
                            todoRow(todo, isChecked: summary.checked.contains(todo.id))
                        }
                    }
                }

                if !summary.upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Coming up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(summary.upcoming) { event in
                            upcomingRow(event)
                        }
                    }
                }

                Text("Updated \(summary.generatedAt.formatted(date: .omitted, time: .shortened))\(summary.usedAI ? " with on-device AI" : "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if isGenerating {
                Text("Writing your summary…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap refresh to see a summary of your desk and a to-do list.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Today", systemImage: "sun.max.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.tint)
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isGenerating {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Updating")
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Update summary")
            }
        }
    }

    /// Hides to-dos whose For Later has been marked Done since the summary was written.
    private func visibleTodos(_ summary: TodaySummary) -> [TodoEntry] {
        summary.todos.filter { todo in
            guard let id = todo.itemID else { return true }
            return item(for: id) != nil
        }
    }

    private func item(for id: PersistentIdentifier) -> ForLaterItem? {
        items.first { $0.persistentModelID == id }
    }

    private func todoRow(_ todo: TodoEntry, isChecked: Bool) -> some View {
        let linked = todo.itemID.flatMap { item(for: $0) }
        let overdue = linked?.isOverdue() ?? false
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if let linked {
                    withAnimation { onDone(linked) }
                } else {
                    withAnimation { onToggleChecked(todo) }
                }
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(overdue ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(linked != nil ? "Done" : (isChecked ? "Uncheck" : "Check off"))

            Text(todo.text)
                .strikethrough(isChecked)
                .foregroundStyle(isChecked ? Color.secondary : (overdue ? Color.red : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let linked { onOpen(linked) }
                }
        }
        .font(.subheadline)
    }

    private func upcomingRow(_ event: UpcomingEvent) -> some View {
        let linked = event.itemID.flatMap { item(for: $0) }
        let when = event.isAllDay
            ? event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.calendarName.isEmpty ? "tray.full" : "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .lineLimit(2)
                Text(event.calendarName.isEmpty ? when : "\(when) · \(event.calendarName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        .onTapGesture {
            if let linked { onOpen(linked) }
        }
    }
}
