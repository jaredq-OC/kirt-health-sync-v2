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
        sleep(2)

        // Tap "Allow" on HealthKit authorization dialog
        let allowButton = XCUIApplication().buttons["Allow"]
        if allowButton.waitForExistence(timeout: 5) {
            allowButton.tap()
            print("Tapped Allow on HealthKit dialog")
        } else {
            let alert = XCUIApplication().alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let allow = alert.buttons["Allow"]
                if allow.exists {
                    allow.tap()
                } else {
                    alert.buttons.firstMatch.tap()
                }
                print("Tapped dialog button")
            } else {
                print("No dialog — may already be authorized")
            }
        }

        // Wait for mock data to be written (async in app)
        sleep(5)

        // Tap Sync Now
        let syncButton = XCUIApplication().buttons["Sync Now"]
        if syncButton.waitForExistence(timeout: 10) {
            let coord = syncButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            coord.tap()
            print("Tapped Sync Now")
            // Wait for HealthKit queries + Firestore write to complete
            sleep(15)
        } else {
            print("Sync Now button not found")
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
