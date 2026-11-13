import Foundation
import SwiftData

/// Sets an item's reminder from a reminder kind, so the card, the archive and
/// the category defaults all work the same way.
enum Reminders {

    /// Daily: at `slot` (minutes after midnight), or the first check-in time.
    /// Weekly: the next weekly check-in. Custom: keeps a future time, otherwise
    /// an hour from now. None: no reminder at all.
    @MainActor
    static func apply(_ kind: ReminderKind, slot: Int? = nil, to item: ForLaterItem, in context: ModelContext, now: Date = Date()) {
        item.reminderKind = kind
        switch kind {
        case .daily:
            let minutes = slot ?? item.slotMinutes ?? firstCheckInMinutes(in: context) ?? 18 * 60
            item.slotMinutes = minutes
            item.remindAt = CheckInTime.nextOccurrence(minutesAfterMidnight: minutes, after: now)
        case .weekly:
            item.slotMinutes = nil
            item.remindAt = DataStore.settings(in: context).nextWeeklyCheckIn(after: now)
        case .custom:
            item.slotMinutes = nil
            if item.remindAt < now {
                item.remindAt = now.addingTimeInterval(3_600)
            }
        case .none:
            item.slotMinutes = nil
        }
    }

    /// Moves a reminder that has already passed to the next time it comes around.
    /// Used when reviving an item from the archive.
    @MainActor
    static func moveForwardIfPassed(_ item: ForLaterItem, in context: ModelContext, now: Date = Date()) {
        guard item.remindAt < now else { return }
        switch item.reminderKind {
        case .daily, .custom:
            apply(.daily, slot: item.slotMinutes, to: item, in: context, now: now)
        case .weekly:
            apply(.weekly, to: item, in: context, now: now)
        case .none:
            break
        }
    }

    @MainActor
    static func firstCheckInMinutes(in context: ModelContext) -> Int? {
        let descriptor = FetchDescriptor<CheckInTime>(sortBy: [SortDescriptor(\.hour), SortDescriptor(\.minute)])
        return (try? context.fetch(descriptor))?.first?.minutesAfterMidnight
    }
}
