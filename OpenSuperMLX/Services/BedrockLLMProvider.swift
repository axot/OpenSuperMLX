// BedrockLLMProvider.swift
// OpenSuperMLX

import Foundation
import os.log

import AWSBedrockRuntime
import AWSSDKIdentity
import ClientRuntime
@_spi(SmithyDocumentImpl) import Smithy

private let logger = Logger(subsystem: "OpenSuperMLX", category: "BedrockLLMProvider")

final class BedrockLLMProvider: LLMProvider, @unchecked Sendable {

    static let providerName = "AWS Bedrock"

    private let variantCache: LLMThinkingVariantCache
    // One client per provider instance, so a chunked correction resolves credentials and connects once.
    private var client: BedrockRuntimeClient?

    let displayName = BedrockLLMProvider.providerName

    init(variantCache: LLMThinkingVariantCache = .shared) {
        self.variantCache = variantCache
    }

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

    var requestOptions: LLMRequestOptions {
        AppPreferences.shared.llmRequestOptions(for: .bedrock)
    }

    // MARK: - LLMProvider

    func correctTranscription(_ text: String, systemPrompt: String) async throws -> String {
        let prefs = AppPreferences.shared
        let client = try await makeClientIfNeeded()
        let options = requestOptions
        let variants: [LLMThinkingVariant] = options.thinkingEnabled ? [.primary, .legacyBudget, .omitted] : [.omitted]
        let cacheKey = "\(prefs.bedrockRegion)|\(prefs.bedrockModelId)|\(options.thinkingEnabled)"

        let response = try await variantCache.firstAccepted(key: cacheKey, variants: variants) { variant in
            do {
                return try await client.converse(input: makeConverseInput(
                    modelId: prefs.bedrockModelId,
                    systemPrompt: systemPrompt,
                    text: text,
                    options: options,
                    thinking: variant
                ))
            } catch {
                let mapped = Self.mapError(error)
                if mapped.rejectsThinkingParameters {
                    logger.warning("Bedrock rejected thinking parameters")
                }
                throw mapped
            }
        }

        let result = try Self.extractText(from: response)
        if prefs.debugMode {
            logger.debug("Bedrock response: outputLength=\(result.count, privacy: .public), inputLength=\(text.count, privacy: .public)")
        }
        return result
    }

    func makeConverseInput(
        modelId: String,
        systemPrompt: String,
        text: String,
        options: LLMRequestOptions,
        thinking: LLMThinkingVariant = .primary
    ) -> ConverseInput {
        let message = BedrockRuntimeClientTypes.Message(
            content: [.text(text)],
            role: .user
        )

        let outputLimit = options.outputTokenLimit(systemPrompt: systemPrompt, text: text)
        let inferenceConfig = BedrockRuntimeClientTypes.InferenceConfiguration(
            maxTokens: outputLimit
        )

        var additionalFields: Document?
        let fields = options.thinkingEnabled
            ? LLMThinkingVariant.anthropicFields(options: options, variant: thinking, outputLimit: outputLimit)
            : [:]
        if !fields.isEmpty {
            additionalFields = Document(Self.smithyDocument(fields))
        }

        return ConverseInput(
            additionalModelRequestFields: additionalFields,
            inferenceConfig: inferenceConfig,
            messages: [message],
            modelId: modelId,
            system: [.text(systemPrompt)]
        )
    }

    static func extractText(from response: ConverseOutput) throws -> String {
        switch response.stopReason {
        case .maxTokens, .modelContextWindowExceeded:
            throw LLMProviderError.outputTruncated(provider: providerName)
        case .contentFiltered, .guardrailIntervened:
            throw LLMProviderError.outputRejected(provider: providerName, reason: "content_filtered")
        default:
            break
        }

        guard case let .message(msg) = response.output else {
            throw LLMProviderError.emptyResponse
        }
        let text = (msg.content ?? []).compactMap { block -> String? in
            if case let .text(value) = block { return value }
            return nil
        }.joined()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return trimmed
    }

    static func mapError(_ error: Error) -> LLMProviderError {
        switch error {
        case let error as LLMProviderError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as AccessDeniedException:
            return .authenticationFailed(provider: providerName, detail: error.properties.message ?? "")
        case let error as ResourceNotFoundException:
            return .httpError(statusCode: 404, message: error.properties.message ?? "")
        case is ThrottlingException:
            return .rateLimited(provider: providerName, retryAfter: nil)
        case let error as ValidationException:
            return .fromHTTP(statusCode: 400, message: error.properties.message ?? "", provider: providerName)
        case let error as ModelTimeoutException:
            return .httpError(statusCode: 408, message: error.properties.message ?? "")
        case let error as ServiceUnavailableException:
            return .httpError(statusCode: 503, message: error.properties.message ?? "")
        case let error as ModelNotReadyException:
            return .httpError(statusCode: 503, message: error.properties.message ?? "")
        case let error as InternalServerException:
            return .httpError(statusCode: 500, message: error.properties.message ?? "")
        case let error as URLError where error.code == .cancelled:
            return .cancelled
        default:
            return .networkError(underlying: error)
        }
    }

    // MARK: - Private

    private func makeClientIfNeeded() async throws -> BedrockRuntimeClient {
        if let client { return client }
        let prefs = AppPreferences.shared

        // Long non-streaming corrections exceed the SDK's 60s socket default; LLMCorrectionService
        // enforces the real time limit.
        let config = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            region: prefs.bedrockRegion,
            httpClientConfiguration: HttpClientConfiguration(connectTimeout: 900, socketTimeout: 900)
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

        let newClient = BedrockRuntimeClient(config: config)
        client = newClient
        return newClient
    }

    private static func smithyDocument(_ value: Any) -> SmithyDocument {
        switch value {
        case let dictionary as [String: Any]:
            return StringMapDocument(value: dictionary.mapValues { smithyDocument($0) })
        case let bool as Bool:
            return BooleanDocument(value: bool)
        case let integer as Int:
            return IntegerDocument(value: integer)
        default:
            return StringDocument(value: "\(value)")
        }
    }
}
