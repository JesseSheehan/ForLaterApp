import Foundation
import SwiftData
import UserNotifications

/// Schedules the "look at your For Laters" notifications.
///
/// At each daily check-in time, if anything on the desk has reached its
/// reminder time, you get "3 For Laters waiting" with their titles. Times with
/// nothing due are skipped. Items with a custom reminder time also get a
/// notification at that exact time. Weekly items are only mentioned at the
/// weekly check-in, and items set to "No reminder" never are. Everything is
/// local; no server.
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

        let openItems = ((try? context.fetch(FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.completedAt == nil }))) ?? [])
            .filter { $0.reminderKind != .none }
        let times = (try? context.fetch(FetchDescriptor<CheckInTime>(sortBy: [SortDescriptor(\.hour), SortDescriptor(\.minute)]))) ?? []
        let settings = DataStore.settings(in: context)

        try? await center.setBadgeCount(openItems.filter { $0.isWaiting(at: now) }.count)

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional, !openItems.isEmpty else { return }

        // Candidate moments over the coming weeks. The value says whether it's a
        // weekly check-in, which is the only time weekly items are mentioned.
        let calendar = Calendar.current
        var moments: [Date: Bool] = [:]
        let weeklyDays = settings.weeklyDays
        let hasWeeklyItems = openItems.contains { $0.reminderKind == .weekly }
        var day = calendar.startOfDay(for: now)
        for _ in 0..<lookAheadDays {
            for time in times {
                if let moment = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day), moment > now {
                    moments[moment] = moments[moment] ?? false
                }
            }
            if hasWeeklyItems, weeklyDays.contains(calendar.component(.weekday, from: day)),
               let moment = calendar.date(bySettingHour: settings.weeklyMinutes / 60, minute: settings.weeklyMinutes % 60, second: 0, of: day),
               moment > now {
                moments[moment] = true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for item in openItems where item.reminderKind == .custom && item.remindAt > now {
            moments[item.remindAt] = moments[item.remindAt] ?? false
        }

        var scheduled = 0
        for moment in moments.keys.sorted() {
            guard scheduled < maxRequests else { break }
            let isWeekly = moments[moment] ?? false
            // Items whose reminder time has been reached by this moment. Weekly
            // items only count at a weekly check-in.
            let due = openItems
                .filter { $0.remindAt <= moment.addingTimeInterval(1) && ($0.reminderKind != .weekly || isWeekly) }
                .sorted { $0.remindAt < $1.remindAt }
            guard !due.isEmpty else { continue }  // nothing due, no nudge

            let content = UNMutableNotificationContent()
            let count = due.count == 1 ? "1 For Later waiting" : "\(due.count) For Laters waiting"
            content.title = isWeekly ? "Weekly check-in: \(count)" : count
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
