import SwiftUI
import SwiftData

/// Settings > Categories: reorder (this is the tab order on the desk), rename,
/// add, and delete. Other is the catch-all and can't be renamed or deleted;
/// items in a deleted category move to Other.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @State private var renaming: ForLaterCategory?
    @State private var nameDraft = ""
    @State private var addingNew = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    HStack {
                        Text(category.name)
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
                    .contentShape(Rectangle())
                    .onTapGesture { startRenaming(category) }
                    .deleteDisabled(category.isOther)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } footer: {
                Text("Drag to change the order of the tabs on your desk. Tap a category to rename it. Deleting a category moves its items to Other.")
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
        .alert("Rename category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { saveRename() }
        }
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

    private func startRenaming(_ category: ForLaterCategory) {
        guard !category.isOther else { return }
        nameDraft = category.name
        renaming = category
    }

    /// Returns the cleaned-up name, or nil (and shows why) if it can't be used.
    private func validName(_ draft: String, excluding current: ForLaterCategory? = nil) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if categories.contains(where: { $0 !== current && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            errorMessage = "You already have a category called \(name)."
            return nil
        }
        return name
    }

    private func saveRename() {
        guard let category = renaming else { return }
        renaming = nil
        guard let name = validName(nameDraft, excluding: category) else { return }
        category.name = name
        try? context.save()
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
