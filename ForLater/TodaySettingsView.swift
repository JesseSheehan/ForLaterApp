import SwiftUI
import SwiftData
import EventKit

/// Settings > Today summary: turn it on or off, write your own instructions,
/// choose when it updates, and whether it reads your calendar.
struct TodaySettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var settings: AppSettings?

    var body: some View {
        Form {
            if let settings {
                TodaySettingsForm(settings: settings)
            }
        }
        .navigationTitle("Today summary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if settings == nil {
                settings = DataStore.settings(in: context)
            }
        }
    }
}

private struct TodaySettingsForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Bindable var settings: AppSettings

    @Query(sort: \ForLaterCategory.sortOrder) private var categories: [ForLaterCategory]

    @State private var calendarGroups: [CalendarGroup] = []
    @State private var calendarDenied = false

    private let limit = AppSettings.summaryInstructionsLimit

    var body: some View {
        Section {
            Toggle(isOn: $settings.summaryEnabled) {
                Label("Today summary", systemImage: "sun.max")
            }
        } footer: {
            Text("A card pinned to the left of your desk with a short summary, a to-do list and what's coming up. Written by on-device AI when it's on in Privacy; otherwise a simple list.")
        }

        if settings.summaryEnabled {
            instructionsSection
            updateSection
            calendarSection
        }
    }

    // MARK: Instructions

    private var instructionsSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if settings.summaryInstructions.isEmpty {
                    Text("For example: Work things first. I only care about concerts in Chicago. Keep it short.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: instructionsBinding)
                    .frame(minHeight: 120)
            }
        } header: {
            Text("Your instructions")
        } footer: {
            HStack(alignment: .top) {
                Text("Tell the AI what to prioritize or how to write your summary. Stays on your iPhone.")
                Spacer()
                Text("\(settings.summaryInstructions.count)/\(limit)")
                    .monospacedDigit()
                    .foregroundStyle(settings.summaryInstructions.count >= limit ? Color.orange : Color.secondary)
            }
        }
    }

    private var instructionsBinding: Binding<String> {
        Binding(
            get: { settings.summaryInstructions },
            set: { settings.summaryInstructions = String($0.prefix(limit)) }
        )
    }

    // MARK: When it updates

    private var updateSection: some View {
        Section {
            Toggle("At check-in times", isOn: $settings.summaryAtCheckIns)

            Toggle("At custom times", isOn: $settings.summaryAtCustomTimes)
            if settings.summaryAtCustomTimes {
                ForEach(Array(settings.summaryCustomTimes.enumerated()), id: \.offset) { index, _ in
                    DatePicker("Time \(index + 1)", selection: customTimeBinding(at: index), displayedComponents: .hourAndMinute)
                }
                .onDelete { offsets in
                    var times = settings.summaryCustomTimes
                    times.remove(atOffsets: offsets)
                    settings.summaryCustomTimes = times
                }
                Button("Add a time", systemImage: "plus") {
                    var times = settings.summaryCustomTimes
                    times.append(min((times.last ?? 420) + 60, 23 * 60))
                    settings.summaryCustomTimes = times
                }
                .disabled(settings.summaryCustomTimes.count >= 6)
            }

            Toggle("When a new For Later is added", isOn: $settings.summaryOnNewItem)
            if settings.summaryOnNewItem {
                Picker("From", selection: $settings.summaryOnlyCertainCategories) {
                    Text("Any category").tag(false)
                    Text("Certain categories").tag(true)
                }
                if settings.summaryOnlyCertainCategories {
                    ForEach(categories) { category in
                        Button {
                            category.triggersSummary.toggle()
                        } label: {
                            HStack {
                                Text(category.name)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                if category.triggersSummary {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Update the summary")
        } footer: {
            Text("It only updates when you open For Later, once for each of these that has passed since the last update. You can also tap refresh on the card any time.")
        }
    }

    private func customTimeBinding(at index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = settings.summaryCustomTimes.indices.contains(index) ? settings.summaryCustomTimes[index] : 480
                return Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                var times = settings.summaryCustomTimes
                guard times.indices.contains(index) else { return }
                times[index] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                settings.summaryCustomTimes = times
            }
        )
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            Toggle(isOn: calendarBinding) {
                Label("Include my calendar", systemImage: "calendar")
            }
            if calendarDenied {
                Button("Allow calendar access in the Settings app") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if settings.summaryUsesCalendar {
                ForEach(calendarGroups) { group in
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Button {
                            toggle(calendar)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                        .foregroundStyle(Color.primary)
                                    Text(group.account)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isChosen(calendar) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Your next 7 days of events are added to the summary. They're only read on this iPhone, never changed. Google, Outlook and other calendars show up here once their account is added in the Settings app under Apps > Calendar > Calendar Accounts.")
        }
        .task(id: settings.summaryUsesCalendar) { loadCalendars() }
    }

    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { settings.summaryUsesCalendar },
            set: { isOn in
                guard isOn else {
                    settings.summaryUsesCalendar = false
                    return
                }
                Task {
                    let granted = CalendarProvider.shared.hasFullAccess
                        ? true
                        : await CalendarProvider.shared.requestAccess()
                    calendarDenied = !granted
                    settings.summaryUsesCalendar = granted
                    loadCalendars()
                }
            }
        )
    }

    private func loadCalendars() {
        calendarGroups = settings.summaryUsesCalendar ? CalendarProvider.shared.calendarsByAccount() : []
    }

    /// No calendars picked means all of them.
    private func isChosen(_ calendar: EKCalendar) -> Bool {
        settings.summaryCalendarIDs.isEmpty || settings.summaryCalendarIDs.contains(calendar.calendarIdentifier)
    }

    private func toggle(_ calendar: EKCalendar) {
        let all = Set(calendarGroups.flatMap { $0.calendars.map(\.calendarIdentifier) })
        var chosen = settings.summaryCalendarIDs.isEmpty ? all : settings.summaryCalendarIDs
        if chosen.contains(calendar.calendarIdentifier) {
            // Keep at least one calendar; turn the switch off to use none.
            guard chosen.count > 1 else { return }
            chosen.remove(calendar.calendarIdentifier)
        } else {
            chosen.insert(calendar.calendarIdentifier)
        }
        // Everything picked is stored as "all", so new calendars are included too.
        settings.summaryCalendarIDs = (chosen == all) ? [] : chosen
    }
}
