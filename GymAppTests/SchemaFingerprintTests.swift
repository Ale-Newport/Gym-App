import Foundation
import SwiftData
import Testing

@testable import GymApp

/// Guards the on-disk format that version 1.0 shipped.
///
/// `SchemaV1` lists the live `@Model` classes, so changing any of them silently changes what
/// "version 1" means and stores written by 1.0 stop opening. This test records the shape of every
/// entity as released; when it fails, follow the steps on `GymAppMigrationPlan` (freeze the 1.0
/// models inside `SchemaV1`, add `SchemaV2` and a migration stage) and only then update the
/// expected fingerprint.
@Suite("Store schema fingerprint")
struct SchemaFingerprintTests {

    /// Every entity, attribute and relationship of the current `SchemaV1`, in a stable order.
    static func fingerprint() -> String {
        let schema = Schema(versionedSchema: SchemaV1.self)
        return schema.entities
            .sorted { $0.name < $1.name }
            .map { entity in
                let attributes = entity.attributes
                    .map { "\($0.name):\(String(describing: $0.valueType))\($0.isOptional ? "?" : "")" }
                    .sorted()
                let relationships = entity.relationships
                    .map { "\($0.name)->\($0.destination)\($0.isToOneRelationship ? "" : "[]")" }
                    .sorted()
                return "\(entity.name){\((attributes + relationships).joined(separator: ","))}"
            }
            .joined(separator: "\n")
    }

    /// FNV-1a, so the expected value is a short, stable number rather than the whole schema.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }

    @Test("The models still match the schema that version 1.0 shipped")
    func schemaMatchesTheReleasedVersion() {
        let actual = Self.hash(Self.fingerprint())
        #expect(
            actual == Self.releasedV1,
            """
            The SwiftData models changed (fingerprint \(actual)). Stores written by 1.0 will no longer \
            open. Freeze the 1.0 models in SchemaV1 and add SchemaV2 + a migration stage first — see \
            GymAppMigrationPlan.
            """
        )
    }

    /// The fingerprint of the models in the v1.0.0 release.
    static let releasedV1 = "50341000b1bc5b0a"
}
