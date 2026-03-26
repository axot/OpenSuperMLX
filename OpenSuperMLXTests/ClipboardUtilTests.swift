// ClipboardUtilTests.swift
// OpenSuperMLX

import Carbon
import XCTest

@testable import OpenSuperMLX

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
