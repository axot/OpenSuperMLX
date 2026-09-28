// CoreMLAudioTowerAssetsTests.swift
// OpenSuperMLXTests

import XCTest
@testable import OpenSuperMLX

final class CoreMLAudioTowerAssetsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLAudioTowerAssetsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Resolve

    func testDownloadURLPointsAtThePinnedRepository() {
        XCTAssertEqual(
            CoreMLAudioTowerAssets.downloadURL(for: "model.mil").absoluteString,
            "https://huggingface.co/ax0t/Qwen3-ASR-1.7B-CoreML-INT8/resolve/main/qwen3_asr_audio_tower_int8.mlmodelc/model.mil"
        )
    }

    func testResolveUsesAnInstalledModelWithoutDownloading() async throws {
        let model = directory.appendingPathComponent(CoreMLAudioTowerAssets.modelName)
        try writeModelFiles(into: model)

        let resolved = try await CoreMLAudioTowerAssets.resolve(in: directory) { _, _, _ in
            XCTFail("An installed model must not be downloaded again")
        }

        XCTAssertEqual(resolved.standardizedFileURL, model.standardizedFileURL)
    }

    func testResolveInstallsEveryModelFile() async throws {
        let resolved = try await CoreMLAudioTowerAssets.resolve(in: directory) { _, destination, _ in
            try Data("x".utf8).write(to: destination)
        }

        XCTAssertTrue(CoreMLAudioTowerAssets.isInstalled(at: resolved))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [CoreMLAudioTowerAssets.modelName])
    }

    func testResolvePassesTheProgressHandlerToEveryDownload() async throws {
        _ = try await CoreMLAudioTowerAssets.resolve(in: directory, progressHandler: { _ in }) { remote, destination, progressHandler in
            XCTAssertNotNil(progressHandler, remote.lastPathComponent)
            try Data("x".utf8).write(to: destination)
        }
    }

    func testFailedDownloadLeavesNoPartialModel() async throws {
        do {
            _ = try await CoreMLAudioTowerAssets.resolve(in: directory) { remote, destination, _ in
                if remote.lastPathComponent == "weight.bin" { throw URLError(.networkConnectionLost) }
                try Data("x".utf8).write(to: destination)
            }
            XCTFail("Expected the download to fail")
        } catch {}

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // MARK: - Download

    @MainActor
    func testDownloadReportsItsByteProgress() async throws {
        let destination = directory.appendingPathComponent("weight.bin")
        let log = ProgressLog()

        try await CoreMLAudioTowerAssets.download(from: StubURLProtocol.url(for: "weight.bin"), to: destination) { progress in
            log.completedUnits.append(progress.completedUnitCount)
        }

        XCTAssertEqual(try Data(contentsOf: destination), StubURLProtocol.body)
        XCTAssertEqual(log.completedUnits.last, Int64(StubURLProtocol.body.count))
    }

    func testDownloadRejectsAnErrorResponse() async throws {
        let destination = directory.appendingPathComponent("missing")
        do {
            try await CoreMLAudioTowerAssets.download(
                from: StubURLProtocol.url(for: "missing"), to: destination, progressHandler: nil
            )
            XCTFail("Expected a 404 response to fail")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    private func writeModelFiles(into model: URL) throws {
        for file in CoreMLAudioTowerAssets.modelFiles {
            let url = model.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }
}

@MainActor
private final class ProgressLog {
    var completedUnits: [Int64] = []
}

/// Serves `body` for any path on its host, or a 404 for the path `missing`.
private final class StubURLProtocol: URLProtocol {
    static let host = "coreml-assets.test"
    static let body = Data((0..<300_000).map { UInt8($0 % 251) })

    static func url(for path: String) -> URL {
        URL(string: "https://\(host)/\(path)")!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let found = request.url?.lastPathComponent != "missing"
        let payload = found ? Self.body : Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: found ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(payload.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
