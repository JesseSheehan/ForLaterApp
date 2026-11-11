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
    /// Brought back from the archive. Revived items are shown in purple.
    var isRevived: Bool = false
    var revivedAt: Date?

    init(title: String = "", screenshot: Data? = nil, link: String = "") {
        self.title = title
        self.screenshot = screenshot
        self.link = link
        self.createdAt = Date()
        self.remindAt = Date()
    }

    /// Done items live in the archive.
    var isCompleted: Bool { completedAt != nil }

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
    var sortOrder: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \ForLaterItem.category)
    var items: [ForLaterItem]? = []

    init(name: String, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    static let builtInNames = ["Events", "Content", "Other"]
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

    init(hometown: String = "") {
        self.hometown = hometown
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
