import Foundation

/// Plain text, one block per file. Control characters are escaped so a filename
/// cannot insert a forged log line. This renderer does not read or hash files.
enum TextLogRenderer {
    static func escaped(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            default:
                if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    result += String(format: "\\u{%04X}", scalar.value)
                } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    static func render(records: [ChecksumRecord], started: Date, finished: Date,
                       status: String, bytes: Int64, files: Int, verificationEnabled: Bool,
                       sourceNames: [String], sources: [URL], destinations: [URL],
                       diagnostics: String) -> String {
        let pass = records.filter { $0.status == "PASS" && validMatch($0) }.count
        let fail = records.filter { $0.status == "FAIL" || ($0.status == "PASS" && !validMatch($0)) }.count
        let copied = records.filter { $0.status == "COPIED" }.count
        let outstanding = records.filter { !["PASS", "FAIL", "COPIED"].contains($0.status) }.count
        let pending = max(0, files - records.count) + outstanding
        let unique = Set(records.map { $0.destination }).count == records.count
        let complete = verificationEnabled && status == "COMPLETED / VERIFIED" && files > 0 &&
            pass == files && fail == 0 && copied == 0 && pending == 0 && unique
        let verdict = complete ? "VERIFIED — all planned files passed checksum verification" : "NOT FULLY VERIFIED — keep source files"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.calendar = Calendar(identifier: .gregorian)
        date.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let rule = String(repeating: "-", count: 86)
        var text = "NefCopy 21.1.4 — \(escaped(ProcessInfo.processInfo.operatingSystemVersionString))\n\n\(rule)\n\n"
        for source in sources { text += "Source: \(escaped(source.path))\n" }
        for destination in destinations { text += "Destination: \(escaped(destination.path))\n" }
        text += "Source folders: \(sourceNames.map(escaped).joined(separator: ", "))\n\n"
        text += "Started: \(date.string(from: started))\nFinished/report time: \(date.string(from: finished))\n"
        text += String(format: "Duration: %.1f seconds\n\n", max(0, finished.timeIntervalSince(started)))
        text += "Planned files: \(files)\nRecorded files: \(records.count)\n"
        text += "Total files completed: \(pass + copied)\nPlanned size: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(bytes) Bytes)\n"
        text += "Hash type: XXH64BE\nVerification mode: \(verificationEnabled ? "Full destination readback" : "OFF — NOT VERIFIED")\n\n"
        text += "Status: \(escaped(status))\nResult: \(verdict)\nPASS: \(pass)\nFAIL: \(fail)\nCOPIED / NOT VERIFIED: \(copied)\nPending/unreported: \(pending)\n\n"
        let sections: [(String, (ChecksumRecord) -> Bool)] = [
            ("Transferred files", { $0.status == "PASS" && validMatch($0) }),
            ("Copied without verification", { $0.status == "COPIED" }),
            ("Failed files", { $0.status == "FAIL" || ($0.status == "PASS" && !validMatch($0)) }),
            ("Copied to temporary file — verification incomplete", { $0.status == "PENDING" }),
            ("Interrupted files", { $0.status == "INTERRUPTED" }),
            ("Not transferred", { $0.status == "NOT TRANSFERRED" })
        ]
        var number = 0
        for (heading, matches) in sections {
            let group = records.filter(matches)
            guard !group.isEmpty else { continue }
            text += "-- \(heading) --\n"
            for record in group {
                number += 1
                text += "#\(number): \(escaped(URL(fileURLWithPath: record.file).lastPathComponent))\nPath: \(escaped(record.file))\n"
                text += "Size: \(record.size.map { "\($0) bytes" } ?? "Unknown")\n"
                if record.status == "PASS" || record.status == "FAIL" || record.status == "PENDING" {
                    text += "Source hash (XXH64BE): \(escaped(record.sourceChecksum))\nDestination hash (XXH64BE): \(escaped(record.destinationChecksum))\n"
                }
                let description: String
                switch record.status {
                case "PASS": description = validMatch(record) ? "verified (PASS)" : "FAIL — invalid or mismatched checksums"
                case "FAIL": description = "failed (FAIL)"
                case "COPIED": description = "copied — NOT VERIFIED"
                case "PENDING": description = "not verified (Temporary copy is not published; cleanup attempted.)"
                case "INTERRUPTED": description = "not transferred (Operation started but did not complete.)"
                default: description = "not transferred (Copy process did not reach this file.)"
                }
                text += "Status: \(description)\n\n"
            }
        }
        if files > records.count { text += "File list incomplete: \(files - records.count) planned entries unavailable.\n\n" }
        text += "\(rule)\nDiagnostics\n\(diagnostics)\n"
        return text
    }

    private static func validMatch(_ record: ChecksumRecord) -> Bool {
        !record.sourceChecksum.isEmpty && record.sourceChecksum != "ERROR" &&
        record.sourceChecksum != "Not verified" && record.sourceChecksum == record.destinationChecksum
    }
}
