// BedrockLLMProvider.swift
// OpenSuperMLX

import Foundation
import os.log

import AWSBedrockRuntime
import AWSSDKIdentity

private let logger = Logger(subsystem: "OpenSuperMLX", category: "BedrockLLMProvider")

final class BedrockLLMProvider: LLMProvider, @unchecked Sendable {

    let displayName = "AWS Bedrock"

    var isConfigured: Bool {
        let prefs = AppPreferences.shared
        guard !prefs.bedrockRegion.isEmpty, !prefs.bedrockModelId.isEmpty else {
            return false
        }
        if prefs.bedrockAuthMode == "accessKey" {
            return !prefs.bedrockAccessKey.isEmpty && !prefs.bedrockSecretKey.isEmpty
        }
        return true
    }

    // MARK: - LLMProvider

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let prefs = AppPreferences.shared

        let config = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            region: prefs.bedrockRegion
        )

        if prefs.debugMode {
            logger.debug("Bedrock request: region=\(prefs.bedrockRegion, privacy: .public), modelId=\(prefs.bedrockModelId, privacy: .public), authMode=\(prefs.bedrockAuthMode, privacy: .public)")
        }

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
            system: [.text(systemPrompt)]
        )

        let response: ConverseOutput
        do {
            response = try await client.converse(input: input)
        } catch {
            throw LLMProviderError.networkError(underlying: error)
        }

        guard case let .message(msg) = response.output,
              let content = msg.content,
              let first = content.first,
              case let .text(correctedText) = first else {
            throw LLMProviderError.emptyResponse
        }

        let trimmedResult = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else {
            throw LLMProviderError.emptyResponse
        }

        logger.info("Bedrock correction applied successfully")
        if prefs.debugMode {
            logger.debug("Bedrock response: outputLength=\(trimmedResult.count, privacy: .public), inputLength=\(text.count, privacy: .public)")
        }

        return trimmedResult
    }
}
