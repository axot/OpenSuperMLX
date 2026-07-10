// TranscriptMCPHTTPServerTests.swift
// OpenSuperMLXTests

import Foundation
import XCTest

@testable import OpenSuperMLX

final class TranscriptMCPHTTPServerTests: XCTestCase {

    private var store: TranscriptSessionStore!
    private var handler: TranscriptMCPHandler!
    private var sut: TranscriptMCPHTTPServer!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        store = TranscriptSessionStore()
        handler = TranscriptMCPHandler(store: store)
        sut = TranscriptMCPHTTPServer(handler: handler)
    }

    override func tearDown() {
        sut = nil
        handler = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testPostMCPReturnsJSONRPCResponse() throws {
        let sessionID = store.startSession(startedAt: Date(timeIntervalSince1970: 100))
        _ = try store.appendSegment(sessionID: sessionID, kind: .final, text: "hello", startMs: 0, endMs: 1_000)

        let body = try jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "get_transcript_delta",
                "arguments": [
                    "session_id": sessionID,
                    "max_segments": 10
                ]
            ]
        ])

        let response = try parseHTTPResponse(sut.httpResponse(for: makeRequest(method: "POST", path: "/mcp", body: body)))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let result = try XCTUnwrap(payload["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let segments = try XCTUnwrap(structured["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["text"] as? String, "hello")
    }

    func testGetMCPIsRejectedBecauseV1IsPostOnly() throws {
        let response = try parseHTTPResponse(sut.httpResponse(for: makeRequest(method: "GET", path: "/mcp", body: Data())))

        XCTAssertEqual(response.statusCode, 405)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("POST"))
    }

    func testUnknownPathReturnsNotFound() throws {
        let response = try parseHTTPResponse(sut.httpResponse(for: makeRequest(method: "POST", path: "/other", body: Data())))

        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Helpers

    private func makeRequest(method: String, path: String, body: Data) -> Data {
        var request = Data()
        request.append("\(method) \(path) HTTP/1.1\r\n".data(using: .utf8)!)
        request.append("Host: 127.0.0.1\r\n".data(using: .utf8)!)
        request.append("Content-Type: application/json\r\n".data(using: .utf8)!)
        request.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        request.append("\r\n".data(using: .utf8)!)
        request.append(body)
        return request
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func parseHTTPResponse(_ data: Data) throws -> HTTPResponse {
        let marker = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(data.range(of: marker))
        let headerData = data[..<range.lowerBound]
        let body = data[range.upperBound...]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let statusLine = try XCTUnwrap(lines.first)
        let statusParts = statusLine.split(separator: " ")
        let statusCode = try XCTUnwrap(Int(statusParts[1]))
        let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        })
        return HTTPResponse(statusCode: statusCode, headers: headers, body: Data(body))
    }

    private struct HTTPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }
}
