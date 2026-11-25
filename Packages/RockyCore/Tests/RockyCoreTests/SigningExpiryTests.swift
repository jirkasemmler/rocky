import XCTest
@testable import RockyCore

final class SigningExpiryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A synthetic profile: binary junk around an XML plist, like the CMS envelope of a real one.
    private func profile(expiration: String?) -> Data {
        let entry = expiration.map { "<key>ExpirationDate</key><date>\($0)</date>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Test profile</string>\(entry)</dict></plist>
        """
        return Data([0x30, 0x82, 0x00, 0xFF]) + Data(xml.utf8) + Data([0xA0, 0x82, 0x01, 0x00, 0xFE])
    }

    func testReadsExpirationDateFromProfile() {
        let data = profile(expiration: "2026-12-02T21:02:40Z")
        XCTAssertEqual(SigningExpiry.expirationDate(inProvisioningProfile: data), date(2026, 12, 2, 22, 2).addingTimeInterval(40))
    }

    func testUnreadableProfilesGiveNil() {
        XCTAssertNil(SigningExpiry.expirationDate(inProvisioningProfile: Data()))
        XCTAssertNil(SigningExpiry.expirationDate(inProvisioningProfile: Data([0x01, 0x02, 0x03])))
        XCTAssertNil(SigningExpiry.expirationDate(inProvisioningProfile: profile(expiration: nil)))
        XCTAssertNil(SigningExpiry.expirationDate(inProvisioningProfile: Data("<?xml broken </plist>".utf8)))
    }

    func testEarliestExpirationWinsAndSkipsUnreadable() {
        let phone = profile(expiration: "2026-11-26T09:10:40Z")
        let watch = profile(expiration: "2026-11-22T22:43:44Z")
        XCTAssertEqual(
            SigningExpiry.earliestExpiration(inProvisioningProfiles: [phone, Data([0x00]), watch]),
            SigningExpiry.expirationDate(inProvisioningProfile: watch)
        )
        XCTAssertNil(SigningExpiry.earliestExpiration(inProvisioningProfiles: []))
    }

    func testRemindsEveningBeforeAndMorningOfExpiryDay() {
        let dates = SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 22, 2), now: date(2026, 11, 25, 20), calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 12, 1, 18), date(2026, 12, 2, 8)])
    }

    func testPastReminderIsSkipped() {
        let dates = SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 22, 2), now: date(2026, 12, 1, 19), calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 12, 2, 8)])
    }

    func testMorningTooCloseToExpiryIsSkipped() {
        let dates = SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 8, 30), now: date(2026, 11, 25, 20), calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 12, 1, 18)])
    }

    func testLateOnLastDayFallsBackToThreeHoursBefore() {
        let dates = SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 22, 2), now: date(2026, 12, 2, 9), calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 12, 2, 19, 2)])
    }

    func testInLastHoursRemindsRightAway() {
        let now = date(2026, 12, 2, 21)
        let dates = SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 22, 2), now: now, calendar: calendar)
        XCTAssertEqual(dates, [now.addingTimeInterval(60)])
    }

    func testNoRemindersAfterExpiry() {
        XCTAssertEqual(SigningExpiry.reminderDates(expiry: date(2026, 12, 2, 22, 2), now: date(2026, 12, 2, 23), calendar: calendar), [])
    }
}
