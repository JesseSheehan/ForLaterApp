import SwiftUI
import SwiftData
import PhotosUI

/// The For Later card: shown from the share sheet for a new item, and from the
/// desk when editing one. Only category and reminder time are required.
struct ForLaterCardView: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: ForLaterItem
    var isAnalyzing: Bool = false
    /// In the app (not the share sheet): pick a photo and run the AI on demand.
    var allowsPhotoPicking: Bool = false
    var onCancel: (() -> Void)?
    var onDone: () -> Void

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]
    @Query(sort: [SortDescriptor(\CheckInTime.hour), SortDescriptor(\CheckInTime.minute)])
    private var checkInTimes: [CheckInTime]

    /// Minutes after midnight of the chosen check-in time, or `customChoice`.
    @State private var reminderChoice: Int = Self.unsetChoice
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var photoSelection: PhotosPickerItem?
    @State private var isRunningAI = false

    private static let unsetChoice = -2
    private static let customChoice = -1

    var body: some View {
        Form {
            if allowsPhotoPicking {
                Section {
                    if let image = screenshotImage {
                        imageView(image)
                        Button {
                            Task { await runAI() }
                        } label: {
                            Label("Use AI to input details", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunningAI)
                    }
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label(item.screenshot == nil ? "Add a photo from Photos" : "Choose a different photo",
                              systemImage: "photo.on.rectangle")
                    }
                }
            } else if let image = screenshotImage {
                Section {
                    imageView(image)
                }
            }

            if isAnalyzing || isRunningAI {
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

            if item.category?.name == "Events" || item.dueDate != nil {
                Section {
                    Toggle("Due date", isOn: dueDateEnabled)
                    if item.dueDate != nil {
                        Picker("Due in", selection: dueOptionBinding) {
                            ForEach(DueOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        if item.dueOption == .custom {
                            DatePicker("Date", selection: dueDayBinding, displayedComponents: .date)
                            Toggle("Include a time", isOn: dueTimeEnabled)
                            if item.dueHasTime {
                                DatePicker("Time", selection: dueTimeBinding, displayedComponents: .hourAndMinute)
                            }
                        } else if let label = item.dueLabel {
                            LabeledContent("Due", value: label)
                        }
                    }
                } header: {
                    Text("Due date")
                } footer: {
                    if item.isOverdue() {
                        Text("This is past its due date.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional. Leave the time off if only the day matters.")
                    }
                }
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
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task {
                if let data = try? await selection.loadTransferable(type: Data.self) {
                    item.screenshot = ScreenshotAnalyzer.preparedImageData(from: data)
                }
            }
        }
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

    // MARK: Due date bindings

    private var dueDateEnabled: Binding<Bool> {
        Binding(
            get: { item.dueDate != nil },
            set: { isOn in
                if isOn {
                    item.applyDueOption(DueOption.defaultOption)
                } else {
                    item.clearDueDate()
                }
            }
        )
    }

    private var dueTimeEnabled: Binding<Bool> {
        Binding(
            get: { item.dueHasTime },
            set: { isOn in
                if isOn {
                    // Start at the next whole hour. If that has already passed
                    // on the chosen day (only possible today), it moves to tomorrow.
                    let hour = Calendar.current.component(.hour, from: Date())
                    item.setDueTime(hour: (hour + 1) % 24, minute: 0)
                } else {
                    item.clearDueTime()
                }
            }
        )
    }

    private var dueOptionBinding: Binding<DueOption> {
        Binding(
            get: { item.dueOption },
            set: { item.applyDueOption($0) }
        )
    }

    private var dueDayBinding: Binding<Date> {
        Binding(
            get: { item.dueDate ?? Date() },
            set: { item.setDueDay($0) }
        )
    }

    private var dueTimeBinding: Binding<Date> {
        Binding(
            get: { item.dueDate ?? Date() },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                item.setDueTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            }
        )
    }

    private var screenshotImage: UIImage? {
        item.screenshot.flatMap { UIImage(data: $0) }
    }

    private func imageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func runAI() async {
        isRunningAI = true
        defer { isRunningAI = false }
        await ScreenshotAnalyzer.enrichFromLink(item)
        let result = await ScreenshotAnalyzer.analyze(
            imageData: item.screenshot,
            sharedLink: item.link.isEmpty ? nil : item.link,
            sharedText: item.sharedText,
            categoryNames: categories.map(\.name),
            hometown: DataStore.settings(in: context).hometown
        )
        ScreenshotAnalyzer.apply(result, to: item, categories: categories, overwrite: true)
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
