import Foundation
import CryptoKit

/// Deterministic identifiers. The archive is rebuilt from sources on every
/// import, so anything that must survive a rebuild — a selection, a saved
/// place, a link — is keyed by a hash of its content rather than a random
/// UUID.
public enum StableID {
    /// UUID version 5 shape: the SHA-256 of the seed, with the version and
    /// variant bits set.
    public static func uuid(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
