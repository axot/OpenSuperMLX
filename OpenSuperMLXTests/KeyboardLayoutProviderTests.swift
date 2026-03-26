// KeyboardLayoutProviderTests.swift
// OpenSuperMLX

import XCTest
import Carbon
@testable import OpenSuperMLX

final class KeyboardLayoutProviderTests: XCTestCase {
    
    private let provider = KeyboardLayoutProvider.shared
    private var originalInputSourceID: String?
    
    override func setUpWithError() throws {
        originalInputSourceID = ClipboardUtil.getCurrentInputSourceID()
    }
    
    override func tearDownWithError() throws {
        if let originalID = originalInputSourceID {
            _ = ClipboardUtil.switchToInputSource(withID: originalID)
        }
    }
    
    // MARK: - Physical Type Detection
    
    func testDetectPhysicalType_returnsValue() {
        let physicalType = provider.detectPhysicalType()
        print("Detected physical keyboard type: \(physicalType)")
        XCTAssertTrue([.ansi, .iso, .jis].contains(physicalType))
    }
    
    // MARK: - Label Resolution
    
    func testResolveLabels_returnsLabelsForCurrentLayout() {
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels, "Should resolve labels for current layout")
        if let labels = labels {
            XCTAssertEqual(labels.count, KeyboardLayoutProvider.ansiKeycodes.count,
                           "Should have a label for every ANSI keycode")
        }
    }
    
    func testResolveLabels_USLayout_hasExpectedKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "A", "Keycode 0 should be A in US layout")
        XCTAssertEqual(labels[1], "S", "Keycode 1 should be S in US layout")
        XCTAssertEqual(labels[13], "W", "Keycode 13 should be W in US layout")
        XCTAssertEqual(labels[50], "`", "Keycode 50 should be ` in US layout")
    }
    
    func testResolveLabels_RussianLayout_hasCyrillicKeys() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let labels = provider.resolveLabels()
        XCTAssertNotNil(labels)
        guard let labels = labels else { return }
        
        XCTAssertEqual(labels[0], "Ф", "Keycode 0 should be Ф in Russian layout")
        XCTAssertEqual(labels[1], "Ы", "Keycode 1 should be Ы in Russian layout")
    }
    
    // MARK: - resolveInfo (full validation)
    
    func testResolveInfo_USLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "US")
        if !switched { throw XCTSkip("US layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "US layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_RussianLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "Russian")
        if !switched { throw XCTSkip("Russian layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "Russian layout on ANSI keyboard should produce info (Cyrillic labels)")
        }
    }
    
    func testResolveInfo_GermanLayout_returnsInfo() throws {
        let switched = ClipboardUtil.switchToInputSource(withID: "German")
        if !switched { throw XCTSkip("German layout not available") }
        
        let info = provider.resolveInfo()
        if provider.detectPhysicalType() == .ansi {
            XCTAssertNotNil(info, "German layout on ANSI keyboard should produce info")
        }
    }
    
    func testResolveInfo_nonANSI_returnsNil() throws {
        let physicalType = provider.detectPhysicalType()
        if physicalType != .ansi {
            let info = provider.resolveInfo()
            XCTAssertNil(info, "Non-ANSI physical keyboard should return nil from resolveInfo")
        } else {
            throw XCTSkip("This machine has ANSI keyboard, cannot test non-ANSI rejection")
        }
    }
    
    // MARK: - All Available Layouts
    
    func testResolveLabels_allAvailableLayouts() {
        let layouts = ClipboardUtil.getAvailableInputSources()
        var results: [(layout: String, labelCount: Int, success: Bool)] = []
        
        for layout in layouts {
            let switched = ClipboardUtil.switchToInputSource(withID: layout)
            guard switched else {
                results.append((layout, 0, false))
                continue
            }
            
            let labels = provider.resolveLabels()
            let count = labels?.count ?? 0
            let ok = count == KeyboardLayoutProvider.ansiKeycodes.count
            results.append((layout, count, ok))
        }
        
        print("\n=== Keyboard Layout Provider Results ===")
        for r in results {
            let status = r.success ? "OK" : "SKIP"
            print("[\(status)] \(r.layout): \(r.labelCount) labels")
        }
        print("=========================================\n")
    }
}
