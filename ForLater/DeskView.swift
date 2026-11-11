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

/// Cards you swipe through (the default) or a list. Saved between launches.
enum DeskLayout: String {
    case cards, list
}

/// What's open in a sheet: a new item being made, or an existing item's details.
private enum DeskSheet: Identifiable {
    case new(ForLaterItem)
    case detail(ForLaterItem)

    var id: String {
        switch self {
        case .new(let item): "new-\(item.persistentModelID.hashValue)"
        case .detail(let item): "detail-\(item.persistentModelID.hashValue)"
        }
    }
}

/// The "desk": every For Later that hasn't been marked Done, in category tabs.
struct DeskView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(filter: #Predicate<ForLaterItem> { $0.completedAt == nil })
    private var openItems: [ForLaterItem]

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @Query private var checkInTimes: [CheckInTime]

    @AppStorage("deskSort") private var sort: DeskSort = .mostRecent
    @AppStorage("deskLayout") private var layout: DeskLayout = .cards
    /// nil means the "All" tab.
    @State private var selectedCategory: ForLaterCategory?
    @State private var sheet: DeskSheet?
    @State private var showingSettings = false
    @State private var showingConfetti = false
    /// Set while a just-made item is being thrown away, so that doesn't count as clearing the desk.
    @State private var discardingNew = false

    /// Changes whenever something that affects notifications changes.
    private var scheduleSignature: [String] {
        openItems.map { "\($0.persistentModelID.hashValue):\($0.remindAt.timeIntervalSince1970):\($0.title)" }
            + checkInTimes.map { "\($0.hour):\($0.minute)" }
    }

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
                } else if layout == .cards {
                    DeskCarousel(
                        items: visibleItems,
                        onOpen: { sheet = .detail($0) },
                        onDone: archive
                    )
                } else {
                    DeskList(
                        items: visibleItems,
                        onOpen: { sheet = .detail($0) },
                        onDone: archive
                    )
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
                    Button {
                        withAnimation { layout = (layout == .cards) ? .list : .cards }
                    } label: {
                        Image(systemName: layout == .cards ? "list.bullet" : "rectangle.on.rectangle")
                    }
                    .accessibilityLabel(layout == .cards ? "Show as list" : "Show as cards")

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
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .new(let item):
                    NavigationStack {
                        ForLaterCardView(
                            item: item,
                            allowsPhotoPicking: true,
                            onCancel: { discardNew(item) },
                            onDone: { self.sheet = nil }
                        )
                    }
                    .interactiveDismissDisabled()
                case .detail(let item):
                    ItemDetailView(item: item)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .overlay {
            if showingConfetti {
                ConfettiView()
            }
        }
        .task {
            DataStore.seedIfNeeded(context)
            Archive.applyScreenshotRetention(in: context)
            await ScreenshotAnalyzer.processPending(in: context)
            await NotificationScheduler.reschedule(in: context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Archive.applyScreenshotRetention(in: context)
                Task {
                    await ScreenshotAnalyzer.processPending(in: context)
                    await NotificationScheduler.reschedule(in: context)
                }
            } else if phase == .background {
                Task { await NotificationScheduler.reschedule(in: context) }
            }
        }
        .onChange(of: scheduleSignature) { _, _ in
            Task { await NotificationScheduler.reschedule(in: context) }
        }
        .onChange(of: openItems.count) { oldCount, newCount in
            // The desk was just cleared: confetti.
            if oldCount > 0, newCount == 0, !discardingNew {
                celebrate()
            }
            discardingNew = false
        }
        .onChange(of: categories) { _, newCategories in
            // If the selected category was deleted in Settings, go back to All.
            if let selected = selectedCategory, !newCategories.contains(selected) {
                selectedCategory = nil
            }
        }
    }

    private func addItem() {
        let item = ForLaterItem()
        // Start in the category of the tab you're looking at.
        item.category = selectedCategory
        context.insert(item)
        sheet = .new(item)
    }

    private func celebrate() {
        showingConfetti = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            showingConfetti = false
        }
    }

    private func discardNew(_ item: ForLaterItem) {
        discardingNew = true
        sheet = nil
        context.delete(item)
        try? context.save()
    }

    private func archive(_ item: ForLaterItem) {
        withAnimation {
            Archive.archive(item, in: context)
        }
    }
}

// MARK: - Category tabs

/// The row of category tabs at the top of the desk, in a rounded container.
private struct CategoryTabs: View {
    let categories: [ForLaterCategory]
    let items: [ForLaterItem]
    @Binding var selected: ForLaterCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
            .padding(6)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func tab(_ title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), in: Capsule())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

/// The desk as a row of cards you swipe left and right through.
private struct DeskCarousel: View {
    let items: [ForLaterItem]
    let onOpen: (ForLaterItem) -> Void
    let onDone: (ForLaterItem) -> Void

    @State private var currentID: PersistentIdentifier?

    private var currentIndex: Int {
        guard let currentID,
              let index = items.firstIndex(where: { $0.persistentModelID == currentID }) else { return 0 }
        return index
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        // Re-checks every minute so cards turn red when they pass their due date.
                        TimelineView(.everyMinute) { timeline in
                            DeskCard(
                                item: item,
                                now: timeline.date,
                                onOpen: { onOpen(item) },
                                onDone: { onDone(item) }
                            )
                        }
                        .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)

            SwipeIndicator(count: items.count, index: currentIndex, onMove: move(by:))
        }
        .padding(.vertical, 8)
    }

    private func move(by offset: Int) {
        let target = currentIndex + offset
        guard items.indices.contains(target) else { return }
        withAnimation { currentID = items[target].persistentModelID }
    }
}

/// Arrows and page dots under the cards, showing there's more to swipe to.
private struct SwipeIndicator: View {
    let count: Int
    let index: Int
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button { onMove(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous card")

            if count <= 10 {
                HStack(spacing: 7) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: i == index ? 8 : 6, height: i == index ? 8 : 6)
                    }
                }
                .animation(.snappy, value: index)
            } else {
                Text("\(min(index + 1, count)) of \(count)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button { onMove(1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= count - 1)
            .accessibilityLabel("Next card")
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.borderless)
        .opacity(count > 1 ? 1 : 0)
    }
}

private struct DeskCard: View {
    let item: ForLaterItem
    let now: Date
    let onOpen: () -> Void
    let onDone: () -> Void

    var body: some View {
        let highlight = item.highlightColor(at: now)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        VStack(alignment: .leading, spacing: 12) {
            if let data = item.screenshot, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ItemBadges(item: item, now: now)

            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(highlight ?? Color.primary)
                .lineLimit(3)

            if !item.notes.isEmpty {
                Text(item.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                if let due = item.dueLabel {
                    Label("Due \(due)", systemImage: "calendar")
                        .foregroundStyle(item.isOverdue(at: now) ? Color.red : Color.secondary)
                }
                Label("Reminder \(item.remindAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "bell")
                    .foregroundStyle(.secondary)
                if item.needsAnalysis {
                    Label("Waiting for AI…", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(shape.fill((highlight ?? Color.clear).opacity(0.08)))
        .background(shape.fill(Color(.secondarySystemBackground)))
        .overlay(shape.strokeBorder(highlight ?? Color.clear, lineWidth: 2))
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - List

private struct DeskList: View {
    let items: [ForLaterItem]
    let onOpen: (ForLaterItem) -> Void
    let onDone: (ForLaterItem) -> Void

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            List {
                ForEach(items) { item in
                    DeskRow(item: item, now: timeline.date, onDone: { onDone(item) })
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(item) }
                        .swipeActions(edge: .leading) {
                            Button("Done", systemImage: "checkmark") { onDone(item) }
                                .tint(.green)
                        }
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct DeskRow: View {
    let item: ForLaterItem
    let now: Date
    let onDone: () -> Void

    var body: some View {
        let highlight = item.highlightColor(at: now)

        HStack(spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(highlight ?? Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")

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
                    .foregroundStyle(highlight ?? Color.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let category = item.category {
                        Text(category.name)
                    }
                    if let due = item.dueLabel {
                        Text("Due \(due)")
                            .foregroundStyle(item.isOverdue(at: now) ? Color.red : Color.secondary)
                    } else {
                        Text(item.remindAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if item.isRevived {
                        Text("Revived").foregroundStyle(Color.purple)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
