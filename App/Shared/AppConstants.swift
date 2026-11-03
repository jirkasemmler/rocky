import Foundation

enum AppConstants {
    /// App Group shared by the iOS app (and future widget/complication extensions).
    /// Note: App Groups do NOT share data between iPhone and Watch; that goes over WatchConnectivity.
    static let appGroupID = "group.cz.semmler.rocky"
    static let dataFileName = "training-data.json"

    /// Local JSON file in the App Group container (falls back to Application Support).
    static func dataFileURL() -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent(dataFileName)
        }
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent(dataFileName)
    }
}
