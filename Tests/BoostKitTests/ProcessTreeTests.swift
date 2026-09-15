import Testing
import Darwin
@testable import BoostKit

/// Grouping an app with every process it spawned is what makes the list
/// readable — Discord is one row and ~1 GB, not seven mystery rows. It is also
/// what makes Pause safe: freezing a parent without its children leaves the
/// children running against a stopped parent.
@Suite("Process tree")
struct ProcessTreeTests {

    /// 1 ─ 2 ─ 4
    ///   └ 3 ─ 5 ─ 6
    private let tree: [pid_t: [pid_t]] = [
        1: [2, 3],
        2: [4],
        3: [5],
        5: [6],
    ]

    @Test("Collects every descendant, not just direct children")
    func collectsWholeSubtree() {
        let found = Set(SystemScan.descendants(of: 1, children: tree))
        #expect(found == [2, 3, 4, 5, 6])
    }

    @Test("Collects from a node partway down")
    func collectsFromMidTree() {
        #expect(Set(SystemScan.descendants(of: 3, children: tree)) == [5, 6])
    }

    @Test("A leaf has no descendants")
    func leafHasNone() {
        #expect(SystemScan.descendants(of: 6, children: tree).isEmpty)
    }

    @Test("A pid absent from the table has no descendants")
    func unknownPidHasNone() {
        #expect(SystemScan.descendants(of: 999, children: tree).isEmpty)
    }

    @Test("Never returns the root itself — callers prepend it")
    func excludesRoot() {
        #expect(!SystemScan.descendants(of: 1, children: tree).contains(1))
    }

    /// Regression: this looped forever and grew its result without bound, so an
    /// app for reclaiming memory would have exhausted it. pid reuse can make a
    /// parent chain appear cyclic — see `descendants`.
    @Test("A cycle terminates instead of spinning forever", .timeLimit(.minutes(1)))
    func cycleTerminates() {
        let cyclic: [pid_t: [pid_t]] = [1: [2], 2: [3], 3: [1]]
        let found = SystemScan.descendants(of: 1, children: cyclic)
        #expect(Set(found) == [2, 3])      // the root is not its own descendant
    }

    @Test("Each process is reported once, even reached by two paths",
          .timeLimit(.minutes(1)))
    func noDuplicates() {
        // 4 is a child of both 2 and 3. Counting it twice would double its RAM
        // in the row total.
        let diamond: [pid_t: [pid_t]] = [1: [2, 3], 2: [4], 3: [4]]
        let found = SystemScan.descendants(of: 1, children: diamond)
        #expect(found.count == Set(found).count)
        #expect(Set(found) == [2, 3, 4])
    }
}

@Suite("Widget names")
struct WidgetNameTests {

    @Test("Turns an extension's bundle name into something readable", arguments: [
        ("CalendarWidgetExtension", "Calendar Widget"),
        ("WeatherWidget", "Weather Widget"),
        ("com.apple.NotesWidgetExtension", "Notes Widget"),
    ])
    func prettifies(raw: String, expected: String) {
        #expect(SystemScan.prettifyWidget(raw) == expected)
    }

    @Test("Leaves a plain name alone")
    func leavesPlainNames() {
        #expect(SystemScan.prettifyWidget("Clock") == "Clock")
    }

    @Test("Finds the containing app, for the icon")
    func findsContainingApp() {
        #expect(SystemScan.containingApp(of: "/Applications/Foo.app/Contents/PlugIns/Bar.appex")
                == "/Applications/Foo.app")
    }

    @Test("Returns nothing when there is no containing app")
    func noContainingApp() {
        #expect(SystemScan.containingApp(of: "/usr/libexec/something") == nil)
    }
}
