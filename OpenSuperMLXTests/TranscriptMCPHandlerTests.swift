// TranscriptMCPHandlerTests.swift
// OpenSuperMLXTests

import XCTest

@testable import OpenSuperMLX

final class TranscriptMCPHandlerTests: XCTestCase {

    private var store: TranscriptSessionStore!
    private var sut: TranscriptMCPHandler!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        store = TranscriptSessionStore()
        sut = TranscriptMCPHandler(store: store)
    }

    override func tearDown() {
        sut = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testInitializeAdvertisesToolsCapability() throws {
        let response = try callJSONRPC(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "tests", "version": "1.0"]
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
    }

    func testToolsListExposesTranscriptTools() throws {
        let response = try callJSONRPC(method: "tools/list", params: [:])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        XCTAssertTrue(names.contains("get_transcript_delta"))
        XCTAssertTrue(names.contains("search_transcript"))
        XCTAssertTrue(names.contains("get_transcript_window"))
    }

    func testInitializedNotificationIsAccepted() throws {
        let response = try callJSONRPC(method: "notifications/initialized", params: [:])

        XCTAssertNotNil(response["result"] as? [String: Any])
        XCTAssertNil(response["error"])
    }

    func testDeltaToolReturnsCursorOnlyInStructuredContent() throws {
        let sessionID = store.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try store.appendSegment(sessionID: sessionID, kind: .final, text: "first", startMs: 0, endMs: 1_000)
        let second = try store.appendSegment(sessionID: sessionID, kind: .final, text: "second", startMs: 1_000, endMs: 2_000)

        let response = try callJSONRPC(method: "tools/call", params: [
            "name": "get_transcript_delta",
            "arguments": [
                "session_id": sessionID,
                "after_cursor": "seg_000001",
                "max_segments": 10
            ]
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("cursor"))
        XCTAssertFalse(text.contains(second.cursor))

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["next_cursor"] as? String, second.cursor)
        let segments = try XCTUnwrap(structured["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["text"] as? String, "second")
    }

    func testSearchToolReturnsStructuredMatches() throws {
        let sessionID = store.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try store.appendSegment(sessionID: sessionID, kind: .final, text: "meeting starts", startMs: 0, endMs: 1_000)
        _ = try store.appendSegment(sessionID: sessionID, kind: .final, text: "search Bedrock docs", startMs: 1_000, endMs: 2_000)

        let response = try callJSONRPC(method: "tools/call", params: [
            "name": "search_transcript",
            "arguments": [
                "session_id": sessionID,
                "query": "bedrock",
                "limit": 5,
                "context_segments": 1
            ]
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let matches = try XCTUnwrap(structured["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        let segment = try XCTUnwrap(matches.first?["segment"] as? [String: Any])
        XCTAssertEqual(segment["text"] as? String, "search Bedrock docs")
    }

    func testUnknownToolReturnsToolErrorResult() throws {
        let response = try callJSONRPC(method: "tools/call", params: [
            "name": "unknown_tool",
            "arguments": [:]
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains("Unknown tool") == true)
    }

    func testToolsCallWithoutNameReturnsInvalidParamsError() throws {
        let response = try callJSONRPC(method: "tools/call", params: [:])

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - Helpers

    private func callJSONRPC(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let responseData = try sut.handle(requestData)
        let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        return try XCTUnwrap(response)
    }
}
