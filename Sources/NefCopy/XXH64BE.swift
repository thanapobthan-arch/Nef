import Foundation
import CXXHash

// Official xxHash 0.8.3 C implementation, seed 0; canonical big-endian output.
// Non-cryptographic: intended to detect accidental file corruption.
final class XXH64BE {
    private let state:OpaquePointer
    init() {
        guard let allocated=nef_xxh64_create() else { preconditionFailure("Unable to allocate XXH64 state") }
        state=allocated
    }
    deinit { nef_xxh64_free(state) }
    func update(data:Data) {
        data.withUnsafeBytes { bytes in
            nef_xxh64_update(state,bytes.baseAddress,bytes.count)
        }
    }
    func finalize()->[UInt8] {
        let value=nef_xxh64_digest(state)
        return (0..<8).map { UInt8(truncatingIfNeeded:value >> ((7-$0)*8)) }
    }
}
