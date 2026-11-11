import SwiftUI
import SwiftData

@main
struct ForLaterApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                DeskView()
            } else {
                OnboardingView(onFinish: {
                    withAnimation { hasCompletedOnboarding = true }
                })
            }
        }
        .modelContainer(DataStore.shared)
    }
}
