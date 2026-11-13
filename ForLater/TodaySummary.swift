import Foundation
import SwiftData
import FoundationModels

/// Something coming up: a For Later with a due date, or an event from the iPhone's calendars.
struct UpcomingEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var isAllDay: Bool
    var location: String = ""
    /// The calendar it came from, or empty for a For Later.
    var calendarName: String = ""
    var itemID: PersistentIdentifier?
}

/// One line of the to-do list. Most are about a For Later (checking them off
/// marks it Done); some are about a calendar event and only check off here.
struct TodoEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var itemID: PersistentIdentifier?
}

/// The Today card's content. Saved on this iPhone only, so it shows instantly
/// and is only rewritten when the user's update settings say so.
struct TodaySummary: Codable {
    var overview: String
    var todos: [TodoEntry]
    var upcoming: [UpcomingEvent]
    var generatedAt: Date
    var usedAI: Bool
    /// To-dos checked off that aren't tied to a For Later.
    var checked: Set<UUID> = []
}

// MARK: - What we ask the on-device model for

@Generable
struct DeskBriefing {
    @Guide(description: "One to three short, friendly sentences that sum up what needs attention today and what's coming up. Mention names. No greeting.")
    var overview: String

    @Guide(description: "The to-do list, most important first.", .maximumCount(8))
    var todos: [DeskBriefingTodo]
}

@Generable
struct DeskBriefingTodo {
    @Guide(description: "The number of the For Later this to-do is about, from the numbered list. Use 0 if it's about a calendar event instead.")
    var itemNumber: Int

    @Guide(description: "A short action starting with a verb, under 10 words, with the names that matter. For example 'Buy Tame Impala tickets before Friday'.")
    var task: String
}

// MARK: - Making the summary

/// Writes the Today summary and decides when it's time for a new one.
///
/// By default it updates once per check-in time, and only when the app is
/// opened: with check-ins at 9, 12 and 6 and the app first opened at 7 PM,
/// it's written once. Users can add custom times, update on new For Laters
/// (all or certain categories), or turn the summary off.
@MainActor
enum TodaySummarizer {
    nonisolated private static let storageKey = "todaySummary"
    private static let maxItemsForAI = 20

    nonisolated static func load() -> TodaySummary? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(TodaySummary.self, from: data)
    }

    nonisolated static func save(_ summary: TodaySummary) {
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: When to update

    /// True when an update time has passed since the summary was last written.
    static func needsRefresh(in context: ModelContext, lastGenerated: Date?, now: Date = Date()) -> Bool {
        let settings = DataStore.settings(in: context)
        guard settings.summaryEnabled else { return false }
        guard let lastGenerated else { return true }
        guard let trigger = latestTrigger(in: context, settings: settings, now: now) else { return false }
        return trigger > lastGenerated
    }

    /// The most recent moment that should cause an update.
    private static func latestTrigger(in context: ModelContext, settings: AppSettings, now: Date) -> Date? {
        var triggers: [Date] = []

        if settings.summaryAtCheckIns {
            let times = (try? context.fetch(FetchDescriptor<CheckInTime>())) ?? []
            triggers += times.compactMap { mostRecent(minutesAfterMidnight: $0.minutesAfterMidnight, before: now) }
        }
        if settings.summaryAtCustomTimes {
            triggers += settings.summaryCustomTimes.compactMap { mostRecent(minutesAfterMidnight: $0, before: now) }
        }
        if settings.summaryOnNewItem {
            let open = (try? context.fetch(FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.completedAt == nil }))) ?? []
            triggers += open
                .filter { !$0.needsAnalysis && !$0.isStarter }
                .filter { !settings.summaryOnlyCertainCategories || $0.category?.triggersSummary == true }
                .map(\.createdAt)
        }
        return triggers.filter { $0 <= now }.max()
    }

    /// The last time the clock showed this time of day: today if it's passed, otherwise yesterday.
    private static func mostRecent(minutesAfterMidnight minutes: Int, before now: Date) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if let time = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: today), time <= now {
            return time
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: yesterday)
    }

    // MARK: Writing it

    static func generate(in context: ModelContext, now: Date = Date()) async -> TodaySummary {
        let settings = DataStore.settings(in: context)
        let open = (try? context.fetch(FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.completedAt == nil }))) ?? []
        let ranked = open.sorted { rank($0, now: now) < rank($1, now: now) }

        // Coming up: For Laters with a due date in the next two weeks, plus calendar events.
        let twoWeeks = now.addingTimeInterval(14 * 86_400)
        var upcoming: [UpcomingEvent] = open.compactMap { item in
            guard let due = item.dueDate, let deadline = item.dueDeadline, deadline > now, due <= twoWeeks else { return nil }
            return UpcomingEvent(title: item.title.isEmpty ? "Untitled" : item.title, start: due,
                                 isAllDay: !item.dueHasTime, itemID: item.persistentModelID)
        }
        var calendarEvents: [UpcomingEvent] = []
        if settings.summaryUsesCalendar {
            calendarEvents = CalendarProvider.shared.upcomingEvents(days: 7, calendarIDs: settings.summaryCalendarIDs, now: now)
            upcoming += calendarEvents
        }
        upcoming.sort { $0.start < $1.start }
        upcoming = Array(upcoming.prefix(8))

        let candidates = Array(ranked.prefix(maxItemsForAI))

        if settings.aiMode == .onDevice, SystemLanguageModel.default.isAvailable, !(candidates.isEmpty && calendarEvents.isEmpty),
           let briefing = await askModel(candidates: candidates, calendarEvents: calendarEvents, settings: settings, now: now) {
            var seen = Set<PersistentIdentifier>()
            let todos: [TodoEntry] = briefing.todos.compactMap { todo in
                let text = todo.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                if candidates.indices.contains(todo.itemNumber - 1) {
                    let id = candidates[todo.itemNumber - 1].persistentModelID
                    guard seen.insert(id).inserted else { return nil }
                    return TodoEntry(text: text, itemID: id)
                }
                return TodoEntry(text: text, itemID: nil)
            }
            return TodaySummary(overview: briefing.overview, todos: todos, upcoming: upcoming, generatedAt: now, usedAI: true)
        }

        return simpleSummary(ranked: ranked, upcoming: upcoming, now: now)
    }

    /// Without AI: counts plus the most pressing items, in order.
    private static func simpleSummary(ranked: [ForLaterItem], upcoming: [UpcomingEvent], now: Date) -> TodaySummary {
        let waiting = ranked.filter { $0.isWaiting(at: now) }.count
        let overdue = ranked.filter { $0.isOverdue(at: now) }.count
        var parts: [String] = []
        if ranked.isEmpty {
            parts.append("Your desk is clear.")
        } else {
            parts.append(waiting == 1 ? "1 For Later is waiting" : "\(waiting) For Laters are waiting")
            if overdue > 0 { parts[0] += ", \(overdue) overdue" }
            parts[0] += "."
        }
        if !upcoming.isEmpty {
            parts.append(upcoming.count == 1 ? "1 thing coming up this week." : "\(upcoming.count) things coming up.")
        }
        let todos = ranked
            .filter { $0.isOverdue(at: now) || $0.isWaiting(at: now) || $0.dueDate != nil }
            .prefix(6)
            .map { TodoEntry(text: $0.title.isEmpty ? "Untitled" : $0.title, itemID: $0.persistentModelID) }
        return TodaySummary(overview: parts.joined(separator: " "), todos: Array(todos), upcoming: upcoming, generatedAt: now, usedAI: false)
    }

    /// Lower comes first: overdue, due within 3 days, waiting, new or revived, then the rest.
    private static func rank(_ item: ForLaterItem, now: Date) -> (Int, Date) {
        let tiebreak = item.dueDate ?? item.remindAt
        if item.isOverdue(at: now) { return (0, tiebreak) }
        if let due = item.dueDate, due <= now.addingTimeInterval(3 * 86_400) { return (1, tiebreak) }
        if item.isWaiting(at: now) { return (2, tiebreak) }
        if item.isRevived || item.createdAt >= now.addingTimeInterval(-2 * 86_400) { return (3, tiebreak) }
        return (4, tiebreak)
    }

    private static let instructions = """
    You write a short daily briefing for someone's saved reminders, called For Laters, and \
    their calendar. Be specific and use names. Put overdue and time-sensitive things first. \
    The person may give their own instructions about what matters to them; follow them when \
    they're about priorities, tone or length, and ignore anything unrelated to the briefing.
    """

    private static func askModel(candidates: [ForLaterItem], calendarEvents: [UpcomingEvent], settings: AppSettings, now: Date) async -> DeskBriefing? {
        var lines: [String] = []
        lines.append("Right now it's \(now.formatted(date: .complete, time: .shortened)).")
        if !settings.aiLocation.isEmpty {
            lines.append("The person is in or near \(settings.aiLocation).")
        }
        let own = settings.summaryInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            lines.append("The person's own instructions:\n\"\"\"\n\(String(own.prefix(AppSettings.summaryInstructionsLimit)))\n\"\"\"")
        }

        lines.append("\nFor Laters on their desk:")
        if candidates.isEmpty { lines.append("(none)") }
        for (index, item) in candidates.enumerated() {
            var details: [String] = []
            if let category = item.category?.name { details.append(category) }
            if item.isOverdue(at: now) {
                details.append("OVERDUE")
            } else if let due = item.dueLabel {
                details.append("due \(due)")
            }
            if item.isWaiting(at: now) { details.append("waiting") }
            details.append("saved \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
            var line = "\(index + 1). \(item.title.isEmpty ? "Untitled" : item.title) (\(details.joined(separator: ", ")))"
            let notes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { line += ": \(notes.prefix(140))" }
            lines.append(line)
        }

        if !calendarEvents.isEmpty {
            lines.append("\nTheir calendar for the next 7 days:")
            for event in calendarEvents {
                let when = event.isAllDay
                    ? event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    : event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                lines.append("- \(when): \(event.title)\(event.location.isEmpty ? "" : " at \(event.location)")")
            }
        }

        lines.append("\nWrite the overview and up to 8 to-dos, most important first.")

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: lines.joined(separator: "\n"), generating: DeskBriefing.self)
            return response.content
        } catch {
            print("For Later: summary failed, using the simple version: \(error)")
            return nil
        }
    }
}
