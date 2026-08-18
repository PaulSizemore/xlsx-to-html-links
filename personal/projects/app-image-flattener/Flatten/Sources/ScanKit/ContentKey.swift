import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum ContentKey {
    /// Duplicate/relink identity: hash of the embedded preview plus capture time.
    static func make(thumbnailJPEG: Data, captureTime: Date?) -> String {
        var input = thumbnailJPEG
        if let captureTime {
            var seconds = Int64(captureTime.timeIntervalSince1970)
            withUnsafeBytes(of: &seconds) { input.append(contentsOf: $0) }
        }
        return hexDigest(input)
    }

    static func hexDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // Non-cryptographic fallback for platforms without CryptoKit (dev only).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%016llx", hash)
        #endif
    }
}
