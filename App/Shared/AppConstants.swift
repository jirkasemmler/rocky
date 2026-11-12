import Foundation

enum AppConstants {
    /// App Group shared by the iOS app (and future widget/complication extensions).
    /// Note: App Groups do NOT share data between iPhone and Watch; that goes over WatchConnectivity.
    static let appGroupID = "group.cz.semmler.rocky"
    static let dataFileName = "training-data.json"

    /// UI tests launch the app with `-uiTesting`: fresh data in a temp file, no permission prompts.
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }

    /// `-uiTestingPlanStartDaysAgo N`: start the plan N days ago (to get debt / catch-up states).
    static var uiTestingPlanStartDaysAgo: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiTestingPlanStartDaysAgo"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Cached server catalog, next to the data file.
    static func catalogFileURL() -> URL {
        dataFileURL().deletingLastPathComponent().appendingPathComponent(isUITesting ? "uitest-catalog.json" : "catalog.json")
    }

    /// Server sync state (iPhone only), next to the data file.
    static func syncStateFileURL() -> URL {
        dataFileURL().deletingLastPathComponent().appendingPathComponent(isUITesting ? "uitest-sync-state.json" : "sync-state.json")
    }

    /// Local JSON file in the App Group container (falls back to Application Support).
    static func dataFileURL() -> URL {
        let fm = FileManager.default
        if isUITesting {
            return fm.temporaryDirectory.appendingPathComponent("uitest-" + dataFileName)
        }
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent(dataFileName)
        }
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent(dataFileName)
    }
}
