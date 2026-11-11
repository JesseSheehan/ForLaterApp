import SwiftUI
import SwiftData

/// The For Later card: shown from the share sheet for a new item, and from the
/// desk when editing one. Only category and reminder time are required.
struct ForLaterCardView: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: ForLaterItem
    var isAnalyzing: Bool = false
    var onCancel: (() -> Void)?
    var onDone: () -> Void

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]
    @Query(sort: [SortDescriptor(\CheckInTime.hour), SortDescriptor(\CheckInTime.minute)])
    private var checkInTimes: [CheckInTime]

    /// Minutes after midnight of the chosen check-in time, or `customChoice`.
    @State private var reminderChoice: Int = Self.unsetChoice
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""

    private static let unsetChoice = -2
    private static let customChoice = -1

    var body: some View {
        Form {
            if let data = item.screenshot, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if isAnalyzing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your screenshot…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Content") {
                TextField("What do you want to come back to?", text: $item.title, axis: .vertical)
            }

            Section("Category") {
                Picker("Category", selection: $item.category) {
                    Text("Choose…").tag(Optional<ForLaterCategory>.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category))
                    }
                }
                Button("New category…") { showingNewCategory = true }
            }

            Section {
                Picker("Remind me", selection: $reminderChoice) {
                    ForEach(checkInTimes) { time in
                        Text(time.label).tag(time.minutesAfterMidnight)
                    }
                    Text("Custom date and time").tag(Self.customChoice)
                }
                if reminderChoice == Self.customChoice {
                    DatePicker("When", selection: $item.remindAt, in: Date()...)
                } else {
                    LabeledContent("Next reminder", value: item.remindAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text("Tip: a single daily check-in works best. Make it part of your routine.")
            }

            Section("Link") {
                TextField("Link", text: $item.link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Notes") {
                TextField("Additional notes", text: $item.notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .navigationTitle("For Later")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    try? context.save()
                    onDone()
                } label: {
                    Image(systemName: "checkmark")
                }
                .disabled(item.category == nil)
                .accessibilityLabel("Save For Later")
            }
        }
        .onAppear(perform: setUpReminderChoice)
        .onChange(of: checkInTimes.count) { _, _ in setUpReminderChoice() }
        .onChange(of: reminderChoice) { _, newValue in
            if newValue >= 0 {
                item.slotMinutes = newValue
                item.remindAt = CheckInTime.nextOccurrence(minutesAfterMidnight: newValue)
            } else if newValue == Self.customChoice {
                item.slotMinutes = nil
                if item.remindAt < Date() {
                    item.remindAt = Date().addingTimeInterval(3600)
                }
            }
        }
        .alert("New category", isPresented: $showingNewCategory) {
            TextField("Name, like Jobs or Gifts", text: $newCategoryName)
            Button("Cancel", role: .cancel) { newCategoryName = "" }
            Button("Add") { addCategory() }
        }
    }

    private func setUpReminderChoice() {
        guard reminderChoice == Self.unsetChoice, !checkInTimes.isEmpty else { return }
        if let slot = item.slotMinutes, checkInTimes.contains(where: { $0.minutesAfterMidnight == slot }) {
            reminderChoice = slot
        } else if item.slotMinutes == nil && item.remindAt > Date() && !item.needsAnalysis && !item.title.isEmpty {
            reminderChoice = Self.customChoice
        } else {
            reminderChoice = checkInTimes[0].minutesAfterMidnight
        }
    }

    private func addCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        newCategoryName = ""
        guard !name.isEmpty else { return }
        if let existing = categories.first(where: { $0.name.lowercased() == name.lowercased() }) {
            item.category = existing
            return
        }
        let category = ForLaterCategory(name: name, sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1)
        context.insert(category)
        item.category = category
    }
}
