import SwiftUI
import SwiftData

@main
struct ForLaterApp: App {
    var body: some Scene {
        WindowGroup {
            DeskView()
        }
        .modelContainer(DataStore.shared)
    }
}
