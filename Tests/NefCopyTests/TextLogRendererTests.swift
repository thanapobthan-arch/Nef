import XCTest
@testable import NefCopy

final class TextLogRendererTests: XCTestCase {
    private func render(_ records: [ChecksumRecord], files: Int = 1) -> String {
        TextLogRenderer.render(records: records, started: Date(timeIntervalSince1970: 0), finished: Date(timeIntervalSince1970: 330), status: "COMPLETED / VERIFIED", bytes: 42, files: files, verificationEnabled: true, sourceNames: ["Camera_A"], sources: [URL(fileURLWithPath: "/src/Camera_A")], destinations: [URL(fileURLWithPath: "/dst")], diagnostics: "")
    }
    func testPlainTextPerFileFieldsAndSourceName() {
        let text = render([ChecksumRecord(file: "A001/clip.mov", source: "/src/clip.mov", destination: "/dst/clip.mov", sourceChecksum: "1234", destinationChecksum: "1234", status: "PASS", size: 42)])
        for field in ["Source folders: Camera_A", "-- Transferred files --", "#1: clip.mov", "Path: A001/clip.mov", "Size: 42 bytes", "Source hash (XXH64BE): 1234", "Status: verified (PASS)", "Result: VERIFIED"] { XCTAssertTrue(text.contains(field), field) }
        XCTAssertFalse(text.contains("JSON lines"))
    }
    func testUnreachedAndPendingFilesAreSeparateAndCannotPass() {
        let records = [
            ChecksumRecord(file: "copied.mov", source: "/src/a", destination: "/dst/a", sourceChecksum: "1234", destinationChecksum: "Not verified", status: "PENDING", size: 20),
            ChecksumRecord(file: "unreached.mov", source: "/src/b", destination: "/dst/b", sourceChecksum: "Unavailable", destinationChecksum: "Not verified", status: "NOT TRANSFERRED", size: 22)
        ]
        let text = render(records, files: 2)
        XCTAssertTrue(text.contains("-- Not transferred --"))
        XCTAssertTrue(text.contains("Path: unreached.mov\nSize: 22 bytes"))
        XCTAssertTrue(text.contains("Copy process did not reach this file."))
        XCTAssertTrue(text.contains("-- Copied to temporary file — verification incomplete --"))
        XCTAssertTrue(text.contains("Pending/unreported: 2"))
        XCTAssertTrue(text.contains("Result: NOT FULLY VERIFIED"))
    }
    func testMismatchOverridesPassLabel() {
        let text = render([ChecksumRecord(file: "x", source: "/s", destination: "/d", sourceChecksum: "a", destinationChecksum: "b", status: "PASS")])
        XCTAssertTrue(text.contains("FAIL: 1"))
        XCTAssertTrue(text.contains("Result: NOT FULLY VERIFIED"))
        XCTAssertFalse(text.contains("Status: verified (PASS)"))
    }
    func testDuplicateRecordsCannotCertifyCompleteJob() {
        let item = ChecksumRecord(file: "x", source: "/s", destination: "/d", sourceChecksum: "a", destinationChecksum: "a", status: "PASS")
        XCTAssertTrue(render([item, item], files: 2).contains("Result: NOT FULLY VERIFIED"))
    }
    func testControlCharactersCannotForgeStatusLines() {
        XCTAssertEqual(TextLogRenderer.escaped("a\nStatus: verified\r\t\\b"), "a\\nStatus: verified\\r\\t\\\\b")
        XCTAssertFalse(TextLogRenderer.escaped("a\u{2028}Status: verified").contains("\u{2028}"))
    }
}
