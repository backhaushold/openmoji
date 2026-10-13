import OpenMojiCore
import SwiftUI

/// The audit log in Settings (ADR-0020): every prompt a sticker was asked
/// for, newest first, with when. Read-only: nothing here edits or clears it.
///
/// Text styles only, so everything follows Dynamic Type.
struct AuditLogView: View {
    /// Reads the log, newest first.
    let load: () async throws -> [PromptLogEntry]

    private enum Content {
        case loading
        case loaded([PromptLogEntry])
        case failed
    }

    @State private var content = Content.loading

    var body: some View {
        List {
            switch content {
            case .loading:
                ProgressView()
            case .failed:
                Text("Couldn't read the audit log.")
                    .foregroundStyle(.orange)
            case .loaded(let entries) where entries.isEmpty:
                Text("Nothing yet. Every description sent to make a sticker will be listed here.")
                    .foregroundStyle(.secondary)
            case .loaded(let entries):
                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.prompt)
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Every description sent to make a sticker, newest first. Kept on this iPad only.")
                }
            }
        }
        .navigationTitle("Audit log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                content = try await .loaded(load())
            } catch {
                content = .failed
            }
        }
    }
}
