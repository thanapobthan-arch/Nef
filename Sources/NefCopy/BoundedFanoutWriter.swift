import Foundation

// Writes each source chunk to every destination on independent serial queues.
// A bounded number of chunks may be in flight, so a temporarily slow drive does
// not stall every writer immediately and memory usage cannot grow without limit.
final class BoundedFanoutWriter {
    private struct Writer {
        let handle: FileHandle
        let queue: DispatchQueue
    }

    private let writers: [Writer]
    private let chunkSlots: DispatchSemaphore
    private let allWrites = DispatchGroup()
    private let completionQueue = DispatchQueue(label: "local.nefcopy.fanout.completion")
    private let lock = NSLock()
    private var firstError: Error?

    init(handles: [FileHandle], maxChunksInFlight: Int = 4) {
        self.writers = handles.enumerated().map { index, handle in
            Writer(handle: handle, queue: DispatchQueue(label: "local.nefcopy.fanout.writer.\(index)", qos: .userInitiated))
        }
        self.chunkSlots = DispatchSemaphore(value: max(1, maxChunksInFlight))
    }

    func submit(_ data: Data, isCancelled: () -> Bool) throws {
        while chunkSlots.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled() { throw CopyError.cancelled }
            if let error = currentError() { throw error }
        }
        if isCancelled() { chunkSlots.signal(); throw CopyError.cancelled }
        if let error = currentError() { chunkSlots.signal(); throw error }

        let chunkDone = DispatchGroup()
        for writer in writers {
            allWrites.enter(); chunkDone.enter()
            writer.queue.async {
                defer { chunkDone.leave(); self.allWrites.leave() }
                if self.currentError() != nil { return }
                do { try writer.handle.write(contentsOf: data) }
                catch { self.storeFirstError(error) }
            }
        }
        chunkDone.notify(queue: completionQueue) { self.chunkSlots.signal() }
    }

    func finish() throws {
        allWrites.wait()
        if let error = currentError() { throw error }
    }

    private func currentError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return firstError
    }

    private func storeFirstError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }
}
