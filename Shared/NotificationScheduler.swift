import Foundation
import SwiftData
import UserNotifications

/// Schedules the "look at your For Laters" notifications.
///
/// At each daily check-in time, if anything on the desk has reached its
/// reminder time, you get "3 For Laters waiting" with their titles. Times with
/// nothing due are skipped. Items with a custom reminder time also get a
/// notification at that exact time. Everything is local; no server.
///
/// iOS allows 64 scheduled notifications per app, so this schedules the next
/// 60 and is re-run whenever the app or share sheet is used.
enum NotificationScheduler {
    private static let idPrefix = "forlater.checkin."
    private static let maxRequests = 60
    private static let lookAheadDays = 60

    static func requestPermission() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return granted ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Rebuilds every pending check-in notification from the current data.
    @MainActor
    static func reschedule(in context: ModelContext, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        let openItems = (try? context.fetch(FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.completedAt == nil }))) ?? []
        let times = (try? context.fetch(FetchDescriptor<CheckInTime>(sortBy: [SortDescriptor(\.hour), SortDescriptor(\.minute)]))) ?? []

        try? await center.setBadgeCount(openItems.filter { $0.remindAt <= now }.count)

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional, !openItems.isEmpty else { return }

        // Candidate moments: every check-in time over the coming weeks, plus custom reminder times.
        let calendar = Calendar.current
        var moments = Set<Date>()
        var day = calendar.startOfDay(for: now)
        for _ in 0..<lookAheadDays {
            for time in times {
                if let moment = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day), moment > now {
                    moments.insert(moment)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for item in openItems where item.slotMinutes == nil && item.remindAt > now {
            moments.insert(item.remindAt)
        }

        var scheduled = 0
        for moment in moments.sorted() {
            guard scheduled < maxRequests else { break }
            // Items whose reminder time has been reached by this moment.
            let due = openItems
                .filter { $0.remindAt <= moment.addingTimeInterval(1) }
                .sorted { $0.remindAt < $1.remindAt }
            guard !due.isEmpty else { continue }  // nothing due, no nudge

            let content = UNMutableNotificationContent()
            content.title = due.count == 1 ? "1 For Later waiting" : "\(due.count) For Laters waiting"
            content.body = body(for: due)
            content.sound = .default
            content.badge = NSNumber(value: due.count)
            content.threadIdentifier = "check-in"

            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            let id = idPrefix + String(Int(moment.timeIntervalSince1970))
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            scheduled += 1
        }
    }

    private static func body(for due: [ForLaterItem]) -> String {
        let titles = due.prefix(3).map { $0.title.isEmpty ? "Untitled" : $0.title }
        var text = titles.joined(separator: ", ")
        if due.count > 3 {
            text += " and \(due.count - 3) more"
        }
        return text + ". Time to clear your desk."
    }
}
