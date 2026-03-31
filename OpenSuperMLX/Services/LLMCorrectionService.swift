// LLMCorrectionService.swift
// OpenSuperMLX

import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "OpenSuperMLX", category: "LLMCorrectionService")

@MainActor
final class LLMCorrectionService {

    static let shared = LLMCorrectionService(providerFactory: { resolveProvider() })

    static let defaultCorrectionPrompt = """
        You are a transcription corrector applying intelligible verbatim style.
        Your task is to recover the speaker's intended message from raw speech-to-text output.

        Speech is produced in real time — the speaker had a clear thought but the act of \
        speaking introduced noise. Remove the noise. Preserve every word of the intended message.

        REMOVE these categories of speech noise:

        1. FILLERS: um, uh, er, hmm, well, えー, あのー, まあ, なんか, そのー, えっと, 那个, 就是说, 嗯
        2. DISCOURSE SCAFFOLDING (no semantic content): sentence-initial "So,", "Basically,", \
        "Right,", "Like,"; parenthetical "you know?", "right?", "I mean" when not clarifying. \
        Keep when it reflects the speaker's characteristic tone (e.g., casual "So," at the start of a story).
        3. FALSE STARTS: speaker abandons mid-phrase and immediately restarts the same thought
        4. ABANDONED THOUGHTS: speaker starts a clause, then pivots to a NEW thought that \
        supersedes it. Signals: topic shift after "but actually", "hold on", "wait", \
        trailing off into a different complete clause. Keep ONLY the final intended thought. \
        IMPORTANT: If both clauses contain complementary information, keep both.
        5. EXPLICIT SELF-CORRECTIONS: "Monday, no wait, Tuesday" → "Tuesday" \
        "Aじゃなくて、B" → "B" / "不是A，是B" → "B"
        6. STUTTERS AND REPETITIONS: "the the", "あの、あの", "对对对"
        7. ORAL HEDGING with no content: excessive "I think", "kind of", "sort of", "可能", \
        "なんていうか" when they add no meaning. Keep when expressing genuine uncertainty.

        FIX:
        - Misrecognized words and homophones (including kanji/kana errors)
        - Missing or incorrect punctuation
        - Unnatural word splits or merges from STT

        DO NOT:
        - Paraphrase or restructure sentences that are already fluent
        - Summarize, omit, or add information beyond what was spoken \
        (removing incomplete clauses superseded by a subsequent complete thought per rule 4 is not omission)
        - Over-formalize casual speech or remove speaker personality
        - Include any explanations, annotations, or comments

        PRECISION RULE: When uncertain whether something is noise or content, PRESERVE it. \
        Removing real content is worse than leaving a speech artifact.

        EXAMPLES:

        INPUT: 我想说的是，那个，不是，我的意思是我们需要更多时间。
        OUTPUT: 我的意思是我们需要更多时间。

        INPUT: The deadline is, hmm, actually we don't have a hard deadline yet.
        OUTPUT: Actually we don't have a hard deadline yet.

        INPUT: えっと、来週の月曜日に、あ、違う、火曜日にミーティングがあります。
        OUTPUT: 来週の火曜日にミーティングがあります。

        INPUT: I was going to suggest we... the real issue is the API latency.
        OUTPUT: The real issue is the API latency.

        INPUT: 我们打算用Python来做，但是那个，其实整个架构都有问题。
        OUTPUT: 我们打算用Python来做，但是其实整个架构都有问题。

        INPUT: I think, um, I think we should probably, kind of, revisit the timeline.
        OUTPUT: I think we should probably revisit the timeline.

        Output ONLY the corrected text. Nothing else.
        """

    private let providerFactory: @Sendable () -> LLMProvider

    init(providerFactory: @escaping @Sendable () -> LLMProvider) {
        self.providerFactory = providerFactory
    }

    // MARK: - Notification Permission

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Public API

    func correctTranscription(_ text: String, forceEnabled: Bool = false) async -> String {
        let prefs = AppPreferences.shared

        guard forceEnabled || prefs.llmCorrectionEnabled else {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("No speech detected") else {
            return text
        }

        let provider = providerFactory()

        guard provider.isConfigured else {
            return text
        }

        let systemPrompt = prefs.llmCorrectionPrompt

        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.correctTranscription(trimmed, systemPrompt: systemPrompt)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw LLMProviderError.timeout(seconds: 30)
                }
                guard let result = try await group.next() else {
                    throw LLMProviderError.emptyResponse
                }
                group.cancelAll()
                return result
            }

            let trimmedResult = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedResult.isEmpty else {
                logger.warning("LLM correction returned empty result, using original text")
                return text
            }

            logger.info("LLM correction applied successfully")
            if prefs.debugMode {
                logger.debug("[DEBUG] LLM response: outputLength=\(trimmedResult.count, privacy: .public), inputLength=\(text.count, privacy: .public), changed=\(trimmedResult != trimmed, privacy: .public)")
            }
            return trimmedResult

        } catch {
            let errorDetail = String(describing: error)
            logger.error("LLM correction failed: \(errorDetail, privacy: .public)")
            NotificationCenter.default.post(
                name: .llmCorrectionFailed,
                object: nil,
                userInfo: ["error": error]
            )

            let content = UNMutableNotificationContent()
            content.title = "LLM Correction Failed"
            content.body = error.localizedDescription
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)

            return text
        }
    }

    // MARK: - Provider Resolution

    private nonisolated static func resolveProvider() -> LLMProvider {
        let providerType = LLMProviderType(rawValue: AppPreferences.shared.llmProvider) ?? .bedrock
        switch providerType {
        case .bedrock:
            return BedrockLLMProvider()
        case .openai:
            return OpenAICompatibleLLMProvider()
        }
    }
}
