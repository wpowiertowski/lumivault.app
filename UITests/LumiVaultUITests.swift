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

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
    }
}

// MARK: - TC-1: Welcome Screen

extension LumiVaultUITests {

    /// TC-1.1: Fresh launch shows welcome view with restore options.
    /// Note: This test is meaningful only when the app has no prior data.
    /// If albums already exist, the welcome view is hidden — the test will skip gracefully.
    func testWelcomeScreenRestoreButtons() throws {
        let restoreFile = app.buttons["welcome.restoreFile"]
        let restoreVolume = app.buttons["welcome.restoreVolume"]

        // If welcome view is not shown (albums exist), skip
        try XCTSkipUnless(restoreFile.waitForExistence(timeout: 3),
                          "Welcome view not shown — app already has albums")

        XCTAssertTrue(restoreFile.exists, "From File button should be visible")
        XCTAssertTrue(restoreVolume.exists, "From Volume button should be visible")
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

extension LumiVaultUITests {

    /// TC-16.1: Album context menu has Delete option.
    /// Note: Requires at least one album to exist. Skips if sidebar is empty.
    func testAlbumContextMenuDeleteExists() throws {
        let sidebar = app.otherElements["nav.sidebar"]
        guard sidebar.waitForExistence(timeout: 5) else {
            throw XCTSkip("Sidebar not found")
        }

        // Look for any album row in the sidebar
        let albumRows = app.outlines.descendants(matching: .outlineRow)
        try XCTSkipUnless(albumRows.count > 0, "No albums in sidebar — cannot test context menu")

        // Right-click first album row to open context menu
        let firstAlbum = albumRows.element(boundBy: 0)
        firstAlbum.rightClick()

        // Look for Delete Album menu item
        let deleteItem = app.menuItems["Delete Album"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3),
                      "Delete Album should appear in context menu")

        // Dismiss context menu without deleting
        app.typeKey(.escape, modifierFlags: [])
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
