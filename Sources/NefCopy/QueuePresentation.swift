import Foundation

enum QueueStatusTone {case neutral,copying,verifying,success,paused,failure,warning}
struct QueueRowPresentation {
    let title:String
    let tone:QueueStatusTone
    let fraction:Double
    let showsMetrics:Bool
    var percent:Int {Int((fraction*100).rounded(.down))}

    init(state:QueuedJobState,workerState:JobState?=nil,progress:Double=0,verified:Bool=false,paused:Bool=false,hasError:Bool=false) {
        let safe=progress.isFinite ? min(max(progress,0),0.99):0
        switch state {
        case .queued:title="Waiting";tone = .neutral;fraction=0;showsMetrics=false
        case .verified:
            let passed=verified && !hasError
            title=passed ? "Completed":"Needs attention";tone=passed ? .success:.failure;fraction=passed ? 1:safe;showsMetrics=false
        case .copied:title="Copied · Not verified";tone = .warning;fraction=safe;showsMetrics=false
        case .failed:title="Failed";tone = .failure;fraction=safe;showsMetrics=false
        case .cancelled:title="Cancelled";tone = .failure;fraction=safe;showsMetrics=false
        case .running:
            fraction=safe
            if paused {title="Paused";tone = .paused;showsMetrics=false}
            else if hasError {title="Needs attention";tone = .warning;showsMetrics=false}
            else if workerState == .verifying {title="Verifying";tone = .verifying;showsMetrics=true}
            else if workerState == .copying {title="Copying";tone = .copying;showsMetrics=true}
            else {title="Finalizing";tone = .verifying;showsMetrics=false}
        }
    }
    init(job:QueuedTransferJob) {
        self.init(state:job.state,workerState:job.engine?.phaseName.hasPrefix("Verifying source") == true ? .verifying:job.engine?.state,progress:job.engine?.progress ?? 0,
                  verified:job.engine?.lastRunWasVerified ?? (job.state == .verified),paused:job.engine?.isPaused ?? false,
                  hasError:job.error != nil || job.engine?.errorMessage != nil)
    }
    // Average job completion, not an invented byte-weighted estimate.
    static func overall(_ rows:[QueueRowPresentation])->Double {
        guard !rows.isEmpty else{return 0}
        return rows.reduce(0){$0+$1.fraction}/Double(rows.count)
    }
}
