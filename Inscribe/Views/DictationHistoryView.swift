import SwiftUI
import SwiftData

#if os(macOS)

/// Recent dictations, so one that landed in the wrong window is recoverable.
struct DictationHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Dictation.createdAt, order: .reverse) private var dictations: [Dictation]

    @State private var searchText = ""
    @State private var justCopied: PersistentIdentifier?

    /// What the last Insert did. The button used to throw its answer away, which left
    /// the user with no way to tell a successful paste from a silent miss.
    @State private var insertResult: String?

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

            if let insertResult {
                Text(insertResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .transition(.opacity)
                    .task(id: insertResult) {
                        try? await Task.sleep(for: .seconds(4))
                        self.insertResult = nil
                    }
            }
        }
        .animation(.default, value: insertResult)
        .navigationTitle("Dictation History")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            ToolbarItem {
                Button("Clear All", role: .destructive) {
                    DictationHistory.clear(in: modelContext)
                }
                .disabled(dictations.isEmpty)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { dictation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(dictation.createdAt, style: .time)
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
                            confirmCopy(of: dictation)
                        } label: {
                            Label(
                                justCopied == dictation.persistentModelID ? "Copied" : "Copy",
                                systemImage: justCopied == dictation.persistentModelID
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
                                confirmCopy(of: dictation)
                            } label: {
                                Label("Copy Original", systemImage: "arrow.uturn.backward")
                            }
                            .help("The transcript before the AI rewrote it")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            modelContext.delete(dictation)
                            try? modelContext.save()
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

    /// Show the checkmark, then take it back.
    ///
    /// Nothing else in the row ever clears it, so a row left showing "Copied" would
    /// still claim a copy that happened an hour ago.
    private func confirmCopy(of dictation: Dictation) {
        let id = dictation.persistentModelID
        justCopied = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justCopied == id {
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

            insertResult = switch outcome {
            case .inserted(let appName): "Sent to \(appName)."
            case .copiedToClipboard: "No text field was focused, so it is on your clipboard."
            }
        }
    }
}
#endif
