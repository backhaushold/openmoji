import SwiftUI

/// Switches on `AppModel.state`. Placeholder content only: Compose, Generating,
/// Preview and Error are separate beads. Settings is real: expanded with no
/// key opens it directly (FR-5), and a gear from idle opens it as a sheet.
struct RootView: View {
    let model: AppModel
    let settings: SettingsModel

    @State private var showingSettings = false

    var body: some View {
        content
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: settings) { showingSettings = false }
            }
            // Clearing the key routes to needs-key, whose Settings replaces the sheet.
            .onChange(of: model.state == .needsKey) { _, needsKey in
                if needsKey { showingSettings = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .needsKey:
            if model.presentationStyle == .expanded {
                // Done, once a key is saved, picks up the new key: needs-key → idle.
                SettingsView(model: settings) { model.refreshKey() }
            } else {
                Text("Set up OpenMoji")
            }
        case .idle:
            VStack {
                Text("OpenMoji")
                if model.presentationStyle == .expanded {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        case .generating:
            Text("Making your sticker…")
        case .preview:
            Text("Preview")
        case .failed(let error, _):
            Text(error.userMessage ?? "Something went wrong.")
        }
    }
}
