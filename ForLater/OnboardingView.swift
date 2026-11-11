import SwiftUI
import SwiftData

/// First launch: allow notifications, pick check-in times, learn how it works.
/// Finishing puts a "Clear desk" item on the desk to practice with.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, notifications, times, howTo
    }

    @State private var step: Step = .welcome
    @State private var notificationsAnswered = false
    @State private var notificationsAllowed = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(count: Step.allCases.count, index: step.rawValue)
                .padding(.top, 12)

            Group {
                switch step {
                case .welcome: welcome
                case .notifications: notifications
                case .times: CheckInTimesStep(onContinue: { go(to: .howTo) })
                case .howTo: HowToStep(onFinish: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
        }
        .task { DataStore.seedIfNeeded(context) }
    }

    // MARK: Steps

    private var welcome: some View {
        StepLayout(
            systemImage: "tray.full",
            title: "For Later",
            message: "Screenshot it now. Deal with it later. For Later turns screenshots into reminders and nudges you to clear your desk every day."
        ) {
            Button("Get started") { go(to: .notifications) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var notifications: some View {
        StepLayout(
            systemImage: "bell.badge",
            title: "Allow notifications",
            message: notificationsAnswered && !notificationsAllowed
                ? "No problem. You can turn notifications on later in the Settings app. For Later works best with them on."
                : "For Later reminds you at the times you choose to look at what you've saved. Only when something is waiting."
        ) {
            if notificationsAnswered {
                Button("Continue") { go(to: .times) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Allow notifications") {
                    Task {
                        notificationsAllowed = await NotificationScheduler.requestPermission()
                        notificationsAnswered = true
                        if notificationsAllowed { go(to: .times) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func go(to next: Step) {
        withAnimation(.snappy) { step = next }
    }

    private func finish() {
        let other = try? context.fetch(FetchDescriptor<ForLaterCategory>()).first(where: { $0.isOther })
        let starter = ForLaterItem(title: "Clear desk")
        starter.notes = "This is your first For Later. Tap Done to clear it and see what a clear desk feels like."
        starter.category = other
        starter.isStarter = true
        starter.remindAt = Date()
        context.insert(starter)
        try? context.save()
        Task { await NotificationScheduler.reschedule(in: context) }
        onFinish()
    }
}

// MARK: - Times step

private struct CheckInTimesStep: View {
    @Environment(\.modelContext) private var context
    let onContinue: () -> Void

    @Query(sort: [SortDescriptor(\CheckInTime.hour), SortDescriptor(\CheckInTime.minute)])
    private var times: [CheckInTime]

    private let maxTimes = 12

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("When should we remind you?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Pick at least one time a day. Fewer is better: one daily check-in, as part of your routine, works best.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)

            List {
                ForEach(times) { time in
                    DatePicker("Check-in", selection: binding(for: time), displayedComponents: .hourAndMinute)
                }
                .onDelete { offsets in
                    guard times.count - offsets.count >= 1 else { return }
                    for index in offsets { context.delete(times[index]) }
                }
                .deleteDisabled(times.count <= 1)

                Button("Add another time", systemImage: "plus") {
                    let latest = times.last?.hour ?? 17
                    context.insert(CheckInTime(hour: min(latest + 1, 21), minute: 0))
                }
                .disabled(times.count >= maxTimes)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 360)

            Spacer(minLength: 0)

            Button("Continue") {
                try? context.save()
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(times.isEmpty)
            .padding(.bottom, 24)
        }
    }

    private func binding(for time: CheckInTime) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? Date() },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                time.hour = parts.hour ?? time.hour
                time.minute = parts.minute ?? time.minute
            }
        )
    }
}

// MARK: - How-to cards

private struct HowToStep: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Card {
        let systemImage: String
        let title: String
        let message: String
    }

    private let cards: [Card] = [
        Card(systemImage: "camera.viewfinder", title: "Take a screenshot",
             message: "See something you want to come back to? Take a screenshot of it."),
        Card(systemImage: "crop", title: "Crop it (recommended)",
             message: "Crop the screenshot to just the part you want to be reminded of."),
        Card(systemImage: "square.and.arrow.up", title: "Share it to For Later",
             message: "Tap the Share button and choose For Later."),
        Card(systemImage: "sparkles", title: "AI fills in the card",
             message: "For Later reads the image and fills in the content, category, reminder time, link and notes. Change anything you like."),
        Card(systemImage: "checkmark.circle", title: "Tap the check",
             message: "Tap the check button to save your For Later."),
        Card(systemImage: "bell", title: "Get reminded",
             message: "At your check-in time, you'll get a reminder to look at your For Laters. Mark them Done to clear your desk."),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("How it works")
                .font(.title2.weight(.bold))
                .padding(.top, 32)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    VStack(spacing: 16) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(.tint.opacity(0.15), in: Circle())
                        Image(systemName: card.systemImage)
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text(card.title)
                            .font(.title3.weight(.semibold))
                        Text(card.message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 24)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(maxHeight: 420)

            Spacer(minLength: 0)

            Button(page == cards.count - 1 ? "Go to my desk" : "Next") {
                if page == cards.count - 1 {
                    onFinish()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Shared pieces

private struct StepLayout<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            actions
                .padding(.bottom, 24)
        }
    }
}

private struct ProgressDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == index ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: index)
    }
}
