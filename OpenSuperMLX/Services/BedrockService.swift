// BedrockService.swift
// OpenSuperMLX

import Foundation
import os.log

import AWSBedrockRuntime
import AWSSDKIdentity

private let logger = Logger(subsystem: "OpenSuperMLX", category: "BedrockService")

final class BedrockService {
    static let shared = BedrockService()

    static let defaultCorrectionPrompt = """
        You are a Speech-to-Text (STT) transcription corrector.

        Correct the input text following these rules strictly.


        【Fix】
        - Misrecognized words and homophones (including kanji/kana conversion errors for Japanese)
        - Missing or incorrect punctuation
        - Obvious transcription errors, misspellings, and wrong words
        - Unnatural word splits or merges caused by STT
        - Particle errors in Japanese (は/わ, を/お, へ/え, etc.)
        - Filler words (um, uh, you know, えー, あのー, まあ, なんか, etc.)
        - Stutters and repetitions (e.g., "the the", "あの、あの")
        - Self-corrections: keep only the speaker's final intended version (e.g., "Monday, no wait, Tuesday" → "Tuesday" / "Aじゃなくて、B」→「B」)


        【Do NOT】
        - Change the speaker's tone, style, word choice, or sentence structure
        - Summarize, omit, or add information beyond what was spoken
        - Rewrite expressions that are already understandable
        - Include any explanations, annotations, or comments in the output


        【Output】
        Output ONLY the corrected text. Nothing else.
        """

    private init() {}

    // MARK: - Error Types

    private enum BedrockError: Error {
        case timeout
        case emptyResponse
    }

    // MARK: - Public API

    func correctTranscription(_ text: String) async -> String {
        let prefs = AppPreferences.shared

        guard prefs.bedrockEnabled else {
            return text
        }

        if prefs.bedrockAuthMode == "accessKey" {
            guard !prefs.bedrockAccessKey.isEmpty, !prefs.bedrockSecretKey.isEmpty else {
                return text
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("No speech detected") else {
            return text
        }

        guard !prefs.bedrockRegion.isEmpty, !prefs.bedrockModelId.isEmpty else {
            return text
        }

        do {
            let config = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
                region: prefs.bedrockRegion
            )

            switch prefs.bedrockAuthMode {
            case "profile":
                config.awsCredentialIdentityResolver = ProfileAWSCredentialIdentityResolver(
                    profileName: prefs.bedrockProfileName
                )
            case "accessKey":
                let credentials = AWSCredentialIdentity(
                    accessKey: prefs.bedrockAccessKey,
                    secret: prefs.bedrockSecretKey
                )
                config.awsCredentialIdentityResolver = StaticAWSCredentialIdentityResolver(credentials)
            default:
                break
            }

            let client = BedrockRuntimeClient(config: config)

            let message = BedrockRuntimeClientTypes.Message(
                content: [.text(text)],
                role: .user
            )

            let inferenceConfig = BedrockRuntimeClientTypes.InferenceConfiguration(
                maxTokens: 4096,
                temperature: 0.1
            )

            let input = ConverseInput(
                inferenceConfig: inferenceConfig,
                messages: [message],
                modelId: prefs.bedrockModelId,
                system: [.text(prefs.bedrockCorrectionPrompt)]
            )

            let response = try await withThrowingTaskGroup(of: ConverseOutput.self) { group in
                group.addTask {
                    try await client.converse(input: input)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw BedrockError.timeout
                }
                guard let result = try await group.next() else {
                    throw BedrockError.emptyResponse
                }
                group.cancelAll()
                return result
            }

            guard case let .message(msg) = response.output,
                  let content = msg.content,
                  let first = content.first,
                  case let .text(correctedText) = first else {
                throw BedrockError.emptyResponse
            }

            let trimmedResult = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedResult.isEmpty else {
                throw BedrockError.emptyResponse
            }

            logger.info("Bedrock correction applied successfully")
            return trimmedResult

        } catch {
            logger.error("Bedrock correction failed: \(error.localizedDescription)")
            NotificationCenter.default.post(
                name: .bedrockCorrectionFailed,
                object: nil,
                userInfo: ["error": error]
            )
            return text
        }
    }
}
