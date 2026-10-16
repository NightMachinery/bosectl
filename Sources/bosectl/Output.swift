// Output conventions, shared with sonyctl:
//
// - stdout carries results only: plain text, or one JSON value under --json.
// - Diagnostics always go to stderr (gray on a terminal), as {"error": "..."}
//   under --json, so stdout stays parseable even when a command fails.
// - Exit status: 0 ok, 1 failure, 2 usage error, 3 not connected.

import Foundation

enum Exit {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let notConnected: Int32 = 3
}

/// A failure that ends the command with a message and an exit status.
struct Failure: Error, CustomStringConvertible {
    var message: String
    var status: Int32 = Exit.failure

    init(_ message: String, status: Int32 = Exit.failure)
    {
        self.message = message
        self.status = status
    }

    static func usage(_ message: String) -> Failure { Failure(message, status: Exit.usage) }

    var description: String { message }
}

enum Output {
    static var json = false
    static var colorErrors = false

    static func error(_ message: String)
    {
        let on = colorErrors ? "\u{1b}[90m" : ""
        let off = colorErrors ? "\u{1b}[0m" : ""
        let text = json ? JSON.object([("error", .string(message))]).serialized() : message
        FileHandle.standardError.write(Data((on + text + off + "\n").utf8))
    }

    /// Debug output (--trace): plain text on stderr even under --json.
    static func trace(_ message: String)
    {
        let on = colorErrors ? "\u{1b}[90m" : ""
        let off = colorErrors ? "\u{1b}[0m" : ""
        FileHandle.standardError.write(Data((on + message + off + "\n").utf8))
    }

    /// A diagnostic that is not an error (progress, hints). Suppressed under
    /// --json, where stderr is reserved for errors.
    static func note(_ message: String)
    {
        guard !json else { return }
        error(message)
    }

    /// Prints `value` as JSON under --json, and `text()` otherwise.
    static func emit(_ value: JSON, text: () -> String)
    {
        if json {
            print(value.serialized())
        } else {
            let t = text()
            if !t.isEmpty { print(t) }
        }
    }

    static func configureColor(_ mode: ColorMode)
    {
        switch mode {
        case .always: colorErrors = true
        case .never: colorErrors = false
        case .auto: colorErrors = isatty(STDERR_FILENO) != 0
        }
    }
}

enum ColorMode: String, CaseIterable {
    case auto, always, never
}

/// A JSON value that keeps object keys in insertion order, so output reads in
/// the same order as the plain-text form.
indirect enum JSON {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    static func optional(_ value: Int?) -> JSON { value.map { .int($0) } ?? .null }
    static func optional(_ value: String?) -> JSON { value.map { .string($0) } ?? .null }
    static func optional(_ value: Bool?) -> JSON { value.map { .bool($0) } ?? .null }

    func serialized() -> String
    {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String)
    {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? String(d) : "null"
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (i, (key, value)) in fields.enumerated() {
                if i > 0 { out += "," }
                JSON.writeString(key, to: &out)
                out += ":"
                value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String)
    {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
