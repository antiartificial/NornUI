//
//  NornUIUITests.swift
//  NornUIUITests
//
//  Created by Aaron Barton on 8/7/26.
//

import XCTest

final class NornUIUITests: XCTestCase {

    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["NORN_UI_FIXTURES"] = "1"
        return app
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = fixtureApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testOperationsUsesAvailableDetailHeight() throws {
        let app = fixtureApp()
        app.launch()

        let operationsDestination = app.staticTexts["Operations"].firstMatch
        XCTAssertTrue(operationsDestination.waitForExistence(timeout: 5))
        operationsDestination.click()

        let window = app.windows.firstMatch
        let header = app.staticTexts["operations.header"]
        let metrics = app.descendants(matching: .any)["operations.metrics"]
        let showLabel = app.staticTexts["operations.show-label"]
        let timeline = app.descendants(matching: .any)["operations.timeline"]

        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        XCTAssertTrue(showLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertLessThan(header.frame.minY, window.frame.midY)
        XCTAssertGreaterThanOrEqual(header.frame.minX, timeline.frame.minX - 1)
        XCTAssertLessThan(header.frame.maxX, metrics.frame.minX)
        XCTAssertLessThanOrEqual(metrics.frame.maxX, window.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(showLabel.frame.width, 33)
        XCTAssertGreaterThan(timeline.frame.height, window.frame.height * 0.45)
        XCTAssertLessThanOrEqual(timeline.frame.maxY, window.frame.maxY + 1)

        let initialWindowFrame = window.frame
        let resizeHandle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998))
        let resizedCorner = resizeHandle.withOffset(CGVector(dx: -100, dy: -60))
        resizeHandle.press(forDuration: 0.1, thenDragTo: resizedCorner)

        XCTAssertNotEqual(window.frame, initialWindowFrame)
        XCTAssertLessThan(header.frame.minY, window.frame.midY)
        XCTAssertGreaterThanOrEqual(header.frame.minX, timeline.frame.minX - 1)
        XCTAssertLessThan(header.frame.maxX, metrics.frame.minX)
        XCTAssertLessThanOrEqual(metrics.frame.maxX, window.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(showLabel.frame.width, 33)
        XCTAssertGreaterThan(timeline.frame.height, window.frame.height * 0.45)
        XCTAssertLessThanOrEqual(timeline.frame.maxY, window.frame.maxY + 1)
    }

    @MainActor
    func testPlatformPulseNavigatesToOperationsAndHost() throws {
        let app = fixtureApp()
        app.launch()

        let operationsPulse = app.buttons["overview.pulse.active-operations"]
        XCTAssertTrue(operationsPulse.waitForExistence(timeout: 5))
        operationsPulse.click()
        XCTAssertTrue(app.staticTexts["operations.header"].waitForExistence(timeout: 5))

        app.staticTexts["Overview"].firstMatch.click()
        let hostPulse = app.buttons["overview.pulse.control-plane-checks"]
        XCTAssertTrue(hostPulse.waitForExistence(timeout: 5))
        hostPulse.click()
        XCTAssertTrue(app.descendants(matching: .any)["host.header"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            fixtureApp().launch()
        }
    }
}
