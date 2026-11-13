import SwiftUI
import SwiftData
import UserNotifications

/// Settings, opened from the gear on the desk: hometown, check-in times, categories.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var settings: AppSettings?

    @Query(sort: [SortDescriptor(\CheckInTime.hour), SortDescriptor(\CheckInTime.minute)])
    private var checkInTimes: [CheckInTime]

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @Query(filter: #Predicate<ForLaterItem> { $0.completedAt != nil })
    private var archivedItems: [ForLaterItem]

    private let maxTimes = 12

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        LabeledContent {
                            Text(settings?.aiMode.title ?? "")
                        } label: {
                            Label("Privacy", systemImage: "hand.raised")
                        }
                    }
                } footer: {
                    Text("Hometown, location and how much AI For Later uses.")
                }

                Section {
                    NavigationLink {
                        TodaySettingsView()
                    } label: {
                        LabeledContent {
                            Text(settings?.summaryEnabled == false ? "Off" : "On")
                        } label: {
                            Label("Today summary", systemImage: "sun.max")
                        }
                    }
                } footer: {
                    Text("Your instructions, when it updates, and your calendar.")
                }

                Section {
                    NotificationStatusRow()
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("You're only notified at a check-in time when something on your desk is waiting.")
                }

                Section {
                    NavigationLink {
                        ArchiveView()
                    } label: {
                        LabeledContent {
                            Text("\(archivedItems.count)")
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    if let settings {
                        ScreenshotRetentionPicker(settings: settings)
                    }
                } header: {
                    Text("Archive")
                } footer: {
                    Text("Items you mark Done go to the archive, where you can revive them. Screenshots of archived items are deleted after the time you choose; the item itself stays.")
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

                if let settings {
                    WeeklyCheckInSection(settings: settings)
                }

                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        LabeledContent {
                            Text("\(categories.count)")
                        } label: {
                            Label("Categories", systemImage: "square.grid.2x2")
                        }
                    }
                } footer: {
                    Text("Reorder, rename, add or delete categories. The order here is the order of the tabs on your desk.")
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

}

private struct ScreenshotRetentionPicker: View {
    @Environment(\.modelContext) private var context
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Delete screenshots", selection: $settings.screenshotRetentionRaw) {
            ForEach(ScreenshotRetention.allCases) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
        .onChange(of: settings.screenshotRetentionRaw) { _, _ in
            Archive.applyScreenshotRetention(in: context)
        }
    }
}

private struct NotificationStatusRow: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            switch status {
            case .authorized, .provisional, .ephemeral:
                Label("Notifications are on", systemImage: "bell.fill")
            case .denied:
                Button("Turn on in the Settings app", systemImage: "bell.slash") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .notDetermined:
                Button("Turn on notifications", systemImage: "bell") {
                    Task {
                        _ = await NotificationScheduler.requestPermission()
                        await refresh()
                    }
                }
            default:
                ProgressView()
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        status = await NotificationScheduler.authorizationStatus()
    }
}

/// The weekly check-in: one or two days a week, for items that don't need a
/// daily nudge (like recipes). Items or categories opt in to it.
private struct WeeklyCheckInSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { weekday in
                    let isOn = settings.weeklyDays.contains(weekday)
                    Button {
                        toggle(weekday)
                    } label: {
                        Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1])
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)

            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
        } header: {
            Text("Weekly check-in")
        } footer: {
            Text("For things that don't need a daily nudge, like recipes. Choose Weekly check-in as an item's reminder, or make it a category's default in Categories. Once or twice a week works best.")
        }
    }

    private func toggle(_ weekday: Int) {
        var days = settings.weeklyDays
        if days.contains(weekday) {
            guard days.count > 1 else { return }  // at least one day
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        settings.weeklyDays = days
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: settings.weeklyMinutes / 60, minute: settings.weeklyMinutes % 60)) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.weeklyMinutes = (parts.hour ?? 10) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
