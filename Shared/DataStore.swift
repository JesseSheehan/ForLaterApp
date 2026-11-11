import Foundation
import SwiftData

enum AppIdentifiers {
    static let appGroup = "group.com.jessesheehan.ForLater"
    static let cloudKitContainer = "iCloud.com.jessesheehan.ForLater"
}

enum DataStore {
    static let schema = Schema([ForLaterItem.self, ForLaterCategory.self, CheckInTime.self])

    /// One store in the shared App Group folder, used by both the app and the
    /// share extension, and synced to the user's private iCloud database.
    static let shared: ModelContainer = {
        do {
            let config = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(AppIdentifiers.appGroup),
                cloudKitDatabase: .private(AppIdentifiers.cloudKitContainer)
            )
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Falls back to a local-only store, for example before signing and
            // iCloud are set up in Xcode.
            print("For Later: iCloud store unavailable, using local store. \(error)")
            do {
                let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("For Later: could not open any data store: \(error)")
            }
        }
    }()

    /// Adds the built-in categories and a default check-in time the first time.
    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let categoryCount = (try? context.fetchCount(FetchDescriptor<ForLaterCategory>())) ?? 0
        if categoryCount == 0 {
            for (index, name) in ForLaterCategory.builtInNames.enumerated() {
                context.insert(ForLaterCategory(name: name, isBuiltIn: true, sortOrder: index))
            }
        }
        // Onboarding (next phase) lets the user choose these. Until then, 6 PM.
        let timeCount = (try? context.fetchCount(FetchDescriptor<CheckInTime>())) ?? 0
        if timeCount == 0 {
            context.insert(CheckInTime(hour: 18, minute: 0))
        }
        try? context.save()
    }
}
