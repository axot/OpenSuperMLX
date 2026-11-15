// WordSelectionReplacement.swift
// OpenSuperMLX

import Foundation

struct WordSelectionReplacement {
    struct Selection: Equatable, Sendable {
        let document: String
        let start: Int
        let end: Int
        let text: String
        let isList: Bool
    }

    struct Plan: Equatable, Sendable {
        let start: Int
        let end: Int
        let text: String
    }

    // MARK: - Range Preparation

    static func plan(for selection: Selection, text: String) -> Plan? {
        guard selection.start >= 0, selection.end > selection.start,
              !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var end = selection.end
        var replacement = text
        // Word stores paragraph and list formatting on this mark. Replacing it can
        // merge or restyle the next bullet even if the replacement contains another CR.
        if selection.text.hasSuffix("\r") {
            end -= 1
            if replacement.hasSuffix("\r") { replacement.removeLast() }
        }
        guard end > selection.start else { return nil }
        if selection.isList {
            let leading = replacement.prefix { $0 == " " || $0 == "\t" }
            let content = replacement.dropFirst(leading.count)
            if let first = content.first, "•·‣∙●○".contains(first) {
                replacement = String(leading) + content.dropFirst().drop { $0 == " " || $0 == "\t" }
            }
        }
        return Plan(start: selection.start, end: end, text: replacement)
    }

    // MARK: - Word Automation

    static func capture() async -> Selection? {
        await Task.detached(priority: .userInitiated) {
            guard let result = execute("""
                with timeout of 5 seconds
                    tell application id "com.microsoft.Word"
                        if not (exists active document) then return {}
                        set r to text object of selection
                        if story type of r is not main text story then return {}
                        return {full name of active document, start of content of r, end of content of r, content of r, list type of list format of r is not list no numbering}
                    end tell
                end timeout
                """) else { return nil }
            return selection(from: result)
        }.value
    }

    static func selection(from result: NSAppleEventDescriptor) -> Selection? {
        guard result.numberOfItems == 5,
              let document = result.atIndex(1)?.stringValue,
              let start = result.atIndex(2)?.int32Value,
              let end = result.atIndex(3)?.int32Value,
              let text = result.atIndex(4)?.stringValue,
              start >= 0, end >= start else { return nil }
        return Selection(document: document, start: Int(start), end: Int(end), text: text, isList: result.atIndex(5)?.booleanValue ?? false)
    }

    static func replace(
        _ selection: Selection,
        with text: String,
        run: @escaping @Sendable (String) -> String? = { execute($0)?.stringValue }
    ) async -> Bool {
        guard !Task.isCancelled, let plan = plan(for: selection, text: text) else { return false }
        let task = Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSuperMLX-Word-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let documentFile = directory.appendingPathComponent("document.txt")
                let expectedFile = directory.appendingPathComponent("expected.txt")
                let replacementFile = directory.appendingPathComponent("replacement.txt")
                try selection.document.write(to: documentFile, atomically: true, encoding: .utf8)
                try selection.text.write(to: expectedFile, atomically: true, encoding: .utf8)
                try plan.text.write(to: replacementFile, atomically: true, encoding: .utf8)
                guard !Task.isCancelled else { return false }
                return run("""
                    use scripting additions
                    set expectedDocument to read (POSIX file \(literal(documentFile.path))) as «class utf8»
                    set expectedText to read (POSIX file \(literal(expectedFile.path))) as «class utf8»
                    set theText to read (POSIX file \(literal(replacementFile.path))) as «class utf8»
                    with timeout of 5 seconds
                        considering case and diacriticals
                            tell application id "com.microsoft.Word"
                                if not (exists active document) then return "changed"
                                if full name of active document is not expectedDocument then return "changed"
                                set r to create range active document start \(selection.start) end \(selection.end)
                                if content of r is not expectedText then return "changed"
                                set r to create range active document start \(plan.start) end \(plan.end)
                                set content of r to theText
                                return "applied"
                            end tell
                        end considering
                    end timeout
                    """) == "applied"
            } catch {
                return false
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
