import Foundation

enum TransferStrategy: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard — One drive at a time"
    case singleReadFanOut = "Multi-Drive — All drives at once"
    case cascading = "Cascading — SSD first, then other drives"
    var id: String { rawValue }
}

enum JobState: String { case idle="Ready", copying="Copying", verifying="Verifying", completed="Verified", cancelled="Cancelled", failed="Failed" }
struct Destination: Identifiable, Hashable { let id=UUID(); let url:URL; var name:String { url.lastPathComponent } }
struct CopyEntry: Identifiable, Hashable { let id=UUID(); let source:URL; let relativePath:String; let size:Int64 }
struct ChecksumRecord { let file:String; let source:String; let destination:String; let sourceChecksum:String; let destinationChecksum:String; let status:String; var size:Int64? = nil }
struct TransferHistoryRecord: Codable, Identifiable { let id:UUID; let date:Date; let sources:[String]; let destinations:[String]; let bytes:Int64; let files:Int; let verified:Bool; let status:String; let reportPath:String? }

struct MountedDrive: Identifiable, Hashable { let url: URL; let name: String; let capacity: Int64; let available: Int64; var id: String { url.path } }
struct PreflightResult { let ok: Bool; let messages: [String] }


enum VerificationSchedule:String,Codable,CaseIterable,Identifiable {
    case afterCopy="Copy all, then Verify all"
    case perFile="Copy and Verify each file"
    case pipelined="Copy + Verify concurrently (experimental)"
    var id:String { rawValue }
}
enum IOBufferSize:Int,Codable,CaseIterable,Identifiable {
    case automatic=0, small=4, medium=8, large=16
    var id:Int { rawValue }
    // A persisted raw value of 0 opts into per-file selection. Existing 4/8/16
    // values keep their meaning, including queued/recovered jobs.
    static let automaticLargeFileThreshold:Int64 = 256*1024*1024
    var bytes:Int { self == .automatic ? 8*1024*1024 : rawValue*1024*1024 }
    func bytes(forFileSize size:Int64)->Int {
        self == .automatic && size >= Self.automaticLargeFileThreshold ? 16*1024*1024 : bytes
    }
    var label:String { self == .automatic ? "Automatic — 16 MB for files ≥256 MiB, otherwise 8 MB" : "\(rawValue) MB" }
}
struct PhaseSnapshot {
    var name:String="Ready"
    var progress:Double=0
    var bytes:Int64=0
    var total:Int64 = -1
}

struct DestinationProgress:Identifiable {
    let id:UUID
    let name:String
    let path:String
    let progress:Double
    let state:String
    let verified:Bool
    let report:URL?
}
