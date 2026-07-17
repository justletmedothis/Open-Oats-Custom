import XCTest
@testable import OpenOatsKit

final class DefaultsHygieneTests: XCTestCase {
    /// Every makeSettings()-style helper creates a UserDefaults suite with a
    /// unique UUID name (com.openoats.test.* / com.openoats.tests.*). The
    /// backing plist survives the test process, so each `swift test` run
    /// leaked a few hundred files into ~/Library/Preferences (2,400+ observed
    /// before this sweep existed). Deleting only suites older than 30 minutes
    /// keeps this safe against test runs executing in parallel with this one.
    func testSweepLeakedSuitesFromPriorRuns() throws {
        let fm = FileManager.default
        let prefsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let entries = try fm.contentsOfDirectory(
            at: prefsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = Date().addingTimeInterval(-30 * 60)
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("com.openoats.test"), name.hasSuffix(".plist") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            let domain = String(name.dropLast(".plist".count))
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? fm.removeItem(at: url)
        }
    }
}
