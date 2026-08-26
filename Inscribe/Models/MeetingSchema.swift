import Foundation
import SwiftData

/// Version 1 of the meeting store.
///
/// Schema versions exist so that changing a model is a deliberate act with a stated
/// migration, rather than a silent gamble on whether SwiftData can infer one. Adding
/// `recordedDuration` without this cost a recorded meeting.
///
/// To change a model: add `MeetingSchemaV2` holding the new shape, list it in
/// `MeetingMigrationPlan.schemas`, and add a `MigrationStage` describing the move.
/// A lightweight stage covers added properties with defaults and renames; anything
/// that reinterprets existing data needs a custom stage.
enum MeetingSchemaV1: VersionedSchema {
    /// Bumped whenever a model changes, so the version recorded in the store stops
    /// matching and SwiftData is asked to migrate rather than left to guess.
    ///
    /// 1.1.0 added `Meeting.audioFileName`; 1.2.0 added the `Dictation` model. Added
    /// optional properties and whole new models are the cases lightweight migration
    /// handles cleanly. The change that cost a meeting was `recordedDuration` —
    /// non-optional with a default, added with no plan at all.
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
