import Foundation
import SwiftData

// All properties are optional or have defaults, and there are no unique
// constraints, because SwiftData + CloudKit sync requires that.

@Model
final class ForLaterItem {
    var title: String = ""
    var notes: String = ""
    var link: String = ""
    /// When the user should be reminded about this item.
    var remindAt: Date = Date()
    /// The daily check-in time the user picked, stored as minutes after midnight.
    /// nil means the user chose a custom date and time instead.
    var slotMinutes: Int?
    var createdAt: Date = Date()
    var completedAt: Date?
    /// True until the AI has looked at the screenshot. The main app analyzes
    /// any item still marked this way (for example if the share sheet closed early).
    var needsAnalysis: Bool = false
    var isStarter: Bool = false
    @Attribute(.externalStorage) var screenshot: Data?
    var category: ForLaterCategory?
    /// Optional due date for events. When `dueHasTime` is false only the day matters.
    var dueDate: Date?
    var dueHasTime: Bool = false
    /// Which due date option was picked (see `DueOption`). Empty means custom.
    var dueOptionRaw: String = ""
    /// Extra text that came with a shared link, like an Instagram post's author and caption.
    var sharedText: String = ""
    /// Which step filled in the card (see `AnalysisEngine`), shown in the details.
    var analysisEngineRaw: String = ""
    /// Brought back from the archive. Revived items are shown in purple.
    var isRevived: Bool = false
    var revivedAt: Date?
    /// How this item reminds you (see `ReminderKind`). Empty for items made
    /// before reminder kinds existed: daily if `slotMinutes` is set, otherwise custom.
    var reminderKindRaw: String = ""

    init(title: String = "", screenshot: Data? = nil, link: String = "") {
        self.title = title
        self.screenshot = screenshot
        self.link = link
        self.createdAt = Date()
        self.remindAt = Date()
    }

    /// Done items live in the archive.
    var isCompleted: Bool { completedAt != nil }

    var reminderKind: ReminderKind {
        get { ReminderKind(rawValue: reminderKindRaw) ?? (slotMinutes != nil ? .daily : .custom) }
        set { reminderKindRaw = newValue.rawValue }
    }

    /// Waiting on the desk: its reminder time has come and it wants reminders.
    func isWaiting(at now: Date = Date()) -> Bool {
        completedAt == nil && reminderKind != .none && remindAt <= now
    }

    /// "Reminder Nov 14, 6:00 PM", "Weekly check-in, Sun 10:00 AM" or "No reminder".
    var reminderLabel: String {
        switch reminderKind {
        case .none: "No reminder"
        case .weekly: "Weekly check-in, \(remindAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        case .daily, .custom: "Reminder \(remindAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    /// The moment the item becomes overdue: the due time, or the end of the due day.
    var dueDeadline: Date? {
        guard let dueDate else { return nil }
        if dueHasTime { return dueDate }
        let startOfDay = Calendar.current.startOfDay(for: dueDate)
        return Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
    }

    func isOverdue(at now: Date = Date()) -> Bool {
        guard completedAt == nil, let deadline = dueDeadline else { return false }
        return now >= deadline
    }

    var dueLabel: String? {
        guard let dueDate else { return nil }
        return dueHasTime
            ? dueDate.formatted(date: .abbreviated, time: .shortened)
            : dueDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// Sets the due time. If the due day is today and that time has already
    /// passed, the due day moves to tomorrow. A later day is left alone.
    func setDueTime(hour: Int, minute: Int, now: Date = Date()) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: dueDate ?? now)
        var due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        if calendar.isDate(day, inSameDayAs: now), due <= now {
            due = calendar.date(byAdding: .day, value: 1, to: due) ?? due
        }
        dueDate = due
        dueHasTime = true
    }

    /// Sets the due day, keeping any time already chosen.
    func setDueDay(_ day: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        if dueHasTime, let current = dueDate {
            let parts = calendar.dateComponents([.hour, .minute], from: current)
            dueDate = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start)
        } else {
            dueDate = start
        }
    }

    var dueOption: DueOption { DueOption(rawValue: dueOptionRaw) ?? .custom }

    /// Sets the due date from a preset like "24 hours" (counted from now).
    /// Custom keeps the current date so it can be edited by hand.
    func applyDueOption(_ option: DueOption, now: Date = Date()) {
        dueOptionRaw = option.rawValue
        if let date = option.dueDate(from: now) {
            dueDate = date
            dueHasTime = true
        } else if dueDate == nil {
            dueDate = Calendar.current.startOfDay(for: now)
            dueHasTime = false
        }
    }

    func clearDueDate() {
        dueDate = nil
        dueHasTime = false
        dueOptionRaw = ""
    }

    func clearDueTime() {
        dueHasTime = false
        if let dueDate { self.dueDate = Calendar.current.startOfDay(for: dueDate) }
    }
}

@Model
final class ForLaterCategory {
    var name: String = ""
    var isBuiltIn: Bool = false
    /// Stable id for the starter categories ("events", "content", "other"),
    /// so they keep working after the user renames them. Empty for user-made ones.
    var builtInKey: String = ""
    var sortOrder: Int = 0
    /// The reminder new items in this category start with (see `ReminderKind`).
    /// Empty means a daily check-in, like before.
    var defaultReminderRaw: String = ""
    /// Adding an item here updates the Today summary, when the user picked
    /// "certain categories" for that.
    var triggersSummary: Bool = false
    @Relationship(deleteRule: .nullify, inverse: \ForLaterItem.category)
    var items: [ForLaterItem]? = []

    init(name: String, isBuiltIn: Bool = false, builtInKey: String = "", sortOrder: Int = 0) {
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.builtInKey = builtInKey
        self.sortOrder = sortOrder
    }

    static let builtInNames = ["Events", "Content", "Other"]

    /// Other is the catch-all: it can't be renamed or deleted.
    var isOther: Bool { builtInKey == "other" }
    /// Events items get the due date option.
    var isEvents: Bool { builtInKey == "events" }
    var isContent: Bool { builtInKey == "content" }

    var defaultReminder: ReminderKind {
        get { ReminderKind(rawValue: defaultReminderRaw) ?? .daily }
        set { defaultReminderRaw = newValue == .daily ? "" : newValue.rawValue }
    }
}

/// How an item reminds you.
enum ReminderKind: String, CaseIterable, Identifiable {
    /// At one of the daily check-in times (the default).
    case daily
    /// Only at the weekly check-in, for things that don't need a daily nudge, like recipes.
    case weekly
    /// At an exact date and time.
    case custom
    /// Never. It just waits on the desk.
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: "Daily check-in"
        case .weekly: "Weekly check-in"
        case .custom: "Custom date and time"
        case .none: "No reminder"
        }
    }
}

/// One of the user's daily "look at your For Laters" times (1 to 12 of them).
@Model
final class CheckInTime {
    var hour: Int = 18
    var minute: Int = 0

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    var minutesAfterMidnight: Int { hour * 60 + minute }

    var label: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The next time this check-in comes around after `date`.
    func nextOccurrence(after date: Date = Date()) -> Date {
        Self.nextOccurrence(minutesAfterMidnight: minutesAfterMidnight, after: date)
    }

    static func nextOccurrence(minutesAfterMidnight: Int, after date: Date = Date()) -> Date {
        let components = DateComponents(hour: minutesAfterMidnight / 60, minute: minutesAfterMidnight % 60)
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime) ?? date
    }
}

/// App-wide preferences that sync across the user's devices.
@Model
final class AppSettings {
    /// The user's home city, so the AI can pick the nearest event date and place.
    var hometown: String = ""
    /// How long archived items keep their screenshot. See `ScreenshotRetention`.
    var screenshotRetentionRaw: String = ScreenshotRetention.thirtyDays.rawValue
    /// How much AI to use (see `AIMode`). On-device AI by default.
    var aiModeRaw: String = AIMode.onDevice.rawValue
    /// On: AI polishes every text-recognition result. Off: AI only steps in when
    /// text recognition comes up short (no text, title or category).
    var aiAlwaysRefines: Bool = true
    /// Use the phone's location (city only) instead of the hometown.
    var useLocation: Bool = false
    /// The city from the last location check, like "Austin, TX".
    var locationCity: String = ""

    // Weekly check-in
    /// Days of the week for the weekly check-in, as Calendar weekdays
    /// (1 = Sunday ... 7 = Saturday), comma separated. Sunday by default.
    var weeklyDaysRaw: String = "1"
    /// Weekly check-in time, in minutes after midnight. 10 AM by default.
    var weeklyMinutes: Int = 600

    // Today summary
    var summaryEnabled: Bool = true
    /// The user's own instructions for the summary, up to `summaryInstructionsLimit` characters.
    var summaryInstructions: String = ""
    /// Update at the daily check-in times (the default).
    var summaryAtCheckIns: Bool = true
    /// Update at times of the user's choosing.
    var summaryAtCustomTimes: Bool = false
    /// Those times, in minutes after midnight, comma separated.
    var summaryCustomTimesRaw: String = "480"
    /// Update whenever a new For Later is added.
    var summaryOnNewItem: Bool = false
    /// With `summaryOnNewItem`: only for categories marked `triggersSummary`.
    var summaryOnlyCertainCategories: Bool = false
    /// Include events from the iPhone's calendars (Apple, Google, Outlook accounts added in iOS).
    var summaryUsesCalendar: Bool = false
    /// Calendar identifiers to read, comma separated. Empty means all calendars.
    var summaryCalendarIDsRaw: String = ""

    static let summaryInstructionsLimit = 1000

    init(hometown: String = "") {
        self.hometown = hometown
    }

    var aiMode: AIMode {
        get { AIMode(rawValue: aiModeRaw) ?? .onDevice }
        set { aiModeRaw = newValue.rawValue }
    }

    /// The place the AI should treat as "near you": current city if location is
    /// on and known, otherwise the hometown. Empty if neither is set.
    var aiLocation: String {
        if useLocation, !locationCity.isEmpty { return locationCity }
        return hometown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var weeklyDays: Set<Int> {
        get { Set(weeklyDaysRaw.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }) }
        set { weeklyDaysRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    /// The next weekly check-in after `date`.
    func nextWeeklyCheckIn(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let days = weeklyDays.isEmpty ? [1] : weeklyDays
        let candidates = days.compactMap { weekday in
            calendar.nextDate(after: date,
                              matching: DateComponents(hour: weeklyMinutes / 60, minute: weeklyMinutes % 60, weekday: weekday),
                              matchingPolicy: .nextTime)
        }
        return candidates.min() ?? date.addingTimeInterval(7 * 86_400)
    }

    /// "Sun 10:00 AM" or "Sun & Wed 10:00 AM".
    var weeklyLabel: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = weeklyDays.sorted().map { symbols[$0 - 1] }.joined(separator: " & ")
        let time = Calendar.current.date(from: DateComponents(hour: weeklyMinutes / 60, minute: weeklyMinutes % 60))?
            .formatted(date: .omitted, time: .shortened) ?? ""
        return days.isEmpty ? time : "\(days) \(time)"
    }

    var summaryCustomTimes: [Int] {
        get { summaryCustomTimesRaw.split(separator: ",").compactMap { Int($0) }.sorted() }
        set { summaryCustomTimesRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    var summaryCalendarIDs: Set<String> {
        get { Set(summaryCalendarIDsRaw.split(separator: ",").map(String.init)) }
        set { summaryCalendarIDsRaw = newValue.sorted().joined(separator: ",") }
    }

    var screenshotRetention: ScreenshotRetention {
        get { ScreenshotRetention(rawValue: screenshotRetentionRaw) ?? .thirtyDays }
        set { screenshotRetentionRaw = newValue.rawValue }
    }
}

/// How long a screenshot is kept after its item is archived.
enum ScreenshotRetention: String, CaseIterable, Identifiable {
    case immediately, oneHour, oneDay, thirtyDays, oneYear, forever

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immediately: "Delete right away"
        case .oneHour: "After 1 hour"
        case .oneDay: "After 1 day"
        case .thirtyDays: "After 30 days"
        case .oneYear: "After 1 year"
        case .forever: "Keep forever"
        }
    }

    /// nil means keep forever.
    var interval: TimeInterval? {
        switch self {
        case .immediately: 0
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .thirtyDays: 30 * 86_400
        case .oneYear: 365 * 86_400
        case .forever: nil
        }
    }
}

/// Due date choices on the card. Presets count from the moment you pick them.
enum DueOption: String, CaseIterable, Identifiable {
    case oneHour, twentyFourHours, oneWeek, twoWeeks, oneMonth, twoMonths, threeMonths, sixMonths, oneYear, custom

    static let defaultOption: DueOption = .twentyFourHours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .twentyFourHours: "24 hours"
        case .oneWeek: "1 week"
        case .twoWeeks: "2 weeks"
        case .oneMonth: "1 month"
        case .twoMonths: "2 months"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .custom: "Custom"
        }
    }

    /// nil for custom.
    func dueDate(from now: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .oneHour: return calendar.date(byAdding: .hour, value: 1, to: now)
        case .twentyFourHours: return calendar.date(byAdding: .day, value: 1, to: now)
        case .oneWeek: return calendar.date(byAdding: .day, value: 7, to: now)
        case .twoWeeks: return calendar.date(byAdding: .day, value: 14, to: now)
        case .oneMonth: return calendar.date(byAdding: .month, value: 1, to: now)
        case .twoMonths: return calendar.date(byAdding: .month, value: 2, to: now)
        case .threeMonths: return calendar.date(byAdding: .month, value: 3, to: now)
        case .sixMonths: return calendar.date(byAdding: .month, value: 6, to: now)
        case .oneYear: return calendar.date(byAdding: .year, value: 1, to: now)
        case .custom: return nil
        }
    }
}

/// How much AI For Later uses. Each level adds to the one before it:
/// Vision/OCR, then on-device AI. Everything stays on the device.
/// (An old saved "full" value reads back as on-device AI.)
enum AIMode: String, CaseIterable, Identifiable {
    case manual, visionOnly, onDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .visionOnly: "Limited AI (Vision/OCR)"
        case .onDevice: "On-device AI"
        }
    }

    var summary: String {
        switch self {
        case .manual:
            "Nothing is read automatically. You fill in every card yourself."
        case .visionOnly:
            "Apple's Vision reads the text, links and dates in your screenshot and puts them in the right fields. No AI language model is used."
        case .onDevice:
            "Adds Apple's on-device AI to write clear titles, pick categories and understand photos. Everything runs on your iPhone; nothing is sent to any server."
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "hand.point.up.left"
        case .visionOnly: "text.viewfinder"
        case .onDevice: "iphone"
        }
    }
}

/// Which step actually filled in a card.
enum AnalysisEngine: String {
    case none, vision, onDevice

    var label: String {
        switch self {
        case .none: "You"
        case .vision: "Text recognition (on this device)"
        case .onDevice: "On-device AI"
        }
    }
}
