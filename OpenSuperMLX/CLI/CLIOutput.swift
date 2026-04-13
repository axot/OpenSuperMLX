// CLIOutput.swift
// OpenSuperMLX

import Foundation

// MARK: - Response Types

struct CLISuccessResponse<T: Encodable>: Encodable {
    let status = "success"
    let command: String
    let data: T
}

struct CLIErrorResponse: Encodable {
    let status = "error"
    let command: String
    let error: CLIErrorDetail
}

struct CLIErrorDetail: Encodable {
    let code: String
    let message: String
}

// MARK: - Output Formatting

enum CLIOutput {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func formatSuccess<T: Encodable>(command: String, data: T, json: Bool = true) -> String {
        if json {
            let response = CLISuccessResponse(command: command, data: data)
            guard let jsonData = try? encoder.encode(response),
                  let string = String(data: jsonData, encoding: .utf8)
            else { return "{}" }
            return string
        }
        return String(describing: data)
    }

    static func formatError(command: String, error: CLIError, json: Bool = true) -> String {
        if json {
            let detail = CLIErrorDetail(code: error.rawValue, message: error.description)
            let response = CLIErrorResponse(command: command, error: detail)
            guard let jsonData = try? encoder.encode(response),
                  let string = String(data: jsonData, encoding: .utf8)
            else { return "{}" }
            return string
        }
        return "Error: \(error.description)"
    }

    static func printSuccess<T: Encodable>(command: String, data: T, json: Bool) {
        let output = formatSuccess(command: command, data: data, json: json)
        writeToStdout(output + "\n")
    }

    static func printError(command: String, error: CLIError, json: Bool) {
        let output = formatError(command: command, error: error, json: json)
        writeToStderr(output + "\n")
    }

    static func printProgress(_ message: String, quiet: Bool) {
        guard !quiet else { return }
        writeToStderr(message + "\n")
    }

    // MARK: - Output Streams

    private static func writeToStdout(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func writeToStderr(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
