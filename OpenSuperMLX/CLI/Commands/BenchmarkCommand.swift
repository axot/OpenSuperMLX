// BenchmarkCommand.swift
// OpenSuperMLX

import AVFoundation
import Darwin
import Foundation

import ArgumentParser

// MARK: - Result Types

struct BenchmarkResult: Encodable {
    let file: String
    let language: String
    let accuracy: AccuracyResult?
    let performance: PerformanceResult
    let memory: MemoryResult
    let pass: Bool

    struct AccuracyResult: Encodable {
        let metric: String
        let score: Double
        let substitutions: Int
        let insertions: Int
        let deletions: Int
    }

    struct PerformanceResult: Encodable {
        let audioDurationS: Double
        let processingTimeS: Double
        let rtf: Double
        let speedFactor: Double
        let runs: Int
        let rtfStddev: Double

        enum CodingKeys: String, CodingKey {
            case audioDurationS = "audio_duration_s"
            case processingTimeS = "processing_time_s"
            case rtf
            case speedFactor = "speed_factor"
            case runs
            case rtfStddev = "rtf_stddev"
        }
    }

    struct MemoryResult: Encodable {
        let peakTotalMB: UInt64
        let baselineMB: UInt64
        let inferenceDeltaMB: UInt64

        enum CodingKeys: String, CodingKey {
            case peakTotalMB = "peak_total_mb"
            case baselineMB = "baseline_mb"
            case inferenceDeltaMB = "inference_delta_mb"
        }
    }
}

// MARK: - Command

struct BenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Run transcription benchmarks with accuracy, speed, and memory metrics"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument(help: "Path to audio file")
    var file: String

    @Option(name: .long, help: "Language code (default: auto)")
    var language: String = "auto"

    @Option(name: .long, help: "Model repository ID")
    var model: String?

    @Option(name: .long, help: "Number of timed runs (default: 3)")
    var runs: Int = 3

    @Option(name: .long, help: "WER threshold for pass/fail")
    var werThreshold: Double?

    @Option(name: .long, help: "Reference text for accuracy comparison")
    var referenceText: String?

    @Flag(name: .long, help: "Run the full benchmark suite")
    var suite = false

    // MARK: - Execution

    func run() async throws {
        let result = await executeBenchmark()

        switch result {
        case .success(let data):
            CLIOutput.printSuccess(command: "benchmark", data: data, json: globalOptions.json)
        case .failure(let error):
            CLIOutput.printError(command: "benchmark", error: error, json: globalOptions.json)
            throw ExitCode(1)
        }
    }

    @MainActor
    func executeBenchmark() async -> Result<BenchmarkResult, CLIError> {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.audioFileNotFound)
        }

        if let model = model {
            AppPreferences.shared.selectedMLXModel = model
        }

        let service = TranscriptionService.shared
        let settings = Settings(
            selectedLanguage: language,
            useStreamingTranscription: false
        )

        CLIOutput.printProgress("Loading model...", quiet: globalOptions.quiet)

        var waitCount = 0
        while service.isLoading && waitCount < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitCount += 1
        }

        if service.loadError != nil {
            return .failure(.modelLoadFailed)
        }

        let audioDuration = await loadAudioDuration(url: url)

        let baselineMemory = Self.getPhysFootprint()

        CLIOutput.printProgress("Warm-up run...", quiet: globalOptions.quiet)
        let warmUpText: String
        do {
            warmUpText = try await service.transcribeAudio(
                url: url,
                settings: settings,
                applyCorrection: false
            )
        } catch {
            return .failure(.transcriptionFailed)
        }

        CLIOutput.printProgress("Running \(runs) timed run(s)...", quiet: globalOptions.quiet)
        var times: [Double] = []
        var lastText = warmUpText
        var peakMemory = Self.getPhysFootprint()

        for i in 0 ..< runs {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                lastText = try await service.transcribeAudio(
                    url: url,
                    settings: settings,
                    applyCorrection: false
                )
            } catch {
                return .failure(.transcriptionFailed)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            times.append(elapsed)

            let currentMemory = Self.getPhysFootprint()
            peakMemory = max(peakMemory, currentMemory)

            CLIOutput.printProgress("  Run \(i + 1): \(String(format: "%.2f", elapsed))s", quiet: globalOptions.quiet)
        }

        let meanTime = times.reduce(0, +) / Double(times.count)
        let rtf = audioDuration > 0 ? meanTime / audioDuration : 0.0
        let speedFactor = rtf > 0 ? 1.0 / rtf : 0.0
        let rtfStddev = Self.stddev(times, audioDuration: audioDuration)

        var accuracyResult: BenchmarkResult.AccuracyResult?
        var pass = true

        if let reference = referenceText {
            let isCJK = WERCalculator.isCJKDominant(reference)
            let detailed = isCJK
                ? WERCalculator.computeCERDetailed(reference: reference, hypothesis: lastText)
                : WERCalculator.computeWERDetailed(reference: reference, hypothesis: lastText)

            accuracyResult = BenchmarkResult.AccuracyResult(
                metric: detailed.metric,
                score: detailed.score,
                substitutions: detailed.substitutions,
                insertions: detailed.insertions,
                deletions: detailed.deletions
            )

            if let threshold = werThreshold {
                pass = detailed.score <= threshold
            }
        }

        let peakTotalMB = peakMemory / (1024 * 1024)
        let baselineMB = baselineMemory / (1024 * 1024)
        let deltaMB = peakTotalMB > baselineMB ? peakTotalMB - baselineMB : 0

        let benchmarkResult = BenchmarkResult(
            file: url.lastPathComponent,
            language: language,
            accuracy: accuracyResult,
            performance: BenchmarkResult.PerformanceResult(
                audioDurationS: audioDuration,
                processingTimeS: meanTime,
                rtf: rtf,
                speedFactor: speedFactor,
                runs: runs,
                rtfStddev: rtfStddev
            ),
            memory: BenchmarkResult.MemoryResult(
                peakTotalMB: peakTotalMB,
                baselineMB: baselineMB,
                inferenceDeltaMB: deltaMB
            ),
            pass: pass
        )

        return .success(benchmarkResult)
    }

    // MARK: - Helpers

    private func loadAudioDuration(url: URL) async -> Double {
        await (try? Task.detached(priority: .utility) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        }.value) ?? 0.0
    }

    static func getPhysFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    static func stddev(_ times: [Double], audioDuration: Double) -> Double {
        guard times.count > 1, audioDuration > 0 else { return 0.0 }
        let rtfs = times.map { $0 / audioDuration }
        let mean = rtfs.reduce(0, +) / Double(rtfs.count)
        let variance = rtfs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rtfs.count)
        return variance.squareRoot()
    }
}
