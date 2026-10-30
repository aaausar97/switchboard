import Foundation

@main
struct WindowOwnerExclusionTests {
    private struct Case {
        let name: String
        let ownerName: String
        let bundleIdentifier: String?
        let savedExclusions: Set<String>
        let expectedExcluded: Bool
    }

    static func main() {
        // Pass saved exclusion sets directly: no singleton, real preferences, or NSApplication.
        let cases: [Case] = [
            Case(name: "CUA with empty saved exclusions", ownerName: "CuaDriver", bundleIdentifier: "com.trycua.driver", savedExclusions: [], expectedExcluded: true),
            Case(name: "CUA with custom saved exclusions", ownerName: "CuaDriver", bundleIdentifier: "com.trycua.driver", savedExclusions: ["Safari"], expectedExcluded: true),
            Case(name: "CUA with differing display name", ownerName: "Automation Helper", bundleIdentifier: "com.trycua.driver", savedExclusions: ["Safari"], expectedExcluded: true),
            Case(name: "ordinary app", ownerName: "Safari", bundleIdentifier: "com.apple.Safari", savedExclusions: [], expectedExcluded: false),
            Case(name: "ordinary app with unrelated saved exclusion", ownerName: "Safari", bundleIdentifier: "com.apple.Safari", savedExclusions: ["Terminal"], expectedExcluded: false),
            Case(name: "unknown bundle", ownerName: "Helper", bundleIdentifier: "org.example.unknown", savedExclusions: ["Safari"], expectedExcluded: false),
            Case(name: "nil bundle", ownerName: "Helper", bundleIdentifier: nil, savedExclusions: ["Safari"], expectedExcluded: false),
            Case(name: "driver name alone is not identity", ownerName: "CuaDriver", bundleIdentifier: "org.example.editor", savedExclusions: [], expectedExcluded: false),
            Case(name: "driver name with nil bundle", ownerName: "CuaDriver", bundleIdentifier: nil, savedExclusions: [], expectedExcluded: false),
            Case(name: "user owner-name exclusion", ownerName: "Safari", bundleIdentifier: "com.apple.Safari", savedExclusions: ["Safari"], expectedExcluded: true),
            Case(name: "user exclusion with nil bundle", ownerName: "Helper", bundleIdentifier: nil, savedExclusions: ["Helper"], expectedExcluded: true),
            Case(name: "user exclusion with unknown bundle", ownerName: "Helper", bundleIdentifier: "org.example.unknown", savedExclusions: ["Helper"], expectedExcluded: true),
            Case(name: "bundle suffix near match", ownerName: "CuaDriver", bundleIdentifier: "com.trycua.driver.helper", savedExclusions: [], expectedExcluded: false),
            Case(name: "bundle prefix near match", ownerName: "CuaDriver", bundleIdentifier: "other.com.trycua.driver", savedExclusions: [], expectedExcluded: false),
            Case(name: "bundle case near match", ownerName: "CuaDriver", bundleIdentifier: "com.trycua.Driver", savedExclusions: [], expectedExcluded: false),
        ]

        var failures = 0
        for test in cases {
            let excluded = AltTabManager.isWindowOwnerExcluded(
                ownerName: test.ownerName,
                bundleIdentifier: test.bundleIdentifier,
                excludedAppNames: test.savedExclusions
            )
            if excluded != test.expectedExcluded {
                print("FAIL: \(test.name): expected excluded=\(test.expectedExcluded), got \(excluded)")
                failures += 1
            } else {
                print("PASS: \(test.name)")
            }
        }
        print("\(cases.count - failures)/\(cases.count) policy cases passed")
        if failures > 0 { exit(1) }
    }
}
