// TranscriptMCPHandler.swift
// OpenSuperMLX

import Foundation

enum TranscriptMCPHandlerError: LocalizedError {
    case invalidRequest
    case invalidParams
    case unsupportedMethod(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid JSON-RPC request."
        case .invalidParams:
            return "Invalid JSON-RPC params."
        case .unsupportedMethod(let method):
            return "Unsupported MCP method: \(method)"
        }
    }

    var jsonRPCCode: Int {
        switch self {
        case .invalidRequest:
            return -32600
        case .invalidParams:
            return -32602
        case .unsupportedMethod:
            return -32601
        }
    }
}

final class TranscriptMCPHandler {
    private let store: TranscriptSessionStore
    private let encoder: JSONEncoder

    init(store: TranscriptSessionStore = .shared) {
        self.store = store
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func handle(_ data: Data) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else {
            throw TranscriptMCPHandlerError.invalidRequest
        }

        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]

        let response: [String: Any]
        do {
            let result = try result(for: method, params: params)
            response = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "result": result
            ]
        } catch let error as TranscriptMCPHandlerError {
            response = errorResponse(id: id, code: error.jsonRPCCode, message: error.localizedDescription)
        } catch {
            response = errorResponse(id: id, code: -32603, message: error.localizedDescription)
        }

        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }

    // MARK: - Methods

    private func result(for method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            return initializeResult(params: params)
        case "notifications/initialized":
            return [:]
        case "tools/list":
            return toolsListResult()
        case "tools/call":
            return try toolCallResult(params: params)
        default:
            throw TranscriptMCPHandlerError.unsupportedMethod(method)
        }
    }

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "opensupermlx-transcript",
                "version": "0.1.0"
            ]
        ]
    }

    private func toolsListResult() -> [String: Any] {
        [
            "tools": [
                tool(
                    name: "get_transcript_delta",
                    description: "Return transcript segments after a cursor.",
                    properties: [
                        "session_id": stringSchema(description: "Transcript session id. Defaults to latest session."),
                        "after_cursor": stringSchema(description: "Cursor returned by the previous delta call."),
                        "max_segments": integerSchema(description: "Maximum number of segments to return.", defaultValue: 50),
                        "include_provisional": booleanSchema(description: "Include provisional text that may still change.", defaultValue: false)
                    ]
                ),
                tool(
                    name: "search_transcript",
                    description: "Search transcript text and return bounded snippets.",
                    properties: [
                        "query": stringSchema(description: "Case-insensitive search query."),
                        "session_id": stringSchema(description: "Transcript session id. Defaults to latest session."),
                        "limit": integerSchema(description: "Maximum number of matches.", defaultValue: 10),
                        "context_segments": integerSchema(description: "Segments before and after each match.", defaultValue: 1),
                        "include_provisional": booleanSchema(description: "Search provisional text that may still change.", defaultValue: false)
                    ],
                    required: ["query"]
                ),
                tool(
                    name: "get_transcript_window",
                    description: "Return transcript context around a cursor.",
                    properties: [
                        "session_id": stringSchema(description: "Transcript session id. Defaults to latest session."),
                        "around_cursor": stringSchema(description: "Cursor to center the window on."),
                        "before_segments": integerSchema(description: "Number of previous segments.", defaultValue: 5),
                        "after_segments": integerSchema(description: "Number of following segments.", defaultValue: 5),
                        "include_provisional": booleanSchema(description: "Include provisional text that may still change.", defaultValue: false)
                    ],
                    required: ["around_cursor"]
                ),
                tool(
                    name: "list_transcript_sessions",
                    description: "List recent transcript sessions.",
                    properties: [
                        "limit": integerSchema(description: "Maximum number of sessions.", defaultValue: 20)
                    ]
                )
            ]
        ]
    }

    private func toolCallResult(params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw TranscriptMCPHandlerError.invalidParams
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            switch name {
            case "get_transcript_delta":
                return try getTranscriptDelta(arguments)
            case "search_transcript":
                return try searchTranscript(arguments)
            case "get_transcript_window":
                return try getTranscriptWindow(arguments)
            case "list_transcript_sessions":
                return try listTranscriptSessions(arguments)
            default:
                return toolError("Unknown tool: \(name)")
            }
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func getTranscriptDelta(_ arguments: [String: Any]) throws -> [String: Any] {
        let response = try store.transcriptDelta(
            sessionID: optionalString(arguments["session_id"]),
            afterCursor: optionalString(arguments["after_cursor"]),
            maxSegments: boundedInt(arguments["max_segments"], defaultValue: 50, maxValue: 200),
            includeProvisional: bool(arguments["include_provisional"], defaultValue: false)
        )
        return try toolResult(
            text: "Returned \(response.segments.count) transcript segments.",
            structuredContent: response
        )
    }

    private func searchTranscript(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let query = optionalString(arguments["query"]) else {
            throw TranscriptMCPHandlerError.invalidParams
        }
        let response = try store.searchTranscript(
            query: query,
            sessionID: optionalString(arguments["session_id"]),
            limit: boundedInt(arguments["limit"], defaultValue: 10, maxValue: 50),
            contextSegments: boundedInt(arguments["context_segments"], defaultValue: 1, maxValue: 10),
            includeProvisional: bool(arguments["include_provisional"], defaultValue: false)
        )
        return try toolResult(
            text: "Found \(response.matches.count) transcript matches.",
            structuredContent: response
        )
    }

    private func getTranscriptWindow(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let aroundCursor = optionalString(arguments["around_cursor"]) else {
            throw TranscriptMCPHandlerError.invalidParams
        }
        let response = try store.transcriptWindow(
            sessionID: optionalString(arguments["session_id"]),
            aroundCursor: aroundCursor,
            beforeSegments: boundedInt(arguments["before_segments"], defaultValue: 5, maxValue: 50),
            afterSegments: boundedInt(arguments["after_segments"], defaultValue: 5, maxValue: 50),
            includeProvisional: bool(arguments["include_provisional"], defaultValue: false)
        )
        return try toolResult(
            text: "Returned \(response.segments.count) transcript window segments.",
            structuredContent: response
        )
    }

    private func listTranscriptSessions(_ arguments: [String: Any]) throws -> [String: Any] {
        let sessions = store.listSessions(
            limit: boundedInt(arguments["limit"], defaultValue: 20, maxValue: 100)
        )
        return try toolResult(
            text: "Returned \(sessions.count) transcript sessions.",
            structuredContent: ["sessions": sessions]
        )
    }

    // MARK: - Response Helpers

    private func toolResult<T: Encodable>(text: String, structuredContent: T) throws -> [String: Any] {
        [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "structuredContent": try jsonObject(structuredContent)
        ]
    }

    private func toolError(_ message: String) -> [String: Any] {
        [
            "isError": true,
            "content": [
                [
                    "type": "text",
                    "text": message
                ]
            ]
        ]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Tool Schema Helpers

    private func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }

    private func stringSchema(description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private func integerSchema(description: String, defaultValue: Int) -> [String: Any] {
        ["type": "integer", "description": description, "default": defaultValue]
    }

    private func booleanSchema(description: String, defaultValue: Bool) -> [String: Any] {
        ["type": "boolean", "description": description, "default": defaultValue]
    }

    // MARK: - Argument Helpers

    private func optionalString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boundedInt(_ value: Any?, defaultValue: Int, maxValue: Int) -> Int {
        let raw: Int
        if let int = value as? Int {
            raw = int
        } else if let number = value as? NSNumber {
            raw = number.intValue
        } else {
            raw = defaultValue
        }
        return min(max(1, raw), maxValue)
    }

    private func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return defaultValue
    }
}
