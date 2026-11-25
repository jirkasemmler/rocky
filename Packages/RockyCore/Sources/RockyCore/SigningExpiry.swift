import Foundation

/// When does the app's code signing run out (D-28)? A build signed with a free Personal Team
/// stops launching 7 days after its provisioning profile was issued, so the app reminds the
/// user to reinstall before that. Pure logic: the app passes in the profile files it finds.
public enum SigningExpiry {
    /// `ExpirationDate` of a `.mobileprovision` file: a signed (CMS) blob with an XML property
    /// list inside. Nil when the data holds no such plist.
    public static func expirationDate(inProvisioningProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// The earliest expiry among the profiles (phone app, watch app, complication): the first
    /// one to run out is the one that breaks something. Unreadable profiles are skipped.
    public static func earliestExpiration(inProvisioningProfiles profiles: [Data]) -> Date? {
        profiles.compactMap(expirationDate(inProvisioningProfile:)).min()
    }

    /// Hour of the reminder on the evening before the expiry day.
    public static let eveningHour = 18
    /// Hour of the reminder on the expiry day.
    public static let morningHour = 8
    /// A reminder closer to the expiry than this leaves no time to reinstall.
    public static let minimumLead: TimeInterval = 3600
    /// Lead of the last-resort reminder, used when both regular ones are unusable.
    public static let fallbackLead: TimeInterval = 3 * 3600

    /// When to remind: 18:00 the day before the expiry day and 8:00 on the expiry day, each only
    /// if it is still in the future and at least an hour before the expiry. If neither is left
    /// (the app was opened late on the last day), one reminder 3 hours before the expiry, or
    /// right away when even that has passed. Empty once the signing has expired.
    public static func reminderDates(expiry: Date, now: Date, calendar: Calendar) -> [Date] {
        guard expiry > now else { return [] }
        let expiryDay = calendar.startOfDay(for: expiry)
        var candidates: [Date] = []
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: expiryDay),
           let evening = calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: dayBefore) {
            candidates.append(evening)
        }
        if let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: expiryDay) {
            candidates.append(morning)
        }
        let usable = candidates.filter { $0 > now && expiry.timeIntervalSince($0) >= minimumLead }
        if !usable.isEmpty { return usable.sorted() }
        let fallback = expiry.addingTimeInterval(-fallbackLead)
        return [fallback > now ? fallback : now.addingTimeInterval(60)].filter { $0 < expiry }
    }
}
