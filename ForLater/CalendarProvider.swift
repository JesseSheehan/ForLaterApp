import Foundation
import EventKit

/// Reads upcoming events from the iPhone's calendars for the Today summary.
/// This covers Apple (iCloud) calendars and any Google, Outlook/Exchange or
/// other accounts added in the iOS Settings app, since they all show up in
/// Apple's Calendar. Only used when the user turns it on.
@MainActor
final class CalendarProvider {
    static let shared = CalendarProvider()

    private(set) var store = EKEventStore()

    var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    /// Asks for permission to read calendars. Returns whether it was granted.
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        // A store made before access was granted doesn't see any calendars.
        if granted { store = EKEventStore() }
        return granted
    }

    /// Every calendar on the iPhone, grouped by account name (like "iCloud" or a Gmail address).
    func calendarsByAccount() -> [CalendarGroup] {
        guard hasFullAccess else { return [] }
        let grouped = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.title ?? "Other" }
        return grouped
            .map { CalendarGroup(account: $0.key, calendars: $0.value.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
            .sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
    }

    /// Events from now until `days` from now. An empty `calendarIDs` means every calendar.
    func upcomingEvents(days: Int = 7, calendarIDs: Set<String>, now: Date = Date(), limit: Int = 20) -> [UpcomingEvent] {
        guard hasFullAccess,
              let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now)) else { return [] }
        let all = store.calendars(for: .event)
        let chosen = calendarIDs.isEmpty ? all : all.filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: chosen)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                UpcomingEvent(
                    title: event.title ?? "Event",
                    start: event.startDate,
                    isAllDay: event.isAllDay,
                    location: event.location ?? "",
                    calendarName: event.calendar?.title ?? "Calendar"
                )
            }
    }
}

/// One calendar account on the iPhone (like "iCloud" or a Gmail address) and its calendars.
struct CalendarGroup: Identifiable {
    let account: String
    let calendars: [EKCalendar]
    var id: String { account }
}
