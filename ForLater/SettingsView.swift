import SwiftUI
import SwiftData

/// Settings, opened from the gear on the desk: hometown, check-in times, categories.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var settings: AppSettings?

    @Query(sort: [SortDescriptor(\CheckInTime.hour), SortDescriptor(\CheckInTime.minute)])
    private var checkInTimes: [CheckInTime]

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    private let maxTimes = 12

    var body: some View {
        NavigationStack {
            Form {
                if let settings {
                    HometownSection(settings: settings)
                }

                Section {
                    ForEach(checkInTimes) { time in
                        DatePicker("Check-in", selection: binding(for: time), displayedComponents: .hourAndMinute)
                    }
                    .onDelete(perform: deleteTimes)
                    .deleteDisabled(checkInTimes.count <= 1)

                    Button("Add a time", systemImage: "plus", action: addTime)
                        .disabled(checkInTimes.count >= maxTimes)
                } header: {
                    Text("Daily check-in times")
                } footer: {
                    Text("Fewer is better. One check-in a day, as part of your routine, works best. You can have up to \(maxTimes).")
                }

                Section {
                    ForEach(categories) { category in
                        HStack {
                            Text(category.name)
                            Spacer()
                            if category.isBuiltIn {
                                Text("Built in").foregroundStyle(.secondary)
                            }
                        }
                        .deleteDisabled(category.isBuiltIn)
                    }
                    .onDelete(perform: deleteCategories)
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Add categories from any For Later card. Deleting one moves its items to Other.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if settings == nil {
                    settings = DataStore.settings(in: context)
                }
            }
        }
    }

    private func binding(for time: CheckInTime) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                time.hour = parts.hour ?? time.hour
                time.minute = parts.minute ?? time.minute
            }
        )
    }

    private func addTime() {
        guard checkInTimes.count < maxTimes else { return }
        // Default to an hour after the latest time, capped at 9 PM.
        let latest = checkInTimes.last?.hour ?? 17
        context.insert(CheckInTime(hour: min(latest + 1, 21), minute: 0))
    }

    private func deleteTimes(at offsets: IndexSet) {
        guard checkInTimes.count - offsets.count >= 1 else { return }
        for index in offsets {
            context.delete(checkInTimes[index])
        }
    }

    private func deleteCategories(at offsets: IndexSet) {
        let other = categories.first(where: { $0.isBuiltIn && $0.name == "Other" })
        for index in offsets {
            let category = categories[index]
            guard !category.isBuiltIn else { continue }
            for item in category.items ?? [] {
                item.category = other
            }
            context.delete(category)
        }
    }
}

private struct HometownSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            TextField("City, like Austin, TX", text: $settings.hometown)
                .textContentType(.addressCity)
        } header: {
            Text("Hometown")
        } footer: {
            Text("The AI uses this to pick the event date and place nearest you, like the closest stop on a tour.")
        }
    }
}
