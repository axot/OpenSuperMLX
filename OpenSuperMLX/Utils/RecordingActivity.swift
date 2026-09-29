// RecordingActivity.swift
// OpenSuperMLX

import Combine
import Foundation

@MainActor
final class RecordingActivity {
    static let shared = RecordingActivity()

    @Published private(set) var isActive = false

    private struct WeakOwner {
        weak var value: AnyObject?
    }

    private var activeOwners: [ObjectIdentifier: WeakOwner] = [:]

    func report(_ owner: AnyObject, isActive active: Bool) {
        activeOwners[ObjectIdentifier(owner)] = active ? WeakOwner(value: owner) : nil
        activeOwners = activeOwners.filter { $0.value.value != nil }
        let anyActive = !activeOwners.isEmpty
        if isActive != anyActive {
            isActive = anyActive
        }
    }
}
