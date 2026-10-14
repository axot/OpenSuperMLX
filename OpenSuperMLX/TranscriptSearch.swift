// TranscriptSearch.swift
// OpenSuperMLX

import Foundation

struct TranscriptSearch {
    struct Input: Equatable {
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.utf16.elementsEqual(rhs.text.utf16)
        }
    }

    private(set) var ranges: [NSRange] = []
    private(set) var selectedIndex = 0
    private var query = ""

    var selectedRange: NSRange? {
        ranges.indices.contains(selectedIndex) ? ranges[selectedIndex] : nil
    }

    mutating func update(text: String, query: String, resetSelection: Bool = false) {
        if !query.utf16.elementsEqual(self.query.utf16) || resetSelection {
            selectedIndex = 0
        }
        self.query = query
        if query.isEmpty {
            ranges = []
        } else {
            let expression = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: query),
                options: .caseInsensitive
            )
            ranges = expression?.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ).map(\.range) ?? []
        }
        selectedIndex = min(selectedIndex, max(0, ranges.count - 1))
    }

    mutating func move(by offset: Int) {
        guard !ranges.isEmpty else { return }
        selectedIndex = (selectedIndex + offset % ranges.count + ranges.count) % ranges.count
    }
}
