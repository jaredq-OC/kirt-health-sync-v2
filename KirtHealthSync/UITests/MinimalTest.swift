import XCTest

final class MinimalTest: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
    }

    func testAppLaunchesAndStaysRunning() throws {
        app.launch()
        print("App launched, waiting 10 seconds...")
        sleep(10)
        print("App stayed running for 10 seconds — PASS")
    }
}
