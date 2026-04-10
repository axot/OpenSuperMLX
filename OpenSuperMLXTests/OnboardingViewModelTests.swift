//
//  OnboardingViewModelTests.swift
//  OpenSuperMLX
//

import XCTest
@testable import OpenSuperMLX

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    // MARK: - downloadProgress

    func testDownloadProgressStartsNil() {
        let vm = OnboardingViewModel()
        XCTAssertNil(vm.downloadProgress)
    }

    func testDownloadProgressResetsOnCancel() {
        let vm = OnboardingViewModel()
        vm.downloadProgress = 0.5
        vm.cancelDownload()
        XCTAssertNil(vm.downloadProgress)
    }

    func testDownloadProgressResetsWhenNotDownloading() {
        let vm = OnboardingViewModel()
        vm.downloadProgress = 0.75
        vm.cancelDownload()
        XCTAssertFalse(vm.isDownloading)
        XCTAssertNil(vm.downloadProgress)
    }
}
