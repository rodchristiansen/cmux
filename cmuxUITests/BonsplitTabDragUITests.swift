import XCTest
import Foundation

final class BonsplitTabDragUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHiddenWorkspaceTitlebarKeepsTabReorderWorking() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for Bonsplit tab drag UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected tab-drag setup data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 12.0) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let alphaTab = app.buttons[alphaTitle]
        let betaTab = app.buttons[betaTitle]

        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")
        XCTAssertLessThan(alphaTab.frame.minX, betaTab.frame.minX, "Expected beta tab to start to the right of alpha")

        let start = betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = alphaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: destination)

        XCTAssertTrue(
            waitForCondition(timeout: 5.0) { betaTab.frame.minX < alphaTab.frame.minX },
            "Expected dragging beta onto alpha to reorder tabs. alpha=\(alphaTab.frame) beta=\(betaTab.frame)"
        )
    }

    func testHiddenWorkspaceTitlebarPlacesPaneTabBarAtTopEdge() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for hidden titlebar top-gap UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected tab-drag setup data at \(dataPath)")

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")

        let alphaTab = app.buttons["UITest Alpha"]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")

        let gapIfOriginIsBottomLeft = abs(window.frame.maxY - alphaTab.frame.maxY)
        let gapIfOriginIsTopLeft = abs(alphaTab.frame.minY - window.frame.minY)
        let topGap = min(gapIfOriginIsBottomLeft, gapIfOriginIsTopLeft)
        XCTAssertLessThanOrEqual(
            topGap,
            8,
            "Expected the selected pane tab to reach the top edge when the workspace titlebar is hidden. window=\(window.frame) alphaTab=\(alphaTab.frame) gap.bottomLeft=\(gapIfOriginIsBottomLeft) gap.topLeft=\(gapIfOriginIsTopLeft)"
        )
    }

    func testPaneTabBarControlsRevealWhenHoveringAnywhereOnPaneTabBar() {
        let (app, dataPath) = launchConfiguredApp()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for Bonsplit controls hover UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: 12.0), "Expected tab-drag setup data at \(dataPath)")

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")
        let alphaTab = app.buttons["UITest Alpha"]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5.0), "Expected alpha tab to exist")
        let betaTab = app.buttons["UITest Beta"]
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")

        let newTerminalButton = app.buttons["paneTabBarControl.newTerminal"]
        XCTAssertTrue(newTerminalButton.waitForExistence(timeout: 5.0), "Expected new terminal control to exist")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { !newTerminalButton.isHittable },
            "Expected pane tab bar controls to hide away from the pane tab bar. button=\(newTerminalButton.debugDescription)"
        )

        hover(
            in: window,
            at: CGPoint(
                x: min(window.frame.maxX - 140, betaTab.frame.maxX + 80),
                y: alphaTab.frame.midY
            )
        )
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { newTerminalButton.isHittable },
            "Expected pane tab bar controls to reveal when hovering inside empty pane-tab-bar space. window=\(window.frame) alphaTab=\(alphaTab.frame) betaTab=\(betaTab.frame) button=\(newTerminalButton.debugDescription)"
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        XCTAssertTrue(
            waitForCondition(timeout: 2.0) { !newTerminalButton.isHittable },
            "Expected pane tab bar controls to hide again after leaving the pane tab bar. button=\(newTerminalButton.debugDescription)"
        )
    }

    private func launchConfiguredApp() -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-bonsplit-tab-drag-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchArguments += ["-workspaceTitlebarVisible", "NO"]
        app.launchArguments += ["-paneTabBarControlsVisibilityMode", "onHover"]
        app.launch()
        app.activate()
        return (app, dataPath)
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForAnyJSON(atPath path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadJSON(atPath: path) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path) != nil
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path), data[key] == expected {
            return data
        }
        return nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func hover(in window: XCUIElement, at point: CGPoint) {
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(
            CGVector(
                dx: point.x - window.frame.minX,
                dy: point.y - window.frame.minY
            )
        ).hover()
    }
}
