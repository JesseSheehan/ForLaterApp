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

    init(title: String = "", screenshot: Data? = nil, link: String = "") {
        self.title = title
        self.screenshot = screenshot
        self.link = link
        self.createdAt = Date()
        self.remindAt = Date()
    }

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

    init(hometown: String = "") {
        self.hometown = hometown
    }
}
