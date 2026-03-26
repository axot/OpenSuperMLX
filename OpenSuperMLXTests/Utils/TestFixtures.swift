// TestFixtures.swift
// OpenSuperMLX

import Foundation

enum TestFixtures {
    static func audioURL(named name: String, extension ext: String = "wav") -> URL? {
        Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext)
    }
    private class BundleToken {}
}
