import SwiftUI
import SwiftData

#if os(macOS)

/// Recent dictations, so one that landed in the wrong window is recoverable.
struct DictationHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Dictation.createdAt, order: .reverse) private var dictations: [Dictation]

    @State private var searchText = ""
    @State private var justCopied: CopiedKind?
    @State private var isConfirmingClearAll = false

    /// Which copy button last completed, so only that button's own label flips —
    /// not its sibling, which copies a different string for the same dictation.
    private enum CopiedKind: Equatable {
        case cleaned(PersistentIdentifier)
        case original(PersistentIdentifier)
    }

    private var filtered: [Dictation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return dictations }
        return dictations.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !settings.keepDictationHistory {
                Label("History is switched off in Settings, so nothing new is being kept.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }

            if dictations.isEmpty {
                ContentUnavailableView(
                    "No Dictations Yet",
                    systemImage: "text.quote",
                    description: Text("Finished dictations appear here, so one that goes to the wrong window is not lost.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Dictation History")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            ToolbarItem {
                Button("Clear All", role: .destructive) {
                    isConfirmingClearAll = true
                }
                .disabled(dictations.isEmpty)
                .confirmationDialog(
                    "Delete all \(dictations.count) dictations?",
                    isPresented: $isConfirmingClearAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        DictationHistory.clear(in: modelContext)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This cannot be undone.")
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { dictation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        timestamp(for: dictation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if let destination = dictation.destination {
                            Text("→ \(destination)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let prompt = dictation.promptName {
                            Text(prompt)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }

                        Spacer()

                        Text("\(dictation.characterCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Text(dictation.text)
                        .textSelection(.enabled)
                        .lineLimit(4)

                    HStack(spacing: 12) {
                        Button {
                            ClipboardService.copy(dictation.text)
                            confirmCopy(.cleaned(dictation.persistentModelID))
                        } label: {
                            Label(
                                justCopied == .cleaned(dictation.persistentModelID) ? "Copied" : "Copy",
                                systemImage: justCopied == .cleaned(dictation.persistentModelID)
                                    ? "checkmark" : "doc.on.doc"
                            )
                        }

                        // The reason history exists: put it where it should have gone.
                        Button {
                            insert(dictation)
                        } label: {
                            Label("Insert", systemImage: "text.cursor")
                        }

                        if dictation.wasEditedByAI, let raw = dictation.rawText {
                            Button {
                                ClipboardService.copy(raw)
                                confirmCopy(.original(dictation.persistentModelID))
                            } label: {
                                Label(
                                    justCopied == .original(dictation.persistentModelID) ? "Copied" : "Copy Original",
                                    systemImage: justCopied == .original(dictation.persistentModelID)
                                        ? "checkmark" : "arrow.uturn.backward"
                                )
                            }
                            .help("The transcript before the AI rewrote it")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            modelContext.delete(dictation)
                            modelContext.saveOrLog()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The time alone for something dictated today; the date and time otherwise, so
    /// a week-old entry does not read as though it just happened.
    private func timestamp(for dictation: Dictation) -> Text {
        if Calendar.current.isDateInToday(dictation.createdAt) {
            return Text(dictation.createdAt, style: .time)
        }
        return Text(dictation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Show the checkmark, then take it back.
    ///
    /// Nothing else in the row ever clears it, so a row left showing "Copied" would
    /// still claim a copy that happened an hour ago.
    private func confirmCopy(_ kind: CopiedKind) {
        justCopied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justCopied == kind {
                justCopied = nil
            }
        }
    }

    /// Send it to whatever has focus now.
    ///
    /// Deliberately not the app it originally went to: the point is usually that the
    /// first destination was wrong.
    private func insert(_ dictation: Dictation) {
        Task {
            // Step out of the way first. While this window is frontmost the focused
            // text field is Inscribe's own search box, which is where the text used
            // to land.
            NSApp.hide(nil)
            try? await Task.sleep(for: .milliseconds(250))

            let outcome = await TextInsertionService.deliver(
                dictation.text,
                targetApp: NSWorkspace.shared.frontmostApplication,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: false
            )

            // Reported as a notification rather than in-window text: hiding
            // Inscribe above is what let the insert reach another app's text
            // field in the first place, so a banner drawn in this window would
            // report the outcome somewhere the user is no longer looking.
            let destination: String? = switch outcome {
            case .inserted(let appName): appName
            case .copiedToClipboard: nil
            }
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: dictation.text.count,
                destination: destination,
                settings: settings
            )
        }
    }
}
#endif
