import SwiftUI
import EventKit
import EventKitUI

/// Apple's own "New Event" screen, filled in from a For Later. The user picks
/// the calendar (iCloud, Google, Outlook or any other account on the iPhone)
/// and taps Add. iOS shows this screen without asking for calendar access,
/// because the user decides what's saved.
struct AddToCalendarView: UIViewControllerRepresentable {
    let item: ForLaterItem
    let onFinish: (_ added: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = item.title.isEmpty ? "For Later" : item.title

        let start = item.dueDate ?? item.remindAt
        if item.dueDate != nil && !item.dueHasTime {
            event.isAllDay = true
            event.startDate = Calendar.current.startOfDay(for: start)
            event.endDate = event.startDate
        } else {
            event.startDate = start
            event.endDate = start.addingTimeInterval(3_600)
        }
        if !item.notes.isEmpty { event.notes = item.notes }
        if let url = URL(string: item.link), !item.link.isEmpty { event.url = url }

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action == .saved)
        }
    }
}
