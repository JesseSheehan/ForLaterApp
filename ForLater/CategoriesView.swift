import SwiftUI
import SwiftData

/// Settings > Categories: reorder (this is the tab order on the desk), rename,
/// add, and delete. Other is the catch-all and can't be renamed or deleted;
/// items in a deleted category move to Other.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @State private var nameDraft = ""
    @State private var addingNew = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryDetailView(category: category, otherNames: categories.filter { $0 !== category }.map(\.name))
                    } label: {
                        HStack {
                            Text(category.name)
                            if category.defaultReminder != .daily {
                                Image(systemName: category.defaultReminder == .none ? "bell.slash" : "calendar.badge.clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if category.isOther {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Can't be renamed or deleted")
                            } else {
                                Text("\(category.items?.filter { $0.completedAt == nil }.count ?? 0)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .deleteDisabled(category.isOther)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } footer: {
                Text("Drag to change the order of the tabs on your desk. Tap a category to rename it or set its default reminder. Deleting a category moves its items to Other.")
            }

            Section {
                Button("Add a category", systemImage: "plus") {
                    nameDraft = ""
                    addingNew = true
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar { EditButton() }
        .alert("New category", isPresented: $addingNew) {
            TextField("Name, like Jobs or Gifts", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addCategory() }
        }
        .alert("Can't use that name", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Returns the cleaned-up name, or nil (and shows why) if it can't be used.
    private func validName(_ draft: String) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if categories.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            errorMessage = "You already have a category called \(name)."
            return nil
        }
        return name
    }

    private func addCategory() {
        guard let name = validName(nameDraft) else { return }
        let nextOrder = (categories.map(\.sortOrder).max() ?? -1) + 1
        context.insert(ForLaterCategory(name: name, sortOrder: nextOrder))
        try? context.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in reordered.enumerated() {
            category.sortOrder = index
        }
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        let other = categories.first(where: { $0.isOther })
        for index in offsets {
            let category = categories[index]
            guard !category.isOther else { continue }
            for item in category.items ?? [] {
                item.category = other
            }
            context.delete(category)
        }
        try? context.save()
    }
}

/// One category: its name and the reminder new items in it start with.
private struct CategoryDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var category: ForLaterCategory
    /// The other categories' names, so two can't share a name.
    let otherNames: [String]

    @State private var nameDraft = ""
    @State private var weeklyLabel = ""

    private var nameProblem: String? {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "A category needs a name." }
        if otherNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "You already have a category called \(name)."
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $nameDraft)
                    .disabled(category.isOther)
                    .onSubmit(saveName)
            } header: {
                Text("Name")
            } footer: {
                if category.isOther {
                    Text("Other is the catch-all category, so it can't be renamed.")
                } else if let nameProblem {
                    Text(nameProblem).foregroundStyle(.red)
                }
            }

            Section {
                Picker("New items", selection: $category.defaultReminderRaw) {
                    Text(ReminderKind.daily.label).tag("")
                    Text(ReminderKind.weekly.label).tag(ReminderKind.weekly.rawValue)
                    Text(ReminderKind.none.label).tag(ReminderKind.none.rawValue)
                }
            } header: {
                Text("Default reminder")
            } footer: {
                switch category.defaultReminder {
                case .weekly:
                    Text("New items here are only mentioned at your weekly check-in (\(weeklyLabel)). You can still change it on each item.")
                case .none:
                    Text("New items here never send a notification. They wait on your desk and show in your Today summary.")
                default:
                    Text("New items here are mentioned at your daily check-ins. Weekly suits things like recipes.")
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nameDraft = category.name
            weeklyLabel = DataStore.settings(in: context).weeklyLabel
        }
        .onDisappear {
            saveName()
            try? context.save()
        }
    }

    private func saveName() {
        guard !category.isOther, nameProblem == nil else { return }
        category.name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
