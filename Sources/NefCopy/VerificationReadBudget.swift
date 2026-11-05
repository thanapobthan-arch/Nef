import Foundation

// Shared by isolated destination engines: at most four verification readers,
// and one reader per detected disk/container. Copy writers never hold this gate.
enum VerificationReadBudget {
    private static let lock=NSLock()
    private static let global=DispatchSemaphore(value:4)
    private static var lanes:[String:DispatchSemaphore]=[:]
    static func acquire(key:String,checkpoint:() throws -> Void) throws -> () -> Void {
        lock.lock()
        let lane=lanes[key] ?? DispatchSemaphore(value:1)
        lanes[key]=lane
        lock.unlock()
        while lane.wait(timeout:.now()+0.05) == .timedOut { try checkpoint() }
        do {
            try checkpoint()
            while global.wait(timeout:.now()+0.05) == .timedOut { try checkpoint() }
        } catch { lane.signal();throw error }
        return {global.signal();lane.signal()}
    }
}
