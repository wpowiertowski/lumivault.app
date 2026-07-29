import XCTest

// MARK: - LumiVault UI Tests
//
// XCUIAutomation tests covering navigation, settings and the import sheet. They run
// on CI (`ui-test` job) and locally:
//
//   xcodebuild test -project LumiVault.xcodeproj -scheme LumiVault \
//     -destination 'platform=macOS' -only-testing:LumiVaultUITests
//
// Local runs need Automation + Accessibility permission for Xcode in
// System Settings > Privacy & Security, or every launch fails with
// "Timed out while enabling automation mode".

/// Thrown when a test cannot reach the UI it needs. Carries the accessibility
/// hierarchy, because "element not found" without the tree is a guessing game — the
/// whole reason five of these tests sat red for a week.
private struct UIStateNotReached: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class LumiVaultUITests: XCTestCase {
    let app = XCUIApplication()

    /// Throwaway library for this test's app launch.
    private var libraryURL: URL!

    /// Defaults every launch is pinned to.
    ///
    /// `@AppStorage` reads `UserDefaults.standard`, and `NSArgumentDomain` outranks the
    /// app domain, so `-key value` at launch fixes the value for that process without
    /// writing anything into the developer's real defaults.
    ///
    /// This is the `UserDefaults` half of the isolation the library override started,
    /// and it is not optional. `hasSeenWelcome` decides which of two entirely different
    /// welcome screens renders: `false` on a fresh CI runner (the first-launch view,
    /// which has no restore buttons at all), `true` on any machine that has ever clicked
    /// Get Started. That single unisolated default is why
    /// `testWelcomeScreenRestoreButtons` passed on a developer machine and failed on CI.
    /// `b2Enabled` has the same shape in reverse — a developer with B2 configured sees an
    /// extra welcome button and a different import sheet.
    private static let pinnedDefaults = [
        "-hasSeenWelcome", "YES",
        "-b2Enabled", "NO",
        "-encryptionEnabled", "NO",
        "-iCloudSyncEnabled", "NO",
    ]

    override func setUp() async throws {
        continueAfterFailure = false

        // Launch into an isolated library. Without this the app opens the real
        // ~/Pictures/LumiVault and the real Application Support store, which makes
        // every assertion depend on whatever the developer happens to have
        // archived — the actual reason these tests were considered flaky — and
        // lets a UI-driven import write junk into a real photo archive.
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        app.launchEnvironment["LUMIVAULT_UITEST_LIBRARY"] = libraryURL.path
        app.launchArguments = Self.pinnedDefaults

        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        if let libraryURL { try? FileManager.default.removeItem(at: libraryURL) }
    }
}

// MARK: - Helpers

extension LumiVaultUITests {

    /// Wait for an element, failing with the accessibility hierarchy attached.
    ///
    /// `XCTAssertTrue(x.waitForExistence(...))` tells you an element was missing but not
    /// what was there instead, which on a headless CI runner is the only question worth
    /// answering.
    func assertExists(
        _ element: XCUIElement,
        _ message: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(message)\n\nAccessibility hierarchy:\n\(app.debugDescription)",
                file: file, line: line)
    }

    /// Relaunch with one pinned default overridden. The argument domain is fixed at
    /// process start, so changing a default means a new process.
    func relaunch(setting key: String, to value: String) {
        var arguments = Self.pinnedDefaults
        if let index = arguments.firstIndex(of: "-\(key)") {
            arguments[index + 1] = value
        } else {
            arguments += ["-\(key)", value]
        }
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    /// Open Settings and return its window, identified *by exclusion*: it is the window
    /// that does not carry the main window's toolbar.
    ///
    /// Neither title nor index works here. `app.windows["Settings"]` never matches —
    /// SwiftUI's `Settings` scene is not titled "Settings" on macOS 26 — and four tests
    /// used to skip their assertions on that failed lookup, one of them silently passing
    /// while checking nothing. `element(boundBy: 1)` is no better: the CI log shows the
    /// freshly-opened settings window sorting *ahead* of the main window, so index 1 was
    /// the main window and every tab lookup searched the wrong tree.
    func openSettingsWindow(timeout: TimeInterval = 10) throws -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for window in app.windows.allElementsBoundByIndex
            where !window.buttons["toolbar.importPhotos"].exists {
                return window
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline

        throw UIStateNotReached(description: """
            Settings did not open within \(timeout)s (no window without the main toolbar).

            Accessibility hierarchy:
            \(app.debugDescription)
            """)
    }

    /// The control for a settings tab, located by its visible title.
    ///
    /// Not by identifier: the `settings.tab.*` identifiers in `SettingsView` are attached
    /// to each tab's *content* view, not to the tab control, so clicking one clicks the
    /// content area and cannot change the selection.
    ///
    /// `Button`, established by running the query chain on CI once and reading which type
    /// matched — the tabs are neither `RadioButton` nor `Tab`, which is what the shape of
    /// a `TabView` would suggest.
    func settingsTab(_ title: String, in window: XCUIElement) -> XCUIElement {
        window.buttons[title]
    }

    func selectSettingsTab(_ title: String, in window: XCUIElement) throws {
        // The window is reported before its toolbar is populated; give the first lookup
        // a chance rather than racing it.
        _ = window.buttons.firstMatch.waitForExistence(timeout: 3)

        let tab = settingsTab(title, in: window)
        guard tab.exists else {
            throw UIStateNotReached(description: """
                No settings tab control titled "\(title)".

                Accessibility hierarchy:
                \(window.debugDescription)
                """)
        }
        tab.click()
    }
}

// MARK: - TC-1: Welcome Screen

extension LumiVaultUITests {

    /// TC-1.1: A returning user with no albums gets the restore options.
    ///
    /// Asserts unconditionally. This used to `XCTSkipUnless` the welcome view was
    /// present, on the grounds that the app might already have albums — which was
    /// true when every run shared the developer's real store, and meant the test
    /// silently did nothing on any machine that had ever imported a photo. Each
    /// launch now gets a fresh in-memory store *and* a pinned `hasSeenWelcome`, so
    /// this screen is guaranteed and a missing button is a real failure.
    func testWelcomeScreenRestoreButtons() throws {
        assertExists(app.buttons["welcome.restoreFile"],
                     "Welcome view should be shown on a store with no albums",
                     timeout: 10)
        XCTAssertTrue(app.buttons["welcome.restoreVolume"].exists,
                      "From Volume button should be visible")
        // Not `welcome.restoreB2`: that button is inside `if b2Enabled`, which the
        // pinned defaults hold off.
        XCTAssertFalse(app.buttons["welcome.restoreB2"].exists,
                       "B2 restore should be hidden while b2Enabled is off")
    }

    /// TC-1.2: A genuinely first-time user gets the explainer, not the restore options.
    ///
    /// This is the branch CI was actually in for the whole time
    /// `testWelcomeScreenRestoreButtons` was red: `hasSeenWelcome` defaults to false, so
    /// a fresh profile renders `FirstLaunchView`, which has no restore buttons. It was
    /// never covered, so nothing said which of the two screens was supposed to be there.
    func testFirstLaunchShowsTheExplainer() throws {
        relaunch(setting: "hasSeenWelcome", to: "NO")

        assertExists(app.buttons["welcome.getStarted"],
                     "A first-time profile should see the first-launch explainer",
                     timeout: 10)
        XCTAssertFalse(app.buttons["welcome.restoreFile"].exists,
                       "restore options belong to the returning-user screen, not first launch")
    }
}

// MARK: - TC-21: Navigation & UI

extension LumiVaultUITests {

    /// TC-21.1: The sidebar renders its empty state on a store with no albums.
    ///
    /// Asserts on what the sidebar *draws*, not on a container element. The previous
    /// version looked for `otherElements["nav.sidebar"]`, an identifier applied to
    /// `SidebarView` from `ContentView`; with an empty store that view is a bare
    /// `VStack`, SwiftUI builds no accessibility element for it, and the identifier
    /// attached to nothing. The identifier has been removed rather than left implying
    /// a query seam that does not exist.
    func testSidebarShowsEmptyState() {
        assertExists(app.staticTexts["No albums yet"],
                     "The sidebar should show its empty state on a store with no albums")
    }

    /// TC-21.2: Toolbar import button is accessible.
    func testToolbarImportButton() {
        let importButton = app.buttons["toolbar.importPhotos"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5),
                      "Import from Photos toolbar button should exist")
    }

    /// TC-21.3: Toolbar near-duplicates button is accessible.
    func testToolbarNearDuplicatesButton() {
        let nearDupesButton = app.buttons["toolbar.nearDuplicates"]
        XCTAssertTrue(nearDupesButton.waitForExistence(timeout: 5),
                      "Near-Duplicates toolbar button should exist")
    }

    /// TC-21.5: Window exists and app is responsive.
    func testWindowExists() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window should exist")
    }
}

// MARK: - TC-22: Settings Tabs

extension LumiVaultUITests {

    /// Visible titles of the eight tabs in `SettingsView`, in declaration order.
    private static let settingsTabTitles = [
        "General", "Import Defaults", "Volumes", "iCloud",
        "B2", "Encryption", "Integrity", "Support",
    ]

    /// TC-22.1-22.8: All 8 settings tabs are present.
    ///
    /// This test used to pass while asserting nothing: it waited five seconds for
    /// `app.windows["Settings"]`, never found it, and returned from the `guard` after a
    /// window count check. All eight assertions were skipped on every run.
    func testSettingsTabsExist() throws {
        let settings = try openSettingsWindow()
        _ = settings.buttons.firstMatch.waitForExistence(timeout: 3)

        for title in Self.settingsTabTitles {
            XCTAssertTrue(
                settingsTab(title, in: settings).exists,
                """
                Settings tab "\(title)" should exist.

                Accessibility hierarchy:
                \(settings.debugDescription)
                """
            )
        }
    }

    /// TC-22.5: B2 tab shows the enable toggle.
    func testB2CredentialFields() throws {
        let settings = try openSettingsWindow()
        try selectSettingsTab("B2", in: settings)

        assertExists(settings.descendants(matching: .any)["b2.enable"],
                     "B2 enable toggle should exist")
    }

    /// TC-22.6: Encryption tab shows whichever key control matches the current state.
    ///
    /// Exactly one of three controls is shown, and which one depends on the keychain:
    /// no stored key gives the passphrase field, a stored-but-locked key gives the
    /// unlock field, a loaded key gives only Lock Key. The keychain is *not* isolated
    /// for UI tests — it is scoped to the app identifier, so a UI test shares the
    /// developer's real one. (Separating it is the dev-bundle-id work recorded in
    /// SANDBOX-PLAN.md.) Asserting "one of the three" is the strongest claim that holds
    /// on both a fresh runner and a machine with encryption configured.
    func testEncryptionTabFields() throws {
        let settings = try openSettingsWindow()
        try selectSettingsTab("Encryption", in: settings)

        let anySettings = settings.descendants(matching: .any)
        let setUpKey = anySettings["encryption.passphrase"]
        _ = setUpKey.waitForExistence(timeout: 3)

        let controls = [
            setUpKey.exists,
            anySettings["encryption.unlockPassphrase"].exists,
            settings.buttons["Lock Key"].exists,
        ]
        XCTAssertEqual(
            controls.filter { $0 }.count, 1,
            """
            The Encryption tab should show exactly one key control \
            (set-up passphrase, unlock passphrase, or Lock Key).

            Accessibility hierarchy:
            \(settings.debugDescription)
            """
        )
    }

    /// TC-22.2: Import defaults tab shows PAR2 and near-dupe toggles.
    func testImportDefaultsToggles() throws {
        let settings = try openSettingsWindow()
        try selectSettingsTab("Import Defaults", in: settings)

        let anySettings = settings.descendants(matching: .any)
        assertExists(anySettings["importDefaults.par2"],
                     "PAR2 toggle should exist on Import Defaults tab")
        XCTAssertTrue(anySettings["importDefaults.nearDupe"].exists,
                      "Near-duplicate toggle should exist on Import Defaults tab")
    }
}

// MARK: - TC-2: Photos Import Flow

extension LumiVaultUITests {

    /// TC-2.1: Import from Photos button opens the import sheet.
    func testPhotosImportOpensSheet() {
        let importButton = app.buttons["toolbar.importPhotos"]
        guard importButton.waitForExistence(timeout: 5) else {
            XCTFail("Import button should exist")
            return
        }

        importButton.click()

        // The import sheet should appear with the cancel button
        let cancelButton = app.buttons["import.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5),
                      "Export sheet should open with cancel button visible")

        // Dismiss
        cancelButton.click()
    }

    /// TC-4.1-4.2: Cancel button is accessible during import flow.
    func testImportCancelButtonExists() {
        let importButton = app.buttons["toolbar.importPhotos"]
        guard importButton.waitForExistence(timeout: 5) else {
            XCTFail("Import button should exist")
            return
        }

        importButton.click()

        let cancelButton = app.buttons["import.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5),
                      "Cancel button should be visible in import sheet")

        // Next button should be disabled (no album selected)
        let nextButton = app.buttons["import.next"]
        if nextButton.waitForExistence(timeout: 3) {
            XCTAssertFalse(nextButton.isEnabled,
                           "Next button should be disabled when no album is selected")
        }

        cancelButton.click()
    }
}

// MARK: - TC-16, TC-17: Deletion
//
// The album context-menu test that used to live here was removed rather than
// carried forward. It skipped unless the sidebar already had an album, which was
// only ever true because runs shared the developer's real store; with a fresh
// store per launch it could *only* ever skip. Covering it properly needs an album
// seeded into the UI-test store — now feasible, since `SyncCoordinator.setup`
// hydrates SwiftData from `catalog.json` under the overridden library, so a test can
// write a catalog into its temp dir and launch into a populated app. Recorded in
// TEST-PLAN rather than papered over with a test that runs zero assertions. The
// model-level deletion semantics are covered by
// `PipelineOrchestrationTests.deletingOneAlbumKeepsAnImageThatStillBelongsToAnother`.

// MARK: - TC-37: Open Settings from inside a modal sheet (regression: cbf5f3a)

extension LumiVaultUITests {

    /// `NSApp.sendAction(Selector(("showSettingsWindow:")), …)` silently did
    /// nothing when invoked from inside a modal sheet — no responder handled it,
    /// so the button looked functional and simply never opened Settings. The fix
    /// switched to `@Environment(\.openSettings)` and dismisses the sheet first.
    ///
    /// This is a view-body bug: it cannot be reached from a unit test, and the
    /// failure mode is "nothing happens", which no compile or runtime check sees.
    func testOpenSettingsFromImportSheetActuallyOpensSettings() throws {
        let importButton = app.buttons["toolbar.importPhotos"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Import button should exist")
        importButton.click()

        let openSettings = app.buttons["import.openSettings"]
        try XCTSkipUnless(
            openSettings.waitForExistence(timeout: 5),
            "Storage warning not shown — no volumes configured is a precondition for this button"
        )

        let windowsBefore = app.windows.count
        openSettings.click()

        // The sheet must dismiss *and* a Settings window must appear. Before the
        // fix the sheet stayed put and no window opened.
        let settingsAppeared = NSPredicate(format: "count > %d", windowsBefore)
        expectation(for: settingsAppeared, evaluatedWith: app.windows, handler: nil)
        waitForExpectations(timeout: 10)

        XCTAssertFalse(app.buttons["import.cancel"].exists,
                       "the import sheet should have been dismissed before Settings opened")
    }
}
