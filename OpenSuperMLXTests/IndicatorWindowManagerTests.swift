// IndicatorWindowManagerTests.swift
// OpenSuperMLXTests

import AppKit
import XCTest

@testable import OpenSuperMLX

@MainActor
final class IndicatorWindowManagerTests: XCTestCase {
    func testShowingIndicatorKeepsApplicationAndMainWindowHidden() async throws {
        try await withHiddenApplication { application, mainWindow, panel in
            await showAndCheckApplicationStaysHidden(panel, application: application)

            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(application.isHidden)
            XCTAssertFalse(mainWindow.isVisible)
            XCTAssertFalse(application.isActive)
        }
    }

    func testShowingIndicatorAgainKeepsMainWindowHidden() async throws {
        try await withHiddenApplication { application, mainWindow, panel in
            panel.orderFront(nil)
            panel.orderOut(nil)
            XCTAssertFalse(panel.isVisible)

            await showAndCheckApplicationStaysHidden(panel, application: application)

            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(application.isHidden)
            XCTAssertFalse(mainWindow.isVisible)
        }
    }

    func testShowingIndicatorKeepsClosedMainWindowClosed() async throws {
        try await withHiddenApplication { application, mainWindow, panel in
            mainWindow.close()

            await showAndCheckApplicationStaysHidden(panel, application: application)

            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(application.isHidden)
            XCTAssertFalse(mainWindow.isVisible)
        }
    }

    // MARK: - Helpers

    private func showAndCheckApplicationStaysHidden(
        _ panel: NSPanel,
        application: NSApplication
    ) async {
        let unhidden = expectation(
            forNotification: NSApplication.didUnhideNotification,
            object: application
        )
        unhidden.isInverted = true

        panel.orderFront(nil)
        await fulfillment(of: [unhidden], timeout: 0.1)
    }

    private func withHiddenApplication(
        _ body: (NSApplication, NSWindow, NSPanel) async -> Void
    ) async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires an active display")

        let application = NSApplication.shared
        let wasHidden = application.isHidden
        let activationPolicy = application.activationPolicy()
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        mainWindow.isReleasedWhenClosed = false
        defer {
            mainWindow.close()
            if wasHidden {
                application.hide(nil)
            } else {
                application.unhideWithoutActivation()
            }
            application.setActivationPolicy(activationPolicy)
        }

        application.setActivationPolicy(.regular)
        mainWindow.orderFrontRegardless()
        await Task.yield()
        application.hide(nil)
        for _ in 0..<100 where !application.isHidden {
            try await Task.sleep(for: .milliseconds(10))
        }
        try XCTSkipUnless(application.isHidden, "Application hiding requires a window session")
        XCTAssertFalse(mainWindow.isVisible)

        let panel = IndicatorWindowManager.makePanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        await body(application, mainWindow, panel)
    }
}
