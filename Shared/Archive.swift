import Foundation
import SwiftData

/// Archiving (Done), reviving, permanent deletes, and screenshot clean-up.
enum Archive {

    /// Done: moves the item to the archive.
    @MainActor
    static func archive(_ item: ForLaterItem, in context: ModelContext) {
        item.completedAt = Date()
        if DataStore.settings(in: context).screenshotRetention == .immediately {
            item.screenshot = nil
        }
        try? context.save()
    }

    /// Brings an archived item back to the desk, marked as revived.
    @MainActor
    static func revive(_ item: ForLaterItem, in context: ModelContext) {
        item.completedAt = nil
        item.isRevived = true
        item.revivedAt = Date()
        // If its reminder time has passed, move it to the next time it comes around.
        Reminders.moveForwardIfPassed(item, in: context)
        try? context.save()
    }

    /// Deletes an archived item for good, screenshot and all.
    @MainActor
    static func deletePermanently(_ item: ForLaterItem, in context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    /// Removes screenshots from archived items once they're older than the
    /// user's setting. Runs when the app opens and when the setting changes.
    @MainActor
    static func applyScreenshotRetention(in context: ModelContext, now: Date = Date()) {
        guard let interval = DataStore.settings(in: context).screenshotRetention.interval else { return }
        let descriptor = FetchDescriptor<ForLaterItem>(predicate: #Predicate { $0.completedAt != nil })
        guard let archived = try? context.fetch(descriptor) else { return }
        var changed = false
        for item in archived {
            guard item.screenshot != nil, let completedAt = item.completedAt else { continue }
            if now.timeIntervalSince(completedAt) >= interval {
                item.screenshot = nil
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
