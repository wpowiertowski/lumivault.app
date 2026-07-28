import XCTest

// MARK: - LumiVault UI Tests (Local Environment)
//
// These tests use XCUIAutomation and are designed for local development only (not CI).
// They verify core navigation flows, settings UI, and import/deletion workflows.
//
// Run with:
//   xcodebuild test -project LumiVault.xcodeproj -scheme LumiVaultUITests -destination 'platform=macOS'
//
// Or use Xcode 26's XCUIAutomation recording (Product > Record UI Test) to capture additional flows.

@MainActor
final class LumiVaultUITests: XCTestCase {
    let app = XCUIApplication()

    /// Throwaway library for this test's app launch.
    private var libraryURL: URL!

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

        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        if let libraryURL { try? FileManager.default.removeItem(at: libraryURL) }
    }
}

// MARK: - TC-1: Welcome Screen

extension LumiVaultUITests {

    /// TC-1.1: Fresh launch shows welcome view with restore options.
    ///
    /// Asserts unconditionally. This used to `XCTSkipUnless` the welcome view was
    /// present, on the grounds that the app might already have albums — which was
    /// true when every run shared the developer's real store, and meant the test
    /// silently did nothing on any machine that had ever imported a photo. Each
    /// launch now gets a fresh in-memory store, so "no albums" is guaranteed and a
    /// missing welcome view is a real failure.
    func testWelcomeScreenRestoreButtons() throws {
        let restoreFile = app.buttons["welcome.restoreFile"]
        XCTAssertTrue(restoreFile.waitForExistence(timeout: 10),
                      "Welcome view should be shown on a store with no albums")
        XCTAssertTrue(app.buttons["welcome.restoreVolume"].exists,
                      "From Volume button should be visible")
        XCTAssertTrue(app.buttons["welcome.restoreB2"].exists,
                      "From B2 button should be visible")
    }
}

// MARK: - TC-21: Navigation & UI

extension LumiVaultUITests {

    /// TC-21.1: Sidebar is present in the navigation split view.
    func testSidebarExists() {
        let sidebar = app.otherElements["nav.sidebar"]
        // NavigationSplitView sidebar may take a moment to render
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Sidebar should exist")
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

    /// TC-22.1-22.8: All 8 settings tabs are accessible and can be selected.
    func testSettingsTabsExist() {
        // Open Settings via menu bar
        app.menuItems["Settings…"].click()

        let settingsWindow = app.windows["Settings"]
        guard settingsWindow.waitForExistence(timeout: 5) else {
            // Try alternate: Cmd+, shortcut
            app.typeKey(",", modifierFlags: .command)
            guard app.windows.count > 1 else {
                XCTFail("Settings window should open")
                return
            }
            return
        }

        let tabIds = [
            "settings.tab.general",
            "settings.tab.import",
            "settings.tab.volumes",
            "settings.tab.icloud",
            "settings.tab.b2",
            "settings.tab.encryption",
            "settings.tab.integrity",
            "settings.tab.support",
        ]

        for tabId in tabIds {
            // Tab items may appear as buttons, radio buttons, or tab elements
            let tab = settingsWindow.descendants(matching: .any)[tabId]
            XCTAssertTrue(tab.waitForExistence(timeout: 3),
                          "Settings tab '\(tabId)' should exist")
        }
    }

    /// TC-22.5: B2 tab shows credential fields when B2 is enabled.
    func testB2CredentialFields() {
        // Open Settings
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows.element(boundBy: app.windows.count > 1 ? 1 : 0)
        guard settingsWindow.waitForExistence(timeout: 5) else {
            XCTFail("Settings window should open")
            return
        }

        // Navigate to B2 tab
        let b2Tab = settingsWindow.descendants(matching: .any)["settings.tab.b2"]
        if b2Tab.waitForExistence(timeout: 3) {
            b2Tab.click()
        }

        // Check toggle exists
        let enableToggle = settingsWindow.descendants(matching: .any)["b2.enable"]
        XCTAssertTrue(enableToggle.waitForExistence(timeout: 3),
                      "B2 enable toggle should exist")
    }

    /// TC-22.6: Encryption tab shows passphrase field.
    func testEncryptionTabFields() {
        // Open Settings
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows.element(boundBy: app.windows.count > 1 ? 1 : 0)
        guard settingsWindow.waitForExistence(timeout: 5) else {
            XCTFail("Settings window should open")
            return
        }

        // Navigate to Encryption tab
        let encTab = settingsWindow.descendants(matching: .any)["settings.tab.encryption"]
        if encTab.waitForExistence(timeout: 3) {
            encTab.click()
        }

        // Check for passphrase field or create key button (depends on whether key exists)
        let passphrase = settingsWindow.descendants(matching: .any)["encryption.passphrase"]
        let unlockPassphrase = settingsWindow.descendants(matching: .any)["encryption.unlockPassphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 3) || unlockPassphrase.exists,
                      "A passphrase field should exist on the Encryption tab")
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
// store per launch it could *only* ever skip. Covering it properly needs a way
// to seed an album into the UI-test store, which does not exist yet — a real
// gap, recorded in TEST-PLAN rather than papered over with a test that runs zero
// assertions. The model-level deletion semantics are covered by
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

// MARK: - TC-22: Import Defaults Persistence

extension LumiVaultUITests {

    /// TC-22.2: Import defaults tab shows PAR2 and near-dupe toggles.
    func testImportDefaultsToggles() {
        // Open Settings
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows.element(boundBy: app.windows.count > 1 ? 1 : 0)
        guard settingsWindow.waitForExistence(timeout: 5) else {
            XCTFail("Settings window should open")
            return
        }

        // Navigate to Import Defaults tab
        let importTab = settingsWindow.descendants(matching: .any)["settings.tab.import"]
        if importTab.waitForExistence(timeout: 3) {
            importTab.click()
        }

        let par2Toggle = settingsWindow.descendants(matching: .any)["importDefaults.par2"]
        let nearDupeToggle = settingsWindow.descendants(matching: .any)["importDefaults.nearDupe"]

        XCTAssertTrue(par2Toggle.waitForExistence(timeout: 3),
                      "PAR2 toggle should exist on Import Defaults tab")
        XCTAssertTrue(nearDupeToggle.exists,
                      "Near-duplicate toggle should exist on Import Defaults tab")
    }
}
