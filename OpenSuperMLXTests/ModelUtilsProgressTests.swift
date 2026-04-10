// ModelUtilsProgressTests.swift
// OpenSuperMLXTests

import XCTest

import HuggingFace
import MLXAudioCore
import MLXAudioSTT

final class ModelUtilsProgressTests: XCTestCase {

    // MARK: - API Contract Tests

    func testResolveOrDownloadModelAcceptsProgressHandler() async throws {
        let repoID = Repo.ID(rawValue: "mlx-community/Qwen3-ASR-0.6B-4bit")!

        // Compile-time contract: the public overload accepts an optional progressHandler.
        // We pass a no-op handler and expect a download error (no network in tests) — the
        // important thing is that this call COMPILES.
        let progressHandler: @Sendable @MainActor (Progress) -> Void = { _ in }
        do {
            _ = try await ModelUtils.resolveOrDownloadModel(
                repoID: repoID,
                requiredExtension: "safetensors",
                progressHandler: progressHandler
            )
        } catch {
            // Expected — no real download in tests
        }
    }

    func testResolveOrDownloadModelWorksWithoutProgressHandler() async throws {
        let repoID = Repo.ID(rawValue: "mlx-community/Qwen3-ASR-0.6B-4bit")!

        // Backward compat: calling WITHOUT progressHandler must still compile.
        do {
            _ = try await ModelUtils.resolveOrDownloadModel(
                repoID: repoID,
                requiredExtension: "safetensors"
            )
        } catch {
            // Expected — no real download in tests
        }
    }

    func testFromPretrainedAcceptsProgressHandler() async throws {
        // Compile-time contract: Qwen3ASRModel.fromPretrained accepts progressHandler.
        let progressHandler: @Sendable @MainActor (Progress) -> Void = { _ in }
        do {
            _ = try await Qwen3ASRModel.fromPretrained(
                "mlx-community/Qwen3-ASR-0.6B-4bit",
                progressHandler: progressHandler
            )
        } catch {
            // Expected — no real download in tests
        }
    }

    func testFromPretrainedWorksWithoutProgressHandler() async throws {
        // Backward compat: calling fromPretrained WITHOUT progressHandler must compile.
        do {
            _ = try await Qwen3ASRModel.fromPretrained(
                "mlx-community/Qwen3-ASR-0.6B-4bit"
            )
        } catch {
            // Expected — no real download in tests
        }
    }
}
