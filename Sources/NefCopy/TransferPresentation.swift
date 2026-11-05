import Foundation

enum OffloadPage: String { case disks = "Disks", transfers = "Transfers" }

/// UI status never turns an incomplete/unverified job into a green success.
struct TransferPresentation {
    let state: JobState
    let progress: Double
    let verified: Bool
    let hasError: Bool

    var fraction: Double {
        guard progress.isFinite else { return 0 }
        let bounded = min(max(progress, 0), 1)
        // A rounded 100% must not imply completion before the engine finishes.
        return state == .completed && verified && !hasError ? 1 : min(bounded, 0.99)
    }
    var percent: Int { Int((fraction * 100).rounded(.down)) }
    var showsLiveMetrics: Bool { !hasError && (state == .copying || state == .verifying) }
    var title: String {
        if hasError { return "Interrupted — check transfer details" }
        switch state {
        case .idle: return "Ready"
        case .copying: return "Copying"
        case .verifying: return "Verifying destination"
        case .completed: return verified ? "Verified" : "Copy finished — NOT VERIFIED"
        case .cancelled: return "Stopped — not fully verified"
        case .failed: return "Failed — not fully verified"
        }
    }
}
