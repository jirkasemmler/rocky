import Foundation
import RockyCore
import UserNotifications

/// Local notifications only (no server, PRD 8a). The planner computes the reminders
/// (incl. escalation on catch-up days); this service just (re)schedules them.
protocol NotificationScheduling: Sendable {
    func requestAuthorization() async -> Bool
    func reschedule(_ reminders: [Reminder]) async
}

struct NotificationService: NotificationScheduling {
    static let identifierPrefix = "reminder-"
    /// iOS keeps at most 64 pending local notifications per app.
    static let maxPending = 60

    static func isTimeSensitive(_ reminder: Reminder) -> Bool {
        reminder.isCatchUp || reminder.level > 0
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func reschedule(_ reminders: [Reminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        let calendar = Calendar.current
        for reminder in reminders.sorted(by: { $0.fireDate < $1.fireDate }).prefix(Self.maxPending) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = reminder.isCatchUp ? "catch-up" : "reminder"
            // Catch-up (debt) reminders and escalations (+1 h / +2 h) are time-sensitive so they get
            // through Focus modes; the plain reminder at the set hour stays `.active` (D-19).
            content.interruptionLevel = Self.isTimeSensitive(reminder) ? .timeSensitive : .active
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: Self.identifierPrefix + reminder.id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
