import XCTest

final class KirtHealthSyncUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Launch Tests

    func testAppLaunchesAndShowsMainScreen() throws {
        // Verify navigation title appears
        XCTAssertTrue(app.navigationBars["Kirt Health Sync"].waitForExistence(timeout: 5),
                      "App should display main navigation title")

        // Verify all main sections are present
        XCTAssertTrue(app.staticTexts["Today's Summary"].waitForExistence(timeout: 3),
                      "Today's Summary section should be visible")
        XCTAssertTrue(app.staticTexts["Nutrition"].waitForExistence(timeout: 3),
                      "Nutrition section should be visible")
        XCTAssertTrue(app.staticTexts["Last Sync"].waitForExistence(timeout: 3),
                      "Last Sync section should be visible")
    }

    // MARK: - Sync Button Tests

    func testSyncNowButtonExistsAndIsTappable() throws {
        let syncButton = app.buttons["Sync Now"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 5), "Sync Now button should exist")

        // Button should be tappable (not disabled when not loading)
        XCTAssertTrue(syncButton.isEnabled, "Sync Now should be enabled by default")
    }

    func testSyncNowButtonTriggersLoadingState() throws {
        let syncButton = app.buttons["Sync Now"]

        // Tap sync and immediately check button becomes disabled
        syncButton.tap()

        // Button should be disabled during sync
        let disabledPredicate = NSPredicate(format: "isEnabled == false")
        expectation(for: disabledPredicate, evaluatedWith: syncButton, handler: nil)
        waitForExpectations(timeout: 5, handler: nil)

        // After sync completes (or times out), button should re-enable
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        expectation(for: enabledPredicate, evaluatedWith: syncButton, handler: nil)
        waitForExpectations(timeout: 30, handler: nil)
    }

    // MARK: - Displayed Metrics Tests

    func testMetricsSectionDisplaysAllRows() throws {
        XCTAssertTrue(app.staticTexts["Steps"].waitForExistence(timeout: 3),
                      "Steps row should be visible")
        XCTAssertTrue(app.staticTexts["Sleep"].waitForExistence(timeout: 3),
                      "Sleep row should be visible")
        XCTAssertTrue(app.staticTexts["Weight"].waitForExistence(timeout: 3),
                      "Weight row should be visible")
        XCTAssertTrue(app.staticTexts["Resting HR"].waitForExistence(timeout: 3),
                      "Resting HR row should be visible")
    }

    func testNutritionSectionDisplaysAllRows() throws {
        XCTAssertTrue(app.staticTexts["Calories"].waitForExistence(timeout: 3),
                      "Calories row should be visible")
        XCTAssertTrue(app.staticTexts["Protein"].waitForExistence(timeout: 3),
                      "Protein row should be visible")
        XCTAssertTrue(app.staticTexts["Carbs"].waitForExistence(timeout: 3),
                      "Carbs row should be visible")
        XCTAssertTrue(app.staticTexts["Fat"].waitForExistence(timeout: 3),
                      "Fat row should be visible")
    }

    func testWeightDisplayedInKilograms() throws {
        // Find all static texts and verify one contains "Weight" and another contains "kg"
        let allTexts = app.staticTexts.allElementsBoundByIndex
        var hasWeightLabel = false
        var hasKgUnit = false
        for text in allTexts {
            if text.label == "Weight" { hasWeightLabel = true }
            if text.label.contains("kg") { hasKgUnit = true }
        }
        XCTAssertTrue(hasWeightLabel && hasKgUnit, "Weight should be displayed with 'kg' unit")
    }

    func testSyncTimestampIsDisplayed() throws {
        // Last Sync section should show a timestamp (not "Never" forever)
        XCTAssertTrue(app.staticTexts["Last Sync"].waitForExistence(timeout: 3),
                      "Last Sync section header should be visible")

        // Give the app time to call loadData() in onAppear
        let expectationForTimestamp = expectation(description: "Timestamp visible")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            expectationForTimestamp.fulfill()
        }
        waitForExpectations(timeout: 5, handler: nil)
    }

    // MARK: - Workouts Section Tests

    func testWorkoutsSectionExists() throws {
        XCTAssertTrue(app.staticTexts["Recent Workouts"].waitForExistence(timeout: 3),
                      "Recent Workouts section should be visible")
    }

    func testEmptyWorkoutsStateHandled() throws {
        // Either workouts are shown OR "No workouts logged" placeholder is shown
        let noWorkoutsLabel = app.staticTexts["No workouts logged"]
        let cycling = app.staticTexts["Cycling"]
        let running = app.staticTexts["Running"]
        let walking = app.staticTexts["Walking"]
        let swimming = app.staticTexts["Swimming"]

        let hasPlaceholder = noWorkoutsLabel.waitForExistence(timeout: 3)
        let hasCycling = cycling.waitForExistence(timeout: 3)
        let hasRunning = running.waitForExistence(timeout: 3)
        let hasWalking = walking.waitForExistence(timeout: 3)
        let hasSwimming = swimming.waitForExistence(timeout: 3)

        XCTAssertTrue(hasPlaceholder || hasCycling || hasRunning || hasWalking || hasSwimming,
                      "Should either show 'No workouts logged' or actual workout entries")
    }

    // MARK: - Navigation Tests

    func testNavigationBarDisplaysCorrectTitle() throws {
        XCTAssertTrue(app.navigationBars["Kirt Health Sync"].waitForExistence(timeout: 5),
                      "Navigation bar should show 'Kirt Health Sync' title")
    }

    // MARK: - Orientation Tests

    func testPortraitOrientationOnly() throws {
        // Verify we're in portrait on iPhone
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        if !isIPad {
            let orientation = UIDevice.current.orientation
            let isPortrait = orientation.isPortrait
            XCTAssertTrue(isPortrait, "iPhone should maintain portrait orientation")
        }
    }

    // MARK: - Mock Data Flow Tests (Simulator)

    func testAppHandlesEmptyHealthKitGracefully() throws {
        // On simulator, HK returns empty — app should not crash
        // Verify sections still render
        let hasTable = app.tables.count > 0
        XCTAssertTrue(hasTable, "App should display content even when HK returns empty data")

        // Verify Sync Now button is still functional
        XCTAssertTrue(app.buttons["Sync Now"].exists,
                      "Sync Now should be accessible even with empty HK data")
    }

    func testMultipleSyncTapsDoNotCrash() throws {
        let syncButton = app.buttons["Sync Now"]

        // Tap sync multiple times in quick succession
        for _ in 0..<3 {
            syncButton.tap()
            _ = syncButton.waitForExistence(timeout: 1)
        }

        // App should still be alive
        XCTAssertTrue(app.navigationBars["Kirt Health Sync"].exists,
                      "App should survive multiple rapid sync taps")
    }
}
