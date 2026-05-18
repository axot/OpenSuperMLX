// ClipboardUtilTests.swift
// OpenSuperMLX

import AppKit
import Carbon
import XCTest

@testable import OpenSuperMLX

// MARK: - Pasteboard Restoration Tests

/// Regression: previously the restore was synchronous after 100 ms `Thread.sleep` and
/// unconditionally overwrote concurrent pasteboard writes. The fix restores async after
/// 400 ms only when `pasteboard.changeCount` hasn't advanced since our write.
final class ClipboardUtilRestorationTests: XCTestCase {

    private var savedSnapshot: [(NSPasteboard.PasteboardType, Data)] = []

    override func setUp() {
        super.setUp()
        // Snapshot the real pasteboard so the test doesn't trash the user's clipboard.
        let pb = NSPasteboard.general
        savedSnapshot = (pb.types ?? []).compactMap { type in
            pb.data(forType: type).map { (type, $0) }
        }
    }

    override func tearDown() {
        // Best-effort restore of the snapshot taken in setUp.
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in savedSnapshot {
            pb.setData(data, forType: type)
        }
        savedSnapshot = []
        super.tearDown()
    }

    /// Schedules a background write to the pasteboard so it lands AFTER `insertText` returns
    /// but BEFORE the async restore fires. Used to simulate "user copied something else
    /// during the restore window."
    private func scheduleExternalPasteboardWrite(after delay: TimeInterval, value: String) -> XCTestExpectation {
        let scheduled = expectation(description: "external write scheduled")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            scheduled.fulfill()
        }
        return scheduled
    }

    /// Regression: an external write to the pasteboard that lands AFTER `insertText` returns
    /// but BEFORE the async restore must not be clobbered. With the old synchronous
    /// 100 ms sleep + unconditional restore, the external write was overwritten by the saved
    /// contents and the user lost their data.
    func testInsertText_DoesNotClobberExternalPasteboardWriteAfterReturn() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("ORIGINAL_CLIPBOARD", forType: .string)

        let externalWriteScheduled = scheduleExternalPasteboardWrite(
            after: ClipboardUtil.pasteboardRestoreDelay / 2, value: "EXTERNAL_WRITE"
        )

        ClipboardUtil.insertText("TRANSCRIBED_TEXT")

        wait(for: [externalWriteScheduled], timeout: 1.0)
        Thread.sleep(forTimeInterval: ClipboardUtil.pasteboardRestoreDelay + 0.1)

        XCTAssertEqual(pb.string(forType: .string), "EXTERNAL_WRITE")
    }

    func testInsertText_RestoresWhenNoExternalWriteHappens() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("PRESERVE_ME", forType: .string)

        ClipboardUtil.insertText("TRANSCRIBED_TEXT")

        Thread.sleep(forTimeInterval: ClipboardUtil.pasteboardRestoreDelay + 0.2)

        XCTAssertEqual(pb.string(forType: .string), "PRESERVE_ME")
    }
}

// MARK: - Keyboard Layout Tests

final class ClipboardUtilKeyboardLayoutTests: XCTestCase {
    
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    func testGetAvailableInputSources() throws {
        let sources = ClipboardUtil.getAvailableInputSources()
        XCTAssertFalse(sources.isEmpty, "Should have at least one input source")
    }
    
    func testGetCurrentInputSourceID() throws {
        let currentID = ClipboardUtil.getCurrentInputSourceID()
        XCTAssertNotNil(currentID, "Should be able to get current input source ID")
    }
    
    func testFindKeycodeForV_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in US layout")
        XCTAssertEqual(keycode, 9, "Keycode for 'v' in US QWERTY should be 9")
    }
    
    func testFindKeycodeForV_DvorakQwertyLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak-QWERTY layout")
    }
    
    func testFindKeycodeForV_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Left-Handed layout")
    }
    
    func testFindKeycodeForV_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNotNil(keycode, "Should find keycode for 'v' in Dvorak Right-Handed layout")
    }
    
    func testFindKeycodeForV_RussianLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched {
            throw XCTSkip("Russian layout not available")
        }
        
        let keycode = ClipboardUtil.findKeycodeForCharacter("v")
        XCTAssertNil(keycode, "Should NOT find keycode for 'v' in Russian layout (no Latin 'v')")
    }
    
    func testIsQwertyCommandLayout_USLayout() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched {
            throw XCTSkip("US layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "US layout should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakQwerty() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "DVORAK-QWERTYCMD")
        if !switched {
            throw XCTSkip("Dvorak-QWERTY layout not available")
        }
        
        XCTAssertTrue(ClipboardUtil.isQwertyCommandLayout(), "Dvorak-QWERTY should be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakLeftHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Left")
        if !switched {
            throw XCTSkip("Dvorak Left-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Left-Handed should NOT be detected as QWERTY command layout")
    }
    
    func testIsQwertyCommandLayout_DvorakRightHand() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Dvorak-Right")
        if !switched {
            throw XCTSkip("Dvorak Right-Handed layout not available")
        }
        
        XCTAssertFalse(ClipboardUtil.isQwertyCommandLayout(), "Dvorak Right-Handed should NOT be detected as QWERTY command layout")
    }
}
