import SwiftUI
import SwiftData

/// How the desk is sorted. Saved between launches.
enum DeskSort: String, CaseIterable, Identifiable {
    case mostRecent, leastRecent, aToZ, zToA

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mostRecent: "Most recent"
        case .leastRecent: "Least recent"
        case .aToZ: "A–Z"
        case .zToA: "Z–A"
        }
    }

    func sorted(_ items: [ForLaterItem]) -> [ForLaterItem] {
        switch self {
        case .mostRecent:
            items.sorted { $0.createdAt > $1.createdAt }
        case .leastRecent:
            items.sorted { $0.createdAt < $1.createdAt }
        case .aToZ:
            items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .zToA:
            items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }
}

/// The card being shown in a sheet: an existing item, or a new one made in the app.
private struct CardSheet: Identifiable {
    let item: ForLaterItem
    let isNew: Bool
    var id: PersistentIdentifier { item.persistentModelID }
}

/// The "desk": every For Later that hasn't been completed yet, in category tabs.
struct DeskView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(filter: #Predicate<ForLaterItem> { $0.completedAt == nil })
    private var openItems: [ForLaterItem]

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @AppStorage("deskSort") private var sort: DeskSort = .mostRecent
    /// nil means the "All" tab.
    @State private var selectedCategory: ForLaterCategory?
    @State private var cardSheet: CardSheet?
    @State private var showingSettings = false

    private var visibleItems: [ForLaterItem] {
        let filtered = selectedCategory.map { category in
            openItems.filter { $0.category == category }
        } ?? openItems
        return sort.sorted(filtered)
    }

    var body: some View {
        NavigationStack {
            Group {
                if openItems.isEmpty {
                    ContentUnavailableView(
                        "Your desk is clear",
                        systemImage: "checkmark.seal",
                        description: Text("Take a screenshot of something for later and share it to For Later, or tap + to add one.")
                    )
                } else if visibleItems.isEmpty {
                    ContentUnavailableView(
                        "Nothing in \(selectedCategory?.name ?? "this tab")",
                        systemImage: "tray",
                        description: Text("Items you file under this category show up here.")
                    )
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            DeskRow(item: item, onComplete: { complete(item) })
                                .contentShape(Rectangle())
                                .onTapGesture { cardSheet = CardSheet(item: item, isNew: false) }
                                .swipeActions(edge: .leading) {
                                    Button("Done") { complete(item) }
                                        .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { delete(item) }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .top) {
                CategoryTabs(categories: categories, items: openItems, selected: $selectedCategory)
            }
            .navigationTitle("For Later")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(DeskSort.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")

                    Button(action: addItem) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New For Later")
                }
            }
            .sheet(item: $cardSheet) { sheet in
                NavigationStack {
                    ForLaterCardView(
                        item: sheet.item,
                        allowsPhotoPicking: true,
                        onCancel: cancelAction(for: sheet),
                        onDone: { cardSheet = nil }
                    )
                }
                .interactiveDismissDisabled(sheet.isNew)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
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
        .onChange(of: categories) { _, newCategories in
            // If the selected category was deleted in Settings, go back to All.
            if let selected = selectedCategory, !newCategories.contains(selected) {
                selectedCategory = nil
            }
        }
    }

    private func cancelAction(for sheet: CardSheet) -> (() -> Void)? {
        guard sheet.isNew else { return nil }
        return { discardNew(sheet.item) }
    }

    private func addItem() {
        let item = ForLaterItem()
        // Start in the category of the tab you're looking at.
        item.category = selectedCategory
        context.insert(item)
        cardSheet = CardSheet(item: item, isNew: true)
    }

    private func discardNew(_ item: ForLaterItem) {
        cardSheet = nil
        context.delete(item)
        try? context.save()
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

/// The row of category tabs at the top of the desk: All, then each category.
private struct CategoryTabs: View {
    let categories: [ForLaterCategory]
    let items: [ForLaterItem]
    @Binding var selected: ForLaterCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab("All", count: items.count, isSelected: selected == nil) {
                    selected = nil
                }
                ForEach(categories) { category in
                    tab(category.name,
                        count: items.filter { $0.category == category }.count,
                        isSelected: selected == category) {
                        selected = category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func tab(_ title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
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
