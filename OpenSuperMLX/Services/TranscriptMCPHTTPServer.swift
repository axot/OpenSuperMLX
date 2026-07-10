// TranscriptMCPHTTPServer.swift
// OpenSuperMLX

import Foundation
import Network
import os.log

private let transcriptMCPHTTPLogger = Logger(subsystem: "OpenSuperMLX", category: "TranscriptMCPHTTPServer")

enum TranscriptMCPHTTPServerError: LocalizedError {
    case malformedRequest

    var errorDescription: String? {
        switch self {
        case .malformedRequest:
            return "Malformed HTTP request."
        }
    }
}

final class TranscriptMCPHTTPServer {
    static let defaultPort: UInt16 = 17653

    private let handler: TranscriptMCPHandler
    private let port: UInt16
    private let queue = DispatchQueue(label: "OpenSuperMLX.TranscriptMCPHTTPServer")
    private var listener: NWListener?

    init(handler: TranscriptMCPHandler = TranscriptMCPHandler(), port: UInt16 = TranscriptMCPHTTPServer.defaultPort) {
        self.handler = handler
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        let port = self.port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                transcriptMCPHTTPLogger.info("Transcript MCP server listening on 127.0.0.1:\(port, privacy: .public)")
            case .failed(let error):
                transcriptMCPHTTPLogger.error("Transcript MCP server failed: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func httpResponse(for requestData: Data) -> Data {
        do {
            let request = try HTTPRequest.parse(requestData)
            guard request.path == "/mcp" else {
                return makeResponse(statusCode: 404, reason: "Not Found", body: errorBody("Not found."))
            }
            guard request.method == "POST" else {
                return makeResponse(statusCode: 405, reason: "Method Not Allowed", body: errorBody("Use POST /mcp."))
            }

            let responseBody = try handler.handle(request.body)
            return makeResponse(statusCode: 200, reason: "OK", body: responseBody)
        } catch {
            return makeResponse(statusCode: 400, reason: "Bad Request", body: errorBody(error.localizedDescription))
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if Self.hasCompleteRequest(nextBuffer) || isComplete {
                let response = self.httpResponse(for: nextBuffer)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func makeResponse(statusCode: Int, reason: String, body: Data) -> Data {
        var response = Data()
        response.appendUTF8("HTTP/1.1 \(statusCode) \(reason)\r\n")
        response.appendUTF8("Content-Type: application/json\r\n")
        response.appendUTF8("Content-Length: \(body.count)\r\n")
        response.appendUTF8("Connection: close\r\n")
        response.appendUTF8("\r\n")
        response.append(body)
        return response
    }

    private func errorBody(_ message: String) -> Data {
        let object = ["error": message]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = HTTPRequest.contentLength(from: headerText)
        return data.count >= headerRange.upperBound + contentLength
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data

        static func parse(_ data: Data) throws -> HTTPRequest {
            let marker = Data("\r\n\r\n".utf8)
            guard let headerRange = data.range(of: marker) else {
                throw TranscriptMCPHTTPServerError.malformedRequest
            }

            let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                throw TranscriptMCPHTTPServerError.malformedRequest
            }
            let requestParts = requestLine.split(separator: " ", maxSplits: 2)
            guard requestParts.count >= 2 else {
                throw TranscriptMCPHTTPServerError.malformedRequest
            }

            let contentLength = contentLength(from: headerText)
            guard data.count >= headerRange.upperBound + contentLength else {
                throw TranscriptMCPHTTPServerError.malformedRequest
            }

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + contentLength
            return HTTPRequest(
                method: String(requestParts[0]),
                path: String(requestParts[1]),
                body: Data(data[bodyStart..<bodyEnd])
            )
        }

        static func contentLength(from headerText: String) -> Int {
            for line in headerText.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                    continue
                }
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
            return 0
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
