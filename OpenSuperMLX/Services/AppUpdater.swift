// AppUpdater.swift
// OpenSuperMLX

import AppKit
import Combine
import CoreGraphics
import Foundation

import Sparkle

// MARK: - UpdateDeferral

@MainActor
final class UpdateDeferral {
    enum Action: CaseIterable {
        case showUpdate
        case relaunch
    }

    // The settle window covers the paste and clipboard restore that follow a save.
    static let settleInterval: TimeInterval = 2
    static let inputQuietInterval: TimeInterval = 5

    private var isBusy = false
    private var idleSince = Date.distantPast
    private var pending: [Action: @MainActor () -> Void] = [:]

    var hasPending: Bool { !pending.isEmpty }

    func setBusy(_ busy: Bool, now: Date) {
        if isBusy, !busy {
            idleSince = now
        }
        isBusy = busy
    }

    func isReady(_ action: Action, now: Date, secondsSinceInput: TimeInterval) -> Bool {
        guard !isBusy, now.timeIntervalSince(idleSince) >= Self.settleInterval else { return false }
        return action != .showUpdate || secondsSinceInput >= Self.inputQuietInterval
    }

    @discardableResult
    func deferUnlessReady(
        _ action: Action, now: Date, secondsSinceInput: TimeInterval, _ run: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !isReady(action, now: now, secondsSinceInput: secondsSinceInput) else {
            pending[action] = nil
            return false
        }
        pending[action] = run
        return true
    }

    func runReady(now: Date, secondsSinceInput: TimeInterval) {
        for action in Action.allCases where isReady(action, now: now, secondsSinceInput: secondsSinceInput) {
            pending.removeValue(forKey: action)?()
        }
    }

    func cancel(_ action: Action) {
        pending[action] = nil
    }
}

// MARK: - AppUpdater

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    nonisolated static let isEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return getenv("XCTestConfigurationFilePath") == nil
        #endif
    }()

    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
    )

    private let deferral = UpdateDeferral()
    private let now: () -> Date
    private let secondsSinceUserInput: () -> TimeInterval
    private let presentUpdate: @MainActor () -> Void
    private let quit: @MainActor () -> Void
    private var busyObserver: AnyCancellable?
    private var pollTimer: Timer?
    private var isRelaunchingForUpdate = false

    init(
        now: @escaping () -> Date = Date.init,
        secondsSinceUserInput: @escaping () -> TimeInterval = AppUpdater.secondsSinceLastUserInput,
        presentUpdate: @escaping @MainActor () -> Void = { AppUpdater.shared.controller.checkForUpdates(nil) },
        quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.now = now
        self.secondsSinceUserInput = secondsSinceUserInput
        self.presentUpdate = presentUpdate
        self.quit = quit
        super.init()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func start(busy: AnyPublisher<Bool, Never>) {
        observeBusy(busy)
        controller.startUpdater()
    }

    func observeBusy(_ busy: AnyPublisher<Bool, Never>) {
        busyObserver = busy.sink { [weak self] isBusy in
            guard let self else { return }
            deferral.setBusy(isBusy, now: now())
        }
    }

    // MARK: - Deferral

    func handleScheduledUpdate() {
        if !deferUnlessReady(.showUpdate, presentUpdate) {
            presentUpdate()
        }
    }

    func cancelScheduledUpdate() {
        deferral.cancel(.showUpdate)
    }

    func handleRelaunchRequest(_ installHandler: @escaping () -> Void) -> Bool {
        let postponed = deferUnlessReady(.relaunch) { [weak self] in
            self?.isRelaunchingForUpdate = true
            installHandler()
        }
        if !postponed {
            isRelaunchingForUpdate = true
        }
        return postponed
    }

    // Sparkle quits the app after the relaunch is released; a recording may have started in between.
    func holdsTerminationForUpdate() -> Bool {
        guard isRelaunchingForUpdate else { return false }
        return deferUnlessReady(.relaunch, quit)
    }

    func runReadyActions() {
        deferral.runReady(now: now(), secondsSinceInput: secondsSinceUserInput())
        if !deferral.hasPending {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func deferUnlessReady(_ action: UpdateDeferral.Action, _ run: @escaping @MainActor () -> Void) -> Bool {
        let deferred = deferral.deferUnlessReady(
            action, now: now(), secondsSinceInput: secondsSinceUserInput(), run
        )
        if deferred, pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runReadyActions() }
            }
            timer.tolerance = 0.5
            pollTimer = timer
        }
        return deferred
    }

    nonisolated static func secondsSinceLastUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// MARK: - SPUUpdaterDelegate

extension AppUpdater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        handleRelaunchRequest(installHandler)
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    // A menu-bar app is usually inactive, where Sparkle would open the alert behind other windows.
    // Presenting through checkForUpdates brings it to the front once the app is idle and the user pauses.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        handleScheduledUpdate()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        cancelScheduledUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        cancelScheduledUpdate()
    }
}
