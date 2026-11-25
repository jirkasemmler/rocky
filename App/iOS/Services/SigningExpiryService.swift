import Foundation
import RockyCore
import UserNotifications

/// Reminds the user to reinstall before the code signing runs out (D-28). A build signed with a
/// free Personal Team stops launching after 7 days; the watch app and its complication have
/// their own profiles (embedded in this bundle), so the earliest of the three counts.
struct SigningExpiryService: Sendable {
    static let identifierPrefix = "signing-"
    private static let profilePaths = [
        "embedded.mobileprovision",
        "Watch/RockyWatch.app/embedded.mobileprovision",
        "Watch/RockyWatch.app/PlugIns/RockyWatchWidgets.appex/embedded.mobileprovision",
    ]

    /// Nil when the bundle has no provisioning profile (simulator, App Store build).
    static func expiry(bundle: Bundle = .main) -> Date? {
        let profiles = profilePaths.compactMap { try? Data(contentsOf: bundle.bundleURL.appendingPathComponent($0)) }
        return SigningExpiry.earliestExpiration(inProvisioningProfiles: profiles)
    }

    static func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "cs_CZ")))
    }

    /// Replaces the pending signing reminders with the ones for the current build.
    func reschedule(now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard let expiry = Self.expiry() else { return }
        let calendar = Calendar.current
        for (index, fireDate) in SigningExpiry.reminderDates(expiry: expiry, now: now, calendar: calendar).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Rocky potřebuje přeinstalovat"
            content.body = "Podpis aplikace vyprší \(Self.formatted(expiry)), potom se Rocky neotevře v telefonu ani v hodinkách. "
                + "Připoj iPhone k Macu, měj u sebe odemčené hodinky a pusť bash tools/install-iphone.sh."
            content.sound = .default
            content.threadIdentifier = "signing"
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.identifierPrefix + String(index), content: content, trigger: trigger))
        }
    }
}
