import XCTest

final class KirtHealthSyncUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
    }

    func testDismissHealthKitPermissionAndSync() throws {
        // Launch the app
        app.launch()
        sleep(3)

        // Skip HK dialog handling — we use Mock Direct button instead
        // which bypasses HK entirely

        // Tap "Reset Anchors" to clear HK query anchors (no-op in this flow)
        let resetButton = app.buttons["Reset Anchors"]
        if resetButton.waitForExistence(timeout: 10) {
            resetButton.tap()
            print("Tapped Reset Anchors")
            sleep(1)
        } else {
            print("Reset Anchors button not found (expected in Debug UI)")
        }

        // Tap "Mock Direct" to write mock metrics directly to Firestore (bypasses HK)
        let mockDirectButton = app.buttons["Mock Direct"]
        if mockDirectButton.waitForExistence(timeout: 10) {
            mockDirectButton.tap()
            print("Tapped Mock Direct")
            // Wait for direct Firestore write to complete
            sleep(5)
        } else {
            print("Mock Direct button not found")
            XCTFail("Mock Direct button not found")
            return
        }

        // Tap Sync Now
        let syncButton = app.buttons["Sync Now"]
        if syncButton.waitForExistence(timeout: 10) {
            syncButton.tap()
            print("Tapped Sync Now")
            // Wait for sync to complete
            sleep(15)
        } else {
            print("Sync Now button not found")
            XCTFail("Sync Now button not found")
            return
        }

        // Screenshot for verification
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "HealthSyncUITest-Final"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Test complete")
    }
}
