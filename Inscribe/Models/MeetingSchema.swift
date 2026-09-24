import Foundation
import SwiftData

/// Version 1 of the meeting store.
///
/// Schema versions exist so that changing a model is a deliberate act with a stated
/// migration, rather than a silent gamble on whether SwiftData can infer one. Adding
/// `recordedDuration` without this cost a recorded meeting.
///
/// Version 1 lists the live model classes, so it describes whatever shape those
/// classes have today. That is why changing a model takes these steps, in this order:
///
/// 1. Copy each model class as it stands into `MeetingSchemaV1` as a nested type, and
///    list those copies in its `models` instead of the live classes. Version 1 then
///    keeps describing the shape already on disk.
/// 2. Add `MeetingSchemaV2` with a new `versionIdentifier`, listing the live classes,
///    and change the live classes to the new shape.
/// 3. List `MeetingSchemaV2` in `MeetingMigrationPlan.schemas`, point the container's
///    `Schema(versionedSchema:)` at it, and add a `MigrationStage` from version 1 to
///    version 2. A lightweight stage covers added properties with defaults, added
///    models and renames; anything that reinterprets existing data needs a custom one.
///
/// Skipping the first step leaves both versions describing the same classes. SwiftData
/// then rejects the plan for holding two versions with the same checksum, and the
/// store does not open.
enum MeetingSchemaV1: VersionedSchema {
    /// The version recorded in the stores already on disk. It stays as it is.
    ///
    /// 1.1.0 added `Meeting.audioFileName` and 1.2.0 added the `Dictation` model, both
    /// by editing this version in place. The next change is made as a new version, by
    /// the steps above, not by changing this number.
    static var versionIdentifier: Schema.Version { Schema.Version(1, 2, 0) }

    static var models: [any PersistentModel.Type] {
        [Meeting.self, Utterance.self, MeetingSpeaker.self, Dictation.self]
    }
}

/// How the meeting store moves between schema versions.
enum MeetingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MeetingSchemaV1.self]
    }

    /// Empty while there is only one version. Every future version adds a stage here.
    static var stages: [MigrationStage] {
        []
    }
}
