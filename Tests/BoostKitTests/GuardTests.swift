import Testing
@testable import BoostKit

/// The guard list is the one piece of this app that absolutely must not
/// regress: everything on it takes the desktop down with it when signalled.
@Suite("Protected processes")
struct GuardTests {

    @Test("Killing any of these takes the desktop with it", arguments: [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
    ])
    func criticalBundleIDsAreProtected(id: String) {
        #expect(Guard.isProtected(id: id, name: "irrelevant"))
    }

    @Test("Matched by executable name too, for things with no bundle id", arguments: [
        "WindowServer", "launchd", "kernel_task", "loginwindow", "Dock", "Finder",
    ])
    func criticalExecutablesAreProtected(name: String) {
        #expect(Guard.isProtected(id: "/usr/libexec/\(name)", name: name))
    }

    @Test("Boost cannot close or pause itself")
    func boostProtectsItself() {
        #expect(Guard.isProtected(id: "boost.local.app", name: "Boost"))
        #expect(Guard.isProtected(id: "/Applications/Boost.app", name: "Boost"))
    }

    @Test("Ordinary apps are not protected", arguments: [
        ("com.spotify.client", "Spotify"),
        ("com.hnc.Discord", "Discord"),
        ("com.microsoft.VSCode", "Code"),
        ("com.apple.Safari", "Safari"),
    ])
    func ordinaryAppsAreNotProtected(id: String, name: String) {
        #expect(!Guard.isProtected(id: id, name: name))
    }

    @Test("Apple's own software is recognised by path, not by name")
    func systemPathDetection() {
        #expect(Guard.isSystemPath("/System/Applications/Music.app"))
        #expect(Guard.isSystemPath("/usr/libexec/something"))
        #expect(Guard.isSystemPath("/Library/Apple/System/Foo"))
        #expect(!Guard.isSystemPath("/Applications/Spotify.app"))
        #expect(!Guard.isSystemPath("/Users/me/Applications/Thing.app"))
    }

    /// A name that merely contains a protected one must not be caught by it,
    /// or a user app called "Dockyard" becomes unclosable.
    @Test("Protection matches whole names, not substrings")
    func noSubstringFalsePositives() {
        #expect(!Guard.isProtected(id: "com.example.dockyard", name: "Dockyard"))
        #expect(!Guard.isProtected(id: "com.example.finderhelper", name: "FinderHelper"))
    }
}
