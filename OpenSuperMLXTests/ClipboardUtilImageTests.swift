//
//  ClipboardUtilImageTests.swift
//  OpenSuperMLXTests
//
//  Tests ClipboardUtil.copyImage against a named pasteboard so the user's
//  real clipboard is never mutated during testing.
//

import AppKit
import XCTest
@testable import OpenSuperMLX

@MainActor
final class ClipboardUtilImageTests: XCTestCase {

    private func makeImage(_ size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    func testCopyImageWritesPNGToNamedPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("OpenSuperMLXTest.copyImage"))
        pb.clearContents()

        let ok = ClipboardUtil.copyImage(makeImage(), pasteboard: pb)
        XCTAssertTrue(ok)

        let data = pb.data(forType: .png)
        XCTAssertNotNil(data)
        XCTAssertFalse(data!.isEmpty)
        // PNG magic number
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        pb.releaseGlobally()
    }

    func testCopyImageClearsPriorContents() {
        let pb = NSPasteboard(name: NSPasteboard.Name("OpenSuperMLXTest.copyImageClear"))
        pb.clearContents()
        pb.setString("stale", forType: .string)

        _ = ClipboardUtil.copyImage(makeImage(), pasteboard: pb)

        XCTAssertNil(pb.string(forType: .string), "prior string contents must be cleared")
        XCTAssertNotNil(pb.data(forType: .png))

        pb.releaseGlobally()
    }
}
