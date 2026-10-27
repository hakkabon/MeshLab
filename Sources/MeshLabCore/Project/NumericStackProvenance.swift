import Foundation
import NumericCore

public struct NumericCapabilityRecord: Sendable, Hashable, Codable {
    public let identifier: String
    public let stability: String
    public let contractVersion: Int
}

/// Exact released numerical stack consumed by this MeshLab release.
///
/// The version constants intentionally live beside the capability digest and
/// are checked by `Scripts/check-numeric-stack.sh` against Package.resolved.
/// Rust-NumericCore is distributed inside the pinned Swift-NumericCore binary
/// target, so its release identity is part of this application contract.
public struct NumericStackProvenance: Sendable, Hashable, Codable {
    public static let swiftNumericCoreVersion = "1.0.0"
    public static let rustNumericCoreVersion = "0.34.0"

    public let swiftNumericCoreVersion: String
    public let rustNumericCoreVersion: String
    public let compatibilityEpoch: Int
    public let manifestSchemaVersion: Int
    public let capabilityDigest: String
    public let capabilities: [NumericCapabilityRecord]

    public static var current: NumericStackProvenance {
        let capabilities = NumericCoreAPI.capabilities.map {
            NumericCapabilityRecord(
                identifier: $0.identifier,
                stability: $0.stability.rawValue,
                contractVersion: $0.contractVersion
            )
        }
        return NumericStackProvenance(
            swiftNumericCoreVersion: swiftNumericCoreVersion,
            rustNumericCoreVersion: rustNumericCoreVersion,
            compatibilityEpoch: NumericCoreAPI.compatibilityEpoch,
            manifestSchemaVersion: NumericCoreAPI.manifestSchemaVersion,
            capabilityDigest: digest(capabilities),
            capabilities: capabilities
        )
    }

    public var contract: String {
        "swift-numeric-core-\(swiftNumericCoreVersion)/rust-numeric-core-\(rustNumericCoreVersion)"
    }

    private static func digest(_ capabilities: [NumericCapabilityRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(capabilities)) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
