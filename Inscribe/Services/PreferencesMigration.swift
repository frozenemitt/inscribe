import Foundation
import os

/// Carries preferences across a change of bundle identifier.
///
/// `UserDefaults.standard` is keyed by bundle identifier, so renaming the app from the
/// sample project's `com.swift.examples.scribe.macos` would otherwise silently reset
/// every setting — sounds, hotkey, prompts, output behaviour — with no way back short
/// of editing a plist by hand.
///
/// Runs once, before `AppSettings` reads anything, and never overwrites a value already
/// set under the new identifier.
enum PreferencesMigration {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "Migration")

    /// Identifiers this app has shipped under, newest last.
    private static let legacyDomains = [
        "com.swift.examples.scribe",
        "com.swift.examples.scribe.macos"
    ]

    private static let completedKey = "didMigrateLegacyPreferences"

    /// Copy anything the old identifier held that the new one does not.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return }

        var copied = 0

        for domain in legacyDomains {
            guard let legacy = UserDefaults(suiteName: domain) else { continue }

            // persistentDomain, not dictionaryRepresentation: the latter includes every
            // global and registered default, which would drag NSGlobalDomain settings
            // into this app's plist.
            guard let contents = legacy.persistentDomain(forName: domain) else { continue }

            for (key, value) in contents {
                // Window frames and split positions are AppKit's to manage, and stale
                // ones restore a layout that no longer exists.
                guard !key.hasPrefix("NS"), !key.hasPrefix("com.apple") else { continue }

                // Never clobber a preference already set under the new identifier.
                guard defaults.object(forKey: key) == nil else { continue }

                defaults.set(value, forKey: key)
                copied += 1
            }
        }

        defaults.set(true, forKey: completedKey)

        if copied > 0 {
            log.notice("Carried \(copied) preferences over from the previous bundle identifier")
        }
    }
}
